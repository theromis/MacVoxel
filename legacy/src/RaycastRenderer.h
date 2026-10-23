#pragma once

#import <Metal/Metal.h>

#include <simd/simd.h>

@class SceneWorldBuffer;
@class VolumeTexture;
namespace macvoxel { struct EditorContext; }

// GPU ray-cast renderer. For each pixel of a fullscreen triangle, the
// fragment shader marches a ray (3D DDA) through the document's voxels
// and outputs the color of the first filled cell hit.
//
// Layout uploaded to GPU:
//   * Doc texture: a `texture3d<uint, R8Uint>` sized to the EditVolume
//     (default 256³). Maintained by the `VolumeTexture` helper.
//   * Lift texture: same dims as the doc. Holds the contents of an
//     active selection (lift). Composited on top of the doc with a
//     selection tint when non-zero.
//   * Preview texture: dense R8Uint, same dims as the doc. Composited
//     over the doc by the fragment shader when `preview_active != 0`.
//   * Palette: 256 RGBA floats.
@interface RaycastRenderer : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat
                   depthFormat:(MTLPixelFormat)depthFormat;

// worldBuffer (nullable) supplies the sparse world composite for
// inactive objects; docTexActive gates tex_a sampling (NO in object
// mode, where the world buffer carries every object).
- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                     view:(simd::float4x4)view
               projection:(simd::float4x4)projection
              cameraWorld:(simd::float3)cameraWorld
                  context:(macvoxel::EditorContext*)ctx
            volumeTexture:(VolumeTexture*)docVolumeTex
              worldBuffer:(SceneWorldBuffer*)worldBuffer
             docTexActive:(BOOL)docTexActive;

- (uint32_t)lastChunkCount;
- (size_t)lastGPUBytes;
- (void)invalidate;

@end
