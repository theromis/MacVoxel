#include "FloodSelectController.h"

#include "EditorContext.h"
#include "Input.h"
#include "Selection.h"
#include "SelectionOps.h"
#include "Shapes.h"
#include "ViewContext.h"

namespace macvoxel::flood_select_controller {

void OnMouseDown(EditorContext& ctx, const ViewContext& vc,
                 const MouseEvent& e) {
    shapes::Vec3i pick;
    if (vc.PickCell(e.local.x, e.local.y, &pick)) {
        FloodSelectFromSeed(ctx, pick.x, pick.y, pick.z);
    } else {
        ctx.selection.Clear();
    }
}

}  // namespace macvoxel::flood_select_controller
