#import "EditorContextBridge.h"
#import "EditorContextBridge_Internal.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <cstdio>
#include <memory>
#include <string>
#include <utility>

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
