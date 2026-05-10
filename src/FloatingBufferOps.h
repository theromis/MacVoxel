#pragma once

#include <cstdint>

namespace macvoxel {

struct Bounds3;
struct Clipboard;
struct EditorContext;
class VoxelGrid;

// Move the active selection's voxels off the document into the floating
// buffer. After lift: doc cells at the selection coords are 0;
// FloatingBuffer.grid holds the cells at their original world coords;
// fb.offset = (0, 0, 0). The selection's voxels list is unchanged
// (still references the world coords; the renderer pulls cells from
// the floating buffer at those coords).
//
// Lift does NOT push to EditHistory. The buffer carries the pre-lift
// state on `source_originals` / `pre_lift_sel` instead; commit emits a
// single op covering the full pre-lift → post-commit delta so a single
// Cmd-Z reverses the entire move-and-drop gesture, and undo-while-
// floating uses CancelFloatingLift to put cells back without touching
// the history.
void LiftSelectionToFloating(EditorContext& ctx);

// Stamp the floating buffer's cells back onto the document at
// (cell + offset). Selection becomes the resulting cells. The buffer
// is cleared. Emits ONE EditHistory op covering the entire pre-lift
// state → post-commit state delta (so undo restores the doc and
// marquee atomically, regardless of how many drag / rotate / flip
// steps the user accumulated while floating).
//
// No-op when the buffer is inactive.
void CommitFloatingBuffer(EditorContext& ctx);

// "Roll back the floating gesture" — used when Cmd-Z fires while a
// buffer is alive. For a lift-style buffer: writes the source-original
// cells back into doc.grid, restores the pre-lift selection, and
// clears the buffer. For a paste-style buffer (no source cells):
// just discards. Either way, leaves history untouched (lift never
// pushed an op).
void CancelFloatingLift(EditorContext& ctx);

// Cancel the floating buffer without touching the document — the
// "throw it away" path for Esc / new-document. The selection's voxels
// list is cleared too since those positions no longer reference real
// cells.
void DiscardFloatingBuffer(EditorContext& ctx);

// Replace the floating buffer's grid with a nearest-neighbor stretch
// of `src` (originally bounded by `src_bounds`) into `new_bounds`.
// Used by the transform gizmo's face-handle scale: caller snapshots
// fb.grid + bounds at drag start, then this function rebuilds fb.grid
// from that snapshot every time the dragged face crosses a voxel
// boundary, so resampling is always lossless against the original
// (no compounding shrink-then-grow data loss).
//
// `new_bounds` is in fb-local grid coords. Caller is expected to
// bump fb.version after this returns.
void ResampleFloatingBuffer(EditorContext& ctx,
                            const VoxelGrid& src,
                            const Bounds3& src_bounds,
                            const Bounds3& new_bounds);

// Stage clipboard contents into the floating buffer at the given
// world-coord origin (the clipboard's bottom corner of its AABB).
// Document is NOT modified — the user can drag the buffer to a final
// position before commit. Selection is set to the pasted cells.
void LiftClipboardToFloating(EditorContext& ctx,
                             const Clipboard& cb,
                             int32_t origin_x,
                             int32_t origin_y,
                             int32_t origin_z);

}  // namespace macvoxel
