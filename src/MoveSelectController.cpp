#include "MoveSelectController.h"

#include "EditorContext.h"
#include "FloatingBuffer.h"
#include "FloatingBufferOps.h"
#include "Input.h"
#include "Selection.h"
#include "Shapes.h"
#include "ViewContext.h"
#include "VoxelGrid.h"

#include <cmath>

namespace macvoxel::move_select_controller {

bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e) {
    shapes::Vec3i cell;
    int axis = 2;
    int sign = 1;
    uint8_t color = 0;
    if (!vc.PickFace(e.local.x, e.local.y, &cell, &axis, &sign, &color)) {
        return false;
    }

    FloatingBuffer& fb = ctx.floating_buffer;
    if (!fb.active) {
        // Buffer is not floating yet → lift the on-grid selection into
        // it. Click membership has to be against the selected cells
        // (the ones the user can actually see on the document grid).
        Selection& sel = ctx.selection;
        if (!sel.active() || sel.empty()) return false;
        if (!sel.Contains(cell.x, cell.y, cell.z)) return false;
        LiftSelectionToFloating(ctx);
        if (!fb.active) return false;  // failsafe: lift had nothing to do
    } else {
        // Buffer already active (e.g., from a paste). Click has to
        // land on one of the buffer's cells in their currently-rendered
        // world position.
        const int32_t bx = cell.x - fb.offset_x;
        const int32_t by = cell.y - fb.offset_y;
        const int32_t bz = cell.z - fb.offset_z;
        if (fb.grid.Get(bx, by, bz) == 0) return false;
    }

    // Drag plane: the outward face of the clicked cell in *world*
    // coords. The anchor is the camera-ray hit on that plane; we
    // reuse it on every drag frame so the cursor delta translates
    // 1:1 to a voxel offset regardless of where the user moves to
    // along the in-plane axes.
    const float plane_coord = (axis == 0)
        ? (sign > 0 ? static_cast<float>(cell.x + 1) : static_cast<float>(cell.x))
        : (axis == 1)
        ? (sign > 0 ? static_cast<float>(cell.y + 1) : static_cast<float>(cell.y))
        : (sign > 0 ? static_cast<float>(cell.z + 1) : static_cast<float>(cell.z));
    simd::float3 anchor;
    if (!vc.GridPlaneIntersect(e.local.x, e.local.y, axis, plane_coord, &anchor)) {
        return false;
    }

    state.move_select.axis = axis;
    state.move_select.anchor_grid = anchor;
    state.move_select.start_offset =
        shapes::Vec3i{fb.offset_x, fb.offset_y, fb.offset_z};
    state.drag_mode = DragMode::MoveSelect;
    return true;
}

void OnMouseDragged(EditorContext& ctx,
                    const InteractionState::MoveSelect& m,
                    const ViewContext& vc, const MouseEvent& e) {
    FloatingBuffer& fb = ctx.floating_buffer;
    if (!fb.active) return;

    const float plane_coord = (m.axis == 0) ? m.anchor_grid.x
                            : (m.axis == 1) ? m.anchor_grid.y
                                            : m.anchor_grid.z;
    simd::float3 hit;
    if (!vc.GridPlaneIntersect(e.local.x, e.local.y, m.axis, plane_coord, &hit)) {
        // Grazing ray — leave the offset where it was rather than
        // jumping to the bogus huge t the math gave.
        return;
    }

    auto round_to_int = [](float f) -> int32_t {
        return static_cast<int32_t>(std::lround(f));
    };
    int32_t nx = m.start_offset.x;
    int32_t ny = m.start_offset.y;
    int32_t nz = m.start_offset.z;
    if (m.axis != 0) nx += round_to_int(hit.x - m.anchor_grid.x);
    if (m.axis != 1) ny += round_to_int(hit.y - m.anchor_grid.y);
    if (m.axis != 2) nz += round_to_int(hit.z - m.anchor_grid.z);

    if (nx == fb.offset_x && ny == fb.offset_y && nz == fb.offset_z) return;
    fb.offset_x = nx;
    fb.offset_y = ny;
    fb.offset_z = nz;
    // Note: fb.version stays put. The chunk-pool upload is unchanged;
    // only the offset uniform updates next frame, which is the entire
    // point of the floating-buffer model.
}

}  // namespace macvoxel::move_select_controller
