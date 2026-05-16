#pragma once

#include <cstdint>
#include <vector>

namespace macvoxel {

// Pure-C++ brush parameters. Built by BrushController from
// ToolSettings + the current target cell; passed down to BrushEngine
// via the closure pattern (`brush_controller::StampFn`). Mirrored
// in MSL by Uniforms in BrushKernel.metal.
struct BrushParams {
    int32_t cx, cy, cz;        // brush center cell
    int32_t face_axis;         // 0=X, 1=Y, 2=Z (for 2D slab/disc)
    int32_t lo_x, lo_y, lo_z;  // footprint min offset from center
    int32_t size_x, size_y, size_z;  // footprint dims
    uint32_t flags;            // bit 0 = is_3d, bit 1 = is_circle
    uint32_t mode;             // 0=Add, 1=Remove, 2=Paint
    uint32_t palette_idx;      // 0..255
    int32_t vol_x0, vol_y0, vol_z0;
    int32_t vol_x1, vol_y1, vol_z1;
    float center_offset_x10;   // (lo + hi) * 5 to keep int→float clean
    float r2;                  // (max_dim * 0.5)^2
};

// 3D AABB inclusive on both ends. Used to describe the texture region
// touched by a stroke; populated by BrushController as the union of
// per-stamp footprints, and read by BrushEngine::readTextureRegion
// at end-of-stroke to get post-stroke cell bytes for diff computation.
struct Bbox3 {
    int32_t x0, y0, z0;
    int32_t x1, y1, z1;
};

}  // namespace macvoxel

#ifdef __OBJC__

#import <Metal/Metal.h>

@class VolumeTexture;

// Async brush dispatcher.
//
// During a stroke each call to `dispatch:target:` enqueues a compute
// kernel onto a dedicated command queue *without* waiting for it. The
// GPU texture becomes the authoritative state mid-stroke; CPU-side
// VoxelGrid and VoxelVolume stay frozen at the pre-stroke state until
// BrushController syncs them at OnMouseUp.
//
// Lifecycle:
//   - `dispatch:target:` per stamp during the drag.
//   - `waitForPendingWork` at OnMouseUp barriers the queue so the
//     subsequent texture readback sees all the writes.
//   - `readTextureRegion:texture:bbox:` blits the bbox out of the
//     texture into a CPU-accessible vector for diff against the
//     still-pre-stroke shadow.
@interface BrushEngine : NSObject

- (nullable instancetype)initWithDevice:(nonnull id<MTLDevice>)device
                            commandQueue:(nonnull id<MTLCommandQueue>)queue;

// Enqueue a brush kernel dispatch against `texture`. Async — returns
// once the command buffer is committed. Subsequent dispatches on this
// engine queue serially behind it (no inter-dispatch race).
- (void)dispatch:(const macvoxel::BrushParams&)params
          target:(nonnull VolumeTexture*)texture;

// Block until every dispatch enqueued so far has completed on the GPU.
// Required before `readTextureRegion:` so the readback sees the latest
// kernel writes.
- (void)waitForPendingWork;

// Synchronously read the bbox region of `texture` into `out`. `out` is
// resized to bbox volume bytes; layout is x-fastest, then y, then z
// (same as the dense buffer that backed VoxelVolume::data).
- (void)readTextureRegion:(nonnull std::vector<uint8_t>*)out
                   target:(nonnull VolumeTexture*)texture
                     bbox:(const macvoxel::Bbox3&)bbox;

@end

#endif  // __OBJC__
