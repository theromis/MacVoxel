#include "XformHandleController.h"

// The xform-handle gizmo (six face arrows around the floating buffer
// for scale dragging) was an FB-only feature. With the selection-lift
// refactor, FB is retired and the lift's transform surface area is
// translate + rotate + flip (no scale yet). The gizmo is stubbed to
// no-ops here while the feature is dormant; if a future iteration
// wants scale, port the original logic onto sel.lift_bounds.

namespace macvoxel::xform_handle_controller {

bool OnMouseDown(EditorContext& /*ctx*/, InteractionState& /*state*/,
                 const ViewContext& /*vc*/, const MouseEvent& /*e*/) {
    return false;
}

void OnMouseDragged(EditorContext& /*ctx*/, InteractionState& /*state*/,
                    const ViewContext& /*vc*/, const MouseEvent& /*e*/) {}

void OnMouseUp(InteractionState& /*state*/) {}

void DrawOverlay(const InteractionState& /*state*/, const ViewContext& /*vc*/,
                 OverlayDraw& /*od*/, bool /*mouse_captured_by_ui*/) {}

}  // namespace macvoxel::xform_handle_controller
