#pragma once

#include <bitset>
#include <cstdint>

namespace macvoxel {

// A tool is *what* the cursor does: brush a cell, drag a marquee, etc.
// Future tools (line, face/extrude, box, primitive) join this enum.
enum class ToolKind {
    Brush,   // touch-to-edit a cell, plus drag-paint along the cursor path
    Select,  // drag to define a 3D AABB selection
};

// A mode is *how* a tool's edits modify cells: add new voxels, remove
// existing ones, or repaint without touching presence. Modes are
// orthogonal to ToolKind so every modeling tool routes through the same
// add/remove/paint logic.
enum class ToolMode {
    Add,
    Remove,
    Paint,
};

struct ToolState {
    ToolKind tool = ToolKind::Brush;
    ToolMode mode = ToolMode::Add;
    uint8_t palette_idx = 1;  // current color (0 is "empty"; never used here)
    // Brush extent: edges of (2r-1) voxels per side, centered on the
    // hit cell (r=1 -> 1 voxel; r=2 -> 3x3x3; r=3 -> 5x5x5).
    int brush_radius = 1;
    // Multi-selection of palette slots, driven by the Palette panel's
    // click-drag / shift-click. The Material editor in the Render panel
    // writes edits to every selected slot. `palette_idx` is always a
    // member of this set when non-empty, and is the single "active"
    // slot whose values the editor displays.
    std::bitset<256> selected_slots{};
};

// Single global tool state — single-document app, single shared tool config.
// If we ever grow into multi-document or multi-view, this becomes a member
// of whichever object owns "current tool".
ToolState& CurrentTool();

}  // namespace macvoxel
