#pragma once

#include "InteractionState.h"

namespace macvoxel {
struct EditorContext;
struct MouseEvent;
struct ViewContext;
}

// Face tool: click selects a coplanar same-color flood region whose
// face on the clicked side is exposed; drag extrudes (positive,
// outward) or insets (negative, inward) by an integer number of voxel
// layers along the face normal.
//
// Mode dispatch (mode is frozen at click in TwoClickAnchor::mode):
//   Add    — signed d. Positive extrudes; negative insets (erases).
//            Extrude color comes from `face_with` (read live so the
//            user can flip Geometry/Palette mid-drag and see it).
//   Remove — |d| layers, always inset (drag direction ignored).
//   Paint  — |d| inward layers, repaint existing voxels with the
//            palette color. Empty cells skipped (Paint never fills).
//
// Uses an incremental preview: transitionFaceTo only flips the layers
// that differ between the previous d and the new d, so dragging
// through layer boundaries costs O(seed_cells × Δd) per frame
// rather than O(seed_cells × |d|).
namespace macvoxel::face_controller {

// Pick the clicked face, run a flood fill on the seed plane, set up
// FaceTool state, activate the live preview overlay, do the first
// refresh (the bare-click 1-layer placement). Returns false if no
// face was under the cursor.
bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e);

// Refresh the incremental preview at the cursor's current cell.
void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e);

// Re-converge to the release cursor (the last mouseDragged event isn't
// guaranteed to land at the same point as mouseUp), commit the overlay
// through history as one undo step, clear face state.
void OnMouseUp(EditorContext& ctx, InteractionState& state,
               const ViewContext& vc, const MouseEvent& e);

}  // namespace macvoxel::face_controller
