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

// Which renderer the scene view drives. Edit = realtime ray-cast
// preview; Render = our path tracer (PathTraceRenderer).
enum class RenderMode : uint8_t {
    Edit = 0,
    Render = 1,
};

// User-editable render configuration. Inputs only — anything the
// renderer *produces* (sample_count, etc.) belongs on RenderProgress
// so the input side stays a pure value an Observable / SwiftUI binding
// can publish without churning every frame.
struct RenderSettings {
    RenderMode mode = RenderMode::Edit;
    int max_bounces = 5;        // depth of bounces beyond the primary ray
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
    bool resolution_match_window = false;
    int render_width = 960;
    int render_height = 800;
    GlassMode glass_mode = GlassMode::Probabilistic;
    // Direct-lighting NEE distribution. On = pick lights from a CDF
    // weighted by per-light power (default; the shipped behavior).
    // Off = pick uniformly across the light list and uniformly across
    // the 3 visible faces — the pre-P14.5.A baseline, kept as a toggle
    // so the user can A/B compare on emitter-heavy scenes.
    bool power_weighted_nee = true;
    // MagicaVoxel's "Stochastic Sampling GI" toggle (= OPT_AREA in
    // their shader). On = explicit area-light NEE with MIS on every
    // surface hit. Off = no shadow rays toward emissive voxels; they
    // get discovered only when the BSDF random walk happens to land
    // on one. Higher variance with concentrated emitters but produces
    // the structured "splotchy" SS-GI-off noise character. Sun NEE is
    // independent of this flag.
    bool stochastic_gi = true;
    // CLI-only escape hatch: when true, the Render renderer falls
    // back to fully per-pixel PCG sampling (the unbiased textbook MC
    // path) instead of the MagicaVoxel-style tile-correlated stream.
    // The UI never sets this; it's only meaningful for headless
    // diffs that want a ground-truth reference image.
    bool path_trace_reference = false;
    // Proportional clamp on indirect emitter contributions (both NEE
    // shadow rays at b >= 1 and BSDF-walk arrivals at emissive
    // voxels). In scenes with sharp specular materials a single
    // diffuse→specular→emitter caustic path produces a per-sample
    // contribution that dominates the average, and MIS can't suppress
    // it (the BSDF lobe is essentially delta-aligned with the
    // emitter). Clamping caps those spikes in exchange for slight
    // energy bias. Magica's range is roughly 4..16; 8 is a sensible
    // starting point. <= 0 disables.
    float indirect_clamp_L = 8.0f;
    // Temporal-EMA blend weight for the display compose pass.
    // Mirrors MagicaVoxel's `weight` parameter in pt_post.glsl —
    // their `mix(tex_last, dst, weight)` blend is what we're emulating
    // here. The compose fragment evaluates
    //   displayed_now = mix(displayed_prev, current_mean, weight).
    //
    // Smaller weight = heavier smoothing (longer trail):
    //   0.0  → no smoothing — display = current_mean each frame, raw,
    //          identical to the pre-EMA behavior. Per-frame splash
    //          popping is visible.
    //   0.05 → ≈ 20-frame trailing average. Strongly suppresses
    //          per-sample variance from frame 2 onward; the
    //          displayed image visibly lags lighting changes for
    //          ~20 frames before catching up.
    //   0.5  → ≈ 2-frame trailing average. Light smoothing.
    //   1.0  → full weight on the current frame, history discarded —
    //          equivalent to 0.0.
    //
    // First frame after a reset (camera move, scene edit) always uses
    // weight 1.0 internally since there's no history to blend against.
    //
    // Trade-off: any value other than 0 or 1 introduces a small bias —
    // the displayed image lags the true running mean — but kills the
    // per-frame variance that makes splash mode look "noisy". This is
    // the noise floor Other Claude was reporting against MV.
    float ema_floor = 0.05f;
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
    float sun_angular_diameter_deg = 30.0f;
    float sun_color[3] = {1.0f, 0.95f, 0.85f};  // sRGB warm white
    float sun_intensity = 0.0f;            // 0 = sun disabled
    // Replace the constant sky tint with single-scatter Nishita
    // atmospheric scattering. Rayleigh + Mie species at Earth-like
    // scale heights produce the natural blue-zenith / warm-horizon
    // gradient + sun halo + sunset reddening from `sun_direction`
    // alone. Per-pixel atmospheric integral is moderately expensive
    // (~256 ops per missed sky ray) but offline-render-friendly.
    // When off, falls back to the constant `sky_color × sky_intensity`
    // tint.
    bool atmospheric_sky = false;
    // Aerial-perspective fade applied to grazing-angle primary rays
    // that hit the virtual ground plane: blends in the limit-direction
    // sky color so the floor doesn't meet the sky as a hard line.
    // Interpreted as the angular extent (degrees) over which the fade
    // is concentrated — at `horizon_softness_deg` below the horizon
    // the ground returns ~5% sky (≈ exp(-3)), so smaller = tighter,
    // 0 = off (sharp horizon).
    float horizon_softness_deg = 3.0f;
};

// Renderer-produced state. Reported back from PathTraceRenderer for the
// UI to display; never an input to the renderer.
struct RenderProgress {
    uint32_t sample_count = 0;  // current accumulated samples
};

}  // namespace macvoxel
