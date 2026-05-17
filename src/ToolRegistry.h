#pragma once

#include "Tool.h"

#include <memory>

namespace macvoxel {

class BrushTool;
class FaceTool;
class GeneratorTool;
class OverlayDraw;
class ShapeTool;
struct EditorContext;
struct InteractionState;
struct ViewContext;
enum class ToolKind;

// Owns one instance of each volume-writing Tool subclass and routes
// `ToolKind` queries to them. Selection tools (Marquee / BoxSelect /
// FloodSelect / MoveSelect / XformHandle) are not registered here —
// they kept their per-controller branches in MetalScene because they
// don't write to the volume and were out of scope for the Tool
// abstraction refactor.
class ToolRegistry {
public:
    ToolRegistry();
    ~ToolRegistry();

    // Returns the Tool* for a volume-writing ToolKind, or nullptr for
    // anything else. Callers handle the nullptr case by falling through
    // to their existing per-tool branch.
    Tool* ToolFor(ToolKind kind);

    // Tick every owned Tool every frame. Default Tool::Tick is a no-op
    // so this is cheap for tools that don't override.
    void TickAll(EditorContext& ctx, InteractionState& state,
                 ToolKind active_tool, bool escape_pressed,
                 EditEngine& engine);

    // Draw every owned Tool's overlay. Same default-noop story.
    void DrawOverlays(const InteractionState& state, const ViewContext& vc,
                      OverlayDraw& od, bool mouse_captured_by_ui) const;

    // Direct accessors for Tool-specific methods not on the Tool base
    // interface (e.g. GeneratorTool::HasActiveGizmo /
    // GeneratorTool::Commit for the Enter-key path, FaceTool::Reset
    // for the per-frame tool-switch cancel).
    GeneratorTool* generator() { return generator_tool_.get(); }
    FaceTool* face() { return face_tool_.get(); }

private:
    std::unique_ptr<BrushTool> brush_tool_;
    std::unique_ptr<ShapeTool> shape_tool_;
    std::unique_ptr<FaceTool> face_tool_;
    std::unique_ptr<GeneratorTool> generator_tool_;
};

}  // namespace macvoxel
