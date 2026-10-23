// Mutator compute kernels — cursor-AOE rules that read existing voxel
// state (live-composited from tex_a + tex_t + preview_rem) and write a
// delta back to tex_t. Companion to Generators / Shape / Brush; one
// PSO per kind, dispatched by MutatorEngine.
//
// Output protocol:
//   buffer(0)  = MutatorUniforms (kind, dispatch bbox, AOE bbox, params)
//   texture(0) = tex_a (doc, R8Uint, access::read)
//   texture(1) = tex_t (additive preview, R8Uint, access::read_write)
//   texture(2) = tex_t oracle (R8Uint, access::write)
//   texture(3) = preview_rem (Remove-mask, R8Uint, access::read)
//
// Each thread covers one cell of the dispatch bbox; the AOE shape
// (sphere or cube, 2D or 3D) is evaluated inline against the brush
// footprint and threads outside the footprint early-return without
// touching anything.

#include <metal_stdlib>
using namespace metal;

struct MutatorUniforms {
    int3 dispatch_lo;   // texture-local
    int3 dispatch_size;
    int3 tex_origin;    // texture (0,0,0) in world cells
    int3 vol_min;       // EditVolume bounds (inclusive)
    int3 vol_max;
    int3 aoe_center;    // cursor cell, world coords
    int3 aoe_lo;        // AOE bbox min (world cells)
    int3 aoe_hi;        // AOE bbox max (world cells, inclusive)
    uint kind;          // 0 = Foliage
    uint seed_color;    // Foliage: palette index to detect & write
    float density;      // Foliage: probability per pass
    uint stroke_id;     // per-mouseDown RNG key
    int  brush_size;
    int  brush_shape;   // 0 = square (Chebyshev), 1 = circle (Euclidean)
    int  brush_3d;      // 0 = 2D slab on aoe_center's slice along face axis
    int  face_axis;     // for 2D mode
};

// PCG3D-style integer hash. Standard MSL-friendly RNG: three uint32s of
// state, one Wang-mix per axis, then a final round of avalanche.
// Returns a uniform float in [0, 1).
static float hash3(int3 c, uint stroke_id) {
    uint3 v = uint3(uint(c.x), uint(c.y), uint(c.z));
    v = v * 1664525u + uint3(1013904223u);
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    v.x ^= stroke_id * 2654435761u;
    v.y ^= stroke_id * 1597334677u;
    v.z ^= stroke_id * 374761393u;
    uint h = v.x ^ v.y ^ v.z;
    return float(h & 0x00ffffffu) / float(0x01000000u);
}

// Live-composited read at world cell `w`. preview_rem != 0 hides the
// doc cell; tex_t != 0 shadows it; otherwise tex_a wins. Same rule the
// rasterizer uses for compositing the preview surfaces.
static uint mutator_effective(int3 w,
                              int3 tex_origin,
                              texture3d<uint, access::read> tex_a,
                              texture3d<uint, access::read_write> tex_t,
                              texture3d<uint, access::read> preview_rem) {
    int3 local = w - tex_origin;
    int3 dims  = int3(int(tex_a.get_width()),
                      int(tex_a.get_height()),
                      int(tex_a.get_depth()));
    if (any(local < 0) || any(local >= dims)) return 0u;
    uint rem = preview_rem.read(uint3(local)).r;
    if (rem != 0u) return 0u;
    uint t = tex_t.read(uint3(local)).r;
    if (t != 0u) return t;
    return tex_a.read(uint3(local)).r;
}

// Distance from `cell` to `aoe_center` per the brush footprint shape.
// Returns negative-ish (we just compare to brush_size/2). 2D mode
// requires the cell to live on the aoe_center's slice along face_axis.
static bool in_aoe(int3 cell, constant MutatorUniforms& u) {
    if (u.brush_3d == 0) {
        int axdelta = (u.face_axis == 0) ? (cell.x - u.aoe_center.x)
                    : (u.face_axis == 1) ? (cell.y - u.aoe_center.y)
                                         : (cell.z - u.aoe_center.z);
        if (axdelta != 0) return false;
    }
    float3 delta = float3(cell - u.aoe_center);
    // Even-size brushes shift center between cells — same fixup the
    // shape/brush kernels do via `(lo + hi) / 2`.
    float c = float((-(u.brush_size - 1) / 2) + (u.brush_size / 2)) * 0.5;
    float3 d = delta - float3(c);
    float r = float(u.brush_size) * 0.5;
    if (u.brush_shape == 0) {
        // Square footprint: 2D slab uses 2D Chebyshev (skip the off-axis
        // dim so the cube doesn't bleed off the slice).
        if (u.brush_3d == 0) {
            float a = (u.face_axis == 0) ? max(abs(d.y), abs(d.z))
                    : (u.face_axis == 1) ? max(abs(d.x), abs(d.z))
                                         : max(abs(d.x), abs(d.y));
            return a <= r;
        }
        return max(max(abs(d.x), abs(d.y)), abs(d.z)) <= r;
    }
    // Circle footprint.
    if (u.brush_3d == 0) {
        float a, b;
        if (u.face_axis == 0)      { a = d.y; b = d.z; }
        else if (u.face_axis == 1) { a = d.x; b = d.z; }
        else                       { a = d.x; b = d.y; }
        return a * a + b * b <= r * r;
    }
    return dot(d, d) <= r * r;
}

kernel void foliage_main(
    constant MutatorUniforms& u                              [[buffer(0)]],
    texture3d<uint, access::read>           tex_a            [[texture(0)]],
    texture3d<uint, access::read_write>     tex_t            [[texture(1)]],
    texture3d<uint, access::write>          tex_t_oracle     [[texture(2)]],
    texture3d<uint, access::read>           preview_rem      [[texture(3)]],
    uint3 gid                                                [[thread_position_in_grid]])
{
    int3 d = int3(gid);
    if (any(d >= u.dispatch_size)) return;
    int3 cell_local = u.dispatch_lo + d;
    int3 cell_world = cell_local + u.tex_origin;

    // Edit-volume clip — Foliage never writes outside the edit volume.
    if (any(cell_world < u.vol_min) || any(cell_world > u.vol_max)) return;
    if (!in_aoe(cell_world, u)) return;

    // Don't overwrite existing voxels. Foliage v1 only adds.
    uint here = mutator_effective(cell_world, u.tex_origin,
                                  tex_a, tex_t, preview_rem);
    if (here != 0u) return;

    // Seed check: any 6-neighbor face cell with effective == seed_color.
    uint seed = u.seed_color;
    bool has_seed_neighbor = false;
    int3 offsets[6] = {
        int3(-1, 0, 0), int3(1, 0, 0),
        int3(0, -1, 0), int3(0, 1, 0),
        int3(0, 0, -1), int3(0, 0, 1),
    };
    for (int i = 0; i < 6; ++i) {
        uint v = mutator_effective(cell_world + offsets[i], u.tex_origin,
                                   tex_a, tex_t, preview_rem);
        if (v == seed) { has_seed_neighbor = true; break; }
    }
    if (!has_seed_neighbor) return;

    float r = hash3(cell_world, u.stroke_id);
    if (r >= u.density) return;

    tex_t.write(uint4(seed, 0u, 0u, 0u), uint3(cell_local));
    tex_t_oracle.write(uint4(1u, 0u, 0u, 0u),
                       uint3(uint3(cell_local) >> uint3(4u)));
}
