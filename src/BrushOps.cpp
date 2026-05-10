#include "BrushOps.h"

#include "CellKey.h"
#include "Document.h"
#include "EditHistory.h"
#include "EditorContext.h"
#include "PreviewOverlay.h"
#include "VoxelGrid.h"

#include <algorithm>

namespace macvoxel {

void StampBrushFootprint(EditorContext& ctx,
                         int target_x, int target_y, int target_z,
                         int face_axis, ToolMode mode, bool preview,
                         std::unordered_set<int64_t>* skip_out) {
    Document& doc = ctx.document;
    ToolSettings& tool = ctx.tool;
    EditHistory& history = ctx.history;
    PreviewOverlay& overlay = ctx.preview;

    const int size = std::max(1, tool.brush_size);
    const int lo = -((size - 1) / 2);
    const int hi = size / 2;

    const bool track_skip = !preview && (mode == ToolMode::Add) &&
                            skip_out != nullptr;

    auto apply = [&](int x, int y, int z) {
        const uint8_t old_val = doc.grid.Get(x, y, z);
        const uint8_t new_val = ComputeNewCellValue(old_val, mode,
                                                    tool.palette_idx);
        if (preview) {
            overlay.Stamp(x, y, z, new_val, old_val);
            return;
        }
        if (new_val == old_val) return;
        doc.grid.Set(x, y, z, new_val);
        history.Record(x, y, z, old_val, new_val);
        if (track_skip) {
            skip_out->insert(PackCellKey(x, y, z));
        }
    };

    // Footprint shape combines BrushShape × dim:
    //  Square+3D = cube         |  Square+2D = slab on face plane
    //  Circle+3D = sphere       |  Circle+2D = disc on face plane
    // For 2D modes the plane axis is the face the user clicked
    // (face_axis); the brush is one cell thick along that axis.
    // Brush center: 0 for odd diameters, 0.5 for even diameters.
    // The fractional center on even sizes makes the footprint sit
    // between cells so it stays geometrically centered (and avoids
    // the cardinal-tip "widows" we used to hand-fudge with +0.5).
    const float c = (lo + hi) * 0.5f;
    const float r2 = (size * 0.5f) * (size * 0.5f);
    const bool is_3d = tool.brush_3d;
    const bool is_circle = tool.brush_shape == BrushShape::Circle;
    for (int dz = lo; dz <= hi; ++dz) {
        if (!is_3d && face_axis == 2 && dz != 0) continue;
        for (int dy = lo; dy <= hi; ++dy) {
            if (!is_3d && face_axis == 1 && dy != 0) continue;
            for (int dx = lo; dx <= hi; ++dx) {
                if (!is_3d && face_axis == 0 && dx != 0) continue;
                if (is_circle) {
                    float d2 = 0.0f;
                    if (is_3d || face_axis != 0) {
                        const float f = dx - c; d2 += f * f;
                    }
                    if (is_3d || face_axis != 1) {
                        const float f = dy - c; d2 += f * f;
                    }
                    if (is_3d || face_axis != 2) {
                        const float f = dz - c; d2 += f * f;
                    }
                    if (d2 > r2) continue;
                }
                apply(target_x + dx, target_y + dy, target_z + dz);
            }
        }
    }

    // Preview path edits the overlay only — no doc bump (renderer
    // keys off PreviewOverlay::version, and the caller batches that
    // bump after all stamps).
    if (!preview) {
        doc.BumpGeometry();
    }
}

}  // namespace macvoxel
