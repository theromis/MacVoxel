#pragma once

namespace macvoxel {

struct EditorContext;

// Walk the active PreviewOverlay and apply its additions / removals
// to the document through one EditHistory op, then clear the overlay.
// Used at the commit edge of overlay-backed tool gestures (Line /
// Circle / Square / Box mouseUp; Face commit; Generator-gizmo
// confirm). No-op when the overlay is empty / inactive, so calling
// through a cancelled gesture is safe.
void CommitPreviewOverlayThroughHistory(EditorContext& ctx);

}  // namespace macvoxel
