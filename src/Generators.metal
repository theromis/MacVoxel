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

// --- Explicit recursive-branching tree ------------------------------------
//
// Per cell, walk every branch in a fixed-depth nested tree (K=3 children
// per node, max depth 5) and take the min capsule SDF. Each child's
// `(pos, dir, length)` is computed from its parent's state via a
// hash-jittered tilt/rotation, so branches genuinely emerge from their
// parent's tip. This is brute-force but stays entirely on GPU and
// produces a real tree shape — no fractal-attractor sparseness, no
// KIFS rotation drift.
//
// Reused uniform fields:
//   noise_octaves   = max recursion depth (clamped 1..5)
//   noise_threshold = "wildness" — adds hash-based rotation jitter
//   noise_seed      = re-roll without changing other params
//   torus_tube      = base branch radius (trunk thickness); deeper
//                     levels taper by 0.78× per generation
//   palette_idx     = bark color
//   axis            = world axis pointing "up"
//
// `noise_scale` is ignored in this generator (kept for backward
// compatibility with the shared Perlin slider plumbing).

constant float TREE_BASE_LENGTH = 1.0;
constant float TREE_LENGTH_FALLOFF = 0.72;
constant float TREE_RADIUS_FALLOFF = 0.78;
constant float TREE_MAX_HEIGHT = TREE_BASE_LENGTH / (1.0 - TREE_LENGTH_FALLOFF);

static float tree_hash11(uint n) {
    n = (n ^ 61u) ^ (n >> 16);
    n *= 9u;
    n ^= n >> 4;
    n *= 0x27d4eb2du;
    n ^= n >> 15;
    return float(n & 0x00ffffffu) / float(0x01000000u);
}

static uint tree_mix_seed(uint a, uint b) {
    return a ^ (b + 0x9e3779b9u + (a << 6) + (a >> 2));
}

static float tree_capsule_de(float3 p, float3 a, float3 b, float r) {
    float3 ab = b - a;
    float3 ap = p - a;
    float ll = dot(ab, ab);
    float t = (ll > 1e-6) ? clamp(dot(ap, ab) / ll, 0.0, 1.0) : 0.0;
    float3 qv = ap - ab * t;
    return length(qv) - r;
}

static float3 tree_perp(float3 dir) {
    float3 ref = (abs(dir.x) < 0.9) ? float3(1.0, 0.0, 0.0)
                                    : float3(0.0, 0.0, 1.0);
    return normalize(cross(dir, ref));
}

// Compute child branch tip from parent tip+dir+segment_length. K=3
// children per parent, evenly distributed around `dir` axis with
// per-child hash jitter. tilt = base_tilt * (1 + jitter).
static void tree_grow_child(thread float3& pos, thread float3& dir,
                            thread float& seg_len, uint digit,
                            uint branch_seed, float base_tilt, float wild) {
    float3 perp1 = tree_perp(dir);
    float3 perp2 = cross(dir, perp1);

    const float K_INV = 1.0 / 3.0;
    float angle = (float(digit) + 0.5) * (2.0 * 3.14159265 * K_INV)
                + (tree_hash11(branch_seed + 13u) - 0.5) * wild * 0.7;
    float tilt = base_tilt
               * (1.0 + (tree_hash11(branch_seed + 29u) - 0.5) * wild * 0.5);

    seg_len *= TREE_LENGTH_FALLOFF;
    float ct = cos(tilt), st = sin(tilt);
    float ca = cos(angle), sa = sin(angle);
    float3 new_dir = ct * dir + st * (ca * perp1 + sa * perp2);
    pos = pos + new_dir * seg_len;
    dir = new_dir;
}

// Two-color tree evaluation. Bark de tracks the trunk plus all
// intermediate-level branches; leaf de only catches the deepest
// (depth==user's max) level. Caller picks palette based on which is
// smaller and ≤ 0.
static void tree_de(float3 p, constant Uniforms& u,
                    thread float& de_bark, thread float& de_leaf) {
    const uint depth = clamp(u.noise_octaves, 1u, 5u);
    const float base_radius = max(u.torus_tube, 0.05);
    const float wild = clamp(u.noise_threshold, 0.0, 1.0);
    const float base_tilt = mix(0.45, 0.85, wild);
    const uint root_seed = u.noise_seed * 2654435761u + 1u;

    // Trunk is always bark.
    float3 trunk_base = float3(0.0, 0.0, 0.0);
    float3 trunk_top  = float3(0.0, TREE_BASE_LENGTH, 0.0);
    float3 trunk_dir  = float3(0.0, 1.0, 0.0);
    float  trunk_len  = TREE_BASE_LENGTH;
    de_bark = tree_capsule_de(p, trunk_base, trunk_top, base_radius);
    de_leaf = 1e10;

    // 5 nested levels, unrolled. At each level we ask whether this is
    // the user's deepest level (level == depth) — if so the capsule
    // goes to leaf, else to bark.
    const uint K = 3u;
    if (depth >= 1u) {
        float r1 = base_radius * TREE_RADIUS_FALLOFF;
        bool leaf1 = (depth == 1u);
        for (uint d1 = 0u; d1 < K; ++d1) {
            float3 p1 = trunk_top; float3 v1 = trunk_dir; float l1 = trunk_len;
            uint s1 = tree_mix_seed(root_seed, d1 + 1u);
            tree_grow_child(p1, v1, l1, d1, s1, base_tilt, wild);
            float cd1 = tree_capsule_de(p, trunk_top, p1, r1);
            if (leaf1) de_leaf = min(de_leaf, cd1);
            else       de_bark = min(de_bark, cd1);

            if (depth >= 2u) {
                float r2 = r1 * TREE_RADIUS_FALLOFF;
                bool leaf2 = (depth == 2u);
                for (uint d2 = 0u; d2 < K; ++d2) {
                    float3 p2 = p1; float3 v2 = v1; float l2 = l1;
                    uint s2 = tree_mix_seed(s1, d2 + 1u);
                    tree_grow_child(p2, v2, l2, d2, s2, base_tilt, wild);
                    float cd2 = tree_capsule_de(p, p1, p2, r2);
                    if (leaf2) de_leaf = min(de_leaf, cd2);
                    else       de_bark = min(de_bark, cd2);

                    if (depth >= 3u) {
                        float r3 = r2 * TREE_RADIUS_FALLOFF;
                        bool leaf3 = (depth == 3u);
                        for (uint d3 = 0u; d3 < K; ++d3) {
                            float3 p3 = p2; float3 v3 = v2; float l3 = l2;
                            uint s3 = tree_mix_seed(s2, d3 + 1u);
                            tree_grow_child(p3, v3, l3, d3, s3, base_tilt, wild);
                            float cd3 = tree_capsule_de(p, p2, p3, r3);
                            if (leaf3) de_leaf = min(de_leaf, cd3);
                            else       de_bark = min(de_bark, cd3);

                            if (depth >= 4u) {
                                float r4 = r3 * TREE_RADIUS_FALLOFF;
                                bool leaf4 = (depth == 4u);
                                for (uint d4 = 0u; d4 < K; ++d4) {
                                    float3 p4 = p3; float3 v4 = v3; float l4 = l3;
                                    uint s4 = tree_mix_seed(s3, d4 + 1u);
                                    tree_grow_child(p4, v4, l4, d4, s4, base_tilt, wild);
                                    float cd4 = tree_capsule_de(p, p3, p4, r4);
                                    if (leaf4) de_leaf = min(de_leaf, cd4);
                                    else       de_bark = min(de_bark, cd4);

                                    if (depth >= 5u) {
                                        float r5 = r4 * TREE_RADIUS_FALLOFF;
                                        for (uint d5 = 0u; d5 < K; ++d5) {
                                            float3 p5 = p4; float3 v5 = v4; float l5 = l4;
                                            uint s5 = tree_mix_seed(s4, d5 + 1u);
                                            tree_grow_child(p5, v5, l5, d5, s5, base_tilt, wild);
                                            // depth==5: deepest, always leaf.
                                            de_leaf = min(de_leaf,
                                                tree_capsule_de(p, p4, p5, r5));
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

kernel void generate_tree(
    constant Uniforms& u                  [[buffer(0)]],
    texture3d<uint, access::write> tex_t  [[texture(0)]],
    texture3d<uint, access::write> oracle [[texture(1)]],
    uint3 gid                             [[thread_position_in_grid]])
{
    int3 cell_local, cell_world;
    if (!resolve_cell(gid, u, cell_local, cell_world)) return;

    uint write_val = 0u;
    if (in_bounds(cell_world, u)) {
        AxisView v = make_axis_view(cell_world, u);
        int axis = int(u.axis);
        int u_a = (axis == 0) ? 1 : 0;
        int v_a = (axis == 2) ? 1 : 2;

        // Fit gizmo's up-axis to the tree's maximum (perfectly vertical)
        // height — the geometric series sum of segment lengths. Real
        // trees rarely reach the full vertical extent because branches
        // tilt outward, so we give a bit of headroom (1.05×).
        const float fit = max(v.dim[axis] / (TREE_MAX_HEIGHT * 1.05), 0.0001);

        float up     = (v.pos[axis] - v.lo[axis]) / fit;
        float side_a = (v.pos[u_a] - (v.lo[u_a] + v.dim[u_a] * 0.5)) / fit;
        float side_b = (v.pos[v_a] - (v.lo[v_a] + v.dim[v_a] * 0.5)) / fit;
        // Optional flip so apex_at_max=0 grows the tree from the +axis face.
        if (u.apex_at_max == 0u) up = v.dim[axis] / fit - up;

        float3 p = float3(side_a, up, side_b);
        float de_bark, de_leaf;
        tree_de(p, u, de_bark, de_leaf);
        // Leaf wins when it's both inside and closer than bark; bark
        // covers everything else. perlin_palette_hi doubles as the
        // leaf color for Tree (the field is otherwise unused here).
        if (de_leaf <= 0.0 && de_leaf <= de_bark) {
            write_val = u.perlin_palette_hi;
        } else if (de_bark <= 0.0) {
            write_val = u.palette_idx;
        }
    }
    write_cell(cell_local, write_val, tex_t, oracle);
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
