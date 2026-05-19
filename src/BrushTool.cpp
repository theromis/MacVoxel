#include "BrushTool.h"

#include "BrushEngine.h"
#include "Document.h"
#include "EditEngine.h"
#include "EditHistory.h"
#include "EditorContext.h"
#include "Input.h"
#include "InteractionState.h"
#include "Perf.h"
#include "ShapeEngine.h"  // CommitGenericParams
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
    stroke_bbox_x0_ = stroke_bbox_y0_ = stroke_bbox_z0_ = INT32_MAX;
    stroke_bbox_x1_ = stroke_bbox_y1_ = stroke_bbox_z1_ = INT32_MIN;
    perf_stamp_count_ = 0;
    perf_readback_us_ = 0.0;
    perf_diff_us_ = 0.0;
    perf_apply_us_ = 0.0;
    perf_history_us_ = 0.0;
    perf_cells_committed_ = 0;
}

// Submit one brush stamp and extend the stroke's union bbox by the
// stamp footprint. The kernel writes preview surfaces (tex_t / preview_rem)
// — doc.grid and volume_shadow stay frozen at pre-stroke state, so
// picking already sees the original surface without a CPU-side skip
// set.
void BrushTool::StampAtCursor(EditorContext& ctx, const ViewContext& vc,
                              const MouseEvent& e, ToolMode mode,
                              EditEngine& engine) {
    shapes::Vec3i target;
    int face_axis = 2;
    if (!vc.ComputeTargetCell(e.local.x, e.local.y, mode, &target,
                              &face_axis)) {
        return;
    }
    if (SameCell(target, last_drag_edit_cell_)) return;
    last_drag_edit_cell_ = target;

    const BrushParams p = BuildParams(ctx, target.x, target.y, target.z,
                                      face_axis, mode);

    // The stroke bbox tracks the kernel's footprint AABB — clipped to
    // the edit volume at commit time. The footprint is centered on
    // `target` with half-extent (size/2); circle-shape kernels skip
    // corner cells but the bbox stays AABB.
    const int lo = p.lo_x;
    const int hi = lo + p.size_x - 1;
    stroke_bbox_x0_ = std::min(stroke_bbox_x0_, target.x + lo);
    stroke_bbox_y0_ = std::min(stroke_bbox_y0_, target.y + lo);
    stroke_bbox_z0_ = std::min(stroke_bbox_z0_, target.z + lo);
    stroke_bbox_x1_ = std::max(stroke_bbox_x1_, target.x + hi);
    stroke_bbox_y1_ = std::max(stroke_bbox_y1_, target.y + hi);
    stroke_bbox_z1_ = std::max(stroke_bbox_z1_, target.z + hi);
    ++perf_stamp_count_;

    engine.BrushStamp(p);
}

// End-of-stroke sync. Promotes the stroke's preview surfaces into
// tex_a via commit_generic, then reads back the union bbox and
// diffs it against the still-pre-stroke shadow.
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

    // Add → bm=1 (consume tex_t), Remove → bm=2 (consume preview_rem),
    // Paint → bm=3 (Replace from tex_t).
    CommitGenericParams cp{};
    cp.dispatch_lo_x = bb.x0 - vol.x0;
    cp.dispatch_lo_y = bb.y0 - vol.y0;
    cp.dispatch_lo_z = bb.z0 - vol.z0;
    cp.dispatch_size_x = bb.x1 - bb.x0 + 1;
    cp.dispatch_size_y = bb.y1 - bb.y0 + 1;
    cp.dispatch_size_z = bb.z1 - bb.z0 + 1;
    cp.bm = (paint_mode_ == ToolMode::Remove) ? 2u
          : (paint_mode_ == ToolMode::Paint)  ? 3u
                                              : 1u;
    cp.brush = 0u;  // source = preview surfaces
    cp.fill_palette = ctx.tool.palette_idx;
    engine.CommitGeneric(cp);

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
    paint_mode_ = mode;
    is_dragging_ = true;
    state.drag_mode = DragMode::Paint;
    ctx.preview_active = true;
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
    ctx.preview_active = false;
    ctx.history.CommitOp();
    if (perf::Enabled()) {
        const double total_us = perf::Micros(perf::Now() - t_total);
        fprintf(stderr,
                "[perf brush] stamps=%d cells=%zu "
                "readback=%.0fus diff=%.0fus apply=%.0fus history=%.0fus "
                "total=%.0fus\n",
                perf_stamp_count_, perf_cells_committed_,
                perf_readback_us_, perf_diff_us_, perf_apply_us_,
                perf_history_us_, total_us);
    }
    is_dragging_ = false;
    ResetStrokeState();
}

void BrushTool::Cancel(EditorContext& ctx, InteractionState& /*state*/,
                       EditEngine& engine) {
    if (!is_dragging_) return;
    // Commit whatever's in the preview surfaces as the stroke's
    // history — matches pre-Phase-2.4 cancel semantics (a cancelled
    // stroke leaves its stamps committed so the user can undo).
    const auto t_total = perf::Now();
    SyncStrokeFromTexture(ctx, engine);
    ctx.preview_active = false;
    ctx.history.CommitOp();
    if (perf::Enabled()) {
        const double total_us = perf::Micros(perf::Now() - t_total);
        fprintf(stderr,
                "[perf brush cancel] stamps=%d cells=%zu "
                "readback=%.0fus diff=%.0fus apply=%.0fus history=%.0fus "
                "total=%.0fus\n",
                perf_stamp_count_, perf_cells_committed_,
                perf_readback_us_, perf_diff_us_, perf_apply_us_,
                perf_history_us_, total_us);
    }
    is_dragging_ = false;
    ResetStrokeState();
}

}  // namespace macvoxel
