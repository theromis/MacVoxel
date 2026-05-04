#import "PathTraceRenderer.h"

#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import <cstdio>
#include <array>
#include <cstdint>
#include <cstring>
#include <vector>

#include "Camera.h"
#include "Document.h"
#include "Material.h"
#include "RenderState.h"

#include <cmath>

namespace {

struct PathUniforms {
    simd::float4x4 inv_vp;
    simd::float3 camera_pos;
    float _pad0;
    simd::int3 coarse_min;
    int _pad1;
    simd::int3 coarse_dim;
    int _pad2;
    simd::float3 sky_color;
    float _pad3;
    uint32_t frame_seed;
    uint32_t max_bounces;
    uint32_t light_count;
    uint32_t glass_mode;  // 0 = Probabilistic, 1 = Absorption
};

// Per-emissive-voxel entry in the next-event-estimation light buffer.
// Built CPU-side at doc.version change so the shader doesn't have to
// scan the grid; `le` is the linear-space color × effective emission so
// the shader needs no palette/material lookup at sample time.
struct GpuLight {
    simd::float4 pos;  // .xyz = grid-space corner of the voxel; .w unused
    simd::float4 le;   // .xyz = albedo_linear * effective_emission; .w unused
};
static_assert(sizeof(GpuLight) == 32, "GpuLight size mismatch");

// Per-palette-entry material data uploaded to the path-tracer's
// fragment shader. Mirrors macvoxel::Material but lives in a tightly
// packed format for the GPU.
struct GpuMaterial {
    float type;          // 0=Diffuse, 1=Metal, 2=Emissive, 3=Glass
    float roughness;
    float metallic;
    float emission;
    float transparency;
    float ior;
    float _pad0;
    float _pad1;
};
static_assert(sizeof(GpuMaterial) == 32, "GpuMaterial size mismatch");

struct DisplayUniforms {
    uint32_t sample_count;
    uint32_t aces_tonemap;
    // Fractions of the drawable that the rendered image occupies after
    // aspect-preserving fit-to-window. Both 1.0 means stretch (or
    // identity, when accum size matches drawable size).
    float region_w;
    float region_h;
};

NSString* const kShaderSource = @R"MSL(
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
};

struct GpuLight {
    float4 pos;  // .xyz = grid-space corner; .w unused
    float4 le;   // .xyz = albedo_linear * effective_emission; .w unused
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

// Solid-angle pdf that NEE would have given for sampling a direction
// arriving at an emissive voxel hit, used as the "other" pdf when
// MIS-weighting a BSDF-sampled emitter arrival.
float nee_pdf_solid_for_arrival(constant PathUniforms& u,
                                float3 omega,
                                float3 n_y,
                                float dist2)
{
    if (u.light_count == 0u) return 0.0;
    float cos_y = dot(n_y, -omega);
    if (cos_y <= 0.0) return 0.0;
    float pdf_area = 1.0 / (float(u.light_count) * 3.0);
    return pdf_area * dist2 / cos_y;
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

// Pick a uniformly-random emissive voxel, pick one of the three faces
// oriented toward x, sample uniformly on that face, trace a shadow ray.
// pdf_area = 1 / (N_lights · 3 · 1.0); pdf_solid follows.
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

    uint li = uint(rand1(rng) * float(u.light_count));
    if (li >= u.light_count) li = u.light_count - 1u;
    GpuLight L = lights[li];
    float3 corner = L.pos.xyz;
    float3 center = corner + 0.5;
    float3 to_x = x - center;

    int axis = int(rand1(rng) * 3.0);
    if (axis > 2) axis = 2;
    float coord_axis = (axis == 0) ? to_x.x : (axis == 1) ? to_x.y : to_x.z;
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
    if (dist2 < 1e-8) return r;
    float dist = sqrt(dist2);
    float3 omega = d / dist;
    float cos_x = dot(n_x, omega);
    float cos_y = dot(n_y, -omega);
    if (cos_x <= 0.0 || cos_y <= 0.0) return r;

    DDAHit s = dda_traverse(x + n_x * 1e-3, omega, u,
                            coarse_grid, chunk_pool, 0u);
    int3 light_cell = int3(L.pos.xyz);
    if (!s.hit) return r;
    if (any(s.cell_coord != light_cell)) return r;

    r.visible   = true;
    r.omega_i   = omega;
    r.le        = L.le.xyz;
    r.cos_x     = cos_x;
    r.cos_y     = cos_y;
    r.dist2     = dist2;
    float pdf_area = 1.0 / (float(u.light_count) * 3.0);
    r.pdf_solid = pdf_area * dist2 / cos_y;
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
            if (k < 0.0) {
                // Total internal reflection — bounce back into the medium
                // and start a new Beer-Lambert segment from this point.
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
                    }
                    ray_origin = g_point + kGroundNormal * 1e-3;
                    ray_dir = cosine_hemi(kGroundNormal, rng);
                    prev_bsdf_pdf = pdf_lambert(kGroundNormal, ray_dir);
                    prev_is_delta = false;
                    throughput *= kGroundAlbedo;
                    continue;
                }
            }
            radiance += throughput * u.sky_color;
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
                float3 d = h.point - ray_origin;
                float dist2 = dot(d, d);
                float pdf_light = nee_pdf_solid_for_arrival(
                    u, ray_dir, n_y, dist2);
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
                        medium_albedo = (u.glass_mode == 1u)
                            ? mix(albedo, float3(1.0), trans)
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
            }
            ray_origin = h.point + normal * 1e-3;
            ray_dir = cosine_hemi(normal, rng);
            prev_bsdf_pdf = pdf_lambert(normal, ray_dir);
            prev_is_delta = false;
            throughput *= albedo;
        }

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
)MSL";

}  // namespace

@implementation PathTraceRenderer {
    id<MTLDevice> _device;
    MTLPixelFormat _colorFormat;
    id<MTLRenderPipelineState> _pathPipeline;
    id<MTLRenderPipelineState> _displayPipeline;
    id<MTLTexture> _accumTexture;
    CGSize _accumSize;

    id<MTLBuffer> _coarseBuffer;
    id<MTLBuffer> _poolBuffer;
    id<MTLBuffer> _paletteBuffer;
    id<MTLBuffer> _materialBuffer;
    id<MTLBuffer> _lightBuffer;
    uint32_t _lightCount;
    uint64_t _cachedDocVersion;
    BOOL _resourcesValid;
    simd::int3 _coarseMin;
    simd::int3 _coarseDim;

    // Accumulation state.
    uint32_t _sampleCount;
    BOOL _wantsClear;

    // Camera-state hash for reset detection.
    uint64_t _lastCameraHash;
    // Glass interpretation last seen — toggling forces an accumulator
    // reset since the two modes produce visually different estimators.
    macvoxel::GlassMode _lastGlassMode;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat {
    self = [super init];
    if (self == nil) return nil;
    _device = device;
    _colorFormat = colorFormat;
    _wantsClear = YES;

    NSError* error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:kShaderSource
                                                   options:nil
                                                     error:&error];
    if (library == nil) {
        fprintf(stderr, "MacVoxel: failed to compile path-trace shaders: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    id<MTLFunction> vfn = [library newFunctionWithName:@"pt_vertex"];
    id<MTLFunction> ptffn = [library newFunctionWithName:@"pt_fragment"];
    id<MTLFunction> dispffn = [library newFunctionWithName:@"display_fragment"];

    // Accumulation pipeline: writes float4 RGBA, additive blend (One/One)
    // so each frame's contribution adds into the accum texture.
    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.label = @"PathTraceAccum";
        d.vertexFunction = vfn;
        d.fragmentFunction = ptffn;
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        d.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
        _pathPipeline = [_device newRenderPipelineStateWithDescriptor:d error:&error];
        if (_pathPipeline == nil) {
            fprintf(stderr, "MacVoxel: failed to build path-trace pipeline: %s\n",
                    [[error localizedDescription] UTF8String]);
            return nil;
        }
    }

    // Display pipeline: samples the accum texture, divides by sample
    // count, writes to MTKView's drawable.
    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.label = @"PathTraceDisplay";
        d.vertexFunction = vfn;
        d.fragmentFunction = dispffn;
        d.colorAttachments[0].pixelFormat = colorFormat;
        _displayPipeline = [_device newRenderPipelineStateWithDescriptor:d error:&error];
        if (_displayPipeline == nil) {
            fprintf(stderr, "MacVoxel: failed to build display pipeline: %s\n",
                    [[error localizedDescription] UTF8String]);
            return nil;
        }
    }

    return self;
}

- (uint32_t)sampleCount { return _sampleCount; }
- (void)invalidate { _wantsClear = YES; }

// ---------------------------------------------------------------------------
// Voxel data upload — wholesale on doc->version change. Same coarse-grid /
// chunk-pool layout the raster path uses; we just don't bother with the
// raster path's incremental updates here (path tracing is for stationary
// "render mode" use, not interactive editing).
// ---------------------------------------------------------------------------

- (void)rebuildResourcesFromDocument:(macvoxel::Document*)doc {
    using VG = macvoxel::VoxelGrid;
    const auto& chunks = doc->grid.chunks();

    if (chunks.empty()) {
        _coarseMin = simd::int3{0, 0, 0};
        _coarseDim = simd::int3{0, 0, 0};
        _coarseBuffer = nil;
        _poolBuffer = nil;
    } else {
        int32_t min_cx = INT32_MAX, min_cy = INT32_MAX, min_cz = INT32_MAX;
        int32_t max_cx = INT32_MIN, max_cy = INT32_MIN, max_cz = INT32_MIN;
        for (const auto& [coord, chunk] : chunks) {
            min_cx = std::min(min_cx, coord.x);
            min_cy = std::min(min_cy, coord.y);
            min_cz = std::min(min_cz, coord.z);
            max_cx = std::max(max_cx, coord.x);
            max_cy = std::max(max_cy, coord.y);
            max_cz = std::max(max_cz, coord.z);
        }
        _coarseMin = simd::int3{min_cx, min_cy, min_cz};
        _coarseDim = simd::int3{max_cx - min_cx + 1,
                                max_cy - min_cy + 1,
                                max_cz - min_cz + 1};

        const size_t coarse_count =
            static_cast<size_t>(_coarseDim.x) *
            static_cast<size_t>(_coarseDim.y) *
            static_cast<size_t>(_coarseDim.z);
        std::vector<uint32_t> coarse(coarse_count, 0);
        std::vector<uint8_t> pool;
        pool.reserve(chunks.size() * VG::kChunkVolume);
        uint32_t pool_idx = 1;
        for (const auto& [coord, chunk] : chunks) {
            const size_t cgi =
                static_cast<size_t>(coord.x - min_cx) +
                static_cast<size_t>(coord.y - min_cy) *
                    static_cast<size_t>(_coarseDim.x) +
                static_cast<size_t>(coord.z - min_cz) *
                    static_cast<size_t>(_coarseDim.x) *
                    static_cast<size_t>(_coarseDim.y);
            coarse[cgi] = pool_idx++;
            const size_t old = pool.size();
            pool.resize(old + VG::kChunkVolume);
            std::memcpy(pool.data() + old, chunk->cells, VG::kChunkVolume);
        }
        _coarseBuffer = [_device newBufferWithBytes:coarse.data()
                                             length:coarse.size() * sizeof(uint32_t)
                                            options:MTLResourceStorageModeShared];
        _coarseBuffer.label = @"PTCoarse";
        _poolBuffer = [_device newBufferWithBytes:pool.data()
                                           length:pool.size()
                                          options:MTLResourceStorageModeShared];
        _poolBuffer.label = @"PTChunkPool";
    }

    // Path tracer wants linear-space color for physically-meaningful
    // multiplication. Palette comes in sRGB-ish (the standard storage for
    // 8-bit RGBA), so decode with the gamma-2.2 approximation here. The
    // display fragment re-encodes linear -> sRGB at output time.
    std::array<simd::float4, 256> pal_floats{};
    for (size_t i = 0; i < 256; ++i) {
        const macvoxel::Color c = doc->palette.Get(static_cast<uint8_t>(i));
        const float r = c.r / 255.0f;
        const float g = c.g / 255.0f;
        const float b = c.b / 255.0f;
        pal_floats[i] = simd::float4{
            std::pow(r, 2.2f),
            std::pow(g, 2.2f),
            std::pow(b, 2.2f),
            c.a / 255.0f,
        };
    }
    _paletteBuffer = [_device newBufferWithBytes:pal_floats.data()
                                          length:sizeof(pal_floats)
                                         options:MTLResourceStorageModeShared];
    _paletteBuffer.label = @"PTPalette";

    // Material buffer parallel to palette; one entry per palette index.
    std::array<GpuMaterial, 256> mats{};
    for (size_t i = 0; i < 256; ++i) {
        const macvoxel::Material m = doc->palette.GetMaterial(static_cast<uint8_t>(i));
        mats[i].type = static_cast<float>(static_cast<int>(m.type));
        mats[i].roughness = m.roughness;
        mats[i].metallic = m.metallic;
        mats[i].emission = macvoxel::EffectiveEmission(m);
        mats[i].transparency = m.transparency;
        mats[i].ior = m.ior;
        mats[i]._pad0 = 0.0f;
        mats[i]._pad1 = 0.0f;
    }
    _materialBuffer = [_device newBufferWithBytes:mats.data()
                                           length:sizeof(mats)
                                          options:MTLResourceStorageModeShared];
    _materialBuffer.label = @"PTMaterials";

    // Next-event estimation light list. One entry per emissive voxel
    // (with effective_emission > 0). Stored as { grid corner, linear
    // albedo × emission } so the shader can sample without a palette
    // lookup. We keep the buffer non-nil even when empty (Metal needs a
    // buffer bound at index 5) and gate use via _lightCount.
    std::vector<GpuLight> lights;
    lights.reserve(64);
    for (const auto& [coord, chunk] : chunks) {
        if (chunk->filled_count == 0) continue;
        const int32_t base_x = coord.x * static_cast<int32_t>(VG::kChunkSize);
        const int32_t base_y = coord.y * static_cast<int32_t>(VG::kChunkSize);
        const int32_t base_z = coord.z * static_cast<int32_t>(VG::kChunkSize);
        for (uint32_t lz = 0; lz < VG::kChunkSize; ++lz) {
            for (uint32_t ly = 0; ly < VG::kChunkSize; ++ly) {
                for (uint32_t lx = 0; lx < VG::kChunkSize; ++lx) {
                    const size_t li = lx + ly * VG::kChunkSize +
                                      lz * VG::kChunkSize * VG::kChunkSize;
                    const uint8_t v = chunk->cells[li];
                    if (v == 0) continue;
                    const macvoxel::Material m =
                        doc->palette.GetMaterial(v);
                    if (m.type != macvoxel::MaterialType::Emissive) continue;
                    const float eff = macvoxel::EffectiveEmission(m);
                    if (eff <= 0.0f) continue;
                    const macvoxel::Color c = doc->palette.Get(v);
                    GpuLight L;
                    L.pos = simd::float4{
                        static_cast<float>(base_x + static_cast<int32_t>(lx)),
                        static_cast<float>(base_y + static_cast<int32_t>(ly)),
                        static_cast<float>(base_z + static_cast<int32_t>(lz)),
                        0.0f,
                    };
                    L.le = simd::float4{
                        std::pow(c.r / 255.0f, 2.2f) * eff,
                        std::pow(c.g / 255.0f, 2.2f) * eff,
                        std::pow(c.b / 255.0f, 2.2f) * eff,
                        0.0f,
                    };
                    lights.push_back(L);
                }
            }
        }
    }
    _lightCount = static_cast<uint32_t>(lights.size());
    if (lights.empty()) {
        // One zero-init entry so the shader has a valid binding even
        // when no emissives exist; light_count == 0 keeps it unread.
        lights.resize(1);
    }
    _lightBuffer = [_device newBufferWithBytes:lights.data()
                                        length:lights.size() * sizeof(GpuLight)
                                       options:MTLResourceStorageModeShared];
    _lightBuffer.label = @"PTLights";

    _cachedDocVersion = doc->version;
    _resourcesValid = YES;
}

- (void)ensureAccumTextureForSize:(CGSize)size {
    if (_accumTexture != nil &&
        _accumSize.width == size.width &&
        _accumSize.height == size.height) {
        return;
    }
    MTLTextureDescriptor* td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                           width:static_cast<NSUInteger>(size.width)
                                                          height:static_cast<NSUInteger>(size.height)
                                                       mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    _accumTexture = [_device newTextureWithDescriptor:td];
    _accumTexture.label = @"PTAccum";
    _accumSize = size;
    _wantsClear = YES;
}

// FNV-1a over the camera state — cheap fingerprint for change detection.
- (uint64_t)hashCameraState:(const macvoxel::Camera&)camera {
    uint64_t h = 0xcbf29ce484222325ULL;
    auto mix = [&](float v) {
        uint32_t bits;
        std::memcpy(&bits, &v, 4);
        h ^= bits;
        h *= 0x100000001b3ULL;
    };
    mix(camera.target.x);
    mix(camera.target.y);
    mix(camera.target.z);
    mix(camera.distance);
    mix(camera.yaw);
    mix(camera.pitch);
    mix(camera.fov_y);
    return h;
}

- (void)renderInView:(MTKView*)view
                 cmd:(id<MTLCommandBuffer>)cmd
            document:(macvoxel::Document*)doc
              camera:(const macvoxel::Camera&)camera {
    if (doc == nullptr) return;
    const CGSize drawable = view.drawableSize;
    if (drawable.width <= 0.0 || drawable.height <= 0.0) return;

    const macvoxel::RenderState& rs = macvoxel::CurrentRenderState();
    CGSize size = drawable;
    if (!rs.resolution_match_window) {
        size.width  = std::max(1, std::min(rs.render_width,  16384));
        size.height = std::max(1, std::min(rs.render_height, 16384));
    }

    [self ensureAccumTextureForSize:size];
    if (!_resourcesValid || _cachedDocVersion != doc->version) {
        [self rebuildResourcesFromDocument:doc];
        _wantsClear = YES;
    }
    const uint64_t cam_hash = [self hashCameraState:camera];
    if (cam_hash != _lastCameraHash) {
        _lastCameraHash = cam_hash;
        _wantsClear = YES;
    }
    const macvoxel::GlassMode mode = macvoxel::CurrentRenderState().glass_mode;
    if (mode != _lastGlassMode) {
        _lastGlassMode = mode;
        _wantsClear = YES;
    }

    if (_wantsClear) {
        _sampleCount = 0;
        _wantsClear = NO;
    }

    if (_coarseBuffer == nil || _poolBuffer == nil ||
        _paletteBuffer == nil || _materialBuffer == nil) {
        // Nothing to trace; let the display pass clear to background.
        return;
    }

    // Stop contributing new samples once the cap is reached, or when
    // the app isn't active — there's no point burning GPU on a render
    // the user can't see (and on battery it matters). Display pass
    // below still runs so the image keeps showing the moment focus
    // returns.
    const int max_samples_cfg = std::max(
        1, macvoxel::CurrentRenderState().max_samples);
    const bool accumulate_more =
        _sampleCount < static_cast<uint32_t>(max_samples_cfg) &&
        [NSApp isActive];

    // ---------- Pass 1: accumulate one new sample into accum texture ----------
    if (accumulate_more) {
        [self encodeAccumulationSampleIntoCommandBuffer:cmd
                                                 camera:camera
                                                   size:size
                                             maxBounces:static_cast<uint32_t>(
                                                 macvoxel::CurrentRenderState().max_bounces)
                                              frameSeed:_sampleCount + 1u];
    }

    // ---------- Pass 2: divide accum by sample count, write to drawable ----
    {
        MTLRenderPassDescriptor* rpd = view.currentRenderPassDescriptor;
        if (rpd == nil) return;
        id<MTLRenderCommandEncoder> enc =
            [cmd renderCommandEncoderWithDescriptor:rpd];
        enc.label = @"PathTraceDisplay";

        DisplayUniforms du;
        du.sample_count = _sampleCount;
        du.aces_tonemap =
            macvoxel::CurrentRenderState().aces_tonemap ? 1u : 0u;
        // Aspect-preserving fit-to-window: render-aspect vs drawable-
        // aspect tells us which dimension is the limiter. Whichever
        // axis is over-large gets squeezed to a fraction of its NDC
        // extent; the other stays at 1.0.
        const float ar = static_cast<float>(_accumSize.width) /
                         static_cast<float>(_accumSize.height);
        const float ad = static_cast<float>(drawable.width) /
                         static_cast<float>(drawable.height);
        du.region_w = std::min(1.0f, ar / ad);
        du.region_h = std::min(1.0f, ad / ar);

        [enc setRenderPipelineState:_displayPipeline];
        [enc setCullMode:MTLCullModeNone];
        [enc setFragmentBytes:&du length:sizeof(du) atIndex:0];
        [enc setFragmentTexture:_accumTexture atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }

    macvoxel::CurrentRenderState().sample_count = _sampleCount;
}

// Encodes one accumulation pass into `cmd`, drawing into _accumTexture.
// All resource buffers (_coarseBuffer, _poolBuffer, etc.) and
// _accumTexture must already be set up by the caller. Increments
// _sampleCount; loadAction is Clear iff this is the first sample.
- (void)encodeAccumulationSampleIntoCommandBuffer:(id<MTLCommandBuffer>)cmd
                                            camera:(const macvoxel::Camera&)camera
                                              size:(CGSize)size
                                        maxBounces:(uint32_t)maxBounces
                                         frameSeed:(uint32_t)frameSeed {
    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = _accumTexture;
    rpd.colorAttachments[0].loadAction =
        (_sampleCount == 0) ? MTLLoadActionClear : MTLLoadActionLoad;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc =
        [cmd renderCommandEncoderWithDescriptor:rpd];
    enc.label = @"PathTraceAccumulate";

    const float aspect = static_cast<float>(size.width / size.height);
    const simd::float4x4 vmat = camera.ViewMatrix();
    const simd::float4x4 pmat = camera.ProjectionMatrix(aspect);
    const simd::float4x4 inv_vp = simd_inverse(pmat * vmat);

    PathUniforms u;
    u.inv_vp = inv_vp;
    u.camera_pos = camera.Position();
    u._pad0 = 0.0f;
    u.coarse_min = _coarseMin;
    u._pad1 = 0;
    u.coarse_dim = _coarseDim;
    u._pad2 = 0;
    u.sky_color = simd::float3{0.65f, 0.75f, 0.95f};
    u._pad3 = 0.0f;
    u.frame_seed = frameSeed;
    u.max_bounces = maxBounces;
    u.light_count = _lightCount;
    u.glass_mode = static_cast<uint32_t>(
        macvoxel::CurrentRenderState().glass_mode);

    [enc setRenderPipelineState:_pathPipeline];
    [enc setCullMode:MTLCullModeNone];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc setFragmentBuffer:_coarseBuffer offset:0 atIndex:1];
    [enc setFragmentBuffer:_poolBuffer offset:0 atIndex:2];
    [enc setFragmentBuffer:_paletteBuffer offset:0 atIndex:3];
    [enc setFragmentBuffer:_materialBuffer offset:0 atIndex:4];
    [enc setFragmentBuffer:_lightBuffer offset:0 atIndex:5];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    ++_sampleCount;
}

- (BOOL)renderHeadlessSamples:(uint32_t)samples
                     document:(macvoxel::Document*)doc
                       camera:(const macvoxel::Camera&)camera
                         size:(CGSize)size
                   maxBounces:(uint32_t)maxBounces
                     baseSeed:(uint32_t)baseSeed
                 commandQueue:(id<MTLCommandQueue>)queue
                        error:(NSError**)outError {
    if (doc == nullptr || queue == nil ||
        size.width <= 0.0 || size.height <= 0.0) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"MacVoxelHeadless" code:1
                       userInfo:@{NSLocalizedDescriptionKey:
                                      @"invalid headless render parameters"}];
        }
        return NO;
    }

    [self ensureAccumTextureForSize:size];
    [self rebuildResourcesFromDocument:doc];
    _sampleCount = 0;
    _wantsClear = NO;

    if (_coarseBuffer == nil || _poolBuffer == nil ||
        _paletteBuffer == nil || _materialBuffer == nil) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"MacVoxelHeadless" code:2
                       userInfo:@{NSLocalizedDescriptionKey:
                                      @"document has no voxels"}];
        }
        return NO;
    }

    id<MTLCommandBuffer> last = nil;
    for (uint32_t i = 0; i < samples; ++i) {
        @autoreleasepool {
            id<MTLCommandBuffer> cmd = [queue commandBuffer];
            cmd.label = @"PathTraceHeadless";
            [self encodeAccumulationSampleIntoCommandBuffer:cmd
                                                     camera:camera
                                                       size:size
                                                 maxBounces:maxBounces
                                                  frameSeed:baseSeed + i + 1u];
            [cmd commit];
            last = cmd;
        }
    }
    if (last != nil) [last waitUntilCompleted];
    return YES;
}

- (BOOL)exportPNGToURL:(NSURL*)url
          commandQueue:(id<MTLCommandQueue>)queue
                 error:(NSError**)outError {
    if (_accumTexture == nil || _displayPipeline == nil) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"MacVoxelExport" code:1
                       userInfo:@{NSLocalizedDescriptionKey:
                                      @"nothing rendered yet"}];
        }
        return NO;
    }

    // Shared-storage BGRA8 target so we can read it back after the GPU
    // is done. On Apple Silicon this is a single allocation visible to
    // both CPU and GPU — no blit needed.
    const NSUInteger w = static_cast<NSUInteger>(_accumSize.width);
    const NSUInteger h = static_cast<NSUInteger>(_accumSize.height);
    if (w == 0 || h == 0) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"MacVoxelExport" code:2
                       userInfo:@{NSLocalizedDescriptionKey:
                                      @"render target has zero size"}];
        }
        return NO;
    }
    MTLTextureDescriptor* td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:_colorFormat
                                                           width:w
                                                          height:h
                                                       mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> shot = [_device newTextureWithDescriptor:td];
    shot.label = @"PathTraceExport";

    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    cmd.label = @"PathTraceExport";

    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = shot;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc =
        [cmd renderCommandEncoderWithDescriptor:rpd];
    DisplayUniforms du;
    du.sample_count = _sampleCount;
    du.aces_tonemap =
        macvoxel::CurrentRenderState().aces_tonemap ? 1u : 0u;
    // Export target matches the accum exactly — no letterbox.
    du.region_w = 1.0f;
    du.region_h = 1.0f;
    [enc setRenderPipelineState:_displayPipeline];
    [enc setCullMode:MTLCullModeNone];
    [enc setFragmentBytes:&du length:sizeof(du) atIndex:0];
    [enc setFragmentTexture:_accumTexture atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];

    [cmd commit];
    [cmd waitUntilCompleted];

    // Pull pixels into a CPU buffer. We encode as RGBA so ImageIO
    // doesn't have to swap the channels itself.
    const size_t bytes_per_row = w * 4;
    std::vector<uint8_t> rgba(bytes_per_row * h);
    [shot getBytes:rgba.data()
       bytesPerRow:bytes_per_row
        fromRegion:MTLRegionMake2D(0, 0, w, h)
       mipmapLevel:0];
    if (_colorFormat == MTLPixelFormatBGRA8Unorm) {
        for (size_t i = 0; i < rgba.size(); i += 4) {
            std::swap(rgba[i + 0], rgba[i + 2]);
        }
    }

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider =
        CGDataProviderCreateWithData(nullptr, rgba.data(),
                                     rgba.size(), nullptr);
    const uint32_t bitmap_info = static_cast<uint32_t>(kCGBitmapByteOrderDefault) |
                                 static_cast<uint32_t>(kCGImageAlphaPremultipliedLast);
    CGImageRef img = CGImageCreate(
        w, h, 8, 32, bytes_per_row, cs, bitmap_info,
        provider, nullptr, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
    if (img == nullptr) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"MacVoxelExport" code:3
                       userInfo:@{NSLocalizedDescriptionKey:
                                      @"CGImageCreate failed"}];
        }
        return NO;
    }

    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier,
        1, nullptr);
    if (dest == nullptr) {
        CGImageRelease(img);
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"MacVoxelExport" code:4
                       userInfo:@{NSLocalizedDescriptionKey:
                                      @"could not create PNG destination"}];
        }
        return NO;
    }
    CGImageDestinationAddImage(dest, img, nullptr);
    const bool ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(img);
    if (!ok) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"MacVoxelExport" code:5
                       userInfo:@{NSLocalizedDescriptionKey:
                                      @"PNG write failed"}];
        }
        return NO;
    }
    return YES;
}

@end
