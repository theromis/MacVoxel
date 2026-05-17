#include "ToolRegistry.h"

#include "BrushTool.h"
#include "FaceTool.h"
#include "GeneratorTool.h"
#include "ShapeTool.h"
#include "ToolState.h"

namespace macvoxel {

ToolRegistry::ToolRegistry()
    : brush_tool_(std::make_unique<BrushTool>()),
      shape_tool_(std::make_unique<ShapeTool>()),
      face_tool_(std::make_unique<FaceTool>()),
      generator_tool_(std::make_unique<GeneratorTool>()) {}

ToolRegistry::~ToolRegistry() = default;

Tool* ToolRegistry::ToolFor(ToolKind kind) {
    switch (kind) {
        case ToolKind::Brush:     return brush_tool_.get();
        case ToolKind::Line:
        case ToolKind::Circle:
        case ToolKind::Square:
        case ToolKind::Box:       return shape_tool_.get();
        case ToolKind::Face:      return face_tool_.get();
        case ToolKind::Generator: return generator_tool_.get();
        default:                  return nullptr;
    }
}

void ToolRegistry::TickAll(EditorContext& ctx, InteractionState& state,
                            ToolKind active_tool, bool escape_pressed,
                            EditEngine& engine) {
    brush_tool_->Tick(ctx, state, active_tool, escape_pressed, engine);
    shape_tool_->Tick(ctx, state, active_tool, escape_pressed, engine);
    face_tool_->Tick(ctx, state, active_tool, escape_pressed, engine);
    generator_tool_->Tick(ctx, state, active_tool, escape_pressed, engine);
}

void ToolRegistry::DrawOverlays(const InteractionState& state,
                                 const ViewContext& vc,
                                 OverlayDraw& od,
                                 bool mouse_captured_by_ui) const {
    brush_tool_->DrawOverlay(state, vc, od, mouse_captured_by_ui);
    shape_tool_->DrawOverlay(state, vc, od, mouse_captured_by_ui);
    face_tool_->DrawOverlay(state, vc, od, mouse_captured_by_ui);
    generator_tool_->DrawOverlay(state, vc, od, mouse_captured_by_ui);
}

}  // namespace macvoxel
