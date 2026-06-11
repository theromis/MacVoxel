#pragma once

#import <Metal/Metal.h>
#import <simd/simd.h>

namespace macvoxel { class OverlayDraw; }

// Tiny Metal pipeline that drains an OverlayDraw's accumulated vertex
// buffer into a triangle-list draw. One MTLRenderPipelineState backed
// by Overlay.metal; one shared-memory MTLBuffer that grows on demand.
//
// Premultiplied-alpha blend, no depth test, no MSAA. Designed to
// encode after the scene renderer (raycast or path-trace) inside the
// same command buffer, so the editor's gizmos / marquee / hover
// indicators composite over the rendered scene each frame. Two PSO
// variants because the two host passes disagree on attachments: the
// edit pass is the MTKView's (depth-attached), the PT overlay pass is
// ad-hoc color-only — a pipeline whose depthAttachmentPixelFormat
// doesn't match its pass is a validation failure.
@interface SceneOverlayRenderer : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat
                   depthFormat:(MTLPixelFormat)depthFormat;

// Encode the overlay's vertices into the active render command
// encoder. No-op for empty overlays. viewportSize is in pixels
// (matches MTKView.drawableSize converted to float2). `hasDepth`
// selects the PSO matching the pass's depth attachment.
- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                  overlay:(const macvoxel::OverlayDraw &)overlay
             viewportSize:(simd::float2)viewportSize
                 hasDepth:(BOOL)hasDepth;

@end
