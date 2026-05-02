#include "ToolPanel.h"

#include "ToolState.h"

#include "imgui.h"

#include <algorithm>

namespace macvoxel {
namespace {

void AccentButtonColors(bool active) {
    if (!active) return;
    const ImVec4 base = ImGui::GetStyleColorVec4(ImGuiCol_ButtonActive);
    const ImVec4 lighter{std::min(1.0f, base.x * 1.18f),
                         std::min(1.0f, base.y * 1.18f),
                         std::min(1.0f, base.z * 1.18f), base.w};
    const ImVec4 darker{base.x * 0.82f, base.y * 0.82f,
                        base.z * 0.82f, base.w};
    ImGui::PushStyleColor(ImGuiCol_Button, base);
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, lighter);
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, darker);
}

}  // namespace

void DrawToolPanel() {
    ToolState& t = CurrentTool();

    ImGui::SetNextWindowSize(ImVec2(260, 260), ImGuiCond_FirstUseEver);
    ImGui::Begin("Tool");

    auto tool_button = [&](const char* label, ToolKind k) {
        const bool active = t.tool == k;
        AccentButtonColors(active);
        if (ImGui::Button(label, ImVec2(64, 0))) t.tool = k;
        if (active) ImGui::PopStyleColor(3);
    };
    auto mode_button = [&](const char* label, ToolMode m) {
        const bool active = t.mode == m;
        AccentButtonColors(active);
        if (ImGui::Button(label, ImVec2(64, 0))) t.mode = m;
        if (active) ImGui::PopStyleColor(3);
    };

    ImGui::TextDisabled("Tool");
    tool_button("Brush", ToolKind::Brush);
    ImGui::SameLine();
    tool_button("Select", ToolKind::Select);

    ImGui::Spacing();
    ImGui::TextDisabled("Mode");
    mode_button("Add", ToolMode::Add);
    ImGui::SameLine();
    mode_button("Remove", ToolMode::Remove);
    ImGui::SameLine();
    mode_button("Paint", ToolMode::Paint);

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
        ImGui::BulletText("Click voxel face: apply current mode");
        ImGui::BulletText("Cmd + click: remove (override mode)");
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
