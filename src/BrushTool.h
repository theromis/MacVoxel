#pragma once

#include "Shapes.h"
#include "Tool.h"
#include "ToolState.h"

#include <cstdint>
#include <unordered_set>

namespace macvoxel {

// Bare-click stroke painter. The default tool — anything that doesn't
// claim mouseDown via its own branch lands here. Cmd flips the stroke
// to Remove.
//
// During a stroke: the brush kernel writes the doc texture directly,
// while `doc.grid` / `doc.volume_shadow` stay frozen at pre-stroke
// state. `drag_skip_cells_` is the CPU-side oracle so each pick's
// raycast ignores cells the stroke has *just* placed (otherwise the
// brush marches outward along the face normal). On `OnMouseUp` the
// stroke's union bbox is read back from the texture, diffed against
// the still-pre-stroke shadow, and batch-applied to grid + shadow +
// history.
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

    void Cancel(EditorContext& ctx, InteractionState& state,
                EditEngine& engine) override;

private:
    void StampAtCursor(EditorContext& ctx, const ViewContext& vc,
                       const MouseEvent& e, ToolMode mode,
                       EditEngine& engine);
    void SyncStrokeFromTexture(EditorContext& ctx, EditEngine& engine);
    void ResetStrokeState();

    bool is_dragging_ = false;
    ToolMode paint_mode_ = ToolMode::Add;
    shapes::Vec3i last_drag_edit_cell_{INT32_MIN, INT32_MIN, INT32_MIN};
    std::unordered_set<int64_t> drag_skip_cells_;
    // Union AABB of every stamp's footprint in this stroke. INT32_MAX /
    // MIN sentinels = empty (no stamps fired yet).
    int32_t stroke_bbox_x0_ = INT32_MAX, stroke_bbox_y0_ = INT32_MAX,
            stroke_bbox_z0_ = INT32_MAX;
    int32_t stroke_bbox_x1_ = INT32_MIN, stroke_bbox_y1_ = INT32_MIN,
            stroke_bbox_z1_ = INT32_MIN;
};

}  // namespace macvoxel
