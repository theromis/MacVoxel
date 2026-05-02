#pragma once

#include <cstdint>

namespace macvoxel {

// Application-wide rendering settings — which renderer is active, etc.
struct RenderState {
    bool path_traced = false;
    int max_bounces = 5;        // depth of bounces beyond the primary ray
    uint32_t sample_count = 0;  // current accumulated samples (read-only stat)
};

RenderState& CurrentRenderState();

}  // namespace macvoxel
