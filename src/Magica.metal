// Port of MagicaVoxel's path-tracer fragment shader, adapted to MSL.
// Scope cut to v1: PRIM_CUBE, perspective camera, diffuse + metal +
// emissive + glass materials, sun + procedural sky, optional area-
// light NEE (OPT_AREA = "Stochastic Sampling GI" toggle), MIS.
//
// Out of scope (vs the ubershader): DOF, bokeh, spin, panoramic /
// orthographic projection, atmospheric scattering (Nishita), grid
// overlay, alpha background modes, pixelation, non-uniform world
// scale, volumetric "march" mode, sphere/cylinder/clay/MC primitives,
// IBL.
//
// Coordinate convention: this shader operates entirely in grid space.
// Voxel index (gx, gy, gz) → texture lookup
// (gx - grid_min.x + 0.5) / grid_dim.x, etc.
// Grid-to-world translation lives in the camera matrices.

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Bindings
// ---------------------------------------------------------------------------

struct MagicaUniforms {
    float4x4 inv_vp;
    float3   camera_pos;
    float    _pad0;
    int3     grid_min;
    int      _pad1;
    int3     grid_dim;
    int      _pad2;
    float3   sun_dir;
    float    sun_cos_half_angle;
    float3   sun_radiance;
    float    sky_intensity;
    float3   sky_color;
    float    _pad3;

    uint     frame_seed;
    uint     max_bounces;
    uint     light_count;
    uint     stochastic_gi;

    uint     glass_mode;
    uint     aces_tonemap;
    float    indirect_clamp_L;  // proportional clamp on bounce>0 emitter contribs
    uint     _pad5;

    // Per-frame correlated-noise state (Magica's `lobes[bounce]` +
    // `jitter_mult` + `tex_rand_inv_size`).
    float2   inv_screen_size;
    float2   jitter_mult;
    float4   lobes[8];           // .xy used per bounce; .zw reserved
};

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

struct GpuLight {
    float4 pos;
    float4 le;
};

struct DisplayUniforms {
    uint  sample_count;
    uint  aces_tonemap;
    float region_w;
    float region_h;
};

constant uint MT_DIFFUSE  = 0u;
constant uint MT_METAL    = 1u;
constant uint MT_EMISSIVE = 2u;
constant uint MT_GLASS    = 3u;

// ---------------------------------------------------------------------------
// Vertex: full-screen triangle.
// ---------------------------------------------------------------------------

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut magica_vertex(uint vid [[vertex_id]]) {
    // Standard 3-vertex full-screen triangle covering [-1,1]^2.
    float2 p = float2((vid == 2u) ? 3.0 : -1.0,
                      (vid == 1u) ? -3.0 : 1.0);
    VOut o;
    o.position = float4(p, 0.0, 1.0);
    o.uv = float2(p.x * 0.5 + 0.5, 1.0 - (p.y * 0.5 + 0.5));
    return o;
}

// ---------------------------------------------------------------------------
// RNG. Two parallel streams:
//
//   pcg  — Per-pixel decorrelated PCG. Used for NEE shadow-ray /
//          light-picking / Russian-roulette decisions where we want
//          true variance reduction.
//   corr — TILE-correlated state used only for BSDF direction
//          sampling. This is Magica's "splash mode" trick: every pixel
//          inside a NOISE_TILE_PX tile starts with the same `corr`
//          seed, so all of them sample the same bounce direction. A
//          tile that lands on an emissive voxel lights up as one
//          coherent block carrying that voxel's color, which is the
//          mechanism that produces the splash look in Magica's
//          "Stochastic Sampling GI = OFF" mode.
//
// Per-bounce sampling combines:
//   * a per-frame-uniform stride that varies between samples and
//     bounces (Cranley-Patterson stride);
//   * a small per-pixel rotation taken from `corr`, multiplied by
//     two irrationals so x/y axes decorrelate.
//
// Both streams are advanced independently so NEE noise stays clean
// even as BSDF directions are correlated.
// ---------------------------------------------------------------------------

struct RngState {
    uint  pcg;
    float corr;
};

static uint pcg_hash(uint x) {
    x = x * 747796405u + 2891336453u;
    uint w = ((x >> ((x >> 28) + 4u)) ^ x) * 277803737u;
    return (w >> 22) ^ w;
}

static float u_to_unit(uint k) {
    return float(k & 0xFFFFFFu) / float(0x1000000);
}

static RngState rng_init(float2 frag, uint frame_seed,
                         texture2d<float> noise,
                         float2 inv_screen_size) {
    RngState s;
    uint a = uint(frag.x);
    uint b = uint(frag.y);
    s.pcg = pcg_hash(a + pcg_hash(b * 65537u) + frame_seed * 2654435761u);

    // Per-pixel seed sampled from a small noise texture stretched
    // across the viewport. The annotated source claims NEAREST, but
    // that produces hard 1-texel-wide tile boundaries (≈15 px at
    // 960×800) that take many samples to wash out. LINEAR blends seeds
    // smoothly across the screen, so adjacent pixels see slightly
    // different seeds and the tile lattice disappears while the
    // local-correlation property that drives the splash effect is
    // preserved (pixels within a screen-area-of-one-texel still see
    // very similar bounce directions). The texture is refreshed per
    // frame CPU-side so successive samples take different "views" of
    // the cluster's solid angle.
    constexpr sampler ns(coord::normalized, filter::linear, address::repeat);
    s.corr = noise.sample(ns, frag * inv_screen_size).x;
    return s;
}

static float rand1(thread RngState& r) {
    r.pcg = pcg_hash(r.pcg);
    return u_to_unit(r.pcg);
}

static float2 rand2(thread RngState& r) {
    float x = rand1(r); float y = rand1(r); return float2(x, y);
}

// Per-call correlated sample matching Magica's `jitter1`/`jitter2`.
// `stride` is the per-frame uniform value the caller passes (Magica's
// `lobes[bounce]` / `sun_r` / `area_r` / etc.) and `jitter_mult` is
// the per-frame irrational rotator. Every consumer at the same pixel
// shares the evolving `corr` state, so tile-correlation propagates
// through the whole bounce loop — BSDF directions, NEE light picks,
// shadow-ray sample points, Russian roulette decisions all stay
// aligned for neighbour pixels in a tile.
static float corr1(thread RngState& r, float stride, float mult) {
    r.corr = fract(r.corr * 859.0 + 1.0 / 5.93);
    return fract(stride + mult * r.corr);
}
static float2 corr2(thread RngState& r,
                    float2 stride,
                    float2 jitter_mult) {
    r.corr = fract(r.corr * 859.0 + 1.0 / 5.93);
    return fract(stride + jitter_mult * r.corr);
}

// Helper for inline per-(frame, bounce, site) stride generation —
// avoids needing a uniform-array slot per call site. PCG-hashed so
// distinct (bounce, site) pairs produce uncorrelated strides.
static float2 stride2(uint frame_seed, uint bounce, uint site) {
    uint k = pcg_hash((frame_seed * 13u + bounce) * 17u + site);
    return float2(u_to_unit(k), u_to_unit(pcg_hash(k ^ 0x9E3779B9u)));
}
static float stride1(uint frame_seed, uint bounce, uint site) {
    uint k = pcg_hash((frame_seed * 13u + bounce) * 17u + site);
    return u_to_unit(k);
}

// Color-preserving (hue-preserving) proportional clamp. Standard
// per-channel clamp would shift hue; this scales all channels by the
// same factor needed to bring max(channels, s) down to `s`, which
// caps brightness without altering the color. Magica's
// `clamp_scale()`.
static float3 clamp_scale(float3 v, float s) {
    float m = max(max(v.x, v.y), max(v.z, s));
    return v * (s / m);
}

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

static float3 build_tangent(float3 n) {
    float3 a = (abs(n.x) > 0.5) ? float3(0, 1, 0) : float3(1, 0, 0);
    return normalize(cross(a, n));
}

static float3 cosine_sample_hemisphere(float3 n, float2 r) {
    // Malley's method.
    float phi = 2.0 * M_PI_F * r.x;
    float cos_t = sqrt(1.0 - r.y);
    float sin_t = sqrt(r.y);
    float3 t = build_tangent(n);
    float3 b = cross(n, t);
    return normalize(sin_t * cos(phi) * t + sin_t * sin(phi) * b + cos_t * n);
}

// VNDF GGX sampler (Heitz 2018). Returns a half-vector (sampled visible
// normal) in tangent space.
static float3 ggx_sample_vndf(float3 V_ts, float a, float2 r) {
    // Section 3.2: stretch view direction.
    float3 Vh = normalize(float3(a * V_ts.x, a * V_ts.y, V_ts.z));
    float lensq = Vh.x * Vh.x + Vh.y * Vh.y;
    float3 T1 = (lensq > 0.0) ? float3(-Vh.y, Vh.x, 0.0) * rsqrt(lensq)
                              : float3(1.0, 0.0, 0.0);
    float3 T2 = cross(Vh, T1);
    // Section 4.2: parameterization of the projected area.
    float r1 = sqrt(r.x);
    float phi = 2.0 * M_PI_F * r.y;
    float t1 = r1 * cos(phi);
    float t2 = r1 * sin(phi);
    float s = 0.5 * (1.0 + Vh.z);
    t2 = (1.0 - s) * sqrt(1.0 - t1 * t1) + s * t2;
    float3 Nh = t1 * T1 + t2 * T2 + sqrt(max(0.0, 1.0 - t1 * t1 - t2 * t2)) * Vh;
    // Unstretch.
    return normalize(float3(a * Nh.x, a * Nh.y, max(1e-6, Nh.z)));
}

static float3 to_world(float3 v_ts, float3 N) {
    float3 T = build_tangent(N);
    float3 B = cross(N, T);
    return normalize(v_ts.x * T + v_ts.y * B + v_ts.z * N);
}

static float3 to_local(float3 v_ws, float3 N) {
    float3 T = build_tangent(N);
    float3 B = cross(N, T);
    return float3(dot(v_ws, T), dot(v_ws, B), dot(v_ws, N));
}

static float fresnel_schlick(float cos_t, float F0) {
    float m = 1.0 - cos_t;
    return F0 + (1.0 - F0) * m * m * m * m * m;
}

static float3 fresnel_schlick3(float cos_t, float3 F0) {
    float m = 1.0 - cos_t;
    return F0 + (1.0 - F0) * m * m * m * m * m;
}

// ---------------------------------------------------------------------------
// Sky model: simple two-tone gradient + a sun disc.
// ---------------------------------------------------------------------------

static float3 sample_sky(constant MagicaUniforms& u, float3 dir) {
    // Constant tinted fill (sky_color already includes sky_intensity).
    // Matches PathTraceRenderer's miss path so A/B comparisons reflect
    // bouncing-algorithm differences, not sky-constant differences.
    // Magica's IBL / gradient sky is a v2 task.
    float3 sky = u.sky_color;
    if (u.sun_radiance.x + u.sun_radiance.y + u.sun_radiance.z > 0.0) {
        float c = dot(dir, u.sun_dir);
        if (c > u.sun_cos_half_angle) sky += u.sun_radiance;
    }
    return sky;
}

// ---------------------------------------------------------------------------
// DDA traversal with baked skip distances.
// ---------------------------------------------------------------------------

struct Hit {
    bool   hit;
    float  t;        // parametric distance along (o, d) from clipped origin
    int3   cell;
    int    axis;     // 0/1/2 = which axis was the entry face
    float  side;     // +1 or -1 depending on direction along axis
    uint   id;       // palette ID at the hit cell
};

static float2 ray_aabb_clip(float3 o, float3 d, float3 lo, float3 hi) {
    float3 inv = 1.0 / d;
    float3 t1 = (lo - o) * inv;
    float3 t2 = (hi - o) * inv;
    float3 tmin = min(t1, t2);
    float3 tmax = max(t1, t2);
    float tin  = max(max(tmin.x, tmin.y), tmin.z);
    float tout = min(min(tmax.x, tmax.y), tmax.z);
    return float2(tin, tout);
}

// Trace from o (grid-space) along d (unit, grid-space). Returns the
// first cell with id != 0 within the grid AABB. Empty cells advance by
// max(skip, 1) along the slowest-axis step, gating on the per-cell
// baked skip distance.
static Hit ray_vs_world(constant MagicaUniforms& u,
                        texture3d<uint, access::read> tex_df,
                        float3 o, float3 d) {
    Hit h; h.hit = false; h.t = 0.0; h.id = 0u; h.axis = 0; h.side = 1.0;
    h.cell = int3(0);
    float3 lo = float3(u.grid_min);
    float3 hi = lo + float3(u.grid_dim);
    float2 clip = ray_aabb_clip(o, d, lo, hi);
    if (clip.y <= max(clip.x, 0.0)) return h;
    float t_start = max(clip.x, 0.0) + 1e-4;
    float t_end = clip.y;
    float3 p = o + d * t_start;
    int3 cell = int3(floor(p));
    int3 step = int3(sign(d));
    // Avoid step = 0 for any axis where d is exactly 0.
    if (step.x == 0) step.x = 1;
    if (step.y == 0) step.y = 1;
    if (step.z == 0) step.z = 1;
    float3 next_boundary = float3(
        float(cell.x + (step.x > 0 ? 1 : 0)),
        float(cell.y + (step.y > 0 ? 1 : 0)),
        float(cell.z + (step.z > 0 ? 1 : 0)));
    // t-values at which the ray crosses the next per-axis boundary.
    float3 t_next = (next_boundary - o) / d;
    // t increment per unit cell step along each axis.
    float3 t_delta = abs(1.0 / d);

    float t = t_start;
    // Hard iteration cap so degenerate rays can't hang the GPU.
    for (int i = 0; i < 512; ++i) {
        if (t >= t_end) return h;
        int3 rel = cell - u.grid_min;
        if (any(rel < int3(0)) || any(rel >= u.grid_dim)) return h;
        uint2 sample = tex_df.read(uint3(uint(rel.x), uint(rel.y), uint(rel.z))).rg;
        uint id = sample.x;
        uint skip = max(sample.y, 1u);
        if (id != 0u) {
            h.hit = true; h.t = t; h.id = id; h.cell = cell;
            return h;
        }
        // Advance min(t_next.{x,y,z}) - and apply skip-distance jumps
        // by stepping `skip` cells along the slowest-axis whenever
        // doing so is safe (i.e. cell IDs along the path are 0). The
        // baked skip distance is already chebyshev — stepping `skip`
        // is guaranteed not to cross a different-id cell. We step 1
        // cell here and let the loop iterate; the perf win comes from
        // amortising: a skip of 8 lets one slow-axis test do 8 cells
        // worth of march in a single iteration.
        //
        // Implementation: stretch t_next by (skip - 1) on the slowest
        // axis before crossing, then step skip cells in one shot.
        int axis = 0;
        if (t_next.y < t_next.x) axis = 1;
        if (t_next.z < t_next[axis]) axis = 2;
        int s = int(skip);
        // The chebyshev skip guarantees that stepping `s` cells in any
        // direction stays within a uniform-id region, so it's safe to
        // jump along the slowest axis. Cap to avoid stepping past the
        // grid bound.
        int3 rel_after = rel;
        rel_after[axis] += step[axis] * s;
        if (any(rel_after < int3(0)) || any(rel_after >= u.grid_dim)) {
            s = 1;
        }
        t = t_next[axis] + float(s - 1) * t_delta[axis];
        cell[axis] += step[axis] * s;
        t_next[axis] += t_delta[axis] * float(s);
        h.axis = axis;
        h.side = float(step[axis]);
    }
    return h;
}

// Shadow ray: returns true if no opaque blocker exists between o and
// o + d * max_t. Uses the same DDA but exits as soon as any id != 0 is
// hit. Glass blockers count as opaque shadowers in v1 — refining this
// to allow glass transmission is a follow-up.
static bool ray_shadowed(constant MagicaUniforms& u,
                         texture3d<uint, access::read> tex_df,
                         float3 o, float3 d, float max_t) {
    float3 lo = float3(u.grid_min);
    float3 hi = lo + float3(u.grid_dim);
    float2 clip = ray_aabb_clip(o, d, lo, hi);
    float t_start = max(clip.x, 1e-4);
    float t_end = min(clip.y, max_t);
    if (t_end <= t_start) return false;
    float3 p = o + d * t_start;
    int3 cell = int3(floor(p));
    int3 step = int3(sign(d));
    if (step.x == 0) step.x = 1;
    if (step.y == 0) step.y = 1;
    if (step.z == 0) step.z = 1;
    float3 next_b = float3(
        float(cell.x + (step.x > 0 ? 1 : 0)),
        float(cell.y + (step.y > 0 ? 1 : 0)),
        float(cell.z + (step.z > 0 ? 1 : 0)));
    float3 t_next = (next_b - o) / d;
    float3 t_delta = abs(1.0 / d);
    float t = t_start;
    for (int i = 0; i < 512; ++i) {
        if (t >= t_end) return false;
        int3 rel = cell - u.grid_min;
        if (any(rel < int3(0)) || any(rel >= u.grid_dim)) return false;
        uint2 sample = tex_df.read(uint3(uint(rel.x), uint(rel.y), uint(rel.z))).rg;
        if (sample.x != 0u) return true;
        uint skip = max(sample.y, 1u);
        int axis = 0;
        if (t_next.y < t_next.x) axis = 1;
        if (t_next.z < t_next[axis]) axis = 2;
        int s = int(skip);
        int3 rel_after = rel;
        rel_after[axis] += step[axis] * s;
        if (any(rel_after < int3(0)) || any(rel_after >= u.grid_dim)) s = 1;
        t = t_next[axis] + float(s - 1) * t_delta[axis];
        cell[axis] += step[axis] * s;
        t_next[axis] += t_delta[axis] * float(s);
    }
    return false;
}

// ---------------------------------------------------------------------------
// Primary ray reconstruction.
// ---------------------------------------------------------------------------

static float3 reconstruct_primary_dir(constant MagicaUniforms& u, float2 ndc) {
    // Project the NDC point at z=1 (far plane) through inv_vp; the
    // direction from camera_pos to that point is the ray. ndc is in
    // [-1, 1]^2 with +y up.
    float4 far_h = u.inv_vp * float4(ndc.x, ndc.y, 1.0, 1.0);
    float3 far_w = far_h.xyz / far_h.w;
    float3 dir_world = normalize(far_w - u.camera_pos);
    // World→grid: matches our existing convention (x, y, z)_w =
    // (gx, gz, -gy); inverse is (gx, gy, gz) = (x, -z, y).
    return float3(dir_world.x, -dir_world.z, dir_world.y);
}

static float3 camera_origin_grid(constant MagicaUniforms& u) {
    float3 p = u.camera_pos;
    return float3(p.x, -p.z, p.y);
}

// ---------------------------------------------------------------------------
// MIS helper: power heuristic.
// ---------------------------------------------------------------------------

static float mis_power(float a, float b) {
    float a2 = a * a;
    float b2 = b * b;
    return a2 / max(a2 + b2, 1e-12);
}

// Virtual ground plane at grid z = 0. Diffuse grey (linear-space).
// Matches PathTraceRenderer's editor-fallback floor so rays that
// escape the voxel AABB downward land on something instead of going
// straight to sky — surfaces have undersides and the empty-doc case
// has a horizon.
constant float3 kGroundAlbedo = float3(0.262, 0.218, 0.178);
constant float3 kGroundN      = float3(0.0, 0.0, 1.0);

static float intersect_ground(float3 o, float3 d) {
    // Returns parametric distance along (o, d) to the z=0 plane, or
    // -1 if the ray doesn't hit it from above.
    if (d.z >= -1e-6) return -1.0;
    float t = -o.z / d.z;
    return (t > 1e-3 && o.z > 0.0) ? t : -1.0;
}

// ---------------------------------------------------------------------------
// Path-trace fragment.
//
// One sample per pixel per frame; the additive-blend on the
// accum target sums them and the display pass divides by sample count.
// ---------------------------------------------------------------------------

fragment float4 magica_fragment(
    VOut in [[stage_in]],
    constant MagicaUniforms& u [[buffer(0)]],
    constant float4* palette [[buffer(1)]],
    constant GpuMaterial* materials [[buffer(2)]],
    constant GpuLight* lights [[buffer(3)]],
    texture3d<uint, access::read> tex_df [[texture(0)]],
    texture2d<float, access::sample> tex_noise [[texture(1)]])
{
    RngState rng = rng_init(in.position.xy, u.frame_seed,
                            tex_noise, u.inv_screen_size);

    // Subpixel jitter for AA. NDC ranges over [-1, +1] in y top-to-bottom
    // here since uv.y was flipped in vertex; convert back via in.uv.
    float2 px_jitter = rand2(rng) - 0.5;
    float2 uv = in.uv + px_jitter * float2(dfdx(in.uv.x), dfdy(in.uv.y));
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);

    float3 o = camera_origin_grid(u);
    float3 d = reconstruct_primary_dir(u, ndc);

    float3 throughput = float3(1.0);
    float3 radiance = float3(0.0);
    float prev_brdf_pdf = 0.0;       // for MIS on next event
    bool prev_was_specular = true;   // first hit's emission counted directly

    for (uint bounce = 0u; bounce < u.max_bounces; ++bounce) {
        Hit h = ray_vs_world(u, tex_df, o, d);
        float t_ground = intersect_ground(o, d);
        bool ground_wins = (t_ground > 0.0) && (!h.hit || t_ground < h.t);

        if (!h.hit && !ground_wins) {
            // Sky miss. Sun NEE has already accounted for direct-sun on
            // diffuse/metal hits; the sky-hit emission here is the
            // BSDF-pdf branch of MIS.
            float3 sky = sample_sky(u, d);
            radiance += throughput * sky;
            break;
        }

        // Resolve hit point + normal + material from whichever surface
        // won (voxel or virtual ground).
        float3 hit_p;
        float3 N;
        GpuMaterial m;
        float3 albedo;
        uint mtype;
        if (ground_wins) {
            hit_p = o + d * t_ground;
            N = kGroundN;
            albedo = kGroundAlbedo;
            // Ground is a hard-coded matte diffuse with no transparency
            // / emission / metallic. Synthesised inline rather than
            // burning a palette slot.
            m.type = float(MT_DIFFUSE);
            m.roughness = 1.0;
            m.metallic = 0.0;
            m.emission = 0.0;
            m.transparency = 0.0;
            m.ior = 1.0;
            m._pad0 = m._pad1 = 0.0;
            mtype = MT_DIFFUSE;
        } else {
            hit_p = o + d * h.t;
            N = float3(0);
            N[h.axis] = -h.side;
            m = materials[h.id];
            albedo = palette[h.id].rgb;
            mtype = uint(m.type);
        }
        // Nudge hit point off the face along the normal so subsequent
        // rays don't self-intersect.
        float3 hit_off = hit_p + N * 1e-3;

        // Emissive: terminate. Two regimes:
        //
        //   * No competing NEE estimator (bounce 0 = direct camera
        //     view, post-specular, GI off, or no lights): take the
        //     full BSDF contribution.
        //   * NEE is on and we got here via a non-specular BSDF
        //     bounce: MIS-weight the BSDF contribution against the
        //     pdf NEE would have assigned to this same direction
        //     (power heuristic). This is the path that picks up
        //     indirect light off diffuse surfaces — suppressing it
        //     loses ~half the variance reduction MIS provides.
        if (mtype == MT_EMISSIVE) {
            float emit_scale = max(m.emission, 0.0);
            float3 emit = albedo * emit_scale;
            bool no_nee_competitor =
                (bounce == 0u) || prev_was_specular ||
                u.light_count == 0u || u.stochastic_gi == 0u;
            float w_brdf = 1.0;
            if (!no_nee_competitor) {
                // Solid-angle pdf NEE would have produced for THIS
                // direction. Mirrors the NEE sampler: pick light
                // uniformly (1/N), pick face uniformly among the 3
                // visible (1/3), area pdf 1/face_area = 1, convert to
                // solid angle via dist² / N_light·-d.
                float ndl_light = max(-dot(N, d), 1e-4);
                float dist = h.t;
                float pdf_light_solid =
                    (1.0 / float(u.light_count)) * (1.0 / 3.0) *
                    (dist * dist / ndl_light);
                w_brdf = mis_power(prev_brdf_pdf, pdf_light_solid);
            }
            float3 contrib = throughput * emit * w_brdf;
            // Indirect BSDF-walk arrivals are proportionally clamped
            // to suppress fireflies; first-bounce camera-direct view
            // is unclamped so direct emitter color reads accurately.
            if (bounce > 0u && u.indirect_clamp_L > 0.0) {
                contrib = clamp_scale(contrib, u.indirect_clamp_L);
            }
            radiance += contrib;
            break;
        }

        // Diffuse / metal / glass.
        // -- Sun NEE -------------------------------------------------
        if (mtype == MT_DIFFUSE || mtype == MT_METAL) {
            float3 sun = u.sun_radiance;
            if (sun.x + sun.y + sun.z > 0.0) {
                // Sample a direction in the sun's cone. Correlated
                // stream so neighbour pixels in a tile see the same
                // cone direction → consistent shadows.
                float2 sr = corr2(rng, stride2(u.frame_seed, bounce, 1u),
                                  u.jitter_mult);
                float r1 = sr.x;
                float r2 = sr.y;
                float cos_theta = mix(u.sun_cos_half_angle, 1.0, r1);
                float sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
                float phi = 2.0 * M_PI_F * r2;
                float3 t = build_tangent(u.sun_dir);
                float3 b = cross(u.sun_dir, t);
                float3 L = normalize(sin_theta * cos(phi) * t +
                                     sin_theta * sin(phi) * b +
                                     cos_theta * u.sun_dir);
                float NdL = dot(N, L);
                if (NdL > 0.0 && !ray_shadowed(u, tex_df, hit_off, L, 1e6)) {
                    float3 brdf;
                    if (mtype == MT_DIFFUSE) {
                        brdf = albedo * (1.0 / M_PI_F);
                    } else {
                        // Smooth metal approximation: rough Schlick.
                        float3 F0 = mix(float3(0.04), albedo, m.metallic);
                        float3 F = fresnel_schlick3(max(NdL, 0.0), F0);
                        // GGX D / 4 NdV NdL omitted in the cone-sample
                        // approximation; use F * brdf-lobe-strength.
                        float a = max(m.roughness * m.roughness, 0.01);
                        float3 H = normalize(L - d);
                        float NdH = max(dot(N, H), 0.0);
                        float a2 = a * a;
                        float denom = NdH * NdH * (a2 - 1.0) + 1.0;
                        float D = a2 / (M_PI_F * denom * denom);
                        float NdV = max(-dot(N, d), 0.0);
                        float k = a * 0.5;
                        float G = (NdV / (NdV * (1.0 - k) + k)) *
                                  (NdL / (NdL * (1.0 - k) + k));
                        brdf = (F * D * G) / max(4.0 * NdV * NdL, 1e-4);
                    }
                    // Cone solid angle = 2π(1 - cos_half).
                    float omega = 2.0 * M_PI_F *
                                  (1.0 - u.sun_cos_half_angle);
                    radiance += throughput * brdf * sun * NdL * omega;
                }
            }

            // -- Area-light NEE (gated by Stochastic GI toggle) -----
            //
            // Pick one emissive voxel uniformly. To avoid wasting
            // shadow rays on faces that emit away from the receiver,
            // deterministically pick the face whose outward normal
            // points toward the receiver — the dominant axis of the
            // (receiver - cell_center) vector. Then sample a uniform
            // point on that face. Estimator (one-sample MC, with
            // per-cell area = 1 and pdf = 1 / (N_lights · area)):
            //   contribution = Le · f_r · (N · Ld) · (N_light · -Ld)
            //                  · N_lights / dist²
            // The N_light·-Ld cosine is the one the previous version
            // was missing, which made off-axis emitters look like
            // glowing point sources instead of oriented surfaces.
            if (u.stochastic_gi != 0u && u.light_count > 0u) {
                // All NEE randomness on the correlated stream too —
                // neighbour pixels in a tile pick the same light,
                // same face, same point on the face → same shadow
                // ray. The aligned BSDF + NEE estimators give lower
                // tile-to-tile variance per sample than mixing
                // correlated BSDF with decorrelated NEE.
                float lr = corr1(rng, stride1(u.frame_seed, bounce, 2u),
                                 u.jitter_mult.x);
                uint li = min(uint(lr * float(u.light_count)),
                              u.light_count - 1u);
                GpuLight gl = lights[li];
                float3 cell_min = gl.pos.xyz;
                float3 cell_center = cell_min + float3(0.5);
                float3 from = hit_off - cell_center;

                // Pick uniformly among the 3 axis-aligned faces whose
                // outward normal points toward the receiver. (The
                // other 3 faces emit away and would contribute 0.) An
                // earlier version picked the single dominant-axis
                // face, which silently zeroed contributions whenever
                // the receiver sat near a 45° corner — two faces
                // contributed equally but we only sampled one whose
                // grazing N_light·-Ld was near zero. Sampling 3 faces
                // gives an unbiased estimator at 3× the variance.
                float fr = corr1(rng, stride1(u.frame_seed, bounce, 3u),
                                 u.jitter_mult.x) * 3.0;
                int la = int(fr);
                la = clamp(la, 0, 2);
                float face_sign = (from[la] >= 0.0) ? 1.0 : -1.0;
                float side = (face_sign > 0.0) ? 1.0 : 0.0;

                int t1 = (la + 1) % 3;
                int t2 = (la + 2) % 3;
                float2 pr = corr2(rng, stride2(u.frame_seed, bounce, 4u),
                                  u.jitter_mult);
                float r1 = pr.x;
                float r2 = pr.y;
                float3 sp = cell_min;
                sp[la] += side;
                sp[t1] += r1;
                sp[t2] += r2;

                float3 nL = float3(0);
                nL[la] = face_sign;

                float3 to = sp - hit_off;
                float dist2 = dot(to, to);
                float dist = sqrt(dist2);
                float3 Ld = to / dist;
                float NdL = dot(N, Ld);
                float NdL_light = dot(nL, -Ld);
                if (NdL > 0.0 && NdL_light > 0.0 &&
                    !ray_shadowed(u, tex_df, hit_off, Ld, dist - 1e-2)) {
                    float3 brdf;
                    float pdf_brdf_at_dir;
                    if (mtype == MT_DIFFUSE) {
                        brdf = albedo * (1.0 / M_PI_F);
                        pdf_brdf_at_dir = NdL / M_PI_F;
                    } else {
                        // Glossy NEE eval is a v2 task; skip for now
                        // and let the BSDF random walk find it.
                        brdf = float3(0);
                        pdf_brdf_at_dir = 0.0;
                    }
                    float3 Le = gl.le.xyz;
                    // Solid-angle pdf for this NEE sample, used to
                    // power-heuristic against the BSDF pdf at the
                    // same direction. Same form as the BSDF-arrival
                    // branch above so the two MIS weights sum to 1.
                    float pdf_light_solid =
                        (1.0 / float(u.light_count)) * (1.0 / 3.0) *
                        (dist2 / max(NdL_light, 1e-4));
                    float w_nee = mis_power(pdf_light_solid, pdf_brdf_at_dir);
                    radiance += throughput * brdf * Le * NdL * NdL_light *
                                3.0 * float(u.light_count) / dist2 * w_nee;
                }
            }
        }

        // -- BSDF sample for the next bounce -------------------------
        float3 next_d = d;
        float3 next_o = hit_off;
        if (mtype == MT_DIFFUSE) {
            // Tile-correlated BSDF direction — the heart of the
            // splash effect. corr2() is the only RNG that sees
            // neighbour-pixel correlation; sun NEE / area NEE / RR
            // stay on the decorrelated PCG stream.
            next_d = cosine_sample_hemisphere(N, corr2(rng, u.lobes[min(bounce, 7u)].xy, u.jitter_mult));
            throughput *= albedo;
            prev_brdf_pdf = max(dot(N, next_d), 0.0) / M_PI_F;
            prev_was_specular = false;
        } else if (mtype == MT_METAL) {
            float a = max(m.roughness * m.roughness, 0.001);
            float3 V_ws = -d;
            float3 V_ts = to_local(V_ws, N);
            float3 H_ts = ggx_sample_vndf(V_ts, a,
                              corr2(rng, u.lobes[min(bounce, 7u)].xy, u.jitter_mult));
            float3 H_ws = to_world(H_ts, N);
            next_d = reflect(d, H_ws);
            if (dot(next_d, N) <= 0.0) break;
            float3 F0 = mix(float3(0.04), albedo, m.metallic);
            float HoV = max(dot(H_ws, V_ws), 0.0);
            float3 F = fresnel_schlick3(HoV, F0);
            throughput *= F;
            // No metal NEE yet, so any BSDF-found emitter must count
            // at full weight regardless of roughness — otherwise rough
            // metals near emitters would appear black (MIS would zero
            // BSDF-arrival, NEE contributes nothing).
            prev_was_specular = true;
            prev_brdf_pdf = 0.0;
        } else if (mtype == MT_GLASS) {
            // Probabilistic Fresnel reflect/refract. Assumes the medium
            // we just came from is "air" — interior refraction tracking
            // is a v2 refinement.
            float NoV = dot(N, -d);
            bool entering = NoV > 0.0;
            float3 Nf = entering ? N : -N;
            float eta = entering ? (1.0 / m.ior) : m.ior;
            float cos_i = abs(NoV);
            float k = 1.0 - eta * eta * (1.0 - cos_i * cos_i);
            if (k < 0.0) {
                // Total internal reflection.
                next_d = reflect(d, Nf);
            } else {
                float F = fresnel_schlick(cos_i, 0.04);
                float gr = corr1(rng, stride1(u.frame_seed, bounce, 6u),
                                 u.jitter_mult.x);
                if (gr < F) {
                    next_d = reflect(d, Nf);
                } else {
                    next_d = eta * d + (eta * cos_i - sqrt(k)) * Nf;
                    next_o = hit_p - Nf * 1e-3;
                }
            }
            // Glass tint approximation. Probabilistic mode keeps full
            // tint; absorption mode interpolates toward white as
            // transparency rises (matches our GlassMode convention).
            float3 tint = (u.glass_mode == 0u)
                ? albedo
                : mix(albedo, float3(1.0), m.transparency);
            throughput *= tint;
            prev_was_specular = true;
            prev_brdf_pdf = 0.0;
        } else {
            break;  // unknown material type
        }

        // Russian roulette after a few bounces. Correlated so a tile's
        // pixels all terminate together — same survival probability,
        // same outcome.
        if (bounce >= 3u) {
            float p = clamp(max3(throughput.r, throughput.g, throughput.b),
                            0.05, 0.95);
            float rr = corr1(rng, stride1(u.frame_seed, bounce, 5u),
                             u.jitter_mult.x);
            if (rr > p) break;
            throughput /= p;
        }

        o = next_o;
        d = next_d;
    }

    // Clamp aggressive fireflies (per-sample contribution). Mirrors
    // Magica's clamp_L behaviour; v1 uses a fixed-ish ceiling.
    radiance = min(radiance, float3(32.0));
    return float4(radiance, 1.0);
}

// ---------------------------------------------------------------------------
// Display fragment: accum / sample_count → tonemap → sRGB.
// ---------------------------------------------------------------------------

static float3 aces_film(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

fragment float4 magica_display_fragment(
    VOut in [[stage_in]],
    constant DisplayUniforms& u [[buffer(0)]],
    texture2d<float, access::sample> accum [[texture(0)]])
{
    // Letterbox / pillarbox if aspect-mismatched.
    float2 uv = in.uv;
    float dx = (1.0 - u.region_w) * 0.5;
    float dy = (1.0 - u.region_h) * 0.5;
    if (uv.x < dx || uv.x > 1.0 - dx || uv.y < dy || uv.y > 1.0 - dy) {
        return float4(0, 0, 0, 1);
    }
    float2 inner = float2((uv.x - dx) / u.region_w,
                          (uv.y - dy) / u.region_h);
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float3 col = accum.sample(s, inner).rgb / float(max(u.sample_count, 1u));
    col = (u.aces_tonemap != 0u) ? aces_film(col) : col;
    col = pow(max(col, 0.0), float3(1.0 / 2.2));
    return float4(col, 1.0);
}
