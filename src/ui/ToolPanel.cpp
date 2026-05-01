#include "ToolPanel.h"

#include "ToolState.h"

#include "imgui.h"

namespace macvoxel {

void DrawToolPanel() {
    ToolState& t = CurrentTool();

    ImGui::SetNextWindowSize(ImVec2(260, 220), ImGuiCond_FirstUseEver);
    ImGui::Begin("Tool");

    auto tool_button = [&](const char* label, ToolKind k) {
        const bool active = t.tool == k;
        if (active) {
            ImGui::PushStyleColor(ImGuiCol_Button,
                                  ImGui::GetStyleColorVec4(ImGuiCol_ButtonActive));
        }
        if (ImGui::Button(label, ImVec2(56, 0))) {
            t.tool = k;
        }
        if (active) ImGui::PopStyleColor();
    };

    tool_button("Place", ToolKind::Place);
    ImGui::SameLine();
    tool_button("Erase", ToolKind::Erase);
    ImGui::SameLine();
    tool_button("Paint", ToolKind::Paint);
    ImGui::SameLine();
    tool_button("Select", ToolKind::Select);

    ImGui::Spacing();

    int radius = t.brush_radius;
    if (ImGui::SliderInt("Brush radius", &radius, 1, 8)) {
        t.brush_radius = radius;
    }
    const int edge = 2 * t.brush_radius - 1;
    ImGui::Text("brush  %d × %d × %d  (%d cells)", edge, edge, edge,
                edge * edge * edge);

    ImGui::Spacing();
    if (ImGui::CollapsingHeader("Controls")) {
        ImGui::BulletText("Click voxel face: place / erase / paint");
        ImGui::BulletText("Cmd + click: erase (override tool)");
        ImGui::BulletText("Drag: continuous brush along path");
        ImGui::BulletText("Option + drag: orbit camera");
        ImGui::BulletText("Option + Shift + drag: pan");
        ImGui::BulletText("Scroll / pinch: zoom");
        ImGui::BulletText("Cmd+Z / Cmd+Shift+Z: undo / redo");
        ImGui::BulletText("Cmd+C / Cmd+V / Backspace: copy / paste / delete sel");
        ImGui::BulletText("Cmd+Shift+D: deselect");
    }

    ImGui::End();
}

}  // namespace macvoxel
