#pragma once

#include <cstdint>

namespace macvoxel {

class EditEngine;
class OverlayDraw;
struct EditorContext;
struct InteractionState;
struct MouseEvent;
struct ViewContext;
enum class ToolKind;

// Abstract base for any tool that owns a click → drag → commit gesture.
// Replaces the namespace-of-static-functions controllers + per-tool
// `std::function` closure bags: a Tool is one object, the dispatcher
// forwards every NSEvent to it, the Tool reaches into the shared
// `EditEngine` façade for kernel dispatches and readbacks.
//
// Lifecycle: `ToolRegistry` owns one instance per `ToolKind`. The
// instance survives across drags so Tool implementations can keep
// gesture state (anchors, in-flight previews, gizmo position) as
// private members rather than parking it in the global `InteractionState`.
class Tool {
public:
    virtual ~Tool() = default;

    // Returns true if the click was consumed and a drag (or one-shot
    // commit) was initiated. The dispatcher uses this to decide whether
    // to fall back to camera-orbit / hover / no-op handling.
    //
    // `state` is the transitional InteractionState passthrough — Tools
    // that still share cross-tool fields (e.g. state.anchor between
    // Shape and Generator) read/write it during Phases 1-3. Phase 4
    // dissolves the remaining shared fields and the parameter goes away.
    virtual bool OnMouseDown(EditorContext& ctx, InteractionState& state,
                             const ViewContext& vc, const MouseEvent& e,
                             EditEngine& engine) = 0;

    virtual void OnMouseDragged(EditorContext& ctx, InteractionState& state,
                                const ViewContext& vc, const MouseEvent& e,
                                EditEngine& engine) = 0;

    virtual void OnMouseUp(EditorContext& ctx, InteractionState& state,
                           const ViewContext& vc, const MouseEvent& e,
                           EditEngine& engine) = 0;

    // Called every frame from `MetalScene drawInMTKView`. Tools use this
    // for time-based work (Generator's persistent gizmo, cancel-on-Esc,
    // tool-switch cleanup, Brush/Mutator hover preview). `active_tool`
    // is `EditorContext::tool.tool`; a Tool whose kind no longer
    // matches should Cancel itself. `escape_pressed` is the per-frame
    // edge for Esc handling. `vc` is the current view (camera + view
    // size) — hover-preview tools use it to pick the cursor cell.
    virtual void Tick(EditorContext& /*ctx*/, InteractionState& /*state*/,
                      const ViewContext& /*vc*/,
                      ToolKind /*active_tool*/, bool /*escape_pressed*/,
                      EditEngine& /*engine*/) {}

    // Optional 2D overlay (gizmo handles, anchor markers, preview text).
    // `mouse_captured` is true when *this* Tool currently owns the drag.
    virtual void DrawOverlay(const InteractionState& /*state*/,
                             const ViewContext& /*vc*/,
                             OverlayDraw& /*out*/,
                             bool /*mouse_captured*/) const {}

    // True while a drag is in flight. The dispatcher uses this to route
    // mouseDragged / mouseUp back to the same Tool that consumed
    // mouseDown.
    virtual bool IsDragging() const = 0;

    // Abort any in-flight drag without committing. Called on tool-switch
    // and Esc. Default no-op for tools without persistent state.
    virtual void Cancel(EditorContext& /*ctx*/, InteractionState& /*state*/,
                        EditEngine& /*engine*/) {}

protected:
    // Subclasses override to produce a stable hash of "what would the
    // next kernel dispatch write." OnMouseDragged (or Tick, for tools
    // whose dirty checking is per-frame rather than per-event) calls
    // ShouldDispatch with that hash; identical hash → no work to do,
    // early-return. Returning 0 disables the check (always dispatch).
    // 2^-64 collision rate is fine in practice.
    virtual uint64_t DispatchParamsHash(const EditorContext& /*ctx*/,
                                        const InteractionState& /*state*/,
                                        const ViewContext& /*vc*/,
                                        const MouseEvent& /*e*/) const {
        return 0;
    }
    bool ShouldDispatch(uint64_t h) {
        if (h != 0 && h == last_dispatch_hash_) return false;
        last_dispatch_hash_ = h;
        return true;
    }
    void ResetDispatchHash() { last_dispatch_hash_ = 0; }

private:
    uint64_t last_dispatch_hash_ = 0;
};

}  // namespace macvoxel
