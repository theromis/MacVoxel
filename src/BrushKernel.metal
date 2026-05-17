// MSL source for the brush compute kernel — Magica's "brushes are
// shaders" model adapted to Metal compute. One unified `brush_main`
// handles all four brush variants (square/circle × 2D/3D); the
// footprint is a regular grid over the brush's bounding box and each
// thread tests its cell against the circle/slab constraints.
//
// Async-write protocol (B2):
//   buffer(0)  = Uniforms (brush center / bounds / shape / mode / volume)
//   texture(0) = R8Uint doc texture, access::read_write. Kernel reads the
//                old value, computes the new value, writes back if changed.
//
// No diff/atomic-counter output — the texture is authoritative during a
// stroke, and end-of-stroke sync (BrushController::OnMouseUp) recovers
// the per-cell diff by comparing the texture to the still-pre-stroke
// `doc.volume_shadow`.
//
// Each thread covers exactly one footprint cell. Threads dispatched past
// the bounds (when the dispatch rounds up to threadgroup-multiple) early
// out.

#include <metal_stdlib>
using namespace metal;

// Mode encoding matches macvoxel::ToolMode (ToolState.h):
//   0 = Add    — create non-empty cells; existing cells untouched.
//   1 = Remove — erase non-empty cells.
//   2 = Paint  — overwrite existing non-empty cells with current palette.
constant uint kModeAdd    = 0u;
constant uint kModeRemove = 1u;
constant uint kModePaint  = 2u;

// Flags (bit field).
constant uint kFlag3D     = 1u << 0;
constant uint kFlagCircle = 1u << 1;

struct Uniforms {
    int3 center;        // brush center cell
    int  face_axis;     // 0=X, 1=Y, 2=Z (used by 2D variants)
    int3 lo;            // footprint min offset from center
    int3 size;          // footprint dims (hi - lo + 1)
    uint flags;
    uint mode;
    uint palette_idx;   // 0..255 (the cell value to write for Add/Paint)
    int3 vol_min;       // edit-volume bounds (inclusive)
    int3 vol_max;       // edit-volume bounds (inclusive)
    int3 tex_origin;    // doc texture's [0,0,0] in world cell coords (== vol_min)
    float center_offset_x10;  // (lo.x + lo.x + size.x - 1) * 0.5 (etc) ×10 to fit int
    float r2;           // (max_dim * 0.5)^2 — circle/sphere radius squared
};

// Apply the mode's value-rewrite rule: Add fills empty cells with the
// palette index, Remove clears any cell, Paint repaints non-empty cells.
static uint compute_new_value(uint old_val, uint mode, uint palette_idx) {
    if (mode == kModeAdd)    return old_val == 0u ? palette_idx : old_val;
    if (mode == kModeRemove) return 0u;
    if (mode == kModePaint)  return old_val == 0u ? old_val : palette_idx;
    return old_val;
}

kernel void brush_main(
    constant Uniforms& u                              [[buffer(0)]],
    texture3d<uint, access::read_write> tex_a         [[texture(0)]],
    texture3d<uint, access::write>      oracle        [[texture(1)]],
    uint3 gid                                         [[thread_position_in_grid]])
{
    // Footprint-grid bounds check: dispatches round up to the threadgroup
    // size, so trailing threads in each dim must early-out.
    int3 d = int3(gid);
    if (any(d >= u.size)) return;

    // Translate footprint-local index → offset-from-center, then world cell.
    int3 offset = d + u.lo;
    int3 cell = u.center + offset;

    const bool is_3d = (u.flags & kFlag3D) != 0u;
    const bool is_circle = (u.flags & kFlagCircle) != 0u;

    // 2D variants: only the slice through center on `face_axis` matters.
    if (!is_3d) {
        if (u.face_axis == 0 && offset.x != 0) return;
        if (u.face_axis == 1 && offset.y != 0) return;
        if (u.face_axis == 2 && offset.z != 0) return;
    }

    // Circle / sphere test — distance² from the brush's geometric center.
    if (is_circle) {
        float c = u.center_offset_x10 * 0.1;
        float d2 = 0.0;
        float fdx = float(offset.x) - c;
        float fdy = float(offset.y) - c;
        float fdz = float(offset.z) - c;
        if (is_3d || u.face_axis != 0) d2 += fdx * fdx;
        if (is_3d || u.face_axis != 1) d2 += fdy * fdy;
        if (is_3d || u.face_axis != 2) d2 += fdz * fdz;
        if (d2 > u.r2) return;
    }

    // Read current cell value from the texture.
    int3 tex_coord = cell - u.tex_origin;
    bool in_tex = all(tex_coord >= int3(0)) &&
                  all(tex_coord <  int3(tex_a.get_width(),
                                        tex_a.get_height(),
                                        tex_a.get_depth()));
    if (!in_tex) return;

    uint old_val = tex_a.read(uint3(tex_coord)).r;
    uint new_val = compute_new_value(old_val, u.mode, u.palette_idx);

    // Out-of-volume create-non-empty drop (EditVolume policy: creating a
    // new non-empty cell outside the volume is silently ignored; in-place
    // deletes / repaints of cells that already exist outside are allowed).
    bool in_vol = all(cell >= u.vol_min) && all(cell <= u.vol_max);
    if (new_val != 0u && old_val == 0u && !in_vol) return;
    if (new_val == old_val) return;

    tex_a.write(uint4(new_val, 0u, 0u, 0u), uint3(tex_coord));
    // Mark the chunk non-empty in the oracle. Monotone-empty→non-empty;
    // never cleared by the kernel even on Remove, so a Remove that
    // empties a chunk just leaves the oracle conservatively
    // "non-empty" until the end-of-stroke sync rebuilds it. Cheap, and
    // race-safe because every thread writes the same value (1).
    if (new_val != 0u) {
        oracle.write(uint4(1u, 0u, 0u, 0u),
                     uint3(uint3(tex_coord) >> uint3(4u)));
    }
}
