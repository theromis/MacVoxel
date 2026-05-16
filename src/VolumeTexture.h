#pragma once

#import <Metal/Metal.h>

namespace macvoxel {
class VoxelVolume;
}

// Per-document GPU mirror of `VoxelVolume`: a dense `texture3d<uchar>`
// in R8Uint format, sized to the volume's EditVolume dimensions
// (default 256³ = 16 MiB). Phase A2: read-only mirror; the rasterizer
// samples this directly via `texture3d.read(uint3)`. Phase B1 will add
// a `_texOut` ping-pong partner so brush kernels can write while
// readers still see the previous frame's `_tex`.
//
// Upload cadence: `syncFromVolume:` checks the volume's TakeDirtyChunks
// bitset and `replaceRegion:`-uploads only the modified 16³ chunks.
// First call after construction (or after a `Clear()`) uploads
// everything because `Clear()` marks all chunks dirty.
@interface VolumeTexture : NSObject

- (nullable instancetype)initWithDevice:(nonnull id<MTLDevice>)device
                                 volume:(const macvoxel::VoxelVolume&)volume;

// Drains the volume's dirty-chunk bitset and uploads those chunks to
// the texture. Idempotent: a call with no dirty chunks does nothing.
- (void)syncFromVolume:(macvoxel::VoxelVolume&)volume;

// Read-only access to the underlying texture. Lives on the GPU; the
// caller binds it to a fragment/compute slot.
@property(nonatomic, readonly, nonnull) id<MTLTexture> texture;

// Texture dimensions in cells. Mirrors volume.size_{x,y,z}.
@property(nonatomic, readonly) int sizeX;
@property(nonatomic, readonly) int sizeY;
@property(nonatomic, readonly) int sizeZ;

@end
