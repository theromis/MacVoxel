#pragma once

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#include <simd/simd.h>

namespace macvoxel { struct EditorContext; }
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
// data + render settings from `ctx` and ray origin / direction from
// `camera`. Encodes its own command encoders into the supplied command
// buffer; writes the running sample count back into ctx->render_progress.
- (void)renderInView:(MTKView*)view
                 cmd:(id<MTLCommandBuffer>)cmd
             context:(macvoxel::EditorContext*)ctx
              camera:(const macvoxel::Camera&)camera;

// Forces the accumulation buffer to clear on the next frame. Call when
// the user toggles into path-traced mode (so we don't display stale
// accumulated samples from before the toggle).
- (void)invalidate;

- (uint32_t)sampleCount;

// Headless render: clears the accumulator, runs `samples` path-trace
// passes (driven from `ctx` + `camera` at exactly `size` pixels), and
// waits for the GPU. The seed used for sample i is `baseSeed + i + 1`,
// so a fixed `baseSeed` reproduces the same image for the same inputs.
// After it returns, call `exportPNGToURL:` to write the result.
- (BOOL)renderHeadlessSamples:(uint32_t)samples
                      context:(macvoxel::EditorContext*)ctx
                       camera:(const macvoxel::Camera&)camera
                         size:(CGSize)size
                   maxBounces:(uint32_t)maxBounces
                     baseSeed:(uint32_t)baseSeed
                 commandQueue:(id<MTLCommandQueue>)queue
                        error:(NSError**)outError;

// Render the current accumulated frame (post-tonemap) to a PNG at `url`.
// Synchronous — encodes a one-shot display pass into a shared-storage
// texture, waits for the GPU, then writes via ImageIO. `acesTonemap`
// selects the tone-mapping curve at write time so the user's panel
// toggle picks up between render and save. Returns YES on success;
// on failure, *outError carries an explanation.
- (BOOL)exportPNGToURL:(NSURL*)url
          acesTonemap:(BOOL)acesTonemap
       bloomIntensity:(float)bloomIntensity
          commandQueue:(id<MTLCommandQueue>)queue
                 error:(NSError**)outError;

@end
