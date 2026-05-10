#pragma once

namespace macvoxel {
struct EditorContext;
struct MouseEvent;
struct ViewContext;
}

// FloodSelect fires entirely on mouseDown — there's no drag semantic.
// A click on an occupied voxel becomes the BFS seed; an empty-space
// click clears the selection (lets the user undo a previous flood
// without switching tools).
namespace macvoxel::flood_select_controller {

void OnMouseDown(EditorContext& ctx, const ViewContext& vc,
                 const MouseEvent& e);

}  // namespace macvoxel::flood_select_controller
