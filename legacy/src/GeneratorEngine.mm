#import "GeneratorEngine.h"
#import "VolumeTexture.h"

#import <cstdio>
#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace gen = macvoxel::generators;

namespace {

NSString* LoadGeneratorLibrarySource() {
    NSURL* url = [NSBundle.mainBundle URLForResource:@"Generators"
                                       withExtension:@"metal"];
    if (url == nil) {
        fprintf(stderr,
                "MacVoxel: Generators.metal missing from bundle Resources\n");
        return nil;
    }
    NSError* error = nil;
    NSString* source = [NSString stringWithContentsOfURL:url
                                                encoding:NSUTF8StringEncoding
                                                   error:&error];
    if (source == nil) {
        fprintf(stderr,
                "MacVoxel: failed to read Generators.metal: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    return source;
}

NSString* KernelNameForKind(gen::Kind k) {
    switch (k) {
        case gen::Kind::Ellipsoid: return @"generate_ellipsoid";
        case gen::Kind::Cylinder:  return @"generate_cylinder";
        case gen::Kind::Cone:      return @"generate_cone";
        case gen::Kind::Pyramid:   return @"generate_pyramid";
        case gen::Kind::Perlin:    return @"generate_perlin";
        case gen::Kind::Torus:     return @"generate_torus";
        case gen::Kind::Tree:      return @"generate_tree";
        case gen::Kind::Helix:     return @"generate_helix";
        case gen::Kind::Conifer:   return @"generate_conifer";
        case gen::Kind::Count_:    return nil;
    }
    return nil;
}

// Mirror of Generators.metal's `Uniforms`. int3 fields are 16-byte aligned
// in MSL; the [4]-sized arrays here carry the trailing pad.
struct Uniforms {
    int32_t lo[4];
    int32_t dims[4];
    uint32_t palette_idx;
    uint32_t axis;
    uint32_t apex_at_max;
    uint32_t pad0;
    float    noise_scale;
    float    noise_threshold;
    uint32_t noise_octaves;
    uint32_t noise_seed;
    float    torus_tube;
    uint32_t perlin_palette_lo;
    uint32_t perlin_palette_hi;
    uint32_t pad1;
    float    helix_turns;
    float    helix_radius;
    float    helix_tube;
    uint32_t helix_clockwise;
    int32_t  dispatch_lo[4];
    int32_t  dispatch_size[4];
    int32_t  tex_origin[4];
};
static_assert(sizeof(Uniforms) == 144, "GeneratorUniforms layout drift");

}  // namespace

@implementation GeneratorEngine {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _pipelines[static_cast<size_t>(gen::Kind::Count_)];
    id<MTLCommandBuffer> _lastBuffer;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   commandQueue:(id<MTLCommandQueue>)queue {
    self = [super init];
    if (self == nil) return nil;
    _device = device;
    _queue = queue;

    NSString* source = LoadGeneratorLibrarySource();
    if (source == nil) return nil;
    NSError* error = nil;
    id<MTLLibrary> library =
        [_device newLibraryWithSource:source
                              options:nil
                                error:&error];
    if (library == nil) {
        fprintf(stderr,
                "MacVoxel: failed to compile generator kernels: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }

    for (size_t i = 0; i < static_cast<size_t>(gen::Kind::Count_); ++i) {
        NSString* name = KernelNameForKind(static_cast<gen::Kind>(i));
        id<MTLFunction> fn = [library newFunctionWithName:name];
        if (fn == nil) {
            fprintf(stderr,
                    "MacVoxel: missing generator kernel '%s'\n",
                    [name UTF8String]);
            return nil;
        }
        _pipelines[i] = [_device newComputePipelineStateWithFunction:fn
                                                                error:&error];
        if (_pipelines[i] == nil) {
            fprintf(stderr,
                    "MacVoxel: failed to build pipeline '%s': %s\n",
                    [name UTF8String],
                    [[error localizedDescription] UTF8String]);
            return nil;
        }
    }

    return self;
}

- (void)dispatchInto:(VolumeTexture*)texture
                kind:(gen::Kind)kind
              bounds:(gen::Bounds3i)bounds
          lastBounds:(gen::Bounds3i)last_bounds
                clip:(gen::Bounds3i)clip
              params:(const gen::Params&)params {
    if (texture == nil) return;
    const NSUInteger ki = static_cast<NSUInteger>(kind);
    if (ki >= static_cast<NSUInteger>(gen::Kind::Count_)) return;
    id<MTLComputePipelineState> pso = _pipelines[ki];
    if (pso == nil) return;

    // Dispatch bbox = union(bounds, last_bounds) in WORLD coords,
    // clamped to the texture's extent, then translated to texture-local.
    const int32_t tex_lo_x = texture.originX;
    const int32_t tex_lo_y = texture.originY;
    const int32_t tex_lo_z = texture.originZ;
    const int32_t tex_hi_x = tex_lo_x + texture.sizeX - 1;
    const int32_t tex_hi_y = tex_lo_y + texture.sizeY - 1;
    const int32_t tex_hi_z = tex_lo_z + texture.sizeZ - 1;

    int32_t ux0 = bounds.x0, uy0 = bounds.y0, uz0 = bounds.z0;
    int32_t ux1 = bounds.x1, uy1 = bounds.y1, uz1 = bounds.z1;
    if (last_bounds.x1 >= last_bounds.x0) {
        ux0 = std::min(ux0, last_bounds.x0);
        uy0 = std::min(uy0, last_bounds.y0);
        uz0 = std::min(uz0, last_bounds.z0);
        ux1 = std::max(ux1, last_bounds.x1);
        uy1 = std::max(uy1, last_bounds.y1);
        uz1 = std::max(uz1, last_bounds.z1);
    }
    ux0 = std::max(ux0, std::max(tex_lo_x, clip.x0));
    uy0 = std::max(uy0, std::max(tex_lo_y, clip.y0));
    uz0 = std::max(uz0, std::max(tex_lo_z, clip.z0));
    ux1 = std::min(ux1, std::min(tex_hi_x, clip.x1));
    uy1 = std::min(uy1, std::min(tex_hi_y, clip.y1));
    uz1 = std::min(uz1, std::min(tex_hi_z, clip.z1));
    if (ux0 > ux1 || uy0 > uy1 || uz0 > uz1) return;

    const int32_t dx = ux1 - ux0 + 1;
    const int32_t dy = uy1 - uy0 + 1;
    const int32_t dz = uz1 - uz0 + 1;

    Uniforms u{};
    u.lo[0] = bounds.x0;
    u.lo[1] = bounds.y0;
    u.lo[2] = bounds.z0;
    u.dims[0] = bounds.x1 - bounds.x0 + 1;
    u.dims[1] = bounds.y1 - bounds.y0 + 1;
    u.dims[2] = bounds.z1 - bounds.z0 + 1;
    u.palette_idx = params.palette_idx;
    u.axis = params.axis;
    u.apex_at_max = params.apex_at_max;
    u.noise_scale = params.noise_scale;
    u.noise_threshold = params.noise_threshold;
    u.noise_octaves = params.noise_octaves;
    u.noise_seed = params.noise_seed;
    u.torus_tube = params.torus_tube;
    u.perlin_palette_lo = params.perlin_palette_lo;
    u.perlin_palette_hi = params.perlin_palette_hi;
    u.helix_turns = params.helix_turns;
    u.helix_radius = params.helix_radius;
    u.helix_tube = params.helix_tube;
    u.helix_clockwise = params.helix_clockwise;
    u.dispatch_lo[0] = ux0 - tex_lo_x;
    u.dispatch_lo[1] = uy0 - tex_lo_y;
    u.dispatch_lo[2] = uz0 - tex_lo_z;
    u.dispatch_size[0] = dx;
    u.dispatch_size[1] = dy;
    u.dispatch_size[2] = dz;
    u.tex_origin[0] = tex_lo_x;
    u.tex_origin[1] = tex_lo_y;
    u.tex_origin[2] = tex_lo_z;

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"GeneratorDispatch";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:pso];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setTexture:texture.previewTexture atIndex:0];
    [enc setTexture:texture.previewOracleTexture atIndex:1];

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
