#include "BoxSelectController.h"

#include "EditorContext.h"
#include "Input.h"
#include "Selection.h"
#include "SelectionLift.h"
#include "Shapes.h"
#include "ViewContext.h"
#include "VoxelGrid.h"

#include <algorithm>

namespace macvoxel::box_select_controller {

bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e) {
    shapes::Vec3i pick;
    if (!vc.PickCell(e.local.x, e.local.y, &pick)) return false;
    state.box_select.anchor = pick;
    state.drag_mode = DragMode::BoxSelect;
    Bounds3 b{};
    b.min_x = b.max_x = pick.x;
    b.min_y = b.max_y = pick.y;
    b.min_z = b.max_z = pick.z;
    // Box-mode preview: stores the bbox on the selection so the
    // overlay can draw the wireframe during drag. Not a real lift yet.
    ctx.selection.SetBox(b);
    return true;
}

void OnMouseDragged(EditorContext& ctx,
                    const InteractionState::BoxSelectDrag& bs,
                    const ViewContext& vc, const MouseEvent& e) {
    shapes::Vec3i pick;
    if (!vc.PickCell(e.local.x, e.local.y, &pick)) return;
    Bounds3 b{};
    b.min_x = std::min(bs.anchor.x, pick.x);
    b.min_y = std::min(bs.anchor.y, pick.y);
    b.min_z = std::min(bs.anchor.z, pick.z);
    b.max_x = std::max(bs.anchor.x, pick.x);
    b.max_y = std::max(bs.anchor.y, pick.y);
    b.max_z = std::max(bs.anchor.z, pick.z);
    ctx.selection.SetBox(b);
}

void OnMouseUp(EditorContext& ctx) {
    const Bounds3 b = ctx.selection.bounds();
    // Clear the box-mode preview before lifting (lift sets its own
    // lift_active+bounds; the box-mode preview was a transient
    // visualization during the drag).
    ctx.selection.Clear();
    if (b.empty()) return;
    lift::LiftSelection(ctx, b);
}

}  // namespace macvoxel::box_select_controller
