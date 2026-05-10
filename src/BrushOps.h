#pragma once

#include "ToolState.h"

#include <cstdint>
#include <unordered_set>

namespace macvoxel {

struct EditorContext;

// Per-cell edit arithmetic: given the old cell value, the tool mode,
// and the active palette color, return the new value. Add only fills
// empty cells, Remove always clears, Paint only repaints existing
// voxels. Caller compares against old to decide whether to actually
// write.
inline uint8_t ComputeNewCellValue(uint8_t old_val, ToolMode mode,
                                   uint8_t palette_idx) {
    switch (mode) {
        case ToolMode::Add:
            return (old_val == 0) ? palette_idx : old_val;
        case ToolMode::Remove:
            return 0;
        case ToolMode::Paint:
            return (old_val != 0) ? palette_idx : old_val;
    }
    return old_val;
}

// Stamp the brush footprint at a cell. Footprint shape (Square /
// Circle), size, 2D-vs-3D, and palette index all come from
// EditorContext::tool. face_axis is the face the cursor clicked
// (for 2D brushes, determines the slab plane).
//
// Two write modes, controlled by `preview`:
//
// preview=false (Brush): writes to doc.grid + records into
//   EditHistory + bumps doc.geometry_version. When skip_out is
//   non-null, every successfully written cell is added so subsequent
//   picks in the same drag can ignore them (otherwise the brush
//   marches outward along the face normal as new cells block the
//   raycast).
//
// preview=true (Shape): writes to PreviewOverlay; the doc grid is
//   untouched. Caller is responsible for bumping overlay.version
//   after batching all stamps for one frame. skip_out is ignored.
void StampBrushFootprint(EditorContext& ctx,
                         int target_x, int target_y, int target_z,
                         int face_axis, ToolMode mode, bool preview,
                         std::unordered_set<int64_t>* skip_out);

}  // namespace macvoxel
