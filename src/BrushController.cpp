#include "BrushController.h"

#include "BrushOps.h"
#include "EditHistory.h"
#include "EditorContext.h"
#include "Input.h"
#include "Shapes.h"
#include "ViewContext.h"

#include <cstdint>

namespace macvoxel::brush_controller {
namespace {

// Sentinel for "no last-edit cell" so the per-stroke dedupe doesn't
// short-circuit the very first stamp at (0,0,0).
constexpr shapes::Vec3i kInvalidCell{INT32_MIN, INT32_MIN, INT32_MIN};

inline bool SameCell(const shapes::Vec3i& a, const shapes::Vec3i& b) {
    return a.x == b.x && a.y == b.y && a.z == b.z;
}

// Cursor → cell pick + dedupe + stamp. Shared between OnMouseDown
// (first stroke point) and OnMouseDragged (subsequent points).
void StampAtCursor(EditorContext& ctx, InteractionState& state,
                   const ViewContext& vc, const MouseEvent& e,
                   ToolMode mode) {
    shapes::Vec3i target;
    int face_axis = 2;
    if (!vc.ComputeTargetCell(e.local.x, e.local.y, mode, &target,
                              &face_axis, state.brush.drag_skip_cells)) {
        return;
    }

    // Drag-paint dedupe: only fire when the target cell changes. Without
    // this, every pointer-move event during a drag (many per frame) would
    // re-apply the brush to the same cell, which is harmless for Add but
    // bloats the undo history and produces N²-style work for Paint.
    if (SameCell(target, state.brush.last_drag_edit_cell)) {
        return;
    }
    state.brush.last_drag_edit_cell = target;

    StampBrushFootprint(ctx, target.x, target.y, target.z,
                        face_axis, mode, /*preview=*/false,
                        &state.brush.drag_skip_cells);
}

}  // namespace

void OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e) {
    // Cmd flips the stroke to Remove. Capture mode at click so a
    // mid-stroke panel change doesn't partway-flip the operation.
    const ToolMode mode = e.mods.command ? ToolMode::Remove : ctx.tool.mode;
    state.drag_mode = DragMode::Paint;
    state.brush.paint_mode = mode;
    state.brush.last_drag_edit_cell = kInvalidCell;
    state.brush.drag_skip_cells.clear();
    ctx.history.BeginOp();
    StampAtCursor(ctx, state, vc, e, mode);
}

void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e) {
    StampAtCursor(ctx, state, vc, e, state.brush.paint_mode);
}

void OnMouseUp(EditorContext& ctx, InteractionState& state) {
    ctx.history.CommitOp();
    state.brush.drag_skip_cells.clear();
}

}  // namespace macvoxel::brush_controller
