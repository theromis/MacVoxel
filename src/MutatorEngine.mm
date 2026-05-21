#import "MutatorEngine.h"

#import "VolumeTexture.h"

#import <cstdio>
#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace mut = macvoxel::mutators;

namespace {

NSString* LoadMutatorLibrarySource() {
    NSURL* url = [NSBundle.mainBundle URLForResource:@"Mutators"
                                       withExtension:@"metal"];
    if (url == nil) {
        fprintf(stderr,
                "MacVoxel: Mutators.metal missing from bundle Resources\n");
        return nil;
    }
    NSError* error = nil;
    NSString* source = [NSString stringWithContentsOfURL:url
                                                encoding:NSUTF8StringEncoding
                                                   error:&error];
    if (source == nil) {
        fprintf(stderr,
                "MacVoxel: failed to read Mutators.metal: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    return source;
}

NSString* KernelNameForKind(mut::Kind k) {
    switch (k) {
        case mut::Kind::Foliage: return @"foliage_main";
        case mut::Kind::Count_:  return nil;
    }
    return nil;
}

// Mirror of MutatorUniforms in Mutators.metal. Each int3 occupies 16
// bytes in MSL (12 used, 4 pad); the trailing-pad int32_t[4] arrays
// here keep the layout matched.
struct MutatorUniforms {
    int32_t dispatch_lo[4];
    int32_t dispatch_size[4];
    int32_t tex_origin[4];
    int32_t vol_min[4];
    int32_t vol_max[4];
    int32_t aoe_center[4];
    int32_t aoe_lo[4];
    int32_t aoe_hi[4];
    uint32_t kind;
    uint32_t seed_color;
    float    density;
    uint32_t stroke_id;
    int32_t  brush_size;
    int32_t  brush_shape;
    int32_t  brush_3d;
    int32_t  face_axis;
};

}  // namespace

@implementation MutatorEngine {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _pipelines[static_cast<size_t>(mut::Kind::Count_)];
    id<MTLCommandBuffer> _lastBuffer;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   commandQueue:(id<MTLCommandQueue>)queue {
    self = [super init];
    if (self == nil) return nil;
    _device = device;
    _queue = queue;

    NSString* source = LoadMutatorLibrarySource();
    if (source == nil) return nil;
    NSError* error = nil;
    id<MTLLibrary> library =
        [_device newLibraryWithSource:source options:nil error:&error];
    if (library == nil) {
        fprintf(stderr,
                "MacVoxel: failed to compile mutator kernels: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }

    for (size_t i = 0; i < static_cast<size_t>(mut::Kind::Count_); ++i) {
        NSString* name = KernelNameForKind(static_cast<mut::Kind>(i));
        id<MTLFunction> fn = [library newFunctionWithName:name];
        if (fn == nil) {
            fprintf(stderr,
                    "MacVoxel: missing mutator kernel '%s'\n",
                    [name UTF8String]);
            return nil;
        }
        _pipelines[i] = [_device newComputePipelineStateWithFunction:fn
                                                               error:&error];
        if (_pipelines[i] == nil) {
            fprintf(stderr,
                    "MacVoxel: failed to build mutator pipeline '%s': %s\n",
                    [name UTF8String],
                    [[error localizedDescription] UTF8String]);
            return nil;
        }
    }

    return self;
}

- (void)dispatchInto:(VolumeTexture*)texture
              params:(const macvoxel::MutatorDispatchParams&)p {
    if (texture == nil) return;
    const NSUInteger ki = static_cast<NSUInteger>(p.kind);
    if (ki >= static_cast<NSUInteger>(mut::Kind::Count_)) return;
    id<MTLComputePipelineState> pso = _pipelines[ki];
    if (pso == nil) return;

    const int32_t tex_lo_x = texture.originX;
    const int32_t tex_lo_y = texture.originY;
    const int32_t tex_lo_z = texture.originZ;
    const int32_t tex_hi_x = tex_lo_x + texture.sizeX - 1;
    const int32_t tex_hi_y = tex_lo_y + texture.sizeY - 1;
    const int32_t tex_hi_z = tex_lo_z + texture.sizeZ - 1;

    int32_t x0 = std::max(p.aoe_x0, tex_lo_x);
    int32_t y0 = std::max(p.aoe_y0, tex_lo_y);
    int32_t z0 = std::max(p.aoe_z0, tex_lo_z);
    int32_t x1 = std::min(p.aoe_x1, tex_hi_x);
    int32_t y1 = std::min(p.aoe_y1, tex_hi_y);
    int32_t z1 = std::min(p.aoe_z1, tex_hi_z);
    if (x0 > x1 || y0 > y1 || z0 > z1) return;

    const int32_t dx = x1 - x0 + 1;
    const int32_t dy = y1 - y0 + 1;
    const int32_t dz = z1 - z0 + 1;

    MutatorUniforms u{};
    u.dispatch_lo[0] = x0 - tex_lo_x;
    u.dispatch_lo[1] = y0 - tex_lo_y;
    u.dispatch_lo[2] = z0 - tex_lo_z;
    u.dispatch_size[0] = dx;
    u.dispatch_size[1] = dy;
    u.dispatch_size[2] = dz;
    u.tex_origin[0] = tex_lo_x;
    u.tex_origin[1] = tex_lo_y;
    u.tex_origin[2] = tex_lo_z;
    u.vol_min[0] = tex_lo_x;
    u.vol_min[1] = tex_lo_y;
    u.vol_min[2] = tex_lo_z;
    u.vol_max[0] = tex_hi_x;
    u.vol_max[1] = tex_hi_y;
    u.vol_max[2] = tex_hi_z;
    u.aoe_center[0] = p.center_x;
    u.aoe_center[1] = p.center_y;
    u.aoe_center[2] = p.center_z;
    u.aoe_lo[0] = p.aoe_x0;
    u.aoe_lo[1] = p.aoe_y0;
    u.aoe_lo[2] = p.aoe_z0;
    u.aoe_hi[0] = p.aoe_x1;
    u.aoe_hi[1] = p.aoe_y1;
    u.aoe_hi[2] = p.aoe_z1;
    u.kind = static_cast<uint32_t>(p.kind);
    u.seed_color = p.seed_color;
    u.density = p.density;
    u.stroke_id = p.stroke_id;
    u.brush_size = p.brush_size;
    u.brush_shape = p.brush_shape;
    u.brush_3d = p.brush_3d;
    u.face_axis = p.face_axis;

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"MutatorDispatch";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:pso];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setTexture:texture.texture                   atIndex:0];
    [enc setTexture:texture.previewTexture            atIndex:1];
    [enc setTexture:texture.previewOracleTexture      atIndex:2];
    [enc setTexture:texture.previewRemTexture         atIndex:3];

    const NSUInteger tgX = std::min<NSUInteger>(8, static_cast<NSUInteger>(dx));
    const NSUInteger tgY = std::min<NSUInteger>(8, static_cast<NSUInteger>(dy));
    const NSUInteger tgZ = std::min<NSUInteger>(8, static_cast<NSUInteger>(dz));
    const MTLSize threadsPerThreadgroup = MTLSizeMake(tgX, tgY, tgZ);
    const MTLSize threadgroups = MTLSizeMake(
        (static_cast<NSUInteger>(dx) + tgX - 1) / tgX,
        (static_cast<NSUInteger>(dy) + tgY - 1) / tgY,
        (static_cast<NSUInteger>(dz) + tgZ - 1) / tgZ);
    [enc dispatchThreadgroups:threadgroups
        threadsPerThreadgroup:threadsPerThreadgroup];
    [enc endEncoding];
    [cmd commit];
    _lastBuffer = cmd;
}

- (void)waitForPendingWork {
    if (_lastBuffer == nil) return;
    [_lastBuffer waitUntilCompleted];
    _lastBuffer = nil;
}

@end
