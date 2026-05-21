#pragma once

#import <Metal/Metal.h>

namespace macvoxel {
class Selection;
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

// 16³-resolution occupancy oracle: a R8Uint texture with one cell per
// 16³ chunk of the doc texture, 0 = chunk is empty / 1 = chunk has
// non-zero cells. Sized to `(sizeX/16, sizeY/16, sizeZ/16)`. The
// rasterizer fragment shader samples this first to coarse-skip empty
// chunks (otherwise a per-pixel 256-cell DDA at retina resolution
// crushes frame rate).
//
// Maintenance is monotone-and-rebuild: writes to chunks set the
// oracle byte to 1 (brush kernel + replaceRegion uploads), and a
// full rebuild from VoxelVolume happens via `syncFromVolume`. Stale
// "occupied" entries cause under-skip (a tiny perf hit), never
// over-skip (which would visually drop voxels).
@property(nonatomic, readonly, nonnull) id<MTLTexture> oracleTexture;

// Mark a chunk as non-empty in the oracle. Used by Phase B1+ paths
// that update the doc texture out-of-band from `syncFromVolume`.
- (void)markOracleChunkAtX:(int)x y:(int)y z:(int)z;

// Preview texture ("tex_t" in Magica's framework): shape/face/
// generator tools write their live preview here. The rasterizer
// composites it on top of the doc texture, gated by the
// `preview_active` uniform. Same 256³ R8Uint dimensions + 16³ coarse
// oracle as the doc.
@property(nonatomic, readonly, nonnull) id<MTLTexture> previewTexture;
@property(nonatomic, readonly, nonnull) id<MTLTexture> previewOracleTexture;

// Remove-preview mask ("preview_rem"). Same dims as the doc tex
// (R8Uint 256³ + 16³ oracle); a non-zero cell means "the active tool
// wants this doc cell to read as empty during the preview". The
// rasterizer composites this BEFORE shading, so Remove-mode strokes
// (Brush / Shape / Face / Generator) can show cells disappearing
// live without actually mutating tex_a until commit. commit_generic
// in bm=Erase mode reads this mask in place of tex_t.
@property(nonatomic, readonly, nonnull) id<MTLTexture> previewRemTexture;
@property(nonatomic, readonly, nonnull) id<MTLTexture> previewRemOracleTexture;

// Selection mask ("tex_sel" in MagicaVoxel framing). Same dims as the
// doc tex (R8Uint 256³ + 16³ oracle); a non-zero cell means "the
// user has selected this cell." The rasterizer samples this during
// shading and tints occupied doc cells whose selection byte is set;
// future steps will rebuild transform / cut / copy / delete onto
// kernels that read this mask. `syncFromSelection:` refreshes the
// bounded bbox region that changed since the last sync.
@property(nonatomic, readonly, nonnull) id<MTLTexture> selectionTexture;
@property(nonatomic, readonly, nonnull) id<MTLTexture> selectionOracleTexture;

- (void)syncFromSelection:(const macvoxel::Selection&)selection;

// Texture dimensions in cells. Mirrors volume.size_{x,y,z}.
@property(nonatomic, readonly) int sizeX;
@property(nonatomic, readonly) int sizeY;
@property(nonatomic, readonly) int sizeZ;

// Texture origin in world cell coords (== EditVolume.x0/y0/z0). World
// cell (x, y, z) maps to texture-local (x - originX, y - originY,
// z - originZ).
@property(nonatomic, readonly) int originX;
@property(nonatomic, readonly) int originY;
@property(nonatomic, readonly) int originZ;

@end
