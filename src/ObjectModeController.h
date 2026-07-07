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

// Axis-arrow gizmo drag (DragMode::ObjectGizmo): translate the
// selection along one world axis, integer-snapped.
void OnGizmoDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e);
void OnGizmoUp(EditorContext& ctx, InteractionState& state);

// Rubber-band select (DragMode::ObjectMarquee, started by a click on
// empty space): objects whose projected AABB intersects the rect get
// selected; shift adds to the set, plain replaces it. A sub-2px rect
// keeps the old click-empty semantics (plain deselects).
void OnMarqueeDragged(InteractionState& state, const MouseEvent& e);
void OnMarqueeUp(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e);

// Rotate the selected object 90° about a world axis (0=X 1=Y 2=Z),
// or mirror it across that axis. Pivot = the object's center
// translation; translation unchanged.
void RotateSelected(EditorContext& ctx, int axis, bool ccw);
void FlipSelected(EditorContext& ctx, int axis);

// Selected-object outline + translate arrows (+ a dimmer outline on
// the active object when it isn't the selected one).
void DrawOverlay(const EditorContext& ctx, const InteractionState& state,
                 const ViewContext& vc, OverlayDraw& od);

}  // namespace object_mode_controller
}  // namespace macvoxel
