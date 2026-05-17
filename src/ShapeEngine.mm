#import "ShapeEngine.h"
#import "VolumeTexture.h"

#import <cstdio>
#include <algorithm>
#include <cstdint>

namespace {

// Mirror of ShapeKernel.metal's `ShapeUniforms`. int3 fields are 16-byte
// aligned in MSL; the [4]-sized arrays here carry the trailing pad.
struct Uniforms {
    int32_t anchor[4];
    int32_t endpoint[4];
    int32_t face_axis;
    int32_t brush_size;
    int32_t brush_shape;
    int32_t brush_3d;
    uint32_t mode;
    uint32_t palette_idx;
    int32_t shape_kind;
    int32_t shape_fill;
    int32_t shape_even;
    int32_t line_straight;
    int32_t _pad0;
    int32_t _pad1;
    int32_t dispatch_lo[4];
    int32_t dispatch_size[4];
    int32_t vol_min[4];
    int32_t vol_max[4];
    int32_t tex_origin[4];
};
static_assert(sizeof(Uniforms) == 160, "ShapeUniforms layout drift");

// Mirror of ShapeKernel.metal's `StampCellsUniforms`. Just an int3 +
// pad — 16 bytes.
struct StampCellsUniforms {
    int32_t tex_origin[4];
};
static_assert(sizeof(StampCellsUniforms) == 16,
              "StampCellsUniforms layout drift");

// Mirror of ShapeKernel.metal's `CommitGenericUniforms`. int3 fields
// pad to 16 bytes in MSL — keep the [4] trailing pad here.
struct CommitGenericUniforms {
    int32_t dispatch_lo[4];
    int32_t dispatch_size[4];
    uint32_t bm;
    uint32_t brush;
    uint32_t fill_palette;
    uint32_t _pad;
};
static_assert(sizeof(CommitGenericUniforms) == 48,
              "CommitGenericUniforms layout drift");

NSString* LoadShapeLibrarySource() {
    NSURL* url = [NSBundle.mainBundle URLForResource:@"ShapeKernel"
                                       withExtension:@"metal"];
    if (url == nil) {
        fprintf(stderr,
                "MacVoxel: ShapeKernel.metal missing from bundle Resources\n");
        return nil;
    }
    NSError* error = nil;
    NSString* source = [NSString stringWithContentsOfURL:url
                                                encoding:NSUTF8StringEncoding
                                                   error:&error];
    if (source == nil) {
        fprintf(stderr,
                "MacVoxel: failed to read ShapeKernel.metal: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    return source;
}

void FillUniforms(Uniforms& u, const macvoxel::ShapeParams& p) {
    u.anchor[0] = p.anchor_x; u.anchor[1] = p.anchor_y; u.anchor[2] = p.anchor_z;
    u.endpoint[0] = p.endpoint_x; u.endpoint[1] = p.endpoint_y; u.endpoint[2] = p.endpoint_z;
    u.face_axis = p.face_axis;
    u.brush_size = p.brush_size;
    u.brush_shape = p.brush_shape;
    u.brush_3d = p.brush_3d;
    u.mode = p.mode;
    u.palette_idx = p.palette_idx;
    u.shape_kind = p.shape_kind;
    u.shape_fill = p.shape_fill;
    u.shape_even = p.shape_even;
    u.line_straight = p.line_straight;
    u.dispatch_lo[0] = p.dispatch_lo_x;
    u.dispatch_lo[1] = p.dispatch_lo_y;
    u.dispatch_lo[2] = p.dispatch_lo_z;
    u.dispatch_size[0] = p.dispatch_size_x;
    u.dispatch_size[1] = p.dispatch_size_y;
    u.dispatch_size[2] = p.dispatch_size_z;
    u.vol_min[0] = p.vol_min_x; u.vol_min[1] = p.vol_min_y; u.vol_min[2] = p.vol_min_z;
    u.vol_max[0] = p.vol_max_x; u.vol_max[1] = p.vol_max_y; u.vol_max[2] = p.vol_max_z;
    u.tex_origin[0] = p.tex_origin_x;
    u.tex_origin[1] = p.tex_origin_y;
    u.tex_origin[2] = p.tex_origin_z;
}

void Dispatch(id<MTLComputeCommandEncoder> enc,
              const macvoxel::ShapeParams& p) {
    const NSUInteger tgX = std::min<NSUInteger>(8, (NSUInteger)p.dispatch_size_x);
    const NSUInteger tgY = std::min<NSUInteger>(8, (NSUInteger)p.dispatch_size_y);
    const NSUInteger tgZ = std::min<NSUInteger>(8, (NSUInteger)p.dispatch_size_z);
    if (tgX == 0 || tgY == 0 || tgZ == 0) return;
    const MTLSize threadsPerThreadgroup = MTLSizeMake(tgX, tgY, tgZ);
    const MTLSize threadgroups = MTLSizeMake(
        ((NSUInteger)p.dispatch_size_x + tgX - 1) / tgX,
        ((NSUInteger)p.dispatch_size_y + tgY - 1) / tgY,
        ((NSUInteger)p.dispatch_size_z + tgZ - 1) / tgZ);
    [enc dispatchThreadgroups:threadgroups
        threadsPerThreadgroup:threadsPerThreadgroup];
}

}  // namespace

@implementation ShapeEngine {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _previewPSO;
    id<MTLComputePipelineState> _projectPSO;
    id<MTLComputePipelineState> _clearPSO;
    id<MTLComputePipelineState> _commitPSO;
    id<MTLComputePipelineState> _stampCellsPSO;
    id<MTLComputePipelineState> _commitCellsPSO;
    id<MTLComputePipelineState> _commitGenericPSO;
    id<MTLCommandBuffer> _lastBuffer;
    // Project-mode cell buffer — grows as needed to hold the picked
    // cell list. Packed (x, y, z, _pad) per cell to align with MSL's
    // PackedCellXYZ struct.
    id<MTLBuffer> _projectCellBuffer;
    NSUInteger _projectCellCapacity;
    // (cell, palette) buffer for Face's stamp/commit hot path. Same
    // grow-only policy as the project cell buffer.
    id<MTLBuffer> _cellPaletteBuffer;
    NSUInteger _cellPaletteCapacity;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   commandQueue:(id<MTLCommandQueue>)queue {
    self = [super init];
    if (self == nil) return nil;
    _device = device;
    _queue = queue;

    NSString* source = LoadShapeLibrarySource();
    if (source == nil) return nil;
    NSError* error = nil;
    id<MTLLibrary> library =
        [_device newLibraryWithSource:source options:nil error:&error];
    if (library == nil) {
        fprintf(stderr, "MacVoxel: failed to compile shape kernels: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }

    auto makePso = [&](NSString* name) -> id<MTLComputePipelineState> {
        id<MTLFunction> fn = [library newFunctionWithName:name];
        if (fn == nil) {
            fprintf(stderr, "MacVoxel: missing shape kernel '%s'\n",
                    [name UTF8String]);
            return nil;
        }
        NSError* err = nil;
        id<MTLComputePipelineState> pso =
            [_device newComputePipelineStateWithFunction:fn error:&err];
        if (pso == nil) {
            fprintf(stderr,
                    "MacVoxel: failed to build shape pipeline '%s': %s\n",
                    [name UTF8String],
                    [[err localizedDescription] UTF8String]);
        }
        return pso;
    };
    _previewPSO = makePso(@"shape_main");
    _projectPSO = makePso(@"shape_line_project_main");
    _clearPSO   = makePso(@"shape_clear");
    _commitPSO  = makePso(@"shape_commit");
    _stampCellsPSO  = makePso(@"shape_stamp_cells");
    _commitCellsPSO = makePso(@"shape_commit_cells");
    _commitGenericPSO = makePso(@"commit_generic");
    if (_previewPSO == nil || _projectPSO == nil || _clearPSO == nil ||
        _commitPSO == nil || _stampCellsPSO == nil ||
        _commitCellsPSO == nil || _commitGenericPSO == nil) {
        return nil;
    }
    return self;
}

- (void)ensureCellPaletteCapacity:(NSUInteger)cells {
    if (_cellPaletteCapacity >= cells && _cellPaletteBuffer != nil) return;
    NSUInteger newCap = std::max<NSUInteger>(_cellPaletteCapacity * 2, 1024);
    while (newCap < cells) newCap *= 2;
    _cellPaletteBuffer = [_device newBufferWithLength:newCap * 16
                                              options:MTLResourceStorageModeShared];
    _cellPaletteBuffer.label = @"ShapeCellPalette";
    _cellPaletteCapacity = newCap;
}

- (void)ensureProjectCellCapacity:(NSUInteger)cells {
    if (_projectCellCapacity >= cells && _projectCellBuffer != nil) return;
    NSUInteger newCap = std::max<NSUInteger>(_projectCellCapacity * 2, 512);
    while (newCap < cells) newCap *= 2;
    _projectCellBuffer = [_device newBufferWithLength:newCap * 16
                                              options:MTLResourceStorageModeShared];
    _projectCellBuffer.label = @"ShapeProjectCells";
    _projectCellCapacity = newCap;
}

- (void)dispatchPreview:(const macvoxel::ShapeParams&)p
                  target:(VolumeTexture*)texture {
    if (_previewPSO == nil || texture == nil) return;
    if (p.dispatch_size_x <= 0 || p.dispatch_size_y <= 0 ||
        p.dispatch_size_z <= 0) return;

    Uniforms u{};
    FillUniforms(u, p);

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"ShapePreviewDispatch";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_previewPSO];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setTexture:texture.texture atIndex:0];
    [enc setTexture:texture.previewTexture atIndex:1];
    [enc setTexture:texture.previewOracleTexture atIndex:2];
    Dispatch(enc, p);
    [enc endEncoding];
    [cmd commit];
    _lastBuffer = cmd;
}

- (void)dispatchLineProjectPreview:(const macvoxel::ShapeParams&)p
                              cells:(const int32_t*)cells_xyz
                         cellCount:(NSUInteger)cell_count
                             target:(VolumeTexture*)texture {
    if (_projectPSO == nil || texture == nil) return;
    if (p.dispatch_size_x <= 0 || p.dispatch_size_y <= 0 ||
        p.dispatch_size_z <= 0) return;
    if (cell_count == 0) {
        // No cells — still dispatch the regular shape kernel to clear
        // any previous-frame preview in the union bbox.
        [self dispatchPreview:p target:texture];
        return;
    }
    [self ensureProjectCellCapacity:cell_count];
    int32_t* dst = static_cast<int32_t*>(_projectCellBuffer.contents);
    for (NSUInteger i = 0; i < cell_count; ++i) {
        dst[i * 4 + 0] = cells_xyz[i * 3 + 0];
        dst[i * 4 + 1] = cells_xyz[i * 3 + 1];
        dst[i * 4 + 2] = cells_xyz[i * 3 + 2];
        dst[i * 4 + 3] = 0;
    }

    Uniforms u{};
    FillUniforms(u, p);

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"ShapeProjectDispatch";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_projectPSO];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setBuffer:_projectCellBuffer offset:0 atIndex:1];
    uint32_t count_u = static_cast<uint32_t>(cell_count);
    [enc setBytes:&count_u length:sizeof(count_u) atIndex:2];
    [enc setTexture:texture.texture atIndex:0];
    [enc setTexture:texture.previewTexture atIndex:1];
    [enc setTexture:texture.previewOracleTexture atIndex:2];
    Dispatch(enc, p);
    [enc endEncoding];
    [cmd commit];
    _lastBuffer = cmd;
}

- (void)clearPreviewBbox:(int)x0 y0:(int)y0 z0:(int)z0
                       x1:(int)x1 y1:(int)y1 z1:(int)z1
                   target:(VolumeTexture*)texture {
    if (_clearPSO == nil || texture == nil) return;
    if (x0 > x1 || y0 > y1 || z0 > z1) return;

    Uniforms u{};
    u.dispatch_lo[0] = x0;
    u.dispatch_lo[1] = y0;
    u.dispatch_lo[2] = z0;
    u.dispatch_size[0] = x1 - x0 + 1;
    u.dispatch_size[1] = y1 - y0 + 1;
    u.dispatch_size[2] = z1 - z0 + 1;

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"ShapeClearDispatch";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_clearPSO];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setTexture:texture.previewTexture atIndex:0];

    const NSUInteger tgX = std::min<NSUInteger>(8, (NSUInteger)u.dispatch_size[0]);
    const NSUInteger tgY = std::min<NSUInteger>(8, (NSUInteger)u.dispatch_size[1]);
    const NSUInteger tgZ = std::min<NSUInteger>(8, (NSUInteger)u.dispatch_size[2]);
    if (tgX == 0 || tgY == 0 || tgZ == 0) { [enc endEncoding]; return; }
    const MTLSize threadsPerThreadgroup = MTLSizeMake(tgX, tgY, tgZ);
    const MTLSize threadgroups = MTLSizeMake(
        ((NSUInteger)u.dispatch_size[0] + tgX - 1) / tgX,
        ((NSUInteger)u.dispatch_size[1] + tgY - 1) / tgY,
        ((NSUInteger)u.dispatch_size[2] + tgZ - 1) / tgZ);
    [enc dispatchThreadgroups:threadgroups
        threadsPerThreadgroup:threadsPerThreadgroup];
    [enc endEncoding];
    [cmd commit];
    _lastBuffer = cmd;
}

- (void)commitShape:(const macvoxel::ShapeParams&)p
             target:(VolumeTexture*)texture {
    if (_commitPSO == nil || texture == nil) return;
    if (p.dispatch_size_x <= 0 || p.dispatch_size_y <= 0 ||
        p.dispatch_size_z <= 0) return;

    Uniforms u{};
    FillUniforms(u, p);

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"ShapeCommitDispatch";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_commitPSO];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setTexture:texture.texture atIndex:0];
    [enc setTexture:texture.previewTexture atIndex:1];
    [enc setTexture:texture.oracleTexture atIndex:2];
    Dispatch(enc, p);
    [enc endEncoding];
    [cmd commit];
    _lastBuffer = cmd;
}

- (void)dispatchStampCells:(const macvoxel::CellPalette*)cells
                 cellCount:(NSUInteger)cell_count
                    target:(VolumeTexture*)texture {
    if (_stampCellsPSO == nil || texture == nil || cell_count == 0) return;
    [self ensureCellPaletteCapacity:cell_count];
    std::memcpy(_cellPaletteBuffer.contents, cells,
                cell_count * sizeof(macvoxel::CellPalette));

    StampCellsUniforms u{};
    u.tex_origin[0] = texture.originX;
    u.tex_origin[1] = texture.originY;
    u.tex_origin[2] = texture.originZ;

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"ShapeStampCellsDispatch";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_stampCellsPSO];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setBuffer:_cellPaletteBuffer offset:0 atIndex:1];
    uint32_t cc = static_cast<uint32_t>(cell_count);
    [enc setBytes:&cc length:sizeof(cc) atIndex:2];
    [enc setTexture:texture.previewTexture atIndex:0];
    [enc setTexture:texture.previewOracleTexture atIndex:1];

    const NSUInteger tg = std::min<NSUInteger>(64, cell_count);
    const MTLSize threadsPerThreadgroup = MTLSizeMake(tg, 1, 1);
    const MTLSize threadgroups = MTLSizeMake((cell_count + tg - 1) / tg, 1, 1);
    [enc dispatchThreadgroups:threadgroups
        threadsPerThreadgroup:threadsPerThreadgroup];
    [enc endEncoding];
    [cmd commit];
    _lastBuffer = cmd;
}

- (void)dispatchCommitCells:(const macvoxel::CellPalette*)cells
                  cellCount:(NSUInteger)cell_count
                     target:(VolumeTexture*)texture {
    if (_commitCellsPSO == nil || texture == nil || cell_count == 0) return;
    [self ensureCellPaletteCapacity:cell_count];
    std::memcpy(_cellPaletteBuffer.contents, cells,
                cell_count * sizeof(macvoxel::CellPalette));

    StampCellsUniforms u{};
    u.tex_origin[0] = texture.originX;
    u.tex_origin[1] = texture.originY;
    u.tex_origin[2] = texture.originZ;

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"ShapeCommitCellsDispatch";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_commitCellsPSO];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setBuffer:_cellPaletteBuffer offset:0 atIndex:1];
    uint32_t cc = static_cast<uint32_t>(cell_count);
    [enc setBytes:&cc length:sizeof(cc) atIndex:2];
    [enc setTexture:texture.texture atIndex:0];
    [enc setTexture:texture.previewTexture atIndex:1];
    [enc setTexture:texture.oracleTexture atIndex:2];

    const NSUInteger tg = std::min<NSUInteger>(64, cell_count);
    const MTLSize threadsPerThreadgroup = MTLSizeMake(tg, 1, 1);
    const MTLSize threadgroups = MTLSizeMake((cell_count + tg - 1) / tg, 1, 1);
    [enc dispatchThreadgroups:threadgroups
        threadsPerThreadgroup:threadsPerThreadgroup];
    [enc endEncoding];
    [cmd commit];
    _lastBuffer = cmd;
}

- (void)dispatchCommitGeneric:(const macvoxel::CommitGenericParams&)p
                        target:(VolumeTexture*)texture {
    CommitGenericUniforms u{};
    u.dispatch_lo[0] = p.dispatch_lo_x;
    u.dispatch_lo[1] = p.dispatch_lo_y;
    u.dispatch_lo[2] = p.dispatch_lo_z;
    u.dispatch_size[0] = p.dispatch_size_x;
    u.dispatch_size[1] = p.dispatch_size_y;
    u.dispatch_size[2] = p.dispatch_size_z;
    u.bm = p.bm;
    u.brush = p.brush;
    u.fill_palette = p.fill_palette;

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"CommitGeneric";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_commitGenericPSO];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setTexture:texture.texture atIndex:0];
    [enc setTexture:texture.previewTexture atIndex:1];
    [enc setTexture:texture.oracleTexture atIndex:2];

    const NSUInteger tgX = 4, tgY = 4, tgZ = 4;
    const MTLSize threadsPerThreadgroup = MTLSizeMake(tgX, tgY, tgZ);
    const MTLSize threadgroups = MTLSizeMake(
        ((NSUInteger)p.dispatch_size_x + tgX - 1) / tgX,
        ((NSUInteger)p.dispatch_size_y + tgY - 1) / tgY,
        ((NSUInteger)p.dispatch_size_z + tgZ - 1) / tgZ);
    [enc dispatchThreadgroups:threadgroups
        threadsPerThreadgroup:threadsPerThreadgroup];
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
