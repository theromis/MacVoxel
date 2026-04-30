#import "VoxelRenderer.h"

#import <cstdio>
#include <array>
#include <cstdint>
#include <vector>

#include "Document.h"

namespace {

struct CubeVertex {
    float position[3];
    float normal[3];
};
static_assert(sizeof(CubeVertex) == 24, "CubeVertex layout must match shader");

struct Instance {
    int16_t x;
    int16_t y;
    int16_t z;
    int16_t palette_w;  // low 8 bits = palette index
};
static_assert(sizeof(Instance) == 8, "Instance layout must match shader");

constexpr float H = 0.5f;

const std::array<CubeVertex, 24> kCubeVertices = {{
    // +X
    {{ H, -H,  H}, {1, 0, 0}},
    {{ H, -H, -H}, {1, 0, 0}},
    {{ H,  H, -H}, {1, 0, 0}},
    {{ H,  H,  H}, {1, 0, 0}},
    // -X
    {{-H, -H, -H}, {-1, 0, 0}},
    {{-H, -H,  H}, {-1, 0, 0}},
    {{-H,  H,  H}, {-1, 0, 0}},
    {{-H,  H, -H}, {-1, 0, 0}},
    // +Y
    {{-H,  H,  H}, {0, 1, 0}},
    {{ H,  H,  H}, {0, 1, 0}},
    {{ H,  H, -H}, {0, 1, 0}},
    {{-H,  H, -H}, {0, 1, 0}},
    // -Y
    {{-H, -H, -H}, {0, -1, 0}},
    {{ H, -H, -H}, {0, -1, 0}},
    {{ H, -H,  H}, {0, -1, 0}},
    {{-H, -H,  H}, {0, -1, 0}},
    // +Z
    {{-H, -H,  H}, {0, 0, 1}},
    {{ H, -H,  H}, {0, 0, 1}},
    {{ H,  H,  H}, {0, 0, 1}},
    {{-H,  H,  H}, {0, 0, 1}},
    // -Z
    {{ H, -H, -H}, {0, 0, -1}},
    {{-H, -H, -H}, {0, 0, -1}},
    {{-H,  H, -H}, {0, 0, -1}},
    {{ H,  H, -H}, {0, 0, -1}},
}};

const std::array<uint16_t, 36> kCubeIndices = {{
     0,  1,  2,    0,  2,  3,
     4,  5,  6,    4,  6,  7,
     8,  9, 10,    8, 10, 11,
    12, 13, 14,   12, 14, 15,
    16, 17, 18,   16, 18, 19,
    20, 21, 22,   20, 22, 23,
}};

struct Uniforms {
    simd::float4x4 vp;
    simd::float3 center;
    float _pad0;
    simd::float3 light_dir;
    float _pad1;
};

NSString* const kShaderSource = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    short4 voxel    [[attribute(2)]];  // (gx, gy, gz, palette) in grid space
};

struct Uniforms {
    float4x4 vp;
    float3   center;
    float    _pad0;
    float3   light_dir;
    float    _pad1;
};

struct V2F {
    float4 clip_pos [[position]];
    float3 normal;
    float3 color;
};

vertex V2F voxel_vertex(VertexIn in [[stage_in]],
                        constant Uniforms& u [[buffer(2)]],
                        constant float4* palette [[buffer(3)]]) {
    // .vox source is Z-up; we render Y-up, so swap grid Y and Z when
    // computing world position. Center subtraction puts the model AABB at
    // the world origin so the camera target stays at (0,0,0).
    float gx = float(in.voxel.x);
    float gy = float(in.voxel.y);
    float gz = float(in.voxel.z);

    float3 world = float3(
        gx + in.position.x + 0.5 - u.center.x,
        gz + in.position.y + 0.5 - u.center.y,
        gy + in.position.z + 0.5 - u.center.z
    );

    V2F out;
    out.clip_pos = u.vp * float4(world, 1.0);
    out.normal = in.normal;
    int idx = int(in.voxel.w) & 0xff;
    out.color = palette[idx].rgb;
    return out;
}

fragment float4 voxel_fragment(V2F in [[stage_in]],
                               constant Uniforms& u [[buffer(2)]]) {
    float3 n = normalize(in.normal);
    float ndl = max(dot(n, u.light_dir), 0.0);
    float lambert = 0.3 + 0.7 * ndl;
    return float4(in.color * lambert, 1.0);
}
)MSL";

}  // namespace

@implementation VoxelRenderer {
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLDepthStencilState> _depthState;
    id<MTLBuffer> _vertexBuffer;
    id<MTLBuffer> _indexBuffer;
    id<MTLBuffer> _instanceBuffer;
    id<MTLBuffer> _paletteBuffer;

    uint64_t _cachedVersion;
    BOOL _cacheValid;
    uint32_t _instanceCount;
    simd::float3 _center;
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
    [self buildCubeBuffers];
    return self;
}

- (uint32_t)lastInstanceCount {
    return _instanceCount;
}

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
        fprintf(stderr, "MacVoxel: failed to compile voxel shaders: %s\n",
                [[error localizedDescription] UTF8String]);
        return NO;
    }
    id<MTLFunction> vfn = [library newFunctionWithName:@"voxel_vertex"];
    id<MTLFunction> ffn = [library newFunctionWithName:@"voxel_fragment"];

    MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
    vd.attributes[0].format = MTLVertexFormatFloat3;
    vd.attributes[0].offset = offsetof(CubeVertex, position);
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat3;
    vd.attributes[1].offset = offsetof(CubeVertex, normal);
    vd.attributes[1].bufferIndex = 0;
    vd.attributes[2].format = MTLVertexFormatShort4;
    vd.attributes[2].offset = 0;
    vd.attributes[2].bufferIndex = 1;
    vd.layouts[0].stride = sizeof(CubeVertex);
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    vd.layouts[1].stride = sizeof(Instance);
    vd.layouts[1].stepFunction = MTLVertexStepFunctionPerInstance;

    MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.label = @"MacVoxel Voxels";
    desc.vertexFunction = vfn;
    desc.fragmentFunction = ffn;
    desc.vertexDescriptor = vd;
    desc.colorAttachments[0].pixelFormat = colorFormat;
    desc.depthAttachmentPixelFormat = depthFormat;

    _pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (_pipeline == nil) {
        fprintf(stderr, "MacVoxel: failed to build voxel pipeline: %s\n",
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

- (void)buildCubeBuffers {
    _vertexBuffer = [_device newBufferWithBytes:kCubeVertices.data()
                                         length:sizeof(kCubeVertices)
                                        options:MTLResourceStorageModeShared];
    _vertexBuffer.label = @"VoxelCubeVertices";
    _indexBuffer = [_device newBufferWithBytes:kCubeIndices.data()
                                        length:sizeof(kCubeIndices)
                                       options:MTLResourceStorageModeShared];
    _indexBuffer.label = @"VoxelCubeIndices";
}

// ---------------------------------------------------------------------------
// Document-driven cache
// ---------------------------------------------------------------------------

- (void)rebuildFromDocument:(const macvoxel::Document*)doc {
    const macvoxel::Bounds3 b = doc->grid.Bounds();

    // Center: midpoint of bounds. Y/Z swapped so the renderer's Y-up world
    // matches the .vox Z-up source data.
    const float cx = b.empty() ? 0.0f
                               : (static_cast<float>(b.min_x) +
                                  static_cast<float>(b.max_x) + 1.0f) * 0.5f;
    const float cy = b.empty() ? 0.0f
                               : (static_cast<float>(b.min_z) +
                                  static_cast<float>(b.max_z) + 1.0f) * 0.5f;
    const float cz = b.empty() ? 0.0f
                               : (static_cast<float>(b.min_y) +
                                  static_cast<float>(b.max_y) + 1.0f) * 0.5f;
    _center = simd::float3{cx, cy, cz};

    // Instance buffer: one Instance per filled cell. Walk chunks (only the
    // ones that exist), then walk filled cells within each chunk. This
    // visits 16^3 cells per non-empty chunk worst case — fine for the
    // chunk densities we see in real .vox scenes.
    std::vector<Instance> instances;
    instances.reserve(doc->grid.FilledCount());
    using VG = macvoxel::VoxelGrid;
    for (const auto& [coord, chunk] : doc->grid.chunks()) {
        if (chunk->filled_count == 0) continue;
        const int32_t bx = coord.x * static_cast<int32_t>(VG::kChunkSize);
        const int32_t by = coord.y * static_cast<int32_t>(VG::kChunkSize);
        const int32_t bz = coord.z * static_cast<int32_t>(VG::kChunkSize);
        for (uint32_t lz = 0; lz < VG::kChunkSize; ++lz) {
            for (uint32_t ly = 0; ly < VG::kChunkSize; ++ly) {
                for (uint32_t lx = 0; lx < VG::kChunkSize; ++lx) {
                    const size_t li = lx + ly * VG::kChunkSize +
                                      lz * VG::kChunkSize * VG::kChunkSize;
                    const uint8_t v = chunk->cells[li];
                    if (v == 0) continue;
                    Instance inst;
                    inst.x = static_cast<int16_t>(bx + static_cast<int32_t>(lx));
                    inst.y = static_cast<int16_t>(by + static_cast<int32_t>(ly));
                    inst.z = static_cast<int16_t>(bz + static_cast<int32_t>(lz));
                    inst.palette_w = static_cast<int16_t>(v);
                    instances.push_back(inst);
                }
            }
        }
    }
    _instanceCount = static_cast<uint32_t>(instances.size());
    if (_instanceCount > 0) {
        _instanceBuffer = [_device newBufferWithBytes:instances.data()
                                               length:instances.size() * sizeof(Instance)
                                              options:MTLResourceStorageModeShared];
        _instanceBuffer.label = @"VoxelInstances";
    } else {
        _instanceBuffer = nil;
    }

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

    _cachedVersion = doc->version;
    _cacheValid = YES;
}

// ---------------------------------------------------------------------------
// Per-frame draw
// ---------------------------------------------------------------------------

- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                     view:(simd::float4x4)view
               projection:(simd::float4x4)projection
                 document:(const macvoxel::Document*)doc {
    if (doc == nullptr) return;
    if (!_cacheValid || _cachedVersion != doc->version) {
        [self rebuildFromDocument:doc];
    }
    if (_instanceCount == 0) return;

    Uniforms u;
    u.vp = projection * view;
    u.center = _center;
    u._pad0 = 0.0f;
    u.light_dir = simd::normalize(simd::float3{0.4f, 0.7f, 0.5f});
    u._pad1 = 0.0f;

    [encoder pushDebugGroup:@"Voxels"];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setDepthStencilState:_depthState];
    [encoder setCullMode:MTLCullModeBack];
    [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
    [encoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
    [encoder setVertexBuffer:_instanceBuffer offset:0 atIndex:1];
    [encoder setVertexBytes:&u length:sizeof(u) atIndex:2];
    [encoder setVertexBuffer:_paletteBuffer offset:0 atIndex:3];
    [encoder setFragmentBytes:&u length:sizeof(u) atIndex:2];
    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:kCubeIndices.size()
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:_indexBuffer
                 indexBufferOffset:0
                     instanceCount:_instanceCount];
    [encoder popDebugGroup];
}

@end
