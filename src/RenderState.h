#pragma once

#include <cstdint>

namespace macvoxel {

// How `Material::transparency` shapes the glass branch of the path
// tracer. Two interpretations the user can flip between:
//
// - Probabilistic: with probability `transparency`, take a refracting
//   transmit path (Beer-Lambert through the actual albedo); otherwise
//   diffuse-fallback bounce. transparency=1 still tints heavily because
//   the medium albedo is the surface color regardless. transparency=0.5
//   reads as "milky glass". This is the editor-original behavior.
// - Absorption: always refract on transmit (no diffuse fallback).
//   transparency interpolates the medium albedo from the surface color
//   (transparency=0) toward white (transparency=1). transparency=1 is a
//   completely clear pane regardless of color; transparency=0 is fully
//   tinted glass. Matches MagicaVoxel's interpretation more closely.
enum class GlassMode : uint8_t {
    Probabilistic = 0,
    Absorption = 1,
};

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
    GlassMode glass_mode = GlassMode::Probabilistic;
    // Direct-lighting NEE distribution. On = pick lights from a CDF
    // weighted by per-light power (default; the shipped behavior).
    // Off = pick uniformly across the light list and uniformly across
    // the 3 visible faces — the pre-P14.5.A baseline, kept as a toggle
    // so the user can A/B compare on emitter-heavy scenes.
    bool power_weighted_nee = true;
    // Resampled importance sampling (RIS) candidate count for direct
    // lighting NEE. Per pixel per frame, draw this many candidates from
    // the source distribution (power-weighted CDF or uniform), reservoir-
    // sample one weighted by the unshadowed integrand luminance, then
    // fire a single shadow ray. M=1 reduces to the non-RIS path, M>1
    // approximates sampling from `target_pdf` and reduces variance on
    // emitter-heavy scenes. Standard ReSTIR-DI starting territory; the
    // temporal / spatial reservoir reuse from Bitterli 2020 lands later.
    int nee_ris_count = 8;
    // Multiplier on the constant sky color the path tracer falls back
    // to when a ray escapes the grid. 1.0 is the default tint
    // (≈ daylight overcast, the post-P10.x default). Lowering it
    // darkens the sky so emitter contributions read more clearly;
    // raising it pushes toward HDR-like overcast. Stays a single
    // float until the eventual sun/sky model lands (Phase 14).
    float sky_intensity = 1.0f;
    // Sun disc — a directional emitter visible in the sky-miss path
    // when the escaping ray's direction lies within
    // `sun_angular_diameter_deg / 2` of `sun_direction`. Off by default
    // (intensity = 0) so existing scenes are unchanged. Position is
    // expressed in elevation/azimuth so the UI feels natural; the path
    // tracer consumes a pre-normalised grid-space direction. Color is
    // sRGB; the renderer decodes to linear and premultiplies by
    // intensity before upload.
    //
    // Direct (NEE) sampling of the sun is a follow-up — the current
    // path is BSDF-only, so surfaces lit primarily by a small sun will
    // be noisy until that lands.
    float sun_elevation_deg = 30.0f;       // 0 = horizon, 90 = zenith
    float sun_azimuth_deg = 30.0f;         // 0 = +grid-X, ccw around +grid-Z
    float sun_angular_diameter_deg = 5.0f; // visible disc; real sun ≈ 0.53°
    float sun_color[3] = {1.0f, 0.95f, 0.85f};  // sRGB warm white
    float sun_intensity = 0.0f;            // 0 = sun disabled
};

RenderState& CurrentRenderState();

}  // namespace macvoxel
