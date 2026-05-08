#import "PathTraceRenderer.h"

#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import <cstdio>
#include <array>
#include <cstdint>
#include <cstring>
#include <vector>

#include "Camera.h"
#include "Document.h"
#include "Material.h"
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
    uint32_t light_count;
    uint32_t glass_mode;  // 0 = Probabilistic, 1 = Absorption
    uint32_t power_weighted_nee;  // 0 = uniform NEE, 1 = power CDF
    uint32_t _pad4;
    uint32_t _pad5;
    uint32_t _pad6;
};
// CPU and MSL `constant` PathUniforms must agree byte-for-byte, since
// we setBytes:length:sizeof(PathUniforms). The simd float3/int3 types
// are 16-byte slots on both sides (3-of-4 used) so the explicit `_padN`
// scalars get an additional 12-byte auto-pad in front of every
// 16-aligned successor — which is why this struct is 224 bytes, not
// the naïve 64+16+16+16+16+4*8 = 160.
static_assert(sizeof(PathUniforms) == 224, "PathUniforms size mismatch");

// Per-emissive-voxel entry in the next-event-estimation light buffer.
// Built CPU-side at doc.version change so the shader doesn't have to
// scan the grid; `le` is the linear-space color × effective emission so
// the shader needs no palette/material lookup at sample time.
struct GpuLight {
    simd::float4 pos;  // .xyz = grid-space corner of the voxel.
                       // .w   = cumulative normalized sampling weight (CDF).
                       //       Last light's .w is 1.0; binary search picks
                       //       `li` such that cdf[li-1] < u <= cdf[li].
    simd::float4 le;   // .xyz = albedo_linear * effective_emission.
                       // .w   = per-light sampling probability (prob[li] =
                       //       cdf[li] - cdf[li-1]). Pre-baked so the
                       //       BSDF-arrives-at-emitter MIS branch reads it
                       //       directly without re-doing the subtract.
};
static_assert(sizeof(GpuLight) == 32, "GpuLight size mismatch");

// Per-palette-entry material data uploaded to the path-tracer's
// fragment shader. Mirrors macvoxel::Material but lives in a tightly
// packed format for the GPU.
struct GpuMaterial {
    float type;          // 0=Diffuse, 1=Metal, 2=Emissive, 3=Glass
    float roughness;
    float metallic;
    float emission;
    float transparency;
    float ior;
    float _pad0;
    float _pad1;
};
static_assert(sizeof(GpuMaterial) == 32, "GpuMaterial size mismatch");

struct DisplayUniforms {
    uint32_t sample_count;
    uint32_t aces_tonemap;
    // Fractions of the drawable that the rendered image occupies after
    // aspect-preserving fit-to-window. Both 1.0 means stretch (or
    // identity, when accum size matches drawable size).
    float region_w;
    float region_h;
};

// MSL source for both pt_fragment (the path-trace pass) and
// display_fragment (tonemap + sRGB encode) lives in src/PathTrace.metal,
// shipped in the app bundle's Resources directory and loaded as a string
// at init via newLibraryWithSource:.

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
    id<MTLBuffer> _materialBuffer;
    id<MTLBuffer> _lightBuffer;
    uint32_t _lightCount;
    uint64_t _cachedDocVersion;
    BOOL _resourcesValid;
    simd::int3 _coarseMin;
    simd::int3 _coarseDim;

    // Accumulation state.
    uint32_t _sampleCount;
    BOOL _wantsClear;

    // Camera-state hash for reset detection.
    uint64_t _lastCameraHash;
    // Glass interpretation last seen — toggling forces an accumulator
    // reset since the two modes produce visually different estimators.
    macvoxel::GlassMode _lastGlassMode;
    bool _lastPowerWeightedNee;
    float _lastSkyIntensity;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat {
    self = [super init];
    if (self == nil) return nil;
    _device = device;
    _colorFormat = colorFormat;
    _wantsClear = YES;

    NSURL* source_url =
        [NSBundle.mainBundle URLForResource:@"PathTrace"
                              withExtension:@"metal"];
    if (source_url == nil) {
        fprintf(stderr,
                "MacVoxel: PathTrace.metal missing from bundle Resources\n");
        return nil;
    }
    NSError* error = nil;
    NSString* source = [NSString stringWithContentsOfURL:source_url
                                                encoding:NSUTF8StringEncoding
                                                   error:&error];
    if (source == nil) {
        fprintf(stderr,
                "MacVoxel: failed to read PathTrace.metal: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    id<MTLLibrary> library = [_device newLibraryWithSource:source
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

    // Material buffer parallel to palette; one entry per palette index.
    std::array<GpuMaterial, 256> mats{};
    for (size_t i = 0; i < 256; ++i) {
        const macvoxel::Material m = doc->palette.GetMaterial(static_cast<uint8_t>(i));
        mats[i].type = static_cast<float>(static_cast<int>(m.type));
        mats[i].roughness = m.roughness;
        mats[i].metallic = m.metallic;
        mats[i].emission = macvoxel::EffectiveEmission(m);
        mats[i].transparency = m.transparency;
        mats[i].ior = m.ior;
        mats[i]._pad0 = 0.0f;
        mats[i]._pad1 = 0.0f;
    }
    _materialBuffer = [_device newBufferWithBytes:mats.data()
                                           length:sizeof(mats)
                                          options:MTLResourceStorageModeShared];
    _materialBuffer.label = @"PTMaterials";

    // Next-event estimation light list. One entry per emissive voxel
    // (with effective_emission > 0). Stored as { grid corner, linear
    // albedo × emission } so the shader can sample without a palette
    // lookup. We keep the buffer non-nil even when empty (Metal needs a
    // buffer bound at index 5) and gate use via _lightCount.
    std::vector<GpuLight> lights;
    lights.reserve(64);
    for (const auto& [coord, chunk] : chunks) {
        if (chunk->filled_count == 0) continue;
        const int32_t base_x = coord.x * static_cast<int32_t>(VG::kChunkSize);
        const int32_t base_y = coord.y * static_cast<int32_t>(VG::kChunkSize);
        const int32_t base_z = coord.z * static_cast<int32_t>(VG::kChunkSize);
        for (uint32_t lz = 0; lz < VG::kChunkSize; ++lz) {
            for (uint32_t ly = 0; ly < VG::kChunkSize; ++ly) {
                for (uint32_t lx = 0; lx < VG::kChunkSize; ++lx) {
                    const size_t li = lx + ly * VG::kChunkSize +
                                      lz * VG::kChunkSize * VG::kChunkSize;
                    const uint8_t v = chunk->cells[li];
                    if (v == 0) continue;
                    const macvoxel::Material m =
                        doc->palette.GetMaterial(v);
                    if (m.type != macvoxel::MaterialType::Emissive) continue;
                    const float eff = macvoxel::EffectiveEmission(m);
                    if (eff <= 0.0f) continue;
                    const macvoxel::Color c = doc->palette.Get(v);
                    GpuLight L;
                    L.pos = simd::float4{
                        static_cast<float>(base_x + static_cast<int32_t>(lx)),
                        static_cast<float>(base_y + static_cast<int32_t>(ly)),
                        static_cast<float>(base_z + static_cast<int32_t>(lz)),
                        0.0f,
                    };
                    L.le = simd::float4{
                        std::pow(c.r / 255.0f, 2.2f) * eff,
                        std::pow(c.g / 255.0f, 2.2f) * eff,
                        std::pow(c.b / 255.0f, 2.2f) * eff,
                        0.0f,
                    };
                    lights.push_back(L);
                }
            }
        }
    }
    _lightCount = static_cast<uint32_t>(lights.size());

    // Power-weighted importance sampling for NEE. Per-light weight =
    // max channel of `le` (a perceptually-reasonable proxy for power
    // when all light surfaces have the same area, which they do here:
    // 3 visible faces × 1 unit² each per voxel). Normalized into a CDF
    // in pos.w and per-light prob in le.w. Falls back to uniform when
    // the total weight is zero (shouldn't happen — we only added cells
    // with eff > 0 — but harmless guard).
    if (_lightCount > 0) {
        double total = 0.0;
        std::vector<float> weights(_lightCount, 0.0f);
        for (uint32_t i = 0; i < _lightCount; ++i) {
            const float w = std::max({lights[i].le.x,
                                      lights[i].le.y,
                                      lights[i].le.z});
            weights[i] = w;
            total += w;
        }
        if (total <= 0.0) {
            const float uniform = 1.0f / static_cast<float>(_lightCount);
            for (uint32_t i = 0; i < _lightCount; ++i) {
                weights[i] = 1.0f;
                lights[i].le.w = uniform;
                lights[i].pos.w = uniform * static_cast<float>(i + 1);
            }
        } else {
            const double inv_total = 1.0 / total;
            double running = 0.0;
            for (uint32_t i = 0; i < _lightCount; ++i) {
                const double prob = weights[i] * inv_total;
                running += prob;
                lights[i].le.w = static_cast<float>(prob);
                lights[i].pos.w = static_cast<float>(running);
            }
            // Guard against fp accumulation drift past 1.0 in the
            // last entry — binary-searching for u ∈ [0, 1] with a
            // CDF that ends at 0.99999... would miss the last light.
            lights[_lightCount - 1].pos.w = 1.0f;
        }
    } else {
        // One zero-init entry so the shader has a valid binding even
        // when no emissives exist; light_count == 0 keeps it unread.
        lights.resize(1);
    }
    _lightBuffer = [_device newBufferWithBytes:lights.data()
                                        length:lights.size() * sizeof(GpuLight)
                                       options:MTLResourceStorageModeShared];
    _lightBuffer.label = @"PTLights";

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
    const CGSize drawable = view.drawableSize;
    if (drawable.width <= 0.0 || drawable.height <= 0.0) return;

    const macvoxel::RenderState& rs = macvoxel::CurrentRenderState();
    CGSize size = drawable;
    if (!rs.resolution_match_window) {
        size.width  = std::max(1, std::min(rs.render_width,  16384));
        size.height = std::max(1, std::min(rs.render_height, 16384));
    }

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
    const macvoxel::GlassMode mode = macvoxel::CurrentRenderState().glass_mode;
    if (mode != _lastGlassMode) {
        _lastGlassMode = mode;
        _wantsClear = YES;
    }
    const bool pw_nee = macvoxel::CurrentRenderState().power_weighted_nee;
    if (pw_nee != _lastPowerWeightedNee) {
        _lastPowerWeightedNee = pw_nee;
        _wantsClear = YES;
    }
    const float sky_k = macvoxel::CurrentRenderState().sky_intensity;
    if (sky_k != _lastSkyIntensity) {
        _lastSkyIntensity = sky_k;
        _wantsClear = YES;
    }

    if (_wantsClear) {
        _sampleCount = 0;
        _wantsClear = NO;
    }

    if (_coarseBuffer == nil || _poolBuffer == nil ||
        _paletteBuffer == nil || _materialBuffer == nil) {
        // Nothing to trace; let the display pass clear to background.
        return;
    }

    // Stop contributing new samples once the cap is reached, or when
    // the app isn't active — there's no point burning GPU on a render
    // the user can't see (and on battery it matters). Display pass
    // below still runs so the image keeps showing the moment focus
    // returns.
    const int max_samples_cfg = std::max(
        1, macvoxel::CurrentRenderState().max_samples);
    const bool accumulate_more =
        _sampleCount < static_cast<uint32_t>(max_samples_cfg) &&
        [NSApp isActive];

    // ---------- Pass 1: accumulate one new sample into accum texture ----------
    if (accumulate_more) {
        [self encodeAccumulationSampleIntoCommandBuffer:cmd
                                                 camera:camera
                                                   size:size
                                             maxBounces:static_cast<uint32_t>(
                                                 macvoxel::CurrentRenderState().max_bounces)
                                              frameSeed:_sampleCount + 1u];
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
        du.aces_tonemap =
            macvoxel::CurrentRenderState().aces_tonemap ? 1u : 0u;
        // Aspect-preserving fit-to-window: render-aspect vs drawable-
        // aspect tells us which dimension is the limiter. Whichever
        // axis is over-large gets squeezed to a fraction of its NDC
        // extent; the other stays at 1.0.
        const float ar = static_cast<float>(_accumSize.width) /
                         static_cast<float>(_accumSize.height);
        const float ad = static_cast<float>(drawable.width) /
                         static_cast<float>(drawable.height);
        du.region_w = std::min(1.0f, ar / ad);
        du.region_h = std::min(1.0f, ad / ar);

        [enc setRenderPipelineState:_displayPipeline];
        [enc setCullMode:MTLCullModeNone];
        [enc setFragmentBytes:&du length:sizeof(du) atIndex:0];
        [enc setFragmentTexture:_accumTexture atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }

    macvoxel::CurrentRenderState().sample_count = _sampleCount;
}

// Encodes one accumulation pass into `cmd`, drawing into _accumTexture.
// All resource buffers (_coarseBuffer, _poolBuffer, etc.) and
// _accumTexture must already be set up by the caller. Increments
// _sampleCount; loadAction is Clear iff this is the first sample.
- (void)encodeAccumulationSampleIntoCommandBuffer:(id<MTLCommandBuffer>)cmd
                                            camera:(const macvoxel::Camera&)camera
                                              size:(CGSize)size
                                        maxBounces:(uint32_t)maxBounces
                                         frameSeed:(uint32_t)frameSeed {
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
    {
        const float k = std::max(0.0f,
            macvoxel::CurrentRenderState().sky_intensity);
        u.sky_color = simd::float3{0.65f * k, 0.75f * k, 0.95f * k};
    }
    u._pad3 = 0.0f;
    u.frame_seed = frameSeed;
    u.max_bounces = maxBounces;
    u.light_count = _lightCount;
    u.glass_mode = static_cast<uint32_t>(
        macvoxel::CurrentRenderState().glass_mode);
    u.power_weighted_nee =
        macvoxel::CurrentRenderState().power_weighted_nee ? 1u : 0u;

    [enc setRenderPipelineState:_pathPipeline];
    [enc setCullMode:MTLCullModeNone];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc setFragmentBuffer:_coarseBuffer offset:0 atIndex:1];
    [enc setFragmentBuffer:_poolBuffer offset:0 atIndex:2];
    [enc setFragmentBuffer:_paletteBuffer offset:0 atIndex:3];
    [enc setFragmentBuffer:_materialBuffer offset:0 atIndex:4];
    [enc setFragmentBuffer:_lightBuffer offset:0 atIndex:5];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    ++_sampleCount;
}

- (BOOL)renderHeadlessSamples:(uint32_t)samples
                     document:(macvoxel::Document*)doc
                       camera:(const macvoxel::Camera&)camera
                         size:(CGSize)size
                   maxBounces:(uint32_t)maxBounces
                     baseSeed:(uint32_t)baseSeed
                 commandQueue:(id<MTLCommandQueue>)queue
                        error:(NSError**)outError {
    if (doc == nullptr || queue == nil ||
        size.width <= 0.0 || size.height <= 0.0) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"MacVoxelHeadless" code:1
                       userInfo:@{NSLocalizedDescriptionKey:
                                      @"invalid headless render parameters"}];
        }
        return NO;
    }

    [self ensureAccumTextureForSize:size];
    [self rebuildResourcesFromDocument:doc];
    _sampleCount = 0;
    _wantsClear = NO;

    if (_coarseBuffer == nil || _poolBuffer == nil ||
        _paletteBuffer == nil || _materialBuffer == nil) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"MacVoxelHeadless" code:2
                       userInfo:@{NSLocalizedDescriptionKey:
                                      @"document has no voxels"}];
        }
        return NO;
    }

    id<MTLCommandBuffer> last = nil;
    for (uint32_t i = 0; i < samples; ++i) {
        @autoreleasepool {
            id<MTLCommandBuffer> cmd = [queue commandBuffer];
            cmd.label = @"PathTraceHeadless";
            [self encodeAccumulationSampleIntoCommandBuffer:cmd
                                                     camera:camera
                                                       size:size
                                                 maxBounces:maxBounces
                                                  frameSeed:baseSeed + i + 1u];
            [cmd commit];
            last = cmd;
        }
    }
    if (last != nil) [last waitUntilCompleted];
    return YES;
}

- (BOOL)exportPNGToURL:(NSURL*)url
          commandQueue:(id<MTLCommandQueue>)queue
                 error:(NSError**)outError {
    if (_accumTexture == nil || _displayPipeline == nil) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"MacVoxelExport" code:1
                       userInfo:@{NSLocalizedDescriptionKey:
                                      @"nothing rendered yet"}];
        }
        return NO;
    }

    // Shared-storage BGRA8 target so we can read it back after the GPU
    // is done. On Apple Silicon this is a single allocation visible to
    // both CPU and GPU — no blit needed.
    const NSUInteger w = static_cast<NSUInteger>(_accumSize.width);
    const NSUInteger h = static_cast<NSUInteger>(_accumSize.height);
    if (w == 0 || h == 0) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"MacVoxelExport" code:2
                       userInfo:@{NSLocalizedDescriptionKey:
                                      @"render target has zero size"}];
        }
        return NO;
    }
    MTLTextureDescriptor* td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:_colorFormat
                                                           width:w
                                                          height:h
                                                       mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> shot = [_device newTextureWithDescriptor:td];
    shot.label = @"PathTraceExport";

    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    cmd.label = @"PathTraceExport";

    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = shot;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc =
        [cmd renderCommandEncoderWithDescriptor:rpd];
    DisplayUniforms du;
    du.sample_count = _sampleCount;
    du.aces_tonemap =
        macvoxel::CurrentRenderState().aces_tonemap ? 1u : 0u;
    // Export target matches the accum exactly — no letterbox.
    du.region_w = 1.0f;
    du.region_h = 1.0f;
    [enc setRenderPipelineState:_displayPipeline];
    [enc setCullMode:MTLCullModeNone];
    [enc setFragmentBytes:&du length:sizeof(du) atIndex:0];
    [enc setFragmentTexture:_accumTexture atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];

    [cmd commit];
    [cmd waitUntilCompleted];

    // Pull pixels into a CPU buffer. We encode as RGBA so ImageIO
    // doesn't have to swap the channels itself.
    const size_t bytes_per_row = w * 4;
    std::vector<uint8_t> rgba(bytes_per_row * h);
    [shot getBytes:rgba.data()
       bytesPerRow:bytes_per_row
        fromRegion:MTLRegionMake2D(0, 0, w, h)
       mipmapLevel:0];
    if (_colorFormat == MTLPixelFormatBGRA8Unorm) {
        for (size_t i = 0; i < rgba.size(); i += 4) {
            std::swap(rgba[i + 0], rgba[i + 2]);
        }
    }

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider =
        CGDataProviderCreateWithData(nullptr, rgba.data(),
                                     rgba.size(), nullptr);
    const uint32_t bitmap_info = static_cast<uint32_t>(kCGBitmapByteOrderDefault) |
                                 static_cast<uint32_t>(kCGImageAlphaPremultipliedLast);
    CGImageRef img = CGImageCreate(
        w, h, 8, 32, bytes_per_row, cs, bitmap_info,
        provider, nullptr, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
    if (img == nullptr) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"MacVoxelExport" code:3
                       userInfo:@{NSLocalizedDescriptionKey:
                                      @"CGImageCreate failed"}];
        }
        return NO;
    }

    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier,
        1, nullptr);
    if (dest == nullptr) {
        CGImageRelease(img);
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"MacVoxelExport" code:4
                       userInfo:@{NSLocalizedDescriptionKey:
                                      @"could not create PNG destination"}];
        }
        return NO;
    }
    CGImageDestinationAddImage(dest, img, nullptr);
    const bool ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(img);
    if (!ok) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"MacVoxelExport" code:5
                       userInfo:@{NSLocalizedDescriptionKey:
                                      @"PNG write failed"}];
        }
        return NO;
    }
    return YES;
}

@end
