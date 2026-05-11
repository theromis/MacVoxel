#pragma once

#include <cstdint>

namespace macvoxel {
class OverlayDraw;
struct EditorContext;
struct InteractionState;
struct ViewContext;
}

// Selection / floating-buffer outline + per-cell silhouette wireframe,
// and the mode-tinted single-cell hover indicator. Lifted out of
// VoxelView's @implementation as pure-C++ free functions taking an
// OverlayDraw — same shape as the per-tool DrawOverlay functions.
namespace macvoxel::selection_overlay {

// AABB outline + per-cell silhouette wireframe for the active
// document selection or floating buffer (whichever is alive). No-op
// when both are empty.
void DrawSelection(const ViewContext& vc, OverlayDraw& od);

// Single-cell wireframe indicator at the cursor's would-affect cell,
// tinted by ToolMode. Skipped during drag, when an overlaying panel
// has the mouse, when the generator gizmo is live, and for tools
// that don't preview a target cell pre-click.
void DrawHover(const InteractionState& state,
               const ViewContext& vc,
               bool mouse_captured_by_ui,
               OverlayDraw& od);

// Project a unit cube at grid cell (cx, cy, cz) and emit its 12
// edges. Shared by the selection and hover overlays so they look
// like the same kind of object.
void DrawCellWire(int cx, int cy, int cz,
                  uint32_t color, float thickness,
                  const ViewContext& vc, OverlayDraw& od);

}  // namespace macvoxel::selection_overlay
