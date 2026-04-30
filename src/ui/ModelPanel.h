#pragma once

#include <cstdint>

namespace macvoxel {

struct Document;

struct RenderStats {
    uint32_t vertex_count = 0;
    uint32_t index_count = 0;
    uint32_t quad_count = 0;
};

void DrawModelPanel(const Document& doc, const RenderStats& stats);

// Toggles the ImGui demo window. Wired to View > Show ImGui Demo (Cmd+D).
void ToggleImGuiDemoWindow();

}  // namespace macvoxel
