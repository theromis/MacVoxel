#include "HelloPanel.h"

#include "imgui.h"

namespace macvoxel {
namespace {

bool g_show_demo = false;
int g_counter = 0;
float g_slider = 0.5f;
ImVec4 g_color = ImVec4(0.45f, 0.55f, 0.60f, 1.0f);

}  // namespace

void DrawHelloPanel() {
    ImGui::SetNextWindowSize(ImVec2(420, 240), ImGuiCond_FirstUseEver);
    ImGui::Begin("Hello, MacVoxel");

    ImGui::TextUnformatted("Phase 0 shell — AppKit + Metal + Dear ImGui.");
    ImGui::Separator();

    ImGui::SliderFloat("slider", &g_slider, 0.0f, 1.0f, "%.3f");
    ImGui::ColorEdit4("color", &g_color.x);

    if (ImGui::Button("click me")) {
        g_counter++;
    }
    ImGui::SameLine();
    ImGui::Text("counter = %d", g_counter);

    const ImGuiIO& io = ImGui::GetIO();
    ImGui::Separator();
    ImGui::Text("%.1f FPS  (%.2f ms/frame)", io.Framerate,
                io.Framerate > 0.0f ? 1000.0f / io.Framerate : 0.0f);

    ImGui::Checkbox("Show ImGui demo (⌘D)", &g_show_demo);

    ImGui::End();

    if (g_show_demo) {
        ImGui::ShowDemoWindow(&g_show_demo);
    }
}

void ToggleImGuiDemoWindow() {
    g_show_demo = !g_show_demo;
}

}  // namespace macvoxel
