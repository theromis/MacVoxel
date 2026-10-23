#pragma once

#include "InteractionState.h"

namespace macvoxel {
class OverlayDraw;
struct EditorContext;
struct MouseEvent;
struct ViewContext;
}

// First per-tool gesture controller, lifted out of VoxelView.mm.
// Pure C++ namespace of free functions in the FloatingBufferOps /
// SelectionOps style — the dispatcher (still on VoxelView) routes
// NSEvents into these by ToolKind / DragMode and otherwise stays
// out of marquee state.
namespace macvoxel::marquee_controller {

// Begin a marquee drag. The dispatcher filters Cmd / Option / Space
// modifiers before reaching here; this just seeds the rect's two
// corners to the click point and sets drag_mode.
void OnMouseDown(InteractionState& state, const MouseEvent& e);

// Update the rectangle's far corner to the cursor position.
void OnMouseDragged(InteractionState::MarqueeDrag& m, const MouseEvent& e);

// Commit: project every occupied voxel's center through view×proj,
// keep the ones whose screen point lands inside the rectangle.
// A click without meaningful drag (<2 px) is treated as a clear-
// selection gesture so the user can deselect without a tool switch.
void OnMouseUp(EditorContext& ctx,
               InteractionState::MarqueeDrag& m,
               const ViewContext& vc,
               const MouseEvent& e);

// Live screen-space rectangle while the user is dragging the marquee.
void DrawOverlay(const InteractionState& state, const ViewContext& vc,
                 OverlayDraw& od);

}  // namespace macvoxel::marquee_controller
