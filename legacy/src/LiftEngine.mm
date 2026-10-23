#import "LiftEngine.h"

#import "VolumeTexture.h"
#import "VoxelGrid.h"  // Bounds3

#import <cstdio>
#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace {

NSString* LoadKernelSource() {
    NSURL* url = [NSBundle.mainBundle URLForResource:@"LiftKernel"
                                       withExtension:@"metal"];
    if (url == nil) {
        fprintf(stderr,
                "MacVoxel: LiftKernel.metal missing from bundle Resources\n");
        return nil;
    }
    NSError* error = nil;
    NSString* source = [NSString stringWithContentsOfURL:url
                                                encoding:NSUTF8StringEncoding
                                                   error:&error];
    if (source == nil) {
        fprintf(stderr,
                "MacVoxel: failed to read LiftKernel.metal: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    return source;
}

// Mirrors LiftBboxUniforms in LiftKernel.metal — int3+pad to match
// MSL's 16-byte alignment.
struct LiftBboxUniforms {
    int32_t dispatch_lo[4];
    int32_t dispatch_size[4];
    int32_t tex_origin[4];
};

struct LiftCellsUniforms {
    int32_t tex_origin[4];
};

struct LiftTranslateUniforms {
    int32_t dispatch_lo[4];
    int32_t dispatch_size[4];
    int32_t tex_origin[4];
    int32_t offset[4];
    int32_t snap_local_min[4];
    int32_t snap_local_max[4];
};

struct LiftTransformUniforms {
    int32_t inv_map_row0[4];
    int32_t inv_map_row1[4];
    int32_t inv_map_row2[4];
    float   src_center[4];
    float   dst_center[4];
    int32_t dst_bbox_min[4];
    int32_t dst_bbox_max[4];
    int32_t dispatch_lo[4];
    int32_t dispatch_size[4];
    int32_t tex_origin[4];
    int32_t snap_local_min[4];
    int32_t snap_local_max[4];
};

struct CellEntry { int32_t x, y, z; uint32_t _pad; };

// Returns inclusive-bbox intersection with the texture extent, in
// texture-local coords. dx/dy/dz are dispatch sizes, all 0 → return
// false (nothing to dispatch).
bool ClipWorldBbox(const macvoxel::Bounds3& bbox,
                   int32_t tex_lo_x, int32_t tex_lo_y, int32_t tex_lo_z,
                   int32_t tex_hi_x, int32_t tex_hi_y, int32_t tex_hi_z,
                   int32_t* out_lo_x, int32_t* out_lo_y, int32_t* out_lo_z,
                   int32_t* out_dx, int32_t* out_dy, int32_t* out_dz) {
    if (bbox.empty()) return false;
    const int32_t x0 = std::max(bbox.min_x, tex_lo_x);
    const int32_t y0 = std::max(bbox.min_y, tex_lo_y);
    const int32_t z0 = std::max(bbox.min_z, tex_lo_z);
    const int32_t x1 = std::min(bbox.max_x, tex_hi_x);
    const int32_t y1 = std::min(bbox.max_y, tex_hi_y);
    const int32_t z1 = std::min(bbox.max_z, tex_hi_z);
    if (x0 > x1 || y0 > y1 || z0 > z1) return false;
    *out_lo_x = x0 - tex_lo_x;
    *out_lo_y = y0 - tex_lo_y;
    *out_lo_z = z0 - tex_lo_z;
    *out_dx = x1 - x0 + 1;
    *out_dy = y1 - y0 + 1;
    *out_dz = z1 - z0 + 1;
    return true;
}

}  // namespace

@implementation LiftEngine {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _boxPSO;
    id<MTLComputePipelineState> _cellsPSO;
    id<MTLComputePipelineState> _translatePSO;
    id<MTLComputePipelineState> _transformPSO;
    id<MTLComputePipelineState> _commitPSO;
    id<MTLComputePipelineState> _clearPSO;
    id<MTLBuffer> _cellsBuffer;
    NSUInteger _cellsBufferCapacity;
    id<MTLCommandBuffer> _lastBuffer;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   commandQueue:(id<MTLCommandQueue>)queue {
    self = [super init];
    if (self == nil) return nil;
    _device = device;
    _queue = queue;

    NSString* source = LoadKernelSource();
    if (source == nil) return nil;
    NSError* error = nil;
    id<MTLLibrary> library =
        [_device newLibraryWithSource:source options:nil error:&error];
    if (library == nil) {
        fprintf(stderr,
                "MacVoxel: failed to compile lift kernel: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }

    auto makePso = ^id<MTLComputePipelineState>(NSString* name) {
        id<MTLFunction> fn = [library newFunctionWithName:name];
        if (fn == nil) {
            fprintf(stderr, "MacVoxel: missing kernel %s\n",
                    [name UTF8String]);
            return nil;
        }
        NSError* err = nil;
        id<MTLComputePipelineState> pso =
            [self->_device newComputePipelineStateWithFunction:fn error:&err];
        if (pso == nil) {
            fprintf(stderr,
                    "MacVoxel: failed to build %s pipeline: %s\n",
                    [name UTF8String], [[err localizedDescription] UTF8String]);
        }
        return pso;
    };
    _boxPSO       = makePso(@"lift_box_main");
    _cellsPSO     = makePso(@"lift_cells_main");
    _translatePSO = makePso(@"lift_translate_main");
    _transformPSO = makePso(@"lift_transform_main");
    _commitPSO    = makePso(@"lift_commit_main");
    _clearPSO     = makePso(@"lift_clear_main");
    if (_boxPSO == nil || _cellsPSO == nil || _translatePSO == nil ||
        _transformPSO == nil || _commitPSO == nil || _clearPSO == nil) {
        return nil;
    }
    return self;
}

- (void)ensureCellsCapacity:(NSUInteger)count {
    const NSUInteger needed = count * sizeof(CellEntry);
    if (_cellsBuffer != nil && _cellsBufferCapacity >= needed) return;
    NSUInteger cap = _cellsBufferCapacity == 0 ? 4096 : _cellsBufferCapacity;
    while (cap < needed) cap *= 2;
    _cellsBuffer = [_device newBufferWithLength:cap
                                        options:MTLResourceStorageModeShared];
    _cellsBuffer.label = @"LiftCells";
    _cellsBufferCapacity = cap;
}

- (void)dispatchLiftBox:(VolumeTexture*)texture
              worldBbox:(const macvoxel::Bounds3&)bbox {
    if (texture == nil || _boxPSO == nil) return;
    const int32_t tex_lo_x = texture.originX;
    const int32_t tex_lo_y = texture.originY;
    const int32_t tex_lo_z = texture.originZ;
    const int32_t tex_hi_x = tex_lo_x + texture.sizeX - 1;
    const int32_t tex_hi_y = tex_lo_y + texture.sizeY - 1;
    const int32_t tex_hi_z = tex_lo_z + texture.sizeZ - 1;
    int32_t lo_x, lo_y, lo_z, dx, dy, dz;
    if (!ClipWorldBbox(bbox, tex_lo_x, tex_lo_y, tex_lo_z,
                        tex_hi_x, tex_hi_y, tex_hi_z,
                        &lo_x, &lo_y, &lo_z, &dx, &dy, &dz)) return;

    LiftBboxUniforms u{};
    u.dispatch_lo[0]   = lo_x;
    u.dispatch_lo[1]   = lo_y;
    u.dispatch_lo[2]   = lo_z;
    u.dispatch_size[0] = dx;
    u.dispatch_size[1] = dy;
    u.dispatch_size[2] = dz;
    u.tex_origin[0]    = tex_lo_x;
    u.tex_origin[1]    = tex_lo_y;
    u.tex_origin[2]    = tex_lo_z;

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"LiftBox";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_boxPSO];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setTexture:texture.texture          atIndex:0];
    [enc setTexture:texture.oracleTexture    atIndex:1];
    [enc setTexture:texture.liftTexture      atIndex:2];
    [enc setTexture:texture.liftOracleTexture atIndex:3];
    const NSUInteger tgX = std::min<NSUInteger>(8, (NSUInteger)dx);
    const NSUInteger tgY = std::min<NSUInteger>(8, (NSUInteger)dy);
    const NSUInteger tgZ = std::min<NSUInteger>(8, (NSUInteger)dz);
    [enc dispatchThreadgroups:MTLSizeMake(((NSUInteger)dx + tgX - 1) / tgX,
                                           ((NSUInteger)dy + tgY - 1) / tgY,
                                           ((NSUInteger)dz + tgZ - 1) / tgZ)
        threadsPerThreadgroup:MTLSizeMake(tgX, tgY, tgZ)];
    [enc endEncoding];
    [cmd commit];
    _lastBuffer = cmd;
}

- (void)dispatchLiftCells:(VolumeTexture*)texture
                    cells:(const int32_t*)cells_xyz
                cellCount:(NSUInteger)cellCount {
    if (texture == nil || _cellsPSO == nil || cellCount == 0) return;
    [self ensureCellsCapacity:cellCount];

    // Pack int3 + 4-byte pad into the GPU buffer.
    CellEntry* dst = static_cast<CellEntry*>(_cellsBuffer.contents);
    for (NSUInteger i = 0; i < cellCount; ++i) {
        dst[i].x = cells_xyz[i * 3 + 0];
        dst[i].y = cells_xyz[i * 3 + 1];
        dst[i].z = cells_xyz[i * 3 + 2];
        dst[i]._pad = 0;
    }

    LiftCellsUniforms u{};
    u.tex_origin[0] = texture.originX;
    u.tex_origin[1] = texture.originY;
    u.tex_origin[2] = texture.originZ;
    uint32_t count32 = (uint32_t)cellCount;

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"LiftCells";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_cellsPSO];
    [enc setBytes:&u       length:sizeof(u)       atIndex:0];
    [enc setBuffer:_cellsBuffer offset:0          atIndex:1];
    [enc setBytes:&count32 length:sizeof(count32) atIndex:2];
    [enc setTexture:texture.texture           atIndex:0];
    [enc setTexture:texture.oracleTexture     atIndex:1];
    [enc setTexture:texture.liftTexture       atIndex:2];
    [enc setTexture:texture.liftOracleTexture atIndex:3];
    const NSUInteger tg =
        std::min<NSUInteger>(_cellsPSO.maxTotalThreadsPerThreadgroup, 64);
    [enc dispatchThreadgroups:MTLSizeMake((cellCount + tg - 1) / tg, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
    [enc endEncoding];
    [cmd commit];
    _lastBuffer = cmd;
}

- (void)dispatchLiftTranslate:(VolumeTexture*)texture
                  oldWorldBbox:(const macvoxel::Bounds3&)old_bbox
                  newWorldBbox:(const macvoxel::Bounds3&)new_bbox
                        offset:(int32_t[3])offset {
    if (texture == nil || _translatePSO == nil) return;
    // Snap blit covers old (we read from it).
    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"LiftTranslate";
    [texture encodeLiftSnapshot:cmd worldBbox:old_bbox];

    // Dispatch covers union(old, new) in world coords, clipped to texture.
    macvoxel::Bounds3 uni = old_bbox;
    if (uni.empty()) {
        uni = new_bbox;
    } else if (!new_bbox.empty()) {
        uni.min_x = std::min(uni.min_x, new_bbox.min_x);
        uni.min_y = std::min(uni.min_y, new_bbox.min_y);
        uni.min_z = std::min(uni.min_z, new_bbox.min_z);
        uni.max_x = std::max(uni.max_x, new_bbox.max_x);
        uni.max_y = std::max(uni.max_y, new_bbox.max_y);
        uni.max_z = std::max(uni.max_z, new_bbox.max_z);
    }
    const int32_t tex_lo_x = texture.originX;
    const int32_t tex_lo_y = texture.originY;
    const int32_t tex_lo_z = texture.originZ;
    const int32_t tex_hi_x = tex_lo_x + texture.sizeX - 1;
    const int32_t tex_hi_y = tex_lo_y + texture.sizeY - 1;
    const int32_t tex_hi_z = tex_lo_z + texture.sizeZ - 1;
    int32_t lo_x, lo_y, lo_z, dx, dy, dz;
    if (!ClipWorldBbox(uni, tex_lo_x, tex_lo_y, tex_lo_z,
                        tex_hi_x, tex_hi_y, tex_hi_z,
                        &lo_x, &lo_y, &lo_z, &dx, &dy, &dz)) {
        [cmd commit];
        _lastBuffer = cmd;
        return;
    }

    LiftTranslateUniforms u{};
    u.dispatch_lo[0]   = lo_x;
    u.dispatch_lo[1]   = lo_y;
    u.dispatch_lo[2]   = lo_z;
    u.dispatch_size[0] = dx;
    u.dispatch_size[1] = dy;
    u.dispatch_size[2] = dz;
    u.tex_origin[0]    = tex_lo_x;
    u.tex_origin[1]    = tex_lo_y;
    u.tex_origin[2]    = tex_lo_z;
    u.offset[0]        = offset[0];
    u.offset[1]        = offset[1];
    u.offset[2]        = offset[2];
    // The snapshot covered old_bbox (clipped to the texture).
    const int32_t snap_min_x =
        std::max(old_bbox.min_x, tex_lo_x) - tex_lo_x;
    const int32_t snap_min_y =
        std::max(old_bbox.min_y, tex_lo_y) - tex_lo_y;
    const int32_t snap_min_z =
        std::max(old_bbox.min_z, tex_lo_z) - tex_lo_z;
    const int32_t snap_max_x =
        std::min(old_bbox.max_x, tex_hi_x) - tex_lo_x;
    const int32_t snap_max_y =
        std::min(old_bbox.max_y, tex_hi_y) - tex_lo_y;
    const int32_t snap_max_z =
        std::min(old_bbox.max_z, tex_hi_z) - tex_lo_z;
    u.snap_local_min[0] = snap_min_x;
    u.snap_local_min[1] = snap_min_y;
    u.snap_local_min[2] = snap_min_z;
    u.snap_local_max[0] = snap_max_x;
    u.snap_local_max[1] = snap_max_y;
    u.snap_local_max[2] = snap_max_z;

    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_translatePSO];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setTexture:texture.liftSnapshotTexture atIndex:0];
    [enc setTexture:texture.liftTexture         atIndex:1];
    [enc setTexture:texture.liftOracleTexture   atIndex:2];
    const NSUInteger tgX = std::min<NSUInteger>(8, (NSUInteger)dx);
    const NSUInteger tgY = std::min<NSUInteger>(8, (NSUInteger)dy);
    const NSUInteger tgZ = std::min<NSUInteger>(8, (NSUInteger)dz);
    [enc dispatchThreadgroups:MTLSizeMake(((NSUInteger)dx + tgX - 1) / tgX,
                                           ((NSUInteger)dy + tgY - 1) / tgY,
                                           ((NSUInteger)dz + tgZ - 1) / tgZ)
        threadsPerThreadgroup:MTLSizeMake(tgX, tgY, tgZ)];
    [enc endEncoding];
    [cmd commit];
    _lastBuffer = cmd;
}

- (void)dispatchLiftTransform:(VolumeTexture*)texture
                       params:(const macvoxel::LiftTransformParams&)params
                      oldBbox:(const macvoxel::Bounds3&)old_bbox {
    if (texture == nil || _transformPSO == nil) return;

    const macvoxel::Bounds3 dst_bbox = {
        params.dst_x0, params.dst_y0, params.dst_z0,
        params.dst_x1, params.dst_y1, params.dst_z1};
    if (dst_bbox.empty()) return;

    // Dispatch covers union(old, dst). Kernel back-maps inside dst,
    // zeroes outside — clearing the old lift position in the same
    // pass so we don't need a separate clear (which would zero the
    // lift before the snapshot blit and produce vanishing voxels).
    macvoxel::Bounds3 uni = dst_bbox;
    if (!old_bbox.empty()) {
        uni.min_x = std::min(uni.min_x, old_bbox.min_x);
        uni.min_y = std::min(uni.min_y, old_bbox.min_y);
        uni.min_z = std::min(uni.min_z, old_bbox.min_z);
        uni.max_x = std::max(uni.max_x, old_bbox.max_x);
        uni.max_y = std::max(uni.max_y, old_bbox.max_y);
        uni.max_z = std::max(uni.max_z, old_bbox.max_z);
    }

    const int32_t tex_lo_x = texture.originX;
    const int32_t tex_lo_y = texture.originY;
    const int32_t tex_lo_z = texture.originZ;
    const int32_t tex_hi_x = tex_lo_x + texture.sizeX - 1;
    const int32_t tex_hi_y = tex_lo_y + texture.sizeY - 1;
    const int32_t tex_hi_z = tex_lo_z + texture.sizeZ - 1;
    int32_t lo_x, lo_y, lo_z, dx, dy, dz;
    if (!ClipWorldBbox(uni, tex_lo_x, tex_lo_y, tex_lo_z,
                        tex_hi_x, tex_hi_y, tex_hi_z,
                        &lo_x, &lo_y, &lo_z, &dx, &dy, &dz)) return;

    // Snapshot the source region (old bbox — that's where the lift
    // currently sits and where the kernel back-map gathers from).
    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"LiftTransform";
    macvoxel::Bounds3 snap_b =
        old_bbox.empty() ? dst_bbox : old_bbox;
    [texture encodeLiftSnapshot:cmd worldBbox:snap_b];

    LiftTransformUniforms u{};
    u.inv_map_row0[0] = params.inv_map[0];
    u.inv_map_row0[1] = params.inv_map[1];
    u.inv_map_row0[2] = params.inv_map[2];
    u.inv_map_row1[0] = params.inv_map[3];
    u.inv_map_row1[1] = params.inv_map[4];
    u.inv_map_row1[2] = params.inv_map[5];
    u.inv_map_row2[0] = params.inv_map[6];
    u.inv_map_row2[1] = params.inv_map[7];
    u.inv_map_row2[2] = params.inv_map[8];
    u.src_center[0]   = params.src_center[0];
    u.src_center[1]   = params.src_center[1];
    u.src_center[2]   = params.src_center[2];
    u.dst_center[0]   = params.dst_center[0];
    u.dst_center[1]   = params.dst_center[1];
    u.dst_center[2]   = params.dst_center[2];
    u.dst_bbox_min[0] = params.dst_x0;
    u.dst_bbox_min[1] = params.dst_y0;
    u.dst_bbox_min[2] = params.dst_z0;
    u.dst_bbox_max[0] = params.dst_x1;
    u.dst_bbox_max[1] = params.dst_y1;
    u.dst_bbox_max[2] = params.dst_z1;
    u.dispatch_lo[0]  = lo_x;
    u.dispatch_lo[1]  = lo_y;
    u.dispatch_lo[2]  = lo_z;
    u.dispatch_size[0] = dx;
    u.dispatch_size[1] = dy;
    u.dispatch_size[2] = dz;
    u.tex_origin[0]   = tex_lo_x;
    u.tex_origin[1]   = tex_lo_y;
    u.tex_origin[2]   = tex_lo_z;
    const int32_t snap_min_x =
        std::max(snap_b.min_x, tex_lo_x) - tex_lo_x;
    const int32_t snap_min_y =
        std::max(snap_b.min_y, tex_lo_y) - tex_lo_y;
    const int32_t snap_min_z =
        std::max(snap_b.min_z, tex_lo_z) - tex_lo_z;
    const int32_t snap_max_x =
        std::min(snap_b.max_x, tex_hi_x) - tex_lo_x;
    const int32_t snap_max_y =
        std::min(snap_b.max_y, tex_hi_y) - tex_lo_y;
    const int32_t snap_max_z =
        std::min(snap_b.max_z, tex_hi_z) - tex_lo_z;
    u.snap_local_min[0] = snap_min_x;
    u.snap_local_min[1] = snap_min_y;
    u.snap_local_min[2] = snap_min_z;
    u.snap_local_max[0] = snap_max_x;
    u.snap_local_max[1] = snap_max_y;
    u.snap_local_max[2] = snap_max_z;

    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_transformPSO];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setTexture:texture.liftSnapshotTexture atIndex:0];
    [enc setTexture:texture.liftTexture         atIndex:1];
    [enc setTexture:texture.liftOracleTexture   atIndex:2];
    const NSUInteger tgX = std::min<NSUInteger>(8, (NSUInteger)dx);
    const NSUInteger tgY = std::min<NSUInteger>(8, (NSUInteger)dy);
    const NSUInteger tgZ = std::min<NSUInteger>(8, (NSUInteger)dz);
    [enc dispatchThreadgroups:MTLSizeMake(((NSUInteger)dx + tgX - 1) / tgX,
                                           ((NSUInteger)dy + tgY - 1) / tgY,
                                           ((NSUInteger)dz + tgZ - 1) / tgZ)
        threadsPerThreadgroup:MTLSizeMake(tgX, tgY, tgZ)];
    [enc endEncoding];
    [cmd commit];
    _lastBuffer = cmd;
}

- (void)dispatchLiftCommit:(VolumeTexture*)texture
                  worldBbox:(const macvoxel::Bounds3&)bbox {
    if (texture == nil || _commitPSO == nil) return;
    const int32_t tex_lo_x = texture.originX;
    const int32_t tex_lo_y = texture.originY;
    const int32_t tex_lo_z = texture.originZ;
    const int32_t tex_hi_x = tex_lo_x + texture.sizeX - 1;
    const int32_t tex_hi_y = tex_lo_y + texture.sizeY - 1;
    const int32_t tex_hi_z = tex_lo_z + texture.sizeZ - 1;
    int32_t lo_x, lo_y, lo_z, dx, dy, dz;
    if (!ClipWorldBbox(bbox, tex_lo_x, tex_lo_y, tex_lo_z,
                        tex_hi_x, tex_hi_y, tex_hi_z,
                        &lo_x, &lo_y, &lo_z, &dx, &dy, &dz)) return;

    LiftBboxUniforms u{};
    u.dispatch_lo[0]   = lo_x;
    u.dispatch_lo[1]   = lo_y;
    u.dispatch_lo[2]   = lo_z;
    u.dispatch_size[0] = dx;
    u.dispatch_size[1] = dy;
    u.dispatch_size[2] = dz;
    u.tex_origin[0]    = tex_lo_x;
    u.tex_origin[1]    = tex_lo_y;
    u.tex_origin[2]    = tex_lo_z;

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"LiftCommit";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_commitPSO];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setTexture:texture.texture          atIndex:0];
    [enc setTexture:texture.oracleTexture    atIndex:1];
    [enc setTexture:texture.liftTexture      atIndex:2];
    const NSUInteger tgX = std::min<NSUInteger>(8, (NSUInteger)dx);
    const NSUInteger tgY = std::min<NSUInteger>(8, (NSUInteger)dy);
    const NSUInteger tgZ = std::min<NSUInteger>(8, (NSUInteger)dz);
    [enc dispatchThreadgroups:MTLSizeMake(((NSUInteger)dx + tgX - 1) / tgX,
                                           ((NSUInteger)dy + tgY - 1) / tgY,
                                           ((NSUInteger)dz + tgZ - 1) / tgZ)
        threadsPerThreadgroup:MTLSizeMake(tgX, tgY, tgZ)];
    [enc endEncoding];
    [cmd commit];
    _lastBuffer = cmd;
}

- (void)dispatchLiftClear:(VolumeTexture*)texture
                worldBbox:(const macvoxel::Bounds3&)bbox {
    if (texture == nil || _clearPSO == nil) return;
    const int32_t tex_lo_x = texture.originX;
    const int32_t tex_lo_y = texture.originY;
    const int32_t tex_lo_z = texture.originZ;
    const int32_t tex_hi_x = tex_lo_x + texture.sizeX - 1;
    const int32_t tex_hi_y = tex_lo_y + texture.sizeY - 1;
    const int32_t tex_hi_z = tex_lo_z + texture.sizeZ - 1;
    int32_t lo_x, lo_y, lo_z, dx, dy, dz;
    if (!ClipWorldBbox(bbox, tex_lo_x, tex_lo_y, tex_lo_z,
                        tex_hi_x, tex_hi_y, tex_hi_z,
                        &lo_x, &lo_y, &lo_z, &dx, &dy, &dz)) return;

    LiftBboxUniforms u{};
    u.dispatch_lo[0]   = lo_x;
    u.dispatch_lo[1]   = lo_y;
    u.dispatch_lo[2]   = lo_z;
    u.dispatch_size[0] = dx;
    u.dispatch_size[1] = dy;
    u.dispatch_size[2] = dz;
    u.tex_origin[0]    = tex_lo_x;
    u.tex_origin[1]    = tex_lo_y;
    u.tex_origin[2]    = tex_lo_z;

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"LiftClear";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_clearPSO];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setTexture:texture.liftTexture atIndex:0];
    const NSUInteger tgX = std::min<NSUInteger>(8, (NSUInteger)dx);
    const NSUInteger tgY = std::min<NSUInteger>(8, (NSUInteger)dy);
    const NSUInteger tgZ = std::min<NSUInteger>(8, (NSUInteger)dz);
    [enc dispatchThreadgroups:MTLSizeMake(((NSUInteger)dx + tgX - 1) / tgX,
                                           ((NSUInteger)dy + tgY - 1) / tgY,
                                           ((NSUInteger)dz + tgZ - 1) / tgZ)
        threadsPerThreadgroup:MTLSizeMake(tgX, tgY, tgZ)];
    [enc endEncoding];
    [cmd commit];
    _lastBuffer = cmd;
}

- (void)waitForPendingWork {
    if (_lastBuffer == nil) return;
    [_lastBuffer waitUntilCompleted];
    _lastBuffer = nil;
}

@end
