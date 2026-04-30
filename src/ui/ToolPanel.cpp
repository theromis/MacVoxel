#include "ToolPanel.h"

#include "ToolState.h"

#include "imgui.h"

namespace macvoxel {

void DrawToolPanel() {
    ToolState& t = CurrentTool();

    ImGui::SetNextWindowSize(ImVec2(220, 180), ImGuiCond_FirstUseEver);
    ImGui::Begin("Tool");

    // Tool selector — three buttons that highlight the active mode.
    auto tool_button = [&](const char* label, ToolKind k) {
        const bool active = t.tool == k;
        if (active) {
            ImGui::PushStyleColor(ImGuiCol_Button,
                                  ImGui::GetStyleColorVec4(ImGuiCol_ButtonActive));
        }
        if (ImGui::Button(label, ImVec2(60, 0))) {
            t.tool = k;
        }
        if (active) ImGui::PopStyleColor();
    };

    tool_button("Place", ToolKind::Place);
    ImGui::SameLine();
    tool_button("Erase", ToolKind::Erase);
    ImGui::SameLine();
    tool_button("Paint", ToolKind::Paint);

    ImGui::Spacing();

    int radius = t.brush_radius;
    if (ImGui::SliderInt("Brush radius", &radius, 1, 8)) {
        t.brush_radius = radius;
    }
    const int edge = 2 * t.brush_radius - 1;
    ImGui::Text("brush: %d × %d × %d  (%d cells)", edge, edge, edge,
                edge * edge * edge);

    ImGui::Spacing();
    ImGui::Text("color: %u", t.palette_idx);
    ImGui::TextDisabled("Click a palette swatch in the Model panel to pick.");

    ImGui::Spacing();
    ImGui::Separator();
    ImGui::TextDisabled("Click empty space  -> %s",
                        t.tool == ToolKind::Place ? "place" :
                        t.tool == ToolKind::Erase ? "erase (no-op)" : "paint (no-op)");
    ImGui::TextDisabled("Cmd+click voxel    -> erase (override)");

    ImGui::End();
}

}  // namespace macvoxel
