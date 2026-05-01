#import "RaycastRenderer.h"

#import <cstdio>
#include <array>
#include <cstdint>
#include <cstring>
#include <vector>

#include "Document.h"

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
    constant float4* palette [[buffer(3)]])
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

    // Clip the ray against the scene AABB (in grid voxel coords). Without
    // this, a camera outside the model's chunk extents would hit the
    // outside-bounds early-out on the very first DDA step and return SKY,
    // never reaching the geometry.
    float3 aabb_min = float3(u.coarse_min) * float(kChunkSize);
    float3 aabb_max = float3(u.coarse_min + u.coarse_dim) * float(kChunkSize);
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

    // Lookup helper inlined into the loop body for clarity.
    for (int s = 0; s < kMaxSteps; ++s) {
        // Chunk coord: arithmetic shift on signed ints rounds toward -inf
        // in Metal, matching C++20 and our CPU code.
        int3 chunk_c;
        chunk_c.x = cell.x >> int(kChunkBits);
        chunk_c.y = cell.y >> int(kChunkBits);
        chunk_c.z = cell.z >> int(kChunkBits);

        int3 cgc = chunk_c - u.coarse_min;
        if (cgc.x < 0 || cgc.y < 0 || cgc.z < 0 ||
            cgc.x >= u.coarse_dim.x || cgc.y >= u.coarse_dim.y ||
            cgc.z >= u.coarse_dim.z) {
            // Outside the coarse grid: scene is bounded, this is sky.
            return float4(0.118, 0.118, 0.18, 1.0);
        }

        uint coarse_idx = uint(cgc.x) +
                          uint(cgc.y) * uint(u.coarse_dim.x) +
                          uint(cgc.z) * uint(u.coarse_dim.x) * uint(u.coarse_dim.y);
        uint pool_idx = coarse_grid[coarse_idx];

        uint cell_val = 0u;
        if (pool_idx != 0u) {
            uint lx = uint(cell.x) & kChunkMask;
            uint ly = uint(cell.y) & kChunkMask;
            uint lz = uint(cell.z) & kChunkMask;
            uint local_idx = lx + ly * kChunkSize + lz * kChunkSize * kChunkSize;
            cell_val = uint(chunk_pool[pool_idx - 1u].cells[local_idx]);
        }

        if (cell_val != 0u) {
            // Hit. Build world normal from which face we crossed last.
            float3 grid_normal = float3(0.0);
            if (last_axis == 0) grid_normal.x = -float(step_dir.x);
            else if (last_axis == 1) grid_normal.y = -float(step_dir.y);
            else if (last_axis == 2) grid_normal.z = -float(step_dir.z);
            // Same rotation as positions: world = (gx, gz, -gy).
            float3 world_normal = float3(grid_normal.x, grid_normal.z, -grid_normal.y);
            float ndl = max(dot(world_normal, u.light_dir), 0.0);
            float lambert = 0.3 + 0.7 * ndl;
            float3 base = palette[cell_val].rgb;
            return float4(base * lambert, 1.0);
        }

        // Step to next cell.
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
    return self;
}

- (uint32_t)lastChunkCount { return _chunkCount; }

// ---------------------------------------------------------------------------
// GPU upload — wholesale on doc->version change. Incremental upload is a
// future optimization; for now even Rancho Ancon's ~200 MB rebuild is a
// few hundred ms one-shot, then editing is free.
// ---------------------------------------------------------------------------

- (void)rebuildFromDocument:(const macvoxel::Document*)doc {
    using VG = macvoxel::VoxelGrid;
    const auto& chunks = doc->grid.chunks();
    _chunkCount = static_cast<uint32_t>(chunks.size());

    if (chunks.empty()) {
        _coarseMin = simd::int3{0, 0, 0};
        _coarseDim = simd::int3{0, 0, 0};
        _coarseBuffer = nil;
        _poolBuffer = nil;
    } else {
        // Compute coarse-grid extents from chunk coords.
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

        // Pool: index 0 reserved as the "empty" sentinel; first real chunk
        // is at pool index 0 inside the buffer but referenced as 1 from
        // coarse_grid (so coarse[i] == 0 means empty without ambiguity).
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
        _coarseBuffer.label = @"RaycastCoarse";
        _poolBuffer = [_device newBufferWithBytes:pool.data()
                                           length:pool.size()
                                          options:MTLResourceStorageModeShared];
        _poolBuffer.label = @"RaycastChunkPool";
    }

    // Palette buffer (same layout the mesh renderer used).
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

    _cachedDocVersion = doc->version;
    _cacheValid = YES;
}

- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                     view:(simd::float4x4)view
               projection:(simd::float4x4)projection
              cameraWorld:(simd::float3)cameraWorld
                 document:(const macvoxel::Document*)doc {
    if (doc == nullptr) return;
    if (!_cacheValid || _cachedDocVersion != doc->version) {
        [self rebuildFromDocument:doc];
    }
    if (_coarseBuffer == nil || _poolBuffer == nil) return;

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

    [encoder pushDebugGroup:@"Voxels (raycast)"];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [encoder setFragmentBuffer:_coarseBuffer offset:0 atIndex:1];
    [encoder setFragmentBuffer:_poolBuffer offset:0 atIndex:2];
    [encoder setFragmentBuffer:_paletteBuffer offset:0 atIndex:3];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:3];
    [encoder popDebugGroup];
}

@end
