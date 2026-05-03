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
    // Path-trace target resolution. When `match_window` is true, the
    // tracer renders at the drawable's pixel size (the values below are
    // ignored). Otherwise it renders at exactly (render_width,
    // render_height) and the display pass scales to the drawable —
    // which is exactly what the user wants for "render this scene at
    // 3840 × 2160" regardless of window size.
    bool resolution_match_window = true;
    int render_width = 1920;
    int render_height = 1080;
};

RenderState& CurrentRenderState();

}  // namespace macvoxel
