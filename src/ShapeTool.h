#pragma once

#include "Tool.h"

#include <cstdint>

namespace macvoxel {

enum class ToolMode;

// Two-click shape tools: Line, Circle, Square, Box. Click 1 anchors;
// drag through click 2 dispatches the shape kernel into `tex_t` each
// `OnMouseDragged`; `OnMouseUp` commits via a copy kernel + diff
// readback. The doc grid stays frozen until commit (same model as
// every other GPU-authoritative tool).
//
// `state.anchor` (in InteractionState) carries the shared two-click
// anchor fields (cell, face_axis, mode, screen_local, tool, has_anchor)
// because Generator's drag-out reads them too — Phase 4 will dissolve
// or relocate them. The per-stroke dispatch / union bbox tracking
// lives privately inside ShapeTool.
class ShapeTool final : public Tool {
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

private:
    void DispatchPreview(EditorContext& ctx, InteractionState& state,
                         const ViewContext& vc, const MouseEvent& e,
                         int kind, EditEngine& engine);
    void ResetBboxes();

    bool dragging_ = false;

    // Per-stroke dispatch + union bboxes. last_bbox_* is the previous
    // frame's dispatch — the kernel unions with it so stale cells get
    // zeroed in the same pass. union_bbox_* accumulates across the
    // whole stroke for the OnMouseUp commit + readback. Sentinels
    // INT32_MAX / MIN = empty.
    int32_t last_bbox_x0_ = INT32_MAX, last_bbox_y0_ = INT32_MAX,
            last_bbox_z0_ = INT32_MAX;
    int32_t last_bbox_x1_ = INT32_MIN, last_bbox_y1_ = INT32_MIN,
            last_bbox_z1_ = INT32_MIN;
    int32_t union_bbox_x0_ = INT32_MAX, union_bbox_y0_ = INT32_MAX,
            union_bbox_z0_ = INT32_MAX;
    int32_t union_bbox_x1_ = INT32_MIN, union_bbox_y1_ = INT32_MIN,
            union_bbox_z1_ = INT32_MIN;
};

// Pick the anchor cell from the cursor + populate `state.anchor`.
// Used by Shape (this Tool) and Generator (drag-out) — they share the
// two-click anchor's screen position / cell / face / mode / tool kind.
// Returns false if the click missed every cell *and* the empty-space
// ground-plane fallback wasn't usable.
bool BeginShapeAnchor(EditorContext& ctx, InteractionState& state,
                      const ViewContext& vc, const MouseEvent& e,
                      ToolMode mode);

}  // namespace macvoxel
