#pragma once

#include "Shapes.h"
#include "Tool.h"

#include <cstdint>

namespace macvoxel {

// Cursor-AOE Mutator tool. Hybrid of Brush (footprint follows the
// cursor) and Generator (parameterized GPU kernel per cell). The kernel
// reads existing voxel state via the live-composited view of tex_a +
// tex_t + preview_rem, then writes a delta into tex_t (Foliage v1) or
// preview_rem (future Erode-style kinds).
//
// Dispatch is gated by `ShouldDispatch` on (cursor cell + params): hold
// the cursor still → no work; move by one cell → one new pass. RNG
// inside the kernel is keyed on (cell, stroke_id) so each stroke
// produces fresh candidate cells.
class MutatorTool final : public Tool {
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

    // Mutator's rule may decline to write any given cell in the AOE
    // (stochastic gate, neighbor predicate, …). The AOE outline lets
    // the user distinguish "didn't fire because not in AOE" from
    // "didn't fire because the rule said no."
    void DrawOverlay(const InteractionState& state, const ViewContext& vc,
                     OverlayDraw& od, bool mouse_captured_by_ui) const override;

    void Tick(EditorContext& ctx, InteractionState& state,
              const ViewContext& vc,
              ToolKind active_tool, bool escape_pressed,
              EditEngine& engine) override;

    void Cancel(EditorContext& ctx, InteractionState& state,
                EditEngine& engine) override;

protected:
    uint64_t DispatchParamsHash(const EditorContext& ctx,
                                 const InteractionState& state,
                                 const ViewContext& vc,
                                 const MouseEvent& e) const override;

private:
    void StampAtCursor(EditorContext& ctx, const ViewContext& vc,
                       const MouseEvent& e, EditEngine& engine);
    void SyncStrokeFromTexture(EditorContext& ctx, EditEngine& engine);
    void ResetStrokeState();
    void ClearHoverPreviewBbox(EditEngine& engine);

    bool is_dragging_ = false;
    uint32_t stroke_id_ = 0;
    // Hover RNG seed — separate from drag's so the ghost is stable
    // across hover frames on the same cursor cell. OnMouseDown
    // *adopts* this id as the drag's stroke_id so the first stamp
    // produces the same cells the user was already seeing.
    uint32_t hover_stroke_id_ = 0;
    static uint32_t s_stroke_counter_;
    shapes::Vec3i last_drag_edit_cell_{INT32_MIN, INT32_MIN, INT32_MIN};
    int last_face_axis_ = 2;
    int32_t hover_bbox_x0_ = INT32_MAX, hover_bbox_y0_ = INT32_MAX,
            hover_bbox_z0_ = INT32_MAX;
    int32_t hover_bbox_x1_ = INT32_MIN, hover_bbox_y1_ = INT32_MIN,
            hover_bbox_z1_ = INT32_MIN;
    uint64_t hover_last_hash_ = 0;
    // Union AABB of every AOE this stroke touched (world cells).
    int32_t stroke_bbox_x0_ = INT32_MAX, stroke_bbox_y0_ = INT32_MAX,
            stroke_bbox_z0_ = INT32_MAX;
    int32_t stroke_bbox_x1_ = INT32_MIN, stroke_bbox_y1_ = INT32_MIN,
            stroke_bbox_z1_ = INT32_MIN;
};

}  // namespace macvoxel
