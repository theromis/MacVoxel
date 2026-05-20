#include <metal_stdlib>
using namespace metal;

struct PathUniforms {
    float4x4 inv_vp;
    float3   camera_pos;
    float    _pad0;
    int3     coarse_min;
    int      _pad1;
    int3     coarse_dim;
    int      _pad2;
    float3   sky_color;
    float    _pad3;
    uint     frame_seed;
    uint     max_bounces;
    uint     light_count;
    uint     glass_mode;
    uint     power_weighted_nee;  // 0 = uniform, 1 = power CDF
    uint     nee_ris_count;       // RIS candidate count (≥ 1)
    uint     atmospheric_sky;     // 0 = constant sky tint, 1 = Nishita
    uint     _pad6;
    float3   sun_dir_grid;        // grid-space, unit-length
    float    sun_cos_half_angle;  // cos(angular_diameter / 2)
    float3   sun_radiance;        // linear color × intensity
    float    horizon_softness_k;  // exp falloff coeff; 0 = no softening
    // Sampling stream selector. Tile-correlated mode (the default;
    // matches MagicaVoxel's path tracer) routes every path-decision
    // random — BSDF directions, NEE light/face/point picks, sun cone,
    // RR survival, glass Fresnel coin flips — through a single
    // per-pixel `corr` seed sampled once from a small noise texture
    // and advanced by `fract(corr * 859 + 1/5.93)` per call. Adjacent
    // pixels in a screen-area-of-one-noise-texel sample near-identical
    // sequences, so emissive cluster silhouettes project as coherent
    // shaped splashes rather than scattering into single-pixel
    // fireflies. AA sub-pixel jitter stays on the decorrelated PCG
    // stream regardless.
    //
    // `bsdf_correlation == 0` is the reference path: every site falls
    // back to PCG, producing unbiased textbook MC. Exposed only via
    // CLI `--reference`; the UI always sets this to 1 so the editor's
    // Render mode matches Magica's aesthetic by default.
    //
    // `lobes[b]` is the per-(frame, bounce) shared 2D stride for BSDF
    // direction samples; `jitter_mult` is the irrational rotator
    // applied to `corr` before adding it to a stride. Other call sites
    // generate their strides inline via `stride1/2(frame_seed, b, site)`.
    float4   lobes[8];              // .xy used; .zw reserved
    float2   jitter_mult;
    uint     bsdf_correlation;      // 0 = PCG reference, 1 = correlated
    uint     _pad_corr;
    // Proportional clamp ceiling on indirect-bounce contributions —
    // both NEE shadow rays at b >= 1 (via nee_clamped) and BSDF-walk
    // arrivals at emissive voxels (via the inline clamp in the no-
    // NEE-competitor branch). Hue-preserving (see clamp_scale below).
    // <= 0 disables. Mirrors MagicaVoxel's `clamp_scale(WL, clamp_L)`
    // in EVAL_LIGHT_DEF / SAMPLE_LIGHT_DEF, gated on the equivalent
    // `bounce > 1` (first-surface NEE is unclamped, every subsequent
    // indirect contribution is clamped).
    float    indirect_clamp_L;
    float    _pad_tail0;
    float    _pad_tail1;
    float    _pad_tail2;
    // Thin-lens DOF. .w slots carry aperture / focus_distance so the
    // struct doesn't need three extra padding rows. aperture == 0
    // (the default) disables DOF entirely in the primary ray block.
    float4   camera_right_grid;    // .xyz = right (grid); .w = aperture
    float4   camera_up_grid;       // .xyz = up    (grid); .w = focus_distance
    float4   camera_forward_grid;  // .xyz = forward (grid); .w unused
};

struct GpuLight {
    float4 pos;  // .xyz = grid-space corner of the exposed face;
                 // .w   = cumulative CDF for power-weighted importance
                 //       sampling (last entry = 1.0).
    float4 le;   // .xyz = albedo_linear * effective_emission;
                 // .w   = per-face sampling probability (= cdf[i]-cdf[i-1]).
    float4 nrm;  // .xyz = outward face normal (axis-aligned ±1 on one axis).
                 // .w   = unused.
};

struct DisplayUniforms {
    uint  sample_count;
    uint  aces_tonemap;
    float region_w;
    float region_h;
    // Temporal-EMA weight applied in `ema_compose_fragment`:
    //   1.0 = no blend (this frame's tonemapped value passes through
    //                   unchanged; behaviour identical to no EMA).
    //   0.0 < w < 1.0  = mix(history, this_frame, w). Smaller w =
    //                    heavier smoothing / slower response to new
    //                    samples. CPU computes per-frame as
    //                    max(1/(sample_count+1), ema_floor) where
    //                    ema_floor ∈ [0, 1] is the user's smoothing knob.
    //   0.0 = freeze (history retained, no update). Useful for
    //         intentionally freezing the displayed image.
    // Mirrors MagicaVoxel's `weight` parameter in pt_post.glsl, where
    // it controls the same mix(tex_last, dst, weight) blend.
    float ema_weight;
};

struct Chunk { uint8_t cells[4096]; };

struct GpuMaterial {
    float type;
    float roughness;
    float metallic;
    float emission;
    float transparency;
    float ior;
    float _pad0;
    float _pad1;
};

constant uint kMatDiffuse  = 0u;
constant uint kMatMetal    = 1u;
constant uint kMatEmissive = 2u;
constant uint kMatGlass    = 3u;

struct VertOut {
    float4 position [[position]];
    float2 ndc;
};

vertex VertOut pt_vertex(uint vid [[vertex_id]]) {
    float2 p;
    if (vid == 0)      p = float2(-1.0, -1.0);
    else if (vid == 1) p = float2( 3.0, -1.0);
    else               p = float2(-1.0,  3.0);
    VertOut o;
    o.position = float4(p, 0.0, 1.0);
    o.ndc = p;
    return o;
}

// PCG32 hash — fast, decent quality for stochastic sampling.
uint pcg(thread uint& s) {
    s = s * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
// Stateless variant used to derive a per-(frame, bounce, site) stride
// for the correlated stream. Same internals as `pcg`, no thread state.
uint pcg_hash(uint x) {
    x = x * 747796405u + 2891336453u;
    uint w = ((x >> ((x >> 28u) + 4u)) ^ x) * 277803737u;
    return (w >> 22u) ^ w;
}
float rand1(thread uint& s) {
    return float(pcg(s)) * (1.0 / 4294967296.0);
}

float2 rand2(thread uint& s) {
    float r1 = rand1(s);
    float r2 = rand1(s);
    return float2(r1, r2);
}

float u_to_unit(uint k) {
    return float(k & 0xFFFFFFu) * (1.0 / float(0x1000000));
}

// Per-(frame, bounce, site) stride for the correlated stream. Distinct
// site ids inside one bounce hash to uncorrelated strides, so adjacent
// NEE call sites don't alias onto the same sample axis. `frame_seed`
// changes every accumulation sample, so successive samples drift the
// chosen direction / light / face across the cluster's solid angle —
// the mechanism that lets variance reduce over time even though every
// pixel's `corr` seed is fixed across samples.
float stride1(uint frame_seed, uint b, uint site) {
    return u_to_unit(pcg_hash((frame_seed * 13u + b) * 17u + site));
}
float2 stride2(uint frame_seed, uint b, uint site) {
    uint k = pcg_hash((frame_seed * 13u + b) * 17u + site);
    return float2(u_to_unit(k), u_to_unit(pcg_hash(k ^ 0x9E3779B9u)));
}

// Correlated samples — MagicaVoxel's `jitter1`/`jitter2` recurrence.
// `corr` is the per-pixel seed initialised once from the noise texture;
// each call advances it, so successive calls inside one path produce
// uncorrelated samples for that pixel while adjacent pixels in a
// noise-texel-sized tile see the same chain (= same BSDF dirs, same
// NEE picks, same RR outcome).
float corr1(thread float& corr, float stride, float mult) {
    corr = fract(corr * 859.0 + 1.0 / 5.93);
    return fract(stride + mult * corr);
}
float2 corr2(thread float& corr, float2 stride, float2 mult) {
    corr = fract(corr * 859.0 + 1.0 / 5.93);
    return fract(stride + mult * corr);
}

// BSDF direction sample. Stride is the per-bounce shared `lobes[b]`
// (uniform across pixels), per-pixel perturbation comes from `corr`.
// At bsdf_correlation == 0 (CLI reference mode) falls back to PCG so
// adjacent pixels sample independently — the textbook MC reference.
float2 dir_sample(constant PathUniforms& u, uint b,
                  thread uint& rng, thread float& corr) {
    if (u.bsdf_correlation != 0u) {
        return corr2(corr, u.lobes[min(b, 7u)].xy, u.jitter_mult);
    }
    return rand2(rng);
}

// Scalar pick — NEE light index, face axis, RIS reservoir coin, RR,
// glass Fresnel coin, metal vs diffuse coin, etc. The `site` index is
// the call-site discriminator; using distinct values per call site
// inside one bounce keeps the strides decorrelated.
float pickrand1(constant PathUniforms& u, uint b, uint site,
                thread uint& rng, thread float& corr) {
    if (u.bsdf_correlation != 0u) {
        return corr1(corr, stride1(u.frame_seed, b, site), u.jitter_mult.x);
    }
    return rand1(rng);
}

// 2D pick — used for in-face NEE point and sun cone. Single call,
// single seed advance — keeps the two dimensions decorrelated via the
// stride hash rather than two sequential corr1 advances.
float2 pickrand2(constant PathUniforms& u, uint b, uint site,
                 thread uint& rng, thread float& corr) {
    if (u.bsdf_correlation != 0u) {
        return corr2(corr, stride2(u.frame_seed, b, site), u.jitter_mult);
    }
    return rand2(rng);
}

// Hue-preserving proportional clamp. v's brightest channel maxes at
// `limit`; other channels scale by the same ratio so the color stays
// the same. Used on indirect-bounce emissive contributions (both NEE
// shadow rays and BSDF-walk emit arrivals) when in splash mode.
// Matches MagicaVoxel's `clamp_scale(v, s)` helper used by its
// EVAL_LIGHT_DEF / SAMPLE_LIGHT_DEF clamp branches.
float3 clamp_scale(float3 v, float limit) {
    float m = max(max(v.x, v.y), v.z);
    return v * (limit / max(m, limit));
}

// Wraps an indirect-contribution accumulation site with the proportional
// clamp:
//   • b == 0 (NEE from the first surface the camera ray hit):
//     unclamped. Carries the smooth-halo direct illumination — this is
//     what your eye reads as a sunlit wall and clamping it would dim
//     it visibly.
//   • b >= 1 (NEE from any subsequent surface interaction, or a BSDF-
//     walk arrival at an emissive in the MIS branch): clamp the
//     contribution proportionally to `indirect_clamp_L`. Caps
//     individual sample spikes that would otherwise read as fireflies,
//     in exchange for slight energy bias.
//
// Matches MagicaVoxel's `bounce > 1` clamp in EVAL_LIGHT_DEF /
// SAMPLE_LIGHT_DEF. MV's `bounce` is incremented inside its material
// functions (so its first surface hit reaches NEE with bounce=1, and
// the clamp condition `bounce > 1` becomes equivalent to our
// `b >= 1` — both fire from the second surface interaction onward).
float3 nee_clamped(constant PathUniforms& u, uint b, float3 contrib) {
    if (b >= 1u && u.indirect_clamp_L > 0.0) {
        return clamp_scale(contrib, u.indirect_clamp_L);
    }
    return contrib;
}

// Cosine-weighted hemisphere sample about a unit normal. Takes the
// uniform-square sample `u` as input so the caller controls whether
// adjacent pixels' samples are correlated (tile-shared `jitter2(lobes[b])`)
// or independent (`rand2(rng)`). Magica's tile-correlated `u` source is
// what makes the "shaped emissive splash" silhouette visible — adjacent
// pixels' bounces interrogate adjacent voxels of the same cluster.
float3 cosine_hemi(float3 n, float2 u) {
    float phi = 6.2831853 * u.x;
    float r = sqrt(u.y);
    float3 local = float3(r * cos(phi), r * sin(phi), sqrt(max(0.0, 1.0 - u.y)));
    float3 helper = abs(n.x) > 0.5 ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 t1 = normalize(cross(n, helper));
    float3 t2 = cross(n, t1);
    return local.x * t1 + local.y * t2 + local.z * n;
}

// GGX visible-normal distribution sampling (Heitz 2018, "Sampling the
// GGX Distribution of Visible Normals"). Returns a microfacet normal in
// world space, sampled with weight proportional to the GGX NDF *and*
// the cosine of the view direction — meaning every sample lies on a
// microfacet that's actually visible to the camera, so reflecting the
// ray about it always yields an above-surface bounce. No need for a
// fallback-to-mirror clamp (which produced a spike of perfect-mirror
// samples piled on top of the diffuse lobe).
//
// `view` is the direction the ray *came from* (i.e. -ray_dir).
// `roughness` is perceptual; alpha = roughness² (Disney/Unreal).
float3 ggx_sample_vndf(float3 n, float3 view, float roughness, float2 u) {
    float a = roughness * roughness;

    // TBN around n.
    float3 helper = abs(n.x) > 0.5 ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 t1 = normalize(cross(n, helper));
    float3 t2 = cross(n, t1);

    // View into tangent space, then stretched to a hemisphere where
    // the NDF is uniform (the trick at the heart of VNDF).
    float3 Ve = float3(dot(view, t1), dot(view, t2), dot(view, n));
    float3 Vh = normalize(float3(a * Ve.x, a * Ve.y, Ve.z));

    // Orthonormal basis on that hemisphere.
    float lensq = Vh.x * Vh.x + Vh.y * Vh.y;
    float3 T1 = lensq > 0.0
        ? float3(-Vh.y, Vh.x, 0.0) * rsqrt(lensq)
        : float3(1.0, 0.0, 0.0);
    float3 T2 = cross(Vh, T1);

    // Sample a disk, warped so the disk's projection covers exactly
    // the visible portion of the hemisphere.
    float r = sqrt(u.x);
    float phi = 6.2831853 * u.y;
    float p1 = r * cos(phi);
    float p2 = r * sin(phi);
    float s = 0.5 * (1.0 + Vh.z);
    p2 = (1.0 - s) * sqrt(1.0 - p1 * p1) + s * p2;

    // Reproject onto hemisphere, then unstretch back to GGX shape.
    float3 Nh = p1 * T1 + p2 * T2 + sqrt(max(0.0, 1.0 - p1*p1 - p2*p2)) * Vh;
    float3 Ne = normalize(float3(a * Nh.x, a * Nh.y, max(0.0, Nh.z)));

    return Ne.x * t1 + Ne.y * t2 + Ne.z * n;
}

constant int kMaxSteps = 4096;
constant uint kChunkBits = 4;
constant uint kChunkMask = 15u;
constant uint kChunkSize = 16u;

// ---------------------------------------------------------------------------
// Nishita single-scatter atmosphere
// ---------------------------------------------------------------------------
// Per-pixel sky integral: for each escaping view ray, march along it
// through the atmosphere, accumulate in-scattering from the sun at each
// step. Two species: Rayleigh (wavelength-dependent, blue-scatters) and
// Mie (broadband, forward-scatters → sun halo). Earth-like constants;
// the scene grid is treated as sitting at sea level so all view rays
// originate at altitude 0.

constant float  kEarthRadius      = 6371000.0;
constant float  kAtmosphereTop    = 6471000.0;        // +100 km
constant float3 kRayleighSigma    = float3(5.802e-6, 13.558e-6, 33.1e-6);
constant float  kMieSigmaScatter  = 3.996e-6;
constant float  kMieSigmaAbsorb   = 4.4e-6;
constant float  kRayleighScaleH   = 8000.0;
constant float  kMieScaleH        = 1200.0;
constant float  kMieG             = 0.76;
constant int    kSkyViewSamples   = 32;
constant int    kSkySunSamples    = 8;

// Distance along `dir` from `p` (atmosphere-frame, Earth at origin) to
// the far intersection with a sphere of `radius`. Returns -1 when the
// ray misses (shouldn't happen for sea-level viewer + outer sphere).
float ray_outer_sphere_t(float3 p, float3 dir, float radius) {
    float b = dot(p, dir);
    float c = dot(p, p) - radius * radius;
    float disc = b * b - c;
    if (disc < 0.0) return -1.0;
    return -b + sqrt(disc);
}

float atmosphere_altitude(float3 p) {
    // Numerically stable form of `length(p) - kEarthRadius`. The
    // naïve subtraction loses ~7 digits to catastrophic cancellation
    // for float32 with our Earth-radius values, occasionally flipping
    // the sign of h on rays that start at the surface — which used to
    // make atmosphere_transmittance return 0 spuriously and blow up
    // sun_radiance_TOA via the safety divide.
    float r2 = dot(p, p);
    float er2 = kEarthRadius * kEarthRadius;
    return (r2 - er2) / (sqrt(r2) + kEarthRadius);
}

// Per-channel transmittance along `omega` from `p` to where the ray
// exits the atmosphere top. Returns 0 when the ray points into the
// Earth (occluded by horizon).
float3 atmosphere_transmittance(float3 p, float3 omega) {
    float t_top = ray_outer_sphere_t(p, omega, kAtmosphereTop);
    if (t_top <= 0.0) return float3(0.0);
    // Reject when the segment genuinely dips below the surface
    // (= hits the ground / horizon). The 1 m tolerance keeps
    // surface-origin rays going to an above-horizon sun safe — those
    // have t_ground of mathematical 0 but float32 might compute
    // anything in [-ε, +ε] due to the catastrophic cancellation in
    // |p|² − r².
    float t_ground = ray_outer_sphere_t(p, omega, kEarthRadius);
    if (t_ground > 1.0 && t_ground < t_top) return float3(0.0);

    float dt = t_top / float(kSkySunSamples);
    float3 od_r = float3(0.0);
    float  od_m = 0.0;
    for (int i = 0; i < kSkySunSamples; ++i) {
        float t = (float(i) + 0.5) * dt;
        // Clamp altitude at 0 — the ray is mathematically always at
        // h ≥ 0 (we already rejected sub-horizon-passing rays via the
        // t_ground check), but the numerically-stable altitude_at can
        // still produce tiny negative values for samples near the
        // surface, which without the clamp would give a non-physical
        // density > 1.
        float h = max(atmosphere_altitude(p + omega * t), 0.0);
        od_r += kRayleighSigma * exp(-h / kRayleighScaleH) * dt;
        od_m += (kMieSigmaScatter + kMieSigmaAbsorb)
              * exp(-h / kMieScaleH) * dt;
    }
    return exp(-od_r - float3(od_m));
}

// Nishita single-scatter sky radiance for view direction `view_dir`
// and sun direction `sun_dir` (both unit-length, atmosphere frame =
// grid frame since grid Z is up). `sun_radiance_in` is the user's
// per-direction sun radiance, treated here as the TOA value: the
// sun-cone integral ∫_cone σ·ρ·phase·L·T dω ≈ σ·ρ·phase·L·T·Ω
// trades the per-direction radiance for an irradiance via the
// solid angle. We do NOT un-attenuate to TOA from a surface-irradiance
// calibration — at low sun elevation, T_surface_to_sun.b → 0 and the
// reciprocal blows up the blue channel, producing an intense blue cast
// (and a worse one as elevation drops). Treating the user's value as
// TOA means the sky dims & reddens naturally at sunset, which is the
// physically right behavior for single-scatter Nishita.
float3 nishita_sky_radiance(float3 view_dir, float3 sun_dir,
                            float3 sun_radiance_in,
                            float sun_cos_half_angle)
{
    float3 origin = float3(0.0, 0.0, kEarthRadius);
    float t_top = ray_outer_sphere_t(origin, view_dir, kAtmosphereTop);
    if (t_top <= 0.0) return float3(0.0);
    float sun_solid_angle = 6.2831853 * (1.0 - sun_cos_half_angle);
    float3 sun_irradiance_TOA = sun_radiance_in * sun_solid_angle;

    float cos_theta = dot(view_dir, sun_dir);
    float cos_theta2 = cos_theta * cos_theta;
    const float kInvPi = 0.31830988618;
    // Rayleigh phase: 3/(16π) · (1 + cos²θ). Integrates to 1 over the
    // sphere — the factor is /16, not /4, which the original landing
    // got wrong and produced a sky 4× too bright.
    float phase_r = (3.0 / 16.0) * kInvPi * (1.0 + cos_theta2);
    float g = kMieG;
    float g2 = g * g;
    float phase_m = (3.0 * 0.125 * kInvPi) * (1.0 - g2)
                  * (1.0 + cos_theta2)
                  / ((2.0 + g2) * pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5));

    float dt = t_top / float(kSkyViewSamples);
    float3 luminance = float3(0.0);
    float3 view_t = float3(1.0);
    for (int i = 0; i < kSkyViewSamples; ++i) {
        float t = (float(i) + 0.5) * dt;
        float3 p = origin + view_dir * t;
        float h = max(atmosphere_altitude(p), 0.0);
        float density_r = exp(-h / kRayleighScaleH);
        float density_m = exp(-h / kMieScaleH);
        float3 t_to_sun = atmosphere_transmittance(p, sun_dir);
        float3 in_scatter = kRayleighSigma * density_r * phase_r
                          + float3(kMieSigmaScatter * density_m * phase_m);
        luminance += view_t * in_scatter * t_to_sun * sun_irradiance_TOA * dt;
        float3 ext = kRayleighSigma * density_r
                   + float3((kMieSigmaScatter + kMieSigmaAbsorb)
                            * density_m);
        view_t *= exp(-ext * dt);
    }
    return luminance;
}

struct DDAHit {
    bool   hit;
    float3 point;     // absolute grid-space coords of the hit
    int    axis;
    int    sign;
    uint   cell_val;
    int3   cell_coord; // integer grid coords of the hit cell (or last visited
                       // before exit, for medium-exit reports)
};

DDAHit dda_traverse(float3 ray_origin,
                    float3 ray_dir,
                    constant PathUniforms& u,
                    device const uint* coarse_grid,
                    device const Chunk* chunk_pool,
                    uint skip_mat)
{
    DDAHit h = {false, float3(0.0), -1, 0, 0u, int3(0)};

    float3 aabb_min = float3(u.coarse_min) * float(kChunkSize);
    float3 aabb_max = float3(u.coarse_min + u.coarse_dim) * float(kChunkSize);
    float3 inv_dir = 1.0 / ray_dir;
    float3 t1 = (aabb_min - ray_origin) * inv_dir;
    float3 t2 = (aabb_max - ray_origin) * inv_dir;
    float3 t_lo = min(t1, t2);
    float3 t_hi = max(t1, t2);
    float t_enter = max(max(t_lo.x, t_lo.y), t_lo.z);
    float t_exit  = min(min(t_hi.x, t_hi.y), t_hi.z);
    if (t_exit < 0.0 || t_enter > t_exit) return h;

    // Track which axis the ray crossed entering the AABB. If the first
    // cell happens to be filled, this becomes the hit's last_axis (so
    // we get a real face normal rather than (0,0,0) → NaN scatter).
    int entry_axis = (t_lo.x >= t_lo.y && t_lo.x >= t_lo.z) ? 0
                   : (t_lo.y >= t_lo.z) ? 1 : 2;

    float t_start = max(t_enter, 0.0);
    float3 origin = ray_origin + ray_dir * (t_start + 1e-3);

    int3 cell = int3(floor(origin));
    int3 step_dir;
    step_dir.x = ray_dir.x > 0.0 ? 1 : (ray_dir.x < 0.0 ? -1 : 0);
    step_dir.y = ray_dir.y > 0.0 ? 1 : (ray_dir.y < 0.0 ? -1 : 0);
    step_dir.z = ray_dir.z > 0.0 ? 1 : (ray_dir.z < 0.0 ? -1 : 0);

    float3 t_max;
    t_max.x = step_dir.x == 0 ? INFINITY :
              (step_dir.x > 0 ? (float(cell.x + 1) - origin.x) / ray_dir.x
                              : (origin.x - float(cell.x))     / -ray_dir.x);
    t_max.y = step_dir.y == 0 ? INFINITY :
              (step_dir.y > 0 ? (float(cell.y + 1) - origin.y) / ray_dir.y
                              : (origin.y - float(cell.y))     / -ray_dir.y);
    t_max.z = step_dir.z == 0 ? INFINITY :
              (step_dir.z > 0 ? (float(cell.z + 1) - origin.z) / ray_dir.z
                              : (origin.z - float(cell.z))     / -ray_dir.z);

    float3 t_delta;
    t_delta.x = step_dir.x != 0 ? 1.0 / abs(ray_dir.x) : INFINITY;
    t_delta.y = step_dir.y != 0 ? 1.0 / abs(ray_dir.y) : INFINITY;
    t_delta.z = step_dir.z != 0 ? 1.0 / abs(ray_dir.z) : INFINITY;

    int last_axis = entry_axis;
    // t_hit is parametric distance from the *clipped* origin, not from
    // ray_origin — the local `origin` is where we are right now, so the
    // initial value is 0. (Setting t_hit = t_start was a leftover from
    // before t_max was made consistently relative to the clipped origin;
    // keeping it nonzero put h.point off by t_start along the ray for
    // first-iteration hits.)
    float t_hit = 0.0;

    // Track whether the most recent non-empty cell we visited was the
    // skip material — needed so we can detect when a ray inside a
    // medium emerges into empty space (or an empty chunk) and report
    // that as a medium-exit hit. Without this the caller can't tell a
    // medium-exit-into-air apart from "missed everything".
    bool was_in_skip = false;

    for (int s = 0; s < kMaxSteps; ++s) {
        int3 chunk_c;
        chunk_c.x = cell.x >> int(kChunkBits);
        chunk_c.y = cell.y >> int(kChunkBits);
        chunk_c.z = cell.z >> int(kChunkBits);
        int3 cgc = chunk_c - u.coarse_min;
        if (cgc.x < 0 || cgc.y < 0 || cgc.z < 0 ||
            cgc.x >= u.coarse_dim.x || cgc.y >= u.coarse_dim.y ||
            cgc.z >= u.coarse_dim.z) {
            // Medium ends at the AABB boundary — same fix as the
            // empty-chunk transition, but for the case where the slab
            // sits at the very edge of the populated grid.
            if (skip_mat != 0u && was_in_skip) {
                h.hit = true;
                h.point = origin + ray_dir * t_hit;
                h.axis = last_axis;
                int step = (last_axis == 0) ? step_dir.x
                         : (last_axis == 1) ? step_dir.y : step_dir.z;
                h.sign = -step;
                h.cell_val = 0u;
                h.cell_coord = cell;
                return h;
            }
            return h;
        }
        uint coarse_idx = uint(cgc.x) +
                          uint(cgc.y) * uint(u.coarse_dim.x) +
                          uint(cgc.z) * uint(u.coarse_dim.x) * uint(u.coarse_dim.y);
        uint pool_idx = coarse_grid[coarse_idx];

        if (pool_idx == 0u) {
            // Stepping into an empty chunk after being inside the
            // medium == ray exits the medium into empty space. Report
            // it before applying the empty-chunk-skip optimization, or
            // the caller would miss the boundary entirely.
            if (skip_mat != 0u && was_in_skip) {
                h.hit = true;
                h.point = origin + ray_dir * t_hit;
                h.axis = last_axis;
                int step = (last_axis == 0) ? step_dir.x
                         : (last_axis == 1) ? step_dir.y : step_dir.z;
                h.sign = -step;
                h.cell_val = 0u;
                h.cell_coord = cell;
                return h;
            }
            // Empty-chunk skip via slab. All t_* values inside this DDA
            // are kept relative to the clipped `origin` so they share a
            // reference frame with the initial t_max setup; computing
            // chunk-exit t against ray_origin and then mixing it into
            // t_max would put h.point off by t_start when the caller
            // reads it.
            float3 chunk_min = float3(chunk_c) * float(kChunkSize);
            float3 chunk_max = chunk_min + float(kChunkSize);
            float3 exit_face = select(chunk_min, chunk_max, step_dir > 0);
            float3 t_face = (exit_face - origin) * inv_dir;
            if (step_dir.x == 0) t_face.x = INFINITY;
            if (step_dir.y == 0) t_face.y = INFINITY;
            if (step_dir.z == 0) t_face.z = INFINITY;
            float t_chunk_exit = min(min(t_face.x, t_face.y), t_face.z);
            int exit_axis = (t_face.x <= t_face.y && t_face.x <= t_face.z) ? 0
                          : (t_face.y <= t_face.z) ? 1 : 2;
            last_axis = exit_axis;
            float eps = max(1e-3, t_chunk_exit * 1e-5);
            float3 pos = origin + ray_dir * (t_chunk_exit + eps);
            cell.x = int(floor(pos.x));
            cell.y = int(floor(pos.y));
            cell.z = int(floor(pos.z));
            if (exit_axis == 0) {
                cell.x = step_dir.x > 0 ? (chunk_c.x + 1) * int(kChunkSize)
                                        : chunk_c.x * int(kChunkSize) - 1;
            } else if (exit_axis == 1) {
                cell.y = step_dir.y > 0 ? (chunk_c.y + 1) * int(kChunkSize)
                                        : chunk_c.y * int(kChunkSize) - 1;
            } else {
                cell.z = step_dir.z > 0 ? (chunk_c.z + 1) * int(kChunkSize)
                                        : chunk_c.z * int(kChunkSize) - 1;
            }
            t_max.x = step_dir.x == 0 ? INFINITY :
                      (step_dir.x > 0
                           ? (float(cell.x + 1) - origin.x) / ray_dir.x
                           : (origin.x - float(cell.x))     / -ray_dir.x);
            t_max.y = step_dir.y == 0 ? INFINITY :
                      (step_dir.y > 0
                           ? (float(cell.y + 1) - origin.y) / ray_dir.y
                           : (origin.y - float(cell.y))     / -ray_dir.y);
            t_max.z = step_dir.z == 0 ? INFINITY :
                      (step_dir.z > 0
                           ? (float(cell.z + 1) - origin.z) / ray_dir.z
                           : (origin.z - float(cell.z))     / -ray_dir.z);
            t_hit = t_chunk_exit;
            continue;
        }

        uint lx = uint(cell.x) & kChunkMask;
        uint ly = uint(cell.y) & kChunkMask;
        uint lz = uint(cell.z) & kChunkMask;
        uint local_idx = lx + ly * kChunkSize + lz * kChunkSize * kChunkSize;
        uint cell_val = uint(chunk_pool[pool_idx - 1u].cells[local_idx]);
        if (cell_val != 0u && cell_val != skip_mat) {
            h.hit = true;
            // t_hit is parametric distance from the *clipped* origin. We
            // compute the hit point against that origin directly so the
            // caller never has to worry about which origin to use.
            h.point = origin + ray_dir * t_hit;
            h.axis = last_axis;
            int step = (last_axis == 0) ? step_dir.x
                     : (last_axis == 1) ? step_dir.y : step_dir.z;
            h.sign = -step;
            h.cell_val = cell_val;
            h.cell_coord = cell;
            return h;
        }
        // Transition skip-mat → empty cell: the ray just exited the
        // medium into open air. Report the boundary so the caller can
        // apply Beer-Lambert and continue the ray in air.
        if (skip_mat != 0u && cell_val == 0u && was_in_skip) {
            h.hit = true;
            h.point = origin + ray_dir * t_hit;
            h.axis = last_axis;
            int step = (last_axis == 0) ? step_dir.x
                     : (last_axis == 1) ? step_dir.y : step_dir.z;
            h.sign = -step;
            h.cell_val = 0u;
            h.cell_coord = cell;
            return h;
        }
        was_in_skip = (cell_val == skip_mat);

        if (t_max.x < t_max.y && t_max.x < t_max.z) {
            cell.x += step_dir.x;
            t_hit = t_max.x;
            t_max.x += t_delta.x;
            last_axis = 0;
        } else if (t_max.y < t_max.z) {
            cell.y += step_dir.y;
            t_hit = t_max.y;
            t_max.y += t_delta.y;
            last_axis = 1;
        } else {
            cell.z += step_dir.z;
            t_hit = t_max.z;
            t_max.z += t_delta.z;
            last_axis = 2;
        }
    }
    return h;
}

// MIS power heuristic (β=2). Returns the weight for the strategy whose
// pdf is `p`, given the other strategy's pdf `q`. Both pdfs must be in
// the same measure (we use solid angle).
float mis_power(float p, float q) {
    if (isinf(p) && !isinf(q)) return 1.0;
    if (isinf(q) && !isinf(p)) return 0.0;
    if (!isfinite(p) || p <= 0.0) return 0.0;
    if (!isfinite(q) || q <= 0.0) return 1.0;
    float r = q / p;
    return 1.0 / (1.0 + r * r);
}

// Lambertian solid-angle pdf at omega given surface normal n.
float pdf_lambert(float3 n, float3 omega) {
    return max(0.0, dot(n, omega)) * 0.31830988618;
}

// GGX VNDF solid-angle pdf for omega_i given outgoing omega_o and
// normal n. Heitz 2018: pdf_omega_i = D(h) · G1(omega_o) / (4·cos_o).
float pdf_ggx_vndf(float3 n, float3 omega_o, float3 omega_i, float roughness) {
    float cos_o = dot(n, omega_o);
    float cos_i = dot(n, omega_i);
    if (cos_o <= 0.0 || cos_i <= 0.0) return 0.0;
    float3 h = normalize(omega_o + omega_i);
    float h_dot_n = max(0.0, dot(h, n));
    float alpha = max(roughness * roughness, 1e-4);
    float a2 = alpha * alpha;
    float denom = h_dot_n * h_dot_n * (a2 - 1.0) + 1.0;
    float D = a2 / (3.14159265 * denom * denom);
    float G1_o = 2.0 * cos_o /
                 (cos_o + sqrt(a2 + (1.0 - a2) * cos_o * cos_o));
    return D * G1_o / max(4.0 * cos_o, 1e-8);
}

// Luminance proxy for the unshadowed direct-lighting integrand in
// solid-angle measure. RIS uses this as the resampling target, and
// nee_pdf_solid_for_arrival evaluates the same expression so both
// sides agree on what "ideal NEE pdf" looks like.
//
// In solid-angle measure, the unshadowed integrand at x toward y is
// proportional to ‖Le‖ · cos_x. The cos_y / dist² Jacobian belongs
// in the source pdf (which already has it — `prob · (1/3) · dist² /
// cos_y` is just the area pdf converted to solid angle), and putting
// it on both sides gives the wrong measure on target — the
// `target / source` ratio then includes spurious `dist⁴ / cos²_y`
// terms that cause distant / grazing lights to firefly.
inline float nee_target_pdf_solid(float3 le, float cos_x)
{
    if (cos_x <= 0.0) return 0.0;
    float Le_lum = dot(le, float3(0.299, 0.587, 0.114));
    return Le_lum * cos_x;
}

// Solid-angle pdf NEE would have assigned to the BSDF-sampled
// direction that arrived at this emissive voxel — used as the "other"
// pdf when MIS-weighting the BSDF-sampled emitter arrival.
//
// Must match nee_sample_light's source pdf so the two MIS weights sum
// to 1. Using the RIS *target* (Le_lum · cos_x) here was wrong: the
// target is a resampling weight, not a pdf in solid-angle units, and
// for bright emitters it dwarfs the BSDF pdf, crushing BSDF-arrival
// contributions to ~0. The visible symptom was an AO-like dark band on
// diffuse surfaces adjacent to emissive voxels — geometry where NEE
// can't sample the visible faces (NdL ≤ 0 from the receiver's
// hemisphere), so only BSDF random walks find the emitter, and those
// then got MIS-zeroed. Now we return the same `prob_li · (1/3) · dist²/
// cos_y` Magica returns — symmetric MIS weights, no missing energy.
float nee_pdf_solid_for_arrival(constant PathUniforms& u,
                                device const GpuLight* lights,
                                int3 hit_cell,
                                float3 hit_point,
                                float3 prev_point,
                                float3 n_x_prev,
                                float3 omega,
                                float3 n_y)
{
    if (u.light_count == 0u) return 0.0;
    float cos_y = dot(n_y, -omega);
    float cos_x = dot(n_x_prev, omega);
    if (cos_x <= 0.0 || cos_y <= 0.0) return 0.0;
    float3 d = hit_point - prev_point;
    float dist2 = dot(d, d);
    if (dist2 < 1e-8) return 0.0;
    // Find the (cell, face_normal) record. We match on the recovered
    // voxel coord (face anchor minus max(n,0)) AND on the normal, so a
    // corner voxel with multiple exposed faces resolves to the right
    // entry — each of its faces has a distinct prob_li.
    for (uint i = 0u; i < u.light_count; ++i) {
        float3 ln = lights[i].nrm.xyz;
        int3 cell_i = int3(lights[i].pos.xyz - max(ln, 0.0));
        if (all(cell_i == hit_cell) && all(ln == n_y)) {
            float prob_li = (u.power_weighted_nee != 0u)
                ? lights[i].le.w
                : (1.0 / float(u.light_count));
            if (prob_li <= 0.0) return 0.0;
            return prob_li * dist2 / cos_y;
        }
    }
    return 0.0;
}

// Result of importance-sampling a single emissive voxel for NEE.
// pdf_solid is in solid-angle measure so it slots directly into MIS.
struct NEELight {
    bool   visible;
    float3 omega_i;      // unit dir from x toward sampled light point
    float3 le;           // emitter linear radiance (premultiplied)
    float  cos_x;        // dot(n_x, omega_i)
    float  cos_y;        // dot(n_y, -omega_i)
    float  dist2;
    float  pdf_solid;    // pdf_area · d² / cos_y
};

// Resampled importance sampling (RIS) for direct-lighting NEE. Per
// call, draw u.nee_ris_count candidates from the source distribution
// (power-weighted CDF or uniform, picked by power_weighted_nee), weight
// each by target_pdf / source_pdf with target = unshadowed integrand
// luminance, and weighted-reservoir-sample one. A single shadow ray
// fires for the chosen sample. Returns NEELight with `pdf_solid` set
// to the EFFECTIVE post-RIS pdf — M · target_chosen / W_sum — which
// makes the existing nee_diffuse_mis / nee_ggx_mis math do the right
// ReSTIR estimator without modification (1/pdf_eff factor naturally
// becomes W_sum / (M · target_chosen), the standard RIS correction).
//
// At M = 1 this collapses to the prior single-candidate behavior:
// w_sum = w_1 = target/source, so M·target/w_sum = source. Identical
// MIS / radiance contribution as before.
NEELight nee_sample_light(float3 x,
                          float3 n_x,
                          uint b,
                          constant PathUniforms& u,
                          device const GpuLight* lights,
                          device const uint* coarse_grid,
                          device const Chunk* chunk_pool,
                          thread uint& rng,
                          thread float& jitter_seed)
{
    NEELight r;
    r.visible = false;
    r.omega_i = float3(0.0);
    r.le = float3(0.0);
    r.cos_x = 0.0;
    r.cos_y = 0.0;
    r.dist2 = 0.0;
    r.pdf_solid = 0.0;
    if (u.light_count == 0u) return r;

    uint M = max(1u, u.nee_ris_count);

    // Reservoir state.
    float w_sum = 0.0;
    bool  have_chosen = false;
    float3 chosen_omega = float3(0.0);
    float3 chosen_le    = float3(0.0);
    float  chosen_cos_x = 0.0;
    float  chosen_cos_y = 0.0;
    float  chosen_dist2 = 0.0;
    int3   chosen_cell  = int3(0);
    float  chosen_target = 0.0;

    for (uint i = 0u; i < M; ++i) {
        // Light selection — same source distribution as the non-RIS
        // path. Power-weighted: CDF binary search; uniform: bare rand.
        // Routed through pickrand1 so splash_mode shares the light
        // pick across tile-neighbour pixels. Note: this is a stylistic
        // extension of MagicaVoxel rather than a direct port — MV's
        // SS-GI-off path doesn't do area-light NEE at all (no OPT_AREA),
        // and MV's SS-GI-on path uses tile-correlated jitter as its
        // *only* random source, so there's no analogous opt-in there.
        // Correlating our area-NEE samples this way damps the
        // per-pixel-PCG fireflies that would otherwise show up in the
        // "splash + area_NEE on" hybrid we run by default.
        uint li;
        float prob_li;
        if (u.power_weighted_nee != 0u) {
            float u_rand = pickrand1(u, b, 2u, rng, jitter_seed);
            uint lo = 0u;
            uint hi = u.light_count;
            while (lo < hi) {
                uint mid = (lo + hi) >> 1u;
                if (lights[mid].pos.w < u_rand) lo = mid + 1u;
                else                            hi = mid;
            }
            li = min(lo, u.light_count - 1u);
            prob_li = lights[li].le.w;
        } else {
            li = uint(pickrand1(u, b, 2u, rng, jitter_seed) * float(u.light_count));
            if (li >= u.light_count) li = u.light_count - 1u;
            prob_li = 1.0 / float(u.light_count);
        }
        if (prob_li <= 0.0) continue;
        GpuLight L = lights[li];

        // Each record already IS a single 1×1 exposed face — no in-cell
        // face-selection step. Sample uniformly within the face plane
        // using two unit tangents derived from the normal via the
        // Magica trick `|n.zxy|·u + |n.yzx|·v`, which produces the two
        // canonical-axis tangents perpendicular to an axis-aligned ±1
        // normal regardless of sign.
        float3 n_y = L.nrm.xyz;
        float2 face_uv = pickrand2(u, b, 4u, rng, jitter_seed);
        float u1 = face_uv.x;
        float u2 = face_uv.y;
        float3 perp1 = abs(float3(n_y.z, n_y.x, n_y.y));
        float3 perp2 = abs(float3(n_y.y, n_y.z, n_y.x));
        float3 y = L.pos.xyz + perp1 * u1 + perp2 * u2;

        float3 d = y - x;
        float dist2 = dot(d, d);
        if (dist2 < 1e-8) continue;
        float dist = sqrt(dist2);
        float3 omega = d / dist;
        float cos_x = dot(n_x, omega);
        float cos_y = dot(n_y, -omega);
        if (cos_x <= 0.0 || cos_y <= 0.0) continue;

        // RIS weight = target / source (both in solid-angle measure).
        // Source pdf = prob_li · dist² / cos_y — face area is 1, so the
        // area→solid-angle Jacobian is the only adjustment. Target is
        // unshadowed integrand luminance. Equal denominators across
        // iterations let us do weighted reservoir sampling with one
        // rand1 per candidate.
        float source_pdf_solid = prob_li * dist2 / cos_y;
        float target = nee_target_pdf_solid(L.le.xyz, cos_x);
        if (source_pdf_solid <= 0.0 || target <= 0.0) continue;
        float w_i = target / source_pdf_solid;

        w_sum += w_i;
        if (pickrand1(u, b, 5u, rng, jitter_seed) * w_sum < w_i) {
            chosen_omega  = omega;
            chosen_le     = L.le.xyz;
            chosen_cos_x  = cos_x;
            chosen_cos_y  = cos_y;
            chosen_dist2  = dist2;
            // Voxel coord behind the face — for +X/+Y/+Z normals the
            // face anchor sits +1 along the normal axis, so subtract
            // max(n, 0) to recover the owning voxel. The DDA shadow-
            // ray hit test below compares against this.
            chosen_cell   = int3(L.pos.xyz - max(L.nrm.xyz, 0.0));
            chosen_target = target;
            have_chosen = true;
        }
    }

    if (!have_chosen || w_sum <= 0.0) return r;

    // Single shadow ray to the chosen candidate.
    DDAHit s = dda_traverse(x + n_x * 1e-3, chosen_omega, u,
                            coarse_grid, chunk_pool, 0u);
    if (!s.hit) return r;
    if (any(s.cell_coord != chosen_cell)) return r;

    r.visible   = true;
    r.omega_i   = chosen_omega;
    r.le        = chosen_le;
    r.cos_x     = chosen_cos_x;
    r.cos_y     = chosen_cos_y;
    r.dist2     = chosen_dist2;
    r.pdf_solid = float(M) * chosen_target / w_sum;
    return r;
}

// Sun NEE: uniform cone sample around `u.sun_dir_grid` of half-angle
// acos(u.sun_cos_half_angle). pdf_solid = 1 / (2π · (1 − cos_half))
// — uniform on the cone. Returns a NEELight-shaped result so the
// existing nee_diffuse_mis / nee_ggx_mis helpers can MIS-weight it
// against the BSDF without duplicating the BRDF math; cos_y / dist2
// are placeholders (unused by the MIS helpers).
//
// No-ops cheaply when the sun is off (intensity = 0 → sun_radiance
// is (0, 0, 0)) or when the cone is degenerate (cos_half >= 1).
// Rejects samples that point through the virtual ground plane from
// above-ground surfaces — keeps the sun from "shining through the
// floor" when the cone dips below the horizon.
NEELight nee_sample_sun(float3 x,
                        float3 n_x,
                        uint b,
                        constant PathUniforms& u,
                        device const uint* coarse_grid,
                        device const Chunk* chunk_pool,
                        thread uint& rng,
                        thread float& jitter_seed)
{
    NEELight r;
    r.visible = false;
    r.omega_i = float3(0.0);
    r.le = float3(0.0);
    r.cos_x = 0.0;
    r.cos_y = 0.0;
    r.dist2 = 0.0;
    r.pdf_solid = 0.0;
    if (u.sun_cos_half_angle >= 1.0) return r;
    if (max(u.sun_radiance.x,
            max(u.sun_radiance.y, u.sun_radiance.z)) <= 0.0) return r;

    // Uniform-on-cone direction sample: pick cos_theta in
    // [cos_half, 1], azimuth uniform around the sun's local Z.
    float2 sun_uv = pickrand2(u, b, 1u, rng, jitter_seed);
    float u1 = sun_uv.x;
    float u2 = sun_uv.y;
    float cos_theta = mix(u.sun_cos_half_angle, 1.0, u1);
    float sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
    float phi = 6.2831853 * u2;

    // TBN around sun_dir.
    float3 sz = u.sun_dir_grid;
    float3 helper = abs(sz.x) > 0.5 ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 sx = normalize(cross(sz, helper));
    float3 sy = cross(sz, sx);
    float3 omega = sin_theta * cos(phi) * sx +
                   sin_theta * sin(phi) * sy +
                   cos_theta * sz;

    float cos_x = dot(omega, n_x);
    if (cos_x <= 0.0) return r;

    // Ground-plane occlusion: the path tracer treats z=0 as a virtual
    // ground (matches the editor's empty-click fallback). Surfaces
    // above the ground can't see sun samples that would punch through
    // the floor.
    if (omega.z < 0.0 && x.z > 0.0) return r;

    // Shadow ray to "infinity." DDA returns hit=true if the ray hits
    // a real cell along the way; hit=false means it escaped the grid
    // (= sun unblocked).
    DDAHit s = dda_traverse(x + n_x * 1e-3, omega, u,
                            coarse_grid, chunk_pool, 0u);
    if (s.hit) return r;

    r.visible   = true;
    r.omega_i   = omega;
    r.le        = u.sun_radiance;
    r.cos_x     = cos_x;
    r.cos_y     = 1.0;   // unused — sun is a directional light
    r.dist2     = 0.0;   // unused
    float sun_solid_angle = 6.2831853 * (1.0 - u.sun_cos_half_angle);
    r.pdf_solid = 1.0 / sun_solid_angle;
    return r;
}

// MIS-weighted NEE for a Lambertian shading point. Caller multiplies by
// throughput. f = albedo / π. Estimator: w · f · Le · cos_x / pdf_solid.
float3 nee_diffuse_mis(NEELight L, float3 albedo, float3 n_x) {
    if (!L.visible) return float3(0.0);
    float pdf_bsdf = pdf_lambert(n_x, L.omega_i);
    float w = mis_power(L.pdf_solid, pdf_bsdf);
    const float kInvPi = 0.31830988618;
    return (albedo * kInvPi) * L.le * L.cos_x * w / L.pdf_solid;
}

// MIS-weighted NEE for a GGX-specular shading point (Cook-Torrance with
// Schlick Fresnel). F0 is the normal-incidence reflectance — albedo for
// metals; ((1-ior)/(1+ior))² for glass-reflect / glass-TIR. The cos_x
// factor in the estimator cancels the 1/cos_i in the BRDF normalisation.
float3 nee_ggx_mis(NEELight L, float3 omega_o, float3 n_x,
                   float3 F0, float roughness)
{
    if (!L.visible) return float3(0.0);
    float cos_o = dot(n_x, omega_o);
    if (cos_o <= 0.0) return float3(0.0);

    float3 h = normalize(L.omega_i + omega_o);
    float h_dot_n = max(0.0, dot(h, n_x));
    float h_dot_o = max(0.0, dot(h, omega_o));

    float alpha = max(roughness * roughness, 1e-4);
    float a2 = alpha * alpha;

    float denom = h_dot_n * h_dot_n * (a2 - 1.0) + 1.0;
    float D = a2 / (3.14159265 * denom * denom);

    float G1_o = 2.0 * cos_o /
                 (cos_o + sqrt(a2 + (1.0 - a2) * cos_o * cos_o));
    float G1_i = 2.0 * L.cos_x /
                 (L.cos_x + sqrt(a2 + (1.0 - a2) * L.cos_x * L.cos_x));
    float G = G1_o * G1_i;

    float fpow = pow(max(0.0, 1.0 - h_dot_o), 5.0);
    float3 F = F0 + (float3(1.0) - F0) * fpow;

    // f · cos_x = D · F · G / (4 cos_o), with the cos_x in the estimator
    // cancelling 1/cos_i from the BRDF normalisation.
    float3 brdf_cos_i = (F * D * G) / max(4.0 * cos_o, 1e-8);
    float pdf_bsdf = D * G1_o / max(4.0 * cos_o, 1e-8);
    float w = mis_power(L.pdf_solid, pdf_bsdf);
    return brdf_cos_i * L.le * w / L.pdf_solid;
}

fragment float4 pt_fragment(
    VertOut in [[stage_in]],
    constant PathUniforms& u [[buffer(0)]],
    device const uint* coarse_grid [[buffer(1)]],
    device const Chunk* chunk_pool [[buffer(2)]],
    constant float4* palette [[buffer(3)]],
    constant GpuMaterial* materials [[buffer(4)]],
    device const GpuLight* lights [[buffer(5)]],
    texture2d<float, access::sample> tex_rand [[texture(0)]])
{
    uint2 pix = uint2(in.position.xy);
    uint rng = (pix.x * 1973u) ^ (pix.y * 9277u) ^ (u.frame_seed * 26699u);
    pcg(rng); pcg(rng);  // mix the seed

    // Per-pixel scalar seed for the correlated stream. Bilinear-filtered
    // noise lookup — adjacent pixels see smoothly-interpolated seeds, so
    // there's no visible grid structure bleeding into the splash pattern
    // while pixels within one screen-area-of-one-noise-texel still share
    // a near-identical sample chain. The 16× scale stretches the 64×64
    // noise texture across ≈1024 screen pixels — wider than the typical
    // emissive cluster on screen, so each tile gets a different "view"
    // into the cluster's solid angle.
    //
    // Per-sample variation comes from `u.frame_seed` being mixed into
    // every stride generator (`stride1/2`), not from a per-sample phase
    // on this seed — so `corr` is constant across samples for a given
    // pixel, and the strides drift the chosen direction / light / face
    // sample-to-sample.
    constexpr sampler tile_sampler(coord::normalized,
                                   filter::linear,
                                   address::repeat);
    float2 noise_uv = (float2(pix) + 0.5f) /
        (16.0f * float(tex_rand.get_width()));
    float jitter_seed = tex_rand.sample(tile_sampler, noise_uv).r;

    // Stochastic anti-aliasing: jitter the NDC point inside the pixel.
    // dfdx/dfdy of NDC give us the pixel's size in NDC space, so the
    // jitter scales correctly regardless of viewport resolution.
    float2 pixel_ndc = float2(abs(dfdx(in.ndc.x)), abs(dfdy(in.ndc.y)));
    float2 jitter = (float2(rand1(rng), rand1(rng)) - 0.5) * pixel_ndc;
    float2 ndc = in.ndc + jitter;

    float4 near_clip = float4(ndc, 0.0, 1.0);
    float4 far_clip  = float4(ndc, 1.0, 1.0);
    float4 nh = u.inv_vp * near_clip;
    float4 fh = u.inv_vp * far_clip;
    float3 nw = nh.xyz / nh.w;
    float3 fw = fh.xyz / fh.w;
    float3 ray_dir_world = normalize(fw - nw);
    float3 ray_origin_world = u.camera_pos;

    // World -> grid (same rotation the raster path uses).
    float3 ray_origin = float3(ray_origin_world.x,
                               -ray_origin_world.z,
                               ray_origin_world.y);
    float3 ray_dir   = float3(ray_dir_world.x,
                               -ray_dir_world.z,
                               ray_dir_world.y);

    // Thin-lens depth of field. aperture == 0 leaves the pinhole ray
    // untouched. Otherwise we sample a uniform point on the lens disc
    // (radius = aperture, in voxel units) in the camera's local
    // right/up plane, then aim through the focal point — the
    // intersection of the original through-pixel ray with the plane at
    // perpendicular distance `focus_distance` along camera-forward.
    // Lens samples ride the decorrelated PCG stream alongside the AA
    // jitter so per-frame variation matches.
    float aperture = u.camera_right_grid.w;
    if (aperture > 0.0) {
        float focus_distance = u.camera_up_grid.w;
        float3 right_g   = u.camera_right_grid.xyz;
        float3 up_g      = u.camera_up_grid.xyz;
        float3 forward_g = u.camera_forward_grid.xyz;
        float xi1 = rand1(rng);
        float xi2 = rand1(rng);
        float theta = 6.2831853 * xi1;
        float rad = aperture * sqrt(xi2);
        float2 lens_uv = float2(cos(theta), sin(theta)) * rad;
        float cos_theta = max(dot(ray_dir, forward_g), 1e-3);
        float3 focus_pt = ray_origin +
                          ray_dir * (focus_distance / cos_theta);
        ray_origin = ray_origin +
                     right_g * lens_uv.x +
                     up_g    * lens_uv.y;
        ray_dir = normalize(focus_pt - ray_origin);
    }

    float3 throughput = float3(1.0);
    float3 radiance   = float3(0.0);

    // MIS state carried forward across bounces.
    //   `prev_bsdf_pdf` is the solid-angle pdf of the BSDF sample that
    //   produced the current ray direction. Combined with the NEE pdf
    //   computed at an emitter arrival, this drives the power-heuristic
    //   MIS weight on the BSDF side.
    //   `prev_is_delta` is true for paths arriving via a delta-like
    //   interaction (refraction, primary camera ray) where NEE can't
    //   compete — those get full BSDF weight at emitter hits.
    float prev_bsdf_pdf = 0.0;
    bool  prev_is_delta = true;
    // Surface normal at the previous bounce, for nee_pdf_solid_for_arrival
    // when the BSDF-sampled ray lands on an emitter. Updated by every
    // non-emissive scatter (overwriting it on delta bounces is harmless
    // — those go through the prev_is_delta short-circuit and skip the
    // pdf evaluation entirely).
    float3 prev_normal = float3(0.0);

    const uint kMinBouncesBeforeRR = 2u;

    // Material the ray is currently "inside" — DDA skips cells with this
    // material so adjacent same-material glass voxels read as one
    // connected medium rather than N stacked surfaces (each of which
    // would otherwise re-multiply throughput by albedo and create a
    // visible seam at every internal boundary).
    uint medium_mat = 0u;
    // Beer-Lambert state for the current medium crossing: where the ray
    // entered, and the per-channel albedo to attenuate by. Tint is then
    // throughput *= albedo^distance, so a perpendicular crossing of a
    // 1-unit slab tints by ~albedo (matching the old behavior) but a
    // grazing crossing of the same slab tints much more heavily — which
    // is exactly the edge-darkening real colored glass shows.
    float3 medium_entry  = float3(0.0);
    float3 medium_albedo = float3(1.0);

    // Virtual ground plane at grid z=0 (matches the editor's
    // ground-plane voxel-placement fallback). Gives undersides somewhere
    // to bounce light from and makes the scene's lighting environment
    // legible without requiring the user to place ground voxels.
    const float3 kGroundAlbedo = float3(0.262, 0.218, 0.178);  // warm grey, linear
    const float3 kGroundNormal = float3(0.0, 0.0, 1.0);

    for (uint b = 0u; b <= u.max_bounces; ++b) {
        DDAHit h = dda_traverse(ray_origin, ray_dir, u,
                                coarse_grid, chunk_pool, medium_mat);
        // Remember whether this DDA was inside a medium. The glass entry
        // branch re-sets medium_mat below if we're entering a new medium;
        // exit refraction (just below) consumes `entered_medium`.
        uint entered_medium = medium_mat;
        medium_mat = 0u;

        // Exit refraction: DDA returned a hit while we were inside a
        // medium, which means the hit is at the medium → air boundary.
        // Refract (or TIR) at that face, then skip processing this hit
        // — the next iteration's DDA will find the real hit in air.
        if (h.hit && entered_medium != 0u) {
            // Beer-Lambert: attenuate throughput by the path length
            // Beer-Lambert through the medium: throughput *= albedo^dist.
            // 1-voxel reference depth matches MagicaVoxel — saturated
            // colored glass darkens to its albedo across a single voxel
            // and edges (longer paths) compound from there. The softer
            // 2-voxel-reference look is what Probabilistic mode is for.
            float dist = length(h.point - medium_entry);
            throughput *= pow(max(medium_albedo, float3(1e-6)),
                              float3(dist));

            GpuMaterial em = materials[entered_medium];
            float3 n = float3(0.0);
            if      (h.axis == 0) n.x = float(h.sign);
            else if (h.axis == 1) n.y = float(h.sign);
            else if (h.axis == 2) n.z = float(h.sign);
            float em_rough = clamp(em.roughness, 0.0, 1.0);
            float3 m = ggx_sample_vndf(n, -ray_dir, em_rough,
                                       dir_sample(u, b, rng, jitter_seed));
            float cos_i = max(0.0, -dot(ray_dir, m));
            float eta = em.ior;  // glass -> air
            float k = 1.0 - eta * eta * (1.0 - cos_i * cos_i);
            // Fresnel at the medium → air interface from the inside.
            // Schlick is symmetric in the index ratio, so the same r0
            // form used at entry applies here. Without this coin-flip
            // the renderer never produces the secondary "ghost"
            // reflection real glass shows: a small fraction of the
            // light entering the front face refracts in, internally
            // reflects on the back face, and exits the front face
            // again — visibly offset from the primary front-face
            // reflection. TIR (k < 0) still forces an internal
            // reflection regardless of the coin flip.
            float r0_in = (em.ior - 1.0) / (em.ior + 1.0);
            r0_in *= r0_in;
            float fresnel_in = r0_in + (1.0 - r0_in) * pow(1.0 - cos_i, 5.0);
            if (k < 0.0 || pickrand1(u, b, 8u, rng, jitter_seed) < fresnel_in) {
                // Total internal reflection or Fresnel-sampled internal
                // bounce — start a new Beer-Lambert segment from here.
                ray_origin = h.point + n * 1e-3;
                ray_dir = ray_dir - 2.0 * dot(ray_dir, m) * m;
                medium_mat = entered_medium;
                medium_entry = h.point;
            } else {
                ray_origin = h.point - n * 1e-3;
                ray_dir = eta * ray_dir + (eta * cos_i - sqrt(k)) * m;
            }
            // Refraction / TIR off the medium-exit boundary is delta-
            // like — NEE can't sample these directions, so the next
            // emitter arrival gets full BSDF weight.
            prev_is_delta = true;
            if (b >= kMinBouncesBeforeRR) {
                float p = max(throughput.r, max(throughput.g, throughput.b));
                p = clamp(p, 0.05, 0.95);
                if (pickrand1(u, b, 6u, rng, jitter_seed) > p) break;
                throughput /= p;
            }
            continue;
        }

        // Ray missed the grid while still inside a medium — the medium
        // would extinguish the ray over an effectively infinite path,
        // so terminate rather than wandering off to sky/ground at full
        // throughput.
        if (!h.hit && entered_medium != 0u) {
            break;
        }

        if (!h.hit) {
            // Try infinite ground before falling back to sky.
            if (ray_dir.z < -1e-6 && ray_origin.z > 0.0) {
                float t_g = -ray_origin.z / ray_dir.z;
                if (t_g > 0.0) {
                    float3 g_point = ray_origin + ray_dir * t_g;
                    if (b == u.max_bounces) {
                        // Out of budget — terminate without contribution
                        // rather than sampling sky; matches the voxel-hit
                        // termination case for consistency.
                        break;
                    }
                    // Aerial perspective at the horizon: a grazing
                    // primary ray traverses a long air column whose
                    // in-scattering looks like the sky in that
                    // direction. Without modelling it, ground-vs-sky
                    // reads as a sharp line near ray_dir.z = 0. Blend
                    // in the limit-direction sky color weighted by
                    // `fade` and attenuate the ground bounce's
                    // throughput by the same amount. The CPU picks
                    // `horizon_softness_k` so fade decays to ~0.05 at
                    // the user's softness angle — 0 disables it.
                    // Primary-ray only — secondary glancing rays don't
                    // read as a horizon to the eye.
                    if (b == 0u && u.horizon_softness_k > 0.0) {
                        float fade = exp(-u.horizon_softness_k *
                                         abs(ray_dir.z));
                        if (fade > 1e-3) {
                            float3 horizon_sky;
                            if (u.atmospheric_sky != 0u) {
                                float3 h_dir = normalize(
                                    float3(ray_dir.x, ray_dir.y, 1e-4));
                                horizon_sky = nishita_sky_radiance(
                                    h_dir, u.sun_dir_grid,
                                    u.sun_radiance,
                                    u.sun_cos_half_angle);
                            } else {
                                horizon_sky = u.sky_color;
                            }
                            radiance += throughput * fade * horizon_sky;
                            throughput *= (1.0 - fade);
                        }
                    }
                    {
                        NEELight nee = nee_sample_light(g_point, kGroundNormal, b, u, lights,
                            coarse_grid, chunk_pool, rng, jitter_seed);
                        radiance += nee_clamped(u, b, throughput *
                            nee_diffuse_mis(nee, kGroundAlbedo, kGroundNormal));
                        NEELight nee_s = nee_sample_sun(g_point, kGroundNormal, b, u, coarse_grid, chunk_pool, rng, jitter_seed);
                        radiance += nee_clamped(u, b, throughput *
                            nee_diffuse_mis(nee_s, kGroundAlbedo, kGroundNormal));
                    }
                    ray_origin = g_point + kGroundNormal * 1e-3;
                    ray_dir = cosine_hemi(kGroundNormal,
                                          dir_sample(u, b, rng, jitter_seed));
                    prev_bsdf_pdf = pdf_lambert(kGroundNormal, ray_dir);
                    prev_is_delta = false;
                    prev_normal = kGroundNormal;
                    throughput *= kGroundAlbedo;
                    continue;
                }
            }
            // Sun disc: the ray escaped to the sky; check whether its
            // direction lies inside the sun cone. sun_radiance is
            // (0,0,0) when intensity is 0, so this is a no-op for the
            // disabled state. MIS against sun-NEE on non-delta paths
            // — same shape as the BSDF-arrives-at-emissive-voxel branch.
            if (u.sun_cos_half_angle < 1.0 &&
                dot(ray_dir, u.sun_dir_grid) >= u.sun_cos_half_angle) {
                if (b == 0u || prev_is_delta) {
                    radiance += throughput * u.sun_radiance;
                } else {
                    float sun_solid_angle =
                        6.2831853 * (1.0 - u.sun_cos_half_angle);
                    float pdf_sun = 1.0 / sun_solid_angle;
                    float w_bsdf = mis_power(prev_bsdf_pdf, pdf_sun);
                    radiance += throughput * u.sun_radiance * w_bsdf;
                }
            }
            // Sky background: Nishita atmospheric scattering when the
            // toggle is on (driven by sun direction + sun radiance),
            // otherwise the constant tinted fill from u.sky_color.
            if (u.atmospheric_sky != 0u) {
                radiance += throughput *
                    nishita_sky_radiance(ray_dir, u.sun_dir_grid,
                                         u.sun_radiance,
                                         u.sun_cos_half_angle);
            } else {
                radiance += throughput * u.sky_color;
            }
            break;
        }
        float3 albedo = palette[h.cell_val].rgb;
        GpuMaterial mat = materials[h.cell_val];
        uint mat_type = uint(mat.type);

        // Emissive cells are light sources. The BSDF arrival has
        // already moved throughput by the BRDF·cos/pdf factor; we just
        // need to multiply by Le and apply the MIS weight on the BSDF
        // side.
        //
        // Three regimes, gated by what NEE we have available:
        //
        //   1. No competing NEE estimator
        //      (b == 0  OR  prev_is_delta  OR  light_count == 0):
        //      contribute Le * throughput with full weight (no MIS to
        //      apply). Clamp at b >= 1 when it's a non-delta BSDF
        //      arrival into the no-area-NEE regime — this is exactly
        //      the path MagicaVoxel takes when SS-GI is off and a
        //      random walk happens to land on an emissive voxel.
        //
        //   2. Competing NEE estimator exists (light_count > 0,
        //      b >= 1, non-delta):
        //      MIS-weight against the solid-angle pdf NEE would have
        //      assigned to this direction, then clamp via nee_clamped.
        //      Matches MagicaVoxel's MIS-weighted EVAL_LIGHT_DEF
        //      branch when OPT_AREA is on.
        if (mat_type == kMatEmissive && mat.emission > 0.0) {
            float3 Le = albedo * mat.emission;
            bool no_nee_competitor = (b == 0u) || prev_is_delta
                                  || (u.light_count == 0u);
            if (no_nee_competitor) {
                float3 contrib = throughput * Le;
                // Clamp only when there's actually a firefly to suppress:
                // skip b == 0 (camera-direct view of emitter — must read
                // unclamped to look correct) and post-refraction delta
                // arrivals (NEE can't sample those either way; let them
                // pass through).
                bool should_clamp = (b >= 1u) && !prev_is_delta
                                 && (u.indirect_clamp_L > 0.0);
                if (should_clamp) {
                    contrib = clamp_scale(contrib, u.indirect_clamp_L);
                }
                radiance += contrib;
            } else {
                float3 n_y = float3(0.0);
                if      (h.axis == 0) n_y.x = float(h.sign);
                else if (h.axis == 1) n_y.y = float(h.sign);
                else if (h.axis == 2) n_y.z = float(h.sign);
                float pdf_light = nee_pdf_solid_for_arrival(
                    u, lights, h.cell_coord, h.point, ray_origin,
                    prev_normal, ray_dir, n_y);
                float w_bsdf = mis_power(prev_bsdf_pdf, pdf_light);
                radiance += nee_clamped(u, b, throughput * Le * w_bsdf);
            }
            break;
        }

        if (b == u.max_bounces) {
            break;  // out of bounce budget
        }

        // Surface normal in grid space.
        float3 normal = float3(0.0);
        if      (h.axis == 0) normal.x = float(h.sign);
        else if (h.axis == 1) normal.y = float(h.sign);
        else if (h.axis == 2) normal.z = float(h.sign);

        if (mat_type == kMatMetal) {
            // Metallic: probability the ray takes the specular path vs.
            // a plain diffuse bounce. 1.0 = pure reflective metal, 0.0 =
            // effectively diffuse, intermediate = semi-glossy. The
            // specular path samples GGX VNDF (Heitz 2018); diffuse uses
            // cosine hemisphere. Each branch gets MIS-weighted NEE
            // against its own BSDF — power heuristic auto-selects
            // whichever is locally lower-variance.
            ray_origin = h.point + normal * 1e-3;
            float3 omega_o = -ray_dir;
            if (pickrand1(u, b, 9u, rng, jitter_seed) < clamp(mat.metallic, 0.0, 1.0)) {
                float r = clamp(mat.roughness, 0.0, 1.0);
                {
                    NEELight nee = nee_sample_light(h.point, normal, b, u, lights,
                        coarse_grid, chunk_pool, rng, jitter_seed);
                    radiance += nee_clamped(u, b, throughput *
                        nee_ggx_mis(nee, omega_o, normal, albedo, r));
                    NEELight nee_s = nee_sample_sun(h.point, normal, b, u, coarse_grid, chunk_pool, rng, jitter_seed);
                    radiance += nee_clamped(u, b, throughput *
                        nee_ggx_mis(nee_s, omega_o, normal, albedo, r));
                }
                float3 m = ggx_sample_vndf(normal, omega_o, r,
                                           dir_sample(u, b, rng, jitter_seed));
                ray_dir = ray_dir - 2.0 * dot(ray_dir, m) * m;
                prev_bsdf_pdf = pdf_ggx_vndf(normal, omega_o, ray_dir, r);
                prev_is_delta = (prev_bsdf_pdf <= 0.0);
            } else {
                {
                    NEELight nee = nee_sample_light(h.point, normal, b, u, lights,
                        coarse_grid, chunk_pool, rng, jitter_seed);
                    radiance += nee_clamped(u, b, throughput *
                        nee_diffuse_mis(nee, albedo, normal));
                    NEELight nee_s = nee_sample_sun(h.point, normal, b, u, coarse_grid, chunk_pool, rng, jitter_seed);
                    radiance += nee_clamped(u, b, throughput *
                        nee_diffuse_mis(nee_s, albedo, normal));
                }
                ray_dir = cosine_hemi(normal,
                                      dir_sample(u, b, rng, jitter_seed));
                prev_bsdf_pdf = pdf_lambert(normal, ray_dir);
                prev_is_delta = false;
            }
            throughput *= albedo;
        } else if (mat_type == kMatGlass) {
            // Microfacet glass: sample a visible microfacet normal `m`
            // from GGX VNDF (Heitz 2018), then do Fresnel + Snell
            // against `m` rather than the geometric surface normal.
            // At roughness 0 this collapses to perfect mirror / Snell;
            // higher roughness gives a clean frosted-glass lobe.
            //
            // Beer-Lambert tint is applied on exit from the medium, not
            // at the surface — so Fresnel reflections off colored glass
            // are spectrally neutral (correct for a dielectric), and
            // transmitted-ray tint scales with actual path length.
            //
            // Transparency interpretation depends on RenderSettings'
            // glass_mode (set per-frame as u.glass_mode):
            //  - Probabilistic (0): with prob=transparency, refract with
            //    medium_albedo = albedo. Else diffuse-fallback bounce.
            //    transparency=1 still tints; transparency=0.5 reads milky.
            //  - Absorption (1): always refract on transmit; medium_albedo
            //    interpolates albedo (transparency=0) toward white
            //    (transparency=1). transparency=1 is fully clear.
            float rough = clamp(mat.roughness, 0.0, 1.0);
            float3 omega_o = -ray_dir;
            float3 m = ggx_sample_vndf(normal, omega_o, rough,
                                       dir_sample(u, b, rng, jitter_seed));
            float cos_i = max(0.0, -dot(ray_dir, m));
            float r0 = (1.0 - mat.ior) / (1.0 + mat.ior);
            r0 *= r0;
            float fresnel = r0 + (1.0 - r0) * pow(1.0 - cos_i, 5.0);
            float trans = clamp(mat.transparency, 0.0, 1.0);
            float3 f0_glass = float3(r0);
            if (pickrand1(u, b, 7u, rng, jitter_seed) < fresnel) {
                // Fresnel reflect lobe — MIS-weighted NEE against the
                // GGX VNDF sampler. At low roughness the BSDF wins and
                // captures crisp mirror-of-light contributions; at high
                // roughness NEE wins and direct-samples emitters.
                {
                    NEELight nee = nee_sample_light(h.point, normal, b, u, lights,
                        coarse_grid, chunk_pool, rng, jitter_seed);
                    radiance += nee_clamped(u, b, throughput *
                        nee_ggx_mis(nee, omega_o, normal, f0_glass, rough));
                    NEELight nee_s = nee_sample_sun(h.point, normal, b, u, coarse_grid, chunk_pool, rng, jitter_seed);
                    radiance += nee_clamped(u, b, throughput *
                        nee_ggx_mis(nee_s, omega_o, normal, f0_glass, rough));
                }
                ray_origin = h.point + normal * 1e-3;
                ray_dir = ray_dir - 2.0 * dot(ray_dir, m) * m;
                prev_bsdf_pdf = pdf_ggx_vndf(normal, omega_o, ray_dir, rough);
                prev_is_delta = (prev_bsdf_pdf <= 0.0);
            } else {
                // Decide whether the transmit branch refracts (always in
                // Absorption mode; with probability = transparency in
                // Probabilistic mode) or falls back to diffuse.
                bool refract_path = (u.glass_mode == 1u) ||
                                    (pickrand1(u, b, 10u, rng, jitter_seed) < trans);
                if (refract_path) {
                    float eta = 1.0 / mat.ior;  // air -> glass
                    float k = 1.0 - eta * eta * (1.0 - cos_i * cos_i);
                    if (k < 0.0) {
                        // TIR — same reflect geometry as the Fresnel
                        // reflect branch; same MIS-weighted NEE.
                        {
                            NEELight nee = nee_sample_light(h.point, normal, b, u, lights,
                                coarse_grid, chunk_pool, rng, jitter_seed);
                            radiance += nee_clamped(u, b, throughput *
                                nee_ggx_mis(nee, omega_o, normal,
                                            f0_glass, rough));
                            NEELight nee_s = nee_sample_sun(h.point, normal, b, u, coarse_grid, chunk_pool, rng, jitter_seed);
                            radiance += nee_clamped(u, b, throughput *
                                nee_ggx_mis(nee_s, omega_o, normal,
                                            f0_glass, rough));
                        }
                        ray_origin = h.point + normal * 1e-3;
                        ray_dir = ray_dir - 2.0 * dot(ray_dir, m) * m;
                        prev_bsdf_pdf = pdf_ggx_vndf(normal, omega_o,
                                                     ray_dir, rough);
                        prev_is_delta = (prev_bsdf_pdf <= 0.0);
                    } else {
                        // Refraction into the medium — delta-like; no
                        // NEE. The next emitter arrival (after exit)
                        // gets full BSDF weight via prev_is_delta.
                        ray_origin = h.point - normal * 1e-3;
                        ray_dir = eta * ray_dir + (eta * cos_i - sqrt(k)) * m;
                        medium_mat = h.cell_val;
                        medium_entry = h.point;
                        // Absorption mode: medium albedo interpolates
                        // from the surface color (transparency=0) toward
                        // pure white (transparency=1). At trans=1 the
                        // medium absorbs nothing and thick glass reads
                        // as clear, matching MagicaVoxel's interpretation.
                        medium_albedo = (u.glass_mode == 1u)
                            ? mix(albedo, float3(1.0), trans)
                            : albedo;
                        prev_is_delta = true;
                    }
                } else {
                    // Diffuse fallback — Probabilistic mode only.
                    {
                        NEELight nee = nee_sample_light(h.point, normal, b, u, lights,
                            coarse_grid, chunk_pool, rng, jitter_seed);
                        radiance += throughput *
                            nee_diffuse_mis(nee, albedo, normal);
                        NEELight nee_s = nee_sample_sun(h.point, normal, b, u, coarse_grid, chunk_pool, rng, jitter_seed);
                        radiance += throughput *
                            nee_diffuse_mis(nee_s, albedo, normal);
                    }
                    ray_origin = h.point + normal * 1e-3;
                    ray_dir = cosine_hemi(normal,
                                          dir_sample(u, b, rng, jitter_seed));
                    prev_bsdf_pdf = pdf_lambert(normal, ray_dir);
                    prev_is_delta = false;
                    throughput *= albedo;
                }
            }
        } else {
            // Diffuse default.
            {
                NEELight nee = nee_sample_light(h.point, normal, b, u, lights,
                                                coarse_grid, chunk_pool,
                                                rng, jitter_seed);
                radiance += nee_clamped(u, b, throughput *
                                        nee_diffuse_mis(nee, albedo, normal));
                NEELight nee_s = nee_sample_sun(h.point, normal, b, u, coarse_grid, chunk_pool,
                                                rng, jitter_seed);
                radiance += nee_clamped(u, b, throughput *
                                        nee_diffuse_mis(nee_s, albedo, normal));
            }
            ray_origin = h.point + normal * 1e-3;
            ray_dir = cosine_hemi(normal,
                                  dir_sample(u, b, rng, jitter_seed));
            prev_bsdf_pdf = pdf_lambert(normal, ray_dir);
            prev_is_delta = false;
            throughput *= albedo;
        }

        // Carry this surface's normal forward so the next iteration's
        // emitter-arrival MIS branch can evaluate target_pdf at the
        // right `x`. Set unconditionally — delta branches go through
        // the prev_is_delta short-circuit and never read it.
        prev_normal = normal;

        // Russian roulette after a couple of guaranteed bounces. Kill
        // paths with probability (1 - p) where p is the maximum component
        // of throughput; survivors get their throughput boosted by 1/p
        // so the estimator stays unbiased. Lets bounce_max go higher
        // without the cost growing linearly. Routed through pickrand1 so
        // adjacent pixels in a tile terminate together (correlated mode);
        // reference mode uses raw PCG per pixel.
        if (b >= kMinBouncesBeforeRR) {
            float p = max(throughput.r, max(throughput.g, throughput.b));
            p = clamp(p, 0.05, 0.95);
            if (pickrand1(u, b, 6u, rng, jitter_seed) > p) break;
            throughput /= p;
        }
    }
    return float4(radiance, 1.0);
}

// Temporal-EMA compose pass — Magica's `pt_post.glsl mix(tex_last, dst,
// weight)` pattern. Runs at accumulator resolution (NOT drawable
// resolution) and writes the tonemapped current frame value into the
// history texture using hardware alpha-blending for the EMA mix:
//
//   pipeline.blendEnabled = YES
//   sourceFactor      = MTLBlendFactorBlendAlpha       (= blend_color.a)
//   destinationFactor = MTLBlendFactorOneMinusBlendAlpha (= 1 - blend_color.a)
//
// CPU sets blend_color.a = ema_weight via setBlendColor:, so the
// hardware ROP evaluates
//   dst' = mix(dst, src, ema_weight)
//        = dst * (1 - ema_weight) + src * ema_weight
// where `src` is THIS fragment's output (tonemapped current value)
// and `dst` is the existing texture content (last frame's blended
// output). Using hardware blending instead of in-shader sampling of
// a "previous history" texture: (1) avoids ping-pong texture state and
// the read-write hazard, (2) makes the EMA chain literally identical
// across every pixel since there's no risk of confusing which texture
// is which, and (3) makes the implementation impossible to get wrong
// at the wiring layer — if EMA isn't visible, the cause is somewhere
// other than this fragment.
//
// CPU also drives loadAction: Clear on the first frame after a reset
// (so the dst is zero and weight=1 gives dst' = current), Load on
// every subsequent frame (so we blend into the persisted previous
// content).
fragment float4 ema_compose_fragment(
    VertOut in [[stage_in]],
    constant DisplayUniforms& u [[buffer(0)]],
    texture2d<float, access::sample> accum [[texture(0)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    // ndc.xy ∈ [-1, 1] maps 1:1 to the accumulator texture since this
    // pass renders to the history texture at accum resolution.
    float2 uv = in.ndc * 0.5 + 0.5;
    uv.y = 1.0 - uv.y;

    float n = max(1.0, float(u.sample_count));
    float3 c = max(accum.sample(s, uv).rgb / n, 0.0);

    if (u.aces_tonemap != 0u) {
        const float a = 2.51, b = 0.03, c1 = 2.43, d = 0.59, e = 0.14;
        c = saturate((c * (a * c + b)) / (c * (c1 * c + d) + e));
        c = select(12.92 * c,
                   1.055 * pow(c, 1.0 / 2.4) - 0.055,
                   c > 0.0031308);
    } else {
        c = pow(c, 1.0 / 2.2);
    }

    // Output the tonemapped current value. Hardware blend factors at
    // pass write time do the EMA mix with whatever's in the render
    // target (the previous frame's blended output). Alpha = 1 lets us
    // use BlendAlpha as the blend factor name.
    return float4(c, 1.0);
}

// Display pass — samples the EMA-composed history texture and writes
// to the drawable with letterbox/region clipping. The actual tonemap
// + EMA blend has already happened in ema_compose_fragment; this pass
// is now just a resolution-mapping copy.
fragment float4 display_fragment(
    VertOut in [[stage_in]],
    constant DisplayUniforms& u [[buffer(0)]],
    texture2d<float, access::sample> composed [[texture(0)]])
{
    // Linear so the display pass blends sensibly when the accumulator
    // is rendered at a different resolution than the drawable
    // (½× iteration mode upscales, 2× supersamples down).
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    // Map drawable NDC [-1, 1] to a centered region of size
    // (region_w, region_h) — pixels outside it are letterbox / pillarbox
    // bars. Inside, scale to [0, 1] for the composed sample.
    float2 ndc = in.ndc;
    if (abs(ndc.x) > u.region_w || abs(ndc.y) > u.region_h) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    float2 uv = float2(ndc.x / u.region_w, ndc.y / u.region_h) * 0.5 + 0.5;
    uv.y = 1.0 - uv.y;
    float3 c = composed.sample(s, uv).rgb;
    return float4(c, 1.0);
}

// Display fragment used by the headless export path — composes from the
// accumulator directly (no EMA history), so single-shot exports are
// deterministic and don't need ping-pong texture state.
fragment float4 display_fragment_direct(
    VertOut in [[stage_in]],
    constant DisplayUniforms& u [[buffer(0)]],
    texture2d<float, access::sample> accum [[texture(0)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 ndc = in.ndc;
    if (abs(ndc.x) > u.region_w || abs(ndc.y) > u.region_h) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    float2 uv = float2(ndc.x / u.region_w, ndc.y / u.region_h) * 0.5 + 0.5;
    uv.y = 1.0 - uv.y;
    float4 v = accum.sample(s, uv);
    float n = max(1.0, float(u.sample_count));
    float3 c = max(v.rgb / n, 0.0);

    if (u.aces_tonemap != 0u) {
        const float a = 2.51, b = 0.03, c1 = 2.43, d = 0.59, e = 0.14;
        c = saturate((c * (a * c + b)) / (c * (c1 * c + d) + e));
        c = select(12.92 * c,
                   1.055 * pow(c, 1.0 / 2.4) - 0.055,
                   c > 0.0031308);
    } else {
        // Gamma-2.2 fallback for before/after comparison.
        c = pow(c, 1.0 / 2.2);
    }
    return float4(c, 1.0);
}
