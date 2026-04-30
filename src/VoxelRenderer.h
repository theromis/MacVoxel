#pragma once

#import <Metal/Metal.h>

#include <simd/simd.h>

namespace macvoxel { struct Document; }

@interface VoxelRenderer : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat
                   depthFormat:(MTLPixelFormat)depthFormat;

// Encodes a draw of the document's visible voxel surfaces, built via
// greedy meshing. The mesh + palette are cached against doc->version
// and rebuilt only when the version changes; encoding itself is just a
// single setRenderPipelineState + drawIndexedPrimitives.
- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                     view:(simd::float4x4)view
               projection:(simd::float4x4)projection
                 document:(const macvoxel::Document*)doc;

// Mesh statistics from the most recent rebuild — for ImGui readouts.
- (uint32_t)lastVertexCount;
- (uint32_t)lastIndexCount;
- (uint32_t)lastQuadCount;

@end
