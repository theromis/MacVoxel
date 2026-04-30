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

constexpr float H = 0.5f;

// 24-vertex unit cube centered at origin, half-extent 0.5, distinct normals
// per face. CCW winding when viewed from outside.
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
    // +Y (top)
    {{-H,  H,  H}, {0, 1, 0}},
    {{ H,  H,  H}, {0, 1, 0}},
    {{ H,  H, -H}, {0, 1, 0}},
    {{-H,  H, -H}, {0, 1, 0}},
    // -Y (bottom)
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
    uchar4 voxel    [[attribute(2)]];  // (x, y, z, palette_idx) in grid space
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
    // .vox source coordinates are Z-up; we render in a Y-up world. Swap
    // grid Y and Z when computing world position so the model stands up
    // correctly under our orbit camera.
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
    out.color = palette[in.voxel.w].rgb;
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
    vd.attributes[2].format = MTLVertexFormatUChar4;
    vd.attributes[2].offset = 0;
    vd.attributes[2].bufferIndex = 1;
    vd.layouts[0].stride = sizeof(CubeVertex);
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    vd.layouts[1].stride = 4;
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
    const macvoxel::Dims d = doc->grid.dims();

    // Center: half the model extent, with grid Y/Z swapped to match the
    // shader's Y-up world.
    _center = simd::float3{
        static_cast<float>(d.x) * 0.5f,
        static_cast<float>(d.z) * 0.5f,
        static_cast<float>(d.y) * 0.5f,
    };

    // Instance buffer: one uchar4 per filled voxel.
    std::vector<uint8_t> bytes;
    bytes.reserve(static_cast<size_t>(doc->grid.FilledCount()) * 4u);
    for (uint32_t z = 0; z < d.z; ++z) {
        for (uint32_t y = 0; y < d.y; ++y) {
            for (uint32_t x = 0; x < d.x; ++x) {
                const uint8_t v = doc->grid.Get(x, y, z);
                if (v == 0) continue;
                bytes.push_back(static_cast<uint8_t>(x));
                bytes.push_back(static_cast<uint8_t>(y));
                bytes.push_back(static_cast<uint8_t>(z));
                bytes.push_back(v);
            }
        }
    }
    _instanceCount = static_cast<uint32_t>(bytes.size() / 4);
    if (_instanceCount > 0) {
        _instanceBuffer = [_device newBufferWithBytes:bytes.data()
                                               length:bytes.size()
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
