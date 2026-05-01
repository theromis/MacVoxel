#import "PathTraceRenderer.h"

#import <cstdio>
#include <array>
#include <cstdint>
#include <cstring>
#include <vector>

#include "Camera.h"
#include "Document.h"
#include "RenderState.h"

#include <cmath>

namespace {

struct PathUniforms {
    simd::float4x4 inv_vp;
    simd::float3 camera_pos;
    float _pad0;
    simd::int3 coarse_min;
    int _pad1;
    simd::int3 coarse_dim;
    int _pad2;
    simd::float3 sky_color;
    float _pad3;
    uint32_t frame_seed;
    uint32_t max_bounces;
    uint32_t _pad4;
    uint32_t _pad5;
};

struct DisplayUniforms {
    uint32_t sample_count;
    uint32_t _pad0;
    uint32_t _pad1;
    uint32_t _pad2;
};

NSString* const kShaderSource = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct PathUniforms {
    float4x4 inv_vp;
    float3   camera_pos;
    float    _pad0;
    int3     coarse_min;
    int      _pad1;
    int3     coarse_dim;
    int      _pad2;
    float3   sky_color;
    float    _pad3;
    uint     frame_seed;
    uint     max_bounces;
    uint     _pad4;
    uint     _pad5;
};

struct DisplayUniforms {
    uint sample_count;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

struct Chunk { uint8_t cells[4096]; };

struct VertOut {
    float4 position [[position]];
    float2 ndc;
};

vertex VertOut pt_vertex(uint vid [[vertex_id]]) {
    float2 p;
    if (vid == 0)      p = float2(-1.0, -1.0);
    else if (vid == 1) p = float2( 3.0, -1.0);
    else               p = float2(-1.0,  3.0);
    VertOut o;
    o.position = float4(p, 0.0, 1.0);
    o.ndc = p;
    return o;
}

// PCG32 hash — fast, decent quality for stochastic sampling.
uint pcg(thread uint& s) {
    s = s * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
float rand1(thread uint& s) {
    return float(pcg(s)) * (1.0 / 4294967296.0);
}

// Cosine-weighted hemisphere sample about a unit normal.
float3 cosine_hemi(float3 n, thread uint& rng) {
    float r1 = rand1(rng);
    float r2 = rand1(rng);
    float phi = 6.2831853 * r1;
    float r = sqrt(r2);
    float3 local = float3(r * cos(phi), r * sin(phi), sqrt(max(0.0, 1.0 - r2)));
    float3 helper = abs(n.x) > 0.5 ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 t1 = normalize(cross(n, helper));
    float3 t2 = cross(n, t1);
    return local.x * t1 + local.y * t2 + local.z * n;
}

constant int kMaxSteps = 4096;
constant uint kChunkBits = 4;
constant uint kChunkMask = 15u;
constant uint kChunkSize = 16u;

struct DDAHit {
    bool   hit;
    float3 point;     // absolute grid-space coords of the hit
    int    axis;
    int    sign;
    uint   cell_val;
};

DDAHit dda_traverse(float3 ray_origin,
                    float3 ray_dir,
                    constant PathUniforms& u,
                    device const uint* coarse_grid,
                    device const Chunk* chunk_pool)
{
    DDAHit h = {false, float3(0.0), -1, 0, 0u};

    float3 aabb_min = float3(u.coarse_min) * float(kChunkSize);
    float3 aabb_max = float3(u.coarse_min + u.coarse_dim) * float(kChunkSize);
    float3 inv_dir = 1.0 / ray_dir;
    float3 t1 = (aabb_min - ray_origin) * inv_dir;
    float3 t2 = (aabb_max - ray_origin) * inv_dir;
    float3 t_lo = min(t1, t2);
    float3 t_hi = max(t1, t2);
    float t_enter = max(max(t_lo.x, t_lo.y), t_lo.z);
    float t_exit  = min(min(t_hi.x, t_hi.y), t_hi.z);
    if (t_exit < 0.0 || t_enter > t_exit) return h;

    // Track which axis the ray crossed entering the AABB. If the first
    // cell happens to be filled, this becomes the hit's last_axis (so
    // we get a real face normal rather than (0,0,0) → NaN scatter).
    int entry_axis = (t_lo.x >= t_lo.y && t_lo.x >= t_lo.z) ? 0
                   : (t_lo.y >= t_lo.z) ? 1 : 2;

    float t_start = max(t_enter, 0.0);
    float3 origin = ray_origin + ray_dir * (t_start + 1e-3);

    int3 cell = int3(floor(origin));
    int3 step_dir;
    step_dir.x = ray_dir.x > 0.0 ? 1 : (ray_dir.x < 0.0 ? -1 : 0);
    step_dir.y = ray_dir.y > 0.0 ? 1 : (ray_dir.y < 0.0 ? -1 : 0);
    step_dir.z = ray_dir.z > 0.0 ? 1 : (ray_dir.z < 0.0 ? -1 : 0);

    float3 t_max;
    t_max.x = step_dir.x == 0 ? INFINITY :
              (step_dir.x > 0 ? (float(cell.x + 1) - origin.x) / ray_dir.x
                              : (origin.x - float(cell.x))     / -ray_dir.x);
    t_max.y = step_dir.y == 0 ? INFINITY :
              (step_dir.y > 0 ? (float(cell.y + 1) - origin.y) / ray_dir.y
                              : (origin.y - float(cell.y))     / -ray_dir.y);
    t_max.z = step_dir.z == 0 ? INFINITY :
              (step_dir.z > 0 ? (float(cell.z + 1) - origin.z) / ray_dir.z
                              : (origin.z - float(cell.z))     / -ray_dir.z);

    float3 t_delta;
    t_delta.x = step_dir.x != 0 ? 1.0 / abs(ray_dir.x) : INFINITY;
    t_delta.y = step_dir.y != 0 ? 1.0 / abs(ray_dir.y) : INFINITY;
    t_delta.z = step_dir.z != 0 ? 1.0 / abs(ray_dir.z) : INFINITY;

    int last_axis = entry_axis;
    float t_hit = t_start;

    for (int s = 0; s < kMaxSteps; ++s) {
        int3 chunk_c;
        chunk_c.x = cell.x >> int(kChunkBits);
        chunk_c.y = cell.y >> int(kChunkBits);
        chunk_c.z = cell.z >> int(kChunkBits);
        int3 cgc = chunk_c - u.coarse_min;
        if (cgc.x < 0 || cgc.y < 0 || cgc.z < 0 ||
            cgc.x >= u.coarse_dim.x || cgc.y >= u.coarse_dim.y ||
            cgc.z >= u.coarse_dim.z) {
            return h;
        }
        uint coarse_idx = uint(cgc.x) +
                          uint(cgc.y) * uint(u.coarse_dim.x) +
                          uint(cgc.z) * uint(u.coarse_dim.x) * uint(u.coarse_dim.y);
        uint pool_idx = coarse_grid[coarse_idx];

        if (pool_idx == 0u) {
            // Empty-chunk skip via slab.
            float3 chunk_min = float3(chunk_c) * float(kChunkSize);
            float3 chunk_max = chunk_min + float(kChunkSize);
            float3 exit_face = select(chunk_min, chunk_max, step_dir > 0);
            float3 t_face = (exit_face - ray_origin) * inv_dir;
            if (step_dir.x == 0) t_face.x = INFINITY;
            if (step_dir.y == 0) t_face.y = INFINITY;
            if (step_dir.z == 0) t_face.z = INFINITY;
            float t_chunk_exit = min(min(t_face.x, t_face.y), t_face.z);
            int exit_axis = (t_face.x <= t_face.y && t_face.x <= t_face.z) ? 0
                          : (t_face.y <= t_face.z) ? 1 : 2;
            last_axis = exit_axis;
            float eps = max(1e-3, t_chunk_exit * 1e-5);
            float3 pos = ray_origin + ray_dir * (t_chunk_exit + eps);
            cell.x = int(floor(pos.x));
            cell.y = int(floor(pos.y));
            cell.z = int(floor(pos.z));
            if (exit_axis == 0) {
                cell.x = step_dir.x > 0 ? (chunk_c.x + 1) * int(kChunkSize)
                                        : chunk_c.x * int(kChunkSize) - 1;
            } else if (exit_axis == 1) {
                cell.y = step_dir.y > 0 ? (chunk_c.y + 1) * int(kChunkSize)
                                        : chunk_c.y * int(kChunkSize) - 1;
            } else {
                cell.z = step_dir.z > 0 ? (chunk_c.z + 1) * int(kChunkSize)
                                        : chunk_c.z * int(kChunkSize) - 1;
            }
            t_max.x = step_dir.x == 0 ? INFINITY :
                      (step_dir.x > 0
                           ? (float(cell.x + 1) - ray_origin.x) / ray_dir.x
                           : (ray_origin.x - float(cell.x))     / -ray_dir.x);
            t_max.y = step_dir.y == 0 ? INFINITY :
                      (step_dir.y > 0
                           ? (float(cell.y + 1) - ray_origin.y) / ray_dir.y
                           : (ray_origin.y - float(cell.y))     / -ray_dir.y);
            t_max.z = step_dir.z == 0 ? INFINITY :
                      (step_dir.z > 0
                           ? (float(cell.z + 1) - ray_origin.z) / ray_dir.z
                           : (ray_origin.z - float(cell.z))     / -ray_dir.z);
            t_hit = t_chunk_exit;
            continue;
        }

        uint lx = uint(cell.x) & kChunkMask;
        uint ly = uint(cell.y) & kChunkMask;
        uint lz = uint(cell.z) & kChunkMask;
        uint local_idx = lx + ly * kChunkSize + lz * kChunkSize * kChunkSize;
        uint cell_val = uint(chunk_pool[pool_idx - 1u].cells[local_idx]);
        if (cell_val != 0u) {
            h.hit = true;
            // t_hit is parametric distance from the *clipped* origin. We
            // compute the hit point against that origin directly so the
            // caller never has to worry about which origin to use.
            h.point = origin + ray_dir * t_hit;
            h.axis = last_axis;
            int step = (last_axis == 0) ? step_dir.x
                     : (last_axis == 1) ? step_dir.y : step_dir.z;
            h.sign = -step;
            h.cell_val = cell_val;
            return h;
        }

        if (t_max.x < t_max.y && t_max.x < t_max.z) {
            cell.x += step_dir.x;
            t_hit = t_max.x;
            t_max.x += t_delta.x;
            last_axis = 0;
        } else if (t_max.y < t_max.z) {
            cell.y += step_dir.y;
            t_hit = t_max.y;
            t_max.y += t_delta.y;
            last_axis = 1;
        } else {
            cell.z += step_dir.z;
            t_hit = t_max.z;
            t_max.z += t_delta.z;
            last_axis = 2;
        }
    }
    return h;
}

fragment float4 pt_fragment(
    VertOut in [[stage_in]],
    constant PathUniforms& u [[buffer(0)]],
    device const uint* coarse_grid [[buffer(1)]],
    device const Chunk* chunk_pool [[buffer(2)]],
    constant float4* palette [[buffer(3)]])
{
    uint2 pix = uint2(in.position.xy);
    uint rng = (pix.x * 1973u) ^ (pix.y * 9277u) ^ (u.frame_seed * 26699u);
    pcg(rng); pcg(rng);  // mix the seed

    // Reconstruct primary world ray from NDC (no jitter for this commit;
    // accumulation alone won't antialias, P8.2 will add it).
    float4 near_clip = float4(in.ndc, 0.0, 1.0);
    float4 far_clip  = float4(in.ndc, 1.0, 1.0);
    float4 nh = u.inv_vp * near_clip;
    float4 fh = u.inv_vp * far_clip;
    float3 nw = nh.xyz / nh.w;
    float3 fw = fh.xyz / fh.w;
    float3 ray_dir_world = normalize(fw - nw);
    float3 ray_origin_world = u.camera_pos;

    // World -> grid (same rotation the raster path uses).
    float3 ray_origin = float3(ray_origin_world.x,
                               -ray_origin_world.z,
                               ray_origin_world.y);
    float3 ray_dir   = float3(ray_dir_world.x,
                               -ray_dir_world.z,
                               ray_dir_world.y);

    float3 throughput = float3(1.0);
    float3 radiance   = float3(0.0);

    for (uint b = 0u; b <= u.max_bounces; ++b) {
        DDAHit h = dda_traverse(ray_origin, ray_dir, u, coarse_grid, chunk_pool);
        if (!h.hit) {
            radiance += throughput * u.sky_color;
            break;
        }
        float3 albedo = palette[h.cell_val].rgb;
        if (b == u.max_bounces) {
            // Last bounce: no further rays — sample sky directly via
            // facing the surface (cheap approximation: assume some sky
            // contribution proportional to albedo, or terminate). For
            // P8.1 we just terminate (treat surface as black) so the
            // single-bounce case shows direct diffuse only.
            break;
        }

        // Surface normal in grid space.
        float3 normal = float3(0.0);
        if      (h.axis == 0) normal.x = float(h.sign);
        else if (h.axis == 1) normal.y = float(h.sign);
        else if (h.axis == 2) normal.z = float(h.sign);

        ray_origin = h.point + normal * 1e-3;
        ray_dir = cosine_hemi(normal, rng);
        throughput *= albedo;
    }
    return float4(radiance, 1.0);
}

fragment float4 display_fragment(
    VertOut in [[stage_in]],
    constant DisplayUniforms& u [[buffer(0)]],
    texture2d<float, access::sample> accum [[texture(0)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    float2 uv = in.ndc * 0.5 + 0.5;
    uv.y = 1.0 - uv.y;
    float4 v = accum.sample(s, uv);
    float n = max(1.0, float(u.sample_count));
    float3 c = v.rgb / n;
    // Simple gamma-ish tone (renderer is linear; display assumes sRGB-ish).
    c = pow(max(c, 0.0), 1.0 / 2.2);
    return float4(c, 1.0);
}
)MSL";

}  // namespace

@implementation PathTraceRenderer {
    id<MTLDevice> _device;
    MTLPixelFormat _colorFormat;
    id<MTLRenderPipelineState> _pathPipeline;
    id<MTLRenderPipelineState> _displayPipeline;
    id<MTLTexture> _accumTexture;
    CGSize _accumSize;

    id<MTLBuffer> _coarseBuffer;
    id<MTLBuffer> _poolBuffer;
    id<MTLBuffer> _paletteBuffer;
    uint64_t _cachedDocVersion;
    BOOL _resourcesValid;
    simd::int3 _coarseMin;
    simd::int3 _coarseDim;

    // Accumulation state.
    uint32_t _sampleCount;
    BOOL _wantsClear;

    // Camera-state hash for reset detection.
    uint64_t _lastCameraHash;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat {
    self = [super init];
    if (self == nil) return nil;
    _device = device;
    _colorFormat = colorFormat;
    _wantsClear = YES;

    NSError* error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:kShaderSource
                                                   options:nil
                                                     error:&error];
    if (library == nil) {
        fprintf(stderr, "MacVoxel: failed to compile path-trace shaders: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    id<MTLFunction> vfn = [library newFunctionWithName:@"pt_vertex"];
    id<MTLFunction> ptffn = [library newFunctionWithName:@"pt_fragment"];
    id<MTLFunction> dispffn = [library newFunctionWithName:@"display_fragment"];

    // Accumulation pipeline: writes float4 RGBA, additive blend (One/One)
    // so each frame's contribution adds into the accum texture.
    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.label = @"PathTraceAccum";
        d.vertexFunction = vfn;
        d.fragmentFunction = ptffn;
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        d.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
        _pathPipeline = [_device newRenderPipelineStateWithDescriptor:d error:&error];
        if (_pathPipeline == nil) {
            fprintf(stderr, "MacVoxel: failed to build path-trace pipeline: %s\n",
                    [[error localizedDescription] UTF8String]);
            return nil;
        }
    }

    // Display pipeline: samples the accum texture, divides by sample
    // count, writes to MTKView's drawable.
    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.label = @"PathTraceDisplay";
        d.vertexFunction = vfn;
        d.fragmentFunction = dispffn;
        d.colorAttachments[0].pixelFormat = colorFormat;
        _displayPipeline = [_device newRenderPipelineStateWithDescriptor:d error:&error];
        if (_displayPipeline == nil) {
            fprintf(stderr, "MacVoxel: failed to build display pipeline: %s\n",
                    [[error localizedDescription] UTF8String]);
            return nil;
        }
    }

    return self;
}

- (uint32_t)sampleCount { return _sampleCount; }
- (void)invalidate { _wantsClear = YES; }

// ---------------------------------------------------------------------------
// Voxel data upload — wholesale on doc->version change. Same coarse-grid /
// chunk-pool layout the raster path uses; we just don't bother with the
// raster path's incremental updates here (path tracing is for stationary
// "render mode" use, not interactive editing).
// ---------------------------------------------------------------------------

- (void)rebuildResourcesFromDocument:(macvoxel::Document*)doc {
    using VG = macvoxel::VoxelGrid;
    const auto& chunks = doc->grid.chunks();

    if (chunks.empty()) {
        _coarseMin = simd::int3{0, 0, 0};
        _coarseDim = simd::int3{0, 0, 0};
        _coarseBuffer = nil;
        _poolBuffer = nil;
    } else {
        int32_t min_cx = INT32_MAX, min_cy = INT32_MAX, min_cz = INT32_MAX;
        int32_t max_cx = INT32_MIN, max_cy = INT32_MIN, max_cz = INT32_MIN;
        for (const auto& [coord, chunk] : chunks) {
            min_cx = std::min(min_cx, coord.x);
            min_cy = std::min(min_cy, coord.y);
            min_cz = std::min(min_cz, coord.z);
            max_cx = std::max(max_cx, coord.x);
            max_cy = std::max(max_cy, coord.y);
            max_cz = std::max(max_cz, coord.z);
        }
        _coarseMin = simd::int3{min_cx, min_cy, min_cz};
        _coarseDim = simd::int3{max_cx - min_cx + 1,
                                max_cy - min_cy + 1,
                                max_cz - min_cz + 1};

        const size_t coarse_count =
            static_cast<size_t>(_coarseDim.x) *
            static_cast<size_t>(_coarseDim.y) *
            static_cast<size_t>(_coarseDim.z);
        std::vector<uint32_t> coarse(coarse_count, 0);
        std::vector<uint8_t> pool;
        pool.reserve(chunks.size() * VG::kChunkVolume);
        uint32_t pool_idx = 1;
        for (const auto& [coord, chunk] : chunks) {
            const size_t cgi =
                static_cast<size_t>(coord.x - min_cx) +
                static_cast<size_t>(coord.y - min_cy) *
                    static_cast<size_t>(_coarseDim.x) +
                static_cast<size_t>(coord.z - min_cz) *
                    static_cast<size_t>(_coarseDim.x) *
                    static_cast<size_t>(_coarseDim.y);
            coarse[cgi] = pool_idx++;
            const size_t old = pool.size();
            pool.resize(old + VG::kChunkVolume);
            std::memcpy(pool.data() + old, chunk->cells, VG::kChunkVolume);
        }
        _coarseBuffer = [_device newBufferWithBytes:coarse.data()
                                             length:coarse.size() * sizeof(uint32_t)
                                            options:MTLResourceStorageModeShared];
        _coarseBuffer.label = @"PTCoarse";
        _poolBuffer = [_device newBufferWithBytes:pool.data()
                                           length:pool.size()
                                          options:MTLResourceStorageModeShared];
        _poolBuffer.label = @"PTChunkPool";
    }

    // Path tracer wants linear-space color for physically-meaningful
    // multiplication. Palette comes in sRGB-ish (the standard storage for
    // 8-bit RGBA), so decode with the gamma-2.2 approximation here. The
    // display fragment re-encodes linear -> sRGB at output time.
    std::array<simd::float4, 256> pal_floats{};
    for (size_t i = 0; i < 256; ++i) {
        const macvoxel::Color c = doc->palette.Get(static_cast<uint8_t>(i));
        const float r = c.r / 255.0f;
        const float g = c.g / 255.0f;
        const float b = c.b / 255.0f;
        pal_floats[i] = simd::float4{
            std::pow(r, 2.2f),
            std::pow(g, 2.2f),
            std::pow(b, 2.2f),
            c.a / 255.0f,
        };
    }
    _paletteBuffer = [_device newBufferWithBytes:pal_floats.data()
                                          length:sizeof(pal_floats)
                                         options:MTLResourceStorageModeShared];
    _paletteBuffer.label = @"PTPalette";

    _cachedDocVersion = doc->version;
    _resourcesValid = YES;
}

- (void)ensureAccumTextureForSize:(CGSize)size {
    if (_accumTexture != nil &&
        _accumSize.width == size.width &&
        _accumSize.height == size.height) {
        return;
    }
    MTLTextureDescriptor* td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                           width:static_cast<NSUInteger>(size.width)
                                                          height:static_cast<NSUInteger>(size.height)
                                                       mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    _accumTexture = [_device newTextureWithDescriptor:td];
    _accumTexture.label = @"PTAccum";
    _accumSize = size;
    _wantsClear = YES;
}

// FNV-1a over the camera state — cheap fingerprint for change detection.
- (uint64_t)hashCameraState:(const macvoxel::Camera&)camera {
    uint64_t h = 0xcbf29ce484222325ULL;
    auto mix = [&](float v) {
        uint32_t bits;
        std::memcpy(&bits, &v, 4);
        h ^= bits;
        h *= 0x100000001b3ULL;
    };
    mix(camera.target.x);
    mix(camera.target.y);
    mix(camera.target.z);
    mix(camera.distance);
    mix(camera.yaw);
    mix(camera.pitch);
    mix(camera.fov_y);
    return h;
}

- (void)renderInView:(MTKView*)view
                 cmd:(id<MTLCommandBuffer>)cmd
            document:(macvoxel::Document*)doc
              camera:(const macvoxel::Camera&)camera {
    if (doc == nullptr) return;
    const CGSize size = view.drawableSize;
    if (size.width <= 0.0 || size.height <= 0.0) return;

    [self ensureAccumTextureForSize:size];
    if (!_resourcesValid || _cachedDocVersion != doc->version) {
        [self rebuildResourcesFromDocument:doc];
        _wantsClear = YES;
    }
    const uint64_t cam_hash = [self hashCameraState:camera];
    if (cam_hash != _lastCameraHash) {
        _lastCameraHash = cam_hash;
        _wantsClear = YES;
    }

    if (_wantsClear) {
        _sampleCount = 0;
        _wantsClear = NO;
    }

    if (_coarseBuffer == nil || _poolBuffer == nil || _paletteBuffer == nil) {
        // Nothing to trace; let the display pass clear to background.
        return;
    }

    // ---------- Pass 1: accumulate one new sample into accum texture ----------
    {
        MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = _accumTexture;
        rpd.colorAttachments[0].loadAction =
            (_sampleCount == 0) ? MTLLoadActionClear : MTLLoadActionLoad;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> enc =
            [cmd renderCommandEncoderWithDescriptor:rpd];
        enc.label = @"PathTraceAccumulate";

        const float aspect = static_cast<float>(size.width / size.height);
        const simd::float4x4 vmat = camera.ViewMatrix();
        const simd::float4x4 pmat = camera.ProjectionMatrix(aspect);
        const simd::float4x4 inv_vp = simd_inverse(pmat * vmat);

        PathUniforms u;
        u.inv_vp = inv_vp;
        u.camera_pos = camera.Position();
        u._pad0 = 0.0f;
        u.coarse_min = _coarseMin;
        u._pad1 = 0;
        u.coarse_dim = _coarseDim;
        u._pad2 = 0;
        u.sky_color = simd::float3{0.65f, 0.75f, 0.95f};
        u._pad3 = 0.0f;
        u.frame_seed = _sampleCount + 1u;  // distinct each accumulated sample
        u.max_bounces = static_cast<uint32_t>(
            macvoxel::CurrentRenderState().max_bounces);
        u._pad4 = u._pad5 = 0u;

        [enc setRenderPipelineState:_pathPipeline];
        [enc setCullMode:MTLCullModeNone];
        [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
        [enc setFragmentBuffer:_coarseBuffer offset:0 atIndex:1];
        [enc setFragmentBuffer:_poolBuffer offset:0 atIndex:2];
        [enc setFragmentBuffer:_paletteBuffer offset:0 atIndex:3];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        ++_sampleCount;
    }

    // ---------- Pass 2: divide accum by sample count, write to drawable ----
    {
        MTLRenderPassDescriptor* rpd = view.currentRenderPassDescriptor;
        if (rpd == nil) return;
        id<MTLRenderCommandEncoder> enc =
            [cmd renderCommandEncoderWithDescriptor:rpd];
        enc.label = @"PathTraceDisplay";

        DisplayUniforms du;
        du.sample_count = _sampleCount;
        du._pad0 = du._pad1 = du._pad2 = 0u;

        [enc setRenderPipelineState:_displayPipeline];
        [enc setCullMode:MTLCullModeNone];
        [enc setFragmentBytes:&du length:sizeof(du) atIndex:0];
        [enc setFragmentTexture:_accumTexture atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }

    macvoxel::CurrentRenderState().sample_count = _sampleCount;
}

@end
