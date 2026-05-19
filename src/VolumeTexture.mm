#import "VolumeTexture.h"

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
    int _chunksX;
    int _chunksY;
    int _chunksZ;
    int _strideX;     // bytes per row in the dense buffer (= size_x)
    int _strideZ;     // bytes per slice (= size_x * size_y)
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
