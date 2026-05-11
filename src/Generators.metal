// MSL source for every generator kernel. Kept as a single library so all
// kernels share the same Uniforms layout — adding a new kind is one kernel
// function plus one entry in `KernelNameForKind` in GeneratorEngine.mm.
//
// Output protocol (all kernels):
//   buffer(0) = Uniforms (bounds + params, packed below)
//   buffer(1) = atomic_uint counter (zeroed by the host before dispatch)
//   buffer(2) = device PackedCell* output of capacity ≥ bounds volume
// A thread that decides its cell is filled does:
//   slot = atomic_fetch_add_explicit(counter, 1, relaxed);
//   output[slot] = packed cell
// Threads dispatched outside the bounds (when the dispatch is rounded up
// to a multiple of the threadgroup size) early-return.

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    int3 lo;          // bounds min (x0, y0, z0)
    int3 dims;        // bounds size (x1 - x0 + 1, ...)
    uint palette_idx; // single-color kernels emit this as the cell's palette
    uint axis;        // 0 = X, 1 = Y, 2 = Z (cylinder/cone/pyramid axis)
    uint apex_at_max; // 0 = apex at -axis face, 1 = apex at +axis face
    uint pad;
    float noise_scale;        // Perlin: voxels per feature
    float noise_threshold;    // Perlin: fill when fBm ≥ threshold (0..1)
    uint  noise_octaves;      // Perlin: 1..6 fBm octaves
    uint  noise_seed;         // Perlin: lattice hash seed
    float torus_tube;         // Torus: tube thickness (0..1 of bounds half-extent)
    uint  perlin_palette_lo;  // Perlin: gradient endpoint at fBm = threshold
    uint  perlin_palette_hi;  // Perlin: gradient endpoint at fBm = 1
};

struct PackedCell { int x, y, z; uint palette; };

// Common: convert thread-position-in-grid to a cell coordinate inside
// the bounds, returning false if the thread is past the dispatch tail.
static bool resolve_cell(uint3 gid, constant Uniforms& u, thread int3& cell) {
    if (any(int3(gid) >= u.dims)) return false;
    cell = int3(gid) + u.lo;
    return true;
}

static void emit(int3 cell, uint palette,
                 device atomic_uint* counter,
                 device PackedCell* out) {
    uint slot = atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);
    out[slot] = PackedCell{cell.x, cell.y, cell.z, palette};
}

// Ellipsoid that exactly fits the bounding box: for box width W, the
// ellipsoid's half-extent on that axis is W/2. The center sits at the
// box's geometric center (between cells when W is even, on a cell when
// odd). A cell is filled when the squared sum of its normalized offsets
// from the center is ≤ 1.
kernel void generate_ellipsoid(
    constant Uniforms& u                  [[buffer(0)]],
    device atomic_uint* counter           [[buffer(1)]],
    device PackedCell* out                [[buffer(2)]],
    uint3 gid                             [[thread_position_in_grid]])
{
    int3 cell;
    if (!resolve_cell(gid, u, cell)) return;

    float3 center = float3(2 * u.lo + u.dims) * 0.5;  // (lo + (lo + dims)) / 2
    float3 half_ext = float3(u.dims) * 0.5;
    float3 norm = (float3(cell) + 0.5 - center) / half_ext;
    if (dot(norm, norm) <= 1.0) {
        emit(cell, u.palette_idx, counter, out);
    }
}

// Stack-allocated views of the int3 lo / dims / cell as float[3] so the
// axis-parameterized kernels below can index by `int axis` cleanly.
// MSL's vec3 [] indexing isn't reliable across address spaces, so this
// is the safe form.
struct AxisView {
    float lo[3];
    float dim[3];
    float pos[3];   // cell center (cell + 0.5) along each axis
};

static AxisView make_axis_view(int3 cell, constant Uniforms& u) {
    AxisView v;
    v.lo[0]  = float(u.lo.x);
    v.lo[1]  = float(u.lo.y);
    v.lo[2]  = float(u.lo.z);
    v.dim[0] = float(u.dims.x);
    v.dim[1] = float(u.dims.y);
    v.dim[2] = float(u.dims.z);
    v.pos[0] = float(cell.x) + 0.5;
    v.pos[1] = float(cell.y) + 0.5;
    v.pos[2] = float(cell.z) + 0.5;
    return v;
}

// Cylinder inscribed in the bounding box, symmetry axis = u.axis. The
// cross-section perpendicular to the axis fills the box's other two
// dimensions exactly — so a non-square cross-section produces an
// elliptical cylinder, matching the Ellipsoid convention. Height
// spans the full box along the axis (no taper).
kernel void generate_cylinder(
    constant Uniforms& u                  [[buffer(0)]],
    device atomic_uint* counter           [[buffer(1)]],
    device PackedCell* out                [[buffer(2)]],
    uint3 gid                             [[thread_position_in_grid]])
{
    int3 cell;
    if (!resolve_cell(gid, u, cell)) return;

    int axis = int(u.axis);
    int u_a = (axis == 0) ? 1 : 0;
    int v_a = (axis == 2) ? 1 : 2;
    AxisView v = make_axis_view(cell, u);

    float center_u = v.lo[u_a] + v.dim[u_a] * 0.5;
    float center_v = v.lo[v_a] + v.dim[v_a] * 0.5;
    float n_u = (v.pos[u_a] - center_u) / (v.dim[u_a] * 0.5);
    float n_v = (v.pos[v_a] - center_v) / (v.dim[v_a] * 0.5);

    if (n_u * n_u + n_v * n_v <= 1.0) {
        emit(cell, u.palette_idx, counter, out);
    }
}

// Cone with elliptical cross-section, base at one face of the box and
// apex at the opposite. Cross-section radius factor `r` runs linearly
// from 1 at the base (full-bounds ellipse) to 0 at the apex; a cell is
// filled when its normalized cross-section position has magnitude ≤ r.
kernel void generate_cone(
    constant Uniforms& u                  [[buffer(0)]],
    device atomic_uint* counter           [[buffer(1)]],
    device PackedCell* out                [[buffer(2)]],
    uint3 gid                             [[thread_position_in_grid]])
{
    int3 cell;
    if (!resolve_cell(gid, u, cell)) return;

    int axis = int(u.axis);
    int u_a = (axis == 0) ? 1 : 0;
    int v_a = (axis == 2) ? 1 : 2;
    AxisView v = make_axis_view(cell, u);

    float t = (v.pos[axis] - v.lo[axis]) / v.dim[axis];   // 0 at lo, 1 at hi
    float r = (u.apex_at_max != 0u) ? (1.0 - t) : t;      // 0 at apex, 1 at base
    if (r <= 0.0) return;

    float center_u = v.lo[u_a] + v.dim[u_a] * 0.5;
    float center_v = v.lo[v_a] + v.dim[v_a] * 0.5;
    float n_u = (v.pos[u_a] - center_u) / (v.dim[u_a] * 0.5);
    float n_v = (v.pos[v_a] - center_v) / (v.dim[v_a] * 0.5);

    if (n_u * n_u + n_v * n_v <= r * r) {
        emit(cell, u.palette_idx, counter, out);
    }
}

// Square-base pyramid: same shape as Cone but with a Chebyshev (max-
// norm) cross-section instead of Euclidean — so each layer is a square
// rather than an ellipse, tapering linearly to a point at the apex.
kernel void generate_pyramid(
    constant Uniforms& u                  [[buffer(0)]],
    device atomic_uint* counter           [[buffer(1)]],
    device PackedCell* out                [[buffer(2)]],
    uint3 gid                             [[thread_position_in_grid]])
{
    int3 cell;
    if (!resolve_cell(gid, u, cell)) return;

    int axis = int(u.axis);
    int u_a = (axis == 0) ? 1 : 0;
    int v_a = (axis == 2) ? 1 : 2;
    AxisView v = make_axis_view(cell, u);

    float t = (v.pos[axis] - v.lo[axis]) / v.dim[axis];
    float r = (u.apex_at_max != 0u) ? (1.0 - t) : t;
    if (r <= 0.0) return;

    float center_u = v.lo[u_a] + v.dim[u_a] * 0.5;
    float center_v = v.lo[v_a] + v.dim[v_a] * 0.5;
    float n_u = (v.pos[u_a] - center_u) / (v.dim[u_a] * 0.5);
    float n_v = (v.pos[v_a] - center_v) / (v.dim[v_a] * 0.5);

    if (max(abs(n_u), abs(n_v)) <= r) {
        emit(cell, u.palette_idx, counter, out);
    }
}

// Torus inscribed in the bounding box, symmetry axis = u.axis. The tube
// fully spans the axial direction; in the radial plane, the centerline
// circle sits at normalized radius (1 - tube), and the tube has
// normalized half-width `tube`. tube = 1 degenerates to a cylinder-ish
// solid; tube → 0 vanishes. Cross-section in the (radial, axial) plane
// is an ellipse, matching the Ellipsoid / Cylinder convention.
kernel void generate_torus(
    constant Uniforms& u                  [[buffer(0)]],
    device atomic_uint* counter           [[buffer(1)]],
    device PackedCell* out                [[buffer(2)]],
    uint3 gid                             [[thread_position_in_grid]])
{
    int3 cell;
    if (!resolve_cell(gid, u, cell)) return;

    const float tube = clamp(u.torus_tube, 0.0, 1.0);
    if (tube <= 0.001) return;

    int axis = int(u.axis);
    int u_a = (axis == 0) ? 1 : 0;
    int v_a = (axis == 2) ? 1 : 2;
    AxisView v = make_axis_view(cell, u);

    float center_a = v.lo[axis] + v.dim[axis] * 0.5;
    float center_u = v.lo[u_a] + v.dim[u_a] * 0.5;
    float center_v = v.lo[v_a] + v.dim[v_a] * 0.5;
    float n_a = (v.pos[axis] - center_a) / (v.dim[axis] * 0.5);
    float n_u = (v.pos[u_a] - center_u) / (v.dim[u_a] * 0.5);
    float n_v = (v.pos[v_a] - center_v) / (v.dim[v_a] * 0.5);

    float radial = sqrt(n_u * n_u + n_v * n_v);
    float dr = radial - (1.0 - tube);
    float er = dr / tube;
    if (er * er + n_a * n_a <= 1.0) {
        emit(cell, u.palette_idx, counter, out);
    }
}

// --- Perlin noise -----------------------------------------------------------
//
// Classic gradient noise on the integer lattice, summed across octaves as
// fBm. Output is normalized to roughly [0, 1] and thresholded — cells whose
// fBm value clears `noise_threshold` fill. Reproducible per `noise_seed`:
// the same (bounds, params, seed) tuple yields byte-identical results.

static uint perlin_hash(int3 c, uint seed) {
    uint h = uint(c.x) * 1597334677u;
    h = (h ^ (uint(c.y) * 3812015801u)) * 1597334677u;
    h = (h ^ (uint(c.z) * 2798796415u)) * 1597334677u;
    h = (h ^ seed) * 1597334677u;
    h ^= h >> 16;
    h *= 2246822507u;
    h ^= h >> 13;
    return h;
}

static float3 perlin_grad(int3 c, uint seed) {
    // Standard 12 edge-midpoint gradients of the unit cube — the
    // canonical Perlin gradient set.
    const float3 kGrads[12] = {
        float3( 1,  1,  0), float3(-1,  1,  0), float3( 1, -1,  0), float3(-1, -1,  0),
        float3( 1,  0,  1), float3(-1,  0,  1), float3( 1,  0, -1), float3(-1,  0, -1),
        float3( 0,  1,  1), float3( 0, -1,  1), float3( 0,  1, -1), float3( 0, -1, -1),
    };
    return kGrads[perlin_hash(c, seed) % 12u];
}

static float perlin_fade(float t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

static float perlin3(float3 p, uint seed) {
    int3 pi = int3(floor(p));
    float3 pf = p - float3(pi);
    float3 f = float3(perlin_fade(pf.x), perlin_fade(pf.y), perlin_fade(pf.z));

    float n000 = dot(perlin_grad(pi + int3(0,0,0), seed), pf - float3(0,0,0));
    float n100 = dot(perlin_grad(pi + int3(1,0,0), seed), pf - float3(1,0,0));
    float n010 = dot(perlin_grad(pi + int3(0,1,0), seed), pf - float3(0,1,0));
    float n110 = dot(perlin_grad(pi + int3(1,1,0), seed), pf - float3(1,1,0));
    float n001 = dot(perlin_grad(pi + int3(0,0,1), seed), pf - float3(0,0,1));
    float n101 = dot(perlin_grad(pi + int3(1,0,1), seed), pf - float3(1,0,1));
    float n011 = dot(perlin_grad(pi + int3(0,1,1), seed), pf - float3(0,1,1));
    float n111 = dot(perlin_grad(pi + int3(1,1,1), seed), pf - float3(1,1,1));

    float nx00 = mix(n000, n100, f.x);
    float nx10 = mix(n010, n110, f.x);
    float nx01 = mix(n001, n101, f.x);
    float nx11 = mix(n011, n111, f.x);
    float nxy0 = mix(nx00, nx10, f.y);
    float nxy1 = mix(nx01, nx11, f.y);
    return mix(nxy0, nxy1, f.z);
}

kernel void generate_perlin(
    constant Uniforms& u                  [[buffer(0)]],
    device atomic_uint* counter           [[buffer(1)]],
    device PackedCell* out                [[buffer(2)]],
    uint3 gid                             [[thread_position_in_grid]])
{
    int3 cell;
    if (!resolve_cell(gid, u, cell)) return;

    const float scale = max(u.noise_scale, 0.001);
    const uint octaves = clamp(u.noise_octaves, 1u, 8u);

    // Cell-center sampling, in feature-space (scale voxels per unit).
    float3 p = (float3(cell) + 0.5) / scale;

    float total = 0.0;
    float amp = 1.0;
    float total_amp = 0.0;
    for (uint o = 0u; o < octaves; ++o) {
        // 1013 keeps octave hashes far apart in seed-space so successive
        // octaves don't share lattice points.
        total += amp * perlin3(p, u.noise_seed + o * 1013u);
        total_amp += amp;
        amp *= 0.5;
        p *= 2.0;
    }
    // Perlin3 output sits in roughly [-0.87, 0.87]; the fBm sum (normalized
    // by total_amp) stays in the same range. Map to [0, 1] for threshold.
    float n = clamp((total / total_amp) * 0.5 + 0.5, 0.0, 1.0);
    if (n < u.noise_threshold) return;

    // Gradient-map the palette across the *above-threshold* portion of
    // the noise range so the full lo..hi range stays visible no matter
    // where the threshold sits. Threshold = 1 is the kernel's quiet
    // hint to bail (no cells will pass anyway).
    float gradient_span = 1.0 - u.noise_threshold;
    float t = (gradient_span > 1e-6) ? (n - u.noise_threshold) / gradient_span : 0.0;
    float lo = float(u.perlin_palette_lo);
    float hi = float(u.perlin_palette_hi);
    uint  palette = uint(clamp(round(mix(lo, hi, t)), 0.0, 255.0));
    emit(cell, palette, counter, out);
}
