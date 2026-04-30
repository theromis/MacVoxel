#include "ModelPanel.h"

#include "Document.h"

#include "imgui.h"

namespace macvoxel {
namespace {

bool g_show_demo = false;

ImU32 ColorToImU32(Color c) {
    return IM_COL32(c.r, c.g, c.b, c.a);
}

}  // namespace

void DrawModelPanel(const Document& doc) {
    ImGui::SetNextWindowSize(ImVec2(360, 480), ImGuiCond_FirstUseEver);
    ImGui::Begin("Model");

    ImGui::TextUnformatted("File");
    ImGui::Indent();
    if (doc.path.empty()) {
        ImGui::TextDisabled("(untitled)");
    } else {
        ImGui::TextWrapped("%s", doc.path.c_str());
    }
    ImGui::Unindent();
    ImGui::Spacing();

    ImGui::TextUnformatted("Grid");
    ImGui::Indent();
    const Dims d = doc.grid.dims();
    const size_t volume = d.volume();
    const size_t filled = doc.grid.FilledCount();
    const float pct = volume > 0 ? 100.0f * static_cast<float>(filled) /
                                   static_cast<float>(volume)
                                 : 0.0f;
    ImGui::Text("dims    %u × %u × %u", d.x, d.y, d.z);
    ImGui::Text("cells   %zu", volume);
    ImGui::Text("filled  %zu  (%.2f%%)", filled, pct);
    ImGui::Unindent();
    ImGui::Spacing();

    ImGui::TextUnformatted("Palette");
    ImGui::Indent();
    {
        const float swatch = 16.0f;
        const float spacing = 1.0f;
        ImDrawList* dl = ImGui::GetWindowDrawList();
        const ImVec2 origin = ImGui::GetCursorScreenPos();
        for (int i = 0; i < 256; ++i) {
            const int col = i % 16;
            const int row = i / 16;
            const ImVec2 a{origin.x + col * (swatch + spacing),
                           origin.y + row * (swatch + spacing)};
            const ImVec2 b{a.x + swatch, a.y + swatch};
            const Color c = doc.palette.Get(static_cast<uint8_t>(i));
            // Skip the transparent slot's checkerboard; just render with its
            // current color (alpha is honored by ImGui).
            dl->AddRectFilled(a, b, ColorToImU32(c));
            if (ImGui::IsMouseHoveringRect(a, b)) {
                ImGui::SetTooltip("idx %d  RGBA(%u, %u, %u, %u)", i,
                                  c.r, c.g, c.b, c.a);
            }
        }
        const float total = 16.0f * (swatch + spacing) - spacing;
        ImGui::Dummy(ImVec2(total, total));
    }
    ImGui::Unindent();

    ImGui::Spacing();
    ImGui::Separator();
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
