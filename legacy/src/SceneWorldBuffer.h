#pragma once

#import <Metal/Metal.h>

#include "VoxelGrid.h"

#include <simd/simd.h>

namespace macvoxel {
struct Scene;
}

// Sparse coarse+pool GPU buffers holding a world-space flatten of scene
// objects — the rasterizer's composite source for everything that isn't
// the active object (and, in object mode, for every object). Same layout
// the path tracer traverses: `coarse` is a dense uint32 chunk-slot volume
// over tight chunk bounds (0 = empty), `pool` holds 4096-byte chunk
// payloads at (slot-1)*4096.
@interface SceneWorldBuffer : NSObject

- (nullable instancetype)initWithDevice:(nonnull id<MTLDevice>)device;

// Re-flatten + repack. excludeObject is an index into scene.objects
// (< 0 = include all). Returns whether the buffer ended up non-empty.
- (BOOL)rebuildFromScene:(const macvoxel::Scene&)scene
                 exclude:(int)excludeObject;

@property(nonatomic, readonly, nullable) id<MTLBuffer> coarse;
@property(nonatomic, readonly, nullable) id<MTLBuffer> pool;
@property(nonatomic, readonly) simd::int3 coarseMin;  // chunk coords
@property(nonatomic, readonly) simd::int3 coarseDim;
// Tight cell-coord bounds of the packed cells (march-AABB source).
@property(nonatomic, readonly) macvoxel::Bounds3 worldBounds;
@property(nonatomic, readonly) BOOL nonEmpty;

@end
