#pragma once

#include <cstdint>
#include <functional>

namespace macvoxel {

struct EditorContext;

enum class Axis { X, Y, Z };

// Iterate every occupied cell in the document, call `pred` on each,
// and replace the active selection with the cells where `pred`
// returned true. Empty result clears the selection. One-shot
// O(filled_count); used by both Marquee and BoxSelect at the commit
// edge of the gesture.
void SelectCellsWhere(
    EditorContext& ctx,
    const std::function<bool(int32_t, int32_t, int32_t, uint8_t)>& pred);

// Flood select: BFS from `seed` across 6-connected neighbors that
// share its palette index, replace the active selection with the
// resulting cell list. Empty seed (cell value 0) clears the
// selection. Stops at the first non-matching neighbor in each
// direction; the connected region need not be convex / simply
// connected.
void FloodSelectFromSeed(EditorContext& ctx, int32_t x, int32_t y, int32_t z);

// 90° rotation of the active selection around the named axis. `cw` is
// "clockwise as viewed from +axis looking toward origin" (right-hand
// rule with the negative of the axis vector). Pivots around the
// selection AABB center; for selections with mixed odd / even
// dimensions on the in-plane axes the result can shift by half a
// voxel because that's what the integer lattice forces. Single
// EditHistory op so undo restores both the grid and the marquee.
void RotateSelection(EditorContext& ctx, Axis axis, bool cw);

// Mirror the active selection across the plane perpendicular to the
// named axis through the selection AABB center. Single EditHistory op.
void FlipSelection(EditorContext& ctx, Axis axis);

}  // namespace macvoxel
