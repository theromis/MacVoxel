#pragma once

#include <cstdint>

namespace macvoxel {

enum class ToolKind {
    Place,  // create voxels adjacent to the picked face
    Erase,  // remove the picked voxel
    Paint,  // recolor an existing voxel without changing presence
};

struct ToolState {
    ToolKind tool = ToolKind::Place;
    uint8_t palette_idx = 1;  // current color (0 is "empty"; never used here)
    // Brush extent: edges of (2r-1) voxels per side, centered on the
    // hit cell (r=1 -> 1 voxel; r=2 -> 3x3x3; r=3 -> 5x5x5).
    int brush_radius = 1;
};

// Single global tool state — single-document app, single shared tool config.
// If we ever grow into multi-document or multi-view, this becomes a member
// of whichever object owns "current tool".
ToolState& CurrentTool();

}  // namespace macvoxel
