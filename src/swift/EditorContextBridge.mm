#import "EditorContextBridge.h"
#import "EditorContextBridge_Internal.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <array>
#include <cstdio>
#include <memory>
#include <random>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "CellKey.h"
#include "Clipboard.h"
#include "Document.h"
#include "EditHistory.h"
#include "EditorContext.h"
#include "EditEngine.h"
#include "SelectionLift.h"
#include "GeneratorState.h"
#include "Generators.h"
#include "MutatorState.h"
#include "Mutators.h"
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
        if (macvoxel::LoadVoxScene(p, &doc.scene, &doc.palette, &err)) {
            doc.EnsureSceneInWorld();
            doc.active_object = 0;
            doc.RebakeActiveObject();
            return;
        }
        std::fprintf(stderr,
                     "MacVoxel: failed to load bundled default.vox (%s); "
                     "falling back to single-voxel seed\n",
                     err.c_str());
    }
    doc.ClearCells();
    doc.SetCell(0, 0, 0, 1);
    doc.palette.ResetToDefault();
    doc.scene = macvoxel::Scene::FromSingleGrid(doc.grid);
    doc.active_object = 0;
    doc.RebakeActiveObject();
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
    // Any active lift references the outgoing doc; drop it (no
    // history entry — same intent as the old DiscardFloatingBuffer).
    if (_ctx->selection.lift_active()) {
        macvoxel::lift::CancelLift(*_ctx);
    }
    _ctx->selection.Clear();
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
    if (_ctx->selection.lift_active()) {
        macvoxel::lift::CancelLift(*_ctx);
    }
    _ctx->selection.Clear();
    const std::string path = [[url path] UTF8String];
    macvoxel::Document fresh;
    std::string err;
    if (!macvoxel::LoadVoxScene(path, &fresh.scene, &fresh.palette, &err)) {
        if (error) {
            NSString *msg = [NSString stringWithUTF8String:err.c_str()];
            *error = [NSError errorWithDomain:@"MacVoxel" code:2
                userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }
    fresh.path = path;
    _ctx->document = std::move(fresh);
    _ctx->document.EnsureSceneInWorld();
    _ctx->document.active_object = 0;
    _ctx->document.RebakeActiveObject();
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
    if (_ctx->selection.lift_active()) {
        macvoxel::lift::CommitLift(*_ctx);
    }
    macvoxel::Document &doc = _ctx->document;
    const std::string path = [[url path] UTF8String];
    std::string err;
    // Fold active-object edits back into its model, then write the
    // full scene graph.
    doc.SyncActiveModel();
    if (!macvoxel::SaveVoxScene(path, doc.scene, doc.palette, &err)) {
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
    if (_ctx->selection.lift_active()) return YES;  // undo cancels the lift
    return _ctx->history.CanUndo();
}

- (BOOL)canRedo {
    return _ctx->history.CanRedo();
}

- (void)undo {
    macvoxel::Document &doc = _ctx->document;
    if (_ctx->selection.lift_active()) {
        // Undo while lifted cancels the whole move-in-progress: we
        // restore from pre_lift_originals and pop nothing from history
        // (the lift didn't push an EditOp).
        macvoxel::lift::CancelLift(*_ctx);
        return;
    }
    _ctx->history.Undo(doc, &_ctx->selection);
    [self reconcileAfterHistory];
}

- (void)redo {
    _ctx->history.Redo(_ctx->document, &_ctx->selection);
    [self reconcileAfterHistory];
}

// History can restructure the scene (or, in Scene mode, change cells
// that the world buffer renders from the models): fold grid edits when
// models are the truth, and drop a selection index that no longer
// points at a real object.
- (void)reconcileAfterHistory {
    macvoxel::Document &doc = _ctx->document;
    if (_ctx->editor_mode == macvoxel::EditorMode::Scene) {
        doc.SyncActiveModel();
        doc.BumpScene();
    }
    if (_ctx->selected_object >= 0 &&
        static_cast<size_t>(_ctx->selected_object) >=
            doc.scene.objects.size()) {
        _ctx->selected_object = -1;
    }
}

// ---------------------------------------------------------------------------
// Selection-aware Edit menu
// ---------------------------------------------------------------------------

- (BOOL)canCutOrCopyOrDelete {
    return _ctx->selection.lift_active();
}

- (BOOL)canPaste {
    return !_ctx->clipboard.empty();
}

- (BOOL)canDeselect {
    return _ctx->selection.active();
}

- (void)copy {
    if (!_ctx->selection.lift_active() || _ctx->engine == nullptr) return;
    const macvoxel::Bounds3 sb = _ctx->selection.bounds();
    if (sb.empty()) return;

    // Read the lift contents directly — that's the actual set of
    // selected cells. The bbox alone would pick up neighbour doc
    // cells the user didn't select.
    std::vector<uint8_t> lift_bytes;
    _ctx->engine->ReadbackLift(sb, &lift_bytes);

    macvoxel::Clipboard &cb = _ctx->clipboard;
    cb.origin_x = sb.min_x;
    cb.origin_y = sb.min_y;
    cb.origin_z = sb.min_z;
    cb.size_x = static_cast<uint32_t>(sb.size_x());
    cb.size_y = static_cast<uint32_t>(sb.size_y());
    cb.size_z = static_cast<uint32_t>(sb.size_z());
    cb.cells.assign(
        static_cast<size_t>(cb.size_x) * cb.size_y * cb.size_z, 0);

    const size_t bw = (size_t)sb.size_x();
    const size_t bh = (size_t)sb.size_y();
    const size_t bd = (size_t)sb.size_z();
    if (lift_bytes.size() < bw * bh * bd) return;
    for (size_t z = 0; z < bd; ++z)
    for (size_t y = 0; y < bh; ++y) {
        const size_t row = (z * bh + y) * bw;
        for (size_t x = 0; x < bw; ++x) {
            const uint8_t v = lift_bytes[row + x];
            if (v == 0) continue;
            cb.cells[cb.LinearIndex(
                (uint32_t)x, (uint32_t)y, (uint32_t)z)] = v;
        }
    }
}

- (void)cut {
    if (!_ctx->selection.lift_active()) return;
    // Snapshot to clipboard first, then drop the lift contents.
    [self copy];
    macvoxel::lift::DeleteLift(*_ctx);
}

- (void)deleteSelection {
    if (_ctx->selection.lift_active()) {
        // Drop the lift contents; pre_lift_originals stays on history
        // so undo restores the original state.
        macvoxel::lift::DeleteLift(*_ctx);
        return;
    }
}

- (void)paste {
    const macvoxel::Clipboard &cb = _ctx->clipboard;
    if (cb.empty()) return;
    if (_ctx->selection.lift_active()) {
        macvoxel::lift::CommitLift(*_ctx);
    }
    // Write clipboard cells into the doc at the recorded origin and
    // collect their positions; then lift exactly those cells (not the
    // bbox, which would pick up neighbouring doc cells).
    macvoxel::Document &doc = _ctx->document;
    macvoxel::EditHistory &history = _ctx->history;
    std::vector<std::array<int32_t, 3>> pasted_cells;
    pasted_cells.reserve(
        static_cast<size_t>(cb.size_x) * cb.size_y * cb.size_z / 4);
    history.BeginOp();
    for (uint32_t z = 0; z < cb.size_z; ++z) {
        for (uint32_t y = 0; y < cb.size_y; ++y) {
            for (uint32_t x = 0; x < cb.size_x; ++x) {
                const uint8_t pal = cb.cells[cb.LinearIndex(x, y, z)];
                if (pal == 0) continue;
                const int32_t wx = cb.origin_x + static_cast<int32_t>(x);
                const int32_t wy = cb.origin_y + static_cast<int32_t>(y);
                const int32_t wz = cb.origin_z + static_cast<int32_t>(z);
                if (!doc.volume.Contains(wx, wy, wz)) continue;
                const uint8_t old = doc.grid.Get(wx, wy, wz);
                doc.SetCell(wx, wy, wz, pal);
                if (old != pal) history.Record(wx, wy, wz, old, pal);
                pasted_cells.push_back({wx, wy, wz});
            }
        }
    }
    history.CommitOp();
    if (pasted_cells.empty()) {
        doc.BumpGeometry();
        return;
    }
    macvoxel::lift::LiftSelectionCells(*_ctx, pasted_cells);
    doc.BumpGeometry();
}

- (void)deselect {
    if (_ctx->selection.lift_active()) {
        macvoxel::lift::CommitLift(*_ctx);
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

- (float)generatorHelixTurns {
    return _ctx->generator.params.helix_turns;
}

- (void)setGeneratorHelixTurns:(float)turns {
    _ctx->generator.params.helix_turns = turns;
}

- (float)generatorHelixRadius {
    return _ctx->generator.params.helix_radius;
}

- (void)setGeneratorHelixRadius:(float)radius {
    _ctx->generator.params.helix_radius = radius;
}

- (float)generatorHelixTube {
    return _ctx->generator.params.helix_tube;
}

- (void)setGeneratorHelixTube:(float)tube {
    _ctx->generator.params.helix_tube = tube;
}

- (BOOL)generatorHelixClockwise {
    return _ctx->generator.params.helix_clockwise != 0;
}

- (void)setGeneratorHelixClockwise:(BOOL)clockwise {
    _ctx->generator.params.helix_clockwise = clockwise ? 1u : 0u;
}

// ---------------------------------------------------------------------------
// Mutator panel state
// ---------------------------------------------------------------------------

- (NSInteger)mutatorFoliageSeedColor {
    return static_cast<NSInteger>(_ctx->mutator.params.foliage.seed_color);
}

- (void)setMutatorFoliageSeedColor:(NSInteger)idx {
    _ctx->mutator.params.foliage.seed_color =
        static_cast<uint8_t>(std::clamp<NSInteger>(idx, 1, 255));
}

- (float)mutatorFoliageDensity {
    return _ctx->mutator.params.foliage.density;
}

- (void)setMutatorFoliageDensity:(float)v {
    _ctx->mutator.params.foliage.density = std::clamp(v, 0.0f, 1.0f);
}

// ---------------------------------------------------------------------------
// Render settings
// ---------------------------------------------------------------------------

#define RS _ctx->render_settings

- (NSInteger)maxBounces { return RS.max_bounces; }
- (void)setMaxBounces:(NSInteger)v { RS.max_bounces = static_cast<int>(v); }

- (NSInteger)maxSamples { return RS.max_samples; }
- (void)setMaxSamples:(NSInteger)v { RS.max_samples = static_cast<int>(v); }

- (BridgeRenderMode)renderMode {
    return static_cast<BridgeRenderMode>(RS.mode);
}
- (void)setRenderMode:(BridgeRenderMode)v {
    RS.mode = static_cast<macvoxel::RenderMode>(v);
}

- (BOOL)stochasticGI { return RS.stochastic_gi; }
- (void)setStochasticGI:(BOOL)v { RS.stochastic_gi = (v == YES); }

- (BOOL)acesTonemap { return RS.aces_tonemap; }
- (void)setAcesTonemap:(BOOL)v { RS.aces_tonemap = (v == YES); }

- (BOOL)denoise { return RS.denoise; }
- (void)setDenoise:(BOOL)v { RS.denoise = (v == YES); }

- (BOOL)powerWeightedNEE { return RS.power_weighted_nee; }
- (void)setPowerWeightedNEE:(BOOL)v { RS.power_weighted_nee = (v == YES); }

- (float)indirectClampL { return RS.indirect_clamp_L; }
- (void)setIndirectClampL:(float)v { RS.indirect_clamp_L = v; }

- (float)emaFloor { return RS.ema_floor; }
- (void)setEmaFloor:(float)v { RS.ema_floor = v; }

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

- (float)aperture { return RS.aperture; }
- (void)setAperture:(float)v { RS.aperture = std::max(0.0f, v); }
- (float)focusDistance { return RS.focus_distance; }
- (void)setFocusDistance:(float)v {
    RS.focus_distance = std::max(0.1f, v);
}

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
    // Replace any prior selection: a lift must be torn down (doc
    // restored) before a new one can be created.
    if (_ctx->selection.lift_active()) macvoxel::lift::CancelLift(*_ctx);
    if (matched.empty()) {
        _ctx->selection.Clear();
        return;
    }
    macvoxel::lift::LiftSelectionCells(*_ctx, matched);
}

// Shared painter for the two voxel-paint context-menu items. A voxel
// selection is a GPU lift (its cells live in tex_lift, removed from
// tex_a). Recolor the lift's current contents and land them back into
// the doc in one undoable op, dropping the lift. `choose` returns the
// palette index to write per voxel; called once per lifted voxel.
template <class Choose>
static void PaintSelectedVoxels(macvoxel::EditorContext &ctx, Choose choose) {
    macvoxel::Selection &sel = ctx.selection;
    if (ctx.engine == nullptr || !sel.lift_active()) return;
    const macvoxel::Bounds3 lift_b = sel.bounds();
    if (lift_b.empty()) return;

    macvoxel::Document &doc = ctx.document;
    macvoxel::EditHistory &hist = ctx.history;

    // Current lift contents (handles lifts that were moved/rotated).
    std::vector<uint8_t> lift_bytes;
    ctx.engine->ReadbackLift(lift_b, &lift_bytes);

    // Net diff, pre_lift state → painted result. Mirrors CommitLift's
    // merge of source holes (→ 0) with landed lift cells (→ new color).
    struct Delta { uint8_t old_val; uint8_t new_val; };
    std::unordered_map<int64_t, Delta> changes;
    changes.reserve(sel.pre_lift_originals().size() * 2 + 64);
    for (const auto &orig : sel.pre_lift_originals()) {
        changes[macvoxel::PackCellKey(orig.x, orig.y, orig.z)] =
            {orig.old_val, 0};
    }

    macvoxel::Bounds3 rb = lift_b;
    rb.min_x = std::max(rb.min_x, doc.volume.x0);
    rb.min_y = std::max(rb.min_y, doc.volume.y0);
    rb.min_z = std::max(rb.min_z, doc.volume.z0);
    rb.max_x = std::min(rb.max_x, doc.volume.x1);
    rb.max_y = std::min(rb.max_y, doc.volume.y1);
    rb.max_z = std::min(rb.max_z, doc.volume.z1);
    if (!rb.empty()) {
        const size_t bw = (size_t)rb.size_x();
        const size_t bh = (size_t)rb.size_y();
        const size_t bd = (size_t)rb.size_z();
        if (lift_bytes.size() >= bw * bh * bd) {
            for (size_t z = 0; z < bd; ++z)
            for (size_t y = 0; y < bh; ++y) {
                const size_t row = (z * bh + y) * bw;
                for (size_t x = 0; x < bw; ++x) {
                    const uint8_t v = lift_bytes[row + x];
                    if (v == 0) continue;
                    const int32_t wx = rb.min_x + (int32_t)x;
                    const int32_t wy = rb.min_y + (int32_t)y;
                    const int32_t wz = rb.min_z + (int32_t)z;
                    uint8_t nc = choose();
                    if (nc == 0) nc = v;  // never paint to empty
                    const int64_t k = macvoxel::PackCellKey(wx, wy, wz);
                    auto it = changes.find(k);
                    if (it != changes.end()) {
                        it->second.new_val = nc;
                    } else {
                        changes[k] = {doc.volume_shadow.Get(wx, wy, wz), nc};
                    }
                }
            }
        }
    }

    // Drop the GPU lift; the painted cells reach tex_a via doc.SetCell's
    // dirty-chunk sync on the next frame (BumpGeometry below).
    ctx.engine->ClearLift(lift_b);

    hist.BeginOp();
    for (const auto &[k, d] : changes) {
        int32_t x, y, z;
        macvoxel::UnpackCellKey(k, &x, &y, &z);
        if (doc.grid.Get(x, y, z) != d.new_val) doc.SetCell(x, y, z, d.new_val);
        if (d.old_val != d.new_val) hist.Record(x, y, z, d.old_val, d.new_val);
    }
    sel.ClearLift();
    hist.CommitOp();
    doc.BumpGeometry();
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
