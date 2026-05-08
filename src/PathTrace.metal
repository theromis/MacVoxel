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
    float    _pad7;
};

struct GpuLight {
    float4 pos;  // .xyz = grid-space corner; .w = cumulative CDF for
                 //   power-weighted importance sampling (last entry = 1.0).
    float4 le;   // .xyz = albedo_linear * effective_emission;
                 // .w   = per-light sampling probability (= cdf[i]-cdf[i-1]).
};

struct DisplayUniforms {
    uint  sample_count;
    uint  aces_tonemap;
    float region_w;
    float region_h;
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
float rand1(thread uint& s) {
    return float(pcg(s)) * (1.0 / 4294967296.0);
}

// Cosine-weighted hemisphere sample about a unit normal.
float3 cosine_hemi(float3 n, thread uint& rng) {
    float r1 = rand1(rng);
    float r2 = rand1(rng);
    float phi = 6.2831853 * r1;
    float r = sqrt(r2);
    float3 local = float3(r * cos(phi), r * sin(phi), sqrt(max(0.0, 1.0 - r2)));
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
float3 ggx_sample_vndf(float3 n, float3 view, float roughness, thread uint& rng) {
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
    float u1 = rand1(rng);
    float u2 = rand1(rng);
    float r = sqrt(u1);
    float phi = 6.2831853 * u2;
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
// pdf when MIS-weighting the BSDF-sampled emitter arrival. With RIS,
// the "true" pdf is M · target / W_sum (depends on W_sum, which we'd
// have to re-run RIS to know). The standard approximation is to use
// `target_pdf` directly: at large M the effective pdf converges to
// (target / ∫target), which is proportional to target — and MIS power
// heuristic is scale-invariant in pdf ratios, so the un-normalized
// target works.
float nee_pdf_solid_for_arrival(constant PathUniforms& u,
                                device const GpuLight* lights,
                                int3 hit_cell,
                                float3 n_x_prev,
                                float3 omega,
                                float3 n_y)
{
    if (u.light_count == 0u) return 0.0;
    float cos_y = dot(n_y, -omega);
    float cos_x = dot(n_x_prev, omega);
    if (cos_x <= 0.0 || cos_y <= 0.0) return 0.0;
    for (uint i = 0u; i < u.light_count; ++i) {
        if (all(int3(lights[i].pos.xyz) == hit_cell)) {
            return nee_target_pdf_solid(lights[i].le.xyz, cos_x);
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
                          constant PathUniforms& u,
                          device const GpuLight* lights,
                          device const uint* coarse_grid,
                          device const Chunk* chunk_pool,
                          thread uint& rng)
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
        uint li;
        float prob_li;
        if (u.power_weighted_nee != 0u) {
            float u_rand = rand1(rng);
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
            li = uint(rand1(rng) * float(u.light_count));
            if (li >= u.light_count) li = u.light_count - 1u;
            prob_li = 1.0 / float(u.light_count);
        }
        if (prob_li <= 0.0) continue;
        GpuLight L = lights[li];

        // Face selection — uniform over the 3 visible faces of the cell.
        float3 corner = L.pos.xyz;
        float3 center = corner + 0.5;
        float3 to_x = x - center;
        int axis = int(rand1(rng) * 3.0);
        if (axis > 2) axis = 2;
        float coord_axis = (axis == 0) ? to_x.x
                         : (axis == 1) ? to_x.y : to_x.z;
        float face_sign = coord_axis >= 0.0 ? 1.0 : -1.0;
        float3 n_y = float3(0.0);
        float3 y = corner;
        float u1 = rand1(rng);
        float u2 = rand1(rng);
        if (axis == 0) {
            n_y.x = face_sign;
            y.x += face_sign > 0.0 ? 1.0 : 0.0;
            y.y += u1; y.z += u2;
        } else if (axis == 1) {
            n_y.y = face_sign;
            y.y += face_sign > 0.0 ? 1.0 : 0.0;
            y.x += u1; y.z += u2;
        } else {
            n_y.z = face_sign;
            y.z += face_sign > 0.0 ? 1.0 : 0.0;
            y.x += u1; y.y += u2;
        }

        float3 d = y - x;
        float dist2 = dot(d, d);
        if (dist2 < 1e-8) continue;
        float dist = sqrt(dist2);
        float3 omega = d / dist;
        float cos_x = dot(n_x, omega);
        float cos_y = dot(n_y, -omega);
        if (cos_x <= 0.0 || cos_y <= 0.0) continue;

        // RIS weight = target / source (both in solid-angle measure).
        // Source pdf = prob_li · (1/3) · dist² / cos_y (face-area pdf
        // converted to solid angle); target = unshadowed integrand
        // luminance. Equal denominators across iterations let us do
        // weighted reservoir sampling with one rand1 per candidate.
        float source_pdf_solid = prob_li * (1.0 / 3.0) * dist2 / cos_y;
        float target = nee_target_pdf_solid(L.le.xyz, cos_x);
        if (source_pdf_solid <= 0.0 || target <= 0.0) continue;
        float w_i = target / source_pdf_solid;

        w_sum += w_i;
        if (rand1(rng) * w_sum < w_i) {
            chosen_omega  = omega;
            chosen_le     = L.le.xyz;
            chosen_cos_x  = cos_x;
            chosen_cos_y  = cos_y;
            chosen_dist2  = dist2;
            chosen_cell   = int3(L.pos.xyz);
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
                        constant PathUniforms& u,
                        device const uint* coarse_grid,
                        device const Chunk* chunk_pool,
                        thread uint& rng)
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
    float u1 = rand1(rng);
    float u2 = rand1(rng);
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
    device const GpuLight* lights [[buffer(5)]])
{
    uint2 pix = uint2(in.position.xy);
    uint rng = (pix.x * 1973u) ^ (pix.y * 9277u) ^ (u.frame_seed * 26699u);
    pcg(rng); pcg(rng);  // mix the seed

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
            // through the medium. We want the user's albedo to read as
            // the color at a "typical" slab thickness rather than at
            // exactly 1 voxel — otherwise saturated colors compound
            // into near-black across any slab more than 1 voxel thick
            // or viewed at any angle. The 0.5 factor ties albedo to
            // a 2-voxel reference depth, which keeps body color readable
            // and lets edges (longer paths) darken as expected.
            const float kAbsorptionScale = 0.5;
            float dist = length(h.point - medium_entry);
            throughput *= pow(max(medium_albedo, float3(1e-6)),
                              float3(dist * kAbsorptionScale));

            GpuMaterial em = materials[entered_medium];
            float3 n = float3(0.0);
            if      (h.axis == 0) n.x = float(h.sign);
            else if (h.axis == 1) n.y = float(h.sign);
            else if (h.axis == 2) n.z = float(h.sign);
            float em_rough = clamp(em.roughness, 0.0, 1.0);
            float3 m = ggx_sample_vndf(n, -ray_dir, em_rough, rng);
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
            if (k < 0.0 || rand1(rng) < fresnel_in) {
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
                if (rand1(rng) > p) break;
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
                    {
                        NEELight nee = nee_sample_light(
                            g_point, kGroundNormal, u, lights,
                            coarse_grid, chunk_pool, rng);
                        radiance += throughput *
                            nee_diffuse_mis(nee, kGroundAlbedo, kGroundNormal);
                        NEELight nee_s = nee_sample_sun(
                            g_point, kGroundNormal, u,
                            coarse_grid, chunk_pool, rng);
                        radiance += throughput *
                            nee_diffuse_mis(nee_s, kGroundAlbedo, kGroundNormal);
                    }
                    ray_origin = g_point + kGroundNormal * 1e-3;
                    ray_dir = cosine_hemi(kGroundNormal, rng);
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
        // side. Primary visibility (b=0), delta-like prior bounces, and
        // the no-NEE case (light_count=0) get full weight.
        if (mat_type == kMatEmissive && mat.emission > 0.0) {
            float3 Le = albedo * mat.emission;
            if (b == 0u || prev_is_delta || u.light_count == 0u) {
                radiance += throughput * Le;
            } else {
                float3 n_y = float3(0.0);
                if      (h.axis == 0) n_y.x = float(h.sign);
                else if (h.axis == 1) n_y.y = float(h.sign);
                else if (h.axis == 2) n_y.z = float(h.sign);
                float pdf_light = nee_pdf_solid_for_arrival(
                    u, lights, h.cell_coord, prev_normal,
                    ray_dir, n_y);
                float w_bsdf = mis_power(prev_bsdf_pdf, pdf_light);
                radiance += throughput * Le * w_bsdf;
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
            if (rand1(rng) < clamp(mat.metallic, 0.0, 1.0)) {
                float r = clamp(mat.roughness, 0.0, 1.0);
                {
                    NEELight nee = nee_sample_light(
                        h.point, normal, u, lights,
                        coarse_grid, chunk_pool, rng);
                    radiance += throughput *
                        nee_ggx_mis(nee, omega_o, normal, albedo, r);
                    NEELight nee_s = nee_sample_sun(
                        h.point, normal, u,
                        coarse_grid, chunk_pool, rng);
                    radiance += throughput *
                        nee_ggx_mis(nee_s, omega_o, normal, albedo, r);
                }
                float3 m = ggx_sample_vndf(normal, omega_o, r, rng);
                ray_dir = ray_dir - 2.0 * dot(ray_dir, m) * m;
                prev_bsdf_pdf = pdf_ggx_vndf(normal, omega_o, ray_dir, r);
                prev_is_delta = (prev_bsdf_pdf <= 0.0);
            } else {
                {
                    NEELight nee = nee_sample_light(
                        h.point, normal, u, lights,
                        coarse_grid, chunk_pool, rng);
                    radiance += throughput *
                        nee_diffuse_mis(nee, albedo, normal);
                    NEELight nee_s = nee_sample_sun(
                        h.point, normal, u,
                        coarse_grid, chunk_pool, rng);
                    radiance += throughput *
                        nee_diffuse_mis(nee_s, albedo, normal);
                }
                ray_dir = cosine_hemi(normal, rng);
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
            // Transparency interpretation depends on RenderState's
            // glass_mode (set per-frame as u.glass_mode):
            //  - Probabilistic (0): with prob=transparency, refract with
            //    medium_albedo = albedo. Else diffuse-fallback bounce.
            //    transparency=1 still tints; transparency=0.5 reads milky.
            //  - Absorption (1): always refract on transmit; medium_albedo
            //    interpolates albedo (transparency=0) toward white
            //    (transparency=1). transparency=1 is fully clear.
            float rough = clamp(mat.roughness, 0.0, 1.0);
            float3 omega_o = -ray_dir;
            float3 m = ggx_sample_vndf(normal, omega_o, rough, rng);
            float cos_i = max(0.0, -dot(ray_dir, m));
            float r0 = (1.0 - mat.ior) / (1.0 + mat.ior);
            r0 *= r0;
            float fresnel = r0 + (1.0 - r0) * pow(1.0 - cos_i, 5.0);
            float trans = clamp(mat.transparency, 0.0, 1.0);
            float3 f0_glass = float3(r0);
            if (rand1(rng) < fresnel) {
                // Fresnel reflect lobe — MIS-weighted NEE against the
                // GGX VNDF sampler. At low roughness the BSDF wins and
                // captures crisp mirror-of-light contributions; at high
                // roughness NEE wins and direct-samples emitters.
                {
                    NEELight nee = nee_sample_light(
                        h.point, normal, u, lights,
                        coarse_grid, chunk_pool, rng);
                    radiance += throughput *
                        nee_ggx_mis(nee, omega_o, normal, f0_glass, rough);
                    NEELight nee_s = nee_sample_sun(
                        h.point, normal, u,
                        coarse_grid, chunk_pool, rng);
                    radiance += throughput *
                        nee_ggx_mis(nee_s, omega_o, normal, f0_glass, rough);
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
                                    (rand1(rng) < trans);
                if (refract_path) {
                    float eta = 1.0 / mat.ior;  // air -> glass
                    float k = 1.0 - eta * eta * (1.0 - cos_i * cos_i);
                    if (k < 0.0) {
                        // TIR — same reflect geometry as the Fresnel
                        // reflect branch; same MIS-weighted NEE.
                        {
                            NEELight nee = nee_sample_light(
                                h.point, normal, u, lights,
                                coarse_grid, chunk_pool, rng);
                            radiance += throughput *
                                nee_ggx_mis(nee, omega_o, normal,
                                            f0_glass, rough);
                            NEELight nee_s = nee_sample_sun(
                                h.point, normal, u,
                                coarse_grid, chunk_pool, rng);
                            radiance += throughput *
                                nee_ggx_mis(nee_s, omega_o, normal,
                                            f0_glass, rough);
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
                        // Absorption mode caps the "clear" end at 0.9
                        // rather than full white so even nominally-
                        // clear glass keeps a per-voxel Beer-Lambert
                        // factor. That attenuates the back-face
                        // Fresnel ghost reflection (P11.5) over its
                        // two-medium-traversal path so the ghost reads
                        // as a clearly-fainter copy of the primary.
                        medium_albedo = (u.glass_mode == 1u)
                            ? mix(albedo, float3(0.9), trans)
                            : albedo;
                        prev_is_delta = true;
                    }
                } else {
                    // Diffuse fallback — Probabilistic mode only.
                    {
                        NEELight nee = nee_sample_light(
                            h.point, normal, u, lights,
                            coarse_grid, chunk_pool, rng);
                        radiance += throughput *
                            nee_diffuse_mis(nee, albedo, normal);
                        NEELight nee_s = nee_sample_sun(
                            h.point, normal, u,
                            coarse_grid, chunk_pool, rng);
                        radiance += throughput *
                            nee_diffuse_mis(nee_s, albedo, normal);
                    }
                    ray_origin = h.point + normal * 1e-3;
                    ray_dir = cosine_hemi(normal, rng);
                    prev_bsdf_pdf = pdf_lambert(normal, ray_dir);
                    prev_is_delta = false;
                    throughput *= albedo;
                }
            }
        } else {
            // Diffuse default.
            {
                NEELight nee = nee_sample_light(h.point, normal, u, lights,
                                                coarse_grid, chunk_pool,
                                                rng);
                radiance += throughput * nee_diffuse_mis(nee, albedo, normal);
                NEELight nee_s = nee_sample_sun(h.point, normal, u,
                                                coarse_grid, chunk_pool,
                                                rng);
                radiance += throughput *
                    nee_diffuse_mis(nee_s, albedo, normal);
            }
            ray_origin = h.point + normal * 1e-3;
            ray_dir = cosine_hemi(normal, rng);
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
        // without the cost growing linearly.
        if (b >= kMinBouncesBeforeRR) {
            float p = max(throughput.r, max(throughput.g, throughput.b));
            p = clamp(p, 0.05, 0.95);
            if (rand1(rng) > p) break;
            throughput /= p;
        }
    }
    return float4(radiance, 1.0);
}

// ACES filmic tonemap (Narkowicz 2015 fit) — squeezes the linear HDR
// accumulator into [0, 1] with a soft shoulder so bright emissives roll
// off instead of clipping to white. Followed by a proper linear → sRGB
// encode (gamma 2.2 is a rough approximation; the piecewise sRGB curve
// is what the display actually expects).
fragment float4 display_fragment(
    VertOut in [[stage_in]],
    constant DisplayUniforms& u [[buffer(0)]],
    texture2d<float, access::sample> accum [[texture(0)]])
{
    // Linear so the display pass blends sensibly when the accumulator
    // is rendered at a different resolution than the drawable
    // (½× iteration mode upscales, 2× supersamples down).
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    // Map drawable NDC [-1, 1] to a centered region of size
    // (region_w, region_h) — pixels outside it are letterbox / pillarbox
    // bars. Inside, scale to [0, 1] for the accum sample.
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
