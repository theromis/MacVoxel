#import "GeneratorEngine.h"

#import <cstdio>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace gen = macvoxel::generators;

namespace {

// MSL source for every generator kernel lives in src/Generators.metal,
// shipped in the app bundle's Resources directory. Loaded as a string at
// engine init via newLibraryWithSource: — same runtime-compile path the
// eventual user-authored shader generator will use, just with the
// built-in source coming from the bundle. Read the .metal file for the
// kernel-output protocol and the Uniforms layout.
NSString* LoadGeneratorLibrarySource() {
    NSURL* url = [NSBundle.mainBundle URLForResource:@"Generators"
                                       withExtension:@"metal"];
    if (url == nil) {
        fprintf(stderr,
                "MacVoxel: Generators.metal missing from bundle Resources\n");
        return nil;
    }
    NSError* error = nil;
    NSString* source = [NSString stringWithContentsOfURL:url
                                                encoding:NSUTF8StringEncoding
                                                   error:&error];
    if (source == nil) {
        fprintf(stderr,
                "MacVoxel: failed to read Generators.metal: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    return source;
}

NSString* KernelNameForKind(gen::Kind k) {
    switch (k) {
        case gen::Kind::Ellipsoid: return @"generate_ellipsoid";
        case gen::Kind::Cylinder:  return @"generate_cylinder";
        case gen::Kind::Cone:      return @"generate_cone";
        case gen::Kind::Pyramid:   return @"generate_pyramid";
        case gen::Kind::Perlin:    return @"generate_perlin";
        case gen::Kind::Torus:     return @"generate_torus";
        case gen::Kind::Count_:    return nil;
    }
    return nil;
}

struct Uniforms {
    int32_t lo[4];        // x0, y0, z0, pad
    int32_t dims[4];      // dx, dy, dz, pad
    uint32_t palette_idx;
    uint32_t axis;
    uint32_t apex_at_max;
    uint32_t pad;
    float noise_scale;
    float noise_threshold;
    uint32_t noise_octaves;
    uint32_t noise_seed;
    float torus_tube;
};
static_assert(sizeof(Uniforms) == 68, "Uniforms layout mismatch");

}  // namespace

@implementation GeneratorEngine {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _pipelines[static_cast<size_t>(gen::Kind::Count_)];
    // Grow-only output buffer; doubles when a request needs more cells
    // than the current capacity.
    id<MTLBuffer> _outBuffer;
    NSUInteger _outCapacityCells;
    // Single-uint atomic counter, shared storage so the host can zero
    // it before each dispatch and read the count back without a blit.
    id<MTLBuffer> _counterBuffer;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   commandQueue:(id<MTLCommandQueue>)queue {
    self = [super init];
    if (self == nil) return nil;
    _device = device;
    _queue = queue;

    NSString* source = LoadGeneratorLibrarySource();
    if (source == nil) return nil;
    NSError* error = nil;
    id<MTLLibrary> library =
        [_device newLibraryWithSource:source
                              options:nil
                                error:&error];
    if (library == nil) {
        fprintf(stderr,
                "MacVoxel: failed to compile generator kernels: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }

    for (size_t i = 0; i < static_cast<size_t>(gen::Kind::Count_); ++i) {
        NSString* name = KernelNameForKind(static_cast<gen::Kind>(i));
        id<MTLFunction> fn = [library newFunctionWithName:name];
        if (fn == nil) {
            fprintf(stderr,
                    "MacVoxel: missing generator kernel '%s'\n",
                    [name UTF8String]);
            return nil;
        }
        _pipelines[i] = [_device newComputePipelineStateWithFunction:fn
                                                                error:&error];
        if (_pipelines[i] == nil) {
            fprintf(stderr,
                    "MacVoxel: failed to build pipeline '%s': %s\n",
                    [name UTF8String],
                    [[error localizedDescription] UTF8String]);
            return nil;
        }
    }

    _counterBuffer =
        [_device newBufferWithLength:sizeof(uint32_t)
                              options:MTLResourceStorageModeShared];
    _counterBuffer.label = @"GeneratorCounter";
    return self;
}

- (void)ensureOutCapacity:(NSUInteger)cells {
    if (_outCapacityCells >= cells && _outBuffer != nil) return;
    // Double-when-needed growth so a drag through bigger and bigger
    // bounds doesn't realloc every frame: start from twice the current
    // capacity (or a 4096-cell floor for first allocation), then keep
    // doubling until it covers the request.
    NSUInteger newCap = std::max<NSUInteger>(_outCapacityCells * 2, 4096);
    while (newCap < cells) newCap *= 2;
    _outBuffer = [_device newBufferWithLength:newCap * 12  // PackedCell = 3×int32
                                       options:MTLResourceStorageModeShared];
    _outBuffer.label = @"GeneratorOutput";
    _outCapacityCells = newCap;
}

- (void)generateInto:(std::vector<macvoxel::shapes::Vec3i>&)out
                kind:(gen::Kind)kind
              bounds:(gen::Bounds3i)bounds
              params:(const gen::Params&)params {
    out.clear();
    const NSUInteger ki = static_cast<NSUInteger>(kind);
    if (ki >= static_cast<NSUInteger>(gen::Kind::Count_)) return;
    id<MTLComputePipelineState> pso = _pipelines[ki];
    if (pso == nil) return;

    const int32_t dx = bounds.x1 - bounds.x0 + 1;
    const int32_t dy = bounds.y1 - bounds.y0 + 1;
    const int32_t dz = bounds.z1 - bounds.z0 + 1;
    if (dx <= 0 || dy <= 0 || dz <= 0) return;
    const NSUInteger volume =
        static_cast<NSUInteger>(dx) *
        static_cast<NSUInteger>(dy) *
        static_cast<NSUInteger>(dz);
    [self ensureOutCapacity:volume];

    // Zero the atomic counter via shared-storage CPU write — no blit
    // needed on Apple Silicon's unified memory. The kernel reads/writes
    // it via atomic_fetch_add, so the value visible at dispatch time is
    // 0 and the value visible after waitUntilCompleted is the count.
    *static_cast<uint32_t*>(_counterBuffer.contents) = 0u;

    Uniforms u{};
    u.lo[0] = bounds.x0;
    u.lo[1] = bounds.y0;
    u.lo[2] = bounds.z0;
    u.dims[0] = dx;
    u.dims[1] = dy;
    u.dims[2] = dz;
    u.palette_idx = params.palette_idx;
    u.axis = params.axis;
    u.apex_at_max = params.apex_at_max;
    u.noise_scale = params.noise_scale;
    u.noise_threshold = params.noise_threshold;
    u.noise_octaves = params.noise_octaves;
    u.noise_seed = params.noise_seed;
    u.torus_tube = params.torus_tube;

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    cmd.label = @"GeneratorDispatch";
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:pso];
    [enc setBytes:&u length:sizeof(u) atIndex:0];
    [enc setBuffer:_counterBuffer offset:0 atIndex:1];
    [enc setBuffer:_outBuffer offset:0 atIndex:2];

    const NSUInteger tgX = std::min<NSUInteger>(8, static_cast<NSUInteger>(dx));
    const NSUInteger tgY = std::min<NSUInteger>(8, static_cast<NSUInteger>(dy));
    const NSUInteger tgZ = std::min<NSUInteger>(8, static_cast<NSUInteger>(dz));
    const MTLSize threadsPerThreadgroup = MTLSizeMake(tgX, tgY, tgZ);
    const MTLSize threadgroups = MTLSizeMake(
        (static_cast<NSUInteger>(dx) + tgX - 1) / tgX,
        (static_cast<NSUInteger>(dy) + tgY - 1) / tgY,
        (static_cast<NSUInteger>(dz) + tgZ - 1) / tgZ);
    [enc dispatchThreadgroups:threadgroups
        threadsPerThreadgroup:threadsPerThreadgroup];
    [enc endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];

    const uint32_t count = *static_cast<uint32_t*>(_counterBuffer.contents);
    out.resize(count);
    if (count > 0) {
        // PackedCell == { int32, int32, int32 } == 12 bytes, matching
        // shapes::Vec3i. Bulk copy is safe.
        std::memcpy(out.data(), _outBuffer.contents,
                    static_cast<size_t>(count) * 12);
    }
}

@end
