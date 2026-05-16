#import "VolumeTexture.h"

#include "VoxelVolume.h"

#include <algorithm>
#include <cstdint>
#include <vector>

@implementation VolumeTexture {
    id<MTLTexture> _texture;
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
    desc.usage = MTLTextureUsageShaderRead;
    // Shared storage on Apple Silicon (unified memory). Required for
    // `replaceRegion:` uploads — Private textures are blit-only.
    desc.storageMode = MTLStorageModeShared;
    _texture = [device newTextureWithDescriptor:desc];
    if (_texture == nil) return nil;
    [_texture setLabel:@"VolumeTexture.docTex"];
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
            }
        }
    }
}

@end
