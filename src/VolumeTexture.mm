#import "VolumeTexture.h"

#include "Selection.h"
#include "VoxelGrid.h"  // Bounds3
#include "VoxelVolume.h"

#include <algorithm>
#include <cstdint>
#include <vector>

@implementation VolumeTexture {
    id<MTLTexture> _texture;
    id<MTLTexture> _oracleTexture;
    id<MTLTexture> _previewTexture;
    id<MTLTexture> _previewOracleTexture;
    id<MTLTexture> _previewRemTexture;
    id<MTLTexture> _previewRemOracleTexture;
    id<MTLTexture> _selectionTexture;
    id<MTLTexture> _selectionOracleTexture;
    int _chunksX;
    int _chunksY;
    int _chunksZ;
    int _strideX;     // bytes per row in the dense buffer (= size_x)
    int _strideZ;     // bytes per slice (= size_x * size_y)
    // Last bbox uploaded into _selectionTexture. The next sync zeros
    // out the leftover region (lastBbox minus newBbox) before painting
    // the new contents — saves us a full-volume zero on every change.
    // {INT32_MAX, INT32_MAX, INT32_MAX, INT32_MIN, INT32_MIN, INT32_MIN}
    // is the sentinel for "nothing uploaded yet."
    macvoxel::Bounds3 _lastSelBbox;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                 volume:(const macvoxel::VoxelVolume&)volume {
    self = [super init];
    if (self == nil) return nil;

    _sizeX = volume.size_x();
    _sizeY = volume.size_y();
    _sizeZ = volume.size_z();
    _originX = volume.edit_volume().x0;
    _originY = volume.edit_volume().y0;
    _originZ = volume.edit_volume().z0;
    _chunksX = volume.chunks_x();
    _chunksY = volume.chunks_y();
    _chunksZ = volume.chunks_z();
    _strideX = _sizeX;
    _strideZ = _sizeX * _sizeY;

    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Uint
                                                            width:(NSUInteger)_sizeX
                                                           height:(NSUInteger)_sizeY
                                                        mipmapped:NO];
    desc.textureType = MTLTextureType3D;
    desc.depth = (NSUInteger)_sizeZ;
    // ShaderRead for rasterizer sampling; ShaderWrite so the brush
    // compute kernel can write through `access::read_write`. R8Uint is
    // in the Apple Silicon read-write pixel format subset.
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    // Shared storage on Apple Silicon (unified memory). Required for
    // `replaceRegion:` uploads — Private textures are blit-only.
    desc.storageMode = MTLStorageModeShared;
    _texture = [device newTextureWithDescriptor:desc];
    if (_texture == nil) return nil;
    [_texture setLabel:@"VolumeTexture.docTex"];

    MTLTextureDescriptor* oracleDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Uint
                                                            width:(NSUInteger)_chunksX
                                                           height:(NSUInteger)_chunksY
                                                        mipmapped:NO];
    oracleDesc.textureType = MTLTextureType3D;
    oracleDesc.depth = (NSUInteger)_chunksZ;
    oracleDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    oracleDesc.storageMode = MTLStorageModeShared;
    _oracleTexture = [device newTextureWithDescriptor:oracleDesc];
    if (_oracleTexture == nil) return nil;
    [_oracleTexture setLabel:@"VolumeTexture.oracle"];

    MTLTextureDescriptor* previewDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Uint
                                                            width:(NSUInteger)_sizeX
                                                           height:(NSUInteger)_sizeY
                                                        mipmapped:NO];
    previewDesc.textureType = MTLTextureType3D;
    previewDesc.depth = (NSUInteger)_sizeZ;
    previewDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    previewDesc.storageMode = MTLStorageModeShared;
    _previewTexture = [device newTextureWithDescriptor:previewDesc];
    if (_previewTexture == nil) return nil;
    [_previewTexture setLabel:@"VolumeTexture.previewTex"];

    MTLTextureDescriptor* previewOracleDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Uint
                                                            width:(NSUInteger)_chunksX
                                                           height:(NSUInteger)_chunksY
                                                        mipmapped:NO];
    previewOracleDesc.textureType = MTLTextureType3D;
    previewOracleDesc.depth = (NSUInteger)_chunksZ;
    previewOracleDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    previewOracleDesc.storageMode = MTLStorageModeShared;
    _previewOracleTexture = [device newTextureWithDescriptor:previewOracleDesc];
    if (_previewOracleTexture == nil) return nil;
    [_previewOracleTexture setLabel:@"VolumeTexture.previewOracle"];

    // preview_rem mask — same dims/usage as previewTexture; allocated
    // fresh-zero (Metal default) so a brand-new doc has nothing masked.
    _previewRemTexture = [device newTextureWithDescriptor:previewDesc];
    if (_previewRemTexture == nil) return nil;
    [_previewRemTexture setLabel:@"VolumeTexture.previewRem"];

    _previewRemOracleTexture =
        [device newTextureWithDescriptor:previewOracleDesc];
    if (_previewRemOracleTexture == nil) return nil;
    [_previewRemOracleTexture setLabel:@"VolumeTexture.previewRemOracle"];

    // Selection mask + its oracle — same dims/usage as the preview pair.
    _selectionTexture = [device newTextureWithDescriptor:previewDesc];
    if (_selectionTexture == nil) return nil;
    [_selectionTexture setLabel:@"VolumeTexture.selectionTex"];
    _selectionOracleTexture =
        [device newTextureWithDescriptor:previewOracleDesc];
    if (_selectionOracleTexture == nil) return nil;
    [_selectionOracleTexture setLabel:@"VolumeTexture.selectionOracle"];

    _lastSelBbox = macvoxel::Bounds3{};  // empty sentinel
    return self;
}

- (void)syncFromVolume:(macvoxel::VoxelVolume&)volume {
    auto dirty = volume.TakeDirtyChunks();
    if (dirty.empty()) return;

    const int chunk_size = macvoxel::VoxelVolume::kChunkSize;
    const uint8_t* base = volume.data();
    const int sx = _sizeX;
    const int sy = _sizeY;
    const int sz = _sizeZ;
    const int cx = _chunksX;
    const int cy = _chunksY;
    const int cz = _chunksZ;
    const size_t bytes_per_row = (size_t)_strideX;
    const size_t bytes_per_image = (size_t)_strideZ;

    // Upload one 16³ region per dirty bit. The dense source layout
    // (x-fastest, z-slowest) matches Metal's expected
    // bytesPerRow / bytesPerImage stride convention, so we can point
    // straight into `base` without a staging copy. Per-chunk regions
    // are clamped to the texture's edge for non-multiple-of-16 axes
    // (default 256³ is clean, but stay safe).
    //
    // Each chunk upload also refreshes its corresponding oracle byte:
    // 0 if the chunk's bytes are all zero, 1 otherwise. Scanning 4 KiB
    // per chunk on the CPU is much cheaper than the alternative (a
    // reduction kernel) and stays comparable to the upload itself.
    for (int cz_i = 0; cz_i < cz; ++cz_i) {
        for (int cy_i = 0; cy_i < cy; ++cy_i) {
            for (int cx_i = 0; cx_i < cx; ++cx_i) {
                const size_t bit =
                    (size_t)cx_i +
                    (size_t)cy_i * (size_t)cx +
                    (size_t)cz_i * (size_t)cx * (size_t)cy;
                if (((dirty[bit >> 6] >> (bit & 63)) & 1ULL) == 0) continue;

                const int x0 = cx_i * chunk_size;
                const int y0 = cy_i * chunk_size;
                const int z0 = cz_i * chunk_size;
                const int w = std::min(chunk_size, sx - x0);
                const int h = std::min(chunk_size, sy - y0);
                const int d = std::min(chunk_size, sz - z0);
                if (w <= 0 || h <= 0 || d <= 0) continue;
                const size_t off = (size_t)x0 +
                                   (size_t)y0 * bytes_per_row +
                                   (size_t)z0 * bytes_per_image;
                MTLRegion region = MTLRegionMake3D(
                    (NSUInteger)x0, (NSUInteger)y0, (NSUInteger)z0,
                    (NSUInteger)w,  (NSUInteger)h,  (NSUInteger)d);
                [_texture replaceRegion:region
                            mipmapLevel:0
                                  slice:0
                              withBytes:base + off
                            bytesPerRow:(NSUInteger)bytes_per_row
                          bytesPerImage:(NSUInteger)bytes_per_image];

                uint8_t any = 0;
                for (int z = 0; z < d && !any; ++z) {
                    for (int y = 0; y < h && !any; ++y) {
                        const uint8_t* row = base + off +
                            (size_t)y * bytes_per_row +
                            (size_t)z * bytes_per_image;
                        for (int x = 0; x < w; ++x) {
                            if (row[x]) { any = 1; break; }
                        }
                    }
                }
                MTLRegion oc = MTLRegionMake3D(
                    (NSUInteger)cx_i, (NSUInteger)cy_i, (NSUInteger)cz_i,
                    1, 1, 1);
                [_oracleTexture replaceRegion:oc
                                  mipmapLevel:0
                                        slice:0
                                    withBytes:&any
                                  bytesPerRow:1
                                bytesPerImage:1];
            }
        }
    }
}

- (void)syncFromSelection:(const macvoxel::Selection&)sel {
    using Bounds3 = macvoxel::Bounds3;
    // newBbox = the bbox the selection currently occupies. For
    // cell-list selections that's `voxels_`'s AABB; for SetBox preview
    // (box-select mid-drag) it's the live drag box. Empty = "no
    // selection visible."
    const Bounds3 newBbox = sel.active() ? sel.bounds() : Bounds3{};
    const bool is_box_mode = sel.active() && sel.voxels().empty() &&
                             !sel.bounds().empty();

    // Refresh region = previous-upload bbox ∪ new bbox. Anything
    // outside this rectangle is unchanged (either was 0, stays 0).
    Bounds3 refresh{};
    if (!_lastSelBbox.empty() && !newBbox.empty()) {
        refresh.min_x = std::min(_lastSelBbox.min_x, newBbox.min_x);
        refresh.min_y = std::min(_lastSelBbox.min_y, newBbox.min_y);
        refresh.min_z = std::min(_lastSelBbox.min_z, newBbox.min_z);
        refresh.max_x = std::max(_lastSelBbox.max_x, newBbox.max_x);
        refresh.max_y = std::max(_lastSelBbox.max_y, newBbox.max_y);
        refresh.max_z = std::max(_lastSelBbox.max_z, newBbox.max_z);
    } else if (!_lastSelBbox.empty()) {
        refresh = _lastSelBbox;
    } else if (!newBbox.empty()) {
        refresh = newBbox;
    } else {
        return;  // nothing was uploaded; nothing to upload.
    }

    // Clip to texture extents.
    const int32_t tx0 = _originX, ty0 = _originY, tz0 = _originZ;
    const int32_t tx1 = _originX + _sizeX - 1;
    const int32_t ty1 = _originY + _sizeY - 1;
    const int32_t tz1 = _originZ + _sizeZ - 1;
    refresh.min_x = std::max(refresh.min_x, tx0);
    refresh.min_y = std::max(refresh.min_y, ty0);
    refresh.min_z = std::max(refresh.min_z, tz0);
    refresh.max_x = std::min(refresh.max_x, tx1);
    refresh.max_y = std::min(refresh.max_y, ty1);
    refresh.max_z = std::min(refresh.max_z, tz1);
    if (refresh.empty()) {
        _lastSelBbox = newBbox;
        return;
    }

    const int rx = refresh.size_x();
    const int ry = refresh.size_y();
    const int rz = refresh.size_z();
    std::vector<uint8_t> tile(
        static_cast<size_t>(rx) * static_cast<size_t>(ry) *
            static_cast<size_t>(rz),
        0);
    auto tile_idx = [&](int32_t x, int32_t y, int32_t z) -> size_t {
        return static_cast<size_t>(x - refresh.min_x) +
               static_cast<size_t>(y - refresh.min_y) *
                   static_cast<size_t>(rx) +
               static_cast<size_t>(z - refresh.min_z) *
                   static_cast<size_t>(rx) * static_cast<size_t>(ry);
    };

    if (is_box_mode) {
        const int32_t bx0 = std::max(newBbox.min_x, refresh.min_x);
        const int32_t by0 = std::max(newBbox.min_y, refresh.min_y);
        const int32_t bz0 = std::max(newBbox.min_z, refresh.min_z);
        const int32_t bx1 = std::min(newBbox.max_x, refresh.max_x);
        const int32_t by1 = std::min(newBbox.max_y, refresh.max_y);
        const int32_t bz1 = std::min(newBbox.max_z, refresh.max_z);
        for (int32_t z = bz0; z <= bz1; ++z)
        for (int32_t y = by0; y <= by1; ++y)
        for (int32_t x = bx0; x <= bx1; ++x) {
            tile[tile_idx(x, y, z)] = 1;
        }
    } else if (!newBbox.empty()) {
        for (const auto& v : sel.voxels()) {
            if (v[0] < refresh.min_x || v[0] > refresh.max_x ||
                v[1] < refresh.min_y || v[1] > refresh.max_y ||
                v[2] < refresh.min_z || v[2] > refresh.max_z) continue;
            tile[tile_idx(v[0], v[1], v[2])] = 1;
        }
    }

    MTLRegion region = MTLRegionMake3D(
        (NSUInteger)(refresh.min_x - _originX),
        (NSUInteger)(refresh.min_y - _originY),
        (NSUInteger)(refresh.min_z - _originZ),
        (NSUInteger)rx, (NSUInteger)ry, (NSUInteger)rz);
    [_selectionTexture replaceRegion:region
                         mipmapLevel:0
                               slice:0
                           withBytes:tile.data()
                         bytesPerRow:(NSUInteger)rx
                       bytesPerImage:(NSUInteger)((size_t)rx * (size_t)ry)];

    // Oracle bytes for chunks the refresh region touches. "any" is
    // recomputed per chunk by scanning the freshly-built tile so a
    // stale 1 left over from the previous bbox correctly drops to 0
    // when the new selection no longer covers that chunk.
    const int chunk = macvoxel::VoxelVolume::kChunkSize;
    const int32_t cx0 = (refresh.min_x - _originX) / chunk;
    const int32_t cy0 = (refresh.min_y - _originY) / chunk;
    const int32_t cz0 = (refresh.min_z - _originZ) / chunk;
    const int32_t cx1 = (refresh.max_x - _originX) / chunk;
    const int32_t cy1 = (refresh.max_y - _originY) / chunk;
    const int32_t cz1 = (refresh.max_z - _originZ) / chunk;
    for (int32_t cz_i = cz0; cz_i <= cz1; ++cz_i)
    for (int32_t cy_i = cy0; cy_i <= cy1; ++cy_i)
    for (int32_t cx_i = cx0; cx_i <= cx1; ++cx_i) {
        const int32_t lo_x = std::max((cx_i * chunk) + _originX, refresh.min_x);
        const int32_t lo_y = std::max((cy_i * chunk) + _originY, refresh.min_y);
        const int32_t lo_z = std::max((cz_i * chunk) + _originZ, refresh.min_z);
        const int32_t hi_x = std::min(((cx_i + 1) * chunk - 1) + _originX,
                                       refresh.max_x);
        const int32_t hi_y = std::min(((cy_i + 1) * chunk - 1) + _originY,
                                       refresh.max_y);
        const int32_t hi_z = std::min(((cz_i + 1) * chunk - 1) + _originZ,
                                       refresh.max_z);
        uint8_t any = 0;
        for (int32_t z = lo_z; z <= hi_z && !any; ++z) {
            for (int32_t y = lo_y; y <= hi_y && !any; ++y) {
                for (int32_t x = lo_x; x <= hi_x; ++x) {
                    if (tile[tile_idx(x, y, z)]) { any = 1; break; }
                }
            }
        }
        MTLRegion oc = MTLRegionMake3D(
            (NSUInteger)cx_i, (NSUInteger)cy_i, (NSUInteger)cz_i, 1, 1, 1);
        [_selectionOracleTexture replaceRegion:oc
                                   mipmapLevel:0
                                         slice:0
                                     withBytes:&any
                                   bytesPerRow:1
                                 bytesPerImage:1];
    }

    _lastSelBbox = newBbox;
}

- (void)markOracleChunkAtX:(int)x y:(int)y z:(int)z {
    if (x < 0 || y < 0 || z < 0 ||
        x >= _chunksX || y >= _chunksY || z >= _chunksZ) return;
    uint8_t one = 1;
    MTLRegion oc = MTLRegionMake3D((NSUInteger)x, (NSUInteger)y, (NSUInteger)z,
                                   1, 1, 1);
    [_oracleTexture replaceRegion:oc
                      mipmapLevel:0
                            slice:0
                        withBytes:&one
                      bytesPerRow:1
                    bytesPerImage:1];
}

@end
