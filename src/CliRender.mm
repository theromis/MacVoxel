#import "CliRender.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "Camera.h"
#include "Document.h"
#include "EditorContext.h"
#include "PathTraceRenderer.h"
#include "RenderState.h"
#include "VoxFile.h"
#include "VoxelGrid.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace macvoxel {
namespace {

struct Args {
    const char* input = nullptr;
    const char* output = nullptr;
    int width = 512;
    int height = 512;
    int samples = 64;
    int bounces = 5;
    uint32_t seed = 1;
    bool aces = true;
    bool area_light_nee = true;
    bool splash_mode = false;
    bool override_splash_jitter = false;
    float splash_jitter = 0.0f;
    bool override_splash_tile_px = false;
    int splash_tile_px = 16;
    bool override_sky_intensity = false;
    float sky_intensity = 1.0f;
    bool override_sun_intensity = false;
    float sun_intensity = 0.0f;
    bool override_bloom_intensity = false;
    float bloom_intensity = 0.6f;
    bool override_bloom_threshold = false;
    float bloom_threshold = 1.0f;
    bool override_bloom_samples = false;
    int bloom_samples = 24;
    bool override_clamp_L = false;
    float clamp_L = 8.0f;
    GlassMode glass_mode = GlassMode::Probabilistic;
};

void PrintUsage() {
    std::fprintf(stderr,
        "usage: MacVoxel render --input <file.vox> --output <file.png>\n"
        "                       [--width N] [--height N]\n"
        "                       [--samples N] [--bounces N] [--seed N]\n"
        "                       [--no-aces] [--no-area-nee]\n"
        "                       [--sky-intensity F] [--sun-intensity F]\n"
        "                       [--splash-mode] [--splash-jitter F]\n"
        "                       [--splash-tile-px N] [--clamp-L F]\n"
        "                       [--glass-mode probabilistic|absorption]\n");
}

bool ParseArgs(int argc, const char* argv[], Args* out) {
    // argv[0] == "render"; flags start at argv[1].
    for (int i = 1; i < argc; ++i) {
        auto eq = [&](const char* tag) { return std::strcmp(argv[i], tag) == 0; };
        auto need_val = [&](const char* tag) -> const char* {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "missing value for %s\n", tag);
                return nullptr;
            }
            return argv[++i];
        };
        if (eq("--input")) {
            const char* v = need_val("--input"); if (!v) return false;
            out->input = v;
        } else if (eq("--output")) {
            const char* v = need_val("--output"); if (!v) return false;
            out->output = v;
        } else if (eq("--width")) {
            const char* v = need_val("--width"); if (!v) return false;
            out->width = std::atoi(v);
        } else if (eq("--height")) {
            const char* v = need_val("--height"); if (!v) return false;
            out->height = std::atoi(v);
        } else if (eq("--samples")) {
            const char* v = need_val("--samples"); if (!v) return false;
            out->samples = std::atoi(v);
        } else if (eq("--bounces")) {
            const char* v = need_val("--bounces"); if (!v) return false;
            out->bounces = std::atoi(v);
        } else if (eq("--seed")) {
            const char* v = need_val("--seed"); if (!v) return false;
            out->seed = static_cast<uint32_t>(std::strtoul(v, nullptr, 10));
        } else if (eq("--no-aces")) {
            out->aces = false;
        } else if (eq("--no-area-nee")) {
            out->area_light_nee = false;
        } else if (eq("--splash-mode")) {
            out->splash_mode = true;
        } else if (eq("--splash-jitter")) {
            const char* v = need_val("--splash-jitter"); if (!v) return false;
            out->splash_jitter = static_cast<float>(std::atof(v));
            out->override_splash_jitter = true;
        } else if (eq("--splash-tile-px")) {
            const char* v = need_val("--splash-tile-px"); if (!v) return false;
            out->splash_tile_px = std::atoi(v);
            out->override_splash_tile_px = true;
        } else if (eq("--sky-intensity")) {
            const char* v = need_val("--sky-intensity"); if (!v) return false;
            out->sky_intensity = static_cast<float>(std::atof(v));
            out->override_sky_intensity = true;
        } else if (eq("--sun-intensity")) {
            const char* v = need_val("--sun-intensity"); if (!v) return false;
            out->sun_intensity = static_cast<float>(std::atof(v));
            out->override_sun_intensity = true;
        } else if (eq("--bloom-intensity")) {
            const char* v = need_val("--bloom-intensity"); if (!v) return false;
            out->bloom_intensity = static_cast<float>(std::atof(v));
            out->override_bloom_intensity = true;
        } else if (eq("--bloom-threshold")) {
            const char* v = need_val("--bloom-threshold"); if (!v) return false;
            out->bloom_threshold = static_cast<float>(std::atof(v));
            out->override_bloom_threshold = true;
        } else if (eq("--bloom-samples")) {
            const char* v = need_val("--bloom-samples"); if (!v) return false;
            out->bloom_samples = std::atoi(v);
            out->override_bloom_samples = true;
        } else if (eq("--clamp-L")) {
            const char* v = need_val("--clamp-L"); if (!v) return false;
            out->clamp_L = static_cast<float>(std::atof(v));
            out->override_clamp_L = true;
        } else if (eq("--glass-mode")) {
            const char* v = need_val("--glass-mode"); if (!v) return false;
            if (std::strcmp(v, "probabilistic") == 0) {
                out->glass_mode = GlassMode::Probabilistic;
            } else if (std::strcmp(v, "absorption") == 0) {
                out->glass_mode = GlassMode::Absorption;
            } else {
                std::fprintf(stderr,
                    "--glass-mode must be 'probabilistic' or 'absorption'\n");
                return false;
            }
        } else if (eq("-h") || eq("--help")) {
            PrintUsage();
            return false;
        } else {
            std::fprintf(stderr, "unknown arg: %s\n", argv[i]);
            return false;
        }
    }
    if (out->input == nullptr || out->output == nullptr) {
        PrintUsage();
        return false;
    }
    if (out->width <= 0 || out->height <= 0 ||
        out->samples <= 0 || out->bounces < 0) {
        std::fprintf(stderr, "invalid numeric arg\n");
        return false;
    }
    return true;
}

// Match VoxelView's frameCameraToDocument: fit a ~30°/25° orbit camera
// to the document's grid bounds. Grid → world is (gx, gz, -gy).
void FitCameraToDocument(Camera* camera, const Document& doc) {
    const Bounds3 b = doc.grid.Bounds();
    simd::float3 target_world{0.0f, 0.0f, 0.0f};
    int32_t maxExtent = 1;
    if (!b.empty()) {
        const float gcx = (static_cast<float>(b.min_x) +
                           static_cast<float>(b.max_x) + 1.0f) * 0.5f;
        const float gcy = (static_cast<float>(b.min_y) +
                           static_cast<float>(b.max_y) + 1.0f) * 0.5f;
        const float gcz = (static_cast<float>(b.min_z) +
                           static_cast<float>(b.max_z) + 1.0f) * 0.5f;
        target_world = simd::float3{gcx, gcz, -gcy};
        maxExtent = std::max({b.size_x(), b.size_y(), b.size_z()});
    }
    camera->Frame(target_world, static_cast<float>(maxExtent));
}

}  // namespace

int RunCliRender(int argc, const char* argv[]) {
    Args args;
    if (!ParseArgs(argc, argv, &args)) return 2;

    EditorContext ctx;
    Document& doc = ctx.document;
    std::string err;
    if (!LoadVox(args.input, &doc.grid, &doc.palette, &err)) {
        std::fprintf(stderr, "load failed: %s\n", err.c_str());
        return 1;
    }
    doc.path = args.input;
    doc.BumpAll();

    if (doc.grid.empty()) {
        std::fprintf(stderr, "document has no voxels\n");
        return 1;
    }

    Camera camera;
    FitCameraToDocument(&camera, doc);

    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            std::fprintf(stderr, "no Metal device available\n");
            return 1;
        }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (queue == nil) {
            std::fprintf(stderr, "could not create Metal command queue\n");
            return 1;
        }

        // The path-trace pass reads glass_mode from ctx.render_settings;
        // the export pass takes aces_tonemap as an explicit parameter.
        ctx.render_settings.aces_tonemap = args.aces;
        ctx.render_settings.area_light_nee = args.area_light_nee;
        ctx.render_settings.splash_mode = args.splash_mode;
        if (args.override_splash_jitter) {
            ctx.render_settings.splash_jitter = args.splash_jitter;
        }
        if (args.override_splash_tile_px) {
            ctx.render_settings.splash_tile_px = args.splash_tile_px;
        }
        if (args.override_sky_intensity) {
            ctx.render_settings.sky_intensity = args.sky_intensity;
        }
        if (args.override_sun_intensity) {
            ctx.render_settings.sun_intensity = args.sun_intensity;
        }
        if (args.override_bloom_intensity) {
            ctx.render_settings.bloom_intensity = args.bloom_intensity;
            ctx.render_settings.bloom_enabled = args.bloom_intensity > 0.0f;
        }
        if (args.override_bloom_threshold) {
            ctx.render_settings.bloom_threshold = args.bloom_threshold;
        }
        if (args.override_bloom_samples) {
            ctx.render_settings.bloom_num_samples = args.bloom_samples;
        }
        if (args.override_clamp_L) {
            ctx.render_settings.indirect_clamp_L = args.clamp_L;
        }
        ctx.render_settings.glass_mode = args.glass_mode;

        PathTraceRenderer* renderer =
            [[PathTraceRenderer alloc] initWithDevice:device
                                          colorFormat:MTLPixelFormatBGRA8Unorm];
        if (renderer == nil) {
            std::fprintf(stderr, "could not initialize path tracer\n");
            return 1;
        }

        const CGSize size = CGSizeMake(static_cast<CGFloat>(args.width),
                                       static_cast<CGFloat>(args.height));

        std::fprintf(stderr,
            "rendering %s → %s  %dx%d  %d samples  %d bounces  seed=%u\n",
            args.input, args.output,
            args.width, args.height, args.samples, args.bounces, args.seed);

        NSError* nerr = nil;
        if (![renderer
                 renderHeadlessSamples:static_cast<uint32_t>(args.samples)
                               context:&ctx
                                camera:camera
                                  size:size
                            maxBounces:static_cast<uint32_t>(args.bounces)
                              baseSeed:args.seed
                          commandQueue:queue
                                 error:&nerr]) {
            std::fprintf(stderr, "render failed: %s\n",
                [[nerr localizedDescription] UTF8String]);
            return 1;
        }

        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:args.output]];
        const float bloom_for_export =
            (ctx.render_settings.bloom_enabled &&
             ctx.render_settings.bloom_intensity > 0.0f)
                ? ctx.render_settings.bloom_intensity
                : 0.0f;
        if (![renderer exportPNGToURL:url
                          acesTonemap:args.aces ? YES : NO
                       bloomIntensity:bloom_for_export
                         commandQueue:queue
                                error:&nerr]) {
            std::fprintf(stderr, "export failed: %s\n",
                [[nerr localizedDescription] UTF8String]);
            return 1;
        }
        std::fprintf(stderr, "wrote %s\n", args.output);
    }
    return 0;
}

}  // namespace macvoxel
