#pragma once

#include "ModelPanel.h"  // RenderStats

namespace macvoxel {

struct EditorContext;

void DrawRenderPanel(EditorContext& ctx, const RenderStats& stats);

// True (and self-clears) on the frame the user clicked "Save render…".
// VoxelView consumes it after the panel has drawn and runs the export.
bool ConsumeSaveRenderClick(EditorContext& ctx);

}  // namespace macvoxel
