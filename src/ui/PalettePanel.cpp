#include "PalettePanel.h"

#include "Document.h"
#include "Palette.h"
#include "ToolState.h"

#include "imgui.h"

namespace macvoxel {
namespace {

ImU32 ColorToImU32(Color c) { return IM_COL32(c.r, c.g, c.b, c.a); }

}  // namespace

void DrawPalettePanel(Document& doc) {
    ToolState& tool = CurrentTool();

    ImGui::SetNextWindowSize(ImVec2(320, 540), ImGuiCond_FirstUseEver);
    ImGui::Begin("Palette");

    // -----------------------------------------------------------------
    // Swatch grid: scales swatch size to fit panel width.
    // -----------------------------------------------------------------
    {
        const float spacing = 1.0f;
        const float avail = ImGui::GetContentRegionAvail().x;
        // 16 swatches per row, 15 inter-swatch gaps. Cap swatch size so it
        // doesn't get absurdly large in a wide panel.
        const float swatch = std::min(28.0f, std::max(8.0f,
                                       (avail - 15.0f * spacing) / 16.0f));
        ImDrawList* dl = ImGui::GetWindowDrawList();
        const ImVec2 origin = ImGui::GetCursorScreenPos();
        const float total = 16.0f * (swatch + spacing) - spacing;
        ImGui::InvisibleButton("palette_grid", ImVec2(total, total));
        const bool grid_hovered = ImGui::IsItemHovered();
        const bool grid_clicked = ImGui::IsItemClicked(ImGuiMouseButton_Left);
        const ImVec2 mouse = ImGui::GetIO().MousePos;
        for (int i = 0; i < 256; ++i) {
            const int col = i % 16;
            const int row = i / 16;
            const ImVec2 a{origin.x + col * (swatch + spacing),
                           origin.y + row * (swatch + spacing)};
            const ImVec2 b{a.x + swatch, a.y + swatch};
            const Color c = doc.palette.Get(static_cast<uint8_t>(i));
            dl->AddRectFilled(a, b, ColorToImU32(c));
            const bool inside = mouse.x >= a.x && mouse.x < b.x &&
                                mouse.y >= a.y && mouse.y < b.y;
            if (grid_hovered && inside) {
                ImGui::SetTooltip("idx %d  RGBA(%u, %u, %u, %u)", i,
                                  c.r, c.g, c.b, c.a);
                if (grid_clicked) tool.palette_idx = static_cast<uint8_t>(i);
            }
            if (i == tool.palette_idx) {
                dl->AddRect(a, b, IM_COL32(255, 255, 255, 255), 0.0f, 0, 2.0f);
            }
        }
    }

    ImGui::Spacing();
    ImGui::Separator();

    // -----------------------------------------------------------------
    // Active-entry editor
    // -----------------------------------------------------------------
    const uint8_t idx = tool.palette_idx;
    ImGui::Text("Index %u", idx);

    // Color
    {
        Color c = doc.palette.Get(idx);
        float rgba[4] = {c.r / 255.0f, c.g / 255.0f, c.b / 255.0f, c.a / 255.0f};
        if (ImGui::ColorEdit4("Color", rgba, ImGuiColorEditFlags_AlphaBar)) {
            Color nc;
            nc.r = static_cast<uint8_t>(rgba[0] * 255.0f + 0.5f);
            nc.g = static_cast<uint8_t>(rgba[1] * 255.0f + 0.5f);
            nc.b = static_cast<uint8_t>(rgba[2] * 255.0f + 0.5f);
            nc.a = static_cast<uint8_t>(rgba[3] * 255.0f + 0.5f);
            if (!(nc == c)) {
                doc.palette.Set(idx, nc);
                ++doc.version;
            }
        }
    }

    ImGui::End();
}

}  // namespace macvoxel
