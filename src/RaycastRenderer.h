#pragma once

#import <Metal/Metal.h>

#include <simd/simd.h>

namespace macvoxel { struct EditorContext; }

// GPU ray-cast renderer. For each pixel of a fullscreen triangle, the
// fragment shader marches a ray (3D DDA) through a sparse representation
// of the voxel grid and outputs the color of the first filled cell hit.
//
// Sparse layout uploaded to GPU:
//   * Coarse grid: dense 3D array of uint32 chunk pool indices (1-based;
//     0 = empty 16^3 region). Sized to fit the document's chunk-coord
//     bounds, so a 1 M-slot grid for a Rancho-Ancon-scale scene.
//   * Chunk pool: flat array of {uint8 cells[4096]}, one entry per
//     non-empty chunk in the document.
//   * Palette: 256 RGBA floats (same layout as the mesh renderer used).
//
// Edits don't trigger any mesh rebuild — they only update the affected
// chunks in the pool buffer. For Phase 6.1 the upload still happens
// wholesale on doc->version change; incremental upload is a follow-up.
@interface RaycastRenderer : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat
                   depthFormat:(MTLPixelFormat)depthFormat;

- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                     view:(simd::float4x4)view
               projection:(simd::float4x4)projection
              cameraWorld:(simd::float3)cameraWorld
                  context:(macvoxel::EditorContext*)ctx;

- (uint32_t)lastChunkCount;

// Total GPU memory occupied by the renderer's voxel data structures
// (coarse grid + chunk pool capacity, in bytes).
- (size_t)lastGPUBytes;

// Drop the GPU cache so the next encode does a wholesale rebuild
// instead of an incremental dirty-chunk update. Call when the
// document is replaced wholesale (load, new) — the dirty-chunk set
// only tracks what's been *changed*, not what no longer exists, so
// without this the previous file's chunks linger on the GPU as
// zombies.
- (void)invalidate;

@end
