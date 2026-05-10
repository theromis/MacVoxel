#pragma once

#include "InteractionState.h"

namespace macvoxel {
struct EditorContext;
struct MouseEvent;
struct ViewContext;
}

// Brush: bare-click stroke painter. The dispatcher (VoxelView) routes
// here for any tool that doesn't claim mouseDown via its own branch
// — the catch-all default. Cmd flips the stroke to Remove.
//
// Each stroke is one EditHistory op begun on mouseDown and committed
// on mouseUp, so the whole drag is one undo step. Per-event dedupe
// prevents re-stamping the same cell when the cursor sits over it
// across multiple mouse events.
namespace macvoxel::brush_controller {

void OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e);

void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e);

void OnMouseUp(EditorContext& ctx, InteractionState& state);

}  // namespace macvoxel::brush_controller
