#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Mirror of macvoxel::Axis (defined in SelectionOps.h). Exposed to
// Swift via the bridging header so panels don't need to import C++.
typedef NS_ENUM(NSInteger, BridgeAxis) {
    BridgeAxisX NS_SWIFT_NAME(x) = 0,
    BridgeAxisY NS_SWIFT_NAME(y) = 1,
    BridgeAxisZ NS_SWIFT_NAME(z) = 2,
};

// Mirror of macvoxel::generators::Kind.
typedef NS_ENUM(NSInteger, BridgeGeneratorKind) {
    BridgeGeneratorKindEllipsoid NS_SWIFT_NAME(ellipsoid) = 0,
    BridgeGeneratorKindCylinder  NS_SWIFT_NAME(cylinder)  = 1,
    BridgeGeneratorKindCone      NS_SWIFT_NAME(cone)      = 2,
    BridgeGeneratorKindPyramid   NS_SWIFT_NAME(pyramid)   = 3,
    BridgeGeneratorKindPerlin    NS_SWIFT_NAME(perlin)    = 4,
    BridgeGeneratorKindTorus     NS_SWIFT_NAME(torus)     = 5,
};

// Mirror of macvoxel::ToolKind.
typedef NS_ENUM(NSInteger, BridgeToolKind) {
    BridgeToolKindBrush       NS_SWIFT_NAME(brush)       = 0,
    BridgeToolKindLine        NS_SWIFT_NAME(line)        = 1,
    BridgeToolKindCircle      NS_SWIFT_NAME(circle)      = 2,
    BridgeToolKindSquare      NS_SWIFT_NAME(square)      = 3,
    BridgeToolKindBox         NS_SWIFT_NAME(box)         = 4,
    BridgeToolKindFace        NS_SWIFT_NAME(face)        = 5,
    BridgeToolKindGenerator   NS_SWIFT_NAME(generator)   = 6,
    BridgeToolKindMarquee     NS_SWIFT_NAME(marquee)     = 7,
    BridgeToolKindBoxSelect   NS_SWIFT_NAME(boxSelect)   = 8,
    BridgeToolKindFloodSelect NS_SWIFT_NAME(floodSelect) = 9,
};

typedef NS_ENUM(NSInteger, BridgeToolMode) {
    BridgeToolModeAdd    NS_SWIFT_NAME(add)    = 0,
    BridgeToolModeRemove NS_SWIFT_NAME(remove) = 1,
    BridgeToolModePaint  NS_SWIFT_NAME(paint)  = 2,
};

typedef NS_ENUM(NSInteger, BridgeBrushShape) {
    BridgeBrushShapeSquare NS_SWIFT_NAME(square) = 0,
    BridgeBrushShapeCircle NS_SWIFT_NAME(circle) = 1,
};

typedef NS_ENUM(NSInteger, BridgeLineMode) {
    BridgeLineModeStraight NS_SWIFT_NAME(straight) = 0,
    BridgeLineModeProject  NS_SWIFT_NAME(project)  = 1,
};

typedef NS_ENUM(NSInteger, BridgeFaceExtrudeKind) {
    BridgeFaceExtrudeKindColor    NS_SWIFT_NAME(color)    = 0,
    BridgeFaceExtrudeKindGeometry NS_SWIFT_NAME(geometry) = 1,
};

typedef NS_ENUM(NSInteger, BridgeFaceWithColor) {
    BridgeFaceWithColorGeometry NS_SWIFT_NAME(geometry) = 0,
    BridgeFaceWithColorPalette  NS_SWIFT_NAME(palette)  = 1,
};

typedef NS_ENUM(NSInteger, BridgeGlassMode) {
    BridgeGlassModeProbabilistic NS_SWIFT_NAME(probabilistic) = 0,
    BridgeGlassModeAbsorption    NS_SWIFT_NAME(absorption)    = 1,
};

typedef NS_ENUM(NSInteger, BridgeMaterialType) {
    BridgeMaterialTypeDiffuse  NS_SWIFT_NAME(diffuse)  = 0,
    BridgeMaterialTypeMetal    NS_SWIFT_NAME(metal)    = 1,
    BridgeMaterialTypeEmissive NS_SWIFT_NAME(emissive) = 2,
    BridgeMaterialTypeGlass    NS_SWIFT_NAME(glass)    = 3,
};

// Obj-C wrapper around macvoxel::EditorContext. Owns the C++ context
// via std::unique_ptr behind the @implementation; Swift sees only this
// Obj-C interface (pulled in by MacVoxel-Bridging-Header.h). Pure C++
// accessors live in EditorContextBridge_Internal.h and are only
// available to Obj-C++ callers.
@interface EditorContextBridge : NSObject

// Constructs a fresh editor context. Seeds the document from the
// bundled default.vox if available, falling back to a single-voxel
// grid. Bumps all dirty counters so renderers see fresh data on the
// first frame.
- (instancetype)init;

// Last-path-component of the document path, or "Untitled" if unsaved.
@property (nonatomic, readonly) NSString *documentTitle;

// Absolute path on disk, or empty if the document hasn't been saved.
@property (nonatomic, readonly) NSString *documentPath;

// True once the document has been saved or loaded from a path.
@property (nonatomic, readonly) BOOL hasDocumentPath;

// ---------------------------------------------------------------------------
// Document actions. Mutate EditorContext, bump dirty counters, clear
// undo history when appropriate. Renderer-cache invalidation +
// camera reframing happens in MetalScene; callers (EditorState) call
// the scene-side helpers after these return.
// ---------------------------------------------------------------------------

// Replace the document with a fresh default-seeded one.
- (void)newDocument;

// Load `url` as a .vox file. Returns NO on parse failure; populates
// `error` with the underlying message in that case.
- (BOOL)openDocumentAtURL:(NSURL *)url error:(NSError **)error;

// Serialize the document to `url`. Returns NO with `error` on failure.
// Commits any active floating buffer first so what's on screen is
// what gets persisted.
- (BOOL)saveDocumentToURL:(NSURL *)url error:(NSError **)error;

// Save to the document's current path. Returns NO if there is no
// path yet (caller should fall back to Save As…).
- (BOOL)saveDocumentInPlace:(NSError **)error;

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

@property (nonatomic, readonly) BOOL canUndo;
@property (nonatomic, readonly) BOOL canRedo;
- (void)undo;
- (void)redo;

// ---------------------------------------------------------------------------
// Selection-aware edit menu. Same predicates as AppDelegate's
// validateMenuItem: today.
// ---------------------------------------------------------------------------

@property (nonatomic, readonly) BOOL canCutOrCopyOrDelete;
@property (nonatomic, readonly) BOOL canPaste;
@property (nonatomic, readonly) BOOL canDeselect;

- (void)cut;
- (void)copy;
- (void)paste;
- (void)deleteSelection;
- (void)deselect;

// ---------------------------------------------------------------------------
// Document read-only stats. Read each frame (or each tick) by panels;
// no observation guarantees from the bridge — EditorState's tick
// counter is what triggers SwiftUI redraws.
// ---------------------------------------------------------------------------

@property (nonatomic, readonly) NSInteger gridFilledCount;
@property (nonatomic, readonly) BOOL gridIsEmpty;
@property (nonatomic, readonly) NSInteger gridSizeX;
@property (nonatomic, readonly) NSInteger gridSizeY;
@property (nonatomic, readonly) NSInteger gridSizeZ;

// ---------------------------------------------------------------------------
// Selection transforms. Routes to the floating buffer if one is alive
// (matches the dispatch SelectionOps does internally).
// ---------------------------------------------------------------------------

- (void)rotateSelectionAxis:(BridgeAxis)axis clockwise:(BOOL)cw
    NS_SWIFT_NAME(rotateSelection(axis:clockwise:));
- (void)flipSelectionAxis:(BridgeAxis)axis
    NS_SWIFT_NAME(flipSelection(axis:));

// ---------------------------------------------------------------------------
// Generator panel state. Live — the controller's per-frame Tick
// detects changes and re-runs the engine; no version bumps needed.
// ---------------------------------------------------------------------------

@property (nonatomic, assign) BridgeGeneratorKind generatorKind;
@property (nonatomic, assign) BridgeAxis generatorAxis;
@property (nonatomic, assign) BOOL generatorApexAtMax;
@property (nonatomic, assign) float generatorPerlinScale;
@property (nonatomic, assign) float generatorPerlinThreshold;
@property (nonatomic, assign) NSInteger generatorPerlinOctaves;
@property (nonatomic, assign) NSInteger generatorPerlinSeed;
@property (nonatomic, assign) float generatorTorusTube;

// ---------------------------------------------------------------------------
// Render settings (path tracer inputs). Live state read by the
// renderer each frame. Path-tracer accumulation is NOT auto-reset on
// change today — matches AppDelegate behavior.
// ---------------------------------------------------------------------------

@property (nonatomic, assign) NSInteger maxBounces;     // 1..8
@property (nonatomic, assign) NSInteger maxSamples;     // 1..N
@property (nonatomic, assign) BOOL pathTraced;
@property (nonatomic, assign) BOOL acesTonemap;
@property (nonatomic, assign) BOOL powerWeightedNEE;
@property (nonatomic, assign) NSInteger neeRisCount;    // 1..32

@property (nonatomic, assign) BOOL atmosphericSky;
@property (nonatomic, assign) float skyIntensity;       // 0..4
@property (nonatomic, assign) float horizonSoftnessDeg; // 0..15

@property (nonatomic, assign) float sunElevationDeg;    // -90..90
@property (nonatomic, assign) float sunAzimuthDeg;      // 0..360
@property (nonatomic, assign) float sunAngularDiameterDeg; // 0.1..30
@property (nonatomic, assign) float sunIntensity;       // 0..10 (logarithmic UI)
@property (nonatomic, assign) float sunColorR;          // sRGB 0..1
@property (nonatomic, assign) float sunColorG;
@property (nonatomic, assign) float sunColorB;

// ---------------------------------------------------------------------------
// Tool settings. Live state — no version bump needed; the controllers
// read fresh values each event / frame.
// ---------------------------------------------------------------------------

@property (nonatomic, assign) BridgeToolKind toolKind;
@property (nonatomic, assign) BridgeToolMode toolMode;
@property (nonatomic, assign) NSInteger brushSize;     // 1..63
@property (nonatomic, assign) BridgeBrushShape brushShape;
@property (nonatomic, assign) BOOL brush3D;

@property (nonatomic, assign) BridgeLineMode lineMode;
@property (nonatomic, assign) BOOL circleFill;
@property (nonatomic, assign) BOOL circleEven;
@property (nonatomic, assign) BOOL squareFill;
@property (nonatomic, assign) BOOL squareEven;
@property (nonatomic, assign) BOOL boxFill;
@property (nonatomic, assign) BridgeFaceExtrudeKind faceExtrude;
@property (nonatomic, assign) BridgeFaceWithColor faceWith;
@property (nonatomic, assign) BOOL faceEightConnected;

// More render settings used by RenderPanel.
@property (nonatomic, assign) BridgeGlassMode glassMode;
@property (nonatomic, assign) BOOL resolutionMatchWindow;
@property (nonatomic, assign) NSInteger renderWidth;
@property (nonatomic, assign) NSInteger renderHeight;
@property (nonatomic, readonly) NSInteger sampleCount;

// ---------------------------------------------------------------------------
// Palette panel. RGBA components are 0..255. Index 0 is the empty
// slot and shouldn't be painted/edited from the panel.
// ---------------------------------------------------------------------------

@property (nonatomic, readonly) NSInteger paletteSize;       // = 256
@property (nonatomic, assign) NSInteger activePaletteSlot;   // tool.palette_idx

// Pack RGBA into a UInt32 (0xAARRGGBB) for easy Swift unpacking.
- (uint32_t)paletteColorAt:(NSInteger)index
    NS_SWIFT_NAME(paletteColor(at:));
- (void)setPaletteColorAt:(NSInteger)index r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b a:(uint8_t)a
    NS_SWIFT_NAME(setPaletteColor(at:r:g:b:a:));
- (BOOL)isPaletteSlotSelected:(NSInteger)index
    NS_SWIFT_NAME(isPaletteSlotSelected(_:));

// Click semantics:
//   selectPaletteSlot:withModifiers: 0  → set active + reset selection to [index]
//   1 (shift) → toggle index in selection; active = index
- (void)selectPaletteSlot:(NSInteger)index extend:(BOOL)extend
    NS_SWIFT_NAME(selectPaletteSlot(_:extend:));

// Direct color-edit op recording. Begin/Apply/Commit pattern coalesces
// a ColorPicker drag into one Cmd-Z step.
- (void)beginPaletteEdit;
- (void)applyPaletteColorR:(uint8_t)r g:(uint8_t)g b:(uint8_t)b a:(uint8_t)a
    NS_SWIFT_NAME(applyPaletteColor(r:g:b:a:));
- (void)commitPaletteEdit;

// ---------------------------------------------------------------------------
// Material editor. Reads the active slot for display; writes apply to
// every slot in the selection. Begin/Set/Commit coalesces multi-widget
// drags (slider + combo) into one Cmd-Z step via panel.material_edit's
// per-slot pre snapshot.
// ---------------------------------------------------------------------------

// Read accessors (active slot).
@property (nonatomic, readonly) BridgeMaterialType activeMaterialType;
@property (nonatomic, readonly) float activeMaterialRoughness;
@property (nonatomic, readonly) float activeMaterialMetallic;
@property (nonatomic, readonly) float activeMaterialEmission;
@property (nonatomic, readonly) NSInteger activeMaterialEmissionPower;
@property (nonatomic, readonly) float activeMaterialTransparency;
@property (nonatomic, readonly) float activeMaterialIor;

// Selected-slot count for the "Index N (+M more selected)" label.
@property (nonatomic, readonly) NSInteger selectedSlotCount;

- (void)beginMaterialEdit;
- (void)applyMaterialType:(BridgeMaterialType)type
    NS_SWIFT_NAME(applyMaterialType(_:));
- (void)applyMaterialRoughness:(float)v
    NS_SWIFT_NAME(applyMaterialRoughness(_:));
- (void)applyMaterialMetallic:(float)v
    NS_SWIFT_NAME(applyMaterialMetallic(_:));
- (void)applyMaterialEmission:(float)v
    NS_SWIFT_NAME(applyMaterialEmission(_:));
- (void)applyMaterialEmissionPower:(NSInteger)v
    NS_SWIFT_NAME(applyMaterialEmissionPower(_:));
- (void)applyMaterialTransparency:(float)v
    NS_SWIFT_NAME(applyMaterialTransparency(_:));
- (void)applyMaterialIor:(float)v
    NS_SWIFT_NAME(applyMaterialIor(_:));
- (void)commitMaterialEdit;

@end

NS_ASSUME_NONNULL_END
