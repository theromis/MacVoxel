#pragma once

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#include <simd/simd.h>

namespace macvoxel { struct EditorContext; }
namespace macvoxel { class Camera; }

// Port of MagicaVoxel's path-tracer shader, exposed as the "Magica"
// option in the renderer-mode segmented control alongside Edit
// (RaycastRenderer) and Render (PathTraceRenderer).
//
// Architecture mirrors Magica's:
//   - tex_df: a 3D texture spanning the document AABB. Each texel
//     carries a palette ID (.r) and a baked DDA skip distance (.g).
//     The skip distance is how many cells the DDA can step before the
//     palette ID changes, which lets the traversal jump empty space
//     in O(1) per step instead of touching every cell.
//   - tex_pal: 1D palette texture, 256 entries, sRGB → linear.
//   - tex_mtl: 2D material texture, one row per palette entry,
//     packing the BSDF parameters.
//   - tex_rand: a 64×64 noise texture sampled per fragment for
//     Magica's "Weyl-decorated white-noise" jitter pattern.
//
// Public Obj-C++ surface matches PathTraceRenderer exactly so
// MetalScene can swap between the two with no per-callsite branching.
@interface MagicaRenderer : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat;

- (void)renderInView:(MTKView*)view
                 cmd:(id<MTLCommandBuffer>)cmd
             context:(macvoxel::EditorContext*)ctx
              camera:(const macvoxel::Camera&)camera;

- (void)invalidate;

- (uint32_t)sampleCount;

- (BOOL)renderHeadlessSamples:(uint32_t)samples
                      context:(macvoxel::EditorContext*)ctx
                       camera:(const macvoxel::Camera&)camera
                         size:(CGSize)size
                   maxBounces:(uint32_t)maxBounces
                     baseSeed:(uint32_t)baseSeed
                 commandQueue:(id<MTLCommandQueue>)queue
                        error:(NSError**)outError;

- (BOOL)exportPNGToURL:(NSURL*)url
          acesTonemap:(BOOL)acesTonemap
          commandQueue:(id<MTLCommandQueue>)queue
                 error:(NSError**)outError;

@end
