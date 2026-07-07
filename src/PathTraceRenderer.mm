#import "PathTraceRenderer.h"

#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Metal interop types (MTLCommandQueue_id / MTLBuffer_id) resolve to the
// Obj-C id<> protocols because this is compiled as Obj-C++ after Metal.
#include <OpenImageDenoise/oidn.h>

#import <cstdio>
#include <array>
#include <cstdint>
#include <cstring>
#include <vector>

#include "Camera.h"
#include "ChunkPool.h"
#include "Document.h"
#include "EditEngine.h"
#include "Material.h"
#include "EditorContext.h"
#include "RenderState.h"

#include <unordered_map>
#include <utility>

#include <cmath>

namespace {

// Floating-selection overlay baked into the PT grid rebuild. The lift's
// authoritative content lives in tex_lift (GPU); we read it back at its
// already-transformed bounds and merge it into the coarse+pool buffers so
// the path tracer matches what the rasterizer composites. `bounds` is the
// volume-clipped world bbox the `bytes` cover, x-fastest.
struct LiftOverlay {
    macvoxel::Bounds3 bounds;
    std::vector<uint8_t> bytes;
    bool valid() const { return !bounds.empty() && !bytes.empty(); }
};

struct PathUniforms {
    // Camera basis for primary-ray reconstruction (world space). Unit
    // vectors instead of inv(P*V) — same conditioning fix as the
    // rasterizer (see RaycastRenderer encodeWithEncoder).
    simd::float3 cam_right;  float cam_tan_half;  // tan(fov_y / 2)
    simd::float3 cam_up;     float cam_aspect;
    simd::float3 cam_fwd;    float _padfwd;
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
    uint32_t nee_ris_count;       // RIS candidate count (≥ 1)
    uint32_t atmospheric_sky;     // 0 = constant sky tint, 1 = Nishita
    uint32_t _pad6;
    simd::float3 sun_dir_grid;    // grid-space, unit-length
    float sun_cos_half_angle;     // cos(angular_diameter / 2)
    simd::float3 sun_radiance;    // linear-space color × intensity
    float horizon_softness_k;     // exp falloff coeff; 0 = off
    simd::float4 lobes[8];        // per-bounce shared 2D sample (.xy used)
    simd::float2 jitter_mult;     // irrational rotator on the corr seed
    uint32_t bsdf_correlation;    // 0 = PCG reference, 1 = correlated
    uint32_t _pad_corr;
    float indirect_clamp_L;       // <=0 disables proportional clamp
    float _pad_tail[3];           // round up to 16-byte alignment
    // Thin-lens DOF. Camera basis is grid-space (matches the rest of
    // the path tracer's coord system); .w slots pack the two DOF
    // scalars to avoid extra padding rows.
    simd::float4 camera_right_grid;    // .xyz = right (grid); .w = aperture
    simd::float4 camera_up_grid;       // .xyz = up    (grid); .w = focus_distance
    simd::float4 camera_forward_grid;  // .xyz = forward (grid); .w unused
};
// CPU and MSL `constant` PathUniforms must agree byte-for-byte, since
// we setBytes:length:sizeof(PathUniforms). The simd float3/int3 types
// are 16-byte slots on both sides (3-of-4 used) so the explicit `_padN`
// scalars get an additional 12-byte auto-pad in front of every
// 16-aligned successor.
static_assert(sizeof(PathUniforms) == 528, "PathUniforms size mismatch");

// Per-exposed-emissive-face entry in the next-event-estimation light
// buffer. An "exposed face" is the boundary between an emissive voxel
// and an empty neighbor cell; faces buried inside contiguous emissive
// regions (or against solid non-emissive cells) emit no light to the
// rest of the scene and are skipped. For a 40³ solid emissive cube this
// collapses ~64k voxel records to ~9.6k surface-face records and gets
// rid of the ~85% wasted shadow-ray budget the old per-voxel list
// burned on interior cells. Each record is sampled as a 1×1 area light
// in the plane perpendicular to its outward normal.
struct GpuLight {
    simd::float4 pos;  // .xyz = grid-space corner of the *face*: the
                       //       voxel's minimum corner shifted +1 along
                       //       any normal axis whose sign is positive
                       //       (so the shader can sample as
                       //       pos.xyz + perp1·u1 + perp2·u2 directly).
                       // .w   = cumulative normalized sampling weight (CDF).
                       //       Last face's .w is 1.0; binary search picks
                       //       `li` such that cdf[li-1] < u <= cdf[li].
    simd::float4 le;   // .xyz = albedo_linear * effective_emission.
                       // .w   = per-face sampling probability (prob[li] =
                       //       cdf[li] - cdf[li-1]). Pre-baked so the
                       //       BSDF-arrives-at-emitter MIS branch reads it
                       //       directly without re-doing the subtract.
    simd::float4 nrm;  // .xyz = outward face normal — axis-aligned unit
                       //       vector with a single ±1 component.
                       // .w   = unused.
};
static_assert(sizeof(GpuLight) == 48, "GpuLight size mismatch");

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
    // Temporal-EMA blend weight applied by ema_compose_fragment.
    //   1.0  → no blend (current frame passes through).
    //   <1.0 → mix(history, current, w). Smaller = heavier smoothing.
    // Computed CPU-side as max(1/(sample_count+1), ema_floor).
    float ema_weight;
};

// CPU mirror of AovUniforms in PathTrace.metal. mode: 0 = albedo, 1 = normal.
struct AovUniforms {
    uint32_t sample_count;
    uint32_t mode;
};

// CPU mirror of AovResolveUniforms in PathTrace.metal.
struct AovResolveUniforms {
    uint32_t width;
    uint32_t height;
    uint32_t sample_count;
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
    // Direct accumulator-tonemap pipeline kept for the headless export
    // path — that path is one-shot and doesn't need the EMA's
    // ping-pong texture state.
    id<MTLRenderPipelineState> _displayDirectPipeline;
    // Temporal-EMA compose pipeline: reads accum + previous history,
    // writes the blended tonemapped value to the new history texture.
    // The display pipeline then samples that history into the drawable.
    // Mirrors MagicaVoxel's pt_post.glsl mix pattern.
    id<MTLRenderPipelineState> _emaComposePipeline;
    // Resolves an accumulated AOV buffer (albedo or normal) to a viewable
    // LDR image for the CLI dump path.
    id<MTLRenderPipelineState> _aovResolvePipeline;
    id<MTLTexture> _accumTexture;
    // Denoiser guide buffers (first-hit albedo + grid-space normal),
    // accum-sized, accumulated alongside _accumTexture as MRT targets 1/2.
    id<MTLTexture> _aovAlbedo;
    id<MTLTexture> _aovNormal;

    // OIDN denoise path (Metal backend). The resolve compute kernel packs
    // accum + AOVs into these float4 buffers; OIDN denoises color in place
    // of _dnOutput; the result is blitted into _denoisedTex for tonemap.
    id<MTLComputePipelineState> _aovResolveCompute;
    id<MTLBuffer> _dnColor;
    id<MTLBuffer> _dnAlbedo;
    id<MTLBuffer> _dnNormal;
    id<MTLBuffer> _dnOutput;
    id<MTLTexture> _denoisedTex;
    // OIDN Metal device + the queue it wraps. Created lazily on first
    // denoise, cached for the renderer's lifetime (device init is costly).
    OIDNDevice _oidnDevice;
    id<MTLCommandQueue> _oidnQueue;
    // Live-viewport denoise bookkeeping. `_denoiseValid` gates swapping the
    // display over to _denoisedTex (false until the first denoise after a
    // reset, so camera moves don't flash a stale/black frame).
    // `_lastDenoisedSample` skips re-denoising a sample count we already
    // did — so a converged still image stops costing GPU.
    BOOL _denoiseValid;
    uint32_t _lastDenoisedSample;
    // Temporal-EMA history texture. The compose pass renders into this
    // with hardware alpha-blending using blend_color.a = ema_weight as
    // the source factor, so the texture content evolves as
    //   history' = history * (1 - ema_weight) + current * ema_weight.
    // Single texture; no ping-pong. Accum-sized, RGBA16Float for enough
    // precision in tonemapped color space.
    //
    // `_emaHistoryValid` flips to NO whenever the accumulator resets;
    // the next compose pass uses loadAction=Clear (so dst=0) and
    // blendColor.a=1 (so result=current). After that pass, the
    // history is valid and ongoing frames use loadAction=Load + the
    // user's ema_floor weight.
    id<MTLTexture> _emaHistory;
    BOOL _emaHistoryValid;
    CGSize _accumSize;

    id<MTLBuffer> _coarseBuffer;
    id<MTLBuffer> _poolBuffer;
    id<MTLBuffer> _paletteBuffer;
    id<MTLBuffer> _materialBuffer;
    id<MTLBuffer> _lightBuffer;
    uint32_t _lightCount;
    // Small noise texture for the Magica-style tile-correlated jitter
    // stream. Filled with white noise once at init; the shader reads it
    // with NEAREST filtering, so 16x16 screen-pixel tiles share their
    // seed and adjacent pixels' BRDF directions correlate.
    id<MTLTexture> _jitterNoise;
    // Typed dirty caches — each renderer-side buffer rebuilds only when
    // its category's counter advances. Lights derive from all three, so
    // the light buffer rebuilds whenever any of them changes.
    uint64_t _cachedGeometryVersion;
    uint64_t _cachedPaletteVersion;
    uint64_t _cachedMaterialVersion;
    uint64_t _cachedSceneVersion;
    BOOL _resourcesValid;
    // Whole-scene world flatten built once per geometry sync; the voxel
    // buffers pack it and the light scan traverses it (doc->grid only
    // holds the active object).
    macvoxel::VoxelGrid _flatGrid;
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
    bool _lastAreaLightNee;
    float _lastIndirectClampL;
    float _lastSkyIntensity;
    int _lastNeeRisCount;
    bool _lastAtmosphericSky;
    float _lastHorizonSoftnessDeg;
    // Hash of the sun parameters (elev / azim / diameter / color /
    // intensity). Cheaper to fingerprint than to compare each field.
    uint64_t _lastSunHash;
    float _lastAperture;
    float _lastFocusDistance;
    int _lastMaxBounces;
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
    id<MTLFunction> emaffn = [library newFunctionWithName:@"ema_compose_fragment"];
    id<MTLFunction> dispffn = [library newFunctionWithName:@"display_fragment"];
    id<MTLFunction> dispdirffn = [library newFunctionWithName:@"display_fragment_direct"];
    id<MTLFunction> aovffn = [library newFunctionWithName:@"aov_resolve_fragment"];

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
        // AOV guide buffers (albedo / normal) accumulate the same additive
        // way so they pick up free anti-aliasing from per-sample jitter.
        for (NSUInteger i = 1; i <= 2; ++i) {
            d.colorAttachments[i].pixelFormat = MTLPixelFormatRGBA16Float;
            d.colorAttachments[i].blendingEnabled = YES;
            d.colorAttachments[i].rgbBlendOperation = MTLBlendOperationAdd;
            d.colorAttachments[i].alphaBlendOperation = MTLBlendOperationAdd;
            d.colorAttachments[i].sourceRGBBlendFactor = MTLBlendFactorOne;
            d.colorAttachments[i].sourceAlphaBlendFactor = MTLBlendFactorOne;
            d.colorAttachments[i].destinationRGBBlendFactor = MTLBlendFactorOne;
            d.colorAttachments[i].destinationAlphaBlendFactor = MTLBlendFactorOne;
        }
        _pathPipeline = [_device newRenderPipelineStateWithDescriptor:d error:&error];
        if (_pathPipeline == nil) {
            fprintf(stderr, "MacVoxel: failed to build path-trace pipeline: %s\n",
                    [[error localizedDescription] UTF8String]);
            return nil;
        }
    }

    // EMA compose pipeline: writes the tonemapped current value to the
    // history texture with hardware alpha-blending driven by
    // setBlendColorRed:green:blue:alpha:.  Source factor reads
    // blend_color.a (= ema_weight), destination factor reads
    // 1 - blend_color.a — so the ROP evaluates
    //   dst' = mix(dst, src, ema_weight)
    // which is exactly Magica's pt_post.glsl mix(tex_last, dst, weight).
    // Using hardware blend instead of in-shader sampling of a previous-
    // frame texture eliminates the ping-pong logic, the read/write
    // hazard, and the "did the history texture actually persist" failure
    // mode that the old shader-based version had.
    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.label = @"PathTraceEMACompose";
        d.vertexFunction = vfn;
        d.fragmentFunction = emaffn;
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        d.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorBlendAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorBlendAlpha;
        d.colorAttachments[0].destinationRGBBlendFactor =
            MTLBlendFactorOneMinusBlendAlpha;
        d.colorAttachments[0].destinationAlphaBlendFactor =
            MTLBlendFactorOneMinusBlendAlpha;
        _emaComposePipeline =
            [_device newRenderPipelineStateWithDescriptor:d error:&error];
        if (_emaComposePipeline == nil) {
            fprintf(stderr, "MacVoxel: failed to build EMA compose pipeline: %s\n",
                    [[error localizedDescription] UTF8String]);
            return nil;
        }
    }

    // Display pipeline: samples the EMA-composed history texture (the
    // tonemapped frame from the just-run compose pass), writes to the
    // MTKView's drawable with letterbox/region clipping.
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

    // Direct display pipeline: tonemaps the accumulator in one shot,
    // bypassing the EMA history. Used by exportPNGToURL since headless
    // / one-shot exports don't have a sensible "previous frame" to
    // blend with — they need a deterministic snapshot of the current
    // accumulator.
    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.label = @"PathTraceDisplayDirect";
        d.vertexFunction = vfn;
        d.fragmentFunction = dispdirffn;
        d.colorAttachments[0].pixelFormat = colorFormat;
        _displayDirectPipeline =
            [_device newRenderPipelineStateWithDescriptor:d error:&error];
        if (_displayDirectPipeline == nil) {
            fprintf(stderr, "MacVoxel: failed to build direct-display pipeline: %s\n",
                    [[error localizedDescription] UTF8String]);
            return nil;
        }
    }

    // AOV resolve pipeline: one-shot mean + remap of an accumulated guide
    // buffer to an LDR image for the CLI dump path.
    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.label = @"PathTraceAOVResolve";
        d.vertexFunction = vfn;
        d.fragmentFunction = aovffn;
        d.colorAttachments[0].pixelFormat = colorFormat;
        _aovResolvePipeline =
            [_device newRenderPipelineStateWithDescriptor:d error:&error];
        if (_aovResolvePipeline == nil) {
            fprintf(stderr, "MacVoxel: failed to build AOV resolve pipeline: %s\n",
                    [[error localizedDescription] UTF8String]);
            return nil;
        }
    }

    // Compute pipeline that packs accum + AOV textures into the float4
    // buffers OIDN denoises.
    {
        id<MTLFunction> fn = [library newFunctionWithName:@"aov_resolve_compute"];
        _aovResolveCompute =
            [_device newComputePipelineStateWithFunction:fn error:&error];
        if (_aovResolveCompute == nil) {
            fprintf(stderr, "MacVoxel: failed to build AOV resolve compute: %s\n",
                    [[error localizedDescription] UTF8String]);
            return nil;
        }
    }

    {
        constexpr NSUInteger kNoiseDim = 64;
        // R32Float so the shader's `seed * 859 + ...` mutation chain
        // doesn't compound 8-bit quantization into banded tile-edges
        // in the splash pattern (visible as fragmentation in the
        // cluster silhouette projection).
        MTLTextureDescriptor* td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                          width:kNoiseDim
                                         height:kNoiseDim
                                      mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeManaged;
        _jitterNoise = [_device newTextureWithDescriptor:td];
        _jitterNoise.label = @"PathTraceJitterNoise";
        // White-noise fill — the shader linear-filters between texels,
        // which smooths tile-to-tile transitions enough that the
        // texture content's spectral character doesn't matter much.
        float noise[kNoiseDim * kNoiseDim];
        uint32_t s = 0xC0FFEE;
        for (NSUInteger i = 0; i < kNoiseDim * kNoiseDim; ++i) {
            s ^= s << 13; s ^= s >> 17; s ^= s << 5;
            noise[i] = static_cast<float>(s) * (1.0f / 4294967296.0f);
        }
        MTLRegion region = MTLRegionMake2D(0, 0, kNoiseDim, kNoiseDim);
        [_jitterNoise replaceRegion:region
                        mipmapLevel:0
                          withBytes:noise
                        bytesPerRow:kNoiseDim * sizeof(float)];
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

- (void)rebuildVoxelBuffersFromDocument:(macvoxel::Document*)doc
                            liftOverlay:(const LiftOverlay*)overlay {
    using VG = macvoxel::VoxelGrid;
    using CC = VG::ChunkCoord;

    // Bin the floating-lift cells by chunk so each can be splatted onto the
    // pool region for its chunk (existing or freshly allocated below).
    std::unordered_map<CC, std::vector<std::pair<uint32_t, uint8_t>>,
                       VG::ChunkCoordHash> lift_cells;
    if (overlay != nullptr && overlay->valid()) {
        const macvoxel::Bounds3& b = overlay->bounds;
        const size_t bw = static_cast<size_t>(b.size_x());
        const size_t bh = static_cast<size_t>(b.size_y());
        const size_t bd = static_cast<size_t>(b.size_z());
        if (overlay->bytes.size() >= bw * bh * bd) {
            for (size_t z = 0; z < bd; ++z)
            for (size_t y = 0; y < bh; ++y) {
                const size_t row = (z * bh + y) * bw;
                for (size_t x = 0; x < bw; ++x) {
                    const uint8_t v = overlay->bytes[row + x];
                    if (v == 0) continue;
                    const int32_t wx = b.min_x + static_cast<int32_t>(x);
                    const int32_t wy = b.min_y + static_cast<int32_t>(y);
                    const int32_t wz = b.min_z + static_cast<int32_t>(z);
                    lift_cells[VG::ToChunkCoord(wx, wy, wz)].push_back(
                        {static_cast<uint32_t>(VG::LocalIndex(wx, wy, wz)), v});
                }
            }
        }
    }

    macvoxel::PackedChunks packed =
        macvoxel::PackGridChunks(_flatGrid, std::move(lift_cells));
    if (packed.empty()) {
        _coarseMin = simd::int3{0, 0, 0};
        _coarseDim = simd::int3{0, 0, 0};
        _coarseBuffer = nil;
        _poolBuffer = nil;
        return;
    }
    _coarseMin = simd::int3{packed.min[0], packed.min[1], packed.min[2]};
    _coarseDim = simd::int3{packed.dim[0], packed.dim[1], packed.dim[2]};
    _coarseBuffer =
        [_device newBufferWithBytes:packed.coarse.data()
                             length:packed.coarse.size() * sizeof(uint32_t)
                            options:MTLResourceStorageModeShared];
    _coarseBuffer.label = @"PTCoarse";
    _poolBuffer = [_device newBufferWithBytes:packed.pool.data()
                                       length:packed.pool.size()
                                      options:MTLResourceStorageModeShared];
    _poolBuffer.label = @"PTChunkPool";
}

- (void)rebuildPaletteBufferFromDocument:(macvoxel::Document*)doc {
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
}

- (void)rebuildMaterialBufferFromDocument:(macvoxel::Document*)doc {
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
}

// Lights are derived from (geometry × palette emission × material
// emission strength), so rebuild whenever any of those three categories
// has advanced. Cheaper than the voxel buffer in absolute terms but
// it's the only buffer that has to *traverse* every cell on rebuild,
// so skipping it on pure render-mode entries is meaningful.
- (void)rebuildLightBufferFromDocument:(macvoxel::Document*)doc {
    using VG = macvoxel::VoxelGrid;
    const auto& chunks = _flatGrid.chunks();
    // Next-event estimation light list — one entry per *exposed*
    // emissive face. A face is exposed when the neighbor cell across
    // it is empty (v == 0); faces against any solid neighbor — even
    // another emissive voxel — emit nothing into the rest of the scene
    // and are skipped. The light-list size therefore scales with the
    // emissive *surface area*, not the emissive *volume*, which is
    // what fixes the 40³ solid-emissive-cube perf cliff (64k → 9.6k).
    // Neighbor probes consult the full flatten (the dense shadow only
    // covers the active object's edit volume).
    std::vector<GpuLight> lights;
    lights.reserve(64);
    const macvoxel::VoxelGrid& flat = _flatGrid;
    auto is_empty = [&flat](int32_t x, int32_t y, int32_t z) {
        return flat.Get(x, y, z) == 0;
    };
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
                    const int32_t gx = base_x + static_cast<int32_t>(lx);
                    const int32_t gy = base_y + static_cast<int32_t>(ly);
                    const int32_t gz = base_z + static_cast<int32_t>(lz);
                    const simd::float4 le_pre = simd::float4{
                        std::pow(c.r / 255.0f, 2.2f) * eff,
                        std::pow(c.g / 255.0f, 2.2f) * eff,
                        std::pow(c.b / 255.0f, 2.2f) * eff,
                        0.0f,
                    };
                    // Six axial neighbors. For each exposed face, the
                    // record's `pos` is the face's minimum corner (the
                    // voxel corner shifted +1 along the normal axis
                    // when the normal points in the positive direction),
                    // so the shader's `pos + perp1·u + perp2·v` sweeps
                    // the unit-area face directly.
                    struct Face {
                        int32_t dx, dy, dz;
                        float   nx, ny, nz;
                        float   ox, oy, oz;  // anchor offset from voxel corner
                    };
                    static constexpr Face kFaces[6] = {
                        { -1, 0, 0,  -1, 0, 0,  0, 0, 0 },
                        { +1, 0, 0,  +1, 0, 0,  1, 0, 0 },
                        {  0,-1, 0,   0,-1, 0,  0, 0, 0 },
                        {  0,+1, 0,   0,+1, 0,  0, 1, 0 },
                        {  0, 0,-1,   0, 0,-1,  0, 0, 0 },
                        {  0, 0,+1,   0, 0,+1,  0, 0, 1 },
                    };
                    for (const Face& f : kFaces) {
                        if (!is_empty(gx + f.dx, gy + f.dy, gz + f.dz)) continue;
                        GpuLight L;
                        L.pos = simd::float4{
                            static_cast<float>(gx) + f.ox,
                            static_cast<float>(gy) + f.oy,
                            static_cast<float>(gz) + f.oz,
                            0.0f,
                        };
                        L.le  = le_pre;
                        L.nrm = simd::float4{ f.nx, f.ny, f.nz, 0.0f };
                        lights.push_back(L);
                    }
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
}

// Sync GPU resources to the document, rebuilding only the categories
// whose typed counter has advanced since last call. Returns YES if any
// rebuild fired (caller uses that to decide whether to clear the
// accumulator).
- (BOOL)syncResourcesToContext:(macvoxel::EditorContext*)ctx {
    macvoxel::Document* doc = &ctx->document;
    BOOL geom_dirty = NO, pal_dirty = NO, mat_dirty = NO;
    if (!_resourcesValid ||
        _cachedGeometryVersion != doc->geometry_version ||
        _cachedSceneVersion != doc->scene_version) {
        // Fold any active-object edits back into its model, then flatten
        // the live scene — the PT always renders every object.
        doc->SyncActiveModel();
        macvoxel::FlattenScene(doc->scene, -1, &_flatGrid);
        // An active floating selection lives only in tex_lift; read it back
        // and bake it into the grid rebuild so the PT matches the viewport.
        LiftOverlay overlay;
        if (ctx->selection.lift_active() && ctx->engine != nullptr) {
            const macvoxel::Bounds3 lb = ctx->selection.bounds();
            macvoxel::Bounds3 cb = lb;
            cb.min_x = std::max(cb.min_x, doc->volume.x0);
            cb.min_y = std::max(cb.min_y, doc->volume.y0);
            cb.min_z = std::max(cb.min_z, doc->volume.z0);
            cb.max_x = std::min(cb.max_x, doc->volume.x1);
            cb.max_y = std::min(cb.max_y, doc->volume.y1);
            cb.max_z = std::min(cb.max_z, doc->volume.z1);
            if (!cb.empty()) {
                ctx->engine->ReadbackLift(lb, &overlay.bytes);
                overlay.bounds = cb;
            }
        }
        [self rebuildVoxelBuffersFromDocument:doc
                                  liftOverlay:overlay.valid() ? &overlay : nullptr];
        _cachedGeometryVersion = doc->geometry_version;
        _cachedSceneVersion = doc->scene_version;
        geom_dirty = YES;
    }
    if (!_resourcesValid ||
        _cachedPaletteVersion != doc->palette_version) {
        [self rebuildPaletteBufferFromDocument:doc];
        _cachedPaletteVersion = doc->palette_version;
        pal_dirty = YES;
    }
    if (!_resourcesValid ||
        _cachedMaterialVersion != doc->material_version) {
        [self rebuildMaterialBufferFromDocument:doc];
        _cachedMaterialVersion = doc->material_version;
        mat_dirty = YES;
    }
    if (geom_dirty || pal_dirty || mat_dirty) {
        [self rebuildLightBufferFromDocument:doc];
        _resourcesValid = YES;
        return YES;
    }
    return NO;
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

    // EMA history texture: same dimensions as accum, RGBA16Float for
    // enough precision to hold tonemapped+blended values across many
    // EMA frames without banding. Render target + shader-read since
    // the compose pass writes it (hardware blend) and the display pass
    // samples it.
    MTLTextureDescriptor* tdh =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                           width:static_cast<NSUInteger>(size.width)
                                                          height:static_cast<NSUInteger>(size.height)
                                                       mipmapped:NO];
    tdh.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    tdh.storageMode = MTLStorageModePrivate;
    _emaHistory = [_device newTextureWithDescriptor:tdh];
    _emaHistory.label = @"PTEMAHistory";
    _emaHistoryValid = NO;

    // Denoiser guide buffers: accum-sized RGBA16Float (signed-capable for
    // the normal), accumulated as MRT targets alongside _accumTexture and
    // resolved by exportAOVToURL.
    MTLTextureDescriptor* tda =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                           width:static_cast<NSUInteger>(size.width)
                                                          height:static_cast<NSUInteger>(size.height)
                                                       mipmapped:NO];
    tda.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    tda.storageMode = MTLStorageModePrivate;
    _aovAlbedo = [_device newTextureWithDescriptor:tda];
    _aovAlbedo.label = @"PTAOVAlbedo";
    _aovNormal = [_device newTextureWithDescriptor:tda];
    _aovNormal.label = @"PTAOVNormal";

    // OIDN I/O: one packed float4 per pixel per channel, Private (the whole
    // denoise round-trip stays on-GPU). _denoisedTex receives the result
    // for the existing tonemap pass.
    const NSUInteger pixels =
        static_cast<NSUInteger>(size.width) * static_cast<NSUInteger>(size.height);
    const NSUInteger bufLen = pixels * 4 * sizeof(float);
    _dnColor  = [_device newBufferWithLength:bufLen options:MTLResourceStorageModePrivate];
    _dnAlbedo = [_device newBufferWithLength:bufLen options:MTLResourceStorageModePrivate];
    _dnNormal = [_device newBufferWithLength:bufLen options:MTLResourceStorageModePrivate];
    _dnOutput = [_device newBufferWithLength:bufLen options:MTLResourceStorageModePrivate];
    MTLTextureDescriptor* tdd =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                           width:static_cast<NSUInteger>(size.width)
                                                          height:static_cast<NSUInteger>(size.height)
                                                       mipmapped:NO];
    tdd.usage = MTLTextureUsageShaderRead;
    tdd.storageMode = MTLStorageModePrivate;
    _denoisedTex = [_device newTextureWithDescriptor:tdd];
    _denoisedTex.label = @"PTDenoised";

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
             context:(macvoxel::EditorContext*)ctx
              camera:(const macvoxel::Camera&)camera {
    if (ctx == nullptr) return;
    const CGSize drawable = view.drawableSize;
    if (drawable.width <= 0.0 || drawable.height <= 0.0) return;

    const macvoxel::RenderSettings& rs = ctx->render_settings;
    CGSize size = drawable;
    if (!rs.resolution_match_window) {
        size.width  = std::max(1, std::min(rs.render_width,  16384));
        size.height = std::max(1, std::min(rs.render_height, 16384));
    }

    [self ensureAccumTextureForSize:size];
    if ([self syncResourcesToContext:ctx]) {
        _wantsClear = YES;
    }
    const uint64_t cam_hash = [self hashCameraState:camera];
    if (cam_hash != _lastCameraHash) {
        _lastCameraHash = cam_hash;
        _wantsClear = YES;
    }
    const macvoxel::GlassMode mode = rs.glass_mode;
    if (mode != _lastGlassMode) {
        _lastGlassMode = mode;
        _wantsClear = YES;
    }
    const bool pw_nee = rs.power_weighted_nee;
    if (pw_nee != _lastPowerWeightedNee) {
        _lastPowerWeightedNee = pw_nee;
        _wantsClear = YES;
    }
    const bool area_nee = rs.stochastic_gi;
    if (area_nee != _lastAreaLightNee) {
        _lastAreaLightNee = area_nee;
        _wantsClear = YES;
    }
    const float clamp_L = rs.indirect_clamp_L;
    if (clamp_L != _lastIndirectClampL) {
        _lastIndirectClampL = clamp_L;
        _wantsClear = YES;
    }
    const float sky_k = rs.sky_intensity;
    if (sky_k != _lastSkyIntensity) {
        _lastSkyIntensity = sky_k;
        _wantsClear = YES;
    }
    const int ris_m = rs.nee_ris_count;
    if (ris_m != _lastNeeRisCount) {
        _lastNeeRisCount = ris_m;
        _wantsClear = YES;
    }
    const bool atmo = rs.atmospheric_sky;
    if (atmo != _lastAtmosphericSky) {
        _lastAtmosphericSky = atmo;
        _wantsClear = YES;
    }
    const float horizon_deg =
        rs.horizon_softness_deg;
    if (horizon_deg != _lastHorizonSoftnessDeg) {
        _lastHorizonSoftnessDeg = horizon_deg;
        _wantsClear = YES;
    }
    {
        uint64_t h = 0xcbf29ce484222325ull;  // FNV-1a 64
        auto mix = [&h](float v) {
            uint32_t bits = 0;
            std::memcpy(&bits, &v, sizeof(bits));
            h ^= bits;
            h *= 0x100000001b3ull;
        };
        mix(rs.sun_elevation_deg);
        mix(rs.sun_azimuth_deg);
        mix(rs.sun_angular_diameter_deg);
        mix(rs.sun_color[0]);
        mix(rs.sun_color[1]);
        mix(rs.sun_color[2]);
        mix(rs.sun_intensity);
        if (h != _lastSunHash) {
            _lastSunHash = h;
            _wantsClear = YES;
        }
    }
    if (rs.aperture != _lastAperture) {
        _lastAperture = rs.aperture;
        _wantsClear = YES;
    }
    if (rs.focus_distance != _lastFocusDistance) {
        _lastFocusDistance = rs.focus_distance;
        _wantsClear = YES;
    }
    if ((int)rs.max_bounces != _lastMaxBounces) {
        _lastMaxBounces = (int)rs.max_bounces;
        _wantsClear = YES;
    }

    if (_wantsClear) {
        _sampleCount = 0;
        _wantsClear = NO;
        // EMA history is stale once the accumulator resets — start
        // fresh so the first post-reset frame doesn't blend with
        // pre-reset pixels (which would produce a "fade-from-old"
        // ghost).
        _emaHistoryValid = NO;
        // Likewise the denoised frame: don't display it until a fresh
        // denoise runs against the post-reset accumulator.
        _denoiseValid = NO;
    }

    if (_coarseBuffer == nil || _poolBuffer == nil ||
        _paletteBuffer == nil || _materialBuffer == nil) {
        // Nothing to trace — but MetalScene presents the drawable
        // unconditionally, so encode an empty pass (loadAction=Clear)
        // or the user sees uninitialized/stale memory in Render mode
        // with an empty grid.
        MTLRenderPassDescriptor* rpd = view.currentRenderPassDescriptor;
        if (rpd != nil) {
            id<MTLRenderCommandEncoder> enc =
                [cmd renderCommandEncoderWithDescriptor:rpd];
            enc.label = @"PathTraceEmptyClear";
            [enc endEncoding];
        }
        ctx->render_progress.sample_count = 0;
        return;
    }

    // Stop contributing new samples once the cap is reached, or when
    // the app isn't active — there's no point burning GPU on a render
    // the user can't see (and on battery it matters). Display pass
    // below still runs so the image keeps showing the moment focus
    // returns.
    const int max_samples_cfg = std::max(
        1, rs.max_samples);
    const bool accumulate_more =
        _sampleCount < static_cast<uint32_t>(max_samples_cfg) &&
        [NSApp isActive];

    // ---------- Pass 0: optional OIDN denoise of the live viewport -------
    // Only once accumulation has reached the sample target — denoising
    // intermediate frames is wasted work and would hitch camera moves (which
    // reset the count). While converging, the viewport shows the normal
    // progressive image; on hitting the cap we denoise exactly once (the
    // count stops changing) and display that until the next reset. The
    // denoise reads the accumulator committed through the previous frame, so
    // the resolve divides by the matching _sampleCount. It runs its own
    // command buffers + blocking waits on the frame queue, before the
    // drawable is acquired, so there's no present stall.
    BOOL useDenoised = NO;
    const bool reachedTarget =
        _sampleCount >= static_cast<uint32_t>(max_samples_cfg);
    if (rs.denoise && reachedTarget) {
        // Re-denoise when this accumulation epoch hasn't been denoised yet
        // (!_denoiseValid is cleared on every reset, e.g. a camera move) or
        // the target moved without a reset (max_samples raised). Without the
        // !_denoiseValid term, a post-reset re-converge that lands on the
        // same sample cap would match _lastDenoisedSample and never denoise.
        if (!_denoiseValid || _sampleCount != _lastDenoisedSample) {
            if ([self denoiseAccumulatedWithQueue:cmd.commandQueue]) {
                _lastDenoisedSample = _sampleCount;
                _denoiseValid = YES;
            }
        }
        useDenoised = _denoiseValid;
    }

    // ---------- Pass 1: accumulate one new sample into accum texture ----------
    if (accumulate_more) {
        [self encodeAccumulationSampleIntoCommandBuffer:cmd
                                                 camera:camera
                                                   size:size
                                             maxBounces:static_cast<uint32_t>(
                                                 rs.max_bounces)
                                              frameSeed:_sampleCount + 1u
                                               settings:rs];
    }

    // ---------- Pass 2: tonemap + EMA compose, then display -----------
    // Two-pass display: an EMA compose pass that runs at accum size and
    // bakes tonemapped+temporal-blend into the new history texture,
    // then a tiny display pass that copies that history into the
    // drawable with letterbox/region clipping.

    // Per-frame uniforms used by both passes (display ignores the
    // tonemap field).
    DisplayUniforms du;
    du.sample_count = _sampleCount;
    du.aces_tonemap = rs.aces_tonemap ? 1u : 0u;
    // Always fill the viewport vertically so the path-trace display
    // matches the raycast preview's framing (vertical FOV is fixed,
    // so vertical extent is identical regardless of accum aspect).
    // If the path-trace aspect is wider than the drawable, ndc.x
    // outside [-1, 1] never fires the display fragment's discard —
    // ndc.x / region_w stays sub-unit and we sample only the center
    // crop of the accum. If narrower, region_w < 1 and we get
    // pillarbox bars on the sides.
    const float ar = static_cast<float>(_accumSize.width) /
                     static_cast<float>(_accumSize.height);
    const float ad = static_cast<float>(drawable.width) /
                     static_cast<float>(drawable.height);
    du.region_w = ar / ad;
    du.region_h = 1.0f;
    // Temporal-EMA weight per MagicaVoxel's pt_post.glsl `mix(tex_last,
    // dst, weight)` shape. The compose fragment computes
    // `display = mix(history, current_mean, weight)`.
    //
    // We treat `rs.ema_floor` as the steady-state blend weight: small
    // values = heavy smoothing (longer trail), 1.0 = no smoothing
    // (current frame passes through unchanged). 0 also means no
    // smoothing — we force `weight = 1.0` so the compose pass is a
    // no-op rather than displaying a zeroed history.
    //
    // Earlier draft computed `weight = max(1/N, floor)` reasoning that
    // 1/N preserves the unbiased running mean during early
    // accumulation. That gave the slider zero visible effect for the
    // first ~1/floor frames because weight stayed at 1/N regardless of
    // the user setting; by the time the floor kicked in the underlying
    // running mean had already settled. Using `weight = floor`
    // directly from frame 2 onwards introduces a small bias (the
    // estimator now lags the true running mean) but makes the slider
    // actually do something at every accumulation stage.
    //
    // First frame after a clear is always weight 1.0 — there's no
    // history to blend against.
    const float ema_floor = std::clamp(rs.ema_floor, 0.0f, 1.0f);
    float ema_weight = ema_floor;
    if (!_emaHistoryValid || ema_floor <= 0.0f) ema_weight = 1.0f;
    du.ema_weight = ema_weight;

    // Pass A — EMA compose: write the tonemapped current frame into
    // the history texture. The pipeline state has hardware alpha-
    // blending enabled (BlendAlpha / OneMinusBlendAlpha) and
    // setBlendColor:alpha: drives the EMA weight, so the ROP evaluates
    //   dst' = mix(dst, src, ema_weight)
    // automatically without any shader-side history sampling.
    //
    // First frame after a reset: history texture content is stale.
    // We loadAction=Clear (so dst=0) and force blend_color.a=1.0
    // (so result = current with no contribution from dst). After this
    // pass, the history is valid; subsequent frames loadAction=Load
    // (so dst = previous frame's blended output) and use the user's
    // ema_floor as the blend alpha.
    {
        MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = _emaHistory;
        rpd.colorAttachments[0].loadAction = _emaHistoryValid
            ? MTLLoadActionLoad
            : MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLRenderCommandEncoder> enc =
            [cmd renderCommandEncoderWithDescriptor:rpd];
        enc.label = @"PathTraceEMACompose";
        [enc setRenderPipelineState:_emaComposePipeline];
        [enc setCullMode:MTLCullModeNone];
        // Hardware-blend factor for the EMA mix. With history invalid
        // (just-cleared dst) we want full src so the first frame after
        // a reset displays the unblended current value.
        const float blend_a = _emaHistoryValid ? ema_weight : 1.0f;
        [enc setBlendColorRed:0.0 green:0.0 blue:0.0 alpha:blend_a];
        // The denoised texture is already a per-sample mean, so the compose
        // pass must not divide it again — feed it with sample_count = 1.
        DisplayUniforms duCompose = du;
        if (useDenoised) duCompose.sample_count = 1u;
        [enc setFragmentBytes:&duCompose length:sizeof(duCompose) atIndex:0];
        [enc setFragmentTexture:(useDenoised ? _denoisedTex : _accumTexture) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }

    // Pass B — display: sample the just-written history texture into
    // the drawable with letterbox/region clipping.
    {
        MTLRenderPassDescriptor* rpd = view.currentRenderPassDescriptor;
        if (rpd == nil) return;
        id<MTLRenderCommandEncoder> enc =
            [cmd renderCommandEncoderWithDescriptor:rpd];
        enc.label = @"PathTraceDisplay";
        [enc setRenderPipelineState:_displayPipeline];
        [enc setCullMode:MTLCullModeNone];
        [enc setFragmentBytes:&du length:sizeof(du) atIndex:0];
        [enc setFragmentTexture:_emaHistory atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }

    // History is now valid and will be loaded next frame.
    _emaHistoryValid = YES;

    ctx->render_progress.sample_count = _sampleCount;
}

// Encodes one accumulation pass into `cmd`, drawing into _accumTexture.
// All resource buffers (_coarseBuffer, _poolBuffer, etc.) and
// _accumTexture must already be set up by the caller. Increments
// _sampleCount; loadAction is Clear iff this is the first sample.
- (void)encodeAccumulationSampleIntoCommandBuffer:(id<MTLCommandBuffer>)cmd
                                            camera:(const macvoxel::Camera&)camera
                                              size:(CGSize)size
                                        maxBounces:(uint32_t)maxBounces
                                         frameSeed:(uint32_t)frameSeed
                                          settings:(const macvoxel::RenderSettings&)rs {
    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = _accumTexture;
    rpd.colorAttachments[0].loadAction =
        (_sampleCount == 0) ? MTLLoadActionClear : MTLLoadActionLoad;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    // AOV guide buffers ride the same load/store/clear lifecycle as accum
    // so they stay in lockstep with the sample count and the camera-reset
    // clear.
    id<MTLTexture> aovTex[2] = { _aovAlbedo, _aovNormal };
    for (NSUInteger i = 0; i < 2; ++i) {
        rpd.colorAttachments[i + 1].texture = aovTex[i];
        rpd.colorAttachments[i + 1].loadAction =
            (_sampleCount == 0) ? MTLLoadActionClear : MTLLoadActionLoad;
        rpd.colorAttachments[i + 1].clearColor = MTLClearColorMake(0, 0, 0, 0);
        rpd.colorAttachments[i + 1].storeAction = MTLStoreActionStore;
    }

    id<MTLRenderCommandEncoder> enc =
        [cmd renderCommandEncoderWithDescriptor:rpd];
    enc.label = @"PathTraceAccumulate";

    const float aspect = static_cast<float>(size.width / size.height);
    const simd::float4x4 vmat = camera.ViewMatrix();
    const simd::float4x4 pmat = camera.ProjectionMatrix(aspect);

    PathUniforms u;
    // Camera basis from the view-matrix rows (R = [r; u; -f]) and
    // FOV/aspect from the projection — see RaycastRenderer for why
    // this replaces inv(P*V).
    u.cam_right = simd::float3{vmat.columns[0].x, vmat.columns[1].x,
                               vmat.columns[2].x};
    u.cam_up    = simd::float3{vmat.columns[0].y, vmat.columns[1].y,
                               vmat.columns[2].y};
    u.cam_fwd   = simd::float3{-vmat.columns[0].z, -vmat.columns[1].z,
                               -vmat.columns[2].z};
    u.cam_tan_half = 1.0f / pmat.columns[1].y;
    u.cam_aspect   = pmat.columns[1].y / pmat.columns[0].x;
    u._padfwd = 0.0f;
    u.camera_pos = camera.Position();
    u._pad0 = 0.0f;
    u.coarse_min = _coarseMin;
    u._pad1 = 0;
    u.coarse_dim = _coarseDim;
    u._pad2 = 0;
    {
        const float k = std::max(0.0f,
            rs.sky_intensity);
        u.sky_color = simd::float3{0.65f * k, 0.75f * k, 0.95f * k};
    }
    u._pad3 = 0.0f;
    u.frame_seed = frameSeed;
    u.max_bounces = maxBounces;
    u.light_count = rs.stochastic_gi ? _lightCount : 0u;
    u.glass_mode = static_cast<uint32_t>(
        rs.glass_mode);
    u.power_weighted_nee =
        rs.power_weighted_nee ? 1u : 0u;
    u.nee_ris_count = static_cast<uint32_t>(std::max(
        1, rs.nee_ris_count));
    u.atmospheric_sky =
        rs.atmospheric_sky ? 1u : 0u;
    {
        // Convert UI elevation/azimuth (degrees) to a unit-length
        // grid-space direction. Grid Z is up — elevation tilts off the
        // horizon plane, azimuth rotates around grid Z. (0°, 0°) points
        // along +grid-X.
        const float elev = rs.sun_elevation_deg * (3.14159265f / 180.0f);
        const float azim = rs.sun_azimuth_deg   * (3.14159265f / 180.0f);
        const float ce = std::cos(elev);
        u.sun_dir_grid = simd::float3{
            ce * std::cos(azim), ce * std::sin(azim), std::sin(elev)};
        const float cos_half = std::cos(
            std::max(0.0f, rs.sun_angular_diameter_deg) * 0.5f
            * (3.14159265f / 180.0f));
        u.sun_cos_half_angle = cos_half;
        // sun_intensity is an *irradiance* scale (the integrated
        // strength reaching a surface facing the sun) — the per-direction
        // radiance the shader uses is `color × intensity / solid_angle`,
        // so the per-pixel surface contribution comes out independent of
        // angular size:
        //
        //     ∫_cone (albedo/π) · radiance · cos_x dω
        //   = (albedo/π) · (color · intensity / solid_angle) · cos_x · solid_angle
        //   = (albedo/π) · color · intensity · cos_x
        //
        // So `intensity` at a fixed value lights surfaces equally whether
        // the sun is 0.5° or 20° — angular size only changes the disc's
        // visible size in the sky and the BSDF-side variance pattern.
        // sRGB → linear before the intensity multiply so HDR sun colours
        // mix with the path tracer's linear throughput accumulation.
        const float solid_angle =
            6.2831853f * (1.0f - cos_half);
        const float radiance_scale = (solid_angle > 1e-12f)
            ? (std::max(0.0f, rs.sun_intensity) / solid_angle)
            : 0.0f;
        u.sun_radiance = simd::float3{
            std::pow(rs.sun_color[0], 2.2f) * radiance_scale,
            std::pow(rs.sun_color[1], 2.2f) * radiance_scale,
            std::pow(rs.sun_color[2], 2.2f) * radiance_scale,
        };
        // Convert the user's "fade-out angle" (degrees) into the
        // exponential coefficient k the shader plugs into
        // exp(-k·|ray_dir.z|). At |ray_dir.z| = sin(angle) we want
        // fade ≈ exp(-3) ≈ 0.05, so k = 3 / sin(angle). 0° disables
        // the softening (k = 0 → shader falls back to a sharp horizon).
        const float horizon_rad =
            std::max(0.0f, rs.horizon_softness_deg) * (3.14159265f / 180.0f);
        const float horizon_sin = std::sin(horizon_rad);
        u.horizon_softness_k = (horizon_sin > 1e-6f)
            ? (3.0f / horizon_sin)
            : 0.0f;
    }
    {
        // Per-(sample, bounce) BSDF-direction stride. Same seed sequence
        // every pixel uses; the per-pixel `corr` perturbation lives in
        // the shader. Across samples `frameSeed` advances so each pixel
        // sees a different stride per bounce and the chosen BRDF
        // direction drifts across the cluster's solid angle.
        uint32_t s = frameSeed * 2654435761u + 0x9E3779B9u;
        auto next = [&s]() {
            s ^= s << 13; s ^= s >> 17; s ^= s << 5;
            return static_cast<float>(s) * (1.0f / 4294967296.0f);
        };
        for (int b = 0; b < 8; ++b) {
            u.lobes[b] = simd::float4{next(), next(), 0.0f, 0.0f};
        }
        // Irrational rotator on `corr`. Constant per frame — per-sample
        // drift is driven by `frame_seed` flowing into every stride
        // generator inside the shader, not by changing the rotator.
        // Values are MagicaVoxel's choice; magnitude ≈ 0.94 gives wide
        // per-pixel deviation so neighbour pixels in a noise texel
        // collapse to nearly the same sample, while pixels two texels
        // away decorrelate.
        u.jitter_mult = simd::float2{0.7548777f, 0.5698403f};
        // Reference mode disables the correlated stream entirely (every
        // call site falls back to per-pixel PCG). CLI-only escape hatch;
        // the UI always runs with bsdf_correlation = 1.
        u.bsdf_correlation = rs.path_trace_reference ? 0u : 1u;
        u._pad_corr = 0u;
        // Proportional clamp on indirect-bounce emitter contributions:
        // in scenes with sharp specular materials a single
        // diffuse→specular→emitter caustic path produces a per-sample
        // contribution that dominates the average, and MIS can't
        // suppress it (the BSDF lobe is essentially delta-aligned with
        // the emitter). The clamp tames those single-pixel spikes.
        u.indirect_clamp_L = std::max(0.0f, rs.indirect_clamp_L);
        u._pad_tail[0] = 0.0f;
        u._pad_tail[1] = 0.0f;
        u._pad_tail[2] = 0.0f;
    }
    {
        // Camera basis in grid space for the thin-lens DOF block.
        // World→grid rotation is (x, -z, y), matching the primary-ray
        // conversion in PathTrace.metal.
        const simd::float3 eye = camera.Position();
        const simd::float3 up_world{0.0f, 1.0f, 0.0f};
        const simd::float3 fwd_w = simd::normalize(camera.target - eye);
        const simd::float3 right_w =
            simd::normalize(simd::cross(fwd_w, up_world));
        const simd::float3 up_w = simd::cross(right_w, fwd_w);
        auto to_grid = [](simd::float3 v) {
            return simd::float3{v.x, -v.z, v.y};
        };
        const simd::float3 right_g = to_grid(right_w);
        const simd::float3 up_g    = to_grid(up_w);
        const simd::float3 fwd_g   = to_grid(fwd_w);
        const float aperture =
            std::max(0.0f, rs.aperture);
        const float focus_dist =
            std::max(0.1f, rs.focus_distance);
        u.camera_right_grid = simd::float4{
            right_g.x, right_g.y, right_g.z, aperture};
        u.camera_up_grid = simd::float4{
            up_g.x, up_g.y, up_g.z, focus_dist};
        u.camera_forward_grid = simd::float4{
            fwd_g.x, fwd_g.y, fwd_g.z, 0.0f};
    }

    [enc setRenderPipelineState:_pathPipeline];
    [enc setCullMode:MTLCullModeNone];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc setFragmentBuffer:_coarseBuffer offset:0 atIndex:1];
    [enc setFragmentBuffer:_poolBuffer offset:0 atIndex:2];
    [enc setFragmentBuffer:_paletteBuffer offset:0 atIndex:3];
    [enc setFragmentBuffer:_materialBuffer offset:0 atIndex:4];
    [enc setFragmentBuffer:_lightBuffer offset:0 atIndex:5];
    [enc setFragmentTexture:_jitterNoise atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    ++_sampleCount;
}

- (BOOL)renderHeadlessSamples:(uint32_t)samples
                      context:(macvoxel::EditorContext*)ctx
                       camera:(const macvoxel::Camera&)camera
                         size:(CGSize)size
                   maxBounces:(uint32_t)maxBounces
                     baseSeed:(uint32_t)baseSeed
                 commandQueue:(id<MTLCommandQueue>)queue
                        error:(NSError**)outError {
    if (ctx == nullptr || queue == nil ||
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
    [self syncResourcesToContext:ctx];
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

    const macvoxel::RenderSettings& rs = ctx->render_settings;
    id<MTLCommandBuffer> last = nil;
    for (uint32_t i = 0; i < samples; ++i) {
        @autoreleasepool {
            id<MTLCommandBuffer> cmd = [queue commandBuffer];
            cmd.label = @"PathTraceHeadless";
            [self encodeAccumulationSampleIntoCommandBuffer:cmd
                                                     camera:camera
                                                       size:size
                                                 maxBounces:maxBounces
                                                  frameSeed:baseSeed + i + 1u
                                                   settings:rs];
            [cmd commit];
            last = cmd;
        }
    }
    if (last != nil) [last waitUntilCompleted];
    return YES;
}

- (void)dealloc {
    if (_oidnDevice != nullptr) {
        oidnReleaseDevice(_oidnDevice);
        _oidnDevice = nullptr;
    }
}

// Runs OIDN over the accumulated frame: resolve textures → packed buffers,
// denoise on the Metal device, blit the result into _denoisedTex. Returns
// NO (leaving _denoisedTex untouched) if the device or filter errors, so
// callers can fall back to the raw accumulator.
- (BOOL)denoiseAccumulatedWithQueue:(id<MTLCommandQueue>)queue {
    const NSUInteger w = static_cast<NSUInteger>(_accumSize.width);
    const NSUInteger h = static_cast<NSUInteger>(_accumSize.height);
    if (w == 0 || h == 0 || _dnColor == nil || _aovResolveCompute == nil) {
        return NO;
    }

    if (_oidnDevice == nullptr) {
        _oidnQueue = [_device newCommandQueue];
        _oidnQueue.label = @"OIDNQueue";
        MTLCommandQueue_id q = _oidnQueue;
        _oidnDevice = oidnNewMetalDevice(&q, 1);
        if (_oidnDevice == nullptr) {
            fprintf(stderr, "MacVoxel: oidnNewMetalDevice returned null\n");
            return NO;
        }
        oidnCommitDevice(_oidnDevice);
        const char* derr = nullptr;
        if (oidnGetDeviceError(_oidnDevice, &derr) != OIDN_ERROR_NONE) {
            fprintf(stderr, "MacVoxel: OIDN device error: %s\n",
                    derr ? derr : "(none)");
            oidnReleaseDevice(_oidnDevice);
            _oidnDevice = nullptr;
            return NO;
        }
    }

    // 1. Pack accum + AOVs into the OIDN input buffers.
    {
        id<MTLCommandBuffer> cmd = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:_aovResolveCompute];
        [enc setTexture:_accumTexture atIndex:0];
        [enc setTexture:_aovAlbedo atIndex:1];
        [enc setTexture:_aovNormal atIndex:2];
        [enc setBuffer:_dnColor offset:0 atIndex:0];
        [enc setBuffer:_dnAlbedo offset:0 atIndex:1];
        [enc setBuffer:_dnNormal offset:0 atIndex:2];
        AovResolveUniforms ru;
        ru.width = static_cast<uint32_t>(w);
        ru.height = static_cast<uint32_t>(h);
        ru.sample_count = _sampleCount;
        [enc setBytes:&ru length:sizeof(ru) atIndex:3];
        const MTLSize tg = MTLSizeMake(8, 8, 1);
        const MTLSize groups = MTLSizeMake((w + 7) / 8, (h + 7) / 8, 1);
        [enc dispatchThreadgroups:groups threadsPerThreadgroup:tg];
        [enc endEncoding];
        [cmd commit];
        [cmd waitUntilCompleted];
    }

    // 2. Denoise. cleanAux=true: our albedo/normal are noise-free, so OIDN
    //    skips aux prefiltering (faster + sharper). FLOAT3 over a 16-byte
    //    pixel stride reads rgb from each packed float4.
    OIDNBuffer cb = oidnNewSharedBufferFromMetal(_oidnDevice, _dnColor);
    OIDNBuffer ab = oidnNewSharedBufferFromMetal(_oidnDevice, _dnAlbedo);
    OIDNBuffer nb = oidnNewSharedBufferFromMetal(_oidnDevice, _dnNormal);
    OIDNBuffer ob = oidnNewSharedBufferFromMetal(_oidnDevice, _dnOutput);
    OIDNFilter f = oidnNewFilter(_oidnDevice, "RT");
    const size_t pxStride = 4 * sizeof(float);
    const size_t rowStride = static_cast<size_t>(w) * pxStride;
    oidnSetFilterImage(f, "color",  cb, OIDN_FORMAT_FLOAT3, w, h, 0, pxStride, rowStride);
    oidnSetFilterImage(f, "albedo", ab, OIDN_FORMAT_FLOAT3, w, h, 0, pxStride, rowStride);
    oidnSetFilterImage(f, "normal", nb, OIDN_FORMAT_FLOAT3, w, h, 0, pxStride, rowStride);
    oidnSetFilterImage(f, "output", ob, OIDN_FORMAT_FLOAT3, w, h, 0, pxStride, rowStride);
    oidnSetFilterBool(f, "hdr", true);
    oidnSetFilterBool(f, "cleanAux", true);
    oidnCommitFilter(f);
    oidnExecuteFilter(f);
    const char* ferr = nullptr;
    const OIDNError ec = oidnGetDeviceError(_oidnDevice, &ferr);
    oidnReleaseFilter(f);
    oidnReleaseBuffer(cb);
    oidnReleaseBuffer(ab);
    oidnReleaseBuffer(nb);
    oidnReleaseBuffer(ob);
    if (ec != OIDN_ERROR_NONE) {
        fprintf(stderr, "MacVoxel: OIDN filter error: %s\n", ferr ? ferr : "(none)");
        return NO;
    }

    // 3. Denoised buffer → texture for the existing tonemap pass.
    {
        id<MTLCommandBuffer> cmd = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        [blit copyFromBuffer:_dnOutput
                sourceOffset:0
           sourceBytesPerRow:rowStride
         sourceBytesPerImage:rowStride * h
                  sourceSize:MTLSizeMake(w, h, 1)
                   toTexture:_denoisedTex
            destinationSlice:0
            destinationLevel:0
           destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        [cmd commit];
        [cmd waitUntilCompleted];
    }
    return YES;
}

- (BOOL)exportPNGToURL:(NSURL*)url
          acesTonemap:(BOOL)acesTonemap
              denoise:(BOOL)denoise
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

    // Denoise into _denoisedTex (which is already a per-sample mean). On
    // failure we fall back to the raw accumulator so export never aborts.
    const BOOL denoised = denoise ? [self denoiseAccumulatedWithQueue:queue] : NO;
    if (denoise && !denoised) {
        fprintf(stderr, "MacVoxel: denoise failed; exporting un-denoised frame\n");
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
    // The denoised texture is already a mean; the raw accumulator is a sum
    // the tonemap divides by sample_count.
    du.sample_count = denoised ? 1u : _sampleCount;
    du.aces_tonemap = acesTonemap ? 1u : 0u;
    // Export target matches the accum exactly — no letterbox.
    du.region_w = 1.0f;
    du.region_h = 1.0f;
    du.ema_weight = 1.0f;   // export is one-shot; no history to blend
    // Export uses the direct pipeline (accum → tonemap → drawable),
    // bypassing the EMA history so the saved PNG is a deterministic
    // snapshot of the current accumulator state, independent of which
    // ping-pong texture was the "current" one when the user hit export.
    [enc setRenderPipelineState:_displayDirectPipeline];
    [enc setCullMode:MTLCullModeNone];
    [enc setFragmentBytes:&du length:sizeof(du) atIndex:0];
    [enc setFragmentTexture:(denoised ? _denoisedTex : _accumTexture) atIndex:0];
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

- (BOOL)exportAOVToURL:(NSURL*)url
                  kind:(NSInteger)kind
          commandQueue:(id<MTLCommandQueue>)queue
                 error:(NSError**)outError {
    id<MTLTexture> src = (kind == 0) ? _aovAlbedo : _aovNormal;
    if (src == nil || _aovResolvePipeline == nil) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"MacVoxelExport" code:1
                       userInfo:@{NSLocalizedDescriptionKey:
                                      @"nothing rendered yet"}];
        }
        return NO;
    }

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
    shot.label = @"PathTraceAOVExport";

    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    cmd.label = @"PathTraceAOVExport";

    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = shot;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc =
        [cmd renderCommandEncoderWithDescriptor:rpd];
    AovUniforms au;
    au.sample_count = _sampleCount;
    au.mode = (kind == 0) ? 0u : 1u;
    [enc setRenderPipelineState:_aovResolvePipeline];
    [enc setCullMode:MTLCullModeNone];
    [enc setFragmentBytes:&au length:sizeof(au) atIndex:0];
    [enc setFragmentTexture:src atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];

    [cmd commit];
    [cmd waitUntilCompleted];

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
