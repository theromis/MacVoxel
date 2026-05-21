#pragma once

#include "Shapes.h"
#include "Tool.h"
#include "ToolState.h"

#include <cstdint>

namespace macvoxel {

// Bare-click stroke painter. The default tool — anything that doesn't
// claim mouseDown via its own branch lands here. Cmd flips the stroke
// to Remove.
//
// During a stroke: the kernel writes preview surfaces (tex_t for Add /
// Paint, preview_rem for Remove); doc.grid / volume_shadow / tex_a
// stay frozen at pre-stroke state. On `OnMouseUp` commit_generic
// promotes the preview into tex_a, then the stroke's union bbox is
// read back, diffed against the shadow, and batch-applied to grid +
// shadow + history.
class BrushTool final : public Tool {
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

    bool IsDragging() const override { return is_dragging_; }

    void Tick(EditorContext& ctx, InteractionState& state,
              const ViewContext& vc,
              ToolKind active_tool, bool escape_pressed,
              EditEngine& engine) override;

    void Cancel(EditorContext& ctx, InteractionState& state,
                EditEngine& engine) override;

private:
    void StampAtCursor(EditorContext& ctx, const ViewContext& vc,
                       const MouseEvent& e, ToolMode mode,
                       EditEngine& engine);
    void SyncStrokeFromTexture(EditorContext& ctx, EditEngine& engine);
    void ResetStrokeState();
    // Hover preview: dispatch the brush kernel into the preview
    // surfaces every frame the cursor cell changes; clear the previous
    // frame's footprint so the rasterizer only composites the current.
    void ClearHoverPreviewBbox(EditEngine& engine);

    bool is_dragging_ = false;
    ToolMode paint_mode_ = ToolMode::Add;
    shapes::Vec3i last_drag_edit_cell_{INT32_MIN, INT32_MIN, INT32_MIN};
    // Union AABB of every stamp's footprint in this stroke. INT32_MAX /
    // MIN sentinels = empty (no stamps fired yet).
    int32_t stroke_bbox_x0_ = INT32_MAX, stroke_bbox_y0_ = INT32_MAX,
            stroke_bbox_z0_ = INT32_MAX;
    int32_t stroke_bbox_x1_ = INT32_MIN, stroke_bbox_y1_ = INT32_MIN,
            stroke_bbox_z1_ = INT32_MIN;

    // Hover preview state — separate from stroke_bbox so a drag-start
    // can flush the hover footprint cleanly without re-flushing the
    // drag's own bbox math.
    int32_t hover_bbox_x0_ = INT32_MAX, hover_bbox_y0_ = INT32_MAX,
            hover_bbox_z0_ = INT32_MAX;
    int32_t hover_bbox_x1_ = INT32_MIN, hover_bbox_y1_ = INT32_MIN,
            hover_bbox_z1_ = INT32_MIN;
    uint64_t hover_last_hash_ = 0;

    // MACVOXEL_PERF accumulators. Reset in ResetStrokeState; printed
    // once per stroke in OnMouseUp / Cancel.
    int perf_stamp_count_ = 0;
    double perf_readback_us_ = 0.0;
    double perf_diff_us_ = 0.0;
    double perf_apply_us_ = 0.0;
    double perf_history_us_ = 0.0;
    size_t perf_cells_committed_ = 0;
};

}  // namespace macvoxel
