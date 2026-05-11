#pragma once

#import <Metal/Metal.h>
#import <simd/simd.h>

namespace macvoxel { class OverlayDraw; }

// Tiny Metal pipeline that drains an OverlayDraw's accumulated vertex
// buffer into a triangle-list draw. One MTLRenderPipelineState backed
// by Overlay.metal; one shared-memory MTLBuffer that grows on demand.
//
// Premultiplied-alpha blend, no depth, no MSAA. Designed to encode
// after the scene renderer (raycast or path-trace) inside the same
// command buffer, so the editor's gizmos / marquee / hover indicators
// composite over the rendered scene each frame.
@interface SceneOverlayRenderer : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat;

// Encode the overlay's vertices into the active render command
// encoder. No-op for empty overlays. viewportSize is in pixels
// (matches MTKView.drawableSize converted to float2).
- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                  overlay:(const macvoxel::OverlayDraw &)overlay
             viewportSize:(simd::float2)viewportSize;

@end
