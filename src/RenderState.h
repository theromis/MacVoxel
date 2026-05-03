#pragma once

#include <cstdint>

namespace macvoxel {

// Application-wide rendering settings — which renderer is active, etc.
struct RenderState {
    bool path_traced = false;
    int max_bounces = 5;        // depth of bounces beyond the primary ray
    uint32_t sample_count = 0;  // current accumulated samples (read-only stat)
    // Cap on accumulated samples. Once reached, the renderer keeps
    // displaying the already-accumulated buffer but stops contributing
    // new samples — which makes "looks the same any longer" stop costing
    // GPU time. Camera or doc changes invalidate and start the count over.
    int max_samples = 1024;
    bool aces_tonemap = true;  // off = gamma-2.2 only, for before/after compare
};

RenderState& CurrentRenderState();

}  // namespace macvoxel
