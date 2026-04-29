#pragma once

namespace macvoxel {

// Phase 0 demo panel. Pure C++; safe to call from any backend.
void DrawHelloPanel();

// Toggles the ImGui demo window state read by DrawHelloPanel().
// Wired to View > "Show ImGui Demo" (Cmd+D) in the menu bar.
void ToggleImGuiDemoWindow();

}  // namespace macvoxel
