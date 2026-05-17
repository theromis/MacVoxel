#pragma once

#include "Generators.h"
#include "InteractionState.h"
#include "ToolState.h"

#include <functional>
#include <vector>

namespace macvoxel {
class OverlayDraw;
struct EditorContext;
struct MouseEvent;
struct ViewContext;
struct Bbox3;
struct ShapeParams;
}

// Generator tool: parameterized shape primitives laid out via a
// gizmoized AABB. Click-and-drag-out lays the initial AABB (live
// preview during drag); mouseUp leaves the box visible with face-
// normal arrow handles; clicking a handle drags that face along its
// outward normal (the engine re-runs each frame from the per-frame
// Tick); clicking outside any handle commits through history; Esc /
// tool switch cancels.
namespace macvoxel::generator_controller {

// Pure-C++ binding for the Obj-C++ GeneratorEngine. The dispatcher
// (MetalScene) wraps the engine in a closure; the controller never
// sees AppKit / Metal types and stays portable. The kernel writes
// preview cells directly into the doc's tex_t (and clears stale
// cells from the previous frame's bounds in the same dispatch).
using GenerateFn = std::function<
    void(generators::Kind, generators::Bounds3i bounds,
         generators::Bounds3i last_bounds, generators::Params)>;

// Commit + readback closures, reusing the shape engine's shape_commit
// kernel (mode-aware Add/Paint/Remove + clears preview) and the
// shared bbox-to-CPU readback.
using CommitFn = std::function<void(const ShapeParams& params)>;
using ReadBackFn =
    std::function<void(const Bbox3& world_bbox, std::vector<uint8_t>* out_bytes)>;

// mouseDown when tool=Generator and gizmo isn't active. Picks the
// anchor cell, activates the gizmo at that cell (single-cell box),
// runs the engine for the first preview. Cmd flips to Remove for
// the stroke. Returns false on anchor miss; caller resets drag_mode.
bool BeginDragOut(EditorContext& ctx, InteractionState& state,
                  const ViewContext& vc, const MouseEvent& e,
                  const GenerateFn& generate);

// mouseDragged during DragMode::Shape with anchor.tool=Generator.
// Recomputes bounds from anchor + cursor, re-runs engine, refreshes
// preview, keeps gen_gizmo state synced so DrawOverlay sees the
// live bounds.
void UpdateDragOut(EditorContext& ctx, InteractionState& state,
                   const ViewContext& vc, const MouseEvent& e,
                   const GenerateFn& generate);

// mouseUp ending drag-out. Leaves the gizmo live and visible; the
// user commits / cancels / face-drags later. Drops the anchor.
void EndDragOut(InteractionState& state);

// mouseDown while gizmo is active. Picks a face arrow → enter
// face-handle scale drag; click outside any handle → commit through
// history. Always consumes the click (drag_mode is set or the gizmo
// exits). `commit` + `readback` are only invoked on the outside-
// handle path.
void OnGizmoClick(EditorContext& ctx, InteractionState& state,
                  const ViewContext& vc, const MouseEvent& e,
                  const CommitFn& commit, const ReadBackFn& readback);

// mouseDragged during DragMode::GenHandle. Projects cursor delta
// onto the dragged face's normal in NDC, scales gizmo.bounds.
// Tick re-runs the engine on the next frame.
void UpdateHandleDrag(InteractionState& state,
                      const ViewContext& vc, const MouseEvent& e);

// mouseUp ending handle drag. Leaves bounds where the user released
// them; clears active_drag_face so the arrow tint clears.
void EndHandleDrag(InteractionState& state);

// Per-frame:
// - Cancel the gizmo on tool-switch (active_tool != Generator) or
//   when escape_pressed.
// - Detect kind / bounds / params / palette changes since last
//   refresh, re-run the engine if dirty.
//
// active_tool and escape_pressed are injected so the controller
// stays free of ImGui and AppKit dependencies.
void Tick(EditorContext& ctx, InteractionState& state,
          ToolKind active_tool, bool escape_pressed,
          const GenerateFn& generate);

// Commit the live preview through history as one undo step; exit
// gizmo state. The commit kernel + readback come from MetalScene
// (same pattern the shape tools use for mouseUp).
void Commit(EditorContext& ctx, InteractionState& state,
            const CommitFn& commit, const ReadBackFn& readback);

// Discard the gizmo without writing to history. Drops the preview
// (the doc was never touched). Also clears any in-progress
// face-handle drag so the next mouse event lands cleanly. Issues a
// generate dispatch with an empty `bounds` so the kernel zeros
// every cell in the last dispatch's bbox.
void Cancel(EditorContext& ctx, InteractionState& state,
            const GenerateFn& generate);

// Gizmo overlay: 12-edge AABB outline + 6 face-normal arrow handles.
// mouse_captured_by_ui suppresses hover-tinting when an overlaying
// panel has the cursor.
void DrawOverlay(const InteractionState& state, const ViewContext& vc,
                 OverlayDraw& od, bool mouse_captured_by_ui);

}  // namespace macvoxel::generator_controller
