#import "RaycastRenderer.h"
#import "VolumeTexture.h"

#include "EditorContext.h"

#import <cstdio>
#include <array>
#include <cstdint>
#include <cstring>

#include "Document.h"

namespace {

struct Uniforms {
    // Camera basis for per-pixel ray reconstruction (world space). Built
    // from unit vectors instead of inverting P*V — see encodeWithEncoder.
    simd::float3 cam_right;  float cam_tan_half;  // tan(fov_y / 2)
    simd::float3 cam_up;     float cam_aspect;
    simd::float3 cam_fwd;    float _padfwd;
    simd::float3 camera_pos;
    float _pad0;
    simd::float3 light_dir;
    float _pad1;
    // Edit-volume bounds in cell coords. `box_min` is inclusive, `box_max`
    // is exclusive (e.g. EditVolume{x0=-128, x1=127} → box_min.x=-128,
    // box_max.x=128). Doubles as the doc texture's index space.
    simd::float3 box_min;
    float _pad2;
    simd::float3 box_max;
    float _pad3;
    // Preview-tex slot. When `preview_active != 0` the fragment
    // shader samples `preview_tex` for each cell after the doc lookup.
    int preview_active;
    // < 1.0 enables the "ghost" composite. 1.0 = opaque.
    float preview_alpha;
    // Lift slot. When `lift_active != 0`, non-zero cells of `tex_lift`
    // override the doc value at the same cell and get the selection
    // tint applied.
    int lift_active;
    int _pad4;
};

NSString* const kShaderSource = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct VertOut {
    float4 position [[position]];
    float2 ndc;
};

struct Uniforms {
    float3   cam_right;  float cam_tan_half;
    float3   cam_up;     float cam_aspect;
    float3   cam_fwd;    float _padfwd;
    float3   camera_pos;
    float    _pad0;
    float3   light_dir;
    float    _pad1;
    float3   box_min;
    float    _pad2;
    float3   box_max;
    float    _pad3;
    int      preview_active;
    float    preview_alpha;
    int      lift_active;
    int      _pad4;
};

// Fullscreen triangle covering NDC [-1, 1]² with one extra-large vertex
// past each corner; no vertex buffer needed.
vertex VertOut raycast_vertex(uint vid [[vertex_id]]) {
    float2 p;
    if (vid == 0)      p = float2(-1.0, -1.0);
    else if (vid == 1) p = float2( 3.0, -1.0);
    else               p = float2(-1.0,  3.0);
    VertOut o;
    o.position = float4(p, 0.0, 1.0);
    o.ndc = p;
    return o;
}

constexpr constant int kChunkBits = 4;
constexpr constant int kChunkSize = 1 << kChunkBits;
constexpr constant int kChunkMask = kChunkSize - 1;
constexpr constant int kMaxSteps = 1024;

float3 ray_to_axis_line(float3 ro, float3 rd, int axis, float a, float b) {
    float2 r_perp;
    float2 d_perp;
    float r_along, d_along;
    if (axis == 0) {
        r_perp = float2(ro.y, ro.z); d_perp = float2(rd.y, rd.z);
        r_along = ro.x; d_along = rd.x;
    } else if (axis == 1) {
        r_perp = float2(ro.x, ro.z); d_perp = float2(rd.x, rd.z);
        r_along = ro.y; d_along = rd.y;
    } else {
        r_perp = float2(ro.x, ro.y); d_perp = float2(rd.x, rd.y);
        r_along = ro.z; d_along = rd.z;
    }
    float denom = dot(d_perp, d_perp);
    if (denom < 1e-8) return float3(1e10, 0.0, 0.0);
    float t = dot(float2(a, b) - r_perp, d_perp) / denom;
    if (t < 0.0) return float3(1e10, 0.0, 0.0);
    float2 closest = r_perp + t * d_perp;
    return float3(length(closest - float2(a, b)),
                  t,
                  r_along + t * d_along);
}

float3 bbox_edges_color(float3 ro, float3 rd, float3 bg,
                        float3 box_min, float3 box_max) {
    float xs[2] = {box_min.x, box_max.x};
    float ys[2] = {box_min.y, box_max.y};
    float zs[2] = {box_min.z, box_max.z};
    float3 mid = (box_min + box_max) * 0.5;
    int nx = (ro.x < mid.x) ? 0 : 1;
    int ny = (ro.y < mid.y) ? 0 : 1;
    int nz = (ro.z < mid.z) ? 0 : 1;
    float strongest = 0.0;
    for (int i = 0; i < 2; ++i) {
        for (int j = 0; j < 2; ++j) {
            if (!(i == ny && j == nz)) {
                float3 ex = ray_to_axis_line(ro, rd, 0, ys[i], zs[j]);
                if (ex.z >= box_min.x && ex.z <= box_max.x) {
                    float w = max(0.18, ex.y * 0.0014);
                    strongest = max(strongest, 1.0 - smoothstep(w * 0.5, w, ex.x));
                }
            }
            if (!(i == nx && j == nz)) {
                float3 ey = ray_to_axis_line(ro, rd, 1, xs[i], zs[j]);
                if (ey.z >= box_min.y && ey.z <= box_max.y) {
                    float w = max(0.18, ey.y * 0.0014);
                    strongest = max(strongest, 1.0 - smoothstep(w * 0.5, w, ey.x));
                }
            }
            if (!(i == nx && j == ny)) {
                float3 ez = ray_to_axis_line(ro, rd, 2, xs[i], ys[j]);
                if (ez.z >= box_min.z && ez.z <= box_max.z) {
                    float w = max(0.18, ez.y * 0.0014);
                    strongest = max(strongest, 1.0 - smoothstep(w * 0.5, w, ez.x));
                }
            }
        }
    }
    if (strongest <= 0.0) return bg;
    return mix(bg, float3(0.6, 0.65, 0.75), strongest * 0.45);
}

fragment float4 raycast_fragment(
    VertOut in [[stage_in]],
    constant Uniforms& u [[buffer(0)]],
    constant float4* palette [[buffer(1)]],
    texture3d<uint, access::read> tex_a [[texture(0)]],
    texture3d<uint, access::read> doc_oracle [[texture(1)]],
    texture3d<uint, access::read> preview_tex [[texture(2)]],
    texture3d<uint, access::read> preview_oracle [[texture(3)]],
    texture3d<uint, access::read> preview_rem [[texture(4)]],
    texture3d<uint, access::read> preview_rem_oracle [[texture(5)]],
    texture3d<uint, access::read> tex_lift [[texture(6)]],
    texture3d<uint, access::read> lift_oracle [[texture(7)]])
{
    // Reconstruct world-space ray from the camera basis (no matrix
    // inverse): unit-scale vectors keep the direction precise even with a
    // far camera and our wide near/far range, which inv(P*V) did not.
    float3 ray_dir_world = normalize(
        u.cam_fwd +
        in.ndc.x * u.cam_aspect * u.cam_tan_half * u.cam_right +
        in.ndc.y * u.cam_tan_half * u.cam_up);
    float3 ray_origin_world = u.camera_pos;

    // World -> grid: invert the rotation R = (gx, gz, -gy).
    float3 ray_origin = float3(ray_origin_world.x, -ray_origin_world.z, ray_origin_world.y);
    float3 ray_dir   = float3(ray_dir_world.x,   -ray_dir_world.z,   ray_dir_world.y);
    float3 cam_origin = ray_origin;

    float3 aabb_min = u.box_min;
    float3 aabb_max = u.box_max;
    float3 inv_dir = 1.0 / ray_dir;
    float3 t1 = (aabb_min - ray_origin) * inv_dir;
    float3 t2 = (aabb_max - ray_origin) * inv_dir;
    float3 t_lo = min(t1, t2);
    float3 t_hi = max(t1, t2);
    float t_enter = max(max(t_lo.x, t_lo.y), t_lo.z);
    float t_exit  = min(min(t_hi.x, t_hi.y), t_hi.z);
    if (t_exit < 0.0 || t_enter > t_exit) {
        float3 bg = float3(0.118, 0.118, 0.18);
        return float4(bbox_edges_color(cam_origin, ray_dir, bg, u.box_min, u.box_max), 1.0);
    }
    float t_start = max(t_enter, 0.0);
    ray_origin = ray_origin + ray_dir * (t_start + 1e-4);

    int3 cell = int3(floor(ray_origin));
    int3 step_dir;
    step_dir.x = ray_dir.x > 0.0 ? 1 : (ray_dir.x < 0.0 ? -1 : 0);
    step_dir.y = ray_dir.y > 0.0 ? 1 : (ray_dir.y < 0.0 ? -1 : 0);
    step_dir.z = ray_dir.z > 0.0 ? 1 : (ray_dir.z < 0.0 ? -1 : 0);

    float3 t_max;
    t_max.x = step_dir.x == 0 ? INFINITY :
              (step_dir.x > 0 ? (float(cell.x + 1) - ray_origin.x) / ray_dir.x
                              : (ray_origin.x - float(cell.x))     / -ray_dir.x);
    t_max.y = step_dir.y == 0 ? INFINITY :
              (step_dir.y > 0 ? (float(cell.y + 1) - ray_origin.y) / ray_dir.y
                              : (ray_origin.y - float(cell.y))     / -ray_dir.y);
    t_max.z = step_dir.z == 0 ? INFINITY :
              (step_dir.z > 0 ? (float(cell.z + 1) - ray_origin.z) / ray_dir.z
                              : (ray_origin.z - float(cell.z))     / -ray_dir.z);

    float3 t_delta;
    t_delta.x = step_dir.x != 0 ? 1.0 / abs(ray_dir.x) : INFINITY;
    t_delta.y = step_dir.y != 0 ? 1.0 / abs(ray_dir.y) : INFINITY;
    t_delta.z = step_dir.z != 0 ? 1.0 / abs(ray_dir.z) : INFINITY;

    int last_axis = -1;

    bool ghost_active = (u.preview_active != 0) && (u.preview_alpha < 0.999);
    bool ghost_seen = false;
    bool skip_preview = false;
    float3 ghost_color = float3(0.0);

    int3 box_min_i = int3(int(u.box_min.x), int(u.box_min.y), int(u.box_min.z));
    int3 box_max_i = int3(int(u.box_max.x), int(u.box_max.y), int(u.box_max.z));
    int3 box_chunk_min = box_min_i >> int(kChunkBits);

    for (int s = 0; s < kMaxSteps; ++s) {
        int3 cell_local = cell - box_min_i;
        bool doc_in = (cell.x >= box_min_i.x && cell.x < box_max_i.x &&
                       cell.y >= box_min_i.y && cell.y < box_max_i.y &&
                       cell.z >= box_min_i.z && cell.z < box_max_i.z);
        int3 doc_chunk_c = cell >> int(kChunkBits);
        bool doc_chunk_empty = true;
        uint val_doc = 0u;
        int3 oracle_c = int3(0);
        if (doc_in) {
            oracle_c = doc_chunk_c - box_chunk_min;
            doc_chunk_empty = (doc_oracle.read(uint3(oracle_c)).r == 0u);
            if (!doc_chunk_empty) {
                val_doc = tex_a.read(uint3(cell_local)).r;
            }
        }
        // preview_rem hides doc cells during a Remove stroke.
        if (val_doc != 0u && u.preview_active != 0 &&
            preview_rem_oracle.read(uint3(oracle_c)).r != 0u &&
            preview_rem.read(uint3(cell_local)).r != 0u) {
            val_doc = 0u;
        }
        // Preview-tex (shape/face/generator/brush live preview).
        bool preview_chunk_empty = true;
        uint val_preview = 0u;
        if (u.preview_active != 0 && !skip_preview && doc_in) {
            preview_chunk_empty =
                (preview_oracle.read(uint3(oracle_c)).r == 0u);
            if (!preview_chunk_empty) {
                val_preview = preview_tex.read(uint3(cell_local)).r;
            }
        }
        // Lift texture (selection contents).
        bool lift_chunk_empty = true;
        uint val_lift = 0u;
        if (u.lift_active != 0 && doc_in) {
            lift_chunk_empty =
                (lift_oracle.read(uint3(oracle_c)).r == 0u);
            if (!lift_chunk_empty) {
                val_lift = tex_lift.read(uint3(cell_local)).r;
            }
        }

        if (!doc_in) {
            float3 bg = float3(0.118, 0.118, 0.18);
            float3 bg_edged = bbox_edges_color(cam_origin, ray_dir, bg, u.box_min, u.box_max);
            if (ghost_seen) {
                return float4(mix(bg_edged, ghost_color, u.preview_alpha), 1.0);
            }
            return float4(bg_edged, 1.0);
        }

        // Hit precedence: preview > lift > doc.
        if (val_preview != 0u) {
            float3 grid_normal = float3(0.0);
            if (last_axis == 0) grid_normal.x = -float(step_dir.x);
            else if (last_axis == 1) grid_normal.y = -float(step_dir.y);
            else if (last_axis == 2) grid_normal.z = -float(step_dir.z);
            float3 world_normal = float3(grid_normal.x, grid_normal.z, -grid_normal.y);
            float ndl = max(dot(world_normal, u.light_dir), 0.0);
            float lambert = 0.3 + 0.7 * ndl;
            float3 base = palette[val_preview].rgb;
            float3 preview_shaded = base * lambert;
            if (ghost_active) {
                ghost_color = preview_shaded;
                ghost_seen = true;
                skip_preview = true;
            } else {
                return float4(preview_shaded, 1.0);
            }
        }
        if (val_lift != 0u) {
            float3 grid_normal = float3(0.0);
            if (last_axis == 0) grid_normal.x = -float(step_dir.x);
            else if (last_axis == 1) grid_normal.y = -float(step_dir.y);
            else if (last_axis == 2) grid_normal.z = -float(step_dir.z);
            float3 world_normal = float3(grid_normal.x, grid_normal.z, -grid_normal.y);
            float ndl = max(dot(world_normal, u.light_dir), 0.0);
            float lambert = 0.3 + 0.7 * ndl;
            float3 base = palette[val_lift].rgb;
            float3 shaded = base * lambert;
            // Selection tint — warm yellow mix so lifted cells read
            // visually as "selected" while keeping the palette colour
            // legible.
            shaded = mix(shaded, float3(1.0, 0.9, 0.4) * lambert, 0.45);
            if (ghost_seen) {
                return float4(mix(shaded, ghost_color, u.preview_alpha), 1.0);
            }
            return float4(shaded, 1.0);
        }
        if (val_doc != 0u) {
            float3 grid_normal = float3(0.0);
            if (last_axis == 0) grid_normal.x = -float(step_dir.x);
            else if (last_axis == 1) grid_normal.y = -float(step_dir.y);
            else if (last_axis == 2) grid_normal.z = -float(step_dir.z);
            float3 world_normal = float3(grid_normal.x, grid_normal.z, -grid_normal.y);
            float ndl = max(dot(world_normal, u.light_dir), 0.0);
            float lambert = 0.3 + 0.7 * ndl;
            float3 base = palette[val_doc].rgb;
            float3 shaded = base * lambert;
            if (ghost_seen) {
                return float4(mix(shaded, ghost_color, u.preview_alpha), 1.0);
            }
            return float4(shaded, 1.0);
        }

        // No hit at this cell. If doc + preview + lift chunks are all
        // empty, coarse-skip to the next chunk boundary.
        if (doc_chunk_empty && preview_chunk_empty && lift_chunk_empty) {
            float3 chunk_min_doc = float3(doc_chunk_c) * float(kChunkSize);
            float3 chunk_max_doc = chunk_min_doc + float(kChunkSize);
            float3 exit_face = select(chunk_min_doc, chunk_max_doc, step_dir > 0);
            float3 t_face = (exit_face - ray_origin) * inv_dir;
            if (step_dir.x == 0) t_face.x = INFINITY;
            if (step_dir.y == 0) t_face.y = INFINITY;
            if (step_dir.z == 0) t_face.z = INFINITY;
            float t_exit_doc = min(min(t_face.x, t_face.y), t_face.z);
            int exit_axis = (t_face.x <= t_face.y && t_face.x <= t_face.z) ? 0
                          : (t_face.y <= t_face.z) ? 1 : 2;
            last_axis = exit_axis;

            float eps = max(1e-3, t_exit_doc * 1e-5);
            float3 pos = ray_origin + ray_dir * (t_exit_doc + eps);
            cell.x = int(floor(pos.x));
            cell.y = int(floor(pos.y));
            cell.z = int(floor(pos.z));
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
            continue;
        }

        if (t_max.x < t_max.y && t_max.x < t_max.z) {
            cell.x += step_dir.x;
            t_max.x += t_delta.x;
            last_axis = 0;
        } else if (t_max.y < t_max.z) {
            cell.y += step_dir.y;
            t_max.y += t_delta.y;
            last_axis = 1;
        } else {
            cell.z += step_dir.z;
            t_max.z += t_delta.z;
            last_axis = 2;
        }
    }
    float3 bg = float3(0.118, 0.118, 0.18);
    float3 bg_edged = bbox_edges_color(cam_origin, ray_dir, bg, u.box_min, u.box_max);
    if (ghost_seen) {
        return float4(mix(bg_edged, ghost_color, u.preview_alpha), 1.0);
    }
    return float4(bg_edged, 1.0);
}
)MSL";

}  // namespace

@implementation RaycastRenderer {
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLBuffer> _paletteBuffer;
    uint64_t _cachedPaletteVersion;
    BOOL _cacheValid;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   colorFormat:(MTLPixelFormat)colorFormat
                   depthFormat:(MTLPixelFormat)depthFormat {
    self = [super init];
    if (self == nil) return nil;
    _device = device;

    NSError* error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:kShaderSource
                                                   options:nil
                                                     error:&error];
    if (library == nil) {
        fprintf(stderr, "MacVoxel: failed to compile raycast shaders: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    id<MTLFunction> vfn = [library newFunctionWithName:@"raycast_vertex"];
    id<MTLFunction> ffn = [library newFunctionWithName:@"raycast_fragment"];

    MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.label = @"MacVoxel Raycast";
    desc.vertexFunction = vfn;
    desc.fragmentFunction = ffn;
    desc.colorAttachments[0].pixelFormat = colorFormat;
    desc.depthAttachmentPixelFormat = depthFormat;

    _pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (_pipeline == nil) {
        fprintf(stderr, "MacVoxel: failed to build raycast pipeline: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    return self;
}

- (uint32_t)lastChunkCount {
    return 0;
}

- (size_t)lastGPUBytes {
    return _paletteBuffer == nil ? 0 : _paletteBuffer.length;
}

- (void)invalidate {
    _cacheValid = NO;
    _paletteBuffer = nil;
    _cachedPaletteVersion = 0;
}

- (void)uploadPalette:(macvoxel::Document*)doc {
    std::array<simd::float4, 256> pal_floats{};
    for (size_t i = 0; i < 256; ++i) {
        const macvoxel::Color c = doc->palette.Get(static_cast<uint8_t>(i));
        pal_floats[i] = simd::float4{
            c.r / 255.0f, c.g / 255.0f, c.b / 255.0f, c.a / 255.0f,
        };
    }
    if (_paletteBuffer == nil) {
        _paletteBuffer =
            [_device newBufferWithBytes:pal_floats.data()
                                 length:sizeof(pal_floats)
                                options:MTLResourceStorageModeShared];
        _paletteBuffer.label = @"RaycastPalette";
        return;
    }
    std::memcpy(_paletteBuffer.contents, pal_floats.data(), sizeof(pal_floats));
}

- (void)encodeWithEncoder:(id<MTLRenderCommandEncoder>)encoder
                     view:(simd::float4x4)view
               projection:(simd::float4x4)projection
              cameraWorld:(simd::float3)cameraWorld
                  context:(macvoxel::EditorContext*)ctx
            volumeTexture:(VolumeTexture*)docVolumeTex {
    if (ctx == nullptr || docVolumeTex == nil) return;
    macvoxel::Document* doc = &ctx->document;
    if (_paletteBuffer == nil ||
        _cachedPaletteVersion != doc->palette_version) {
        [self uploadPalette:doc];
        _cachedPaletteVersion = doc->palette_version;
    }
    if (_paletteBuffer == nil) return;
    _cacheValid = YES;

    Uniforms u;
    // Extract the camera basis from the view matrix rows (R = [r; u; -f])
    // and the FOV/aspect from the projection, so per-pixel rays are built
    // from unit vectors rather than an ill-conditioned inverse of P*V.
    u.cam_right = simd::float3{view.columns[0].x, view.columns[1].x, view.columns[2].x};
    u.cam_up    = simd::float3{view.columns[0].y, view.columns[1].y, view.columns[2].y};
    u.cam_fwd   = simd::float3{-view.columns[0].z, -view.columns[1].z, -view.columns[2].z};
    u.cam_tan_half = 1.0f / projection.columns[1].y;
    u.cam_aspect   = projection.columns[1].y / projection.columns[0].x;
    u._padfwd = 0.0f;
    u.camera_pos = cameraWorld;
    u._pad0 = 0.0f;
    u.light_dir = simd::normalize(simd::float3{0.4f, 0.7f, 0.5f});
    u._pad1 = 0.0f;

    const macvoxel::EditVolume& vol = doc->volume;
    u.box_min = simd::float3{static_cast<float>(vol.x0),
                             static_cast<float>(vol.y0),
                             static_cast<float>(vol.z0)};
    u.box_max = simd::float3{static_cast<float>(vol.x1 + 1),
                             static_cast<float>(vol.y1 + 1),
                             static_cast<float>(vol.z1 + 1)};
    u._pad2 = 0.0f;
    u._pad3 = 0.0f;
    u.preview_active = ctx->preview_active ? 1 : 0;
    u.preview_alpha = ctx->preview_alpha;
    u.lift_active = ctx->selection.lift_active() ? 1 : 0;
    u._pad4 = 0;

    [encoder pushDebugGroup:@"Voxels (raycast)"];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [encoder setFragmentBuffer:_paletteBuffer offset:0 atIndex:1];
    [encoder setFragmentTexture:docVolumeTex.texture atIndex:0];
    [encoder setFragmentTexture:docVolumeTex.oracleTexture atIndex:1];
    [encoder setFragmentTexture:docVolumeTex.previewTexture atIndex:2];
    [encoder setFragmentTexture:docVolumeTex.previewOracleTexture atIndex:3];
    [encoder setFragmentTexture:docVolumeTex.previewRemTexture atIndex:4];
    [encoder setFragmentTexture:docVolumeTex.previewRemOracleTexture atIndex:5];
    [encoder setFragmentTexture:docVolumeTex.liftTexture atIndex:6];
    [encoder setFragmentTexture:docVolumeTex.liftOracleTexture atIndex:7];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:3];
    [encoder popDebugGroup];
}

@end
