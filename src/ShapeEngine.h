#pragma once

#include <cstdint>

namespace macvoxel {

// Pure-C++ shape-kernel parameters. Built by ShapeController each
// mouseDragged event and handed to ShapeEngine via the closure
// pattern; mirrored in MSL by ShapeUniforms in ShapeKernel.metal.
struct ShapeParams {
    int32_t anchor_x, anchor_y, anchor_z;
    int32_t endpoint_x, endpoint_y, endpoint_z;
    int32_t face_axis;
    int32_t brush_size;
    int32_t brush_shape;   // 0 square, 1 circle
    int32_t brush_3d;
    uint32_t mode;         // 0 add / 1 remove / 2 paint
    uint32_t palette_idx;
    int32_t shape_kind;    // 0 line / 1 circle / 2 square / 3 box
    int32_t shape_fill;
    int32_t shape_even;
    int32_t line_straight;
    // Dispatch bbox in *texture-local* cells (i.e. world cell minus
    // EditVolume's lo). The kernel evaluates / clears every cell in
    // this region — union with the previous frame's bbox so the
    // previous preview gets zeroed where the new one doesn't cover.
    int32_t dispatch_lo_x, dispatch_lo_y, dispatch_lo_z;
    int32_t dispatch_size_x, dispatch_size_y, dispatch_size_z;
    int32_t vol_min_x, vol_min_y, vol_min_z;
    int32_t vol_max_x, vol_max_y, vol_max_z;
    int32_t tex_origin_x, tex_origin_y, tex_origin_z;
};

// One entry of the (cell, palette) buffer consumed by Face's stamp /
// commit kernels. World cell coords. palette == 0 means "this cell
// should become empty on commit" — the stamp kernel writes 0 to
// tex_t (silent preview); the commit kernel writes 0 to tex_a.
struct CellPalette {
    int32_t x, y, z;
    uint32_t palette;
};

// Pure-C++ parameters for the generic commit kernel — the Magica
// `shader_0018.glsl` shape. `bm` (blend mode) and `brush` (source
// selector) match the MSL constants in `ShapeKernel.metal`.
//
// bm:    1 = Add (fill where doc is empty)
//        2 = Erase (zero doc where preview is set)
//        3 = Replace (write preview where both doc and preview are set)
//        4 = Intersect (clear doc where preview is empty)
// brush: 0 = sample preview texture (tex_t)
//        1 = use the `fill_palette` constant per cell
struct CommitGenericParams {
    // Dispatch bbox in texture-local cells (world cell minus
    // EditVolume's lo).
    int32_t dispatch_lo_x, dispatch_lo_y, dispatch_lo_z;
    int32_t dispatch_size_x, dispatch_size_y, dispatch_size_z;
    uint32_t bm;
    uint32_t brush;
    uint32_t fill_palette;  // used when brush == 1
};

}  // namespace macvoxel

#ifdef __OBJC__

#import <Metal/Metal.h>

@class VolumeTexture;

// Dispatches the shape preview + clear + commit kernels for the four
// shape tools (Line / Circle / Square / Box). Same async pattern as
// BrushEngine: a dedicated command queue, fire-and-forget dispatches
// during the stroke, `waitForPendingWork` at end-of-stroke.
@interface ShapeEngine : NSObject

- (nullable instancetype)initWithDevice:(nonnull id<MTLDevice>)device
                            commandQueue:(nonnull id<MTLCommandQueue>)queue;

// Dispatch the shape kernel against `texture`'s preview tex. Writes
// palette cells inside the shape and zeros outside cells within the
// dispatch bbox. Async.
- (void)dispatchPreview:(const macvoxel::ShapeParams&)params
                  target:(nonnull VolumeTexture*)texture;

// Dispatch the Line tool's project-mode kernel. The picked cells
// (one per oversampled screen-space step, deduped on the CPU) are
// uploaded into the engine's reusable buffer and the kernel runs
// over the dispatch bbox testing brush-footprint distance to any
// picked cell. `cells_xyz` is packed [x,y,z, x,y,z, ...] in world
// cell coords; `cell_count` is the entry count (not the int count).
- (void)dispatchLineProjectPreview:(const macvoxel::ShapeParams&)params
                              cells:(nonnull const int32_t*)cells_xyz
                         cellCount:(NSUInteger)cell_count
                             target:(nonnull VolumeTexture*)texture;

// Zero a 3D region of the preview tex. Used to wipe the active
// stroke's preview on cancel / abandon. Async.
- (void)clearPreviewBbox:(int)x0 y0:(int)y0 z0:(int)z0
                       x1:(int)x1 y1:(int)y1 z1:(int)z1
                   target:(nonnull VolumeTexture*)texture;

// Promote the preview cells inside the dispatch bbox into the doc
// texture + doc oracle, applying the mode rule (Add only fills
// empty, Paint only repaints occupied, Remove zeroes any). Clears
// the preview cells. Async; caller follows with `waitForPendingWork`
// + a doc-texture readback to compute the per-cell history diff.
- (void)commitShape:(const macvoxel::ShapeParams&)params
             target:(nonnull VolumeTexture*)texture;

// Per-cell stamp: write each entry's palette into tex_t. The Face
// controller's hot path uses this — CPU does the flood-fill +
// mode-aware extrusion enumeration, the kernel just splats palettes.
- (void)dispatchStampCells:(nonnull const macvoxel::CellPalette*)cells
                 cellCount:(NSUInteger)cell_count
                    target:(nonnull VolumeTexture*)texture;

// Per-cell commit: write each entry's palette directly into tex_a
// (clearing the corresponding tex_t cell). Used by the Face tool at
// OnMouseUp — handles Add / Remove / Paint uniformly because the
// CPU pre-computed the target value per cell.
- (void)dispatchCommitCells:(nonnull const macvoxel::CellPalette*)cells
                  cellCount:(NSUInteger)cell_count
                     target:(nonnull VolumeTexture*)texture;

// Generic commit — blends tex_t (or a constant) into tex_a over a
// dispatch bbox per `bm` / `brush` selectors. Phase 2.2+ routes
// Shape, Generator, Face, and Brush commits through this one kernel.
- (void)dispatchCommitGeneric:(const macvoxel::CommitGenericParams&)params
                       target:(nonnull VolumeTexture*)texture;

- (void)waitForPendingWork;

@end

#endif  // __OBJC__
