#pragma once

#include "InteractionState.h"

namespace macvoxel {
struct EditorContext;
struct MouseEvent;
struct ViewContext;
}

// Selection / floating-buffer transform gizmo. Six face-arrow handles
// around the active selection's world AABB (or the floating buffer's,
// if one is alive). Clicking a handle enters scale-drag — if no
// buffer exists yet the click also lifts the on-grid selection into
// one so the resample has somewhere to write. The visual is just the
// arrows; the existing drawSelectionOverlay draws the AABB outline.
namespace macvoxel::xform_handle_controller {

// Hit-test the cursor against the gizmo's face arrows; if one is
// hit, lift the selection if needed, snapshot the floating buffer
// for resampling, and enter DragMode::XformHandle. Returns true iff
// the gesture took ownership of the drag.
bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e);

// Project the cursor delta from drag-start onto the dragged face's
// outward normal in NDC, and resample the floating buffer to match
// the new bounds. Bounds clamp at 1 voxel thick on the dragged axis.
void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e);

// Drop drag-start state. The buffer is at its final scaled state
// already (every drag frame resampled); the unified lift+commit op
// picks up the current fb.grid when commit fires later.
void OnMouseUp(InteractionState& state);

// Six axis-coloured face-arrow handles. Hovered / actively-dragged
// face gets a brighter tint and a thicker stem.
void DrawOverlay(const InteractionState& state, const ViewContext& vc);

}  // namespace macvoxel::xform_handle_controller
