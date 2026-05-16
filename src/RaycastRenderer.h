#pragma once

#import <Metal/Metal.h>

#include <simd/simd.h>

@class VolumeTexture;
namespace macvoxel { struct EditorContext; }

// GPU ray-cast renderer. For each pixel of a fullscreen triangle, the
// fragment shader marches a ray (3D DDA) through the document's voxels
// and outputs the color of the first filled cell hit.
//
// Layout uploaded to GPU (Phase A2):
//   * Doc texture: a `texture3d<uint, R8Uint>` sized to the EditVolume
//     (default 256³). Per-cell lookup is a direct `tex.read(uint3)`.
//     Maintained by the `VolumeTexture` helper, which uploads dirty
//     16³ chunks from `doc.volume_shadow` on geometry_version change.
//   * Overlay slots: coarse-grid + chunk-pool buffers for the floating-
//     buffer (selection lift/paste/move) and preview-removals
//     (Remove/Paint preview). Those stay sparse — they're small (one
//     brush footprint) and can wander outside the edit volume during
//     a drag, which the dense doc texture can't represent.
//   * Palette: 256 RGBA floats.
@interface RaycastRenderer : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat
                   depthFormat:(MTLPixelFormat)depthFormat;

- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                     view:(simd::float4x4)view
               projection:(simd::float4x4)projection
              cameraWorld:(simd::float3)cameraWorld
                  context:(macvoxel::EditorContext*)ctx
            volumeTexture:(VolumeTexture*)docVolumeTex;

- (uint32_t)lastChunkCount;

// Total GPU memory occupied by the renderer's voxel data structures
// (doc texture, in bytes).
- (size_t)lastGPUBytes;

// Drop the GPU cache so the next encode rebuilds from scratch. Called
// when the document is replaced wholesale (load, new) — the new
// document's shadow may be a different size, and any prior chunk
// state must be discarded.
- (void)invalidate;

@end
