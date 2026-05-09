#import "RaycastRenderer.h"

#import <cstdio>
#include <array>
#include <cstdint>
#include <cstring>
#include <vector>

#include "Document.h"
#include "FloatingBuffer.h"

namespace {

struct Uniforms {
    simd::float4x4 inv_vp;
    simd::float3 camera_pos;
    float _pad0;
    simd::int3 coarse_min;     // min chunk coord (signed; can be negative)
    int _pad1;
    simd::int3 coarse_dim;     // # of chunks per axis in the coarse grid
    int _pad2;
    simd::float3 light_dir;
    float _pad3;
    // Floating-buffer overlay: a second sparse grid the shader DDA
    // samples in parallel. Renders "on top of" the document in any
    // cell where the buffer is non-zero (lift / paste / move-drag
    // stage their cells here, so the document grid stays untouched
    // until the user explicitly commits). When `buf_active == 0` all
    // buf_* fields are ignored.
    simd::int3 buf_coarse_min;
    int _pad4;
    simd::int3 buf_coarse_dim;
    int _pad5;
    simd::int3 buf_offset;     // world cell delta added to buffer-local cells
    int buf_active;            // 0 = ignore buffer
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
    int3     coarse_min;
    int      _pad1;
    int3     coarse_dim;
    int      _pad2;
    float3   light_dir;
    float    _pad3;
    int3     buf_coarse_min;
    int      _pad4;
    int3     buf_coarse_dim;
    int      _pad5;
    int3     buf_offset;
    int      buf_active;
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

fragment float4 raycast_fragment(
    VertOut in [[stage_in]],
    constant Uniforms& u [[buffer(0)]],
    device const uint* coarse_grid [[buffer(1)]],
    device const Chunk* chunk_pool [[buffer(2)]],
    constant float4* palette [[buffer(3)]],
    device const uint* buf_coarse_grid [[buffer(4)]],
    device const Chunk* buf_chunk_pool [[buffer(5)]])
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

    // Combined AABB clip. Without the buffer this is just the doc's
    // chunk extents; with it, we expand to include the buffer's footprint
    // (which can wander outside the doc, e.g. dragging a paste off into
    // empty space). The early reject keeps cameras far from any geometry
    // from spinning the DDA in pure void.
    float3 doc_min = float3(u.coarse_min) * float(kChunkSize);
    float3 doc_max = float3(u.coarse_min + u.coarse_dim) * float(kChunkSize);
    float3 aabb_min = doc_min;
    float3 aabb_max = doc_max;
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
        return float4(0.118, 0.118, 0.18, 1.0);
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

    // Dual-volume DDA. At each cell we look up both volumes' chunk
    // indices; if both chunks are empty we coarse-skip to whichever
    // chunk boundary comes first (so the skip never overshoots a
    // non-empty chunk in either volume). When a cell is non-empty we
    // sample the buffer first — it renders on top of the document
    // wherever the two overlap (which only happens during a paste at
    // offset 0; once the user starts dragging, the lift cleared the
    // document cells under the buffer's source position).
    for (int s = 0; s < kMaxSteps; ++s) {
        int3 chunk_c;
        chunk_c.x = cell.x >> int(kChunkBits);
        chunk_c.y = cell.y >> int(kChunkBits);
        chunk_c.z = cell.z >> int(kChunkBits);

        int3 cgc = chunk_c - u.coarse_min;
        bool doc_in = (cgc.x >= 0 && cgc.y >= 0 && cgc.z >= 0 &&
                       cgc.x < u.coarse_dim.x &&
                       cgc.y < u.coarse_dim.y &&
                       cgc.z < u.coarse_dim.z);
        uint pool_idx_doc = 0u;
        if (doc_in) {
            uint coarse_idx = uint(cgc.x) +
                              uint(cgc.y) * uint(u.coarse_dim.x) +
                              uint(cgc.z) * uint(u.coarse_dim.x) * uint(u.coarse_dim.y);
            pool_idx_doc = coarse_grid[coarse_idx];
        }

        // Buffer-side lookup (only when the buffer is active and the
        // cell falls inside its chunk extents in *world* coords).
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

        // Outside both volumes' chunk extents: nothing to hit anywhere
        // along the ray's continuation either (the AABB clip already
        // guaranteed we'd enter at least one of them, so leaving both
        // means we exited the union).
        if (!doc_in && !buf_in) {
            return float4(0.118, 0.118, 0.18, 1.0);
        }

        if (pool_idx_doc == 0u && pool_idx_buf == 0u) {
            // Both volumes empty here. Skip to whichever chunk boundary
            // comes first, so the next iteration lands at the earliest
            // cell that *might* be non-empty in either volume.
            float3 chunk_min_doc = float3(chunk_c) * float(kChunkSize);
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
            int3 chunk_c_skip = (t_exit_doc <= t_exit_buf) ? chunk_c : chunk_c_buf;
            int3 base_offset = (t_exit_doc <= t_exit_buf) ? int3(0) : u.buf_offset;
            int exit_axis = (t_face.x <= t_face.y && t_face.x <= t_face.z) ? 0
                          : (t_face.y <= t_face.z) ? 1 : 2;
            last_axis = exit_axis;

            float eps = max(1e-3, t_skip * 1e-5);
            float3 pos = ray_origin + ray_dir * (t_skip + eps);
            cell.x = int(floor(pos.x));
            cell.y = int(floor(pos.y));
            cell.z = int(floor(pos.z));
            if (exit_axis == 0) {
                cell.x = step_dir.x > 0
                    ? (chunk_c_skip.x + 1) * int(kChunkSize) + base_offset.x
                    :  chunk_c_skip.x      * int(kChunkSize) + base_offset.x - 1;
            } else if (exit_axis == 1) {
                cell.y = step_dir.y > 0
                    ? (chunk_c_skip.y + 1) * int(kChunkSize) + base_offset.y
                    :  chunk_c_skip.y      * int(kChunkSize) + base_offset.y - 1;
            } else {
                cell.z = step_dir.z > 0
                    ? (chunk_c_skip.z + 1) * int(kChunkSize) + base_offset.z
                    :  chunk_c_skip.z      * int(kChunkSize) + base_offset.z - 1;
            }
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

        // At least one chunk has cells. Sample the buffer first — when
        // it overlaps the document the buffer wins.
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
        if (pool_idx_doc != 0u) {
            uint lx = uint(cell.x) & kChunkMask;
            uint ly = uint(cell.y) & kChunkMask;
            uint lz = uint(cell.z) & kChunkMask;
            uint local_idx = lx + ly * kChunkSize + lz * kChunkSize * kChunkSize;
            uint val = uint(chunk_pool[pool_idx_doc - 1u].cells[local_idx]);
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

        // Both chunks present, both cells empty here. Cell-level step.
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
    return float4(0.118, 0.118, 0.18, 1.0);
}
)MSL";

}  // namespace

@implementation RaycastRenderer {
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLBuffer> _coarseBuffer;
    id<MTLBuffer> _poolBuffer;
    id<MTLBuffer> _paletteBuffer;
    uint64_t _cachedDocVersion;
    BOOL _cacheValid;
    simd::int3 _coarseMin;
    simd::int3 _coarseDim;
    uint32_t _chunkCount;
    // Pool slot bookkeeping: how many slots are currently in use, and how
    // many fit in the buffer's current allocation. Slot 0 is reserved as
    // the "empty" sentinel that coarse_grid uses (1-based pool indices).
    uint32_t _poolSlotsUsed;
    uint32_t _poolSlotsCapacity;
    // Palette state (cached so we don't re-upload it every edit).
    uint64_t _paletteSignature;
    // Floating-buffer resources. Built fresh from FloatingBuffer.grid
    // whenever `version` advances; pure offset changes (the dragging
    // case) cost a single uniform write, no rebuild.
    id<MTLBuffer> _bufCoarseBuffer;
    id<MTLBuffer> _bufPoolBuffer;
    uint64_t _bufLastVersion;
    BOOL _bufBuilt;
    simd::int3 _bufCoarseMin;
    simd::int3 _bufCoarseDim;
    // Stub buffers always bound at fragment slots 4 and 5 — Metal needs
    // a valid backing even when buf_active = 0 in the uniforms.
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

- (uint32_t)lastChunkCount { return _chunkCount; }

- (size_t)lastGPUBytes {
    size_t bytes = 0;
    if (_coarseBuffer != nil) bytes += _coarseBuffer.length;
    if (_poolBuffer != nil) bytes += _poolBuffer.length;
    return bytes;
}

- (void)invalidate {
    _cacheValid = NO;
}

// ---------------------------------------------------------------------------
// GPU upload. The hot path is incremental: drain the grid's dirty-chunk
// set and update only the affected slots in the chunk pool. Wholesale
// rebuild is reserved for the cases where the chunk-coord bounds shift
// (a fresh document, or an edit that places voxels past the previous
// extents) — there the coarse grid itself has to be reshaped.
// ---------------------------------------------------------------------------

// Build (or rebuild) the floating-buffer's GPU mirror. Same coarse-grid +
// chunk-pool layout as the document, just smaller. Called when
// FloatingBuffer.version advances since the last upload — pure offset
// changes (the dragging case) don't trigger a rebuild.
- (void)rebuildFloatingResources:(const macvoxel::FloatingBuffer&)fb {
    using VG = macvoxel::VoxelGrid;
    const auto& chunks = fb.grid.chunks();
    if (chunks.empty()) {
        _bufCoarseBuffer = nil;
        _bufPoolBuffer = nil;
        _bufCoarseMin = simd::int3{0, 0, 0};
        _bufCoarseDim = simd::int3{0, 0, 0};
        _bufBuilt = NO;
        _bufLastVersion = fb.version;
        return;
    }

    int32_t min_cx = INT32_MAX, min_cy = INT32_MAX, min_cz = INT32_MAX;
    int32_t max_cx = INT32_MIN, max_cy = INT32_MIN, max_cz = INT32_MIN;
    for (const auto& [coord, chunk] : chunks) {
        min_cx = std::min(min_cx, coord.x); max_cx = std::max(max_cx, coord.x);
        min_cy = std::min(min_cy, coord.y); max_cy = std::max(max_cy, coord.y);
        min_cz = std::min(min_cz, coord.z); max_cz = std::max(max_cz, coord.z);
    }
    _bufCoarseMin = simd::int3{min_cx, min_cy, min_cz};
    _bufCoarseDim = simd::int3{max_cx - min_cx + 1,
                               max_cy - min_cy + 1,
                               max_cz - min_cz + 1};

    const size_t coarse_count =
        static_cast<size_t>(_bufCoarseDim.x) *
        static_cast<size_t>(_bufCoarseDim.y) *
        static_cast<size_t>(_bufCoarseDim.z);
    std::vector<uint32_t> coarse(coarse_count, 0);
    const size_t pool_bytes = chunks.size() * VG::kChunkVolume;
    _bufPoolBuffer = [_device newBufferWithLength:pool_bytes
                                          options:MTLResourceStorageModeShared];
    _bufPoolBuffer.label = @"RaycastBufPool";
    auto* pool = static_cast<uint8_t*>(_bufPoolBuffer.contents);
    uint32_t pool_idx = 1;
    for (const auto& [coord, chunk] : chunks) {
        const size_t cgi =
            static_cast<size_t>(coord.x - min_cx) +
            static_cast<size_t>(coord.y - min_cy) *
                static_cast<size_t>(_bufCoarseDim.x) +
            static_cast<size_t>(coord.z - min_cz) *
                static_cast<size_t>(_bufCoarseDim.x) *
                static_cast<size_t>(_bufCoarseDim.y);
        coarse[cgi] = pool_idx;
        std::memcpy(pool + (pool_idx - 1) * VG::kChunkVolume,
                    chunk->cells, VG::kChunkVolume);
        ++pool_idx;
    }
    _bufCoarseBuffer = [_device newBufferWithBytes:coarse.data()
                                           length:coarse.size() * sizeof(uint32_t)
                                          options:MTLResourceStorageModeShared];
    _bufCoarseBuffer.label = @"RaycastBufCoarse";
    _bufBuilt = YES;
    _bufLastVersion = fb.version;
}

- (void)wholesaleRebuildFromDocument:(macvoxel::Document*)doc {
    using VG = macvoxel::VoxelGrid;
    const auto& chunks = doc->grid.chunks();
    _chunkCount = static_cast<uint32_t>(chunks.size());

    if (chunks.empty()) {
        _coarseMin = simd::int3{0, 0, 0};
        _coarseDim = simd::int3{0, 0, 0};
        _coarseBuffer = nil;
        _poolBuffer = nil;
        _poolSlotsUsed = 0;
        _poolSlotsCapacity = 0;
    } else {
        // Coarse-grid extents from chunk coords, inflated with headroom so
        // edits that grow the model into nearby empty chunks don't fall
        // outside the cached bounds and trigger another wholesale rebuild.
        // Without this, dragging the brush / Face tool into empty space
        // re-uploads the entire chunk pool every frame: two MTLBuffer
        // allocations + a memcpy per chunk for the whole document, which
        // tanks framerate on anything beyond a few-chunk model.
        //
        // Cost is one bigger coarse buffer (4 bytes per padded slot —
        // trivial). The pool buffer is unaffected; growPoolToSlots: still
        // amortizes new-slot growth via doubling.
        constexpr int32_t kPaddingChunks = 4;
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
        min_cx -= kPaddingChunks; min_cy -= kPaddingChunks; min_cz -= kPaddingChunks;
        max_cx += kPaddingChunks; max_cy += kPaddingChunks; max_cz += kPaddingChunks;
        _coarseMin = simd::int3{min_cx, min_cy, min_cz};
        _coarseDim = simd::int3{max_cx - min_cx + 1,
                                max_cy - min_cy + 1,
                                max_cz - min_cz + 1};

        const size_t coarse_count =
            static_cast<size_t>(_coarseDim.x) *
            static_cast<size_t>(_coarseDim.y) *
            static_cast<size_t>(_coarseDim.z);
        std::vector<uint32_t> coarse(coarse_count, 0);

        // Pool capacity: one slot per chunk plus headroom so subsequent
        // edits can append without reallocating immediately.
        _poolSlotsCapacity = static_cast<uint32_t>(
            std::max<size_t>(chunks.size() * 3 / 2 + 16, 64));
        const size_t pool_bytes =
            static_cast<size_t>(_poolSlotsCapacity) * VG::kChunkVolume;
        _poolBuffer = [_device newBufferWithLength:pool_bytes
                                           options:MTLResourceStorageModeShared];
        _poolBuffer.label = @"RaycastChunkPool";

        auto* pool = static_cast<uint8_t*>(_poolBuffer.contents);
        uint32_t pool_idx = 1;  // 1-based; 0 means empty in the coarse grid
        for (const auto& [coord, chunk] : chunks) {
            const size_t cgi =
                static_cast<size_t>(coord.x - min_cx) +
                static_cast<size_t>(coord.y - min_cy) *
                    static_cast<size_t>(_coarseDim.x) +
                static_cast<size_t>(coord.z - min_cz) *
                    static_cast<size_t>(_coarseDim.x) *
                    static_cast<size_t>(_coarseDim.y);
            coarse[cgi] = pool_idx;
            std::memcpy(pool + (pool_idx - 1) * VG::kChunkVolume,
                        chunk->cells, VG::kChunkVolume);
            ++pool_idx;
        }
        _poolSlotsUsed = pool_idx - 1;

        _coarseBuffer = [_device newBufferWithBytes:coarse.data()
                                             length:coarse.size() * sizeof(uint32_t)
                                            options:MTLResourceStorageModeShared];
        _coarseBuffer.label = @"RaycastCoarse";
    }

    // Palette buffer.
    std::array<simd::float4, 256> pal_floats{};
    for (size_t i = 0; i < 256; ++i) {
        const macvoxel::Color c = doc->palette.Get(static_cast<uint8_t>(i));
        pal_floats[i] = simd::float4{
            c.r / 255.0f, c.g / 255.0f, c.b / 255.0f, c.a / 255.0f,
        };
    }
    _paletteBuffer = [_device newBufferWithBytes:pal_floats.data()
                                          length:sizeof(pal_floats)
                                         options:MTLResourceStorageModeShared];
    _paletteBuffer.label = @"RaycastPalette";
    _paletteSignature = [self paletteSignature:doc];

    // Wholesale rebuild covered everything; flush the dirty queue so the
    // next encode doesn't redundantly re-process those same chunks.
    doc->grid.TakeDirtyChunks();

    _cachedDocVersion = doc->version;
    _cacheValid = YES;
}

- (uint64_t)paletteSignature:(const macvoxel::Document*)doc {
    // Cheap fingerprint of the palette so we can skip re-uploading it
    // when only the grid changed. FNV-1a over the 256 RGBA bytes.
    uint64_t h = 0xcbf29ce484222325ULL;
    const auto* p = reinterpret_cast<const uint8_t*>(doc->palette.data());
    for (size_t i = 0; i < 256 * sizeof(macvoxel::Color); ++i) {
        h ^= p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

- (BOOL)dirtyFitsInExistingBounds:(const macvoxel::VoxelGrid::ChunkSet&)dirty {
    for (const auto& coord : dirty) {
        if (coord.x < _coarseMin.x ||
            coord.y < _coarseMin.y ||
            coord.z < _coarseMin.z ||
            coord.x >= _coarseMin.x + _coarseDim.x ||
            coord.y >= _coarseMin.y + _coarseDim.y ||
            coord.z >= _coarseMin.z + _coarseDim.z) {
            return NO;
        }
    }
    return YES;
}

- (void)growPoolToSlots:(uint32_t)needed {
    using VG = macvoxel::VoxelGrid;
    uint32_t new_cap = std::max(_poolSlotsCapacity * 2, needed);
    new_cap = std::max<uint32_t>(new_cap, 64);
    const size_t new_bytes = static_cast<size_t>(new_cap) * VG::kChunkVolume;
    id<MTLBuffer> new_buf =
        [_device newBufferWithLength:new_bytes
                             options:MTLResourceStorageModeShared];
    new_buf.label = @"RaycastChunkPool";
    if (_poolBuffer != nil && _poolSlotsUsed > 0) {
        std::memcpy(new_buf.contents, _poolBuffer.contents,
                    static_cast<size_t>(_poolSlotsUsed) * VG::kChunkVolume);
    }
    _poolBuffer = new_buf;
    _poolSlotsCapacity = new_cap;
}

- (void)applyDirty:(macvoxel::Document*)doc dirty:(const macvoxel::VoxelGrid::ChunkSet&)dirty {
    using VG = macvoxel::VoxelGrid;
    const auto& chunks = doc->grid.chunks();

    auto* coarse = static_cast<uint32_t*>(_coarseBuffer.contents);

    // First pass: see how many new pool slots we need and grow once.
    uint32_t new_slots_needed = 0;
    for (const auto& coord : dirty) {
        const size_t cgi =
            static_cast<size_t>(coord.x - _coarseMin.x) +
            static_cast<size_t>(coord.y - _coarseMin.y) *
                static_cast<size_t>(_coarseDim.x) +
            static_cast<size_t>(coord.z - _coarseMin.z) *
                static_cast<size_t>(_coarseDim.x) *
                static_cast<size_t>(_coarseDim.y);
        if (coarse[cgi] == 0 && chunks.find(coord) != chunks.end()) {
            ++new_slots_needed;
        }
    }
    if (_poolSlotsUsed + new_slots_needed > _poolSlotsCapacity) {
        [self growPoolToSlots:_poolSlotsUsed + new_slots_needed];
    }

    auto* pool = static_cast<uint8_t*>(_poolBuffer.contents);

    for (const auto& coord : dirty) {
        const size_t cgi =
            static_cast<size_t>(coord.x - _coarseMin.x) +
            static_cast<size_t>(coord.y - _coarseMin.y) *
                static_cast<size_t>(_coarseDim.x) +
            static_cast<size_t>(coord.z - _coarseMin.z) *
                static_cast<size_t>(_coarseDim.x) *
                static_cast<size_t>(_coarseDim.y);

        auto chunk_it = chunks.find(coord);
        if (chunk_it == chunks.end()) {
            // Chunk was deleted (last filled cell cleared). Mark its coarse
            // slot empty; pool slot is left unreclaimed for now (a future
            // free-list could reuse it).
            coarse[cgi] = 0;
            continue;
        }

        uint32_t pool_idx = coarse[cgi];
        if (pool_idx == 0) {
            ++_poolSlotsUsed;
            pool_idx = _poolSlotsUsed;  // 1-based
            coarse[cgi] = pool_idx;
        }
        std::memcpy(pool + (pool_idx - 1) * VG::kChunkVolume,
                    chunk_it->second->cells, VG::kChunkVolume);
    }

    _chunkCount = static_cast<uint32_t>(chunks.size());
}

- (void)updateFromDocument:(macvoxel::Document*)doc {
    auto dirty = doc->grid.TakeDirtyChunks();

    if (!_cacheValid || _coarseBuffer == nil ||
        ![self dirtyFitsInExistingBounds:dirty]) {
        [self wholesaleRebuildFromDocument:doc];
        return;
    }

    if (!dirty.empty()) {
        [self applyDirty:doc dirty:dirty];
    }

    // Palette is far smaller than the chunk pool but still worth skipping
    // when it didn't change. Most edits don't touch it.
    const uint64_t sig = [self paletteSignature:doc];
    if (sig != _paletteSignature) {
        std::array<simd::float4, 256> pal_floats{};
        for (size_t i = 0; i < 256; ++i) {
            const macvoxel::Color c = doc->palette.Get(static_cast<uint8_t>(i));
            pal_floats[i] = simd::float4{
                c.r / 255.0f, c.g / 255.0f, c.b / 255.0f, c.a / 255.0f,
            };
        }
        std::memcpy(_paletteBuffer.contents, pal_floats.data(),
                    sizeof(pal_floats));
        _paletteSignature = sig;
    }

    _cachedDocVersion = doc->version;
}

- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                     view:(simd::float4x4)view
               projection:(simd::float4x4)projection
              cameraWorld:(simd::float3)cameraWorld
                 document:(macvoxel::Document*)doc {
    if (doc == nullptr) return;
    if (!_cacheValid || _cachedDocVersion != doc->version) {
        [self updateFromDocument:doc];
    }
    if (_coarseBuffer == nil || _poolBuffer == nil) return;

    // Floating buffer: rebuild GPU resources only if its grid actually
    // changed since last upload. Offset moves the buffer in O(1) — pure
    // uniform write.
    const macvoxel::FloatingBuffer& fb = macvoxel::CurrentFloatingBuffer();
    if (fb.active) {
        if (!_bufBuilt || _bufLastVersion != fb.version) {
            [self rebuildFloatingResources:fb];
        }
    } else if (_bufBuilt) {
        _bufCoarseBuffer = nil;
        _bufPoolBuffer = nil;
        _bufBuilt = NO;
    }

    Uniforms u;
    u.inv_vp = simd_inverse(projection * view);
    u.camera_pos = cameraWorld;
    u._pad0 = 0.0f;
    u.coarse_min = _coarseMin;
    u._pad1 = 0;
    u.coarse_dim = _coarseDim;
    u._pad2 = 0;
    u.light_dir = simd::normalize(simd::float3{0.4f, 0.7f, 0.5f});
    u._pad3 = 0.0f;

    const bool buffer_drawable = fb.active && _bufBuilt && _bufCoarseBuffer != nil;
    if (buffer_drawable) {
        u.buf_coarse_min = _bufCoarseMin;
        u.buf_coarse_dim = _bufCoarseDim;
        u.buf_offset = simd::int3{fb.offset_x, fb.offset_y, fb.offset_z};
        u.buf_active = 1;
    } else {
        u.buf_coarse_min = simd::int3{0, 0, 0};
        u.buf_coarse_dim = simd::int3{0, 0, 0};
        u.buf_offset = simd::int3{0, 0, 0};
        u.buf_active = 0;
    }
    u._pad4 = 0;
    u._pad5 = 0;

    [encoder pushDebugGroup:@"Voxels (raycast)"];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [encoder setFragmentBuffer:_coarseBuffer offset:0 atIndex:1];
    [encoder setFragmentBuffer:_poolBuffer offset:0 atIndex:2];
    [encoder setFragmentBuffer:_paletteBuffer offset:0 atIndex:3];
    [encoder setFragmentBuffer:(buffer_drawable ? _bufCoarseBuffer : _stubBuffer)
                        offset:0
                       atIndex:4];
    [encoder setFragmentBuffer:(buffer_drawable ? _bufPoolBuffer : _stubBuffer)
                        offset:0
                       atIndex:5];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:3];
    [encoder popDebugGroup];
}

@end
