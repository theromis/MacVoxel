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
    tool_button(ICON_PENCIL1 "  Line", ToolKind::Line);
    tool_button(ICON_SCOPE "  Circle", ToolKind::Circle);
    ImGui::SameLine();
    tool_button(ICON_SQUARE "  Square", ToolKind::Square);
    tool_button(ICON_ARROW "  Face", ToolKind::Face);
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

    // Brush footprint controls don't apply to the Face tool — its seed
    // region is a flood fill, not a stamped brush.
    const bool show_brush_footprint = t.tool != ToolKind::Face;
    if (show_brush_footprint) {
        int size = t.brush_size;
        if (ImGui::SliderInt("Brush size", &size, 1, 63)) {
            t.brush_size = std::clamp(size, 1, 63);
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
    }

    if (t.tool == ToolKind::Line) {
        auto line_button = [&](const char* label, LineMode m) {
            const bool active = t.line_mode == m;
            AccentButtonColors(active);
            if (ImGui::Button(label, ImVec2(80, 0))) t.line_mode = m;
            if (active) ImGui::PopStyleColor(3);
        };
        line_button("Straight", LineMode::Straight);
        ImGui::SameLine();
        line_button("Project", LineMode::Project);
    }

    auto fill_even_row = [&](bool* fill, bool* even) {
        auto toggle_button = [&](const char* label, bool* state) {
            // Capture the pre-click value so the pop count matches the
            // push count regardless of whether the click flipped the state.
            const bool active = *state;
            AccentButtonColors(active);
            if (ImGui::Button(label, ImVec2(80, 0))) *state = !*state;
            if (active) ImGui::PopStyleColor(3);
        };
        toggle_button("Fill", fill);
        ImGui::SameLine();
        toggle_button("Even", even);
    };

    if (t.tool == ToolKind::Circle) {
        fill_even_row(&t.circle_fill, &t.circle_even);
    } else if (t.tool == ToolKind::Square) {
        fill_even_row(&t.square_fill, &t.square_even);
    } else if (t.tool == ToolKind::Face) {
        // Extrude: which voxels qualify for the flood-filled seed region.
        auto extrude_button = [&](const char* label, FaceExtrudeKind k) {
            const bool active = t.face_extrude == k;
            AccentButtonColors(active);
            if (ImGui::Button(label, ImVec2(80, 0))) t.face_extrude = k;
            if (active) ImGui::PopStyleColor(3);
        };
        ImGui::TextDisabled("Extrude");
        extrude_button("Color##extrude", FaceExtrudeKind::Color);
        ImGui::SameLine();
        extrude_button("Geometry##extrude", FaceExtrudeKind::Geometry);

        // With: source color for newly-extruded voxels.
        auto with_button = [&](const char* label, FaceWithColor w) {
            const bool active = t.face_with == w;
            AccentButtonColors(active);
            if (ImGui::Button(label, ImVec2(80, 0))) t.face_with = w;
            if (active) ImGui::PopStyleColor(3);
        };
        ImGui::TextDisabled("With");
        with_button("Geometry##with", FaceWithColor::Geometry);
        ImGui::SameLine();
        with_button("Palette##with", FaceWithColor::Palette);

        // Connectivity for the flood fill.
        auto connectivity_button = [&](const char* label, bool want_eight) {
            const bool active = t.face_eight_connected == want_eight;
            AccentButtonColors(active);
            if (ImGui::Button(label, ImVec2(80, 0))) {
                t.face_eight_connected = want_eight;
            }
            if (active) ImGui::PopStyleColor(3);
        };
        ImGui::TextDisabled("Connectivity");
        connectivity_button("4-side", false);
        ImGui::SameLine();
        connectivity_button("8-side", true);
    }

    // Footprint summary: edge length is fixed at (2r-1); cell count
    // depends on shape and dimensionality. Computed by sampling the
    // same predicate the editor uses so the label can't drift from
    // the actual brush. Hidden for Face since it doesn't stamp a brush.
    if (show_brush_footprint) {
    const int edge = std::max(1, t.brush_size);
    const int lo = -((edge - 1) / 2);
    const int hi = edge / 2;
    // Brush center: 0 for odd diameters, 0.5 for even diameters
    // (between cells, so the footprint stays geometrically symmetric).
    // Distance threshold = D/2; with odd D this matches the old
    // (span + 0.5) anti-widow expression exactly.
    const float c = (lo + hi) * 0.5f;
    const float r2 = (edge * 0.5f) * (edge * 0.5f);
    int cells = 0;
    for (int dz = lo; dz <= hi; ++dz) {
        if (!t.brush_3d && dz != 0) continue;
        for (int dy = lo; dy <= hi; ++dy) {
            for (int dx = lo; dx <= hi; ++dx) {
                if (t.brush_shape == BrushShape::Circle) {
                    const float fx = dx - c, fy = dy - c, fz = dz - c;
                    const float d2 = fx*fx + fy*fy + (t.brush_3d ? fz*fz : 0.0f);
                    if (d2 > r2) continue;
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
    }  // end if (show_brush_footprint)

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
