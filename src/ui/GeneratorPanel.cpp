#include "GeneratorPanel.h"

#include "GeneratorState.h"
#include "Generators.h"

#include "imgui.h"

#include <algorithm>

namespace macvoxel {
namespace {

const char* KindLabel(generators::Kind k) {
    switch (k) {
        case generators::Kind::Ellipsoid: return "Ellipsoid";
        case generators::Kind::Count_:    return "?";
    }
    return "?";
}

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

void DrawGeneratorPanel() {
    ImGui::SetNextWindowSize(ImVec2(260, 220), ImGuiCond_FirstUseEver);
    ImGui::Begin("Generators");

    GeneratorState& g = CurrentGeneratorState();

    auto kind_button = [&](generators::Kind k) {
        const bool active = g.active_kind == k;
        AccentButtonColors(active);
        if (ImGui::Button(KindLabel(k), ImVec2(110, 0))) {
            g.active_kind = k;
        }
        if (active) ImGui::PopStyleColor(3);
    };

    ImGui::TextDisabled("Kind");
    kind_button(generators::Kind::Ellipsoid);
    // Cylinder, Pyramid, Cone, Maze, Perlin, Fractal slot in here as
    // each new kernel lands.

    ImGui::Spacing();
    ImGui::TextDisabled("Parameters");
    switch (g.active_kind) {
        case generators::Kind::Ellipsoid:
            // Ellipsoid is fully described by its bounding box — no
            // additional parameters at this stage. (Anisotropic axes,
            // hollow shells, partial-sphere wedges are candidates for
            // later passes.)
            ImGui::TextDisabled("(none — shape derives from bounds)");
            break;
        case generators::Kind::Count_:
            break;
    }

    ImGui::Spacing();
    if (ImGui::CollapsingHeader("How to use")) {
        ImGui::BulletText("Pick a kind above.");
        ImGui::BulletText("Switch to the Generators tool in the Tool panel.");
        ImGui::BulletText("Click-drag in the viewport to lay out a box.");
        ImGui::BulletText("Drag the box's face arrows to resize.");
        ImGui::BulletText("Click outside the box to commit.");
    }

    ImGui::End();
}

}  // namespace macvoxel
