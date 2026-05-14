#import "MagicaRenderer.h"

#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "Camera.h"
#include "Document.h"
#include "EditorContext.h"
#include "Material.h"
#include "RenderState.h"
#include "VoxelGrid.h"

namespace {

// CPU-side mirror of MagicaUniforms (defined in Magica.metal). Members
// follow MSL alignment: vec3 is 16-aligned, vec4 is 16-aligned, scalars
// pack adjacently. The static_assert at the bottom validates layout.
struct MagicaUniforms {
    simd::float4x4 inv_vp;
    simd::float3 camera_pos;
    float _pad0;
    simd::int3 grid_min;          // tex_df origin in grid coords
    int _pad1;
    simd::int3 grid_dim;          // tex_df dimensions in cells
    int _pad2;
    simd::float3 sun_dir;         // grid-space unit vector
    float sun_cos_half_angle;
    simd::float3 sun_radiance;    // linear-space color × intensity
    float sky_intensity;
    simd::float3 sky_color;       // baseline constant sky tint (linear)
    float _pad3;

    uint32_t frame_seed;
    uint32_t max_bounces;
    uint32_t light_count;
    uint32_t stochastic_gi;       // 0 = no area-light NEE, 1 = NEE+MIS

    uint32_t glass_mode;
    uint32_t aces_tonemap;
    float    indirect_clamp_L;
    uint32_t _pad5;

    simd::float2 inv_screen_size;
    simd::float2 jitter_mult;
    simd::float4 lobes[8];
};
static_assert(sizeof(MagicaUniforms) % 16 == 0,
              "MagicaUniforms must be 16-byte aligned for MSL constant binding");

struct GpuMaterial {
    float type;
    float roughness;
    float metallic;
    float emission;
    float transparency;
    float ior;
    float _pad0;
    float _pad1;
};
static_assert(sizeof(GpuMaterial) == 32, "GpuMaterial size mismatch");

struct GpuLight {
    simd::float4 pos;  // .xyz = grid corner, .w = unused
    simd::float4 le;   // .xyz = linear-albedo × emission, .w = pdf
};
static_assert(sizeof(GpuLight) == 32, "GpuLight size mismatch");

struct DisplayUniforms {
    uint32_t sample_count;
    uint32_t aces_tonemap;
    float region_w;
    float region_h;
};

// 64-bit FNV-1a hash. Used to fingerprint camera + settings so we can
// detect changes that should reset accumulation without holding every
// field in a parallel "_last…" slot.
uint64_t Fnv1a(const void* data, size_t n, uint64_t seed = 14695981039346656037ull) {
    const uint8_t* p = static_cast<const uint8_t*>(data);
    uint64_t h = seed;
    for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ull; }
    return h;
}

uint64_t HashCameraState(const macvoxel::Camera& c) {
    // Pack into a plain float array — simd types carry alignment
    // padding bytes whose contents are unspecified by the language,
    // so hashing the struct directly would mix in stack garbage and
    // produce a fresh hash every frame even when the camera is
    // unchanged. Manifested as continuous accumulation resets in the
    // live view.
    const simd::float3 pos = c.Position();
    const simd::float4x4 view = c.ViewMatrix();
    float buf[3 + 16];
    buf[0] = pos.x; buf[1] = pos.y; buf[2] = pos.z;
    std::memcpy(&buf[3], &view, sizeof(view));
    return Fnv1a(buf, sizeof(buf));
}

uint64_t HashRenderSettings(const macvoxel::RenderSettings& rs) {
    struct {
        int max_bounces;
        int max_samples;
        uint8_t glass_mode;
        uint8_t aces;
        uint8_t stochastic_gi;
        uint8_t _pad;
        float sky_intensity;
        float sun_elev, sun_azim, sun_diam, sun_int;
        float sun_r, sun_g, sun_b;
    } s = {
        rs.max_bounces, rs.max_samples,
        static_cast<uint8_t>(rs.glass_mode),
        static_cast<uint8_t>(rs.aces_tonemap ? 1 : 0),
        static_cast<uint8_t>(rs.magica_stochastic_gi ? 1 : 0),
        0,
        rs.sky_intensity,
        rs.sun_elevation_deg, rs.sun_azimuth_deg,
        rs.sun_angular_diameter_deg, rs.sun_intensity,
        rs.sun_color[0], rs.sun_color[1], rs.sun_color[2],
    };
    return Fnv1a(&s, sizeof(s));
}

simd::float3 SrgbToLinear(uint8_t r, uint8_t g, uint8_t b) {
    auto c = [](uint8_t v) {
        const float f = v / 255.0f;
        return std::pow(f, 2.2f);
    };
    return simd::float3{c(r), c(g), c(b)};
}

simd::float3 SunDirGridSpace(float elev_deg, float azim_deg) {
    const float e = elev_deg * static_cast<float>(M_PI) / 180.0f;
    const float a = azim_deg * static_cast<float>(M_PI) / 180.0f;
    const float ce = std::cos(e), se = std::sin(e);
    // Grid axes: +X / +Y horizontal, +Z up.
    return simd::float3{ce * std::cos(a), ce * std::sin(a), se};
}

// Bake a per-cell skip-distance volume from the document grid.
//
// Magica's `tex_df` carries (palette_id, skip_distance) per cell. The
// skip distance is the number of cells the DDA can advance along the
// slowest axis before reaching a cell whose palette ID differs. For
// air cells, that's the distance to the nearest filled cell; for
// interior cells of a uniform run, the distance to the nearest
// different-id cell. Bounded by 255 (uint8 storage).
//
// Implementation: per-axis run scan. For each axis, walk every row
// counting how many consecutive cells share the same id, then for
// every cell in the run store min(distance_to_run_start,
// distance_to_run_end). Final skip = min over the three axes.
//
// One-shot O(N) bake. Not incremental — the dirty-chunk path can be a
// follow-up optimisation if rebuilds get expensive.
struct DfBake {
    std::vector<uint8_t> data;    // interleaved (id, skip) per cell
    simd::int3 origin;
    simd::int3 dim;
};

DfBake BakeDistanceField(const macvoxel::Document& doc) {
    const macvoxel::Bounds3 b = doc.grid.Bounds();
    DfBake out;
    if (b.empty()) {
        out.origin = {0, 0, 0};
        out.dim = {1, 1, 1};
        out.data.assign(2, 0);
        return out;
    }
    const int32_t mx = b.min_x, my = b.min_y, mz = b.min_z;
    const int32_t dx = b.size_x(), dy = b.size_y(), dz = b.size_z();
    out.origin = simd::int3{mx, my, mz};
    out.dim = simd::int3{dx, dy, dz};

    const size_t N = static_cast<size_t>(dx) * dy * dz;
    std::vector<uint8_t> id(N, 0);
    for (int32_t z = 0; z < dz; ++z)
    for (int32_t y = 0; y < dy; ++y)
    for (int32_t x = 0; x < dx; ++x) {
        const size_t i = static_cast<size_t>(x) +
                         static_cast<size_t>(dx) * (y + static_cast<size_t>(dy) * z);
        id[i] = doc.grid.Get(mx + x, my + y, mz + z);
    }

    // V1 ships with skip=1 (no DDA acceleration). The "obvious" per-
    // axis run-length scan over-estimates the safe DDA jump in mixed-
    // axis empty regions (a cell whose three axis-runs are long can
    // still be chebyshev-1 from a diagonal solid neighbour), so the
    // DDA would jump over thin features. Correct skip distances need
    // a 3D chebyshev distance transform — deferred. Using tex_df with
    // skip=1 still gives us cache-tight memory layout vs the
    // coarse+pool indirection in PathTraceRenderer, which is the
    // first half of the perf experiment.
    std::vector<uint8_t> skip(N, 1);

    out.data.resize(N * 2);
    for (size_t i = 0; i < N; ++i) {
        out.data[i * 2 + 0] = id[i];
        out.data[i * 2 + 1] = skip[i];
    }
    return out;
}

}  // namespace

@implementation MagicaRenderer {
    id<MTLDevice> _device;
    MTLPixelFormat _colorFormat;

    id<MTLRenderPipelineState> _pathPipeline;
    id<MTLRenderPipelineState> _displayPipeline;
    id<MTLRenderPipelineState> _displayDirectPipeline;

    id<MTLTexture> _accumTexture;
    CGSize _accumSize;
    id<MTLTexture> _dfTexture;
    id<MTLTexture> _noiseTexture;

    id<MTLBuffer> _paletteBuffer;
    id<MTLBuffer> _materialBuffer;
    id<MTLBuffer> _lightBuffer;
    uint32_t _lightCount;

    uint64_t _cachedGeometryVersion;
    uint64_t _cachedPaletteVersion;
    uint64_t _cachedMaterialVersion;
    BOOL _resourcesValid;
    simd::int3 _gridOrigin;
    simd::int3 _gridDim;

    uint32_t _sampleCount;
    BOOL _wantsClear;

    uint64_t _lastCameraHash;
    uint64_t _lastSettingsHash;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat {
    self = [super init];
    if (self == nil) return nil;
    _device = device;
    _colorFormat = colorFormat;
    _wantsClear = YES;

    NSURL* source_url = [NSBundle.mainBundle URLForResource:@"Magica"
                                              withExtension:@"metal"];
    if (source_url == nil) {
        std::fprintf(stderr, "MagicaRenderer: Magica.metal not in bundle\n");
        return nil;
    }
    NSError* err = nil;
    NSString* source = [NSString stringWithContentsOfURL:source_url
                                                encoding:NSUTF8StringEncoding
                                                   error:&err];
    if (source == nil) {
        std::fprintf(stderr, "MagicaRenderer: failed to load Magica.metal: %s\n",
                     [[err localizedDescription] UTF8String]);
        return nil;
    }
    id<MTLLibrary> lib = [device newLibraryWithSource:source
                                              options:nil
                                                error:&err];
    if (lib == nil) {
        std::fprintf(stderr, "MagicaRenderer: Magica.metal compile failure: %s\n",
                     [[err localizedDescription] UTF8String]);
        return nil;
    }

    id<MTLFunction> vfn = [lib newFunctionWithName:@"magica_vertex"];
    id<MTLFunction> pfn = [lib newFunctionWithName:@"magica_fragment"];
    id<MTLFunction> dfn = [lib newFunctionWithName:@"magica_display_fragment"];
    if (vfn == nil || pfn == nil || dfn == nil) {
        std::fprintf(stderr, "MagicaRenderer: missing Magica.metal functions\n");
        return nil;
    }

    {
        MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
        d.label = @"Magica Path-Trace";
        d.vertexFunction = vfn;
        d.fragmentFunction = pfn;
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
        _pathPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
        if (_pathPipeline == nil) {
            std::fprintf(stderr, "MagicaRenderer: PT pipeline: %s\n",
                         [[err localizedDescription] UTF8String]);
            return nil;
        }
    }
    {
        MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
        d.label = @"Magica Display";
        d.vertexFunction = vfn;
        d.fragmentFunction = dfn;
        d.colorAttachments[0].pixelFormat = colorFormat;
        _displayPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
        if (_displayPipeline == nil) {
            std::fprintf(stderr, "MagicaRenderer: display pipeline: %s\n",
                         [[err localizedDescription] UTF8String]);
            return nil;
        }
    }
    {
        // Headless / export uses BGRA8Unorm so PNG encode can read it
        // back. (Same convention as PathTraceRenderer's
        // _displayDirectPipeline.)
        MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
        d.label = @"Magica Display Direct";
        d.vertexFunction = vfn;
        d.fragmentFunction = dfn;
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        _displayDirectPipeline = [device newRenderPipelineStateWithDescriptor:d
                                                                        error:&err];
        if (_displayDirectPipeline == nil) {
            std::fprintf(stderr, "MagicaRenderer: direct display pipeline: %s\n",
                         [[err localizedDescription] UTF8String]);
            return nil;
        }
    }

    // 64×64 white noise texture, filled once. The shader samples this
    // with the per-pixel fragment coord as a seed so adjacent pixels
    // get decorrelated PRNG streams without per-pixel hash inline.
    {
        MTLTextureDescriptor* td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                              width:64
                                                             height:64
                                                          mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeManaged;
        _noiseTexture = [device newTextureWithDescriptor:td];
        std::vector<float> noise(64 * 64);
        uint32_t s = 0xDEADBEEFu;
        for (auto& f : noise) {
            s = s * 1664525u + 1013904223u;
            f = (s & 0xFFFFFF) / static_cast<float>(0x1000000);
        }
        [_noiseTexture replaceRegion:MTLRegionMake2D(0, 0, 64, 64)
                         mipmapLevel:0
                           withBytes:noise.data()
                         bytesPerRow:64 * sizeof(float)];
    }

    return self;
}

- (void)invalidate {
    _wantsClear = YES;
    _resourcesValid = NO;
}

- (uint32_t)sampleCount {
    return _sampleCount;
}

// ---------------------------------------------------------------------------
// Resource sync: rebuild tex_df / palette / materials / lights on dirty.
// ---------------------------------------------------------------------------

- (void)ensureAccumTextureForSize:(CGSize)size {
    if (_accumTexture != nil &&
        std::fabs(_accumSize.width - size.width) < 0.5 &&
        std::fabs(_accumSize.height - size.height) < 0.5) {
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
    _accumSize = size;
    _sampleCount = 0;
    _wantsClear = YES;
}

- (void)syncResourcesToDocument:(const macvoxel::EditorContext*)ctx {
    const macvoxel::Document& doc = ctx->document;
    const uint64_t gv = doc.geometry_version;
    const uint64_t pv = doc.palette_version;
    const uint64_t mv = doc.material_version;
    if (_resourcesValid &&
        gv == _cachedGeometryVersion &&
        pv == _cachedPaletteVersion &&
        mv == _cachedMaterialVersion) {
        return;
    }

    if (!_resourcesValid || gv != _cachedGeometryVersion) {
        DfBake bake = BakeDistanceField(doc);
        const NSUInteger dx = static_cast<NSUInteger>(bake.dim.x);
        const NSUInteger dy = static_cast<NSUInteger>(bake.dim.y);
        const NSUInteger dz = static_cast<NSUInteger>(bake.dim.z);
        MTLTextureDescriptor* td = [MTLTextureDescriptor new];
        td.textureType = MTLTextureType3D;
        td.pixelFormat = MTLPixelFormatRG8Uint;
        td.width = dx;
        td.height = dy;
        td.depth = dz;
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeManaged;
        _dfTexture = [_device newTextureWithDescriptor:td];
        [_dfTexture replaceRegion:MTLRegionMake3D(0, 0, 0, dx, dy, dz)
                      mipmapLevel:0
                            slice:0
                        withBytes:bake.data.data()
                      bytesPerRow:dx * 2
                    bytesPerImage:dx * dy * 2];
        _gridOrigin = bake.origin;
        _gridDim = bake.dim;
        _cachedGeometryVersion = gv;
    }

    if (!_resourcesValid || pv != _cachedPaletteVersion) {
        std::array<simd::float4, 256> pal;
        for (int i = 0; i < 256; ++i) {
            const macvoxel::Color c = doc.palette.Get(static_cast<uint8_t>(i));
            const simd::float3 lin = SrgbToLinear(c.r, c.g, c.b);
            pal[i] = simd::float4{lin.x, lin.y, lin.z, c.a / 255.0f};
        }
        _paletteBuffer = [_device newBufferWithBytes:pal.data()
                                              length:sizeof(pal)
                                             options:MTLResourceStorageModeShared];
        _cachedPaletteVersion = pv;
    }

    if (!_resourcesValid || mv != _cachedMaterialVersion) {
        std::array<GpuMaterial, 256> mats;
        for (int i = 0; i < 256; ++i) {
            const macvoxel::Material m = doc.palette.GetMaterial(static_cast<uint8_t>(i));
            mats[i].type = static_cast<float>(m.type);
            mats[i].roughness = m.roughness;
            mats[i].metallic = m.metallic;
            // Apply emissionPower as a multiplier so the user's UI
            // slider matches our PathTraceRenderer convention.
            const float emit_mult = std::pow(10.0f,
                static_cast<float>(std::max(0, m.emissionPower - 1)));
            mats[i].emission = m.emission * emit_mult;
            mats[i].transparency = m.transparency;
            mats[i].ior = m.ior;
            mats[i]._pad0 = mats[i]._pad1 = 0.0f;
        }
        _materialBuffer = [_device newBufferWithBytes:mats.data()
                                               length:sizeof(mats)
                                              options:MTLResourceStorageModeShared];
        _cachedMaterialVersion = mv;
    }

    // Light buffer: built on any of {geo, palette, material} dirty since
    // it's derived from all three.
    {
        std::vector<GpuLight> lights;
        constexpr uint32_t kCS = macvoxel::VoxelGrid::kChunkSize;
        for (const auto& kv : doc.grid.chunks()) {
            const macvoxel::VoxelGrid::Chunk* ch = kv.second.get();
            if (ch->filled_count == 0) continue;
            const int32_t bx = kv.first.x << macvoxel::VoxelGrid::kChunkBits;
            const int32_t by = kv.first.y << macvoxel::VoxelGrid::kChunkBits;
            const int32_t bz = kv.first.z << macvoxel::VoxelGrid::kChunkBits;
            for (uint32_t lz = 0; lz < kCS; ++lz)
            for (uint32_t ly = 0; ly < kCS; ++ly)
            for (uint32_t lx = 0; lx < kCS; ++lx) {
                const uint8_t pid = ch->cells[lx + ly * kCS + lz * kCS * kCS];
                if (pid == 0) continue;
                const macvoxel::Material m = doc.palette.GetMaterial(pid);
                if (m.type != macvoxel::MaterialType::Emissive ||
                    m.emission <= 0.0f) continue;
                const macvoxel::Color c = doc.palette.Get(pid);
                const simd::float3 alb = SrgbToLinear(c.r, c.g, c.b);
                const float emit_mult = std::pow(10.0f,
                    static_cast<float>(std::max(0, m.emissionPower - 1)));
                const float e = m.emission * emit_mult;
                GpuLight gl;
                gl.pos = simd::float4{
                    static_cast<float>(bx + static_cast<int32_t>(lx)),
                    static_cast<float>(by + static_cast<int32_t>(ly)),
                    static_cast<float>(bz + static_cast<int32_t>(lz)),
                    0.0f};
                gl.le = simd::float4{alb.x * e, alb.y * e, alb.z * e, 0.0f};
                lights.push_back(gl);
            }
        }
        _lightCount = static_cast<uint32_t>(lights.size());
        if (_lightCount > 0) {
            // Uniform per-light selection: probability = 1 / N.
            const float p = 1.0f / static_cast<float>(_lightCount);
            for (auto& gl : lights) gl.le.w = p;
            _lightBuffer = [_device newBufferWithBytes:lights.data()
                                                length:lights.size() * sizeof(GpuLight)
                                               options:MTLResourceStorageModeShared];
        } else {
            // 1-element placeholder so the shader's pointer is non-null;
            // the shader reads light_count == 0 and skips area NEE.
            GpuLight zero{};
            _lightBuffer = [_device newBufferWithBytes:&zero
                                                length:sizeof(GpuLight)
                                               options:MTLResourceStorageModeShared];
        }
    }

    _resourcesValid = YES;
    _wantsClear = YES;  // any resource rebuild invalidates accumulation
}

// ---------------------------------------------------------------------------
// Per-frame encode.
// ---------------------------------------------------------------------------

// Refresh the per-frame noise texture content. Matches Magica's
// behaviour of re-filling `tex_rand` each frame so successive
// accumulation samples take a different "view" of the cluster through
// correlated noise, instead of locking into a single tile pattern.
// White noise is what's expected from quasi-Sobol fill (which is what
// Magica uses) at the granularity of 64×64 — close enough for the
// splash aesthetic, much cheaper than generating Sobol on the CPU.
- (void)refreshNoiseForFrame:(uint32_t)frameSeed {
    constexpr NSUInteger N = 64;
    float buf[N * N];
    uint32_t s = frameSeed * 2654435761u + 0x9E3779B9u;
    for (NSUInteger i = 0; i < N * N; ++i) {
        s = s * 1664525u + 1013904223u;
        buf[i] = static_cast<float>(s & 0xFFFFFFu) / static_cast<float>(0x1000000);
    }
    [_noiseTexture replaceRegion:MTLRegionMake2D(0, 0, N, N)
                     mipmapLevel:0
                       withBytes:buf
                     bytesPerRow:N * sizeof(float)];
}

- (void)fillUniforms:(MagicaUniforms*)u
             context:(const macvoxel::EditorContext*)ctx
              camera:(const macvoxel::Camera&)camera
              aspect:(float)aspect
          baseSeed:(uint32_t)baseSeed {
    const macvoxel::RenderSettings& rs = ctx->render_settings;

    const simd::float4x4 view = camera.ViewMatrix();
    const simd::float4x4 proj = camera.ProjectionMatrix(aspect);
    const simd::float4x4 vp = simd_mul(proj, view);
    u->inv_vp = simd_inverse(vp);
    u->camera_pos = camera.Position();
    u->_pad0 = 0.0f;
    u->grid_min = _gridOrigin;
    u->_pad1 = 0;
    u->grid_dim = _gridDim;
    u->_pad2 = 0;

    u->sun_dir = SunDirGridSpace(rs.sun_elevation_deg, rs.sun_azimuth_deg);
    const float half_rad = (rs.sun_angular_diameter_deg * 0.5f) *
                           static_cast<float>(M_PI) / 180.0f;
    u->sun_cos_half_angle = std::cos(half_rad);
    const simd::float3 sun_lin = SrgbToLinear(
        static_cast<uint8_t>(std::clamp(rs.sun_color[0] * 255.0f, 0.0f, 255.0f)),
        static_cast<uint8_t>(std::clamp(rs.sun_color[1] * 255.0f, 0.0f, 255.0f)),
        static_cast<uint8_t>(std::clamp(rs.sun_color[2] * 255.0f, 0.0f, 255.0f)));
    u->sun_radiance = sun_lin * rs.sun_intensity;
    u->sky_intensity = rs.sky_intensity;
    // Same constant overcast tint PathTraceRenderer ships. Premultiplied
    // by sky_intensity on the CPU so the shader uses it as the linear
    // sky color directly.
    {
        const float k = std::max(0.0f, rs.sky_intensity);
        u->sky_color = simd::float3{0.65f * k, 0.75f * k, 0.95f * k};
    }
    u->_pad3 = 0.0f;

    u->frame_seed = baseSeed + _sampleCount + 1u;
    u->max_bounces = static_cast<uint32_t>(std::max(1, rs.max_bounces));
    u->light_count = _lightCount;
    u->stochastic_gi = rs.magica_stochastic_gi ? 1u : 0u;
    u->glass_mode = static_cast<uint32_t>(rs.glass_mode);
    u->aces_tonemap = rs.aces_tonemap ? 1u : 0u;
    u->indirect_clamp_L = rs.indirect_clamp_L;
    u->_pad5 = 0u;

    // Per-frame correlated-noise machinery. Mirrors Magica's set-up:
    // `lobes[bounce]` is a per-frame uniform 2D point (one per bounce),
    // `jitter_mult` is an irrational rotator (constant), and
    // `inv_screen_size` maps fragCoord into the tiled noise texture.
    const CGSize sz = _accumSize;
    u->inv_screen_size = simd::float2{
        sz.width > 0 ? 1.0f / static_cast<float>(sz.width) : 1.0f,
        sz.height > 0 ? 1.0f / static_cast<float>(sz.height) : 1.0f};
    u->jitter_mult = simd::float2{0.7548777f, 0.5698403f};
    const uint32_t fs = u->frame_seed;
    for (int b = 0; b < 8; ++b) {
        // Cheap quasi-uniform pair per (frame, bounce). Sobol would
        // converge faster — v2.
        uint32_t k = fs * 2654435761u + static_cast<uint32_t>(b);
        k ^= k >> 16; k *= 0x7feb352du;
        k ^= k >> 15; k *= 0x846ca68bu; k ^= k >> 16;
        const float x = static_cast<float>(k & 0xFFFFFFu) /
                        static_cast<float>(0x1000000);
        uint32_t k2 = k ^ 0x9E3779B9u;
        k2 ^= k2 >> 16; k2 *= 0x7feb352du;
        k2 ^= k2 >> 15; k2 *= 0x846ca68bu; k2 ^= k2 >> 16;
        const float y = static_cast<float>(k2 & 0xFFFFFFu) /
                        static_cast<float>(0x1000000);
        u->lobes[b] = simd::float4{x, y, 0.0f, 0.0f};
    }
}

- (void)renderInView:(MTKView*)view
                 cmd:(id<MTLCommandBuffer>)cmd
             context:(macvoxel::EditorContext*)ctx
              camera:(const macvoxel::Camera&)camera {
    if (ctx == nullptr) return;

    [self syncResourcesToDocument:ctx];

    const macvoxel::RenderSettings& rs = ctx->render_settings;
    const CGSize ds = view.drawableSize;
    CGSize accumSize;
    if (rs.resolution_match_window) {
        accumSize = ds;
    } else {
        accumSize = CGSizeMake(
            std::max(16, rs.render_width),
            std::max(16, rs.render_height));
    }
    [self ensureAccumTextureForSize:accumSize];

    // Reset triggers: camera change, settings change.
    const uint64_t ch = HashCameraState(camera);
    const uint64_t sh = HashRenderSettings(rs);
    if (ch != _lastCameraHash || sh != _lastSettingsHash) {
        _wantsClear = YES;
        _lastCameraHash = ch;
        _lastSettingsHash = sh;
    }

    if (_wantsClear) {
        _sampleCount = 0;
        _wantsClear = NO;
    }

    const uint32_t cap = static_cast<uint32_t>(std::max(1, rs.max_samples));
    const bool accumulating = _sampleCount < cap;

    if (accumulating) {
        [self refreshNoiseForFrame:(_sampleCount + 1u)];
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = _accumTexture;
        pass.colorAttachments[0].loadAction =
            (_sampleCount == 0 ? MTLLoadActionClear : MTLLoadActionLoad);
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc =
            [cmd renderCommandEncoderWithDescriptor:pass];
        enc.label = @"Magica PT";
        [enc setRenderPipelineState:_pathPipeline];

        MagicaUniforms u{};
        const float aspect = accumSize.height > 0
            ? static_cast<float>(accumSize.width / accumSize.height) : 1.0f;
        [self fillUniforms:&u context:ctx camera:camera aspect:aspect baseSeed:0];

        [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
        [enc setFragmentTexture:_dfTexture atIndex:0];
        [enc setFragmentTexture:_noiseTexture atIndex:1];
        [enc setFragmentBuffer:_paletteBuffer offset:0 atIndex:1];
        [enc setFragmentBuffer:_materialBuffer offset:0 atIndex:2];
        [enc setFragmentBuffer:_lightBuffer offset:0 atIndex:3];

        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];

        _sampleCount += 1;
        ctx->render_progress.sample_count = _sampleCount;
    }

    // Display pass: accum → drawable. Aspect-fit so the user can resize
    // the window without stretching a fixed-aspect render. Matches the
    // PathTraceRenderer convention.
    id<MTLDrawable> drawable = view.currentDrawable;
    if (drawable == nil) return;
    MTLRenderPassDescriptor* dpass =
        [MTLRenderPassDescriptor renderPassDescriptor];
    dpass.colorAttachments[0].texture = view.currentDrawable.texture;
    dpass.colorAttachments[0].loadAction = MTLLoadActionClear;
    dpass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    dpass.colorAttachments[0].storeAction = MTLStoreActionStore;

    float region_w = 1.0f, region_h = 1.0f;
    if (ds.width > 0 && ds.height > 0 &&
        accumSize.width > 0 && accumSize.height > 0) {
        const float ar_a = static_cast<float>(accumSize.width / accumSize.height);
        const float ar_d = static_cast<float>(ds.width / ds.height);
        if (ar_a > ar_d) {
            region_h = ar_d / ar_a;
        } else {
            region_w = ar_a / ar_d;
        }
    }

    id<MTLRenderCommandEncoder> denc =
        [cmd renderCommandEncoderWithDescriptor:dpass];
    denc.label = @"Magica Display";
    [denc setRenderPipelineState:_displayPipeline];
    DisplayUniforms du = {
        std::max<uint32_t>(1, _sampleCount),
        rs.aces_tonemap ? 1u : 0u,
        region_w, region_h
    };
    [denc setFragmentBytes:&du length:sizeof(du) atIndex:0];
    [denc setFragmentTexture:_accumTexture atIndex:0];
    [denc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [denc endEncoding];
}

// ---------------------------------------------------------------------------
// Headless render + export.
// ---------------------------------------------------------------------------

- (BOOL)renderHeadlessSamples:(uint32_t)samples
                      context:(macvoxel::EditorContext*)ctx
                       camera:(const macvoxel::Camera&)camera
                         size:(CGSize)size
                   maxBounces:(uint32_t)maxBounces
                     baseSeed:(uint32_t)baseSeed
                 commandQueue:(id<MTLCommandQueue>)queue
                        error:(NSError**)outError {
    (void)outError;
    [self syncResourcesToDocument:ctx];
    [self ensureAccumTextureForSize:size];

    _sampleCount = 0;
    _wantsClear = NO;

    macvoxel::RenderSettings& rs = ctx->render_settings;
    const int saved_bounces = rs.max_bounces;
    rs.max_bounces = static_cast<int>(maxBounces);

    const float aspect = size.height > 0
        ? static_cast<float>(size.width / size.height) : 1.0f;

    for (uint32_t i = 0; i < samples; ++i) {
        [self refreshNoiseForFrame:(baseSeed + i + 1u)];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        cb.label = @"Magica Headless Sample";
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = _accumTexture;
        pass.colorAttachments[0].loadAction =
            (_sampleCount == 0 ? MTLLoadActionClear : MTLLoadActionLoad);
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc =
            [cb renderCommandEncoderWithDescriptor:pass];
        [enc setRenderPipelineState:_pathPipeline];

        MagicaUniforms u{};
        [self fillUniforms:&u context:ctx camera:camera aspect:aspect baseSeed:baseSeed];

        [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
        [enc setFragmentTexture:_dfTexture atIndex:0];
        [enc setFragmentTexture:_noiseTexture atIndex:1];
        [enc setFragmentBuffer:_paletteBuffer offset:0 atIndex:1];
        [enc setFragmentBuffer:_materialBuffer offset:0 atIndex:2];
        [enc setFragmentBuffer:_lightBuffer offset:0 atIndex:3];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        _sampleCount += 1;
        ctx->render_progress.sample_count = _sampleCount;
    }

    rs.max_bounces = saved_bounces;
    return YES;
}

- (BOOL)exportPNGToURL:(NSURL*)url
          acesTonemap:(BOOL)acesTonemap
          commandQueue:(id<MTLCommandQueue>)queue
                 error:(NSError**)outError {
    if (_accumTexture == nil || _sampleCount == 0) {
        if (outError) *outError = [NSError errorWithDomain:@"MacVoxel" code:20
            userInfo:@{NSLocalizedDescriptionKey:
                @"Magica renderer has no samples to export."}];
        return NO;
    }
    const NSUInteger w = _accumTexture.width;
    const NSUInteger h = _accumTexture.height;
    MTLTextureDescriptor* td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                          width:w
                                                         height:h
                                                      mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> readback = [_device newTextureWithDescriptor:td];

    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = readback;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:_displayDirectPipeline];
    DisplayUniforms du = {
        _sampleCount,
        acesTonemap ? 1u : 0u,
        1.0f, 1.0f
    };
    [enc setFragmentBytes:&du length:sizeof(du) atIndex:0];
    [enc setFragmentTexture:_accumTexture atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];

    std::vector<uint8_t> pixels(w * h * 4);
    [readback getBytes:pixels.data()
           bytesPerRow:w * 4
            fromRegion:MTLRegionMake2D(0, 0, w, h)
           mipmapLevel:0];

    // BGRA → RGBA for PNG encode.
    for (size_t i = 0; i < pixels.size(); i += 4) {
        std::swap(pixels[i + 0], pixels[i + 2]);
    }

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx_ = CGBitmapContextCreate(
        pixels.data(), w, h, 8, w * 4, cs,
        static_cast<uint32_t>(kCGImageAlphaPremultipliedLast) |
        static_cast<uint32_t>(kCGBitmapByteOrder32Big));
    CGImageRef img = CGBitmapContextCreateImage(ctx_);
    CFURLRef cf_url = (__bridge CFURLRef)url;
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        cf_url, (CFStringRef)UTTypePNG.identifier, 1, nullptr);
    BOOL ok = NO;
    if (dst != nullptr) {
        CGImageDestinationAddImage(dst, img, nullptr);
        ok = CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CGImageRelease(img);
    CGContextRelease(ctx_);
    CGColorSpaceRelease(cs);
    if (!ok && outError) {
        *outError = [NSError errorWithDomain:@"MacVoxel" code:21
            userInfo:@{NSLocalizedDescriptionKey: @"PNG write failed."}];
    }
    return ok;
}

@end
