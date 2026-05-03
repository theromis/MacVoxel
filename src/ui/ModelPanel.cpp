#include "ModelPanel.h"

#include "Document.h"
#include "Fonts.h"

#include "imgui.h"

namespace macvoxel {
namespace {

bool g_show_demo = false;

}  // namespace

void DrawModelPanel(const Document& doc, const RenderStats&) {
    ImGui::SetNextWindowSize(ImVec2(320, 200), ImGuiCond_FirstUseEver);
    ImGui::Begin("Model");

    ImGui::PushFont(Fonts().header);
    ImGui::TextUnformatted("File");
    ImGui::PopFont();
    ImGui::Indent();
    if (doc.path.empty()) {
        ImGui::TextDisabled("(untitled)");
    } else {
        ImGui::TextWrapped("%s", doc.path.c_str());
    }
    ImGui::Unindent();
    ImGui::Spacing();

    ImGui::PushFont(Fonts().header);
    ImGui::TextUnformatted("Grid");
    ImGui::PopFont();
    ImGui::Indent();
    const Bounds3 b = doc.grid.Bounds();
    const size_t filled = doc.grid.FilledCount();
    if (b.empty()) {
        ImGui::TextDisabled("(empty)");
    } else {
        ImGui::Text("extent  %d × %d × %d",
                    b.size_x(), b.size_y(), b.size_z());
        const size_t bbox_cells = static_cast<size_t>(b.size_x()) *
                                  static_cast<size_t>(b.size_y()) *
                                  static_cast<size_t>(b.size_z());
        const float density = bbox_cells > 0
                                  ? 100.0f * static_cast<float>(filled) /
                                        static_cast<float>(bbox_cells)
                                  : 0.0f;
        ImGui::Text("filled  %zu  (%.3f%% of bbox)", filled, density);
    }
    ImGui::Unindent();

    ImGui::End();

    if (g_show_demo) {
        ImGui::ShowDemoWindow(&g_show_demo);
    }
}

void ToggleImGuiDemoWindow() {
    g_show_demo = !g_show_demo;
}

}  // namespace macvoxel
