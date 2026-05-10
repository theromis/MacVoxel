#include "SelectionPanel.h"

#include "Fonts.h"
#include "../FloatingBuffer.h"
#include "../Selection.h"
#include "../SelectionOps.h"

#include "imgui.h"

namespace macvoxel {

namespace {

constexpr ImVec2 kAxisButtonSize{60.0f, 0.0f};

void SectionHeader(const char* title) {
    ImGui::PushFont(Fonts().header);
    ImGui::TextUnformatted(title);
    ImGui::PopFont();
}

}  // namespace

void DrawSelectionPanel(Document& doc) {
    ImGui::SetNextWindowSize(ImVec2(260, 180), ImGuiCond_FirstUseEver);
    ImGui::Begin("Selection");

    // Either an on-grid selection or a floating buffer counts — the
    // op routes to whichever is active.
    const bool has_target =
        (CurrentSelection().active() && !CurrentSelection().empty()) ||
        (CurrentFloatingBuffer().active && !CurrentFloatingBuffer().grid.empty());
    ImGui::BeginDisabled(!has_target);

    SectionHeader("Rotate 90°");
    ImGui::Indent();
    // Two rows of three: the top row is "counter-clockwise viewed from
    // +axis" (the right-hand-rule positive direction), the bottom row
    // is the opposite. The labels are short axis letters because the
    // button group is the meaning — column = axis, row = direction.
    if (ImGui::Button("X##rotXccw", kAxisButtonSize))
        RotateSelection(doc, Axis::X, /*cw=*/false);
    ImGui::SameLine();
    if (ImGui::Button("Y##rotYccw", kAxisButtonSize))
        RotateSelection(doc, Axis::Y, /*cw=*/false);
    ImGui::SameLine();
    if (ImGui::Button("Z##rotZccw", kAxisButtonSize))
        RotateSelection(doc, Axis::Z, /*cw=*/false);
    ImGui::TextDisabled("CCW (right-hand rule)");

    if (ImGui::Button("X##rotXcw", kAxisButtonSize))
        RotateSelection(doc, Axis::X, /*cw=*/true);
    ImGui::SameLine();
    if (ImGui::Button("Y##rotYcw", kAxisButtonSize))
        RotateSelection(doc, Axis::Y, /*cw=*/true);
    ImGui::SameLine();
    if (ImGui::Button("Z##rotZcw", kAxisButtonSize))
        RotateSelection(doc, Axis::Z, /*cw=*/true);
    ImGui::TextDisabled("CW");
    ImGui::Unindent();

    ImGui::Spacing();
    SectionHeader("Flip");
    ImGui::Indent();
    if (ImGui::Button("X##flipX", kAxisButtonSize))
        FlipSelection(doc, Axis::X);
    ImGui::SameLine();
    if (ImGui::Button("Y##flipY", kAxisButtonSize))
        FlipSelection(doc, Axis::Y);
    ImGui::SameLine();
    if (ImGui::Button("Z##flipZ", kAxisButtonSize))
        FlipSelection(doc, Axis::Z);
    ImGui::TextDisabled("Mirror across axis-perpendicular plane");
    ImGui::Unindent();

    ImGui::EndDisabled();

    ImGui::End();
}

}  // namespace macvoxel
