#import "RaycastRenderer.h"
#import "VolumeTexture.h"

#include "EditorContext.h"

#import <cstdio>
#include <array>
#include <cstdint>
#include <cstring>
#include <vector>

#include "Document.h"
#include "FloatingBuffer.h"
#include "PreviewOverlay.h"

namespace {

struct Uniforms {
    simd::float4x4 inv_vp;
    simd::float3 camera_pos;
    float _pad0;
    simd::float3 light_dir;
    float _pad1;
    // Overlay additions slot — a sparse grid the shader DDA samples
    // alongside the doc texture. Renders "on top of" the doc wherever
    // non-zero. Two mutually-exclusive sources share the slot:
    //   1. FloatingBuffer.grid for selection lift / paste / move-drag /
    //      rotate / flip — `buf_offset` is the running drag delta.
    //   2. PreviewOverlay.additions for shape / face / generator tool
    //      previews — no offset; cells are at their final coords.
    // When `buf_active == 0` all buf_* fields are ignored.
    simd::int3 buf_coarse_min;
    int _pad2;
    simd::int3 buf_coarse_dim;
    int _pad3;
    simd::int3 buf_offset;
    int buf_active;
    // Preview removals slot — only set during a tool preview. Marks doc
    // cells the preview wants to appear empty (Remove / Paint / Add-inset
    // strokes). Same coarse-grid + chunk-pool layout as the additions
    // slot; any non-zero byte means "hide the doc cell here".
    simd::int3 rem_coarse_min;
    int _pad4;
    simd::int3 rem_coarse_dim;
    int rem_active;
    // Edit-volume bounds in cell coords. `box_min` is inclusive, `box_max`
    // is exclusive (e.g. EditVolume{x0=-128, x1=127} → box_min.x=-128,
    // box_max.x=128). Doubles as the doc texture's index space:
    // `tex_a.read(uint3(cell - int3(box_min)))`.
    simd::float3 box_min;
    float _pad5;
    simd::float3 box_max;
    float _pad6;
};

NSString* const kShaderSource = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct VertOut {
    float4 position [[position]];
    float2 ndc;
};

struct Uniforms {
    float4x4 inv_vp;
    float3   camera_pos;
    float    _pad0;
    float3   light_dir;
    float    _pad1;
    int3     buf_coarse_min;
    int      _pad2;
    int3     buf_coarse_dim;
    int      _pad3;
    int3     buf_offset;
    int      buf_active;
    int3     rem_coarse_min;
    int      _pad4;
    int3     rem_coarse_dim;
    int      rem_active;
    float3   box_min;
    float    _pad5;
    float3   box_max;
    float    _pad6;
};

struct Chunk {
    uint8_t cells[4096];
};

// Fullscreen triangle covering NDC [-1, 1]² with one extra-large vertex
// past each corner; no vertex buffer needed.
vertex VertOut raycast_vertex(uint vid [[vertex_id]]) {
    float2 p;
    if (vid == 0)      p = float2(-1.0, -1.0);
    else if (vid == 1) p = float2( 3.0, -1.0);
    else               p = float2(-1.0,  3.0);
    VertOut o;
    o.position = float4(p, 0.0, 1.0);
    o.ndc = p;
    return o;
}

constant int kMaxSteps = 4096;
constant uint kChunkBits = 4;
constant uint kChunkMask = 15u;
constant uint kChunkSize = 16u;
constant uint kChunkVolume = 4096u;

// Closest approach of the forward ray (t ≥ 0) to an axis-aligned
// infinite line. `axis` is which world axis the line runs along
// (0=X, 1=Y, 2=Z); (a, b) are the line's two perpendicular
// coordinates. Returns float3(perp_dist, t_at_closest, along_at_closest)
// — caller clips along_at_closest to the segment range. Sentinel
// returns 1e10 when the closest approach is behind the camera or the
// ray is parallel to the line.
float3 ray_to_axis_line(float3 ro, float3 rd, int axis, float a, float b) {
    float2 r_perp, d_perp;
    float r_along, d_along;
    if (axis == 0) {
        r_perp = float2(ro.y, ro.z); d_perp = float2(rd.y, rd.z);
        r_along = ro.x; d_along = rd.x;
    } else if (axis == 1) {
        r_perp = float2(ro.x, ro.z); d_perp = float2(rd.x, rd.z);
        r_along = ro.y; d_along = rd.y;
    } else {
        r_perp = float2(ro.x, ro.y); d_perp = float2(rd.x, rd.y);
        r_along = ro.z; d_along = rd.z;
    }
    float denom = dot(d_perp, d_perp);
    if (denom < 1e-8) return float3(1e10, 0.0, 0.0);
    float t = dot(float2(a, b) - r_perp, d_perp) / denom;
    if (t < 0.0) return float3(1e10, 0.0, 0.0);
    float2 closest = r_perp + t * d_perp;
    return float3(length(closest - float2(a, b)),
                  t,
                  r_along + t * d_along);
}

// Wireframe of (9 of) the 12 cube edges drawn into background pixels.
// Width scales linearly with depth so edges hold a roughly constant
// screen width across zoom levels; opacity max-pools so corners don't
// bloom where edges meet. ro must be the *original* (pre-AABB-clip)
// camera-space ray origin so edges behind the clip plane render
// correctly when the ray entered through them.
//
// The 3 edges meeting at the cube vertex nearest the camera are
// hidden — they'd visually plug the front of the box from typical
// viewing angles. The matching 3 near faces are also excluded from
// empty-space click anchoring (see ViewContext::IntersectVolumeWall),
// so the cutaway is consistent between rendering and interaction.
float3 bbox_edges_color(float3 ro, float3 rd, float3 bg,
                        float3 box_min, float3 box_max) {
    float xs[2] = {box_min.x, box_max.x};
    float ys[2] = {box_min.y, box_max.y};
    float zs[2] = {box_min.z, box_max.z};
    float3 mid = (box_min + box_max) * 0.5;
    int nx = (ro.x < mid.x) ? 0 : 1;
    int ny = (ro.y < mid.y) ? 0 : 1;
    int nz = (ro.z < mid.z) ? 0 : 1;
    float strongest = 0.0;
    for (int i = 0; i < 2; ++i) {
        for (int j = 0; j < 2; ++j) {
            // X-axis edge at perpendicular (ys[i], zs[j]). The near
            // corner's X-edge has y == near_y and z == near_z.
            if (!(i == ny && j == nz)) {
                float3 ex = ray_to_axis_line(ro, rd, 0, ys[i], zs[j]);
                if (ex.z >= box_min.x && ex.z <= box_max.x) {
                    float w = max(0.18, ex.y * 0.0014);
                    strongest = max(strongest, 1.0 - smoothstep(w * 0.5, w, ex.x));
                }
            }
            if (!(i == nx && j == nz)) {
                float3 ey = ray_to_axis_line(ro, rd, 1, xs[i], zs[j]);
                if (ey.z >= box_min.y && ey.z <= box_max.y) {
                    float w = max(0.18, ey.y * 0.0014);
                    strongest = max(strongest, 1.0 - smoothstep(w * 0.5, w, ey.x));
                }
            }
            if (!(i == nx && j == ny)) {
                float3 ez = ray_to_axis_line(ro, rd, 2, xs[i], ys[j]);
                if (ez.z >= box_min.z && ez.z <= box_max.z) {
                    float w = max(0.18, ez.y * 0.0014);
                    strongest = max(strongest, 1.0 - smoothstep(w * 0.5, w, ez.x));
                }
            }
        }
    }
    if (strongest <= 0.0) return bg;
    return mix(bg, float3(0.6, 0.65, 0.75), strongest * 0.45);
}

fragment float4 raycast_fragment(
    VertOut in [[stage_in]],
    constant Uniforms& u [[buffer(0)]],
    constant float4* palette [[buffer(1)]],
    device const uint* buf_coarse_grid [[buffer(2)]],
    device const Chunk* buf_chunk_pool [[buffer(3)]],
    device const uint* rem_coarse_grid [[buffer(4)]],
    device const Chunk* rem_chunk_pool [[buffer(5)]],
    texture3d<uint, access::read> tex_a [[texture(0)]],
    texture3d<uint, access::read> doc_oracle [[texture(1)]])
{
    // Reconstruct world-space ray from NDC.
    float4 near_clip = float4(in.ndc, 0.0, 1.0);
    float4 far_clip  = float4(in.ndc, 1.0, 1.0);
    float4 near_h = u.inv_vp * near_clip;
    float4 far_h  = u.inv_vp * far_clip;
    float3 near_world = near_h.xyz / near_h.w;
    float3 far_world  = far_h.xyz / far_h.w;
    float3 ray_dir_world = normalize(far_world - near_world);
    float3 ray_origin_world = u.camera_pos;

    // World -> grid: invert the rotation R = (gx, gz, -gy).
    // R^-1 (wx, wy, wz) = (wx, -wz, wy).
    float3 ray_origin = float3(ray_origin_world.x, -ray_origin_world.z, ray_origin_world.y);
    float3 ray_dir   = float3(ray_dir_world.x,   -ray_dir_world.z,   ray_dir_world.y);
    // Pre-clip origin, kept across the AABB advance below — bbox-edge
    // rendering needs the camera position to compute ray-to-edge
    // distances in front of the clip plane.
    float3 cam_origin = ray_origin;

    // Combined AABB clip. Without the buffer this is just the edit
    // volume; with it, we expand to include the buffer's footprint
    // (which can wander outside the volume, e.g. dragging a paste off
    // into empty space). The early reject keeps cameras far from any
    // geometry from spinning the DDA in pure void.
    float3 aabb_min = u.box_min;
    float3 aabb_max = u.box_max;
    if (u.buf_active != 0) {
        float3 b_min = float3(u.buf_coarse_min) * float(kChunkSize)
                     + float3(u.buf_offset);
        float3 b_max = float3(u.buf_coarse_min + u.buf_coarse_dim) * float(kChunkSize)
                     + float3(u.buf_offset);
        aabb_min = min(aabb_min, b_min);
        aabb_max = max(aabb_max, b_max);
    }
    float3 inv_dir = 1.0 / ray_dir;  // ±inf for zero components is fine
    float3 t1 = (aabb_min - ray_origin) * inv_dir;
    float3 t2 = (aabb_max - ray_origin) * inv_dir;
    float3 t_lo = min(t1, t2);
    float3 t_hi = max(t1, t2);
    float t_enter = max(max(t_lo.x, t_lo.y), t_lo.z);
    float t_exit  = min(min(t_hi.x, t_hi.y), t_hi.z);
    if (t_exit < 0.0 || t_enter > t_exit) {
        float3 bg = float3(0.118, 0.118, 0.18);
        return float4(bbox_edges_color(cam_origin, ray_dir, bg, u.box_min, u.box_max), 1.0);
    }
    // Advance origin to the entry point if we're outside. The small nudge
    // past the boundary avoids landing on a cell edge with floor() rounding
    // ambiguously to the cell on either side.
    float t_start = max(t_enter, 0.0);
    ray_origin = ray_origin + ray_dir * (t_start + 1e-4);

    // 3D DDA setup (using the clipped origin).
    int3 cell = int3(floor(ray_origin));
    int3 step_dir;
    step_dir.x = ray_dir.x > 0.0 ? 1 : (ray_dir.x < 0.0 ? -1 : 0);
    step_dir.y = ray_dir.y > 0.0 ? 1 : (ray_dir.y < 0.0 ? -1 : 0);
    step_dir.z = ray_dir.z > 0.0 ? 1 : (ray_dir.z < 0.0 ? -1 : 0);

    float3 t_max;
    t_max.x = step_dir.x == 0 ? INFINITY :
              (step_dir.x > 0 ? (float(cell.x + 1) - ray_origin.x) / ray_dir.x
                              : (ray_origin.x - float(cell.x))     / -ray_dir.x);
    t_max.y = step_dir.y == 0 ? INFINITY :
              (step_dir.y > 0 ? (float(cell.y + 1) - ray_origin.y) / ray_dir.y
                              : (ray_origin.y - float(cell.y))     / -ray_dir.y);
    t_max.z = step_dir.z == 0 ? INFINITY :
              (step_dir.z > 0 ? (float(cell.z + 1) - ray_origin.z) / ray_dir.z
                              : (ray_origin.z - float(cell.z))     / -ray_dir.z);

    float3 t_delta;
    t_delta.x = step_dir.x != 0 ? 1.0 / abs(ray_dir.x) : INFINITY;
    t_delta.y = step_dir.y != 0 ? 1.0 / abs(ray_dir.y) : INFINITY;
    t_delta.z = step_dir.z != 0 ? 1.0 / abs(ray_dir.z) : INFINITY;

    int last_axis = -1;

    // Dense-doc DDA with a 16³ coarse occupancy oracle. The doc lives
    // in a `texture3d<uint>` sized to the edit volume; the oracle is a
    // 1/16-scale `texture3d<uint>` where each cell is 0 (chunk empty) or
    // non-zero (chunk has filled voxels). At retina resolution the
    // per-pixel DDA cost is dominated by empty-space marching, so
    // skipping a whole 16³ chunk at a time when its oracle entry is 0
    // is the difference between ~35 ms and ~3 ms per frame.
    int3 box_min_i = int3(int(u.box_min.x), int(u.box_min.y), int(u.box_min.z));
    int3 box_max_i = int3(int(u.box_max.x), int(u.box_max.y), int(u.box_max.z));
    int3 box_chunk_min = box_min_i >> int(kChunkBits);
    for (int s = 0; s < kMaxSteps; ++s) {
        // Doc-side: oracle lookup. Skip the per-cell read when the
        // chunk is reported empty; only sample tex_a otherwise.
        int3 cell_local = cell - box_min_i;
        bool doc_in = (cell.x >= box_min_i.x && cell.x < box_max_i.x &&
                       cell.y >= box_min_i.y && cell.y < box_max_i.y &&
                       cell.z >= box_min_i.z && cell.z < box_max_i.z);
        int3 doc_chunk_c = cell >> int(kChunkBits);
        bool doc_chunk_empty = true;
        uint val_doc = 0u;
        if (doc_in) {
            int3 oracle_c = doc_chunk_c - box_chunk_min;
            doc_chunk_empty = (doc_oracle.read(uint3(oracle_c)).r == 0u);
            if (!doc_chunk_empty) {
                val_doc = tex_a.read(uint3(cell_local)).r;
            }
        }

        // Buffer-side lookup (unchanged — overlay slots stay sparse).
        uint pool_idx_buf = 0u;
        int3 chunk_c_buf = int3(0);
        bool buf_in = false;
        if (u.buf_active != 0) {
            int3 cell_buf = cell - u.buf_offset;
            chunk_c_buf.x = cell_buf.x >> int(kChunkBits);
            chunk_c_buf.y = cell_buf.y >> int(kChunkBits);
            chunk_c_buf.z = cell_buf.z >> int(kChunkBits);
            int3 cgb = chunk_c_buf - u.buf_coarse_min;
            buf_in = (cgb.x >= 0 && cgb.y >= 0 && cgb.z >= 0 &&
                      cgb.x < u.buf_coarse_dim.x &&
                      cgb.y < u.buf_coarse_dim.y &&
                      cgb.z < u.buf_coarse_dim.z);
            if (buf_in) {
                uint b_idx = uint(cgb.x) +
                             uint(cgb.y) * uint(u.buf_coarse_dim.x) +
                             uint(cgb.z) * uint(u.buf_coarse_dim.x) * uint(u.buf_coarse_dim.y);
                pool_idx_buf = buf_coarse_grid[b_idx];
            }
        }

        // Outside the union of doc volume + buf extent: ray has exited.
        if (!doc_in && !buf_in) {
            float3 bg = float3(0.118, 0.118, 0.18);
            return float4(bbox_edges_color(cam_origin, ray_dir, bg, u.box_min, u.box_max), 1.0);
        }

        // Hit detection. Buf renders on top of doc where they overlap.
        if (pool_idx_buf != 0u) {
            int3 cell_buf = cell - u.buf_offset;
            uint lx = uint(cell_buf.x) & kChunkMask;
            uint ly = uint(cell_buf.y) & kChunkMask;
            uint lz = uint(cell_buf.z) & kChunkMask;
            uint local_idx = lx + ly * kChunkSize + lz * kChunkSize * kChunkSize;
            uint val = uint(buf_chunk_pool[pool_idx_buf - 1u].cells[local_idx]);
            if (val != 0u) {
                float3 grid_normal = float3(0.0);
                if (last_axis == 0) grid_normal.x = -float(step_dir.x);
                else if (last_axis == 1) grid_normal.y = -float(step_dir.y);
                else if (last_axis == 2) grid_normal.z = -float(step_dir.z);
                float3 world_normal = float3(grid_normal.x, grid_normal.z, -grid_normal.y);
                float ndl = max(dot(world_normal, u.light_dir), 0.0);
                float lambert = 0.3 + 0.7 * ndl;
                float3 base = palette[val].rgb;
                return float4(base * lambert, 1.0);
            }
        }
        if (val_doc != 0u) {
            // Preview removals: skip doc cells the active preview wants to
            // appear empty (Remove / Paint / Add-inset previews stage their
            // hidden cells here so the doc texture stays untouched).
            if (u.rem_active != 0) {
                int3 chunk_c;
                chunk_c.x = cell.x >> int(kChunkBits);
                chunk_c.y = cell.y >> int(kChunkBits);
                chunk_c.z = cell.z >> int(kChunkBits);
                int3 rgc = chunk_c - u.rem_coarse_min;
                if (rgc.x >= 0 && rgc.y >= 0 && rgc.z >= 0 &&
                    rgc.x < u.rem_coarse_dim.x &&
                    rgc.y < u.rem_coarse_dim.y &&
                    rgc.z < u.rem_coarse_dim.z) {
                    uint r_idx = uint(rgc.x) +
                                 uint(rgc.y) * uint(u.rem_coarse_dim.x) +
                                 uint(rgc.z) * uint(u.rem_coarse_dim.x) *
                                               uint(u.rem_coarse_dim.y);
                    uint pool_idx_rem = rem_coarse_grid[r_idx];
                    if (pool_idx_rem != 0u) {
                        uint lx = uint(cell.x) & kChunkMask;
                        uint ly = uint(cell.y) & kChunkMask;
                        uint lz = uint(cell.z) & kChunkMask;
                        uint local_idx = lx + ly * kChunkSize +
                                         lz * kChunkSize * kChunkSize;
                        if (rem_chunk_pool[pool_idx_rem - 1u].cells[local_idx] != 0u) {
                            val_doc = 0u;
                        }
                    }
                }
            }
            if (val_doc != 0u) {
                float3 grid_normal = float3(0.0);
                if (last_axis == 0) grid_normal.x = -float(step_dir.x);
                else if (last_axis == 1) grid_normal.y = -float(step_dir.y);
                else if (last_axis == 2) grid_normal.z = -float(step_dir.z);
                float3 world_normal = float3(grid_normal.x, grid_normal.z, -grid_normal.y);
                float ndl = max(dot(world_normal, u.light_dir), 0.0);
                float lambert = 0.3 + 0.7 * ndl;
                float3 base = palette[val_doc].rgb;
                return float4(base * lambert, 1.0);
            }
        }

        // No hit at this cell. If both the doc oracle says this chunk
        // is empty AND the buf pool slot here is empty, coarse-skip to
        // whichever chunk boundary comes first along the ray. Otherwise
        // cell-step (the chunk we're in has either doc or buf cells
        // and we need to keep sampling per cell).
        if (doc_chunk_empty && pool_idx_buf == 0u) {
            float3 chunk_min_doc = float3(doc_chunk_c) * float(kChunkSize);
            float3 chunk_max_doc = chunk_min_doc + float(kChunkSize);
            float3 exit_face_doc = select(chunk_min_doc, chunk_max_doc, step_dir > 0);
            float3 t_face_doc = (exit_face_doc - ray_origin) * inv_dir;
            if (step_dir.x == 0) t_face_doc.x = INFINITY;
            if (step_dir.y == 0) t_face_doc.y = INFINITY;
            if (step_dir.z == 0) t_face_doc.z = INFINITY;
            float t_exit_doc = min(min(t_face_doc.x, t_face_doc.y), t_face_doc.z);

            float t_exit_buf = INFINITY;
            float3 t_face_buf = float3(INFINITY);
            if (u.buf_active != 0) {
                float3 chunk_min_buf = float3(chunk_c_buf) * float(kChunkSize)
                                     + float3(u.buf_offset);
                float3 chunk_max_buf = chunk_min_buf + float(kChunkSize);
                float3 exit_face_buf = select(chunk_min_buf, chunk_max_buf, step_dir > 0);
                t_face_buf = (exit_face_buf - ray_origin) * inv_dir;
                if (step_dir.x == 0) t_face_buf.x = INFINITY;
                if (step_dir.y == 0) t_face_buf.y = INFINITY;
                if (step_dir.z == 0) t_face_buf.z = INFINITY;
                t_exit_buf = min(min(t_face_buf.x, t_face_buf.y), t_face_buf.z);
            }

            float t_skip = min(t_exit_doc, t_exit_buf);
            float3 t_face = (t_exit_doc <= t_exit_buf) ? t_face_doc : t_face_buf;
            int exit_axis = (t_face.x <= t_face.y && t_face.x <= t_face.z) ? 0
                          : (t_face.y <= t_face.z) ? 1 : 2;
            last_axis = exit_axis;

            float eps = max(1e-3, t_skip * 1e-5);
            float3 pos = ray_origin + ray_dir * (t_skip + eps);
            cell.x = int(floor(pos.x));
            cell.y = int(floor(pos.y));
            cell.z = int(floor(pos.z));
            t_max.x = step_dir.x == 0 ? INFINITY :
                      (step_dir.x > 0
                           ? (float(cell.x + 1) - ray_origin.x) / ray_dir.x
                           : (ray_origin.x - float(cell.x))     / -ray_dir.x);
            t_max.y = step_dir.y == 0 ? INFINITY :
                      (step_dir.y > 0
                           ? (float(cell.y + 1) - ray_origin.y) / ray_dir.y
                           : (ray_origin.y - float(cell.y))     / -ray_dir.y);
            t_max.z = step_dir.z == 0 ? INFINITY :
                      (step_dir.z > 0
                           ? (float(cell.z + 1) - ray_origin.z) / ray_dir.z
                           : (ray_origin.z - float(cell.z))     / -ray_dir.z);
            continue;
        }

        if (t_max.x < t_max.y && t_max.x < t_max.z) {
            cell.x += step_dir.x;
            t_max.x += t_delta.x;
            last_axis = 0;
        } else if (t_max.y < t_max.z) {
            cell.y += step_dir.y;
            t_max.y += t_delta.y;
            last_axis = 1;
        } else {
            cell.z += step_dir.z;
            t_max.z += t_delta.z;
            last_axis = 2;
        }
    }
    float3 bg = float3(0.118, 0.118, 0.18);
    return float4(bbox_edges_color(cam_origin, ray_dir, bg, u.box_min, u.box_max), 1.0);
}
)MSL";

}  // namespace

@implementation RaycastRenderer {
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLBuffer> _paletteBuffer;
    uint64_t _cachedPaletteVersion;
    BOOL _cacheValid;
    // Overlay-additions resources. The slot is shared by FloatingBuffer
    // (selection lift / paste / move-drag) and PreviewOverlay (shape /
    // face / generator preview); the two are mutually exclusive at the
    // gesture level. _bufSource records which kind currently populates
    // the slot so a switch (e.g. ending a preview, starting a move)
    // forces a rebuild instead of mistakenly reusing version numbers.
    enum class OverlaySource : uint8_t {
        None = 0,
        FloatingBuffer = 1,
        Preview = 2,
    };
    id<MTLBuffer> _bufCoarseBuffer;
    id<MTLBuffer> _bufPoolBuffer;
    uint64_t _bufLastVersion;
    BOOL _bufBuilt;
    simd::int3 _bufCoarseMin;
    simd::int3 _bufCoarseDim;
    OverlaySource _bufSource;
    // Preview-removals resources. Mirrors the additions slot's coarse-grid
    // + chunk-pool layout. Only populated while a PreviewOverlay is active
    // (FloatingBuffer doesn't need removals — its lift mechanism cleared
    // the source cells in the doc grid up front). _remBuilt + version
    // gate rebuilds the same way the additions slot does.
    id<MTLBuffer> _remCoarseBuffer;
    id<MTLBuffer> _remPoolBuffer;
    uint64_t _remLastVersion;
    BOOL _remBuilt;
    simd::int3 _remCoarseMin;
    simd::int3 _remCoarseDim;
    // Stub buffers always bound at fragment slots 4–7 — Metal needs a
    // valid backing for every declared fragment buffer even when the
    // corresponding {buf,rem}_active flag is 0 in the uniforms.
    id<MTLBuffer> _stubBuffer;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat
                   depthFormat:(MTLPixelFormat)depthFormat {
    self = [super init];
    if (self == nil) return nil;
    _device = device;

    NSError* error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:kShaderSource
                                                   options:nil
                                                     error:&error];
    if (library == nil) {
        fprintf(stderr, "MacVoxel: failed to compile raycast shaders: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    id<MTLFunction> vfn = [library newFunctionWithName:@"raycast_vertex"];
    id<MTLFunction> ffn = [library newFunctionWithName:@"raycast_fragment"];

    MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.label = @"MacVoxel Raycast";
    desc.vertexFunction = vfn;
    desc.fragmentFunction = ffn;
    desc.colorAttachments[0].pixelFormat = colorFormat;
    desc.depthAttachmentPixelFormat = depthFormat;

    _pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (_pipeline == nil) {
        fprintf(stderr, "MacVoxel: failed to build raycast pipeline: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    // 4-byte stub: bound at the floating-buffer slots whenever no
    // buffer is active, just so Metal sees a non-nil binding.
    _stubBuffer = [_device newBufferWithLength:sizeof(uint32_t)
                                       options:MTLResourceStorageModeShared];
    _stubBuffer.label = @"RaycastBufStub";
    return self;
}

- (uint32_t)lastChunkCount {
    // Dense texture has no chunk count of its own — report nothing.
    // Field stays in the API for the SwiftUI stats panel, which now
    // reads chunk counts off VoxelGrid directly.
    return 0;
}

- (size_t)lastGPUBytes {
    return _paletteBuffer == nil ? 0 : _paletteBuffer.length;
}

- (void)invalidate {
    _cacheValid = NO;
    _paletteBuffer = nil;
    _cachedPaletteVersion = 0;
}

// ---------------------------------------------------------------------------
// GPU upload. The hot path is incremental: drain the grid's dirty-chunk
// set and update only the affected slots in the chunk pool. Wholesale
// rebuild is reserved for the cases where the chunk-coord bounds shift
// (a fresh document, or an edit that places voxels past the previous
// extents) — there the coarse grid itself has to be reshaped.
// ---------------------------------------------------------------------------

// Build (or rebuild) one of the overlay slots' GPU mirror from a sparse
// VoxelGrid. Same coarse-grid + chunk-pool layout as the document, just
// smaller. Used for both the additions slot (FloatingBuffer.grid OR
// PreviewOverlay.additions) and the removals slot
// (PreviewOverlay.removals). Caller picks the slot's ivars.
- (void)rebuildSparseSlotFromGrid:(const macvoxel::VoxelGrid&)grid
                           coarse:(__strong id<MTLBuffer>* _Nonnull)coarseOut
                             pool:(__strong id<MTLBuffer>* _Nonnull)poolOut
                        coarseMin:(simd::int3* _Nonnull)minOut
                        coarseDim:(simd::int3* _Nonnull)dimOut
                       coarseName:(NSString*)coarseLabel
                         poolName:(NSString*)poolLabel {
    using VG = macvoxel::VoxelGrid;
    const auto& chunks = grid.chunks();
    if (chunks.empty()) {
        *coarseOut = nil;
        *poolOut = nil;
        *minOut = simd::int3{0, 0, 0};
        *dimOut = simd::int3{0, 0, 0};
        return;
    }

    int32_t min_cx = INT32_MAX, min_cy = INT32_MAX, min_cz = INT32_MAX;
    int32_t max_cx = INT32_MIN, max_cy = INT32_MIN, max_cz = INT32_MIN;
    for (const auto& [coord, chunk] : chunks) {
        min_cx = std::min(min_cx, coord.x); max_cx = std::max(max_cx, coord.x);
        min_cy = std::min(min_cy, coord.y); max_cy = std::max(max_cy, coord.y);
        min_cz = std::min(min_cz, coord.z); max_cz = std::max(max_cz, coord.z);
    }
    *minOut = simd::int3{min_cx, min_cy, min_cz};
    *dimOut = simd::int3{max_cx - min_cx + 1,
                         max_cy - min_cy + 1,
                         max_cz - min_cz + 1};

    const size_t coarse_count =
        static_cast<size_t>((*dimOut).x) *
        static_cast<size_t>((*dimOut).y) *
        static_cast<size_t>((*dimOut).z);
    std::vector<uint32_t> coarse(coarse_count, 0);
    const size_t pool_bytes = chunks.size() * VG::kChunkVolume;
    *poolOut = [_device newBufferWithLength:pool_bytes
                                    options:MTLResourceStorageModeShared];
    (*poolOut).label = poolLabel;
    auto* pool = static_cast<uint8_t*>((*poolOut).contents);
    uint32_t pool_idx = 1;
    for (const auto& [coord, chunk] : chunks) {
        const size_t cgi =
            static_cast<size_t>(coord.x - min_cx) +
            static_cast<size_t>(coord.y - min_cy) *
                static_cast<size_t>((*dimOut).x) +
            static_cast<size_t>(coord.z - min_cz) *
                static_cast<size_t>((*dimOut).x) *
                static_cast<size_t>((*dimOut).y);
        coarse[cgi] = pool_idx;
        std::memcpy(pool + (pool_idx - 1) * VG::kChunkVolume,
                    chunk->cells, VG::kChunkVolume);
        ++pool_idx;
    }
    *coarseOut = [_device newBufferWithBytes:coarse.data()
                                     length:coarse.size() * sizeof(uint32_t)
                                    options:MTLResourceStorageModeShared];
    (*coarseOut).label = coarseLabel;
}

// Upload the palette into its GPU buffer. Lazy-allocates _paletteBuffer
// on first call. Cheap (1 KB memcpy).
- (void)uploadPalette:(macvoxel::Document*)doc {
    std::array<simd::float4, 256> pal_floats{};
    for (size_t i = 0; i < 256; ++i) {
        const macvoxel::Color c = doc->palette.Get(static_cast<uint8_t>(i));
        pal_floats[i] = simd::float4{
            c.r / 255.0f, c.g / 255.0f, c.b / 255.0f, c.a / 255.0f,
        };
    }
    if (_paletteBuffer == nil) {
        _paletteBuffer =
            [_device newBufferWithBytes:pal_floats.data()
                                 length:sizeof(pal_floats)
                                options:MTLResourceStorageModeShared];
        _paletteBuffer.label = @"RaycastPalette";
        return;
    }
    std::memcpy(_paletteBuffer.contents, pal_floats.data(), sizeof(pal_floats));
}


- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                     view:(simd::float4x4)view
               projection:(simd::float4x4)projection
              cameraWorld:(simd::float3)cameraWorld
                  context:(macvoxel::EditorContext*)ctx
            volumeTexture:(VolumeTexture*)docVolumeTex {
    if (ctx == nullptr || docVolumeTex == nil) return;
    macvoxel::Document* doc = &ctx->document;
    // Palette upload is independent of geometry; doc volume is synced
    // by the owner (MetalScene) before this encode.
    if (_paletteBuffer == nil ||
        _cachedPaletteVersion != doc->palette_version) {
        [self uploadPalette:doc];
        _cachedPaletteVersion = doc->palette_version;
    }
    if (_paletteBuffer == nil) return;
    _cacheValid = YES;

    // Resolve which overlay (if any) feeds the additions slot this frame.
    // FloatingBuffer (selection move/paste/transform) and PreviewOverlay
    // (shape/face/generator preview) are mutually exclusive at the gesture
    // level, so they share one slot — the source tag tracks which one
    // last filled it so a switch invalidates the cache cleanly.
    const macvoxel::FloatingBuffer& fb = ctx->floating_buffer;
    const macvoxel::PreviewOverlay& prev = ctx->preview;
    const OverlaySource active_source =
        fb.active ? OverlaySource::FloatingBuffer
        : (prev.active ? OverlaySource::Preview : OverlaySource::None);

    if (active_source == OverlaySource::FloatingBuffer) {
        if (!_bufBuilt || _bufSource != active_source ||
            _bufLastVersion != fb.version) {
            [self rebuildSparseSlotFromGrid:fb.grid
                                     coarse:&_bufCoarseBuffer
                                       pool:&_bufPoolBuffer
                                  coarseMin:&_bufCoarseMin
                                  coarseDim:&_bufCoarseDim
                                 coarseName:@"RaycastBufCoarse"
                                   poolName:@"RaycastBufPool"];
            _bufBuilt = (_bufCoarseBuffer != nil);
            _bufLastVersion = fb.version;
            _bufSource = active_source;
        }
    } else if (active_source == OverlaySource::Preview) {
        if (!_bufBuilt || _bufSource != active_source ||
            _bufLastVersion != prev.version) {
            [self rebuildSparseSlotFromGrid:prev.additions
                                     coarse:&_bufCoarseBuffer
                                       pool:&_bufPoolBuffer
                                  coarseMin:&_bufCoarseMin
                                  coarseDim:&_bufCoarseDim
                                 coarseName:@"RaycastBufCoarse"
                                   poolName:@"RaycastBufPool"];
            _bufBuilt = (_bufCoarseBuffer != nil);
            _bufLastVersion = prev.version;
            _bufSource = active_source;
        }
        if (!_remBuilt || _remLastVersion != prev.version) {
            [self rebuildSparseSlotFromGrid:prev.removals
                                     coarse:&_remCoarseBuffer
                                       pool:&_remPoolBuffer
                                  coarseMin:&_remCoarseMin
                                  coarseDim:&_remCoarseDim
                                 coarseName:@"RaycastRemCoarse"
                                   poolName:@"RaycastRemPool"];
            _remBuilt = (_remCoarseBuffer != nil);
            _remLastVersion = prev.version;
        }
    } else {
        if (_bufBuilt) {
            _bufCoarseBuffer = nil;
            _bufPoolBuffer = nil;
            _bufBuilt = NO;
            _bufSource = OverlaySource::None;
        }
        if (_remBuilt) {
            _remCoarseBuffer = nil;
            _remPoolBuffer = nil;
            _remBuilt = NO;
        }
    }
    // Removals are preview-only — drop them whenever the active overlay
    // isn't a preview, so a leftover removal mask never bleeds into a
    // floating-buffer or no-overlay frame.
    if (active_source != OverlaySource::Preview && _remBuilt) {
        _remCoarseBuffer = nil;
        _remPoolBuffer = nil;
        _remBuilt = NO;
    }

    Uniforms u;
    u.inv_vp = simd_inverse(projection * view);
    u.camera_pos = cameraWorld;
    u._pad0 = 0.0f;
    u.light_dir = simd::normalize(simd::float3{0.4f, 0.7f, 0.5f});
    u._pad1 = 0.0f;

    const bool buffer_drawable = _bufBuilt && _bufCoarseBuffer != nil;
    if (buffer_drawable) {
        u.buf_coarse_min = _bufCoarseMin;
        u.buf_coarse_dim = _bufCoarseDim;
        u.buf_offset = (active_source == OverlaySource::FloatingBuffer)
            ? simd::int3{fb.offset_x, fb.offset_y, fb.offset_z}
            : simd::int3{0, 0, 0};
        u.buf_active = 1;
    } else {
        u.buf_coarse_min = simd::int3{0, 0, 0};
        u.buf_coarse_dim = simd::int3{0, 0, 0};
        u.buf_offset = simd::int3{0, 0, 0};
        u.buf_active = 0;
    }
    u._pad2 = 0;
    u._pad3 = 0;

    const bool removals_drawable = _remBuilt && _remCoarseBuffer != nil;
    if (removals_drawable) {
        u.rem_coarse_min = _remCoarseMin;
        u.rem_coarse_dim = _remCoarseDim;
        u.rem_active = 1;
    } else {
        u.rem_coarse_min = simd::int3{0, 0, 0};
        u.rem_coarse_dim = simd::int3{0, 0, 0};
        u.rem_active = 0;
    }
    u._pad4 = 0;

    const macvoxel::EditVolume& vol = doc->volume;
    u.box_min = simd::float3{static_cast<float>(vol.x0),
                             static_cast<float>(vol.y0),
                             static_cast<float>(vol.z0)};
    u.box_max = simd::float3{static_cast<float>(vol.x1 + 1),
                             static_cast<float>(vol.y1 + 1),
                             static_cast<float>(vol.z1 + 1)};
    u._pad5 = 0.0f;
    u._pad6 = 0.0f;

    [encoder pushDebugGroup:@"Voxels (raycast)"];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [encoder setFragmentBuffer:_paletteBuffer offset:0 atIndex:1];
    [encoder setFragmentBuffer:(buffer_drawable ? _bufCoarseBuffer : _stubBuffer)
                        offset:0
                       atIndex:2];
    [encoder setFragmentBuffer:(buffer_drawable ? _bufPoolBuffer : _stubBuffer)
                        offset:0
                       atIndex:3];
    [encoder setFragmentBuffer:(removals_drawable ? _remCoarseBuffer : _stubBuffer)
                        offset:0
                       atIndex:4];
    [encoder setFragmentBuffer:(removals_drawable ? _remPoolBuffer : _stubBuffer)
                        offset:0
                       atIndex:5];
    [encoder setFragmentTexture:docVolumeTex.texture atIndex:0];
    [encoder setFragmentTexture:docVolumeTex.oracleTexture atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:3];
    [encoder popDebugGroup];
}

@end
