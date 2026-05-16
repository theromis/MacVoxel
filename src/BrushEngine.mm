#import "BrushEngine.h"
#import "VolumeTexture.h"

#import <cstdio>
#include <algorithm>
#include <cstdint>
#include <cstring>

namespace {

// Mirror of BrushKernel.metal's `Uniforms`. simd-aligned via padding.
struct Uniforms {
    int32_t center[4];
    int32_t face_axis[4];
    int32_t lo[4];
    int32_t size[4];
    uint32_t flags;
    uint32_t mode;
    uint32_t palette_idx;
    uint32_t _pad0;
    int32_t vol_min[4];
    int32_t vol_max[4];
    int32_t tex_origin[4];
    float center_offset_x10;
    float r2;
    float _pad1[2];
};

NSString* LoadBrushLibrarySource() {
    NSURL* url = [NSBundle.mainBundle URLForResource:@"BrushKernel"
                                       withExtension:@"metal"];
    if (url == nil) {
        fprintf(stderr,
                "MacVoxel: BrushKernel.metal missing from bundle Resources\n");
        return nil;
    }
    NSError* error = nil;
    NSString* source = [NSString stringWithContentsOfURL:url
                                                encoding:NSUTF8StringEncoding
                                                   error:&error];
    if (source == nil) {
        fprintf(stderr,
                "MacVoxel: failed to read BrushKernel.metal: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    return source;
}

}  // namespace

@implementation BrushEngine {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _pipeline;
    // Most recent command buffer enqueued. waitForPendingWork awaits
    // it; subsequent dispatches don't need to track previous buffers
    // because the queue serializes them.
    id<MTLCommandBuffer> _lastBuffer;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   commandQueue:(id<MTLCommandQueue>)queue {
    self = [super init];
    if (self == nil) return nil;
    _device = device;
    _queue = queue;

    NSString* source = LoadBrushLibrarySource();
    if (source == nil) return nil;
    NSError* error = nil;
    id<MTLLibrary> library =
        [_device newLibraryWithSource:source options:nil error:&error];
    if (library == nil) {
        fprintf(stderr, "MacVoxel: failed to compile brush kernel: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    id<MTLFunction> fn = [library newFunctionWithName:@"brush_main"];
    if (fn == nil) {
        fprintf(stderr, "MacVoxel: missing brush kernel 'brush_main'\n");
        return nil;
    }
    _pipeline = [_device newComputePipelineStateWithFunction:fn error:&error];
    if (_pipeline == nil) {
        fprintf(stderr, "MacVoxel: failed to build brush pipeline: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    return self;
}

- (void)dispatch:(const macvoxel::BrushParams&)p
          target:(VolumeTexture*)texture {
    if (_pipeline == nil || texture == nil) return;
    if (p.size_x <= 0 || p.size_y <= 0 || p.size_z <= 0) return;

    Uniforms u{};
    u.center[0] = p.cx; u.center[1] = p.cy; u.center[2] = p.cz;
    u.face_axis[0] = p.face_axis;
    u.lo[0] = p.lo_x; u.lo[1] = p.lo_y; u.lo[2] = p.lo_z;
    u.size[0] = p.size_x; u.size[1] = p.size_y; u.size[2] = p.size_z;
    u.flags = p.flags;
    u.mode = p.mode;
    u.palette_idx = p.palette_idx;
    u.vol_min[0] = p.vol_x0; u.vol_min[1] = p.vol_y0; u.vol_min[2] = p.vol_z0;
    u.vol_max[0] = p.vol_x1; u.vol_max[1] = p.vol_y1; u.vol_max[2] = p.vol_z1;
    u.tex_origin[0] = p.vol_x0;
    u.tex_origin[1] = p.vol_y0;
    u.tex_origin[2] = p.vol_z0;
    u.center_offset_x10 = p.center_offset_x10;
    u.r2 = p.r2;

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"BrushDispatch";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_pipeline];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setTexture:texture.texture atIndex:0];
    [enc setTexture:texture.oracleTexture atIndex:1];

    const NSUInteger tgX = std::min<NSUInteger>(8, (NSUInteger)p.size_x);
    const NSUInteger tgY = std::min<NSUInteger>(8, (NSUInteger)p.size_y);
    const NSUInteger tgZ = std::min<NSUInteger>(8, (NSUInteger)p.size_z);
    const MTLSize threadsPerThreadgroup = MTLSizeMake(tgX, tgY, tgZ);
    const MTLSize threadgroups = MTLSizeMake(
        ((NSUInteger)p.size_x + tgX - 1) / tgX,
        ((NSUInteger)p.size_y + tgY - 1) / tgY,
        ((NSUInteger)p.size_z + tgZ - 1) / tgZ);
    [enc dispatchThreadgroups:threadgroups
        threadsPerThreadgroup:threadsPerThreadgroup];
    [enc endEncoding];
    // Fire-and-forget. Subsequent dispatches queue behind this one on
    // the same command queue, which guarantees in-order kernel
    // execution.
    [cmd commit];
    _lastBuffer = cmd;
}

- (void)waitForPendingWork {
    if (_lastBuffer == nil) return;
    [_lastBuffer waitUntilCompleted];
    _lastBuffer = nil;
}

- (void)readTextureRegion:(std::vector<uint8_t>*)out
                   target:(VolumeTexture*)texture
                     bbox:(const macvoxel::Bbox3&)bbox {
    if (out == nullptr || texture == nil) return;
    // The bbox is in WORLD cell coords; translate to texture-local
    // (texture origin is the EditVolume's lo corner).
    const int32_t origin_x = bbox.x0 - texture.sizeX  // dummy use of
                              + texture.sizeX;
    (void)origin_x;
    // VolumeTexture doesn't expose its origin separately, but it's
    // always vol.x0 / vol.y0 / vol.z0 by construction. Pass world
    // coords minus those — caller (BrushController::SyncStrokeFrom-
    // Texture) clipped the bbox to volume bounds, so we can read
    // straight via tex.replaceRegion-inverse.
    //
    // Compute local indices using the texture's actual dimensions
    // (sizeX/Y/Z are populated from the volume). Origin = world (vol_x0,
    // vol_y0, vol_z0) → local 0.
    //
    // To keep this self-contained, we don't ask VolumeTexture for its
    // EditVolume — instead infer it by assuming bbox is already inside
    // [0, sizeX) etc. once translated. Callers in BrushController
    // produce bboxes inside the volume, so this holds; we still clamp
    // defensively below.
    int32_t lx0 = bbox.x0;
    int32_t ly0 = bbox.y0;
    int32_t lz0 = bbox.z0;
    int32_t lx1 = bbox.x1;
    int32_t ly1 = bbox.y1;
    int32_t lz1 = bbox.z1;
    // World→local conversion happens at the call site by subtracting
    // EditVolume's lo (VolumeTexture's origin). MetalScene's closure
    // does that subtraction; this method assumes bbox is already
    // local to the texture.
    if (lx0 < 0) lx0 = 0;
    if (ly0 < 0) ly0 = 0;
    if (lz0 < 0) lz0 = 0;
    if (lx1 >= texture.sizeX) lx1 = texture.sizeX - 1;
    if (ly1 >= texture.sizeY) ly1 = texture.sizeY - 1;
    if (lz1 >= texture.sizeZ) lz1 = texture.sizeZ - 1;
    if (lx0 > lx1 || ly0 > ly1 || lz0 > lz1) { out->clear(); return; }

    const NSUInteger w = (NSUInteger)(lx1 - lx0 + 1);
    const NSUInteger h = (NSUInteger)(ly1 - ly0 + 1);
    const NSUInteger d = (NSUInteger)(lz1 - lz0 + 1);
    out->resize(w * h * d);

    MTLRegion region = MTLRegionMake3D(
        (NSUInteger)lx0, (NSUInteger)ly0, (NSUInteger)lz0, w, h, d);
    [texture.texture getBytes:out->data()
                  bytesPerRow:w
                bytesPerImage:w * h
                   fromRegion:region
                  mipmapLevel:0
                        slice:0];
}

@end
