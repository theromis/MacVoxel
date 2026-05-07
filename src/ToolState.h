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

// Shape of the brush footprint. Square = axis-aligned cube/slab;
// Circle = sphere/disc. Combines with `brush_3d` to produce four
// footprints: cube, sphere, square slab, disc.
enum class BrushShape {
    Square,
    Circle,
};

struct ToolState {
    ToolKind tool = ToolKind::Brush;
    ToolMode mode = ToolMode::Add;
    uint8_t palette_idx = 1;  // current color (0 is "empty"; never used here)
    // Brush diameter in voxels. Odd sizes are symmetric around the
    // target cell; even sizes extend one extra cell in the + direction
    // (the brush "center" sits on a cell boundary). Footprint range is
    // [-((size-1)/2), size/2] on each axis.
    int brush_size = 1;
    BrushShape brush_shape = BrushShape::Square;
    // 3D = volumetric (cube or sphere); 2D = one-cell-thick slab on
    // the plane of the clicked face (square or disc).
    bool brush_3d = true;
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
