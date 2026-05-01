#pragma once

#include <cstddef>
#include <cstdint>

namespace macvoxel {

struct Document;

struct RenderStats {
    uint32_t chunk_count = 0;
    size_t gpu_bytes = 0;
};

void DrawModelPanel(const Document& doc, const RenderStats& stats);

// Toggles the ImGui demo window. Wired to View > Show ImGui Demo (Cmd+D).
void ToggleImGuiDemoWindow();

}  // namespace macvoxel
