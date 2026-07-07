#pragma once

namespace macvoxel {

struct EditorContext;
struct InteractionState;
struct MouseEvent;
struct ViewContext;
class OverlayDraw;

// Scene-mode ("object mode") interaction: click-pick whole objects,
// drag-move with integer snapping, rotate/flip via keys. Transform
// edits touch ONLY the leaf nTRN — voxel data never rewrites.
namespace object_mode_controller {

// Pick + begin a move drag. Returns true when a drag started (an
// object was hit); a miss deselects and returns false.
bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e);

void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e);

// Records the drag's net transform change as one history op.
void OnMouseUp(EditorContext& ctx, InteractionState& state);

// Rotate the selected object 90° about a world axis (0=X 1=Y 2=Z),
// or mirror it across that axis. Pivot = the object's center
// translation; translation unchanged.
void RotateSelected(EditorContext& ctx, int axis, bool ccw);
void FlipSelected(EditorContext& ctx, int axis);

// Selected-object outline (+ a dimmer outline on the active object
// when it isn't the selected one).
void DrawOverlay(const EditorContext& ctx, const ViewContext& vc,
                 OverlayDraw& od);

}  // namespace object_mode_controller
}  // namespace macvoxel
