#include "BrushTool.h"

#include "BrushEngine.h"
#include "Document.h"
#include "EditEngine.h"
#include "EditHistory.h"
#include "EditorContext.h"
#include "Input.h"
#include "InteractionState.h"
#include "Perf.h"
#include "Shapes.h"
#include "ToolState.h"
#include "ViewContext.h"
#include "VoxelGrid.h"
#include "VoxelVolume.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

namespace macvoxel {
namespace {

constexpr shapes::Vec3i kInvalidCell{INT32_MIN, INT32_MIN, INT32_MIN};

inline bool SameCell(const shapes::Vec3i& a, const shapes::Vec3i& b) {
    return a.x == b.x && a.y == b.y && a.z == b.z;
}

BrushParams BuildParams(const EditorContext& ctx,
                        int target_x, int target_y, int target_z,
                        int face_axis, ToolMode mode) {
    const ToolSettings& tool = ctx.tool;
    const EditVolume& vol = ctx.document.volume;
    const int size = std::max(1, tool.brush_size);
    const int lo = -((size - 1) / 2);
    const int hi = size / 2;

    BrushParams p{};
    p.cx = target_x; p.cy = target_y; p.cz = target_z;
    p.face_axis = face_axis;
    p.lo_x = p.lo_y = p.lo_z = lo;
    p.size_x = p.size_y = p.size_z = hi - lo + 1;
    p.flags = 0;
    if (tool.brush_3d) p.flags |= 1u;
    if (tool.brush_shape == BrushShape::Circle) p.flags |= 2u;
    p.mode = static_cast<uint32_t>(mode);
    p.palette_idx = tool.palette_idx;
    p.vol_x0 = vol.x0; p.vol_y0 = vol.y0; p.vol_z0 = vol.z0;
    p.vol_x1 = vol.x1; p.vol_y1 = vol.y1; p.vol_z1 = vol.z1;
    p.center_offset_x10 = static_cast<float>((lo + hi) * 5);
    const float r = size * 0.5f;
    p.r2 = r * r;
    return p;
}

}  // namespace

void BrushTool::ResetStrokeState() {
    paint_mode_ = ToolMode::Add;
    last_drag_edit_cell_ = kInvalidCell;
    // drag_skip_ is reset at OnMouseDown when we have the doc's
    // EditVolume; here just leave the existing buffer alone — it's
    // already zero after the prior stroke's CommitOp.
    stroke_bbox_x0_ = stroke_bbox_y0_ = stroke_bbox_z0_ = INT32_MAX;
    stroke_bbox_x1_ = stroke_bbox_y1_ = stroke_bbox_z1_ = INT32_MIN;
    perf_stamp_count_ = 0;
    perf_footprint_us_ = 0.0;
    perf_readback_us_ = 0.0;
    perf_diff_us_ = 0.0;
    perf_apply_us_ = 0.0;
    perf_history_us_ = 0.0;
    perf_cells_committed_ = 0;
}

// Replicate the kernel's footprint walk on the CPU to build the
// drag_skip_cells set + extend the stroke bbox. Doesn't touch
// doc.grid or doc.volume_shadow — those stay frozen at pre-stroke
// state during the stroke.
//
// `doc.volume_shadow.Get` here is the *pre-stroke* state oracle:
// the dense O(1) array, byte-equal to grid inside the EditVolume
// (Document::SetCell invariant). Cells that transition from 0→non-0
// (Add) or non-0→0 (Remove) go into the skip set so the next pick's
// raycast ignores them. Paint doesn't change occupancy, so it skips
// nothing.
void BrushTool::StampAtCursor(EditorContext& ctx, const ViewContext& vc,
                              const MouseEvent& e, ToolMode mode,
                              EditEngine& engine) {
    shapes::Vec3i target;
    int face_axis = 2;
    if (!vc.ComputeTargetCell(e.local.x, e.local.y, mode, &target,
                              &face_axis, &drag_skip_)) {
        return;
    }
    if (SameCell(target, last_drag_edit_cell_)) return;
    last_drag_edit_cell_ = target;

    const BrushParams p = BuildParams(ctx, target.x, target.y, target.z,
                                      face_axis, mode);

    const EditVolume& vol = ctx.document.volume;
    const int lo = p.lo_x;
    const int hi = lo + p.size_x - 1;
    const float c = p.center_offset_x10 * 0.1f;
    const float r2 = p.r2;
    const bool is_3d = (p.flags & 1u) != 0;
    const bool is_circle = (p.flags & 2u) != 0;
    const Document& doc = ctx.document;

    auto extend_bbox = [&](int x, int y, int z) {
        stroke_bbox_x0_ = std::min(stroke_bbox_x0_, x);
        stroke_bbox_y0_ = std::min(stroke_bbox_y0_, y);
        stroke_bbox_z0_ = std::min(stroke_bbox_z0_, z);
        stroke_bbox_x1_ = std::max(stroke_bbox_x1_, x);
        stroke_bbox_y1_ = std::max(stroke_bbox_y1_, y);
        stroke_bbox_z1_ = std::max(stroke_bbox_z1_, z);
    };

    const auto t_footprint = perf::Now();
    for (int dz = lo; dz <= hi; ++dz) {
        if (!is_3d && p.face_axis == 2 && dz != 0) continue;
        for (int dy = lo; dy <= hi; ++dy) {
            if (!is_3d && p.face_axis == 1 && dy != 0) continue;
            for (int dx = lo; dx <= hi; ++dx) {
                if (!is_3d && p.face_axis == 0 && dx != 0) continue;
                if (is_circle) {
                    float d2 = 0.0f;
                    const float fdx = dx - c;
                    const float fdy = dy - c;
                    const float fdz = dz - c;
                    if (is_3d || p.face_axis != 0) d2 += fdx * fdx;
                    if (is_3d || p.face_axis != 1) d2 += fdy * fdy;
                    if (is_3d || p.face_axis != 2) d2 += fdz * fdz;
                    if (d2 > r2) continue;
                }
                const int x = p.cx + dx;
                const int y = p.cy + dy;
                const int z = p.cz + dz;
                if (!vol.Contains(x, y, z)) continue;
                const uint8_t pre = doc.volume_shadow.Get(x, y, z);
                bool changes_occupancy = false;
                if (mode == ToolMode::Add) {
                    changes_occupancy = (pre == 0);
                } else if (mode == ToolMode::Remove) {
                    changes_occupancy = (pre != 0);
                }
                // Track the bbox of every kernel-touched cell (Paint
                // included) so the readback covers all post-stroke
                // changes. Paint changes color but not occupancy, so it
                // extends the bbox but doesn't add to skip.
                extend_bbox(x, y, z);
                if (changes_occupancy) {
                    drag_skip_.Set(x, y, z);
                }
            }
        }
    }
    perf_footprint_us_ += perf::Micros(perf::Now() - t_footprint);
    ++perf_stamp_count_;

    engine.BrushStamp(p);
}

// End-of-stroke sync. Bounds the readback to the stroke's union bbox
// (clipped to the edit volume — out-of-volume writes are dropped by the
// kernel anyway). Computes the per-cell diff vs the still-pre-stroke
// shadow, then batch-applies to doc + history.
void BrushTool::SyncStrokeFromTexture(EditorContext& ctx,
                                       EditEngine& engine) {
    if (stroke_bbox_x0_ > stroke_bbox_x1_) return;  // no stamps fired

    Document& doc = ctx.document;
    const EditVolume& vol = doc.volume;
    Bbox3 bb{};
    bb.x0 = std::max(stroke_bbox_x0_, vol.x0);
    bb.y0 = std::max(stroke_bbox_y0_, vol.y0);
    bb.z0 = std::max(stroke_bbox_z0_, vol.z0);
    bb.x1 = std::min(stroke_bbox_x1_, vol.x1);
    bb.y1 = std::min(stroke_bbox_y1_, vol.y1);
    bb.z1 = std::min(stroke_bbox_z1_, vol.z1);
    if (bb.x0 > bb.x1 || bb.y0 > bb.y1 || bb.z0 > bb.z1) return;

    std::vector<uint8_t> post;
    const auto t_readback = perf::Now();
    engine.Readback(bb, &post);
    perf_readback_us_ += perf::Micros(perf::Now() - t_readback);

    const size_t bw = static_cast<size_t>(bb.x1 - bb.x0 + 1);
    const size_t bh = static_cast<size_t>(bb.y1 - bb.y0 + 1);
    const size_t bd = static_cast<size_t>(bb.z1 - bb.z0 + 1);
    if (post.size() < bw * bh * bd) return;

    // Single-pass diff + shadow update. DiffAndApplyRegion walks the
    // bbox row-by-row with memcmp short-circuit, writes new values
    // into the shadow as it goes, marks chunks dirty, and emits the
    // CellChange diff for history + grid.
    std::vector<CellChange> diff;
    diff.reserve(1024);
    const auto t_diff = perf::Now();
    doc.volume_shadow.DiffAndApplyRegion(bb.x0, bb.y0, bb.z0,
                                         bb.x1, bb.y1, bb.z1,
                                         post.data(), &diff);
    perf_diff_us_ += perf::Micros(perf::Now() - t_diff);

    if (diff.empty()) return;

    EditHistory& history = ctx.history;
    perf_cells_committed_ = diff.size();
    const auto t_apply = perf::Now();
    doc.grid.ApplyChanges(diff.data(), diff.size());
    perf_apply_us_ += perf::Micros(perf::Now() - t_apply);
    const auto t_history = perf::Now();
    history.RecordBatch(diff.data(), diff.size());
    perf_history_us_ += perf::Micros(perf::Now() - t_history);

    // DiffAndApplyRegion marked the shadow's chunks dirty. Drain —
    // the GPU texture has been authoritative the whole stroke, so
    // the next render-pass sync should upload nothing.
    (void)doc.volume_shadow.TakeDirtyChunks();
    doc.BumpGeometry();
}

bool BrushTool::OnMouseDown(EditorContext& ctx, InteractionState& state,
                            const ViewContext& vc, const MouseEvent& e,
                            EditEngine& engine) {
    const ToolMode mode = e.mods.command ? ToolMode::Remove : ctx.tool.mode;
    ResetStrokeState();
    // Bind / zero the skip bitmap to the doc's EditVolume. First call
    // pays a 16 MB allocation; subsequent calls memset in place.
    drag_skip_.ResetTo(ctx.document.volume);
    paint_mode_ = mode;
    is_dragging_ = true;
    state.drag_mode = DragMode::Paint;
    ctx.history.BeginOp();
    StampAtCursor(ctx, vc, e, mode, engine);
    return true;
}

void BrushTool::OnMouseDragged(EditorContext& ctx, InteractionState& /*state*/,
                                const ViewContext& vc, const MouseEvent& e,
                                EditEngine& engine) {
    if (!is_dragging_) return;
    StampAtCursor(ctx, vc, e, paint_mode_, engine);
}

void BrushTool::OnMouseUp(EditorContext& ctx, InteractionState& /*state*/,
                           const ViewContext& /*vc*/, const MouseEvent& /*e*/,
                           EditEngine& engine) {
    if (!is_dragging_) return;
    const auto t_total = perf::Now();
    SyncStrokeFromTexture(ctx, engine);
    ctx.history.CommitOp();
    if (perf::Enabled()) {
        const double total_us = perf::Micros(perf::Now() - t_total) +
                                perf_footprint_us_;
        fprintf(stderr,
                "[perf brush] stamps=%d cells=%zu footprint=%.0fus "
                "readback=%.0fus diff=%.0fus apply=%.0fus history=%.0fus "
                "total=%.0fus\n",
                perf_stamp_count_, perf_cells_committed_, perf_footprint_us_,
                perf_readback_us_, perf_diff_us_, perf_apply_us_,
                perf_history_us_, total_us);
    }
    is_dragging_ = false;
    ResetStrokeState();
}

void BrushTool::Cancel(EditorContext& ctx, InteractionState& /*state*/,
                       EditEngine& engine) {
    if (!is_dragging_) return;
    // Treat cancel like a normal commit-by-readback: anything the
    // kernel already wrote to tex_a stays, and we record it as the
    // stroke's history so the user can undo it. The brush kernel
    // writes the doc texture *directly* so there's no preview to
    // discard — the writes are real.
    const auto t_total = perf::Now();
    SyncStrokeFromTexture(ctx, engine);
    ctx.history.CommitOp();
    if (perf::Enabled()) {
        const double total_us = perf::Micros(perf::Now() - t_total) +
                                perf_footprint_us_;
        fprintf(stderr,
                "[perf brush cancel] stamps=%d cells=%zu footprint=%.0fus "
                "readback=%.0fus diff=%.0fus apply=%.0fus history=%.0fus "
                "total=%.0fus\n",
                perf_stamp_count_, perf_cells_committed_, perf_footprint_us_,
                perf_readback_us_, perf_diff_us_, perf_apply_us_,
                perf_history_us_, total_us);
    }
    is_dragging_ = false;
    ResetStrokeState();
}

}  // namespace macvoxel
