#pragma once

namespace macvoxel {

struct EditorContext;

enum class Axis { X, Y, Z };

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
