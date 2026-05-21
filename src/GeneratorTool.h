#pragma once

#include "Generators.h"
#include "Tool.h"

#include <cstdint>

#include <simd/simd.h>

namespace macvoxel {

// Generator tool: parameterized shape primitives laid out via a
// gizmoized AABB. Click-and-drag-out lays the initial AABB (live
// preview into tex_t); mouseUp leaves the box visible with face-
// normal arrow handles; clicking a handle drags that face along its
// outward normal (Tick re-runs the engine on the next frame from the
// dirty check); clicking outside any handle commits through history;
// Esc / tool switch cancels.
//
// `Commit` is exposed publicly so MetalScene's Enter-key handler can
// invoke it directly — committing isn't tied to mouseUp the way it is
// for Brush / Shape.
class GeneratorTool final : public Tool {
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

    void Tick(EditorContext& ctx, InteractionState& state,
              const ViewContext& vc,
              ToolKind active_tool, bool escape_pressed,
              EditEngine& engine) override;

    void DrawOverlay(const InteractionState& state, const ViewContext& vc,
                     OverlayDraw& od, bool mouse_captured_by_ui) const override;

    bool IsDragging() const override { return mouse_drag_ != Drag::None; }

    void Cancel(EditorContext& ctx, InteractionState& state,
                EditEngine& engine) override;

    // Promote the live preview through history. Triggered by clicking
    // outside any face-handle, or by the Enter key from MetalScene.
    // No-op if no gizmo is active.
    void Commit(EditorContext& ctx, InteractionState& state,
                EditEngine& engine);

    // Whether the persistent gizmo is alive (drag-out or handle drag
    // produces a gizmo that survives the mouseUp; persists until
    // Commit / Cancel). MetalScene's mouseDown dispatcher needs to
    // know this to route into the active-gizmo path vs the BeginDragOut
    // path.
    bool HasActiveGizmo() const { return active_; }

private:
    enum class Drag { None, DragOut, HandleScale };

    void Regenerate(EditorContext& ctx, InteractionState& state,
                    generators::Bounds3i bounds, EditEngine& engine);
    void ExtendUnion(generators::Bounds3i b);
    void ResetUnion();

    // Persistent gizmo state.
    bool active_ = false;
    generators::Bounds3i bounds_{};
    // Last bounds we actually dispatched to the GPU. Read at the start
    // of the next Regenerate to compute the kernel's clear-union.
    generators::Bounds3i last_bounds_dispatched_{};
    bool last_bounds_dispatched_valid_ = false;
    // Union of every dispatch's bbox across the gesture. Commit reads
    // this to know how much of tex_a to blit back for the diff.
    int32_t union_x0_ = INT32_MAX, union_y0_ = INT32_MAX, union_z0_ = INT32_MAX;
    int32_t union_x1_ = INT32_MIN, union_y1_ = INT32_MIN, union_z1_ = INT32_MIN;

    // Face-handle drag state. Captured at drag-start so per-frame
    // drag math projects against a stable NDC reference (bounds
    // change as the user drags, but the reference doesn't).
    int active_drag_face_ = -1;
    simd::float2 handle_start_local_{0.0f, 0.0f};
    generators::Bounds3i handle_start_bounds_{};

    // Which mouse-driven drag is currently live (mirrors the dispatcher's
    // DragMode but private to this Tool).
    Drag mouse_drag_ = Drag::None;
};

}  // namespace macvoxel
