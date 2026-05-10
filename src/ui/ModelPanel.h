#pragma once

#include <cstddef>
#include <cstdint>

namespace macvoxel {

struct EditorContext;

struct RenderStats {
    uint32_t chunk_count = 0;
    size_t gpu_bytes = 0;
};

void DrawModelPanel(EditorContext& ctx, const RenderStats& stats);

}  // namespace macvoxel
