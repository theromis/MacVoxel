#import "SceneOverlayRenderer.h"

#import <Foundation/Foundation.h>

#include <cstdio>
#include <cstring>

#include "OverlayDraw.h"

@implementation SceneOverlayRenderer {
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _pipeline;       // color-only pass (PT)
    id<MTLRenderPipelineState> _pipelineDepth;  // depth-attached pass (edit)
    id<MTLBuffer> _vertexBuffer;
    NSUInteger _vertexBufferBytes;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat
                   depthFormat:(MTLPixelFormat)depthFormat {
    self = [super init];
    if (self == nil) return nil;
    _device = device;

    // Same bundle-resource + newLibraryWithSource pattern PathTraceRenderer
    // uses; keeps the shader human-readable in the build output and
    // editable without a tooling round-trip.
    NSString *path = [[NSBundle mainBundle] pathForResource:@"Overlay"
                                                     ofType:@"metal"];
    if (path == nil) {
        std::fprintf(stderr, "SceneOverlayRenderer: Overlay.metal not in bundle\n");
        return nil;
    }
    NSString *source = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (source == nil) {
        std::fprintf(stderr, "SceneOverlayRenderer: could not read Overlay.metal\n");
        return nil;
    }
    NSError *err = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source
                                                   options:nil
                                                     error:&err];
    if (library == nil) {
        std::fprintf(stderr, "SceneOverlayRenderer: shader compile: %s\n",
                     err.localizedDescription.UTF8String);
        return nil;
    }
    id<MTLFunction> vfn = [library newFunctionWithName:@"overlay_vertex"];
    id<MTLFunction> ffn = [library newFunctionWithName:@"overlay_fragment"];
    if (vfn == nil || ffn == nil) {
        std::fprintf(stderr, "SceneOverlayRenderer: missing shader functions\n");
        return nil;
    }

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.label = @"Overlay";
    desc.vertexFunction = vfn;
    desc.fragmentFunction = ffn;
    desc.colorAttachments[0].pixelFormat = colorFormat;
    // Premultiplied-alpha standard blend.
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;

    _pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (_pipeline == nil) {
        std::fprintf(stderr, "SceneOverlayRenderer: pipeline: %s\n",
                     err.localizedDescription.UTF8String);
        return nil;
    }

    desc.depthAttachmentPixelFormat = depthFormat;
    _pipelineDepth = [device newRenderPipelineStateWithDescriptor:desc
                                                            error:&err];
    if (_pipelineDepth == nil) {
        std::fprintf(stderr, "SceneOverlayRenderer: depth pipeline: %s\n",
                     err.localizedDescription.UTF8String);
        return nil;
    }

    // Initial size large enough for the busiest frame seen in practice
    // (gen gizmo + xform handles + selection wireframe + marquee = a
    // few hundred verts). Grows 2× when exceeded.
    _vertexBufferBytes = 4096 * sizeof(macvoxel::OverlayDraw::Vertex);
    _vertexBuffer = [device newBufferWithLength:_vertexBufferBytes
                                         options:MTLResourceStorageModeShared];
    if (_vertexBuffer == nil) {
        std::fprintf(stderr, "SceneOverlayRenderer: vertex buffer alloc\n");
        return nil;
    }
    return self;
}

- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                  overlay:(const macvoxel::OverlayDraw &)overlay
             viewportSize:(simd::float2)viewportSize
                 hasDepth:(BOOL)hasDepth {
    const auto &verts = overlay.vertices();
    if (verts.empty()) return;

    const NSUInteger needed =
        verts.size() * sizeof(macvoxel::OverlayDraw::Vertex);
    if (needed > _vertexBufferBytes) {
        NSUInteger cap = _vertexBufferBytes;
        while (cap < needed) cap *= 2;
        _vertexBuffer = [_device newBufferWithLength:cap
                                              options:MTLResourceStorageModeShared];
        _vertexBufferBytes = cap;
    }
    std::memcpy(_vertexBuffer.contents, verts.data(), needed);

    [encoder pushDebugGroup:@"Overlay"];
    [encoder setRenderPipelineState:(hasDepth ? _pipelineDepth : _pipeline)];
    [encoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
    [encoder setVertexBytes:&viewportSize
                     length:sizeof(simd::float2)
                    atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:verts.size()];
    [encoder popDebugGroup];
}

@end
