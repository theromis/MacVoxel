#include "ToolPanel.h"

#include "Icons.h"
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
        if (ImGui::Button(label, ImVec2(80, 0))) t.tool = k;
        if (active) ImGui::PopStyleColor(3);
    };
    auto mode_button = [&](const char* label, ToolMode m) {
        const bool active = t.mode == m;
        AccentButtonColors(active);
        if (ImGui::Button(label, ImVec2(80, 0))) t.mode = m;
        if (active) ImGui::PopStyleColor(3);
    };

    ImGui::TextDisabled("Tool");
    tool_button(ICON_PAINT_BRUSH "  Brush", ToolKind::Brush);
    ImGui::SameLine();
    tool_button(ICON_CROP "  Select", ToolKind::Select);

    ImGui::Spacing();
    ImGui::TextDisabled("Mode");
    mode_button(ICON_CUBE "  Add", ToolMode::Add);
    ImGui::SameLine();
    mode_button(ICON_ERASER "  Remove", ToolMode::Remove);
    ImGui::SameLine();
    mode_button(ICON_PAINT "  Paint", ToolMode::Paint);

    ImGui::Spacing();

    int radius = t.brush_radius;
    if (ImGui::SliderInt("Brush radius", &radius, 1, 8)) {
        t.brush_radius = radius;
    }

    auto shape_button = [&](const char* label, BrushShape s) {
        const bool active = t.brush_shape == s;
        AccentButtonColors(active);
        if (ImGui::Button(label, ImVec2(80, 0))) t.brush_shape = s;
        if (active) ImGui::PopStyleColor(3);
    };
    shape_button("Square", BrushShape::Square);
    ImGui::SameLine();
    shape_button("Circle", BrushShape::Circle);

    auto dim_button = [&](const char* label, bool want_3d) {
        const bool active = t.brush_3d == want_3d;
        AccentButtonColors(active);
        if (ImGui::Button(label, ImVec2(80, 0))) t.brush_3d = want_3d;
        if (active) ImGui::PopStyleColor(3);
    };
    dim_button("2D", false);
    ImGui::SameLine();
    dim_button("3D", true);

    // Footprint summary: edge length is fixed at (2r-1); cell count
    // depends on shape and dimensionality. Computed by sampling the
    // same predicate the editor uses so the label can't drift from
    // the actual brush.
    const int span = std::max(0, t.brush_radius - 1);
    const int edge = 2 * t.brush_radius - 1;
    int cells = 0;
    const float r2 = static_cast<float>(span) * static_cast<float>(span);
    for (int dz = -span; dz <= span; ++dz) {
        if (!t.brush_3d && dz != 0) continue;
        for (int dy = -span; dy <= span; ++dy) {
            for (int dx = -span; dx <= span; ++dx) {
                if (t.brush_shape == BrushShape::Circle) {
                    const int d2 = dx*dx + dy*dy + (t.brush_3d ? dz*dz : 0);
                    if (static_cast<float>(d2) > r2) continue;
                }
                ++cells;
            }
        }
    }
    if (t.brush_3d) {
        ImGui::Text("brush  %d × %d × %d  (%d cells)", edge, edge, edge, cells);
    } else {
        ImGui::Text("brush  %d × %d  (%d cells, on face plane)", edge, edge,
                    cells);
    }

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
