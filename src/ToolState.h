#pragma once

#include <bitset>
#include <cstdint>

namespace macvoxel {

// A tool is *what* the cursor does: brush a cell, drag a marquee, etc.
// Future tools (line, face/extrude, box, primitive) join this enum.
enum class ToolKind {
    Brush,   // touch-to-edit a cell, plus drag-paint along the cursor path
    Line,    // two-click point-to-point voxel line
    Circle,  // two-click center-to-edge planar disc / ring
    Square,  // two-click center-to-edge-midpoint planar square / frame
    Face,    // click a face, drag to extrude / inset along its normal
    Select,  // drag to define a 3D AABB selection
};

// Line tool variants. Straight = 3D-Bresenham segment between the two clicks.
// Project = walk the screen-space segment between click 1 and click 2,
// raycast each step from the camera, and place where the rays hit — so the
// line follows the contour of existing geometry, like clicking the brush
// repeatedly along a straight path on the screen.
enum class LineMode {
    Straight,
    Project,
};

// Face tool: how the click-time flood fill picks the seed region.
//   Color    — only voxels matching the clicked voxel's color (default).
//   Geometry — any non-empty voxel coplanar with the click, regardless
//              of color. Useful for extruding a multi-color surface.
enum class FaceExtrudeKind {
    Color,
    Geometry,
};

// Face tool: where the color of newly-extruded voxels comes from.
//   Geometry — match each source seed voxel's color, per-column. With
//              FaceExtrudeKind::Color this is uniform; with Geometry
//              flood it preserves the surface's coloring outward.
//   Palette  — use the currently-selected palette color for every new
//              voxel, regardless of the source.
// Ignored by Remove (no color is being introduced) and Paint (always
// uses the palette color).
enum class FaceWithColor {
    Geometry,
    Palette,
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
    // Line tool variant; ignored when `tool` isn't ToolKind::Line.
    LineMode line_mode = LineMode::Straight;
    // Circle tool: Fill = filled disc (default) vs. outline-only ring;
    // Even = even diameter (center sits between cells) vs. odd (center
    // on a cell, default).
    bool circle_fill = true;
    bool circle_even = false;
    // Square tool: same Fill / Even semantics as Circle, applied to a
    // Chebyshev-norm "disc" (i.e., a square / hollow frame).
    bool square_fill = true;
    bool square_even = false;
    // Face tool options.
    FaceExtrudeKind face_extrude = FaceExtrudeKind::Color;
    FaceWithColor face_with = FaceWithColor::Geometry;
    // Use 8-connectivity (4 cardinals + 4 diagonals) instead of the
    // 4-connectivity default when flood-filling the seed region.
    bool face_eight_connected = false;
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
