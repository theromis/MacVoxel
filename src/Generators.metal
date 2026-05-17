// MSL source for every generator kernel. Kept as a single library so all
// kernels share the same Uniforms layout — adding a new kind is one kernel
// function plus one entry in `KernelNameForKind` in GeneratorEngine.mm.
//
// Output protocol (B3b: tex_t writer):
//   buffer(0)  = Uniforms (current bounds + dispatch bbox + params)
//   texture(0) = preview tex (tex_t), R8Uint, access::write
//   texture(1) = preview oracle, R8Uint, access::write
// Each thread covers exactly one cell in the dispatch bbox (which is
// the union of the previous dispatch's bbox + the current one — so
// cells that the old preview wrote but the new one doesn't cover
// naturally get zeroed). A thread that decides its cell is "inside
// the generator's current bounds AND passes the shape predicate"
// writes its palette to tex_t and marks the oracle; otherwise it
// writes 0. There is no CPU readback during a stroke — the rasterizer
// composites tex_t over the doc; commit promotes via a separate
// kernel.

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    int3 lo;          // current generator bounds min (x0, y0, z0) — world cells
    int3 dims;        // bounds size (x1 - x0 + 1, ...)
    uint palette_idx; // single-color kernels use this; Perlin computes a gradient
    uint axis;        // 0 = X, 1 = Y, 2 = Z (cylinder/cone/pyramid/torus axis)
    uint apex_at_max; // 0 = apex at -axis face, 1 = apex at +axis face
    uint pad0;
    float noise_scale;        // Perlin: voxels per feature
    float noise_threshold;    // Perlin: fill when fBm ≥ threshold (0..1)
    uint  noise_octaves;      // Perlin: 1..6 fBm octaves
    uint  noise_seed;         // Perlin: lattice hash seed
    float torus_tube;         // Torus: tube thickness (0..1 of bounds half-extent)
    uint  perlin_palette_lo;  // Perlin: gradient endpoint at fBm = threshold
    uint  perlin_palette_hi;  // Perlin: gradient endpoint at fBm = 1
    uint  pad1;
    int3  dispatch_lo;        // texture-local dispatch min
    int3  dispatch_size;      // dispatch dims
    int3  tex_origin;         // texture (0,0,0) in world cells (== EditVolume.lo)
};

// Common: convert thread-position-in-grid to the texture-local cell
// coordinate (cell_local) AND the world cell coordinate (cell_world).
// Returns false if the thread is past the dispatch tail.
static bool resolve_cell(uint3 gid, constant Uniforms& u,
                         thread int3& cell_local, thread int3& cell_world) {
    if (any(int3(gid) >= u.dispatch_size)) return false;
    cell_local = int3(gid) + u.dispatch_lo;
    cell_world = cell_local + u.tex_origin;
    return true;
}

static bool in_bounds(int3 cell_world, constant Uniforms& u) {
    return all(cell_world >= u.lo) &&
           all(cell_world < (u.lo + u.dims));
}

static void write_cell(int3 cell_local, uint write_val,
                       texture3d<uint, access::write> tex_t,
                       texture3d<uint, access::write> oracle) {
    tex_t.write(uint4(write_val, 0u, 0u, 0u), uint3(cell_local));
    if (write_val != 0u) {
        oracle.write(uint4(1u, 0u, 0u, 0u),
                     uint3(uint3(cell_local) >> uint3(4u)));
    }
}

// Ellipsoid that exactly fits the bounding box.
kernel void generate_ellipsoid(
    constant Uniforms& u                  [[buffer(0)]],
    texture3d<uint, access::write> tex_t  [[texture(0)]],
    texture3d<uint, access::write> oracle [[texture(1)]],
    uint3 gid                             [[thread_position_in_grid]])
{
    int3 cell_local, cell_world;
    if (!resolve_cell(gid, u, cell_local, cell_world)) return;

    uint write_val = 0u;
    if (in_bounds(cell_world, u)) {
        float3 center = float3(2 * u.lo + u.dims) * 0.5;
        float3 half_ext = float3(u.dims) * 0.5;
        float3 norm = (float3(cell_world) + 0.5 - center) / half_ext;
        if (dot(norm, norm) <= 1.0) write_val = u.palette_idx;
    }
    write_cell(cell_local, write_val, tex_t, oracle);
}

// Stack-allocated views of the int3 lo / dims / cell as float[3] so the
// axis-parameterized kernels below can index by `int axis` cleanly.
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

// Cylinder inscribed in the bounding box.
kernel void generate_cylinder(
    constant Uniforms& u                  [[buffer(0)]],
    texture3d<uint, access::write> tex_t  [[texture(0)]],
    texture3d<uint, access::write> oracle [[texture(1)]],
    uint3 gid                             [[thread_position_in_grid]])
{
    int3 cell_local, cell_world;
    if (!resolve_cell(gid, u, cell_local, cell_world)) return;

    uint write_val = 0u;
    if (in_bounds(cell_world, u)) {
        int axis = int(u.axis);
        int u_a = (axis == 0) ? 1 : 0;
        int v_a = (axis == 2) ? 1 : 2;
        AxisView v = make_axis_view(cell_world, u);
        float center_u = v.lo[u_a] + v.dim[u_a] * 0.5;
        float center_v = v.lo[v_a] + v.dim[v_a] * 0.5;
        float n_u = (v.pos[u_a] - center_u) / (v.dim[u_a] * 0.5);
        float n_v = (v.pos[v_a] - center_v) / (v.dim[v_a] * 0.5);
        if (n_u * n_u + n_v * n_v <= 1.0) write_val = u.palette_idx;
    }
    write_cell(cell_local, write_val, tex_t, oracle);
}

// Cone with elliptical cross-section.
kernel void generate_cone(
    constant Uniforms& u                  [[buffer(0)]],
    texture3d<uint, access::write> tex_t  [[texture(0)]],
    texture3d<uint, access::write> oracle [[texture(1)]],
    uint3 gid                             [[thread_position_in_grid]])
{
    int3 cell_local, cell_world;
    if (!resolve_cell(gid, u, cell_local, cell_world)) return;

    uint write_val = 0u;
    if (in_bounds(cell_world, u)) {
        int axis = int(u.axis);
        int u_a = (axis == 0) ? 1 : 0;
        int v_a = (axis == 2) ? 1 : 2;
        AxisView v = make_axis_view(cell_world, u);
        float t = (v.pos[axis] - v.lo[axis]) / v.dim[axis];
        float r = (u.apex_at_max != 0u) ? (1.0 - t) : t;
        if (r > 0.0) {
            float center_u = v.lo[u_a] + v.dim[u_a] * 0.5;
            float center_v = v.lo[v_a] + v.dim[v_a] * 0.5;
            float n_u = (v.pos[u_a] - center_u) / (v.dim[u_a] * 0.5);
            float n_v = (v.pos[v_a] - center_v) / (v.dim[v_a] * 0.5);
            if (n_u * n_u + n_v * n_v <= r * r) write_val = u.palette_idx;
        }
    }
    write_cell(cell_local, write_val, tex_t, oracle);
}

// Square-base pyramid.
kernel void generate_pyramid(
    constant Uniforms& u                  [[buffer(0)]],
    texture3d<uint, access::write> tex_t  [[texture(0)]],
    texture3d<uint, access::write> oracle [[texture(1)]],
    uint3 gid                             [[thread_position_in_grid]])
{
    int3 cell_local, cell_world;
    if (!resolve_cell(gid, u, cell_local, cell_world)) return;

    uint write_val = 0u;
    if (in_bounds(cell_world, u)) {
        int axis = int(u.axis);
        int u_a = (axis == 0) ? 1 : 0;
        int v_a = (axis == 2) ? 1 : 2;
        AxisView v = make_axis_view(cell_world, u);
        float t = (v.pos[axis] - v.lo[axis]) / v.dim[axis];
        float r = (u.apex_at_max != 0u) ? (1.0 - t) : t;
        if (r > 0.0) {
            float center_u = v.lo[u_a] + v.dim[u_a] * 0.5;
            float center_v = v.lo[v_a] + v.dim[v_a] * 0.5;
            float n_u = (v.pos[u_a] - center_u) / (v.dim[u_a] * 0.5);
            float n_v = (v.pos[v_a] - center_v) / (v.dim[v_a] * 0.5);
            if (max(abs(n_u), abs(n_v)) <= r) write_val = u.palette_idx;
        }
    }
    write_cell(cell_local, write_val, tex_t, oracle);
}

// Torus inscribed in the bounding box.
kernel void generate_torus(
    constant Uniforms& u                  [[buffer(0)]],
    texture3d<uint, access::write> tex_t  [[texture(0)]],
    texture3d<uint, access::write> oracle [[texture(1)]],
    uint3 gid                             [[thread_position_in_grid]])
{
    int3 cell_local, cell_world;
    if (!resolve_cell(gid, u, cell_local, cell_world)) return;

    uint write_val = 0u;
    if (in_bounds(cell_world, u)) {
        const float tube = clamp(u.torus_tube, 0.0, 1.0);
        if (tube > 0.001) {
            int axis = int(u.axis);
            int u_a = (axis == 0) ? 1 : 0;
            int v_a = (axis == 2) ? 1 : 2;
            AxisView v = make_axis_view(cell_world, u);
            float center_a = v.lo[axis] + v.dim[axis] * 0.5;
            float center_u = v.lo[u_a] + v.dim[u_a] * 0.5;
            float center_v = v.lo[v_a] + v.dim[v_a] * 0.5;
            float n_a = (v.pos[axis] - center_a) / (v.dim[axis] * 0.5);
            float n_u = (v.pos[u_a] - center_u) / (v.dim[u_a] * 0.5);
            float n_v = (v.pos[v_a] - center_v) / (v.dim[v_a] * 0.5);
            float radial = sqrt(n_u * n_u + n_v * n_v);
            float dr = radial - (1.0 - tube);
            float er = dr / tube;
            if (er * er + n_a * n_a <= 1.0) write_val = u.palette_idx;
        }
    }
    write_cell(cell_local, write_val, tex_t, oracle);
}

// --- Perlin noise -----------------------------------------------------------

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
    texture3d<uint, access::write> tex_t  [[texture(0)]],
    texture3d<uint, access::write> oracle [[texture(1)]],
    uint3 gid                             [[thread_position_in_grid]])
{
    int3 cell_local, cell_world;
    if (!resolve_cell(gid, u, cell_local, cell_world)) return;

    uint write_val = 0u;
    if (in_bounds(cell_world, u)) {
        const float scale = max(u.noise_scale, 0.001);
        const uint octaves = clamp(u.noise_octaves, 1u, 8u);
        float3 p = (float3(cell_world) + 0.5) / scale;
        float total = 0.0;
        float amp = 1.0;
        float total_amp = 0.0;
        for (uint o = 0u; o < octaves; ++o) {
            total += amp * perlin3(p, u.noise_seed + o * 1013u);
            total_amp += amp;
            amp *= 0.5;
            p *= 2.0;
        }
        float n = clamp((total / total_amp) * 0.5 + 0.5, 0.0, 1.0);
        if (n >= u.noise_threshold) {
            float gradient_span = 1.0 - u.noise_threshold;
            float t = (gradient_span > 1e-6) ?
                      (n - u.noise_threshold) / gradient_span : 0.0;
            float lo = float(u.perlin_palette_lo);
            float hi = float(u.perlin_palette_hi);
            write_val = uint(clamp(round(mix(lo, hi, t)), 0.0, 255.0));
        }
    }
    write_cell(cell_local, write_val, tex_t, oracle);
}
