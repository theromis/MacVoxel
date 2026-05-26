// Lift kernels — the selection-lift compute pipeline. Selection state
// is held as a separate buffer (`tex_lift`) parallel to the doc
// (`tex_a`); this file's kernels handle the lift's lifecycle:
//
//   lift_box_main       — selection finalize from a box (marquee/box-select)
//   lift_cells_main     — selection finalize from a CPU cell list (flood)
//   lift_translate_main — cmd-drag move-by-offset
//   lift_transform_main — rotate / flip (Magica rotate_centered form)
//   lift_commit_main    — blit lift contents into tex_a; zero lift
//   lift_clear_main     — zero a region of tex_lift (cancel path)
//
// Transform kernels read from `tex_lift_snap` (blitted by the caller
// before dispatch) and write live `tex_lift`. This makes source/dest
// overlap race-free without the union-dispatch + clear-if-selected
// gymnastics the in-place-on-tex_a kernel needed.

#include <metal_stdlib>
using namespace metal;

// Bbox-oriented dispatch uniforms — shared by lift_box, lift_translate,
// lift_transform, lift_commit, lift_clear. `dispatch_lo` and
// `dispatch_size` are texture-local; the kernel reconstructs world
// coords by adding `tex_origin`.
struct LiftBboxUniforms {
    int3 dispatch_lo;
    int3 dispatch_size;
    int3 tex_origin;
};

kernel void lift_box_main(
    constant LiftBboxUniforms&          u             [[buffer(0)]],
    texture3d<uint, access::read_write> tex_a         [[texture(0)]],
    texture3d<uint, access::write>      doc_oracle    [[texture(1)]],
    texture3d<uint, access::read_write> tex_lift      [[texture(2)]],
    texture3d<uint, access::write>      lift_oracle   [[texture(3)]],
    uint3 gid                                         [[thread_position_in_grid]])
{
    int3 d = int3(gid);
    if (any(d >= u.dispatch_size)) return;
    int3 cell_local = u.dispatch_lo + d;
    int3 dims = int3(int(tex_a.get_width()),
                     int(tex_a.get_height()),
                     int(tex_a.get_depth()));
    if (any(cell_local < 0) || any(cell_local >= dims)) return;
    uint val = tex_a.read(uint3(cell_local)).r;
    if (val == 0u) return;
    tex_lift.write(uint4(val, 0u, 0u, 0u), uint3(cell_local));
    tex_a.write(uint4(0u, 0u, 0u, 0u), uint3(cell_local));
    // Both oracles are monotonic-or: writes "1" to both since the
    // lift gained a cell and the doc lost one. The doc-side stale-1
    // costs one extra per-cell read but doesn't drop voxels; lift
    // oracle gets a true "non-empty" mark.
    lift_oracle.write(uint4(1u, 0u, 0u, 0u),
                      uint3(uint3(cell_local) >> uint3(4u)));
    doc_oracle.write(uint4(1u, 0u, 0u, 0u),
                     uint3(uint3(cell_local) >> uint3(4u)));
}

// Per-cell scatter — caller hands a list of (world cell, ignored
// palette) triples; one thread per cell. Used by FloodSelectFromSeed.
struct LiftCellsUniforms {
    int3 tex_origin;
    int  _pad;
};
struct CellEntry { int x, y, z; uint _pad; };

kernel void lift_cells_main(
    constant LiftCellsUniforms&         u             [[buffer(0)]],
    constant CellEntry*                 cells         [[buffer(1)]],
    constant uint&                      cell_count    [[buffer(2)]],
    texture3d<uint, access::read_write> tex_a         [[texture(0)]],
    texture3d<uint, access::write>      doc_oracle    [[texture(1)]],
    texture3d<uint, access::read_write> tex_lift      [[texture(2)]],
    texture3d<uint, access::write>      lift_oracle   [[texture(3)]],
    uint gid                                          [[thread_position_in_grid]])
{
    if (gid >= cell_count) return;
    CellEntry c = cells[gid];
    int3 cell_local = int3(c.x, c.y, c.z) - u.tex_origin;
    int3 dims = int3(int(tex_a.get_width()),
                     int(tex_a.get_height()),
                     int(tex_a.get_depth()));
    if (any(cell_local < 0) || any(cell_local >= dims)) return;
    uint val = tex_a.read(uint3(cell_local)).r;
    if (val == 0u) return;
    tex_lift.write(uint4(val, 0u, 0u, 0u), uint3(cell_local));
    tex_a.write(uint4(0u, 0u, 0u, 0u), uint3(cell_local));
    lift_oracle.write(uint4(1u, 0u, 0u, 0u),
                      uint3(uint3(cell_local) >> uint3(4u)));
    doc_oracle.write(uint4(1u, 0u, 0u, 0u),
                     uint3(uint3(cell_local) >> uint3(4u)));
}

// Translate: tex_lift[cell] = tex_lift_snap[cell - offset]. Dispatched
// over union(old_bbox, new_bbox). Cells where the back-mapped source
// is out of bounds or empty get written as zero (clearing the old
// position implicitly).
struct LiftTranslateUniforms {
    int3 dispatch_lo;
    int3 dispatch_size;
    int3 tex_origin;
    int3 offset;            // new = old + offset; back-map: src = dst - offset
    int3 snap_local_min;    // tex-local bounds the snapshot covers — reads
    int3 snap_local_max;    // outside this rectangle would see stale data
                            // from a previous transform's blit, so the
                            // kernel clamps them to 0.
};

kernel void lift_translate_main(
    constant LiftTranslateUniforms&     u             [[buffer(0)]],
    texture3d<uint, access::read>       tex_lift_snap [[texture(0)]],
    texture3d<uint, access::read_write> tex_lift      [[texture(1)]],
    texture3d<uint, access::write>      lift_oracle   [[texture(2)]],
    uint3 gid                                         [[thread_position_in_grid]])
{
    int3 d = int3(gid);
    if (any(d >= u.dispatch_size)) return;
    int3 cell_local = u.dispatch_lo + d;
    int3 dims = int3(int(tex_lift.get_width()),
                     int(tex_lift.get_height()),
                     int(tex_lift.get_depth()));
    if (any(cell_local < 0) || any(cell_local >= dims)) return;
    int3 src_local = cell_local - u.offset;
    uint val = 0u;
    if (all(src_local >= u.snap_local_min) &&
        all(src_local <= u.snap_local_max)) {
        val = tex_lift_snap.read(uint3(src_local)).r;
    }
    tex_lift.write(uint4(val, 0u, 0u, 0u), uint3(cell_local));
    if (val != 0u) {
        lift_oracle.write(uint4(1u, 0u, 0u, 0u),
                          uint3(uint3(cell_local) >> uint3(4u)));
    }
}

// Rotate / flip — Magica's `rotate_centered.glsl` form. Cell-center
// (+0.5) sampling with float pivots; integer `inv_map` (entries in
// {-1,0,1}) applied as float. Dispatch is over dst_bbox only — no
// union, no clear-if-selected. Cells where the back-map src is empty
// or out of bounds get written as zero (the lift's old position is
// effectively cleared because the next translate / commit treats the
// new dst as canonical).
//
// IMPORTANT: caller must clear the old lift_bbox in tex_lift before
// dispatching this (via lift_clear_main over old_bbox ∖ new_bbox), or
// the lift will appear duplicated at both old and new positions.
struct LiftTransformUniforms {
    int3   inv_map_row0;
    int3   inv_map_row1;
    int3   inv_map_row2;
    float3 src_center;
    float3 dst_center;
    int3   dst_bbox_min;     // inclusive, world coords
    int3   dst_bbox_max;     // inclusive, world coords
    int3   dispatch_lo;      // union(old, dst) start (texture-local)
    int3   dispatch_size;    // union(old, dst) dims
    int3   tex_origin;
    int3   snap_local_min;   // tex-local bounds of the snapshot blit
    int3   snap_local_max;
};

// Dispatch covers `union(old_lift_bbox, dst_bbox)`. The kernel
// snapshot was blitted by the caller BEFORE this dispatch in the
// same command buffer; we read it and write live tex_lift. For
// cells inside dst_bbox: back-map gather. For cells outside dst:
// write 0 (clears the old lift position so it doesn't ghost-double
// after the transform).
kernel void lift_transform_main(
    constant LiftTransformUniforms&     u             [[buffer(0)]],
    texture3d<uint, access::read>       tex_lift_snap [[texture(0)]],
    texture3d<uint, access::read_write> tex_lift      [[texture(1)]],
    texture3d<uint, access::write>      lift_oracle   [[texture(2)]],
    uint3 gid                                         [[thread_position_in_grid]])
{
    int3 d = int3(gid);
    if (any(d >= u.dispatch_size)) return;
    int3 cell_local = u.dispatch_lo + d;
    int3 cell_world = cell_local + u.tex_origin;

    bool in_dst =
        all(cell_world >= u.dst_bbox_min) &&
        all(cell_world <= u.dst_bbox_max);

    uint val = 0u;
    if (in_dst) {
        float3 dst_p = float3(cell_world) + 0.5;
        float3 rel = dst_p - u.dst_center;
        float3 mapped = float3(
            float(u.inv_map_row0.x) * rel.x +
            float(u.inv_map_row0.y) * rel.y +
            float(u.inv_map_row0.z) * rel.z,
            float(u.inv_map_row1.x) * rel.x +
            float(u.inv_map_row1.y) * rel.y +
            float(u.inv_map_row1.z) * rel.z,
            float(u.inv_map_row2.x) * rel.x +
            float(u.inv_map_row2.y) * rel.y +
            float(u.inv_map_row2.z) * rel.z);
        float3 src_p = mapped + u.src_center;
        int3 src_world = int3(floor(src_p));
        int3 src_local = src_world - u.tex_origin;
        // Bound to the snapshot blit region — reads outside it would
        // pick up stale bytes from a previous transform.
        if (all(src_local >= u.snap_local_min) &&
            all(src_local <= u.snap_local_max)) {
            val = tex_lift_snap.read(uint3(src_local)).r;
        }
    }
    tex_lift.write(uint4(val, 0u, 0u, 0u), uint3(cell_local));
    if (val != 0u) {
        lift_oracle.write(uint4(1u, 0u, 0u, 0u),
                          uint3(uint3(cell_local) >> uint3(4u)));
    }
}

// Commit: for each non-zero cell in lift_bbox, write tex_lift into
// tex_a, zero tex_lift. Marks doc oracle on writes.
kernel void lift_commit_main(
    constant LiftBboxUniforms&          u             [[buffer(0)]],
    texture3d<uint, access::read_write> tex_a         [[texture(0)]],
    texture3d<uint, access::write>      doc_oracle    [[texture(1)]],
    texture3d<uint, access::read_write> tex_lift      [[texture(2)]],
    uint3 gid                                         [[thread_position_in_grid]])
{
    int3 d = int3(gid);
    if (any(d >= u.dispatch_size)) return;
    int3 cell_local = u.dispatch_lo + d;
    int3 dims = int3(int(tex_a.get_width()),
                     int(tex_a.get_height()),
                     int(tex_a.get_depth()));
    if (any(cell_local < 0) || any(cell_local >= dims)) return;
    uint val = tex_lift.read(uint3(cell_local)).r;
    if (val == 0u) return;
    tex_a.write(uint4(val, 0u, 0u, 0u), uint3(cell_local));
    tex_lift.write(uint4(0u, 0u, 0u, 0u), uint3(cell_local));
    doc_oracle.write(uint4(1u, 0u, 0u, 0u),
                     uint3(uint3(cell_local) >> uint3(4u)));
}

// Clear: zero a region of tex_lift. Used by Cancel and to scrub the
// old lift position before a transform writes the new one.
kernel void lift_clear_main(
    constant LiftBboxUniforms&         u             [[buffer(0)]],
    texture3d<uint, access::write>     tex_lift      [[texture(0)]],
    uint3 gid                                        [[thread_position_in_grid]])
{
    int3 d = int3(gid);
    if (any(d >= u.dispatch_size)) return;
    int3 cell_local = u.dispatch_lo + d;
    tex_lift.write(uint4(0u, 0u, 0u, 0u), uint3(cell_local));
}
