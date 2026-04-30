#pragma once

#import <Metal/Metal.h>

#include <simd/simd.h>

namespace macvoxel { struct Document; }

@interface VoxelRenderer : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat
                   depthFormat:(MTLPixelFormat)depthFormat;

// Encodes a draw of the document's filled voxels — one instanced cube per
// voxel. Internally caches the instance buffer, palette buffer, and model
// center against doc->version; rebuilds when the version changes. A
// document with zero filled voxels skips the draw.
- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                     view:(simd::float4x4)view
               projection:(simd::float4x4)projection
                 document:(const macvoxel::Document*)doc;

// Last instance count actually drawn (0 if the doc was empty). Useful for
// ImGui debug readouts.
- (uint32_t)lastInstanceCount;

@end
