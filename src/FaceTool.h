#pragma once

#include "Shapes.h"
#include "Tool.h"
#include "ToolState.h"

#include <cstdint>
#include <vector>

namespace macvoxel {

struct CellPalette;

// Face tool: click selects a coplanar same-color flood region whose
// face on the clicked side is exposed; drag extrudes (positive,
// outward) or insets (negative, inward) by an integer number of voxel
// layers along the face normal.
//
// Phase B3c (still in place): flood-fill stays CPU (needs `doc.grid`
// for same-color matching), but the per-frame extrusion writes go
// through `EditEngine::StampCells` writing tex_t. The rasterizer
// composites tex_t over the doc; commit promotes via `CommitCells` +
// a bbox readback for the per-cell history diff.
//
// Mode dispatch (mode is frozen at click via state.anchor.mode):
//   Add    — signed d. Positive extrudes; negative insets (erases).
//   Remove — |d| layers, always inset.
//   Paint  — |d| inward layers, repaint existing voxels.
class FaceTool final : public Tool {
public:
    bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                     const ViewContext& vc, const MouseEvent& e,
                     EditEngine& engine) override;
    void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                        const ViewContext& vc, const MouseEvent& e,
                        EditEngine& engine) override;
    void OnMouseUp(EditorContext& ctx, InteractionState& state,
                   const ViewContext& vc, const MouseEvent& e,
                   EditEngine& engine) override;

    bool IsDragging() const override { return dragging_; }

    void Cancel(EditorContext& ctx, InteractionState& state,
                EditEngine& engine) override;

    // Clear gesture-local state without touching history. Called from
    // MetalScene's per-frame tool-switch / Esc handler when the active
    // anchor is invalidated externally. (The full `Cancel` would also
    // AbandonOp on history — preserving the pre-migration behavior
    // here, the soft reset doesn't.)
    void Reset();

private:
    void Refresh(EditorContext& ctx, InteractionState& state, int d,
                 EditEngine& engine);
    void EnumerateCells(const EditorContext& ctx,
                        const InteractionState& state, int d,
                        std::vector<CellPalette>* out,
                        int32_t* bx0, int32_t* by0, int32_t* bz0,
                        int32_t* bx1, int32_t* by1, int32_t* bz1) const;
    int ComputeFaceVoxels(InteractionState& state, const ViewContext& vc,
                          const MouseEvent& e);

    bool dragging_ = false;

    int sign_ = 0;
    uint8_t seed_color_ = 0;
    bool observed_drag_ = false;
    int applied_d_ = 0;
    FaceWithColor applied_with_ = FaceWithColor::Geometry;
    bool from_wall_ = false;
    std::vector<shapes::Vec3i> seed_cells_;

    // Per-frame bbox bookkeeping for the tex_t preview. last_bbox is
    // what we wrote last frame (cleared on the next Refresh);
    // union_bbox accumulates across the stroke for the commit readback.
    // INT32_MAX / MIN = empty.
    int32_t last_bbox_x0_ = INT32_MAX, last_bbox_y0_ = INT32_MAX,
            last_bbox_z0_ = INT32_MAX;
    int32_t last_bbox_x1_ = INT32_MIN, last_bbox_y1_ = INT32_MIN,
            last_bbox_z1_ = INT32_MIN;
    int32_t union_bbox_x0_ = INT32_MAX, union_bbox_y0_ = INT32_MAX,
            union_bbox_z0_ = INT32_MAX;
    int32_t union_bbox_x1_ = INT32_MIN, union_bbox_y1_ = INT32_MIN,
            union_bbox_z1_ = INT32_MIN;

    // MACVOXEL_PERF accumulators. Reset in Reset() at stroke start;
    // printed once per stroke in OnMouseUp / Cancel.
    double perf_flood_us_ = 0.0;
    size_t perf_flood_cells_ = 0;
    double perf_readback_us_ = 0.0;
    double perf_diff_us_ = 0.0;
    double perf_apply_us_ = 0.0;
    double perf_history_us_ = 0.0;
    size_t perf_cells_committed_ = 0;
};

}  // namespace macvoxel
