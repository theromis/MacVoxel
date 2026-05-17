// Shape tool compute kernels — Magica's "shape tools as shaders"
// idea adapted to Metal compute, writing into the preview texture
// (`tex_t`) instead of the doc texture. The rasterizer composites
// tex_t over tex_a so previews appear immediately; on commit the
// preview is promoted into the doc (ShapeEngine.commitInto: kernel).
//
// One unified `shape_main` covers Line / Circle / Square / Box —
// each thread evaluates an analytic shape-SDF expanded by the brush
// footprint, writes palette / 0 to tex_t accordingly. The dispatch
// bbox is the UNION of the previous frame's bbox + the current
// frame's, so cells the previous frame wrote and the current frame
// doesn't naturally get zeroed out.
//
// Variants supported in v1:
//   * Shape: Line, Circle, Square, Box  (kinds 0..3)
//   * Fill: filled OR shell (`shape_fill`)
//   * Brush footprint: Square (L_inf) or Circle (L_2 / Euclidean)
//   * Brush dim: 3D only — kernel returns nothing when `brush_3d == 0`
//     (2D-slice variants are not yet implemented).
//   * Mode: Add, Paint, Remove (Remove writes 0 to tex_t for now;
//     end-of-stroke commit handles the actual cell removal).

#include <metal_stdlib>
using namespace metal;

constant uint kModeAdd    = 0u;
constant uint kModeRemove = 1u;
constant uint kModePaint  = 2u;

// commit_generic blend modes (Magica's shader_0018 `bm` selector).
// Distinct from kModeAdd/Remove/Paint — these are 1-indexed and add
// Intersect as bm=4. Phase 2.2+ routes all per-tool commit kernels
// through this one.
constant uint kCommitBmAdd       = 1u;  // r = a > 0 ? a : t
constant uint kCommitBmErase     = 2u;  // r = t > 0 ? 0 : a
constant uint kCommitBmReplace   = 3u;  // r = (a&&t) > 0 ? t : a
constant uint kCommitBmIntersect = 4u;  // r = (a&&t) > 0 ? t : 0

// commit_generic source selector for the per-cell "t" value.
constant uint kCommitBrushPreview  = 0u;  // sample preview (tex_t)
constant uint kCommitBrushConstant = 1u;  // use uniforms.fill_palette

constant int kShapeLine   = 0;
constant int kShapeCircle = 1;
constant int kShapeSquare = 2;
constant int kShapeBox    = 3;

constant int kBrushSquare = 0;
constant int kBrushCircle = 1;

struct ShapeUniforms {
    int3 anchor;            // anchor cell (click 1)
    int3 endpoint;          // endpoint cell (current cursor)
    int  face_axis;         // 0/1/2 for planar shapes
    int  brush_size;
    int  brush_shape;       // 0 square, 1 circle
    int  brush_3d;          // 1 = 3D, 0 = 2D slice
    uint mode;              // 0 add / 1 remove / 2 paint
    uint palette_idx;
    int  shape_kind;        // 0..3
    int  shape_fill;        // 1 = filled, 0 = shell/outline
    int  shape_even;        // circle/square even-diameter toggle
    int  line_straight;     // 1 = 3D Bresenham, 0 = project mode
                            //   (project handled CPU-side; we draw
                            //   straight even for project so the
                            //   preview at least reflects something
                            //   useful until project kernel exists).
    int3 dispatch_lo;       // bbox to write (texture-local cells)
    int3 dispatch_size;     // dims of the dispatch bbox
    int3 vol_min;           // edit-volume bounds (inclusive)
    int3 vol_max;           // edit-volume bounds (inclusive)
    int3 tex_origin;        // texture's [0,0,0] in world cell coords
};

// Brush footprint test in world coords. Returns the L_inf or L_2
// distance from `delta` (an offset vector) to "the center of a brush
// of side `size`". Even sizes shift center between cells.
static float brush_footprint_distance(float3 delta, int size, int brush_shape) {
    const float c = float((-(size - 1) / 2) + (size / 2)) * 0.5;
    float fdx = delta.x - c;
    float fdy = delta.y - c;
    float fdz = delta.z - c;
    if (brush_shape == kBrushSquare) {
        return max(max(abs(fdx), abs(fdy)), abs(fdz));
    }
    return sqrt(fdx * fdx + fdy * fdy + fdz * fdz);
}

// Distance from cell-center C to a continuous line segment.
static float3 segment_closest(float3 C, float3 a, float3 b) {
    float3 v = b - a;
    float vv = dot(v, v);
    if (vv < 1e-6) return a;
    float t = clamp(dot(C - a, v) / vv, 0.0, 1.0);
    return a + v * t;
}

// Filled axis-aligned box SDF (negative inside, distance to surface
// outside). For a box bounded by inclusive cell coords [lo, hi].
static float box_distance(float3 C, float3 lo, float3 hi, int brush_shape) {
    float3 closest;
    closest.x = clamp(C.x, lo.x, hi.x);
    closest.y = clamp(C.y, lo.y, hi.y);
    closest.z = clamp(C.z, lo.z, hi.z);
    if (brush_shape == kBrushSquare) {
        return max(max(abs(C.x - closest.x), abs(C.y - closest.y)),
                   abs(C.z - closest.z));
    }
    float dx = C.x - closest.x;
    float dy = C.y - closest.y;
    float dz = C.z - closest.z;
    return sqrt(dx * dx + dy * dy + dz * dz);
}

// Test cell against the shape (with brush-footprint expansion in 3D).
static bool cell_in_shape(int3 cell_world, constant ShapeUniforms& u) {
    const float r = float(u.brush_size) * 0.5;
    float3 C = float3(cell_world) + 0.5;

    if (u.shape_kind == kShapeLine) {
        float3 a = float3(u.anchor) + 0.5;
        float3 b = float3(u.endpoint) + 0.5;
        float3 closest = segment_closest(C, a, b);
        float3 d = C - closest;
        float dist = (u.brush_shape == kBrushSquare)
            ? max(max(abs(d.x), abs(d.y)), abs(d.z))
            : sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
        return dist <= r;
    }

    if (u.shape_kind == kShapeBox) {
        // Box bounded by min/max of anchor and endpoint (componentwise).
        float3 lo = float3(min(u.anchor, u.endpoint));
        float3 hi = float3(max(u.anchor, u.endpoint)) + 1.0;  // +1 for exclusive max
        float d = box_distance(C, lo, hi - 1.0, u.brush_shape);
        if (u.shape_fill != 0) return d <= r;
        // Shell: surface band of width 2r around the box surface.
        // Distance to surface = 0 if on surface, abs(signed_box_dist).
        // For points outside box, d > 0 = distance to surface.
        // For points inside box, we need min(C - lo, hi - 1 - C) per axis.
        float3 inside_d = min(C - lo, (hi - 1.0) - C);
        float inside_min = min(min(inside_d.x, inside_d.y), inside_d.z);
        // If inside_min > 0 the point is strictly inside the box; the
        // distance to the surface is inside_min itself. If outside, d > 0.
        float surf_dist = (inside_min > 0.0) ? inside_min : d;
        return surf_dist <= r;
    }

    if (u.shape_kind == kShapeCircle || u.shape_kind == kShapeSquare) {
        // Planar shapes live in the plane perpendicular to face_axis,
        // anchored at the anchor cell. The radius is the in-plane
        // distance from anchor to endpoint.
        int ax = u.face_axis;
        // Pick the two in-plane axes.
        int u_axis = (ax == 0) ? 1 : 0;
        int v_axis = (ax == 2) ? 1 : 2;
        if (ax == 0) { u_axis = 1; v_axis = 2; }
        else if (ax == 1) { u_axis = 0; v_axis = 2; }
        else { u_axis = 0; v_axis = 1; }

        float Cu, Cv;
        if (ax == 0) { Cu = C.y; Cv = C.z; }
        else if (ax == 1) { Cu = C.x; Cv = C.z; }
        else { Cu = C.x; Cv = C.y; }
        float anchor_u, anchor_v;
        if (ax == 0) { anchor_u = float(u.anchor.y); anchor_v = float(u.anchor.z); }
        else if (ax == 1) { anchor_u = float(u.anchor.x); anchor_v = float(u.anchor.z); }
        else { anchor_u = float(u.anchor.x); anchor_v = float(u.anchor.y); }
        float endpoint_u, endpoint_v;
        if (ax == 0) { endpoint_u = float(u.endpoint.y); endpoint_v = float(u.endpoint.z); }
        else if (ax == 1) { endpoint_u = float(u.endpoint.x); endpoint_v = float(u.endpoint.z); }
        else { endpoint_u = float(u.endpoint.x); endpoint_v = float(u.endpoint.y); }

        float du = endpoint_u - anchor_u;
        float dv = endpoint_v - anchor_v;
        float radius = sqrt(du * du + dv * dv);
        // Out-of-plane (along face_axis) distance — used as part of
        // the 3D brush expansion (the planar shape thickens by the
        // brush in the face_axis direction).
        float C_ax = (ax == 0) ? C.x : (ax == 1) ? C.y : C.z;
        float anchor_ax = (ax == 0) ? float(u.anchor.x)
                       : (ax == 1) ? float(u.anchor.y) : float(u.anchor.z);
        float out_of_plane = abs(C_ax - (anchor_ax + 0.5));

        anchor_u += 0.5;
        anchor_v += 0.5;
        float duC = Cu - anchor_u;
        float dvC = Cv - anchor_v;

        if (u.shape_kind == kShapeCircle) {
            float in_plane_dist = sqrt(duC * duC + dvC * dvC);
            float dist_to_shape;
            if (u.shape_fill != 0) {
                dist_to_shape = max(0.0, in_plane_dist - radius);
            } else {
                // Ring: distance from C to circle perimeter.
                dist_to_shape = abs(in_plane_dist - radius);
            }
            float total;
            if (u.brush_shape == kBrushSquare) {
                total = max(dist_to_shape, out_of_plane);
            } else {
                total = sqrt(dist_to_shape * dist_to_shape +
                             out_of_plane * out_of_plane);
            }
            return total <= r;
        }

        // Square (planar) — Chebyshev (L_inf) version of the circle.
        float chebyshev = max(abs(duC), abs(dvC));
        float dist_to_shape;
        if (u.shape_fill != 0) {
            dist_to_shape = max(0.0, chebyshev - radius);
        } else {
            dist_to_shape = abs(chebyshev - radius);
        }
        float total;
        if (u.brush_shape == kBrushSquare) {
            total = max(dist_to_shape, out_of_plane);
        } else {
            total = sqrt(dist_to_shape * dist_to_shape +
                         out_of_plane * out_of_plane);
        }
        return total <= r;
    }

    return false;
}

kernel void shape_main(
    constant ShapeUniforms& u                       [[buffer(0)]],
    texture3d<uint, access::read>       tex_a       [[texture(0)]],
    texture3d<uint, access::write>      preview     [[texture(1)]],
    texture3d<uint, access::write>      preview_oracle [[texture(2)]],
    uint3 gid                                       [[thread_position_in_grid]])
{
    int3 d = int3(gid);
    if (any(d >= u.dispatch_size)) return;

    int3 cell_local = u.dispatch_lo + d;  // texture-local coords
    int3 cell_world = cell_local + u.tex_origin;

    bool in_shape = false;
    if (u.brush_3d != 0) {
        in_shape = cell_in_shape(cell_world, u);
    }

    uint write_val = 0u;
    if (in_shape) {
        // Mode rule: Add only writes when the doc cell is currently
        // empty (so the preview shows added voxels but doesn't paint
        // over existing ones). Remove always writes 0 here — the
        // commit kernel handles the actual cell zeroing; the visual
        // gap is a known v1 wart. Paint only writes where the doc
        // has a non-empty cell.
        uint doc_val = tex_a.read(uint3(cell_local)).r;
        bool in_vol = all(cell_world >= u.vol_min) &&
                      all(cell_world <= u.vol_max);
        if (u.mode == kModeAdd) {
            if (doc_val == 0u && in_vol) write_val = u.palette_idx;
        } else if (u.mode == kModePaint) {
            if (doc_val != 0u) write_val = u.palette_idx;
        }
        // kModeRemove: leaves write_val = 0 (silent preview).
    }

    preview.write(uint4(write_val, 0u, 0u, 0u), uint3(cell_local));
    if (write_val != 0u) {
        preview_oracle.write(uint4(1u, 0u, 0u, 0u),
                             uint3(uint3(cell_local) >> uint3(4u)));
    }
}

// Line tool's "project" mode kernel. The picked cells (one per
// oversampled screen-space step, deduped) live in a constant buffer
// uploaded by the CPU; the kernel runs over the union bbox and
// writes palette / 0 to each cell based on whether any picked cell
// is within the brush footprint. Same mode-rule + footprint shape
// + 3D/2D-brush handling as `shape_main`.
struct PackedCellXYZ { int x, y, z, _pad; };

kernel void shape_line_project_main(
    constant ShapeUniforms& u                            [[buffer(0)]],
    constant PackedCellXYZ* cells                        [[buffer(1)]],
    constant uint& cell_count                            [[buffer(2)]],
    texture3d<uint, access::read>       tex_a            [[texture(0)]],
    texture3d<uint, access::write>      preview          [[texture(1)]],
    texture3d<uint, access::write>      preview_oracle   [[texture(2)]],
    uint3 gid                                            [[thread_position_in_grid]])
{
    int3 d = int3(gid);
    if (any(d >= u.dispatch_size)) return;
    int3 cell_local = u.dispatch_lo + d;
    int3 cell_world = cell_local + u.tex_origin;

    const float r = float(u.brush_size) * 0.5;
    const float c = float((-(u.brush_size - 1) / 2) + (u.brush_size / 2)) * 0.5;

    bool in_shape = false;
    for (uint i = 0; i < cell_count && !in_shape; ++i) {
        int3 L = int3(cells[i].x, cells[i].y, cells[i].z);
        float3 delta = float3(cell_world - L);
        float fdx = delta.x - c;
        float fdy = delta.y - c;
        float fdz = delta.z - c;
        if (u.brush_3d == 0) {
            // 2D slab: cell must be on the line cell's slice along face_axis.
            int ax_delta;
            if (u.face_axis == 0) ax_delta = cell_world.x - L.x;
            else if (u.face_axis == 1) ax_delta = cell_world.y - L.y;
            else ax_delta = cell_world.z - L.z;
            if (ax_delta != 0) continue;
            float pa, pb;
            if (u.face_axis == 0) { pa = fdy; pb = fdz; }
            else if (u.face_axis == 1) { pa = fdx; pb = fdz; }
            else { pa = fdx; pb = fdy; }
            float dist = (u.brush_shape == kBrushSquare)
                ? max(abs(pa), abs(pb))
                : sqrt(pa * pa + pb * pb);
            if (dist <= r) in_shape = true;
        } else {
            float dist = (u.brush_shape == kBrushSquare)
                ? max(max(abs(fdx), abs(fdy)), abs(fdz))
                : sqrt(fdx * fdx + fdy * fdy + fdz * fdz);
            if (dist <= r) in_shape = true;
        }
    }

    uint write_val = 0u;
    if (in_shape) {
        uint doc_val = tex_a.read(uint3(cell_local)).r;
        bool in_vol = all(cell_world >= u.vol_min) &&
                      all(cell_world <= u.vol_max);
        if (u.mode == kModeAdd) {
            if (doc_val == 0u && in_vol) write_val = u.palette_idx;
        } else if (u.mode == kModePaint) {
            if (doc_val != 0u) write_val = u.palette_idx;
        }
    }
    preview.write(uint4(write_val, 0u, 0u, 0u), uint3(cell_local));
    if (write_val != 0u) {
        preview_oracle.write(uint4(1u, 0u, 0u, 0u),
                             uint3(uint3(cell_local) >> uint3(4u)));
    }
}

// "Stamp a list of (cell, palette) entries into tex_t" — one thread
// per buffer entry. Used by the Face tool, where CPU does the
// flood-fill + mode-aware enumeration (per-cell target palette,
// 0 meaning "remove this cell on commit") and the kernel just writes
// the resulting palette into tex_t. Cells with palette == 0 are
// stamped as 0 too; the preview won't render them but the commit
// kernel still touches them so a Face-Remove stroke writes 0 into
// the doc on commit.
struct StampCellsUniforms {
    int3 tex_origin;
    int  _pad;
};

struct CellPalette { int x, y, z; uint palette; };

kernel void shape_stamp_cells(
    constant StampCellsUniforms& u                  [[buffer(0)]],
    constant CellPalette* cells                     [[buffer(1)]],
    constant uint&        cell_count                [[buffer(2)]],
    texture3d<uint, access::write> preview          [[texture(0)]],
    texture3d<uint, access::write> preview_oracle   [[texture(1)]],
    uint gid                                        [[thread_position_in_grid]])
{
    if (gid >= cell_count) return;
    CellPalette c = cells[gid];
    int3 cell_local = int3(c.x, c.y, c.z) - u.tex_origin;
    int3 dims = int3(preview.get_width(),
                     preview.get_height(),
                     preview.get_depth());
    if (any(cell_local < 0) || any(cell_local >= dims)) return;
    preview.write(uint4(c.palette, 0u, 0u, 0u), uint3(cell_local));
    if (c.palette != 0u) {
        preview_oracle.write(uint4(1u, 0u, 0u, 0u),
                             uint3(uint3(cell_local) >> uint3(4u)));
    }
}

// Per-cell commit: write each buffer entry's `palette` directly to
// tex_a and clear the corresponding tex_t cell. Unlike `shape_commit`
// (which iterates a bbox + applies u.mode), this kernel acts on a
// CPU-provided cell list and writes whatever the CPU chose as the
// target value — so it handles all four Face modes uniformly
// (Add/Paint/Remove all collapse into "set tex_a[cell] = palette").
kernel void shape_commit_cells(
    constant StampCellsUniforms& u                          [[buffer(0)]],
    constant CellPalette* cells                             [[buffer(1)]],
    constant uint&        cell_count                        [[buffer(2)]],
    texture3d<uint, access::read_write> tex_a               [[texture(0)]],
    texture3d<uint, access::read_write> preview             [[texture(1)]],
    texture3d<uint, access::write>      doc_oracle          [[texture(2)]],
    uint gid                                                [[thread_position_in_grid]])
{
    if (gid >= cell_count) return;
    CellPalette c = cells[gid];
    int3 cell_local = int3(c.x, c.y, c.z) - u.tex_origin;
    int3 dims = int3(tex_a.get_width(),
                     tex_a.get_height(),
                     tex_a.get_depth());
    if (any(cell_local < 0) || any(cell_local >= dims)) return;
    tex_a.write(uint4(c.palette, 0u, 0u, 0u), uint3(cell_local));
    preview.write(uint4(0u, 0u, 0u, 0u), uint3(cell_local));
    if (c.palette != 0u) {
        doc_oracle.write(uint4(1u, 0u, 0u, 0u),
                         uint3(uint3(cell_local) >> uint3(4u)));
    }
}

// Clear-bbox kernel — zeros a 3D region of tex_t. Called between
// strokes (and at the start of each stamp to drop the previous
// frame's preview).
kernel void shape_clear(
    constant ShapeUniforms& u             [[buffer(0)]],
    texture3d<uint, access::write> preview [[texture(0)]],
    uint3 gid                              [[thread_position_in_grid]])
{
    int3 d = int3(gid);
    if (any(d >= u.dispatch_size)) return;
    int3 cell_local = u.dispatch_lo + d;
    preview.write(uint4(0u, 0u, 0u, 0u), uint3(cell_local));
}

// Generic commit kernel — the Magica `shader_0018.glsl` shape. Loops
// over a dispatch bbox, reads doc + a source value (tex_t or constant
// fill), blends via `bm`, writes the result to tex_a. Clears tex_t in
// the bbox so a subsequent stroke starts clean. Replaces the per-tool
// commit kernels in Phase 2.2-2.5 — the bm/brush parameterization
// covers Add / Erase / Replace / Intersect uniformly.
//
// Phase 2.1 (this commit): kernel exists but has no callers. Phases
// 2.2-2.4 wire shape / generator / face / brush onto it.
struct CommitGenericUniforms {
    int3 dispatch_lo;     // bbox start (texture-local cells)
    int  _pad0;
    int3 dispatch_size;   // bbox dims
    int  _pad1;
    uint bm;              // 1=Add 2=Erase 3=Replace 4=Intersect
    uint brush;           // 0=tex_t source, 1=constant fill_palette
    uint fill_palette;    // used when brush == 1
    uint _pad2;
};

kernel void commit_generic(
    constant CommitGenericUniforms&       u           [[buffer(0)]],
    texture3d<uint, access::read_write>   tex_a       [[texture(0)]],
    texture3d<uint, access::read_write>   preview     [[texture(1)]],
    texture3d<uint, access::write>        doc_oracle  [[texture(2)]],
    uint3                                  gid         [[thread_position_in_grid]])
{
    int3 d = int3(gid);
    if (any(d >= u.dispatch_size)) return;
    int3 cell_local = u.dispatch_lo + d;

    uint a = tex_a.read(uint3(cell_local)).r;
    uint t;
    if (u.brush == kCommitBrushPreview) {
        t = preview.read(uint3(cell_local)).r;
    } else {
        t = u.fill_palette;
    }

    uint r = a;
    if (u.bm == kCommitBmAdd) {
        if (a == 0u) r = t;
    } else if (u.bm == kCommitBmErase) {
        if (t != 0u) r = 0u;
    } else if (u.bm == kCommitBmReplace) {
        if (a != 0u && t != 0u) r = t;
    } else if (u.bm == kCommitBmIntersect) {
        r = (a != 0u && t != 0u) ? t : 0u;
    }

    if (r != a) {
        tex_a.write(uint4(r, 0u, 0u, 0u), uint3(cell_local));
        if (r != 0u) {
            doc_oracle.write(uint4(1u, 0u, 0u, 0u),
                             uint3(uint3(cell_local) >> uint3(4u)));
        }
    }
    // Clear preview in this bbox regardless of write — stroke
    // committed, future strokes shouldn't see stale tex_t.
    if (u.brush == kCommitBrushPreview) {
        preview.write(uint4(0u, 0u, 0u, 0u), uint3(cell_local));
    }
}
