#include "FaceTool.h"

#include "BrushEngine.h"  // Bbox3
#include "Document.h"
#include "EditEngine.h"
#include "EditHistory.h"
#include "EditVolume.h"
#include "EditorContext.h"
#include "Input.h"
#include "InteractionState.h"
#include "ShapeEngine.h"  // CellPalette
#include "Shapes.h"
#include "ToolState.h"
#include "ViewContext.h"
#include "VoxelGrid.h"
#include "VoxelVolume.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace macvoxel {

void FaceTool::Reset() {
    dragging_ = false;
    sign_ = 0;
    seed_color_ = 0;
    observed_drag_ = false;
    applied_d_ = 0;
    from_wall_ = false;
    seed_cells_.clear();
    last_bbox_x0_ = last_bbox_y0_ = last_bbox_z0_ = INT32_MAX;
    last_bbox_x1_ = last_bbox_y1_ = last_bbox_z1_ = INT32_MIN;
    union_bbox_x0_ = union_bbox_y0_ = union_bbox_z0_ = INT32_MAX;
    union_bbox_x1_ = union_bbox_y1_ = union_bbox_z1_ = INT32_MIN;
}

void FaceTool::EnumerateCells(const EditorContext& ctx,
                               const InteractionState& state, int d,
                               std::vector<CellPalette>* out,
                               int32_t* bbox_x0, int32_t* bbox_y0, int32_t* bbox_z0,
                               int32_t* bbox_x1, int32_t* bbox_y1, int32_t* bbox_z1) const {
    out->clear();
    *bbox_x0 = INT32_MAX; *bbox_y0 = INT32_MAX; *bbox_z0 = INT32_MAX;
    *bbox_x1 = INT32_MIN; *bbox_y1 = INT32_MIN; *bbox_z1 = INT32_MIN;
    if (d == 0 || seed_cells_.empty()) return;

    const Document& doc = ctx.document;
    const VoxelVolume& shadow = doc.volume_shadow;
    const ToolSettings& tool = ctx.tool;
    const ToolMode mode = state.anchor.mode;
    int da[3] = {0, 0, 0};
    da[state.anchor.face_axis] = sign_;
    const int n = std::abs(d);

    out->reserve(seed_cells_.size() * static_cast<size_t>(n));
    int32_t bx0 = INT32_MAX, by0 = INT32_MAX, bz0 = INT32_MAX;
    int32_t bx1 = INT32_MIN, by1 = INT32_MIN, bz1 = INT32_MIN;
    auto emit = [&](int32_t x, int32_t y, int32_t z, uint32_t palette) {
        out->push_back(CellPalette{x, y, z, palette});
        bx0 = std::min(bx0, x); by0 = std::min(by0, y); bz0 = std::min(bz0, z);
        bx1 = std::max(bx1, x); by1 = std::max(by1, y); bz1 = std::max(bz1, z);
    };

    if (mode == ToolMode::Add && d > 0) {
        const bool with_geometry =
            !from_wall_ && (tool.face_with == FaceWithColor::Geometry);
        for (int k = 1; k <= d; ++k) {
            for (const auto& v : seed_cells_) {
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
            for (const auto& v : seed_cells_) {
                const int x = v.x - k * da[0];
                const int y = v.y - k * da[1];
                const int z = v.z - k * da[2];
                if (shadow.Get(x, y, z) == 0) continue;
                emit(x, y, z, 0);
            }
        }
    } else if (mode == ToolMode::Remove) {
        for (int k = 0; k < n; ++k) {
            for (const auto& v : seed_cells_) {
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
            for (const auto& v : seed_cells_) {
                const int x = v.x - k * da[0];
                const int y = v.y - k * da[1];
                const int z = v.z - k * da[2];
                const uint8_t cur = shadow.Get(x, y, z);
                if (cur == 0) continue;
                if (cur == pal) continue;
                emit(x, y, z, pal);
            }
        }
    }

    *bbox_x0 = bx0; *bbox_y0 = by0; *bbox_z0 = bz0;
    *bbox_x1 = bx1; *bbox_y1 = by1; *bbox_z1 = bz1;
}

int FaceTool::ComputeFaceVoxels(InteractionState& state, const ViewContext& vc,
                                 const MouseEvent& e) {
    int d = vc.FaceDragVoxels(
        e.local.x, e.local.y, state.anchor.cell,
        state.anchor.face_axis, sign_,
        state.anchor.screen_local.x, state.anchor.screen_local.y);
    if (d != 0) observed_drag_ = true;
    if (d == 0 && !observed_drag_) d = 1;
    if (state.anchor.mode == ToolMode::Remove ||
        state.anchor.mode == ToolMode::Paint) {
        d = std::abs(d);
    }
    return d;
}

void FaceTool::Refresh(EditorContext& ctx, InteractionState& state, int d,
                       EditEngine& engine) {
    std::vector<CellPalette> cells;
    int32_t bx0, by0, bz0, bx1, by1, bz1;
    EnumerateCells(ctx, state, d, &cells, &bx0, &by0, &bz0, &bx1, &by1, &bz1);

    if (last_bbox_x0_ != INT32_MAX) {
        Bbox3 prev{};
        prev.x0 = last_bbox_x0_; prev.y0 = last_bbox_y0_; prev.z0 = last_bbox_z0_;
        prev.x1 = last_bbox_x1_; prev.y1 = last_bbox_y1_; prev.z1 = last_bbox_z1_;
        engine.ClearPreviewBbox(prev);
    }
    if (!cells.empty()) {
        engine.StampCells(cells.data(), cells.size());
    }

    last_bbox_x0_ = bx0; last_bbox_y0_ = by0; last_bbox_z0_ = bz0;
    last_bbox_x1_ = bx1; last_bbox_y1_ = by1; last_bbox_z1_ = bz1;
    if (bx0 != INT32_MAX) {
        union_bbox_x0_ = std::min(union_bbox_x0_, bx0);
        union_bbox_y0_ = std::min(union_bbox_y0_, by0);
        union_bbox_z0_ = std::min(union_bbox_z0_, bz0);
        union_bbox_x1_ = std::max(union_bbox_x1_, bx1);
        union_bbox_y1_ = std::max(union_bbox_y1_, by1);
        union_bbox_z1_ = std::max(union_bbox_z1_, bz1);
    }
    applied_d_ = d;
    applied_with_ = ctx.tool.face_with;
}

bool FaceTool::OnMouseDown(EditorContext& ctx, InteractionState& state,
                            const ViewContext& vc, const MouseEvent& e,
                            EditEngine& engine) {
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

    Reset();
    dragging_ = true;
    sign_ = sign;
    seed_color_ = color;
    applied_with_ = ctx.tool.face_with;
    from_wall_ = (color == 0);

    const ToolSettings& t = ctx.tool;
    if (color == 0) {
        // Wall pick. Flood-fill empty cells on the wall plane,
        // bounded by the EditVolume's in-plane extent. Then shift
        // seed_cells one step outside the volume so the normal
        // k=1..d extrusion math (in EnumerateCells) lands the first
        // voxel on the wall plane itself.
        const EditVolume& vol = ctx.document.volume;
        const int u_axis = (axis == 0) ? 1 : 0;
        const int v_axis = (axis == 2) ? 1 : 2;
        auto axis_lo = [&](int a) {
            return a == 0 ? vol.x0 : a == 1 ? vol.y0 : vol.z0;
        };
        auto axis_hi = [&](int a) {
            return a == 0 ? vol.x1 : a == 1 ? vol.y1 : vol.z1;
        };
        const int u_min = axis_lo(u_axis), u_max = axis_hi(u_axis);
        const int v_min = axis_lo(v_axis), v_max = axis_hi(v_axis);
        shapes::FloodCoplanarEmpty(ctx.document.grid, seed, axis,
                                   u_min, u_max, v_min, v_max,
                                   t.face_eight_connected, seed_cells_);
        int da[3] = {0, 0, 0};
        da[axis] = sign;
        for (auto& s : seed_cells_) {
            s.x -= da[0]; s.y -= da[1]; s.z -= da[2];
        }
    } else {
        const uint8_t flood_color =
            (t.face_extrude == FaceExtrudeKind::Color) ? color : 0;
        shapes::FloodCoplanarFace(ctx.document.grid, seed, axis, sign,
                                  flood_color, t.face_eight_connected,
                                  seed_cells_);
    }
    state.drag_mode = DragMode::Shape;
    ctx.preview_active = true;
    ctx.history.BeginOp();

    ResetDispatchHash();
    const int d = ComputeFaceVoxels(state, vc, e);
    // First frame: prime the hash to whatever we're about to dispatch.
    uint64_t h = (static_cast<uint64_t>(static_cast<uint32_t>(d)) << 32) |
                 static_cast<uint64_t>(static_cast<uint32_t>(ctx.tool.face_with));
    ShouldDispatch(h | 1ULL);
    Refresh(ctx, state, d, engine);
    return true;
}

void FaceTool::OnMouseDragged(EditorContext& ctx, InteractionState& state,
                               const ViewContext& vc, const MouseEvent& e,
                               EditEngine& engine) {
    const int d = ComputeFaceVoxels(state, vc, e);
    uint64_t h = (static_cast<uint64_t>(static_cast<uint32_t>(d)) << 32) |
                 static_cast<uint64_t>(static_cast<uint32_t>(ctx.tool.face_with));
    if (!ShouldDispatch(h | 1ULL)) return;
    Refresh(ctx, state, d, engine);
}

void FaceTool::OnMouseUp(EditorContext& ctx, InteractionState& state,
                          const ViewContext& vc, const MouseEvent& e,
                          EditEngine& engine) {
    if (!state.anchor.has_anchor) {
        Reset();
        return;
    }
    const int d = ComputeFaceVoxels(state, vc, e);
    if (d != applied_d_ || ctx.tool.face_with != applied_with_) {
        Refresh(ctx, state, d, engine);
    }

    Document& doc = ctx.document;
    const EditVolume& vol = doc.volume;

    if (union_bbox_x0_ != INT32_MAX) {
        std::vector<CellPalette> cells;
        int32_t bx0, by0, bz0, bx1, by1, bz1;
        EnumerateCells(ctx, state, d, &cells, &bx0, &by0, &bz0, &bx1, &by1, &bz1);
        if (!cells.empty()) {
            engine.CommitCells(cells.data(), cells.size());

            const int32_t rx0 = std::max(union_bbox_x0_, vol.x0);
            const int32_t ry0 = std::max(union_bbox_y0_, vol.y0);
            const int32_t rz0 = std::max(union_bbox_z0_, vol.z0);
            const int32_t rx1 = std::min(union_bbox_x1_, vol.x1);
            const int32_t ry1 = std::min(union_bbox_y1_, vol.y1);
            const int32_t rz1 = std::min(union_bbox_z1_, vol.z1);
            if (rx0 <= rx1 && ry0 <= ry1 && rz0 <= rz1) {
                Bbox3 bb{};
                bb.x0 = rx0; bb.y0 = ry0; bb.z0 = rz0;
                bb.x1 = rx1; bb.y1 = ry1; bb.z1 = rz1;
                std::vector<uint8_t> post;
                engine.Readback(bb, &post);
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
            if (last_bbox_x0_ != INT32_MAX) {
                Bbox3 prev{};
                prev.x0 = last_bbox_x0_; prev.y0 = last_bbox_y0_; prev.z0 = last_bbox_z0_;
                prev.x1 = last_bbox_x1_; prev.y1 = last_bbox_y1_; prev.z1 = last_bbox_z1_;
                engine.ClearPreviewBbox(prev);
            }
        }
    }

    ctx.history.CommitOp();
    ctx.preview_active = false;
    state.anchor.has_anchor = false;
    Reset();
}

void FaceTool::Cancel(EditorContext& ctx, InteractionState& state,
                      EditEngine& engine) {
    if (!dragging_ && !state.anchor.has_anchor) return;
    if (last_bbox_x0_ != INT32_MAX) {
        Bbox3 prev{};
        prev.x0 = last_bbox_x0_; prev.y0 = last_bbox_y0_; prev.z0 = last_bbox_z0_;
        prev.x1 = last_bbox_x1_; prev.y1 = last_bbox_y1_; prev.z1 = last_bbox_z1_;
        engine.ClearPreviewBbox(prev);
    }
    ctx.history.AbandonOp();
    ctx.preview_active = false;
    state.anchor.has_anchor = false;
    Reset();
}

}  // namespace macvoxel
