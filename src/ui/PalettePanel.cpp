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

// The slot the user right-clicked to open the context menu. Captured at
// popup-open time so menu actions don't depend on whatever the cursor
// happens to be over while the popup is up.
uint8_t& ContextSlot() {
    static uint8_t s = 0;
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
    // Swatch grid (8 cols × 32 rows). Cells scale to fit both the
    // horizontal and vertical space available in the panel — whichever
    // dimension is the limiter — clamped to a sane min/max so they
    // stay clickable but don't get gigantic on a maximized window. A
    // small fixed reservation at the bottom keeps the index label and
    // color editor visible without overlapping the grid.
    // -----------------------------------------------------------------
    {
        const float spacing = 1.0f;
        const float kMinSwatch = 8.0f;
        const float kMaxSwatch = 28.0f;
        // Reserve room for the editor that follows the grid (separator,
        // "Index N" line, and the ColorEdit4 row).
        const float reserved =
            ImGui::GetStyle().ItemSpacing.y * 2.0f +
            ImGui::GetTextLineHeight() +
            ImGui::GetFrameHeightWithSpacing() * 2.0f;
        const ImVec2 avail = ImGui::GetContentRegionAvail();
        // Cells size independently along each axis so the grid fills
        // both directions of the panel — they go rectangular when the
        // panel's aspect ratio doesn't match the grid's. Each axis is
        // clamped to [kMinSwatch, kMaxSwatch] so cells stay clickable
        // on small panels and don't get gigantic on maximized ones.
        const float sw_x = std::clamp(
            (avail.x - (kPaletteCols - 1) * spacing) / kPaletteCols,
            kMinSwatch, kMaxSwatch);
        const float sw_y = std::clamp(
            (std::max(64.0f, avail.y - reserved) -
             (kPaletteRows - 1) * spacing) / kPaletteRows,
            kMinSwatch, kMaxSwatch);
        ImDrawList* dl = ImGui::GetWindowDrawList();
        const ImVec2 origin = ImGui::GetCursorScreenPos();
        const float step_x = sw_x + spacing;
        const float step_y = sw_y + spacing;
        const float total_w = kPaletteCols * step_x - spacing;
        const float total_h = kPaletteRows * step_y - spacing;
        ImGui::InvisibleButton("palette_grid", ImVec2(total_w, total_h));

        const ImVec2 mouse = ImGui::GetIO().MousePos;
        const int hover_col = Clamp(
            static_cast<int>((mouse.x - origin.x) / step_x),
            0, kPaletteCols - 1);
        const int hover_row = Clamp(
            static_cast<int>((mouse.y - origin.y) / step_y),
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
        // Right-click opens a context menu scoped to the slot under the
        // cursor. If that slot isn't already in the selection, replace
        // the selection with it so menu actions read like "operate on
        // what I just clicked".
        if (grid_hovered && ImGui::IsMouseClicked(ImGuiMouseButton_Right)) {
            const uint8_t ctx = SlotIndexAt(hover_col, hover_row);
            ContextSlot() = ctx;
            if (!tool.selected_slots.test(ctx)) {
                tool.selected_slots.reset();
                tool.selected_slots.set(ctx);
                tool.palette_idx = ctx;
            }
            ImGui::OpenPopup("palette_ctx");
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
                const ImVec2 a{origin.x + col * step_x,
                               origin.y + row * step_y};
                const ImVec2 b{a.x + sw_x, a.y + sw_y};
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
            const ImVec2 a{origin.x + ac * step_x, origin.y + ar * step_y};
            const ImVec2 b{a.x + sw_x, a.y + sw_y};
            dl->AddRect(a, b, IM_COL32(255, 220, 80, 255), 0.0f, 0, 2.0f);
        }
        // Live drag rectangle overlay while the user is dragging.
        if (Drag().active) {
            const int min_c = std::min(Drag().start_col, hover_col);
            const int max_c = std::max(Drag().start_col, hover_col);
            const int min_r = std::min(Drag().start_row, hover_row);
            const int max_r = std::max(Drag().start_row, hover_row);
            const ImVec2 a{origin.x + min_c * step_x - 1.0f,
                           origin.y + min_r * step_y - 1.0f};
            const ImVec2 b{origin.x + (max_c + 1) * step_x,
                           origin.y + (max_r + 1) * step_y};
            dl->AddRect(a, b, IM_COL32(255, 220, 80, 255), 2.0f, 0, 1.5f);
        }

        if (ImGui::BeginPopup("palette_ctx")) {
            const uint8_t ctx = ContextSlot();
            const size_t n_sel = tool.selected_slots.count();
            ImGui::TextDisabled("idx %u  (%zu selected)", ctx, n_sel);
            ImGui::Separator();
            ImGui::MenuItem("Copy color", nullptr, false, false);
            ImGui::MenuItem("Paste color", nullptr, false, false);
            ImGui::Separator();
            ImGui::MenuItem("Select voxels by color", nullptr, false, false);
            ImGui::MenuItem("Paint voxels with selected color", nullptr, false, false);
            ImGui::MenuItem("Paint voxels with random selected colors",
                            nullptr, false, false);
            ImGui::Separator();
            ImGui::MenuItem("Make gradient", nullptr, false, false);
            ImGui::EndPopup();
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
