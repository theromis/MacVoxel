#pragma once

#include <array>
#include <cstdint>
#include <functional>
#include <vector>

namespace macvoxel {

struct EditorContext;

enum class Axis { X, Y, Z };

// Enumerate every occupied cell in the document that satisfies `pred`
// and return them as a list. Callers feed the list to
// `lift::LiftSelectionCells` to finalize a selection.
std::vector<std::array<int32_t, 3>> EnumerateCellsWhere(
    EditorContext& ctx,
    const std::function<bool(int32_t, int32_t, int32_t, uint8_t)>& pred);

// Flood select: BFS from `seed` across 6-connected neighbors that
// share its palette index, then lift the resulting cells. Empty seed
// (cell value 0) clears the selection.
void FloodSelectFromSeed(EditorContext& ctx, int32_t x, int32_t y, int32_t z);

// 90° rotation of the active lift around the named axis. Delegates to
// `lift::RotateLift`. No-op if no lift is active.
void RotateSelection(EditorContext& ctx, Axis axis, bool cw);

// Mirror the active lift across the plane perpendicular to the named
// axis through the lift center. Delegates to `lift::FlipLift`.
void FlipSelection(EditorContext& ctx, Axis axis);

}  // namespace macvoxel
