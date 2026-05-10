#include "BoxSelectController.h"

#include "EditorContext.h"
#include "Input.h"
#include "Selection.h"
#include "SelectionOps.h"
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
    SelectCellsWhere(ctx, [&](int32_t cx, int32_t cy, int32_t cz,
                              uint8_t /*pal*/) {
        return (cx >= b.min_x && cx <= b.max_x &&
                cy >= b.min_y && cy <= b.max_y &&
                cz >= b.min_z && cz <= b.max_z);
    });
}

}  // namespace macvoxel::box_select_controller
