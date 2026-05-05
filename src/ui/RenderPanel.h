#pragma once

#include "ModelPanel.h"  // RenderStats

namespace macvoxel {

struct Document;

void DrawRenderPanel(Document& doc, const RenderStats& stats);

// True (and self-clears) on the frame the user clicked "Save render…".
// VoxelView consumes it after the panel has drawn and runs the export.
bool ConsumeSaveRenderClick();

}  // namespace macvoxel
