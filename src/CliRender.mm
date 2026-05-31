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
    const char* aov_albedo = nullptr;  // optional first-hit albedo PNG dump
    const char* aov_normal = nullptr;  // optional first-hit normal PNG dump
    int width = 512;
    int height = 512;
    int samples = 64;
    int bounces = 5;
    uint32_t seed = 1;
    bool aces = true;
    bool denoise = false;  // --denoise: run OIDN over the result
    bool stochastic_gi = true;
    bool reference = false;  // --reference: PCG-only unbiased path
    bool override_sky_intensity = false;
    float sky_intensity = 1.0f;
    bool override_sun_intensity = false;
    float sun_intensity = 0.0f;
    bool override_clamp_L = false;
    float clamp_L = 8.0f;
    bool override_aperture = false;
    float aperture = 0.0f;
    bool override_focus = false;
    float focus = 30.0f;
    GlassMode glass_mode = GlassMode::Probabilistic;
};

void PrintUsage() {
    std::fprintf(stderr,
        "usage: MacVoxel render --input <file.vox> --output <file.png>\n"
        "                       [--width N] [--height N]\n"
        "                       [--samples N] [--bounces N] [--seed N]\n"
        "                       [--no-aces] [--denoise] [--no-stochastic-gi]\n"
        "                       [--reference]\n"
        "                       [--sky-intensity F] [--sun-intensity F]\n"
        "                       [--clamp-L F]\n"
        "                       [--aperture F] [--focus F]\n"
        "                       [--glass-mode probabilistic|absorption]\n"
        "                       [--aov-albedo <file.png>] [--aov-normal <file.png>]\n");
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
        } else if (eq("--denoise")) {
            out->denoise = true;
        } else if (eq("--no-stochastic-gi") || eq("--no-area-nee")) {
            // --no-area-nee accepted as a transitional alias.
            out->stochastic_gi = false;
        } else if (eq("--reference")) {
            out->reference = true;
        } else if (eq("--sky-intensity")) {
            const char* v = need_val("--sky-intensity"); if (!v) return false;
            out->sky_intensity = static_cast<float>(std::atof(v));
            out->override_sky_intensity = true;
        } else if (eq("--sun-intensity")) {
            const char* v = need_val("--sun-intensity"); if (!v) return false;
            out->sun_intensity = static_cast<float>(std::atof(v));
            out->override_sun_intensity = true;
        } else if (eq("--clamp-L")) {
            const char* v = need_val("--clamp-L"); if (!v) return false;
            out->clamp_L = static_cast<float>(std::atof(v));
            out->override_clamp_L = true;
        } else if (eq("--aperture")) {
            const char* v = need_val("--aperture"); if (!v) return false;
            out->aperture = static_cast<float>(std::atof(v));
            out->override_aperture = true;
        } else if (eq("--focus")) {
            const char* v = need_val("--focus"); if (!v) return false;
            out->focus = static_cast<float>(std::atof(v));
            out->override_focus = true;
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
        } else if (eq("--aov-albedo")) {
            const char* v = need_val("--aov-albedo"); if (!v) return false;
            out->aov_albedo = v;
        } else if (eq("--aov-normal")) {
            const char* v = need_val("--aov-normal"); if (!v) return false;
            out->aov_normal = v;
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

        // Device-create precedes LoadVox so EditorContext / Document
        // construction can attach Metal-backed members (Phase A2:
        // VoxelVolume's tex_a/tex_a_out).
        EditorContext ctx;
        Document& doc = ctx.document;
        std::string err;
        if (!LoadVox(args.input, &doc.grid, &doc.palette, &err)) {
            std::fprintf(stderr, "load failed: %s\n", err.c_str());
            return 1;
        }
        doc.ReseedVolumeShadow();
        doc.path = args.input;
        doc.BumpAll();

        if (doc.grid.empty()) {
            std::fprintf(stderr, "document has no voxels\n");
            return 1;
        }

        Camera camera;
        FitCameraToDocument(&camera, doc);

        // The path-trace pass reads glass_mode from ctx.render_settings;
        // the export pass takes aces_tonemap as an explicit parameter.
        ctx.render_settings.aces_tonemap = args.aces;
        ctx.render_settings.stochastic_gi = args.stochastic_gi;
        ctx.render_settings.path_trace_reference = args.reference;
        if (args.override_sky_intensity) {
            ctx.render_settings.sky_intensity = args.sky_intensity;
        }
        if (args.override_sun_intensity) {
            ctx.render_settings.sun_intensity = args.sun_intensity;
        }
        if (args.override_clamp_L) {
            ctx.render_settings.indirect_clamp_L = args.clamp_L;
        }
        if (args.override_aperture) {
            ctx.render_settings.aperture = args.aperture;
        }
        if (args.override_focus) {
            ctx.render_settings.focus_distance = args.focus;
        }
        ctx.render_settings.glass_mode = args.glass_mode;

        const CGSize size = CGSizeMake(static_cast<CGFloat>(args.width),
                                       static_cast<CGFloat>(args.height));

        std::fprintf(stderr,
            "rendering %s → %s  %dx%d  %d samples  %d bounces  seed=%u\n",
            args.input, args.output,
            args.width, args.height, args.samples, args.bounces, args.seed);

        NSError* nerr = nil;
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:args.output]];

        PathTraceRenderer* renderer =
            [[PathTraceRenderer alloc] initWithDevice:device
                                          colorFormat:MTLPixelFormatBGRA8Unorm];
        if (renderer == nil) {
            std::fprintf(stderr, "could not initialize path tracer\n");
            return 1;
        }
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
        if (![renderer exportPNGToURL:url
                          acesTonemap:args.aces ? YES : NO
                              denoise:args.denoise ? YES : NO
                         commandQueue:queue
                                error:&nerr]) {
            std::fprintf(stderr, "export failed: %s\n",
                [[nerr localizedDescription] UTF8String]);
            return 1;
        }
        std::fprintf(stderr, "wrote %s\n", args.output);

        if (args.aov_albedo != nullptr) {
            NSURL* aurl = [NSURL fileURLWithPath:
                [NSString stringWithUTF8String:args.aov_albedo]];
            if (![renderer exportAOVToURL:aurl kind:0
                             commandQueue:queue error:&nerr]) {
                std::fprintf(stderr, "albedo AOV export failed: %s\n",
                    [[nerr localizedDescription] UTF8String]);
                return 1;
            }
            std::fprintf(stderr, "wrote %s\n", args.aov_albedo);
        }
        if (args.aov_normal != nullptr) {
            NSURL* nurl = [NSURL fileURLWithPath:
                [NSString stringWithUTF8String:args.aov_normal]];
            if (![renderer exportAOVToURL:nurl kind:1
                             commandQueue:queue error:&nerr]) {
                std::fprintf(stderr, "normal AOV export failed: %s\n",
                    [[nerr localizedDescription] UTF8String]);
                return 1;
            }
            std::fprintf(stderr, "wrote %s\n", args.aov_normal);
        }
    }
    return 0;
}

}  // namespace macvoxel
