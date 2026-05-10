#pragma once

#include "InteractionState.h"
#include "ToolState.h"

namespace macvoxel {
struct EditorContext;
struct MouseEvent;
struct ViewContext;
}

// Two-click shape tools: Line, Circle, Square, Box. Click 1 anchors;
// drag through click 2 enumerates the shape into the PreviewOverlay
// each frame; mouseUp commits the overlay through history as one
// undo op. The doc grid is not touched until commit.
//
// All four share TwoClickAnchor (anchor cell + face axis + mode +
// screen pixel + tool kind, frozen at click 1) and the brush-thickened
// stamping path (BrushOps::StampBrushFootprint with preview=true).
namespace macvoxel::shape_controller {

// Pick the anchor cell, capture face axis / mode / screen pixel /
// tool kind into TwoClickAnchor. Returns false if the click missed
// every cell *and* the empty-space ground-plane fallback wasn't
// usable (e.g., camera looking straight up). Exposed because the
// Generator tool also needs anchor seeding before its gizmo activates.
bool BeginAnchor(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e,
                 ToolMode mode);

// Click 1: anchor + activate live preview + first refresh. Cmd
// flips the stroke to Remove. Returns false on anchor miss; the
// caller resets drag_mode in that case.
bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e);

// Re-render the live preview at the cursor's current cell. The
// dispatcher's mouseDragged Shape case calls this only when
// anchor.tool is one of Line / Circle / Square / Box; Face and
// Generator route to their own refresh paths.
void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e);

// Commit the preview overlay through history as one undo step,
// clear the anchor.
void OnMouseUp(EditorContext& ctx, InteractionState& state);

}  // namespace macvoxel::shape_controller
