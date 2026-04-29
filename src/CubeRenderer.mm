#import "CubeRenderer.h"

#import <cstdio>
#include <array>
#include <cstdint>

namespace {

// Tight 32-byte vertex matching the shader's [[stage_in]] layout.
// simd::float3 is 16-byte aligned, so we use float[3] for positions/normals
// to get the packed 12-byte storage Metal's MTLVertexFormatFloat3 expects.
struct Vertex {
    float position[3];
    float normal[3];
    float uv[2];
};
static_assert(sizeof(Vertex) == 32, "Vertex layout must match shader");

struct Uniforms {
    simd::float4x4 vp;
    simd::float3 light_dir;
    float pad;
};

// 24 vertices: 4 per face × 6 faces, each with the face's normal and
// per-face UVs in [0,1]. Half-extent cube centered at origin.
constexpr float H = 0.5f;

const std::array<Vertex, 24> kCubeVertices = {{
    // +X face (right)
    {{ H, -H,  H}, {1, 0, 0}, {0, 0}},
    {{ H, -H, -H}, {1, 0, 0}, {1, 0}},
    {{ H,  H, -H}, {1, 0, 0}, {1, 1}},
    {{ H,  H,  H}, {1, 0, 0}, {0, 1}},
    // -X face (left)
    {{-H, -H, -H}, {-1, 0, 0}, {0, 0}},
    {{-H, -H,  H}, {-1, 0, 0}, {1, 0}},
    {{-H,  H,  H}, {-1, 0, 0}, {1, 1}},
    {{-H,  H, -H}, {-1, 0, 0}, {0, 1}},
    // +Y face (top)
    {{-H,  H,  H}, {0, 1, 0}, {0, 0}},
    {{ H,  H,  H}, {0, 1, 0}, {1, 0}},
    {{ H,  H, -H}, {0, 1, 0}, {1, 1}},
    {{-H,  H, -H}, {0, 1, 0}, {0, 1}},
    // -Y face (bottom)
    {{-H, -H, -H}, {0, -1, 0}, {0, 0}},
    {{ H, -H, -H}, {0, -1, 0}, {1, 0}},
    {{ H, -H,  H}, {0, -1, 0}, {1, 1}},
    {{-H, -H,  H}, {0, -1, 0}, {0, 1}},
    // +Z face (front, toward +Z)
    {{-H, -H,  H}, {0, 0, 1}, {0, 0}},
    {{ H, -H,  H}, {0, 0, 1}, {1, 0}},
    {{ H,  H,  H}, {0, 0, 1}, {1, 1}},
    {{-H,  H,  H}, {0, 0, 1}, {0, 1}},
    // -Z face (back)
    {{ H, -H, -H}, {0, 0, -1}, {0, 0}},
    {{-H, -H, -H}, {0, 0, -1}, {1, 0}},
    {{-H,  H, -H}, {0, 0, -1}, {1, 1}},
    {{ H,  H, -H}, {0, 0, -1}, {0, 1}},
}};

const std::array<uint16_t, 36> kCubeIndices = {{
     0,  1,  2,    0,  2,  3,
     4,  5,  6,    4,  6,  7,
     8,  9, 10,    8, 10, 11,
    12, 13, 14,   12, 14, 15,
    16, 17, 18,   16, 18, 19,
    20, 21, 22,   20, 22, 23,
}};

NSString* const kShaderSource = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};

struct Uniforms {
    float4x4 vp;
    float3 light_dir;
};

struct V2F {
    float4 clip_pos [[position]];
    float3 normal;
    float2 uv;
};

vertex V2F vertex_main(Vertex in [[stage_in]],
                       constant Uniforms& u [[buffer(1)]]) {
    V2F out;
    out.clip_pos = u.vp * float4(in.position, 1.0);
    out.normal = in.normal;
    out.uv = in.uv;
    return out;
}

fragment float4 fragment_main(V2F in [[stage_in]],
                              constant Uniforms& u [[buffer(1)]],
                              texture2d<float> tex [[texture(0)]],
                              sampler samp [[sampler(0)]]) {
    float3 n = normalize(in.normal);
    float ndl = max(dot(n, u.light_dir), 0.0);
    float lambert = 0.3 + 0.7 * ndl;
    float4 base = tex.sample(samp, in.uv);
    return float4(base.rgb * lambert, 1.0);
}
)MSL";

// Procedural 64x64 RGBA8 grey checker, 8-pixel cells.
std::array<uint8_t, 64 * 64 * 4> MakeCheckerTexture() {
    std::array<uint8_t, 64 * 64 * 4> px{};
    for (int y = 0; y < 64; ++y) {
        for (int x = 0; x < 64; ++x) {
            const bool on = (((x / 8) + (y / 8)) & 1) != 0;
            const uint8_t v = on ? 0xC0 : 0x80;
            const size_t i = static_cast<size_t>(y * 64 + x) * 4u;
            px[i + 0] = v;
            px[i + 1] = v;
            px[i + 2] = v;
            px[i + 3] = 0xFF;
        }
    }
    return px;
}

}  // namespace

@implementation CubeRenderer {
    id<MTLRenderPipelineState> _pipeline;
    id<MTLDepthStencilState> _depthState;
    id<MTLBuffer> _vertexBuffer;
    id<MTLBuffer> _indexBuffer;
    id<MTLTexture> _texture;
    id<MTLSamplerState> _sampler;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat
                   depthFormat:(MTLPixelFormat)depthFormat {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    if (![self buildPipelineWithDevice:device
                           colorFormat:colorFormat
                           depthFormat:depthFormat]) {
        return nil;
    }
    [self buildDepthStateWithDevice:device];
    [self buildBuffersWithDevice:device];
    [self buildTextureWithDevice:device];
    [self buildSamplerWithDevice:device];

    return self;
}

// ---------------------------------------------------------------------------
// Build steps
// ---------------------------------------------------------------------------

- (BOOL)buildPipelineWithDevice:(id<MTLDevice>)device
                    colorFormat:(MTLPixelFormat)colorFormat
                    depthFormat:(MTLPixelFormat)depthFormat {
    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:kShaderSource
                                                  options:nil
                                                    error:&error];
    if (library == nil) {
        fprintf(stderr, "MacVoxel: failed to compile cube shaders: %s\n",
                [[error localizedDescription] UTF8String]);
        return NO;
    }

    id<MTLFunction> vfn = [library newFunctionWithName:@"vertex_main"];
    id<MTLFunction> ffn = [library newFunctionWithName:@"fragment_main"];

    MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
    vd.attributes[0].format = MTLVertexFormatFloat3;
    vd.attributes[0].offset = offsetof(Vertex, position);
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat3;
    vd.attributes[1].offset = offsetof(Vertex, normal);
    vd.attributes[1].bufferIndex = 0;
    vd.attributes[2].format = MTLVertexFormatFloat2;
    vd.attributes[2].offset = offsetof(Vertex, uv);
    vd.attributes[2].bufferIndex = 0;
    vd.layouts[0].stride = sizeof(Vertex);
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.label = @"MacVoxel Cube";
    desc.vertexFunction = vfn;
    desc.fragmentFunction = ffn;
    desc.vertexDescriptor = vd;
    desc.colorAttachments[0].pixelFormat = colorFormat;
    desc.depthAttachmentPixelFormat = depthFormat;

    _pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (_pipeline == nil) {
        fprintf(stderr, "MacVoxel: failed to build cube pipeline: %s\n",
                [[error localizedDescription] UTF8String]);
        return NO;
    }
    return YES;
}

- (void)buildDepthStateWithDevice:(id<MTLDevice>)device {
    MTLDepthStencilDescriptor* dsd = [[MTLDepthStencilDescriptor alloc] init];
    dsd.depthCompareFunction = MTLCompareFunctionLess;
    dsd.depthWriteEnabled = YES;
    _depthState = [device newDepthStencilStateWithDescriptor:dsd];
}

- (void)buildBuffersWithDevice:(id<MTLDevice>)device {
    _vertexBuffer = [device newBufferWithBytes:kCubeVertices.data()
                                        length:sizeof(kCubeVertices)
                                       options:MTLResourceStorageModeShared];
    _vertexBuffer.label = @"CubeVertices";
    _indexBuffer = [device newBufferWithBytes:kCubeIndices.data()
                                       length:sizeof(kCubeIndices)
                                      options:MTLResourceStorageModeShared];
    _indexBuffer.label = @"CubeIndices";
}

- (void)buildTextureWithDevice:(id<MTLDevice>)device {
    MTLTextureDescriptor* td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:64
                                                          height:64
                                                       mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    _texture = [device newTextureWithDescriptor:td];
    _texture.label = @"CubeChecker";

    const auto pixels = MakeCheckerTexture();
    [_texture replaceRegion:MTLRegionMake2D(0, 0, 64, 64)
                mipmapLevel:0
                  withBytes:pixels.data()
                bytesPerRow:64 * 4];
}

- (void)buildSamplerWithDevice:(id<MTLDevice>)device {
    MTLSamplerDescriptor* sd = [[MTLSamplerDescriptor alloc] init];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeRepeat;
    sd.tAddressMode = MTLSamplerAddressModeRepeat;
    _sampler = [device newSamplerStateWithDescriptor:sd];
}

// ---------------------------------------------------------------------------
// Per-frame draw
// ---------------------------------------------------------------------------

- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                     view:(simd::float4x4)view
               projection:(simd::float4x4)projection {
    Uniforms u;
    u.vp = projection * view;
    u.light_dir = simd::normalize(simd::float3{0.4f, 0.7f, 0.5f});
    u.pad = 0.0f;

    [encoder pushDebugGroup:@"Cube"];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setDepthStencilState:_depthState];
    [encoder setCullMode:MTLCullModeBack];
    [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
    [encoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
    [encoder setVertexBytes:&u length:sizeof(u) atIndex:1];
    [encoder setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [encoder setFragmentTexture:_texture atIndex:0];
    [encoder setFragmentSamplerState:_sampler atIndex:0];
    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:kCubeIndices.size()
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:_indexBuffer
                 indexBufferOffset:0];
    [encoder popDebugGroup];
}

@end
