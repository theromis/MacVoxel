#pragma once

namespace macvoxel {

struct Document;

void DrawModelPanel(const Document& doc);

// Toggles the ImGui demo window. Wired to View > Show ImGui Demo (Cmd+D).
void ToggleImGuiDemoWindow();

}  // namespace macvoxel
