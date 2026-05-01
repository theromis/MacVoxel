#import "VoxelRenderer.h"

#import <cstdio>
#include <array>
#include <cstdint>
#include <unordered_map>
#include <vector>

#include "Document.h"
#include "MeshBuilder.h"

namespace {

struct Uniforms {
    simd::float4x4 vp;
    simd::float3 light_dir;
    float _pad0;
};

NSString* const kShaderSource = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    short3 grid_pos [[attribute(0)]];
    uchar2 packed   [[attribute(1)]];  // .x = normal_idx, .y = palette_idx
};

struct Uniforms {
    float4x4 vp;
    float3   light_dir;
    float    _pad0;
};

struct V2F {
    float4 clip_pos [[position]];
    float3 normal;
    float3 color;
};

constant float3 kNormals[6] = {
    float3( 1.0,  0.0,  0.0),  // 0:+X
    float3(-1.0,  0.0,  0.0),  // 1:-X
    float3( 0.0,  1.0,  0.0),  // 2:+Y in .vox grid space
    float3( 0.0, -1.0,  0.0),  // 3:-Y
    float3( 0.0,  0.0,  1.0),  // 4:+Z (vertical in .vox)
    float3( 0.0,  0.0, -1.0),  // 5:-Z
};

vertex V2F mesh_vertex(VertexIn in [[stage_in]],
                       constant Uniforms& u [[buffer(2)]],
                       constant float4* palette [[buffer(3)]]) {
    // .vox source is Z-up; we render Y-up. +90° rotation around X
    // (a proper rotation — preserves chirality so the mesher's
    // CCW-from-outside winding survives into world space). No center
    // subtraction: voxels render at their actual world positions, so
    // the camera doesn't drift relative to the model when bounds change
    // during editing. Framing is the camera's job.
    float gx = float(in.grid_pos.x);
    float gy = float(in.grid_pos.y);
    float gz = float(in.grid_pos.z);
    float3 world_pos = float3(gx, gz, -gy);

    uint normal_idx = uint(in.packed.x);
    uint palette_idx = uint(in.packed.y);
    float3 gn = kNormals[normal_idx];
    float3 world_normal = float3(gn.x, gn.z, -gn.y);

    V2F out;
    out.clip_pos = u.vp * float4(world_pos, 1.0);
    out.normal = world_normal;
    out.color = palette[palette_idx].rgb;
    return out;
}

fragment float4 mesh_fragment(V2F in [[stage_in]],
                              constant Uniforms& u [[buffer(2)]]) {
    float3 n = normalize(in.normal);
    float ndl = max(dot(n, u.light_dir), 0.0);
    float lambert = 0.3 + 0.7 * ndl;
    return float4(in.color * lambert, 1.0);
}
)MSL";

}  // namespace

// Per-chunk mesh cache. Each chunk owns its own MTLBuffers — drawing
// iterates the map and issues one drawIndexedPrimitives per non-empty
// chunk. Avoids the concat step that was the drag-paint bottleneck on
// huge scenes (memcpy of 100+ MB into the master buffer per edit).
struct ChunkMeshCache {
    uint32_t cached_version = 0;
    bool valid = false;
    id<MTLBuffer> vertexBuffer;
    id<MTLBuffer> indexBuffer;
    uint32_t vertexCount = 0;
    uint32_t indexCount = 0;
};

@implementation VoxelRenderer {
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLDepthStencilState> _depthState;
    id<MTLBuffer> _paletteBuffer;

    std::unordered_map<macvoxel::VoxelGrid::ChunkCoord,
                       ChunkMeshCache,
                       macvoxel::VoxelGrid::ChunkCoordHash>
        _chunkCaches;
    uint64_t _cachedDocVersion;
    BOOL _cacheValid;
    uint32_t _totalVertexCount;
    uint32_t _totalIndexCount;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat
                   depthFormat:(MTLPixelFormat)depthFormat {
    self = [super init];
    if (self == nil) return nil;
    _device = device;

    if (![self buildPipelineWithColorFormat:colorFormat depthFormat:depthFormat]) {
        return nil;
    }
    [self buildDepthState];
    return self;
}

- (uint32_t)lastVertexCount { return _totalVertexCount; }
- (uint32_t)lastIndexCount { return _totalIndexCount; }
- (uint32_t)lastQuadCount { return _totalIndexCount / 6; }

// ---------------------------------------------------------------------------
// Static setup
// ---------------------------------------------------------------------------

- (BOOL)buildPipelineWithColorFormat:(MTLPixelFormat)colorFormat
                         depthFormat:(MTLPixelFormat)depthFormat {
    NSError* error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:kShaderSource
                                                   options:nil
                                                     error:&error];
    if (library == nil) {
        fprintf(stderr, "MacVoxel: failed to compile mesh shaders: %s\n",
                [[error localizedDescription] UTF8String]);
        return NO;
    }
    id<MTLFunction> vfn = [library newFunctionWithName:@"mesh_vertex"];
    id<MTLFunction> ffn = [library newFunctionWithName:@"mesh_fragment"];

    MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
    vd.attributes[0].format = MTLVertexFormatShort3;
    vd.attributes[0].offset = 0;
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatUChar2;
    vd.attributes[1].offset = 6;
    vd.attributes[1].bufferIndex = 0;
    vd.layouts[0].stride = sizeof(macvoxel::MeshVertex);
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.label = @"MacVoxel Mesh";
    desc.vertexFunction = vfn;
    desc.fragmentFunction = ffn;
    desc.vertexDescriptor = vd;
    desc.colorAttachments[0].pixelFormat = colorFormat;
    desc.depthAttachmentPixelFormat = depthFormat;

    _pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (_pipeline == nil) {
        fprintf(stderr, "MacVoxel: failed to build mesh pipeline: %s\n",
                [[error localizedDescription] UTF8String]);
        return NO;
    }
    return YES;
}

- (void)buildDepthState {
    MTLDepthStencilDescriptor* dsd = [[MTLDepthStencilDescriptor alloc] init];
    dsd.depthCompareFunction = MTLCompareFunctionLess;
    dsd.depthWriteEnabled = YES;
    _depthState = [_device newDepthStencilStateWithDescriptor:dsd];
}

// ---------------------------------------------------------------------------
// Document-driven cache
// ---------------------------------------------------------------------------

- (void)rebuildFromDocument:(macvoxel::Document*)doc {
    auto& grid = doc->grid;
    const auto& chunks = grid.chunks();

    // Drop caches for chunks that no longer exist (erased to empty during
    // the last batch of edits, or replaced wholesale by File > Open).
    for (auto it = _chunkCaches.begin(); it != _chunkCaches.end(); ) {
        if (chunks.find(it->first) == chunks.end()) {
            it = _chunkCaches.erase(it);
        } else {
            ++it;
        }
    }

    // Decide which chunks need (re)meshing. For incremental edits the
    // grid hands us its dirty set (a few entries); on the first rebuild
    // after a wholesale doc replacement we may have a fresh grid with no
    // dirty entries but lots of chunks not yet in our cache — fall back
    // to "everything not cached" for those.
    auto dirty = grid.TakeDirtyChunks();
    if (dirty.empty()) {
        for (const auto& [coord, chunk] : chunks) {
            auto it = _chunkCaches.find(coord);
            if (it == _chunkCaches.end() || !it->second.valid) {
                dirty.insert(coord);
            }
        }
    }

    std::vector<macvoxel::MeshVertex> verts_scratch;
    std::vector<uint32_t> idx_scratch;
    uint32_t total_verts = 0;
    uint32_t total_indices = 0;

    // Existing cache contributions (chunks we won't touch this rebuild).
    for (const auto& [coord, cache] : _chunkCaches) {
        if (dirty.find(coord) != dirty.end()) continue;
        total_verts += cache.vertexCount;
        total_indices += cache.indexCount;
    }

    // Re-mesh dirty chunks. Each owns its own MTLBuffers; nothing global
    // gets touched.
    for (const auto& coord : dirty) {
        auto chunk_it = chunks.find(coord);
        if (chunk_it == chunks.end()) {
            _chunkCaches.erase(coord);
            continue;
        }
        const auto& chunk = *chunk_it->second;
        ChunkMeshCache& cache = _chunkCaches[coord];

        verts_scratch.clear();
        idx_scratch.clear();
        if (chunk.filled_count > 0) {
            macvoxel::GreedyMeshChunk(grid, coord, chunk,
                                      &verts_scratch, &idx_scratch);
        }
        cache.vertexCount = static_cast<uint32_t>(verts_scratch.size());
        cache.indexCount = static_cast<uint32_t>(idx_scratch.size());
        if (cache.vertexCount > 0) {
            const size_t v_bytes =
                verts_scratch.size() * sizeof(macvoxel::MeshVertex);
            cache.vertexBuffer =
                [_device newBufferWithBytes:verts_scratch.data()
                                     length:v_bytes
                                    options:MTLResourceStorageModeShared];
            cache.vertexBuffer.label = @"ChunkVertices";
            const size_t i_bytes = idx_scratch.size() * sizeof(uint32_t);
            cache.indexBuffer =
                [_device newBufferWithBytes:idx_scratch.data()
                                     length:i_bytes
                                    options:MTLResourceStorageModeShared];
            cache.indexBuffer.label = @"ChunkIndices";
        } else {
            cache.vertexBuffer = nil;
            cache.indexBuffer = nil;
        }
        cache.cached_version = chunk.version;
        cache.valid = true;
        total_verts += cache.vertexCount;
        total_indices += cache.indexCount;
    }
    _totalVertexCount = total_verts;
    _totalIndexCount = total_indices;

    // Palette buffer: 256 float4 RGBA in [0, 1].
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
    _paletteBuffer.label = @"VoxelPalette";

    _cachedDocVersion = doc->version;
    _cacheValid = YES;
}

// ---------------------------------------------------------------------------
// Per-frame draw
// ---------------------------------------------------------------------------

- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                     view:(simd::float4x4)view
               projection:(simd::float4x4)projection
                 document:(macvoxel::Document*)doc {
    if (doc == nullptr) return;
    if (!_cacheValid || _cachedDocVersion != doc->version) {
        [self rebuildFromDocument:doc];
    }
    if (_totalIndexCount == 0) return;

    Uniforms u;
    u.vp = projection * view;
    u.light_dir = simd::normalize(simd::float3{0.4f, 0.7f, 0.5f});
    u._pad0 = 0.0f;

    [encoder pushDebugGroup:@"Voxels"];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setDepthStencilState:_depthState];
    [encoder setCullMode:MTLCullModeBack];
    [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
    [encoder setVertexBytes:&u length:sizeof(u) atIndex:2];
    [encoder setVertexBuffer:_paletteBuffer offset:0 atIndex:3];
    [encoder setFragmentBytes:&u length:sizeof(u) atIndex:2];
    for (const auto& [coord, cache] : _chunkCaches) {
        if (cache.indexCount == 0) continue;
        [encoder setVertexBuffer:cache.vertexBuffer offset:0 atIndex:0];
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:cache.indexCount
                             indexType:MTLIndexTypeUInt32
                           indexBuffer:cache.indexBuffer
                     indexBufferOffset:0];
    }
    [encoder popDebugGroup];
}

@end
