#pragma once

namespace macvoxel {

struct EditorContext;

// Combined palette selector + active-entry editor.
//
// Top half: 16x16 grid of color swatches. Click to set the active palette
// index (read by every editing tool via ToolSettings).
// Bottom half: color and material attributes for the active entry.
//
// All edits write through to ctx.document.palette and bump version so
// the renderer's palette-signature check uploads the new colors.
void DrawPalettePanel(EditorContext& ctx);

}  // namespace macvoxel
