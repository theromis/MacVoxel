#pragma once

#include "InteractionState.h"

namespace macvoxel {
struct EditorContext;
struct MouseEvent;
struct ViewContext;
}

// BoxSelect: click → drag out a 3-D AABB by anchoring on the first
// picked cell and growing the selection bounds toward the cursor's
// pick on each drag frame. The live preview is just `selection.SetBox`
// — drawSelectionOverlay handles the rendering, so this controller
// has no DrawOverlay of its own.
namespace macvoxel::box_select_controller {

// Pick the click cell and seed the selection's AABB at it. Returns
// false (and leaves drag_mode unchanged) if the click missed every
// cell — the dispatcher resets drag_mode in that case.
bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e);

// Pick the cursor cell; grow / shrink the selection bounds to
// [min(anchor, pick), max(anchor, pick)]. No-op when the cursor is
// over empty space — the previous bounds remain on screen.
void OnMouseDragged(EditorContext& ctx,
                    const InteractionState::BoxSelectDrag& bs,
                    const ViewContext& vc, const MouseEvent& e);

// Materialize the cell list inside the live AABB into the selection's
// per-voxel storage. Bounds are already up-to-date from the drag
// previews; this just reads them back through SelectCellsWhere.
void OnMouseUp(EditorContext& ctx);

}  // namespace macvoxel::box_select_controller
