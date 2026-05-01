#pragma once

namespace macvoxel {

struct Document;

// Edits the active palette entry's color and material. The active entry
// is whatever ToolState.palette_idx points at — clicking a swatch in the
// Model panel selects which entry this panel edits. Changes mutate
// `doc.palette` and bump doc.version so the renderer picks up new colors.
void DrawMaterialPanel(Document& doc);

}  // namespace macvoxel
