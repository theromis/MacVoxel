#pragma once

#include "InteractionState.h"

namespace macvoxel {
struct EditorContext;
struct MouseEvent;
struct ViewContext;
}

// Cmd-drag on a selected voxel translates the whole selection in
// the plane of the clicked face, snapped to integer voxel offsets.
// The selection is lazily lifted into the FloatingBuffer if not
// already there; the per-frame work is just an integer offset bump
// — no document mutation, no chunk dirty queue.
//
// Activated by the dispatcher when Cmd is held during a click in
// any of Marquee / BoxSelect / FloodSelect tools.
//
// There is no OnMouseUp: the buffer stays floating until the user
// issues an explicit commit gesture (deselect, switch tools, render
// toggle, save, ...) — those auto-commit hooks live elsewhere.
namespace macvoxel::move_select_controller {

// Pick the clicked face, lift the selection if needed, capture the
// drag plane + start offset. Returns false (and leaves drag_mode
// alone) if any of: no face under the cursor; no selection to lift;
// click missed the lifted buffer's cells; grazing ray.
bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e);

// Re-intersect the cursor with the captured drag plane and snap the
// floating-buffer offset along the in-plane axes.
void OnMouseDragged(EditorContext& ctx,
                    const InteractionState::MoveSelect& m,
                    const ViewContext& vc, const MouseEvent& e);

}  // namespace macvoxel::move_select_controller
