#pragma once

#include "Material.h"
#include "Palette.h"

#include <array>
#include <cstdint>
#include <optional>

namespace macvoxel {

// Persistent UI-only state for the ImGui panels. Today these values
// live as `static` locals scattered across panel functions (drag
// snapshots, drag-active flags, cross-panel signals like
// "save render was clicked"); collecting them in a single owned
// object means a future SwiftUI port has a real home for them
// instead of relying on function-scope storage that view re-creation
// would lose.
//
// All members are gesture-coalescing or UI-only — nothing here
// affects the document or the renderer's input. Reset of these on
// document load is intentionally a no-op: drag state self-repairs
// the next mouse-up, and clipboards / show flags should survive
// document changes.
struct PanelState {
    // Palette panel — click-drag rectangle multi-select. Lives across
    // frames between mouse-press and mouse-release on the swatch grid.
    struct PaletteSwatchDrag {
        bool active = false;
        int start_col = 0;
        int start_row = 0;
        bool shift = false;  // snapshot of shift state at press time
    } palette_drag;

    // Palette panel — slot the user right-clicked to open the context
    // menu. Captured at popup-open time so menu actions don't depend
    // on whatever the cursor happens to be over while the popup is up.
    uint8_t palette_context_slot = 0;

    // Palette panel — single-color clipboard for the right-click
    // "Copy/Paste color" action. Separate from the voxel-region
    // clipboard in Clipboard.h: this one is RGBA only, used to ferry
    // a color value between palette slots.
    struct ColorClipboard {
        Color color{};
        bool has_value = false;
    } color_clipboard;

    // Palette panel — coalesces a ColorEdit4 drag (the picker fires
    // every cursor frame) into one undo step. `pre` is the pre-drag
    // color; `pre_idx` is the active palette index at drag start, so
    // a mid-drag active-slot change can close out the prior op
    // before opening a new one.
    struct PaletteColorEdit {
        bool drag = false;
        Color pre{};
        uint8_t pre_idx = 0;
    } palette_color_edit;

    // Render panel — coalesces a Material-editor multi-widget gesture
    // (sliders, combo) into one EditHistory op so a slider drag (or
    // a Combo pick) becomes a single Cmd-Z step. `pre` snapshots the
    // pre-drag Material per palette slot; only the entries in the
    // tool's selected_slots get filled. A mid-drag selection change
    // is *not* coalesced — opening a fresh op is the caller's job.
    struct MaterialEdit {
        bool drag = false;
        std::array<std::optional<Material>, 256> pre{};
    } material_edit;

    // Cross-panel click signal — Render panel raises this when the
    // user clicks "Save render…"; VoxelView's frame loop consumes it
    // via ConsumeSaveRenderClick() and runs the save panel. Modeled
    // as a one-shot to avoid wiring an explicit callback through the
    // panel function signatures.
    bool save_render_clicked = false;

    // Model panel — ImGui demo window visibility, toggled directly
    // from the app menu (View > Show ImGui Demo).
    bool show_imgui_demo = false;
};

}  // namespace macvoxel
