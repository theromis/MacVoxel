#pragma once

#import <Metal/Metal.h>

namespace macvoxel {
class VoxelVolume;
struct Bounds3;
}

// Per-document GPU mirror of `VoxelVolume`: a dense `texture3d<uchar>`
// in R8Uint format, sized to the volume's EditVolume dimensions
// (default 256³ = 16 MiB). The rasterizer samples this directly via
// `texture3d.read(uint3)`.
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

// Reallocate every texture when the volume's dimensions changed (the
// edit volume is sized to the active object's AABB cover, so
// activation/resize can change it). Returns YES when a reallocation
// happened; the rebased shadow arrives fully dirty, so the following
// syncFromVolume re-uploads in full. No-op when sizes match.
- (BOOL)resizeIfNeededForVolume:(const macvoxel::VoxelVolume&)volume;

// Drains the dirty-chunk bitset and recomputes only the oracle bytes
// for those chunks — no cell upload. For the commit path, where the
// GPU already wrote tex_a but can't cheaply learn that an Erase left
// a chunk empty (the oracle would otherwise only ever saturate to 1).
- (void)refreshOracleFromVolume:(macvoxel::VoxelVolume&)volume;

// Doc texture: rasterizer DDA samples this. R8Uint 256³.
@property(nonatomic, readonly, nonnull) id<MTLTexture> texture;

// 16³-resolution occupancy oracle for the doc texture.
@property(nonatomic, readonly, nonnull) id<MTLTexture> oracleTexture;

// Mark a chunk as non-empty in the oracle. Used by GPU paths that
// update the doc texture out-of-band from `syncFromVolume`.
- (void)markOracleChunkAtX:(int)x y:(int)y z:(int)z;

// Preview texture ("tex_t" in Magica's framework): shape/face/
// generator/mutator tools write their live preview here.
@property(nonatomic, readonly, nonnull) id<MTLTexture> previewTexture;
@property(nonatomic, readonly, nonnull) id<MTLTexture> previewOracleTexture;

// Remove-preview mask ("preview_rem"). Non-zero cells hide the
// corresponding doc cell during the active stroke; commit_generic in
// bm=Erase mode consumes the mask.
@property(nonatomic, readonly, nonnull) id<MTLTexture> previewRemTexture;
@property(nonatomic, readonly, nonnull) id<MTLTexture> previewRemOracleTexture;

// Lift texture ("tex_lift"): holds the *contents* of the active
// selection as palette indices (R8Uint 256³, world-aligned). Non-zero
// = a cell the user has selected; the rasterizer composites this on
// top of the doc with the selection tint. Empty between selections.
//
// On selection finalize, the lift kernel reads cells out of the doc
// and writes them here, clearing the doc cells in the same pass.
// Transforms (translate / rotate / flip) operate kernel-to-kernel on
// the lift texture (with a snapshot blit between reads and writes).
// Commit blits the lift back to the doc and zeroes the lift.
@property(nonatomic, readonly, nonnull) id<MTLTexture> liftTexture;
@property(nonatomic, readonly, nonnull) id<MTLTexture> liftOracleTexture;

// Scratch mirror of `liftTexture`. Read-only from the kernel's POV;
// written only by `encodeLiftSnapshot:`. Transform kernels read from
// this snapshot and write the live `liftTexture` so source/dest
// overlap is race-free.
@property(nonatomic, readonly, nonnull) id<MTLTexture> liftSnapshotTexture;

// Encode a bbox-bounded blit of `liftTexture → liftSnapshotTexture`
// onto `cmd`. World cell coords, inclusive; the bbox is clipped to
// the texture's extent.
- (void)encodeLiftSnapshot:(nonnull id<MTLCommandBuffer>)cmd
                  worldBbox:(const macvoxel::Bounds3&)world_bbox;

// Texture dimensions in cells. Mirrors volume.size_{x,y,z}.
@property(nonatomic, readonly) int sizeX;
@property(nonatomic, readonly) int sizeY;
@property(nonatomic, readonly) int sizeZ;

// Texture origin in world cell coords (== EditVolume.x0/y0/z0).
@property(nonatomic, readonly) int originX;
@property(nonatomic, readonly) int originY;
@property(nonatomic, readonly) int originZ;

@end
