#include "FaceController.h"

#include "BrushEngine.h"      // for Bbox3 (just the C++ struct)
#include "Document.h"
#include "EditHistory.h"
#include "EditVolume.h"
#include "EditorContext.h"
#include "Input.h"
#include "PreviewOverlay.h"   // ctx.preview.active flag
#include "ShapeEngine.h"      // CellPalette
#include "Shapes.h"
#include "ToolState.h"
#include "ViewContext.h"
#include "VoxelGrid.h"
#include "VoxelVolume.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdint>
#include <vector>

namespace macvoxel::face_controller {
namespace {

void FloodFaceFromCell(const Document& doc, shapes::Vec3i seed,
                       int axis, int sign, uint8_t color,
                       bool eight_connected,
                       std::vector<shapes::Vec3i>& out) {
    out.clear();
    shapes::FloodCoplanarFace(doc.grid, seed, axis, sign, color,
                              eight_connected, out);
}

// Enumerate the cells the current d should produce, with their target
// palettes. CPU does all the mode/face_with/in-volume logic in one
// place so the kernel is just a splat. The output's palette field
// can be 0 (= "make empty on commit", e.g. for Add- / Remove).
//
// Reads occupancy from `doc.volume_shadow` (a dense array) rather than
// `doc.grid` (a chunk hashmap). For a 100k-cell face that's roughly a
// 10× speedup on the lookups, which is the per-frame bottleneck.
// Skip cells whose target equals their current value — Remove/Paint
// past the geometry's edge would otherwise emit thousands of no-ops.
void EnumerateCells(const EditorContext& ctx, const InteractionState& state,
                    int d, std::vector<CellPalette>& out,
                    int32_t* bbox_x0, int32_t* bbox_y0, int32_t* bbox_z0,
                    int32_t* bbox_x1, int32_t* bbox_y1, int32_t* bbox_z1) {
    out.clear();
    *bbox_x0 = INT32_MAX; *bbox_y0 = INT32_MAX; *bbox_z0 = INT32_MAX;
    *bbox_x1 = INT32_MIN; *bbox_y1 = INT32_MIN; *bbox_z1 = INT32_MIN;
    if (d == 0 || state.face.seed_cells.empty()) return;

    const Document& doc = ctx.document;
    const VoxelVolume& shadow = doc.volume_shadow;
    const ToolSettings& tool = ctx.tool;
    const ToolMode mode = state.anchor.mode;
    int da[3] = {0, 0, 0};
    da[state.anchor.face_axis] = state.face.sign;
    const int n = std::abs(d);

    out.reserve(state.face.seed_cells.size() * static_cast<size_t>(n));
    int32_t bx0 = INT32_MAX, by0 = INT32_MAX, bz0 = INT32_MAX;
    int32_t bx1 = INT32_MIN, by1 = INT32_MIN, bz1 = INT32_MIN;
    auto emit = [&](int32_t x, int32_t y, int32_t z, uint32_t palette) {
        out.push_back(CellPalette{x, y, z, palette});
        bx0 = std::min(bx0, x); by0 = std::min(by0, y); bz0 = std::min(bz0, z);
        bx1 = std::max(bx1, x); by1 = std::max(by1, y); bz1 = std::max(bz1, z);
    };

    if (mode == ToolMode::Add && d > 0) {
        // Wall picks have no geometry to source from — the seed
        // cells are shifted one step outside the volume so the
        // k=1..d math lands the first voxel ON the wall plane.
        // Force palette color when from_wall.
        const bool with_geometry =
            !state.face.from_wall &&
            (tool.face_with == FaceWithColor::Geometry);
        for (int k = 1; k <= d; ++k) {
            for (const auto& v : state.face.seed_cells) {
                const int x = v.x + k * da[0];
                const int y = v.y + k * da[1];
                const int z = v.z + k * da[2];
                if (shadow.Get(x, y, z) != 0) continue;
                if (!doc.volume.Contains(x, y, z)) continue;
                const uint8_t color = with_geometry
                    ? shadow.Get(v.x, v.y, v.z)
                    : tool.palette_idx;
                emit(x, y, z, color);
            }
        }
    } else if (mode == ToolMode::Add && d < 0) {
        for (int k = 0; k < n; ++k) {
            for (const auto& v : state.face.seed_cells) {
                const int x = v.x - k * da[0];
                const int y = v.y - k * da[1];
                const int z = v.z - k * da[2];
                if (shadow.Get(x, y, z) == 0) continue;  // already empty
                emit(x, y, z, 0);
            }
        }
    } else if (mode == ToolMode::Remove) {
        for (int k = 0; k < n; ++k) {
            for (const auto& v : state.face.seed_cells) {
                const int x = v.x - k * da[0];
                const int y = v.y - k * da[1];
                const int z = v.z - k * da[2];
                if (shadow.Get(x, y, z) == 0) continue;
                emit(x, y, z, 0);
            }
        }
    } else if (mode == ToolMode::Paint) {
        const uint8_t pal = tool.palette_idx;
        for (int k = 0; k < n; ++k) {
            for (const auto& v : state.face.seed_cells) {
                const int x = v.x - k * da[0];
                const int y = v.y - k * da[1];
                const int z = v.z - k * da[2];
                const uint8_t cur = shadow.Get(x, y, z);
                if (cur == 0) continue;
                if (cur == pal) continue;  // already that color
                emit(x, y, z, pal);
            }
        }
    }

    *bbox_x0 = bx0; *bbox_y0 = by0; *bbox_z0 = bz0;
    *bbox_x1 = bx1; *bbox_y1 = by1; *bbox_z1 = bz1;
}

int ComputeFaceVoxels(InteractionState& state, const ViewContext& vc,
                      const MouseEvent& e) {
    int d = vc.FaceDragVoxels(
        e.local.x, e.local.y, state.anchor.cell,
        state.anchor.face_axis, state.face.sign,
        state.anchor.screen_local.x, state.anchor.screen_local.y);
    if (d != 0) state.face.observed_drag = true;
    if (d == 0 && !state.face.observed_drag) d = 1;
    if (state.anchor.mode == ToolMode::Remove ||
        state.anchor.mode == ToolMode::Paint) {
        d = std::abs(d);
    }
    return d;
}

// Refresh the preview to layer count `d`. Dispatches the stamp kernel
// after enumerating the cell list, and clears the previous frame's
// bbox first so cells the old layer covered but the new one doesn't
// fall to zero. Updates state.face.applied_d + the bbox bookkeeping.
void Refresh(EditorContext& ctx, InteractionState& state, int d,
             const StampCellsFn& stamp, const ClearBboxFn& clear_bbox) {
    std::vector<CellPalette> cells;
    int32_t bx0, by0, bz0, bx1, by1, bz1;
    EnumerateCells(ctx, state, d, cells, &bx0, &by0, &bz0, &bx1, &by1, &bz1);

    if (state.face.last_bbox_x0 != INT32_MAX) {
        clear_bbox(state.face.last_bbox_x0, state.face.last_bbox_y0,
                   state.face.last_bbox_z0,
                   state.face.last_bbox_x1, state.face.last_bbox_y1,
                   state.face.last_bbox_z1);
    }
    if (!cells.empty()) {
        stamp(cells.data(), cells.size());
    }

    state.face.last_bbox_x0 = bx0; state.face.last_bbox_y0 = by0;
    state.face.last_bbox_z0 = bz0;
    state.face.last_bbox_x1 = bx1; state.face.last_bbox_y1 = by1;
    state.face.last_bbox_z1 = bz1;
    if (bx0 != INT32_MAX) {
        state.face.union_bbox_x0 = std::min(state.face.union_bbox_x0, bx0);
        state.face.union_bbox_y0 = std::min(state.face.union_bbox_y0, by0);
        state.face.union_bbox_z0 = std::min(state.face.union_bbox_z0, bz0);
        state.face.union_bbox_x1 = std::max(state.face.union_bbox_x1, bx1);
        state.face.union_bbox_y1 = std::max(state.face.union_bbox_y1, by1);
        state.face.union_bbox_z1 = std::max(state.face.union_bbox_z1, bz1);
    }
    state.face.applied_d = d;
    state.face.applied_with = ctx.tool.face_with;
}

}  // namespace

bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                 const ViewContext& vc, const MouseEvent& e,
                 const StampCellsFn& stamp,
                 const ClearBboxFn& clear_bbox) {
    shapes::Vec3i seed;
    int axis = 2, sign = 1;
    uint8_t color = 0;
    if (!vc.PickFace(e.local.x, e.local.y, &seed, &axis, &sign, &color)) {
        return false;
    }
    state.anchor.has_anchor = true;
    state.anchor.cell = seed;
    state.anchor.face_axis = axis;
    state.anchor.mode = ctx.tool.mode;
    state.anchor.screen_local = e.local;
    state.anchor.tool = ToolKind::Face;
    state.face.sign = sign;
    state.face.seed_color = color;
    state.face.observed_drag = false;
    state.face.applied_d = 0;
    state.face.applied_with = ctx.tool.face_with;
    state.face.from_wall = (color == 0);
    state.face.last_bbox_x0 = INT32_MAX; state.face.last_bbox_y0 = INT32_MAX;
    state.face.last_bbox_z0 = INT32_MAX;
    state.face.last_bbox_x1 = INT32_MIN; state.face.last_bbox_y1 = INT32_MIN;
    state.face.last_bbox_z1 = INT32_MIN;
    state.face.union_bbox_x0 = INT32_MAX; state.face.union_bbox_y0 = INT32_MAX;
    state.face.union_bbox_z0 = INT32_MAX;
    state.face.union_bbox_x1 = INT32_MIN; state.face.union_bbox_y1 = INT32_MIN;
    state.face.union_bbox_z1 = INT32_MIN;

    const ToolSettings& t = ctx.tool;
    if (color == 0) {
        // Wall pick. Flood-fill empty cells on the wall plane,
        // bounded by the EditVolume's in-plane extent. Then shift
        // seed_cells one step *outside* the volume so the normal
        // k=1..d extrusion math (in EnumerateCells) lands the FIRST
        // voxel on the wall plane itself. Without the shift, the
        // user would be drawing one cell into the volume, leaving
        // the wall plane empty — visually wrong.
        const EditVolume& vol = ctx.document.volume;
        int u_min = 0, u_max = 0, v_min = 0, v_max = 0;
        const int u_axis = (axis == 0) ? 1 : 0;
        const int v_axis = (axis == 2) ? 1 : 2;
        auto axis_lo = [&](int a) {
            return a == 0 ? vol.x0 : a == 1 ? vol.y0 : vol.z0;
        };
        auto axis_hi = [&](int a) {
            return a == 0 ? vol.x1 : a == 1 ? vol.y1 : vol.z1;
        };
        u_min = axis_lo(u_axis); u_max = axis_hi(u_axis);
        v_min = axis_lo(v_axis); v_max = axis_hi(v_axis);
        shapes::FloodCoplanarEmpty(ctx.document.grid, seed, axis,
                                   u_min, u_max, v_min, v_max,
                                   t.face_eight_connected,
                                   state.face.seed_cells);
        int da[3] = {0, 0, 0};
        da[axis] = sign;
        for (auto& s : state.face.seed_cells) {
            s.x -= da[0];
            s.y -= da[1];
            s.z -= da[2];
        }
    } else {
        const uint8_t flood_color =
            (t.face_extrude == FaceExtrudeKind::Color) ? color : 0;
        FloodFaceFromCell(ctx.document, seed, axis, sign, flood_color,
                          t.face_eight_connected, state.face.seed_cells);
    }
    state.drag_mode = DragMode::Shape;

    ctx.preview.active = true;
    ctx.history.BeginOp();

    const int d = ComputeFaceVoxels(state, vc, e);
    Refresh(ctx, state, d, stamp, clear_bbox);
    return true;
}

void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                    const ViewContext& vc, const MouseEvent& e,
                    const StampCellsFn& stamp,
                    const ClearBboxFn& clear_bbox) {
    const int d = ComputeFaceVoxels(state, vc, e);
    if (d == state.face.applied_d &&
        ctx.tool.face_with == state.face.applied_with) {
        return;
    }
    Refresh(ctx, state, d, stamp, clear_bbox);
}

void OnMouseUp(EditorContext& ctx, InteractionState& state,
               const ViewContext& vc, const MouseEvent& e,
               const StampCellsFn& stamp,
               const CommitCellsFn& commit,
               const ClearBboxFn& clear_bbox,
               const ReadBackFn& readback) {
    if (!state.anchor.has_anchor) {
        state.face.seed_cells.clear();
        return;
    }
    // Re-converge to release-point d.
    const int d = ComputeFaceVoxels(state, vc, e);
    if (d != state.face.applied_d ||
        ctx.tool.face_with != state.face.applied_with) {
        Refresh(ctx, state, d, stamp, clear_bbox);
    }

    Document& doc = ctx.document;
    const EditVolume& vol = doc.volume;

    if (state.face.union_bbox_x0 != INT32_MAX) {
        // Enumerate final cells once more for the commit (the tex_t
        // state matches but we need the cell list for commit_cells).
        std::vector<CellPalette> cells;
        int32_t bx0, by0, bz0, bx1, by1, bz1;
        EnumerateCells(ctx, state, d, cells, &bx0, &by0, &bz0, &bx1, &by1, &bz1);
        if (!cells.empty()) {
            commit(cells.data(), cells.size());

            // Readback union bbox + diff vs shadow.
            const int32_t rx0 = std::max(state.face.union_bbox_x0, vol.x0);
            const int32_t ry0 = std::max(state.face.union_bbox_y0, vol.y0);
            const int32_t rz0 = std::max(state.face.union_bbox_z0, vol.z0);
            const int32_t rx1 = std::min(state.face.union_bbox_x1, vol.x1);
            const int32_t ry1 = std::min(state.face.union_bbox_y1, vol.y1);
            const int32_t rz1 = std::min(state.face.union_bbox_z1, vol.z1);
            if (rx0 <= rx1 && ry0 <= ry1 && rz0 <= rz1) {
                std::vector<uint8_t> post;
                readback(rx0, ry0, rz0, rx1, ry1, rz1, &post);
                const size_t bw = static_cast<size_t>(rx1 - rx0 + 1);
                const size_t bh = static_cast<size_t>(ry1 - ry0 + 1);
                const size_t bd = static_cast<size_t>(rz1 - rz0 + 1);
                if (post.size() >= bw * bh * bd) {
                    std::vector<CellChange> diff;
                    diff.reserve(cells.size());
                    for (size_t lz = 0; lz < bd; ++lz) {
                        for (size_t ly = 0; ly < bh; ++ly) {
                            const size_t row_base = lz * bw * bh + ly * bw;
                            for (size_t lx = 0; lx < bw; ++lx) {
                                const int32_t x = rx0 + static_cast<int32_t>(lx);
                                const int32_t y = ry0 + static_cast<int32_t>(ly);
                                const int32_t z = rz0 + static_cast<int32_t>(lz);
                                const uint8_t pre = doc.volume_shadow.Get(x, y, z);
                                const uint8_t cur = post[row_base + lx];
                                if (pre == cur) continue;
                                CellChange c{};
                                c.x = x; c.y = y; c.z = z;
                                c.old_val = pre; c.new_val = cur;
                                diff.push_back(c);
                            }
                        }
                    }
                    if (!diff.empty()) {
                        doc.ApplyChanges(diff.data(), diff.size());
                        ctx.history.RecordBatch(diff.data(), diff.size());
                        (void)doc.volume_shadow.TakeDirtyChunks();
                        doc.BumpGeometry();
                    }
                }
            }
        } else {
            // No cells to commit — just clear the preview bbox.
            if (state.face.last_bbox_x0 != INT32_MAX) {
                clear_bbox(state.face.last_bbox_x0, state.face.last_bbox_y0,
                           state.face.last_bbox_z0,
                           state.face.last_bbox_x1, state.face.last_bbox_y1,
                           state.face.last_bbox_z1);
            }
        }
    }

    ctx.history.CommitOp();
    ctx.preview.active = false;
    state.anchor.has_anchor = false;
    state.face.seed_cells.clear();
}

}  // namespace macvoxel::face_controller
