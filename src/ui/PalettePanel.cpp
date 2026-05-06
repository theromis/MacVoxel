#include "PalettePanel.h"

#include "Document.h"
#include "Palette.h"
#include "ToolState.h"

#include "imgui.h"

#include <algorithm>
#include <cstdint>

namespace macvoxel {
namespace {

ImU32 ColorToImU32(Color c) { return IM_COL32(c.r, c.g, c.b, c.a); }

constexpr int kPaletteCols = 8;
constexpr int kPaletteRows = 32;

// (col, row) -> palette index. (col=0, row=kPaletteRows-1) — the bottom
// left — is index 1. Indices increase left→right then bottom→up; the
// top-right cell holds the "empty" slot index 0 since 8·32 = 256 cells
// but only 1..255 are visible colors.
uint8_t SlotIndexAt(int col, int row) {
    int n = (kPaletteRows - 1 - row) * kPaletteCols + col + 1;
    return n >= 256 ? uint8_t(0) : static_cast<uint8_t>(n);
}

// Inverse of SlotIndexAt. Used to position the active-slot outline and
// the start anchor on shift-click.
void SlotPosition(uint8_t idx, int& col, int& row) {
    if (idx == 0) {
        col = kPaletteCols - 1;
        row = 0;
        return;
    }
    int n = idx - 1;
    col = n % kPaletteCols;
    row = kPaletteRows - 1 - (n / kPaletteCols);
}

// Persistent UI state for click-drag rectangle selection. Lives across
// frames between mouse-press and mouse-release.
struct DragState {
    bool active = false;
    int start_col = 0;
    int start_row = 0;
    bool shift = false;  // snapshot of shift state at press time
};
DragState& Drag() {
    static DragState s;
    return s;
}

// Clamp a (col, row) computed from raw mouse position to grid bounds so
// drag sweeps that wander outside the panel still produce a valid rect.
int Clamp(int v, int lo, int hi) { return std::max(lo, std::min(hi, v)); }

}  // namespace

void DrawPalettePanel(Document& doc) {
    ToolState& tool = CurrentTool();

    ImGui::SetNextWindowSize(ImVec2(220, 660), ImGuiCond_FirstUseEver);
    ImGui::Begin("Palette");

    // -----------------------------------------------------------------
    // Swatch grid (8 cols × 32 rows). Swatch size scales to fit the
    // panel's horizontal space; the grid scrolls if the window is too
    // short to display all 32 rows at the chosen swatch size.
    // -----------------------------------------------------------------
    {
        const float spacing = 1.0f;
        const float avail = ImGui::GetContentRegionAvail().x;
        const float swatch = std::max(8.0f,
            (avail - (kPaletteCols - 1) * spacing) / kPaletteCols);
        ImDrawList* dl = ImGui::GetWindowDrawList();
        const ImVec2 origin = ImGui::GetCursorScreenPos();
        const float total_w = kPaletteCols * (swatch + spacing) - spacing;
        const float total_h = kPaletteRows * (swatch + spacing) - spacing;
        ImGui::InvisibleButton("palette_grid", ImVec2(total_w, total_h));

        const ImVec2 mouse = ImGui::GetIO().MousePos;
        const int hover_col = Clamp(
            static_cast<int>((mouse.x - origin.x) / (swatch + spacing)),
            0, kPaletteCols - 1);
        const int hover_row = Clamp(
            static_cast<int>((mouse.y - origin.y) / (swatch + spacing)),
            0, kPaletteRows - 1);
        const bool grid_hovered = ImGui::IsItemHovered();

        // Track press / release. Press starts a drag; release commits
        // the rect-selection (a single-cell rect is the single-click case).
        if (ImGui::IsItemActivated()) {
            Drag().active = true;
            Drag().start_col = hover_col;
            Drag().start_row = hover_row;
            Drag().shift = ImGui::GetIO().KeyShift;
        }
        if (ImGui::IsItemDeactivated() && Drag().active) {
            const int min_c = std::min(Drag().start_col, hover_col);
            const int max_c = std::max(Drag().start_col, hover_col);
            const int min_r = std::min(Drag().start_row, hover_row);
            const int max_r = std::max(Drag().start_row, hover_row);
            // Replace selection on a plain click/drag; toggle each cell
            // in the rect on shift-click/drag.
            if (!Drag().shift) tool.selected_slots.reset();
            for (int r = min_r; r <= max_r; ++r) {
                for (int c = min_c; c <= max_c; ++c) {
                    const uint8_t i = SlotIndexAt(c, r);
                    if (Drag().shift) {
                        tool.selected_slots.flip(i);
                    } else {
                        tool.selected_slots.set(i);
                    }
                }
            }
            // Active paint target follows the drag-end slot, and is
            // always a member of the selection so the Material editor
            // and the painting tool agree on which slot is "current".
            tool.palette_idx = SlotIndexAt(hover_col, hover_row);
            tool.selected_slots.set(tool.palette_idx);
            Drag().active = false;
        }

        // Cell rendering pass. Iterates over the visible (col, row)
        // positions rather than the index range so the empty corner
        // ends up where it should regardless of mapping changes.
        for (int row = 0; row < kPaletteRows; ++row) {
            for (int col = 0; col < kPaletteCols; ++col) {
                const ImVec2 a{origin.x + col * (swatch + spacing),
                               origin.y + row * (swatch + spacing)};
                const ImVec2 b{a.x + swatch, a.y + swatch};
                const uint8_t idx = SlotIndexAt(col, row);
                const Color c = doc.palette.Get(idx);
                dl->AddRectFilled(a, b, ColorToImU32(c));
                // The empty slot shows a small diagonal hatch so users
                // can tell it apart from a black color.
                if (idx == 0) {
                    const ImU32 hatch = IM_COL32(80, 80, 80, 255);
                    dl->AddLine(ImVec2(a.x, a.y), ImVec2(b.x, b.y), hatch, 1.0f);
                    dl->AddLine(ImVec2(b.x, a.y), ImVec2(a.x, b.y), hatch, 1.0f);
                }
                if (tool.selected_slots.test(idx)) {
                    dl->AddRect(a, b, IM_COL32(255, 255, 255, 255),
                                0.0f, 0, 1.0f);
                }
                if (grid_hovered && col == hover_col && row == hover_row) {
                    ImGui::SetTooltip("idx %d  RGBA(%u, %u, %u, %u)", idx,
                                      c.r, c.g, c.b, c.a);
                }
            }
        }
        // Active paint-target gets a thicker outline drawn on top so it
        // stands out among possibly many selected swatches.
        {
            int ac = 0, ar = 0;
            SlotPosition(tool.palette_idx, ac, ar);
            const ImVec2 a{origin.x + ac * (swatch + spacing),
                           origin.y + ar * (swatch + spacing)};
            const ImVec2 b{a.x + swatch, a.y + swatch};
            dl->AddRect(a, b, IM_COL32(255, 220, 80, 255), 0.0f, 0, 2.0f);
        }
        // Live drag rectangle overlay while the user is dragging.
        if (Drag().active) {
            const int min_c = std::min(Drag().start_col, hover_col);
            const int max_c = std::max(Drag().start_col, hover_col);
            const int min_r = std::min(Drag().start_row, hover_row);
            const int max_r = std::max(Drag().start_row, hover_row);
            const ImVec2 a{origin.x + min_c * (swatch + spacing) - 1.0f,
                           origin.y + min_r * (swatch + spacing) - 1.0f};
            const ImVec2 b{origin.x + (max_c + 1) * (swatch + spacing),
                           origin.y + (max_r + 1) * (swatch + spacing)};
            dl->AddRect(a, b, IM_COL32(255, 220, 80, 255), 2.0f, 0, 1.5f);
        }
    }

    ImGui::Spacing();
    ImGui::Separator();

    // -----------------------------------------------------------------
    // Active-entry color editor (material lives in the Render panel).
    // -----------------------------------------------------------------
    const uint8_t idx = tool.palette_idx;
    ImGui::Text("Index %u", idx);
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
