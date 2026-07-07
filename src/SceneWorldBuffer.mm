#import "SceneWorldBuffer.h"

#include "ChunkPool.h"
#include "VoxScene.h"

@implementation SceneWorldBuffer {
    id<MTLDevice> _device;
}

- (nullable instancetype)initWithDevice:(nonnull id<MTLDevice>)device {
    self = [super init];
    if (self == nil) return nil;
    _device = device;
    return self;
}

- (BOOL)rebuildFromScene:(const macvoxel::Scene&)scene
                 exclude:(int)excludeObject {
    macvoxel::VoxelGrid flat;
    macvoxel::FlattenScene(scene, excludeObject, &flat);
    macvoxel::PackedChunks packed = macvoxel::PackGridChunks(flat);
    if (packed.empty()) {
        _coarse = nil;
        _pool = nil;
        _coarseMin = simd::int3{0, 0, 0};
        _coarseDim = simd::int3{0, 0, 0};
        _worldBounds = macvoxel::Bounds3{};
        _nonEmpty = NO;
        return NO;
    }
    _coarseMin = simd::int3{packed.min[0], packed.min[1], packed.min[2]};
    _coarseDim = simd::int3{packed.dim[0], packed.dim[1], packed.dim[2]};
    _worldBounds = flat.Bounds();
    _coarse = [_device newBufferWithBytes:packed.coarse.data()
                                   length:packed.coarse.size() * sizeof(uint32_t)
                                  options:MTLResourceStorageModeShared];
    _coarse.label = @"SceneWorldCoarse";
    _pool = [_device newBufferWithBytes:packed.pool.data()
                                 length:packed.pool.size()
                                options:MTLResourceStorageModeShared];
    _pool.label = @"SceneWorldPool";
    _nonEmpty = (_coarse != nil && _pool != nil);
    return _nonEmpty;
}

@end
