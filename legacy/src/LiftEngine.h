#pragma once

#include <cstddef>
#include <cstdint>

namespace macvoxel {

struct Bounds3;

// Pure-C++ params for the lift-transform kernel. World-cell coords;
// the engine translates the dst bbox into texture-local dispatch.
//
// `inv_map` is the integer inverse of the forward rotation /
// mirror — row-major 3×3 with entries in {-1, 0, 1}. For rotation
// matrices (orthogonal), inv_map = M_fwd^T; for axis-aligned mirror
// matrices, inv_map = M_fwd (self-inverse).
//
// `src_center` / `dst_center` are continuous voxel-space pivots: the
// CPU caller computes them as `min + dim * 0.5`. The kernel uses
// `src_p = inv_map * (dst_p - dst_center) + src_center;
// src_cell = int3(floor(src_p))` to gather from the lift snapshot.
//
// dst bbox is inclusive on both ends.
struct LiftTransformParams {
    int32_t dst_x0, dst_y0, dst_z0;
    int32_t dst_x1, dst_y1, dst_z1;
    int32_t inv_map[9];
    float   src_center[3];
    float   dst_center[3];
};

}  // namespace macvoxel

#ifdef __OBJC__

#import <Metal/Metal.h>

@class VolumeTexture;

// GPU-backed selection-lift kernel dispatcher. Six PSOs, one shared
// command queue with the other edit-time engines. All dispatches are
// async; callers fence via `waitForPendingWork`.
@interface LiftEngine : NSObject

- (nullable instancetype)initWithDevice:(nonnull id<MTLDevice>)device
                            commandQueue:(nonnull id<MTLCommandQueue>)queue;

// Selection-finalize. Reads tex_a over `worldBbox`, writes any non-
// zero cells into tex_lift, zeroes them in tex_a.
- (void)dispatchLiftBox:(nonnull VolumeTexture*)texture
              worldBbox:(const macvoxel::Bounds3&)bbox;

// Selection-finalize from a CPU cell list (flood-fill).
// `cells_xyz` is packed [x, y, z, x, y, z, ...] in world coords;
// `cellCount` is the entry count (not the int count).
- (void)dispatchLiftCells:(nonnull VolumeTexture*)texture
                    cells:(nonnull const int32_t*)cells_xyz
                cellCount:(NSUInteger)cellCount;

// Translate lift by `offset`. Reads tex_lift_snap (caller blits first
// via `encodeLiftSnapshot`), writes tex_lift over union(old, new).
- (void)dispatchLiftTranslate:(nonnull VolumeTexture*)texture
                  oldWorldBbox:(const macvoxel::Bounds3&)old_bbox
                  newWorldBbox:(const macvoxel::Bounds3&)new_bbox
                        offset:(int32_t[_Nonnull 3])offset;

// Transform lift via Magica's rotate_centered form. Snapshots the
// lift, then dispatches over `union(old_bbox, dst_bbox)`. The kernel
// gathers from the snapshot for cells inside dst_bbox and zeros
// every other cell in the dispatch range, so the old lift position
// is cleared in the same pass.
- (void)dispatchLiftTransform:(nonnull VolumeTexture*)texture
                       params:(const macvoxel::LiftTransformParams&)params
                      oldBbox:(const macvoxel::Bounds3&)old_bbox;

// Commit: blits non-zero tex_lift cells into tex_a; zeroes tex_lift.
- (void)dispatchLiftCommit:(nonnull VolumeTexture*)texture
                  worldBbox:(const macvoxel::Bounds3&)bbox;

// Zero a region of tex_lift.
- (void)dispatchLiftClear:(nonnull VolumeTexture*)texture
                worldBbox:(const macvoxel::Bounds3&)bbox;

- (void)waitForPendingWork;

@end

#endif  // __OBJC__
