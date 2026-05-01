#pragma once

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#include <simd/simd.h>

namespace macvoxel { struct Document; }
namespace macvoxel { class Camera; }

// GPU path tracer. Two passes per frame:
//   1. Path-trace pass: for each pixel, traces a ray from the camera into
//      the chunked voxel grid (3D DDA), stochastically scatters at hits
//      via cosine-weighted hemisphere sampling, accumulates radiance into
//      a float-RGBA accumulation texture (additive blending).
//   2. Display pass: reads the accumulation texture, divides by the
//      running sample count, writes to the MTKView's drawable.
//
// Accumulation resets when the camera state, the document version, or
// the framebuffer size changes — anything that would invalidate the
// previously accumulated samples. While the camera is still and the
// scene unchanged, samples accumulate frame by frame and the image
// converges.
@interface PathTraceRenderer : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat;

// Render the path-traced result into `view`'s drawable, sourcing voxel
// data from `doc` and ray origin / direction from `camera`. Encodes its
// own command encoders into the supplied command buffer.
- (void)renderInView:(MTKView*)view
                 cmd:(id<MTLCommandBuffer>)cmd
            document:(macvoxel::Document*)doc
              camera:(const macvoxel::Camera&)camera;

// Forces the accumulation buffer to clear on the next frame. Call when
// the user toggles into path-traced mode (so we don't display stale
// accumulated samples from before the toggle).
- (void)invalidate;

- (uint32_t)sampleCount;

@end
