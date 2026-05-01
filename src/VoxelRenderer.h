#pragma once

#import <Metal/Metal.h>

#include <simd/simd.h>

namespace macvoxel { struct Document; }

@interface VoxelRenderer : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat
                   depthFormat:(MTLPixelFormat)depthFormat;

// Encodes a draw of the document's visible voxel surfaces, built via
// greedy meshing. Per-chunk meshes are cached; the renderer drains
// the grid's dirty-chunks set on each rebuild and only re-meshes those
// chunks. Document* is non-const because the dirty set is consumed
// here.
- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                     view:(simd::float4x4)view
               projection:(simd::float4x4)projection
                 document:(macvoxel::Document*)doc;

// Mesh statistics from the most recent rebuild — for ImGui readouts.
- (uint32_t)lastVertexCount;
- (uint32_t)lastIndexCount;
- (uint32_t)lastQuadCount;

@end
