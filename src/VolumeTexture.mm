#import "VolumeTexture.h"

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
    id<MTLTexture> _liftTexture;
    id<MTLTexture> _liftOracleTexture;
    id<MTLTexture> _liftSnapshotTexture;
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
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
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

    _previewTexture = [device newTextureWithDescriptor:desc];
    if (_previewTexture == nil) return nil;
    [_previewTexture setLabel:@"VolumeTexture.previewTex"];

    _previewOracleTexture = [device newTextureWithDescriptor:oracleDesc];
    if (_previewOracleTexture == nil) return nil;
    [_previewOracleTexture setLabel:@"VolumeTexture.previewOracle"];

    _previewRemTexture = [device newTextureWithDescriptor:desc];
    if (_previewRemTexture == nil) return nil;
    [_previewRemTexture setLabel:@"VolumeTexture.previewRem"];

    _previewRemOracleTexture = [device newTextureWithDescriptor:oracleDesc];
    if (_previewRemOracleTexture == nil) return nil;
    [_previewRemOracleTexture setLabel:@"VolumeTexture.previewRemOracle"];

    // tex_lift: dense R8Uint 256³, same dims as the doc. Holds palette
    // indices for the active lift's contents.
    _liftTexture = [device newTextureWithDescriptor:desc];
    if (_liftTexture == nil) return nil;
    [_liftTexture setLabel:@"VolumeTexture.liftTex"];

    _liftOracleTexture = [device newTextureWithDescriptor:oracleDesc];
    if (_liftOracleTexture == nil) return nil;
    [_liftOracleTexture setLabel:@"VolumeTexture.liftOracle"];

    // Scratch snapshot for transform kernels — blit lift→snap, kernel
    // reads snap and writes live lift.
    _liftSnapshotTexture = [device newTextureWithDescriptor:desc];
    if (_liftSnapshotTexture == nil) return nil;
    [_liftSnapshotTexture setLabel:@"VolumeTexture.liftSnap"];

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

- (void)encodeLiftSnapshot:(id<MTLCommandBuffer>)cmd
                  worldBbox:(const macvoxel::Bounds3&)world_bbox {
    if (world_bbox.empty()) return;
    const int32_t x0 = std::max(world_bbox.min_x, _originX);
    const int32_t y0 = std::max(world_bbox.min_y, _originY);
    const int32_t z0 = std::max(world_bbox.min_z, _originZ);
    const int32_t x1 = std::min(world_bbox.max_x, _originX + _sizeX - 1);
    const int32_t y1 = std::min(world_bbox.max_y, _originY + _sizeY - 1);
    const int32_t z1 = std::min(world_bbox.max_z, _originZ + _sizeZ - 1);
    if (x0 > x1 || y0 > y1 || z0 > z1) return;

    const NSUInteger lx = (NSUInteger)(x0 - _originX);
    const NSUInteger ly = (NSUInteger)(y0 - _originY);
    const NSUInteger lz = (NSUInteger)(z0 - _originZ);
    const MTLOrigin origin = MTLOriginMake(lx, ly, lz);
    const MTLSize size = MTLSizeMake(
        (NSUInteger)(x1 - x0 + 1),
        (NSUInteger)(y1 - y0 + 1),
        (NSUInteger)(z1 - z0 + 1));

    id<MTLBlitCommandEncoder> enc = [cmd blitCommandEncoder];
    enc.label = @"VolumeTexture.LiftSnapshot";
    [enc copyFromTexture:_liftTexture
             sourceSlice:0
             sourceLevel:0
            sourceOrigin:origin
              sourceSize:size
               toTexture:_liftSnapshotTexture
        destinationSlice:0
        destinationLevel:0
       destinationOrigin:origin];
    [enc endEncoding];
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
