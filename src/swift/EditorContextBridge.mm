#import "EditorContextBridge.h"
#import "EditorContextBridge_Internal.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <array>
#include <cstdio>
#include <memory>
#include <random>
#include <string>
#include <utility>
#include <vector>

#include "Clipboard.h"
#include "Document.h"
#include "EditHistory.h"
#include "EditorContext.h"
#include "FloatingBuffer.h"
#include "FloatingBufferOps.h"
#include "GeneratorState.h"
#include "Generators.h"
#include "Palette.h"
#include "Selection.h"
#include "SelectionOps.h"
#include "VoxFile.h"
#include "VoxelGrid.h"

static macvoxel::Axis AxisFromBridge(BridgeAxis a) {
    switch (a) {
        case BridgeAxisX: return macvoxel::Axis::X;
        case BridgeAxisY: return macvoxel::Axis::Y;
        case BridgeAxisZ: return macvoxel::Axis::Z;
    }
    return macvoxel::Axis::X;
}

@implementation EditorContextBridge {
    std::unique_ptr<macvoxel::EditorContext> _ctx;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _ctx = std::make_unique<macvoxel::EditorContext>();
    [self seedDocumentFromDefault];
    _ctx->document.BumpAll();
    return self;
}

// Mirrors AppDelegate's seedDocumentFromDefault: load the bundled
// default.vox if available, otherwise drop a single seed voxel so the
// renderers have something to draw. Document path stays empty —
// "Untitled" until the user saves.
- (void)seedDocumentFromDefault {
    macvoxel::Document &doc = _ctx->document;
    NSString *path = [[NSBundle mainBundle] pathForResource:@"default"
                                                     ofType:@"vox"];
    if (path != nil) {
        const std::string p = [path UTF8String];
        std::string err;
        if (macvoxel::LoadVox(p, &doc.grid, &doc.palette, &err)) {
            return;
        }
        std::fprintf(stderr,
                     "MacVoxel: failed to load bundled default.vox (%s); "
                     "falling back to single-voxel seed\n",
                     err.c_str());
    }
    doc.grid.Clear();
    doc.grid.Set(0, 0, 0, 1);
    doc.palette.ResetToDefault();
}

- (macvoxel::EditorContext *)context {
    return _ctx.get();
}

- (NSString *)documentTitle {
    const std::string &p = _ctx->document.path;
    if (p.empty()) return @"Untitled";
    NSString *path = [NSString stringWithUTF8String:p.c_str()];
    return [path lastPathComponent];
}

- (NSString *)documentPath {
    const std::string &p = _ctx->document.path;
    if (p.empty()) return @"";
    return [NSString stringWithUTF8String:p.c_str()];
}

- (BOOL)hasDocumentPath {
    return !_ctx->document.path.empty();
}

// ---------------------------------------------------------------------------
// Document actions
// ---------------------------------------------------------------------------

- (void)newDocument {
    macvoxel::Document &doc = _ctx->document;
    // FloatingBuffer references the doc's grid; discard before replacing
    // (matches AppDelegate's invariant — see the original comment in
    // newDocument:).
    macvoxel::DiscardFloatingBuffer(*_ctx);
    [self seedDocumentFromDefault];
    doc.path.clear();
    doc.BumpAll();
    _ctx->history.Clear();
}

- (BOOL)openDocumentAtURL:(NSURL *)url error:(NSError **)error {
    if (url == nil) {
        if (error) *error = [NSError errorWithDomain:@"MacVoxel" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"No URL provided."}];
        return NO;
    }
    macvoxel::DiscardFloatingBuffer(*_ctx);
    const std::string path = [[url path] UTF8String];
    macvoxel::Document fresh;
    std::string err;
    if (!macvoxel::LoadVox(path, &fresh.grid, &fresh.palette, &err)) {
        if (error) {
            NSString *msg = [NSString stringWithUTF8String:err.c_str()];
            *error = [NSError errorWithDomain:@"MacVoxel" code:2
                userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }
    fresh.path = path;
    _ctx->document = std::move(fresh);
    _ctx->document.BumpAll();
    _ctx->history.Clear();
    [[NSDocumentController sharedDocumentController]
        noteNewRecentDocumentURL:url];
    return YES;
}

- (BOOL)saveDocumentToURL:(NSURL *)url error:(NSError **)error {
    if (url == nil) {
        if (error) *error = [NSError errorWithDomain:@"MacVoxel" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"No URL provided."}];
        return NO;
    }
    if (_ctx->floating_buffer.active) {
        macvoxel::CommitFloatingBuffer(*_ctx);
    }
    macvoxel::Document &doc = _ctx->document;
    const std::string path = [[url path] UTF8String];
    std::string err;
    if (!macvoxel::SaveVox(path, doc.grid, doc.palette, &err)) {
        if (error) {
            NSString *msg = [NSString stringWithUTF8String:err.c_str()];
            *error = [NSError errorWithDomain:@"MacVoxel" code:4
                userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }
    doc.path = path;
    [[NSDocumentController sharedDocumentController]
        noteNewRecentDocumentURL:url];
    return YES;
}

- (BOOL)saveDocumentInPlace:(NSError **)error {
    if (_ctx->document.path.empty()) {
        if (error) *error = [NSError errorWithDomain:@"MacVoxel" code:5
            userInfo:@{NSLocalizedDescriptionKey:
                @"Document has no on-disk path yet."}];
        return NO;
    }
    NSURL *url = [NSURL fileURLWithPath:
        [NSString stringWithUTF8String:_ctx->document.path.c_str()]];
    return [self saveDocumentToURL:url error:error];
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

- (BOOL)canUndo {
    if (_ctx->floating_buffer.active) return YES;  // undo cancels the lift
    return _ctx->history.CanUndo();
}

- (BOOL)canRedo {
    return _ctx->history.CanRedo();
}

- (void)undo {
    macvoxel::Document &doc = _ctx->document;
    macvoxel::FloatingBuffer &fb = _ctx->floating_buffer;
    if (fb.active) {
        // Undo while floating cancels the whole move-in-progress; we
        // restore from the buffer's source snapshot and pop nothing
        // from history (the lift didn't push an EditOp). Same logic
        // as AppDelegate's undo:.
        macvoxel::CancelFloatingLift(*_ctx);
        doc.BumpGeometry();
        return;
    }
    _ctx->history.Undo(doc, &_ctx->selection);
}

- (void)redo {
    _ctx->history.Redo(_ctx->document, &_ctx->selection);
}

// ---------------------------------------------------------------------------
// Selection-aware Edit menu
// ---------------------------------------------------------------------------

- (BOOL)canCutOrCopyOrDelete {
    const macvoxel::Selection &sel = _ctx->selection;
    const macvoxel::FloatingBuffer &fb = _ctx->floating_buffer;
    if (fb.active && !fb.grid.empty()) return YES;
    return sel.active() && !sel.empty();
}

- (BOOL)canPaste {
    return !_ctx->clipboard.empty();
}

- (BOOL)canDeselect {
    return _ctx->selection.active() || _ctx->floating_buffer.active;
}

- (void)copy {
    macvoxel::Document &doc = _ctx->document;
    macvoxel::Clipboard &cb = _ctx->clipboard;
    macvoxel::FloatingBuffer &fb = _ctx->floating_buffer;

    if (fb.active && !fb.grid.empty()) {
        const macvoxel::Bounds3 b = fb.grid.Bounds();
        cb.origin_x = b.min_x + fb.offset_x;
        cb.origin_y = b.min_y + fb.offset_y;
        cb.origin_z = b.min_z + fb.offset_z;
        cb.size_x = static_cast<uint32_t>(b.size_x());
        cb.size_y = static_cast<uint32_t>(b.size_y());
        cb.size_z = static_cast<uint32_t>(b.size_z());
        cb.cells.assign(
            static_cast<size_t>(cb.size_x) * cb.size_y * cb.size_z, 0);
        constexpr uint32_t kCS = macvoxel::VoxelGrid::kChunkSize;
        for (const auto &[coord, chunk] : fb.grid.chunks()) {
            if (chunk->filled_count == 0) continue;
            const int32_t base_x = coord.x * static_cast<int32_t>(kCS);
            const int32_t base_y = coord.y * static_cast<int32_t>(kCS);
            const int32_t base_z = coord.z * static_cast<int32_t>(kCS);
            for (uint32_t lz = 0; lz < kCS; ++lz)
            for (uint32_t ly = 0; ly < kCS; ++ly)
            for (uint32_t lx = 0; lx < kCS; ++lx) {
                const size_t idx = lx + ly * kCS + lz * kCS * kCS;
                const uint8_t pal = chunk->cells[idx];
                if (pal == 0) continue;
                const int32_t cx = base_x + static_cast<int32_t>(lx);
                const int32_t cy = base_y + static_cast<int32_t>(ly);
                const int32_t cz = base_z + static_cast<int32_t>(lz);
                cb.cells[cb.LinearIndex(
                    static_cast<uint32_t>(cx - b.min_x),
                    static_cast<uint32_t>(cy - b.min_y),
                    static_cast<uint32_t>(cz - b.min_z))] = pal;
            }
        }
        return;
    }

    const macvoxel::Selection &sel = _ctx->selection;
    if (!sel.active() || sel.empty()) return;
    const macvoxel::Bounds3 &sb = sel.bounds();
    cb.origin_x = sb.min_x;
    cb.origin_y = sb.min_y;
    cb.origin_z = sb.min_z;
    cb.size_x = static_cast<uint32_t>(sb.size_x());
    cb.size_y = static_cast<uint32_t>(sb.size_y());
    cb.size_z = static_cast<uint32_t>(sb.size_z());
    cb.cells.assign(
        static_cast<size_t>(cb.size_x) * cb.size_y * cb.size_z, 0);
    for (const auto &v : sel.voxels()) {
        const uint32_t lx = static_cast<uint32_t>(v[0] - sb.min_x);
        const uint32_t ly = static_cast<uint32_t>(v[1] - sb.min_y);
        const uint32_t lz = static_cast<uint32_t>(v[2] - sb.min_z);
        cb.cells[cb.LinearIndex(lx, ly, lz)] =
            doc.grid.Get(v[0], v[1], v[2]);
    }
}

- (void)cut {
    [self copy];
    [self deleteSelection];
}

- (void)deleteSelection {
    macvoxel::Document &doc = _ctx->document;
    macvoxel::FloatingBuffer &fb = _ctx->floating_buffer;
    if (fb.active) {
        // Floating cells aren't on the doc yet — discarding IS the
        // delete. The lift that produced this buffer stays on the
        // undo stack; one more Cmd-Z restores the pre-lift state.
        macvoxel::DiscardFloatingBuffer(*_ctx);
        doc.BumpGeometry();
        return;
    }
    const macvoxel::Selection &sel = _ctx->selection;
    if (!sel.active() || sel.empty()) return;
    macvoxel::EditHistory &history = _ctx->history;
    history.BeginOp();
    for (const auto &v : sel.voxels()) {
        const uint8_t old = doc.grid.Get(v[0], v[1], v[2]);
        if (old != 0) {
            doc.grid.Set(v[0], v[1], v[2], 0);
            history.Record(v[0], v[1], v[2], old, 0);
        }
    }
    history.CommitOp();
    doc.BumpGeometry();
}

- (void)paste {
    macvoxel::Document &doc = _ctx->document;
    const macvoxel::Clipboard &cb = _ctx->clipboard;
    if (cb.empty()) return;

    if (_ctx->floating_buffer.active) {
        macvoxel::CommitFloatingBuffer(*_ctx);
    }
    // Paste in place: land at the clipboard's recorded source origin.
    macvoxel::LiftClipboardToFloating(*_ctx, cb,
                                      cb.origin_x, cb.origin_y, cb.origin_z);
    doc.BumpGeometry();
}

- (void)deselect {
    // "Done with this selection" — drop any floating buffer onto the
    // document, then clear.
    if (_ctx->floating_buffer.active) {
        macvoxel::CommitFloatingBuffer(*_ctx);
    }
    _ctx->selection.Clear();
}

// ---------------------------------------------------------------------------
// Document stats
// ---------------------------------------------------------------------------

- (NSInteger)gridFilledCount {
    return static_cast<NSInteger>(_ctx->document.grid.FilledCount());
}

- (BOOL)gridIsEmpty {
    return _ctx->document.grid.Bounds().empty();
}

- (NSInteger)gridSizeX {
    return static_cast<NSInteger>(_ctx->document.grid.Bounds().size_x());
}

- (NSInteger)gridSizeY {
    return static_cast<NSInteger>(_ctx->document.grid.Bounds().size_y());
}

- (NSInteger)gridSizeZ {
    return static_cast<NSInteger>(_ctx->document.grid.Bounds().size_z());
}

- (void)rotateSelectionAxis:(BridgeAxis)axis clockwise:(BOOL)cw {
    macvoxel::RotateSelection(*_ctx, AxisFromBridge(axis), cw == YES);
}

- (void)flipSelectionAxis:(BridgeAxis)axis {
    macvoxel::FlipSelection(*_ctx, AxisFromBridge(axis));
}

// ---------------------------------------------------------------------------
// Generator panel state
// ---------------------------------------------------------------------------

- (BridgeGeneratorKind)generatorKind {
    return static_cast<BridgeGeneratorKind>(_ctx->generator.active_kind);
}

- (void)setGeneratorKind:(BridgeGeneratorKind)kind {
    _ctx->generator.active_kind =
        static_cast<macvoxel::generators::Kind>(kind);
}

- (BridgeAxis)generatorAxis {
    return static_cast<BridgeAxis>(_ctx->generator.params.axis);
}

- (void)setGeneratorAxis:(BridgeAxis)axis {
    _ctx->generator.params.axis = static_cast<uint32_t>(axis);
}

- (BOOL)generatorApexAtMax {
    return _ctx->generator.params.apex_at_max != 0;
}

- (void)setGeneratorApexAtMax:(BOOL)apex {
    _ctx->generator.params.apex_at_max = apex ? 1u : 0u;
}

- (float)generatorPerlinScale {
    return _ctx->generator.params.noise_scale;
}

- (void)setGeneratorPerlinScale:(float)scale {
    _ctx->generator.params.noise_scale = scale;
}

- (float)generatorPerlinThreshold {
    return _ctx->generator.params.noise_threshold;
}

- (void)setGeneratorPerlinThreshold:(float)threshold {
    _ctx->generator.params.noise_threshold = threshold;
}

- (NSInteger)generatorPerlinOctaves {
    return static_cast<NSInteger>(_ctx->generator.params.noise_octaves);
}

- (void)setGeneratorPerlinOctaves:(NSInteger)octaves {
    _ctx->generator.params.noise_octaves = static_cast<uint32_t>(octaves);
}

- (NSInteger)generatorPerlinSeed {
    return static_cast<NSInteger>(_ctx->generator.params.noise_seed);
}

- (void)setGeneratorPerlinSeed:(NSInteger)seed {
    _ctx->generator.params.noise_seed = static_cast<uint32_t>(seed);
}

- (float)generatorTorusTube {
    return _ctx->generator.params.torus_tube;
}

- (void)setGeneratorTorusTube:(float)tube {
    _ctx->generator.params.torus_tube = tube;
}

- (NSInteger)generatorPerlinPaletteLo {
    return static_cast<NSInteger>(_ctx->generator.params.perlin_palette_lo);
}

- (void)setGeneratorPerlinPaletteLo:(NSInteger)idx {
    _ctx->generator.params.perlin_palette_lo =
        static_cast<uint32_t>(std::clamp<NSInteger>(idx, 0, 255));
}

- (NSInteger)generatorPerlinPaletteHi {
    return static_cast<NSInteger>(_ctx->generator.params.perlin_palette_hi);
}

- (void)setGeneratorPerlinPaletteHi:(NSInteger)idx {
    _ctx->generator.params.perlin_palette_hi =
        static_cast<uint32_t>(std::clamp<NSInteger>(idx, 0, 255));
}

// ---------------------------------------------------------------------------
// Render settings
// ---------------------------------------------------------------------------

#define RS _ctx->render_settings

- (NSInteger)maxBounces { return RS.max_bounces; }
- (void)setMaxBounces:(NSInteger)v { RS.max_bounces = static_cast<int>(v); }

- (NSInteger)maxSamples { return RS.max_samples; }
- (void)setMaxSamples:(NSInteger)v { RS.max_samples = static_cast<int>(v); }

- (BOOL)pathTraced { return RS.path_traced; }
- (void)setPathTraced:(BOOL)v { RS.path_traced = (v == YES); }

- (BOOL)acesTonemap { return RS.aces_tonemap; }
- (void)setAcesTonemap:(BOOL)v { RS.aces_tonemap = (v == YES); }

- (BOOL)powerWeightedNEE { return RS.power_weighted_nee; }
- (void)setPowerWeightedNEE:(BOOL)v { RS.power_weighted_nee = (v == YES); }

- (BOOL)areaLightNEE { return RS.area_light_nee; }
- (void)setAreaLightNEE:(BOOL)v { RS.area_light_nee = (v == YES); }

- (BOOL)splashMode { return RS.splash_mode; }
- (void)setSplashMode:(BOOL)v { RS.splash_mode = (v == YES); }

- (float)indirectClampL { return RS.indirect_clamp_L; }
- (void)setIndirectClampL:(float)v { RS.indirect_clamp_L = v; }

- (float)splashJitter { return RS.splash_jitter; }
- (void)setSplashJitter:(float)v { RS.splash_jitter = v; }

- (NSInteger)splashTilePx { return RS.splash_tile_px; }
- (void)setSplashTilePx:(NSInteger)v { RS.splash_tile_px = static_cast<int>(v); }

- (float)emaFloor { return RS.ema_floor; }
- (void)setEmaFloor:(float)v { RS.ema_floor = v; }

- (BOOL)bloomEnabled { return RS.bloom_enabled; }
- (void)setBloomEnabled:(BOOL)v { RS.bloom_enabled = (v == YES); }

- (float)bloomIntensity { return RS.bloom_intensity; }
- (void)setBloomIntensity:(float)v { RS.bloom_intensity = v; }

- (float)bloomThreshold { return RS.bloom_threshold; }
- (void)setBloomThreshold:(float)v { RS.bloom_threshold = v; }

- (float)bloomRadiusLog0 { return RS.bloom_radius_log0; }
- (void)setBloomRadiusLog0:(float)v { RS.bloom_radius_log0 = v; }

- (float)bloomRadiusLog1 { return RS.bloom_radius_log1; }
- (void)setBloomRadiusLog1:(float)v { RS.bloom_radius_log1 = v; }

- (NSInteger)bloomNumSamples { return RS.bloom_num_samples; }
- (void)setBloomNumSamples:(NSInteger)v { RS.bloom_num_samples = static_cast<int>(v); }

- (NSInteger)neeRisCount { return RS.nee_ris_count; }
- (void)setNeeRisCount:(NSInteger)v { RS.nee_ris_count = static_cast<int>(v); }

- (BOOL)atmosphericSky { return RS.atmospheric_sky; }
- (void)setAtmosphericSky:(BOOL)v { RS.atmospheric_sky = (v == YES); }

- (float)skyIntensity { return RS.sky_intensity; }
- (void)setSkyIntensity:(float)v { RS.sky_intensity = v; }

- (float)horizonSoftnessDeg { return RS.horizon_softness_deg; }
- (void)setHorizonSoftnessDeg:(float)v { RS.horizon_softness_deg = v; }

- (float)sunElevationDeg { return RS.sun_elevation_deg; }
- (void)setSunElevationDeg:(float)v { RS.sun_elevation_deg = v; }

- (float)sunAzimuthDeg { return RS.sun_azimuth_deg; }
- (void)setSunAzimuthDeg:(float)v { RS.sun_azimuth_deg = v; }

- (float)sunAngularDiameterDeg { return RS.sun_angular_diameter_deg; }
- (void)setSunAngularDiameterDeg:(float)v { RS.sun_angular_diameter_deg = v; }

- (float)sunIntensity { return RS.sun_intensity; }
- (void)setSunIntensity:(float)v { RS.sun_intensity = v; }

- (float)sunColorR { return RS.sun_color[0]; }
- (void)setSunColorR:(float)v { RS.sun_color[0] = v; }
- (float)sunColorG { return RS.sun_color[1]; }
- (void)setSunColorG:(float)v { RS.sun_color[1] = v; }
- (float)sunColorB { return RS.sun_color[2]; }
- (void)setSunColorB:(float)v { RS.sun_color[2] = v; }

#undef RS

// ---------------------------------------------------------------------------
// Tool settings
// ---------------------------------------------------------------------------

#define TS _ctx->tool

- (BridgeToolKind)toolKind {
    return static_cast<BridgeToolKind>(TS.tool);
}
- (void)setToolKind:(BridgeToolKind)v {
    TS.tool = static_cast<macvoxel::ToolKind>(v);
}

- (BridgeToolMode)toolMode {
    return static_cast<BridgeToolMode>(TS.mode);
}
- (void)setToolMode:(BridgeToolMode)v {
    TS.mode = static_cast<macvoxel::ToolMode>(v);
}

- (NSInteger)brushSize { return TS.brush_size; }
- (void)setBrushSize:(NSInteger)v {
    if (v < 1) v = 1;
    if (v > 63) v = 63;
    TS.brush_size = static_cast<int>(v);
}

- (BridgeBrushShape)brushShape {
    return static_cast<BridgeBrushShape>(TS.brush_shape);
}
- (void)setBrushShape:(BridgeBrushShape)v {
    TS.brush_shape = static_cast<macvoxel::BrushShape>(v);
}

- (BOOL)brush3D { return TS.brush_3d; }
- (void)setBrush3D:(BOOL)v { TS.brush_3d = (v == YES); }

- (BridgeLineMode)lineMode {
    return static_cast<BridgeLineMode>(TS.line_mode);
}
- (void)setLineMode:(BridgeLineMode)v {
    TS.line_mode = static_cast<macvoxel::LineMode>(v);
}

- (BOOL)circleFill { return TS.circle_fill; }
- (void)setCircleFill:(BOOL)v { TS.circle_fill = (v == YES); }
- (BOOL)circleEven { return TS.circle_even; }
- (void)setCircleEven:(BOOL)v { TS.circle_even = (v == YES); }

- (BOOL)squareFill { return TS.square_fill; }
- (void)setSquareFill:(BOOL)v { TS.square_fill = (v == YES); }
- (BOOL)squareEven { return TS.square_even; }
- (void)setSquareEven:(BOOL)v { TS.square_even = (v == YES); }

- (BOOL)boxFill { return TS.box_fill; }
- (void)setBoxFill:(BOOL)v { TS.box_fill = (v == YES); }

- (BridgeFaceExtrudeKind)faceExtrude {
    return static_cast<BridgeFaceExtrudeKind>(TS.face_extrude);
}
- (void)setFaceExtrude:(BridgeFaceExtrudeKind)v {
    TS.face_extrude = static_cast<macvoxel::FaceExtrudeKind>(v);
}

- (BridgeFaceWithColor)faceWith {
    return static_cast<BridgeFaceWithColor>(TS.face_with);
}
- (void)setFaceWith:(BridgeFaceWithColor)v {
    TS.face_with = static_cast<macvoxel::FaceWithColor>(v);
}

- (BOOL)faceEightConnected { return TS.face_eight_connected; }
- (void)setFaceEightConnected:(BOOL)v {
    TS.face_eight_connected = (v == YES);
}

#undef TS

- (BridgeGlassMode)glassMode {
    return static_cast<BridgeGlassMode>(_ctx->render_settings.glass_mode);
}
- (void)setGlassMode:(BridgeGlassMode)v {
    _ctx->render_settings.glass_mode = static_cast<macvoxel::GlassMode>(v);
}

- (BOOL)resolutionMatchWindow {
    return _ctx->render_settings.resolution_match_window;
}
- (void)setResolutionMatchWindow:(BOOL)v {
    _ctx->render_settings.resolution_match_window = (v == YES);
}

- (NSInteger)renderWidth { return _ctx->render_settings.render_width; }
- (void)setRenderWidth:(NSInteger)v {
    _ctx->render_settings.render_width =
        static_cast<int>(std::max<NSInteger>(16, std::min<NSInteger>(v, 16384)));
}

- (NSInteger)renderHeight { return _ctx->render_settings.render_height; }
- (void)setRenderHeight:(NSInteger)v {
    _ctx->render_settings.render_height =
        static_cast<int>(std::max<NSInteger>(16, std::min<NSInteger>(v, 16384)));
}

- (NSInteger)sampleCount {
    return static_cast<NSInteger>(_ctx->render_progress.sample_count);
}

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------

- (NSInteger)paletteSize {
    return static_cast<NSInteger>(macvoxel::Palette::kSize);
}

- (NSInteger)activePaletteSlot {
    return _ctx->tool.palette_idx;
}

- (void)setActivePaletteSlot:(NSInteger)v {
    if (v < 0) v = 0;
    if (v > 255) v = 255;
    _ctx->tool.palette_idx = static_cast<uint8_t>(v);
}

- (uint32_t)paletteColorAt:(NSInteger)index {
    if (index < 0 || index >= 256) return 0;
    const macvoxel::Color c = _ctx->document.palette.Get(
        static_cast<uint8_t>(index));
    return (static_cast<uint32_t>(c.a) << 24) |
           (static_cast<uint32_t>(c.r) << 16) |
           (static_cast<uint32_t>(c.g) <<  8) |
            static_cast<uint32_t>(c.b);
}

- (void)setPaletteColorAt:(NSInteger)index
                        r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b a:(uint8_t)a {
    if (index <= 0 || index >= 256) return;  // skip empty slot
    _ctx->document.palette.Set(static_cast<uint8_t>(index),
                               macvoxel::Color{r, g, b, a});
    _ctx->document.BumpPalette();
}

- (BOOL)isPaletteSlotSelected:(NSInteger)index {
    if (index < 0 || index >= 256) return NO;
    return _ctx->tool.selected_slots.test(static_cast<size_t>(index)) ? YES : NO;
}

- (void)selectPaletteSlot:(NSInteger)index extend:(BOOL)extend {
    if (index < 0 || index >= 256) return;
    macvoxel::ToolSettings &t = _ctx->tool;
    if (!extend) {
        t.selected_slots.reset();
        t.selected_slots.set(static_cast<size_t>(index));
    } else {
        t.selected_slots.flip(static_cast<size_t>(index));
        if (!t.selected_slots.test(static_cast<size_t>(index)) &&
            t.selected_slots.count() == 0) {
            // Re-select to preserve the invariant that palette_idx is
            // a member of selected_slots when non-empty. Toggling the
            // only selected slot back off is a noop UX-wise.
            t.selected_slots.set(static_cast<size_t>(index));
        }
    }
    t.palette_idx = static_cast<uint8_t>(index);
}

- (void)beginPaletteEdit {
    auto &edit = _ctx->panel.palette_color_edit;
    if (edit.drag) return;  // already mid-drag
    edit.drag = true;
    edit.pre_idx = _ctx->tool.palette_idx;
    edit.pre = _ctx->document.palette.Get(_ctx->tool.palette_idx);
    _ctx->history.BeginOp();
}

- (void)applyPaletteColorR:(uint8_t)r g:(uint8_t)g b:(uint8_t)b a:(uint8_t)a {
    auto &edit = _ctx->panel.palette_color_edit;
    if (!edit.drag) return;
    const uint8_t idx = edit.pre_idx;
    if (idx == 0) return;  // empty slot is non-editable
    const macvoxel::Color nc{r, g, b, a};
    // Record against the captured pre snapshot so a continuous drag
    // collapses to a single (pre → final) undo entry per slot.
    // EditHistory coalesces per-slot writes within one Op.
    _ctx->document.palette.Set(idx, nc);
    _ctx->history.RecordPalette(idx, edit.pre, nc);
    _ctx->document.BumpPalette();
}

- (void)commitPaletteEdit {
    auto &edit = _ctx->panel.palette_color_edit;
    if (!edit.drag) return;
    _ctx->history.CommitOp();
    edit.drag = false;
}

// Grid layout helpers — row 0 is the top row (slots 249..256), row 31
// the bottom (slots 1..8). The top-right cell (col 7, row 0) is the
// empty-slot sentinel (index 0); SlotIndexAt clamps any other
// out-of-range mapping to 0 so wandering drag positions never produce
// a stray paintable slot.
static constexpr int kPaletteCols = 8;
static constexpr int kPaletteRows = 32;

static uint8_t SlotIndexAt(int col, int row) {
    const int n = (kPaletteRows - 1 - row) * kPaletteCols + col + 1;
    return n >= 256 ? uint8_t{0} : static_cast<uint8_t>(n);
}

// Anchor fixup shared by every right-click action: if the user
// right-clicked a slot that isn't part of the current selection,
// collapse the selection to just that slot. Mirrors the old ImGui
// "right-click replaces selection on miss" behavior — the
// SwiftUI .contextMenu has no onOpen hook, so each action runs the
// fixup itself before consulting selected_slots.
- (void)ensurePaletteAnchorInSelection:(NSInteger)anchor {
    if (anchor <= 0 || anchor >= 256) return;
    macvoxel::ToolSettings &t = _ctx->tool;
    const size_t a = static_cast<size_t>(anchor);
    if (!t.selected_slots.test(a)) {
        t.selected_slots.reset();
        t.selected_slots.set(a);
        t.palette_idx = static_cast<uint8_t>(anchor);
    }
}

- (void)selectPaletteRangeFromCol:(NSInteger)c0 row:(NSInteger)r0
                            toCol:(NSInteger)c1 row:(NSInteger)r1
                            shift:(BOOL)shift {
    const int min_c = static_cast<int>(std::min(c0, c1));
    const int max_c = static_cast<int>(std::max(c0, c1));
    const int min_r = static_cast<int>(std::min(r0, r1));
    const int max_r = static_cast<int>(std::max(r0, r1));
    macvoxel::ToolSettings &t = _ctx->tool;
    if (!shift) t.selected_slots.reset();
    for (int r = min_r; r <= max_r; ++r) {
        for (int c = min_c; c <= max_c; ++c) {
            const uint8_t i = SlotIndexAt(c, r);
            if (i == 0) continue;  // empty-corner sentinel
            if (shift) {
                t.selected_slots.flip(i);
            } else {
                t.selected_slots.set(i);
            }
        }
    }
    // Active slot follows the drag's end cell, ignoring the empty
    // corner so palette_idx never becomes 0.
    const uint8_t end = SlotIndexAt(static_cast<int>(c1),
                                    static_cast<int>(r1));
    if (end != 0) {
        t.palette_idx = end;
        t.selected_slots.set(end);
    }
}

- (BOOL)hasColorClipboard {
    return _ctx->panel.color_clipboard.has_value ? YES : NO;
}

- (BOOL)hasVoxelSelection {
    const macvoxel::Selection &sel = _ctx->selection;
    return (sel.active() && !sel.empty()) ? YES : NO;
}

- (NSInteger)effectiveSelectedSlotCountForAnchor:(NSInteger)anchor {
    if (anchor <= 0 || anchor >= 256) return 0;
    const macvoxel::ToolSettings &t = _ctx->tool;
    if (t.selected_slots.test(static_cast<size_t>(anchor))) {
        return static_cast<NSInteger>(t.selected_slots.count());
    }
    // Anchor will replace the selection at action time → effective
    // count is 1.
    return 1;
}

- (void)copyPaletteColorFrom:(NSInteger)slot {
    if (slot < 0 || slot >= 256) return;
    _ctx->panel.color_clipboard.color =
        _ctx->document.palette.Get(static_cast<uint8_t>(slot));
    _ctx->panel.color_clipboard.has_value = true;
}

- (void)pastePaletteColorAnchor:(NSInteger)anchor {
    if (!_ctx->panel.color_clipboard.has_value) return;
    [self ensurePaletteAnchorInSelection:anchor];
    const macvoxel::Color c = _ctx->panel.color_clipboard.color;
    macvoxel::EditHistory &hist = _ctx->history;
    hist.BeginOp();
    bool any = false;
    for (int i = 1; i < 256; ++i) {
        if (!_ctx->tool.selected_slots.test(i)) continue;
        const uint8_t slot = static_cast<uint8_t>(i);
        const macvoxel::Color old_c = _ctx->document.palette.Get(slot);
        if (!(old_c == c)) {
            _ctx->document.palette.Set(slot, c);
            hist.RecordPalette(slot, old_c, c);
            any = true;
        }
    }
    hist.CommitOp();
    if (any) _ctx->document.BumpPalette();
}

- (void)makePaletteGradientAnchor:(NSInteger)anchor {
    [self ensurePaletteAnchorInSelection:anchor];
    const std::bitset<256> &sel = _ctx->tool.selected_slots;
    // Lowest- and highest-index selected slots define the endpoints;
    // every selected slot in between gets the lerped color at its
    // index-parametric position. Unselected indices in the gap are
    // left alone — the selection is the gradient stops.
    int lo = -1, hi = -1;
    for (int i = 1; i < 256; ++i) {
        if (sel.test(i)) {
            if (lo < 0) lo = i;
            hi = i;
        }
    }
    if (lo < 0 || hi - lo < 2) return;  // need ≥1 interior slot
    const macvoxel::Color c0 =
        _ctx->document.palette.Get(static_cast<uint8_t>(lo));
    const macvoxel::Color c1 =
        _ctx->document.palette.Get(static_cast<uint8_t>(hi));
    const float span = static_cast<float>(hi - lo);
    macvoxel::EditHistory &hist = _ctx->history;
    hist.BeginOp();
    bool any = false;
    for (int i = lo + 1; i < hi; ++i) {
        if (!sel.test(i)) continue;
        const float t = (i - lo) / span;
        macvoxel::Color nc;
        nc.r = static_cast<uint8_t>(c0.r + (c1.r - c0.r) * t + 0.5f);
        nc.g = static_cast<uint8_t>(c0.g + (c1.g - c0.g) * t + 0.5f);
        nc.b = static_cast<uint8_t>(c0.b + (c1.b - c0.b) * t + 0.5f);
        nc.a = static_cast<uint8_t>(c0.a + (c1.a - c0.a) * t + 0.5f);
        const uint8_t slot = static_cast<uint8_t>(i);
        const macvoxel::Color old_c = _ctx->document.palette.Get(slot);
        if (!(old_c == nc)) {
            _ctx->document.palette.Set(slot, nc);
            hist.RecordPalette(slot, old_c, nc);
            any = true;
        }
    }
    hist.CommitOp();
    if (any) _ctx->document.BumpPalette();
}

- (void)selectVoxelsByColorAnchor:(NSInteger)anchor {
    [self ensurePaletteAnchorInSelection:anchor];
    const std::bitset<256> &sel = _ctx->tool.selected_slots;
    const macvoxel::VoxelGrid &grid = _ctx->document.grid;
    std::vector<std::array<int32_t, 3>> matched;
    constexpr uint32_t kCS = macvoxel::VoxelGrid::kChunkSize;
    for (const auto &kv : grid.chunks()) {
        const macvoxel::VoxelGrid::Chunk *ch = kv.second.get();
        if (ch->filled_count == 0) continue;
        const int32_t base_x = kv.first.x << macvoxel::VoxelGrid::kChunkBits;
        const int32_t base_y = kv.first.y << macvoxel::VoxelGrid::kChunkBits;
        const int32_t base_z = kv.first.z << macvoxel::VoxelGrid::kChunkBits;
        for (uint32_t lz = 0; lz < kCS; ++lz) {
            for (uint32_t ly = 0; ly < kCS; ++ly) {
                for (uint32_t lx = 0; lx < kCS; ++lx) {
                    const uint8_t v = ch->cells[
                        lx + ly * kCS + lz * kCS * kCS];
                    if (v == 0 || !sel.test(v)) continue;
                    matched.push_back({
                        base_x + static_cast<int32_t>(lx),
                        base_y + static_cast<int32_t>(ly),
                        base_z + static_cast<int32_t>(lz)});
                }
            }
        }
    }
    _ctx->selection.SetVoxels(std::move(matched));
}

// Shared painter for the two voxel-paint context-menu items. `choose`
// returns the palette index to write per voxel; called once per
// non-empty voxel in the selection.
template <class Choose>
static void PaintSelectedVoxels(macvoxel::EditorContext &ctx, Choose choose) {
    macvoxel::Selection &sel = ctx.selection;
    if (!sel.active() || sel.empty()) return;
    macvoxel::Document &doc = ctx.document;
    macvoxel::EditHistory &hist = ctx.history;
    hist.BeginOp();
    bool any = false;
    for (const auto &v : sel.voxels()) {
        const uint8_t old = doc.grid.Get(v[0], v[1], v[2]);
        if (old == 0) continue;  // empty cells aren't "voxels"
        const uint8_t nv = choose();
        if (nv == 0 || nv == old) continue;
        doc.grid.Set(v[0], v[1], v[2], nv);
        hist.Record(v[0], v[1], v[2], old, nv);
        any = true;
    }
    hist.CommitOp();
    if (any) doc.BumpGeometry();
}

- (void)paintSelectedVoxelsWithColorAnchor:(NSInteger)anchor {
    [self ensurePaletteAnchorInSelection:anchor];
    // Single-slot path: collect the one selected slot. Bail if the
    // selection somehow holds 0 or >1 entries — the menu predicate
    // shouldn't have enabled the item in that case.
    const std::bitset<256> &sel = _ctx->tool.selected_slots;
    if (sel.count() != 1) return;
    uint8_t pick = 0;
    for (int i = 1; i < 256; ++i) {
        if (sel.test(i)) { pick = static_cast<uint8_t>(i); break; }
    }
    PaintSelectedVoxels(*_ctx, [pick] { return pick; });
}

- (void)paintSelectedVoxelsWithRandomColorsAnchor:(NSInteger)anchor {
    [self ensurePaletteAnchorInSelection:anchor];
    const std::bitset<256> &sel = _ctx->tool.selected_slots;
    if (sel.count() < 2) return;
    std::vector<uint8_t> palette_idx;
    palette_idx.reserve(sel.count());
    for (int i = 1; i < 256; ++i) {
        if (sel.test(i)) palette_idx.push_back(static_cast<uint8_t>(i));
    }
    std::mt19937 rng{std::random_device{}()};
    std::uniform_int_distribution<size_t> dist(0, palette_idx.size() - 1);
    PaintSelectedVoxels(*_ctx, [&] { return palette_idx[dist(rng)]; });
}

// ---------------------------------------------------------------------------
// Material editor
// ---------------------------------------------------------------------------

- (BridgeMaterialType)activeMaterialType {
    return static_cast<BridgeMaterialType>(
        _ctx->document.palette.GetMaterial(_ctx->tool.palette_idx).type);
}
- (float)activeMaterialRoughness {
    return _ctx->document.palette.GetMaterial(_ctx->tool.palette_idx).roughness;
}
- (float)activeMaterialMetallic {
    return _ctx->document.palette.GetMaterial(_ctx->tool.palette_idx).metallic;
}
- (float)activeMaterialEmission {
    return _ctx->document.palette.GetMaterial(_ctx->tool.palette_idx).emission;
}
- (NSInteger)activeMaterialEmissionPower {
    return _ctx->document.palette.GetMaterial(_ctx->tool.palette_idx).emissionPower;
}
- (float)activeMaterialTransparency {
    return _ctx->document.palette.GetMaterial(_ctx->tool.palette_idx).transparency;
}
- (float)activeMaterialIor {
    return _ctx->document.palette.GetMaterial(_ctx->tool.palette_idx).ior;
}

- (NSInteger)selectedSlotCount {
    return static_cast<NSInteger>(_ctx->tool.selected_slots.count());
}

- (void)beginMaterialEdit {
    auto &me = _ctx->panel.material_edit;
    if (me.drag) return;
    me.drag = true;
    for (auto &v : me.pre) v.reset();
    macvoxel::ToolSettings &tool = _ctx->tool;
    for (size_t i = 1; i < tool.selected_slots.size(); ++i) {
        if (tool.selected_slots.test(i)) {
            me.pre[i] = _ctx->document.palette.GetMaterial(
                static_cast<uint8_t>(i));
        }
    }
    const uint8_t aidx = tool.palette_idx;
    if (aidx != 0 && !me.pre[aidx].has_value()) {
        me.pre[aidx] = _ctx->document.palette.GetMaterial(aidx);
    }
    _ctx->history.BeginOp();
}

- (void)applyMaterialChange:(void(NS_NOESCAPE ^)(macvoxel::Material &))mutator {
    auto &me = _ctx->panel.material_edit;
    if (!me.drag) return;
    macvoxel::ToolSettings &tool = _ctx->tool;
    auto apply_to = [&](uint8_t s) {
        if (!me.pre[s].has_value()) return;
        macvoxel::Material m = _ctx->document.palette.GetMaterial(s);
        mutator(m);
        _ctx->document.palette.SetMaterial(s, m);
        _ctx->history.RecordMaterial(s, *me.pre[s], m);
    };
    for (size_t i = 1; i < tool.selected_slots.size(); ++i) {
        if (tool.selected_slots.test(i)) {
            apply_to(static_cast<uint8_t>(i));
        }
    }
    if (tool.palette_idx != 0 &&
        !tool.selected_slots.test(static_cast<size_t>(tool.palette_idx))) {
        apply_to(tool.palette_idx);
    }
    _ctx->document.BumpMaterials();
}

- (void)applyMaterialType:(BridgeMaterialType)type {
    [self applyMaterialChange:^(macvoxel::Material &m) {
        m.type = static_cast<macvoxel::MaterialType>(type);
    }];
}
- (void)applyMaterialRoughness:(float)v {
    [self applyMaterialChange:^(macvoxel::Material &m) { m.roughness = v; }];
}
- (void)applyMaterialMetallic:(float)v {
    [self applyMaterialChange:^(macvoxel::Material &m) { m.metallic = v; }];
}
- (void)applyMaterialEmission:(float)v {
    [self applyMaterialChange:^(macvoxel::Material &m) { m.emission = v; }];
}
- (void)applyMaterialEmissionPower:(NSInteger)v {
    [self applyMaterialChange:^(macvoxel::Material &m) {
        m.emissionPower = static_cast<int>(v);
    }];
}
- (void)applyMaterialTransparency:(float)v {
    [self applyMaterialChange:^(macvoxel::Material &m) { m.transparency = v; }];
}
- (void)applyMaterialIor:(float)v {
    [self applyMaterialChange:^(macvoxel::Material &m) { m.ior = v; }];
}

- (void)commitMaterialEdit {
    auto &me = _ctx->panel.material_edit;
    if (!me.drag) return;
    _ctx->history.CommitOp();
    me.drag = false;
}

@end
