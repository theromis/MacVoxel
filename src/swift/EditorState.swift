import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

// Swift façade over EditorContextBridge. Held as @State at the App
// level and injected into the view hierarchy via .environment(...).
//
// As panels come online, this class grows version counters that mirror
// Document::version / palette_version / material_version and the
// per-slice bumps for tool / render / selection — SwiftUI views
// re-render on the counter relevant to them, preserving the
// cache-granularity the Metal renderers depend on.
@Observable
final class EditorState {
    let bridge: EditorContextBridge

    // Weak back-reference to the active scene NSView, set when
    // MetalSceneView materialises. Menu commands route through here
    // to invalidate renderer caches / reframe the camera after the
    // bridge mutates document state.
    weak var scene: MetalScene?

    // Mirrors bridge.documentTitle so SwiftUI's @Observable tracking
    // re-renders the window title bar on rename. The bridge itself
    // isn't @Observable (it's an Obj-C++ NSObject), so anything
    // SwiftUI needs to observe is republished here.
    private(set) var documentTitle: String = "Untitled"

    // Bumped after any action that mutates document state. Menu
    // enable-state queries read through to bridge predicates on
    // every access; the version counter is what wakes the observer.
    private(set) var documentVersion: UInt64 = 0

    // Observation tick. The single @Observable-tracked storage every
    // bridge-proxy property funnels through: getters do `_ = tick` to
    // register a dependency, and writes invalidate observers by bumping
    // it. Two sources mutate it:
    //
    // 1. Every panel-facing setter bumps it synchronously after writing
    //    the bridge so user input reflects on screen the same frame
    //    rather than waiting up to a full timer period. Skipping the
    //    bump here causes visible UI lag on conditionals like
    //    `if state.pathTraced` — Observation has no way to see the
    //    bridge mutation otherwise.
    // 2. A 10 Hz Timer below catches controller-driven mutations
    //    (brush strokes, selection ops) that bypass the Swift bridge
    //    entirely, so panels watching counts / sizes still refresh.
    private(set) var tick: UInt64 = 0
    private var tickTimer: Timer?

    init() {
        self.bridge = EditorContextBridge()
        self.documentTitle = bridge.documentTitle
        self.tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1,
                                              repeats: true) { [weak self] _ in
            self?.tick &+= 1
        }
    }

    deinit {
        tickTimer?.invalidate()
    }

    // ---- File ops ----

    func newDocument() {
        bridge.newDocument()
        afterMutation(reframeCamera: true)
    }

    func openDocumentDialog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MacVoxelDocumentType.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            openDocument(at: url)
        }
    }

    @discardableResult
    func openDocument(at url: URL) -> Bool {
        do {
            try bridge.openDocument(at: url)
            afterMutation(reframeCamera: true)
            return true
        } catch {
            presentError(title: "Open Failed", error: error)
            return false
        }
    }

    func saveDocument() {
        if bridge.hasDocumentPath {
            do {
                try bridge.saveDocumentInPlace()
            } catch {
                presentError(title: "Save Failed", error: error)
            }
        } else {
            saveDocumentAsDialog()
        }
    }

    func saveDocumentAsDialog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = MacVoxelDocumentType.contentTypes
        panel.nameFieldStringValue = "Untitled.vox"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try bridge.saveDocument(to: url)
                documentTitle = bridge.documentTitle
            } catch {
                presentError(title: "Save Failed", error: error)
            }
        }
    }

    // ---- History ----

    var canUndo: Bool {
        _ = tick
        return bridge.canUndo
    }

    var canRedo: Bool {
        _ = tick
        return bridge.canRedo
    }

    func undo() {
        bridge.undo()
        afterMutation(reframeCamera: false)
    }

    func redo() {
        bridge.redo()
        afterMutation(reframeCamera: false)
    }

    // ---- Edit ----

    var canCutOrCopyOrDelete: Bool {
        _ = tick
        return bridge.canCutOrCopyOrDelete
    }

    var canPaste: Bool {
        _ = tick
        return bridge.canPaste
    }

    var canDeselect: Bool {
        _ = tick
        return bridge.canDeselect
    }

    func cut()             { bridge.cut();             afterMutation(reframeCamera: false) }
    func copy()            { bridge.copy();            afterMutation(reframeCamera: false) }
    func paste()           { bridge.paste();           afterMutation(reframeCamera: false) }
    func deleteSelection() { bridge.deleteSelection(); afterMutation(reframeCamera: false) }
    func deselect()        { bridge.deselect();        afterMutation(reframeCamera: false) }

    // ---- Document stats (panel-facing) ----
    //
    // Computed views over the bridge. Each reads `tick` first so
    // SwiftUI's @Observable machinery records the dependency — the
    // panel re-evaluates when the 10 Hz timer fires.

    var documentPath: String {
        bridge.documentPath
    }

    var gridFilledCount: Int {
        _ = tick
        return bridge.gridFilledCount
    }

    var gridIsEmpty: Bool {
        _ = tick
        return bridge.gridIsEmpty
    }

    var gridSize: (x: Int, y: Int, z: Int) {
        _ = tick
        return (bridge.gridSizeX, bridge.gridSizeY, bridge.gridSizeZ)
    }

    // ---- Selection transforms (panel-facing) ----

    var canTransformSelection: Bool {
        _ = tick
        return bridge.canCutOrCopyOrDelete  // same predicate
    }

    func rotateSelection(axis: BridgeAxis, clockwise: Bool) {
        bridge.rotateSelection(axis: axis, clockwise: clockwise)
        afterMutation(reframeCamera: false)
    }

    func flipSelection(axis: BridgeAxis) {
        bridge.flipSelection(axis: axis)
        afterMutation(reframeCamera: false)
    }

    // ---- Generator (panel-facing) ----

    var generatorKind: BridgeGeneratorKind {
        get { _ = tick; return bridge.generatorKind }
        set { bridge.generatorKind = newValue; tick &+= 1 }
    }

    var generatorAxis: BridgeAxis {
        get { _ = tick; return bridge.generatorAxis }
        set { bridge.generatorAxis = newValue; tick &+= 1 }
    }

    var generatorApexAtMax: Bool {
        get { _ = tick; return bridge.generatorApexAtMax }
        set { bridge.generatorApexAtMax = newValue; tick &+= 1 }
    }

    var generatorPerlinScale: Float {
        get { _ = tick; return bridge.generatorPerlinScale }
        set { bridge.generatorPerlinScale = newValue; tick &+= 1 }
    }

    var generatorPerlinThreshold: Float {
        get { _ = tick; return bridge.generatorPerlinThreshold }
        set { bridge.generatorPerlinThreshold = newValue; tick &+= 1 }
    }

    var generatorPerlinOctaves: Int {
        get { _ = tick; return bridge.generatorPerlinOctaves }
        set { bridge.generatorPerlinOctaves = newValue; tick &+= 1 }
    }

    var generatorPerlinSeed: Int {
        get { _ = tick; return bridge.generatorPerlinSeed }
        set { bridge.generatorPerlinSeed = newValue; tick &+= 1 }
    }

    var generatorTorusTube: Float {
        get { _ = tick; return bridge.generatorTorusTube }
        set { bridge.generatorTorusTube = newValue; tick &+= 1 }
    }

    var generatorPerlinPaletteLo: Int {
        get { _ = tick; return bridge.generatorPerlinPaletteLo }
        set { bridge.generatorPerlinPaletteLo = newValue; tick &+= 1 }
    }

    var generatorPerlinPaletteHi: Int {
        get { _ = tick; return bridge.generatorPerlinPaletteHi }
        set { bridge.generatorPerlinPaletteHi = newValue; tick &+= 1 }
    }

    // ---- Render settings (panel-facing) ----
    //
    // Path tracer reads these every frame; raycast preview ignores
    // sky / sun. Changes don't auto-reset accumulation (matches old
    // ImGui behavior — user toggles to re-start).

    var maxBounces: Int {
        get { _ = tick; return bridge.maxBounces }
        set { bridge.maxBounces = newValue; tick &+= 1 }
    }
    var maxSamples: Int {
        get { _ = tick; return bridge.maxSamples }
        set { bridge.maxSamples = newValue; tick &+= 1 }
    }
    var pathTraced: Bool {
        get { _ = tick; return bridge.pathTraced }
        set { bridge.pathTraced = newValue; tick &+= 1 }
    }
    var acesTonemap: Bool {
        get { _ = tick; return bridge.acesTonemap }
        set { bridge.acesTonemap = newValue; tick &+= 1 }
    }
    var powerWeightedNEE: Bool {
        get { _ = tick; return bridge.powerWeightedNEE }
        set { bridge.powerWeightedNEE = newValue; tick &+= 1 }
    }
    var neeRisCount: Int {
        get { _ = tick; return bridge.neeRisCount }
        set { bridge.neeRisCount = newValue; tick &+= 1 }
    }
    var atmosphericSky: Bool {
        get { _ = tick; return bridge.atmosphericSky }
        set { bridge.atmosphericSky = newValue; tick &+= 1 }
    }
    var skyIntensity: Float {
        get { _ = tick; return bridge.skyIntensity }
        set { bridge.skyIntensity = newValue; tick &+= 1 }
    }
    var horizonSoftnessDeg: Float {
        get { _ = tick; return bridge.horizonSoftnessDeg }
        set { bridge.horizonSoftnessDeg = newValue; tick &+= 1 }
    }
    var sunElevationDeg: Float {
        get { _ = tick; return bridge.sunElevationDeg }
        set { bridge.sunElevationDeg = newValue; tick &+= 1 }
    }
    var sunAzimuthDeg: Float {
        get { _ = tick; return bridge.sunAzimuthDeg }
        set { bridge.sunAzimuthDeg = newValue; tick &+= 1 }
    }
    var sunAngularDiameterDeg: Float {
        get { _ = tick; return bridge.sunAngularDiameterDeg }
        set { bridge.sunAngularDiameterDeg = newValue; tick &+= 1 }
    }
    var sunIntensity: Float {
        get { _ = tick; return bridge.sunIntensity }
        set { bridge.sunIntensity = newValue; tick &+= 1 }
    }
    var sunColor: (r: Float, g: Float, b: Float) {
        get { _ = tick; return (bridge.sunColorR, bridge.sunColorG, bridge.sunColorB) }
        set {
            bridge.sunColorR = newValue.r
            bridge.sunColorG = newValue.g
            bridge.sunColorB = newValue.b
            tick &+= 1
        }
    }

    // ---- Tool settings (panel-facing) ----

    var toolKind: BridgeToolKind {
        get { _ = tick; return bridge.toolKind }
        set { bridge.toolKind = newValue; tick &+= 1 }
    }
    var toolMode: BridgeToolMode {
        get { _ = tick; return bridge.toolMode }
        set { bridge.toolMode = newValue; tick &+= 1 }
    }
    var brushSize: Int {
        get { _ = tick; return bridge.brushSize }
        set { bridge.brushSize = newValue; tick &+= 1 }
    }
    var brushShape: BridgeBrushShape {
        get { _ = tick; return bridge.brushShape }
        set { bridge.brushShape = newValue; tick &+= 1 }
    }
    var brush3D: Bool {
        get { _ = tick; return bridge.brush3D }
        set { bridge.brush3D = newValue; tick &+= 1 }
    }
    var lineMode: BridgeLineMode {
        get { _ = tick; return bridge.lineMode }
        set { bridge.lineMode = newValue; tick &+= 1 }
    }
    var circleFill: Bool {
        get { _ = tick; return bridge.circleFill }
        set { bridge.circleFill = newValue; tick &+= 1 }
    }
    var circleEven: Bool {
        get { _ = tick; return bridge.circleEven }
        set { bridge.circleEven = newValue; tick &+= 1 }
    }
    var squareFill: Bool {
        get { _ = tick; return bridge.squareFill }
        set { bridge.squareFill = newValue; tick &+= 1 }
    }
    var squareEven: Bool {
        get { _ = tick; return bridge.squareEven }
        set { bridge.squareEven = newValue; tick &+= 1 }
    }
    var boxFill: Bool {
        get { _ = tick; return bridge.boxFill }
        set { bridge.boxFill = newValue; tick &+= 1 }
    }
    var faceExtrude: BridgeFaceExtrudeKind {
        get { _ = tick; return bridge.faceExtrude }
        set { bridge.faceExtrude = newValue; tick &+= 1 }
    }
    var faceWith: BridgeFaceWithColor {
        get { _ = tick; return bridge.faceWith }
        set { bridge.faceWith = newValue; tick &+= 1 }
    }
    var faceEightConnected: Bool {
        get { _ = tick; return bridge.faceEightConnected }
        set { bridge.faceEightConnected = newValue; tick &+= 1 }
    }

    // ---- Render panel ----

    var glassMode: BridgeGlassMode {
        get { _ = tick; return bridge.glassMode }
        set { bridge.glassMode = newValue; tick &+= 1 }
    }
    var resolutionMatchWindow: Bool {
        get { _ = tick; return bridge.resolutionMatchWindow }
        set { bridge.resolutionMatchWindow = newValue; tick &+= 1 }
    }
    var renderWidth: Int {
        get { _ = tick; return bridge.renderWidth }
        set { bridge.renderWidth = newValue; tick &+= 1 }
    }
    var renderHeight: Int {
        get { _ = tick; return bridge.renderHeight }
        set { bridge.renderHeight = newValue; tick &+= 1 }
    }
    var sampleCount: Int {
        _ = tick
        return bridge.sampleCount
    }

    // ---- Palette ----

    var paletteSize: Int { bridge.paletteSize }

    var activePaletteSlot: Int {
        get { _ = tick; return bridge.activePaletteSlot }
        set { bridge.activePaletteSlot = newValue; tick &+= 1 }
    }

    func paletteColor(at index: Int) -> UInt32 {
        _ = tick
        return bridge.paletteColor(at: index)
    }

    func isPaletteSlotSelected(_ index: Int) -> Bool {
        _ = tick
        return bridge.isPaletteSlotSelected(index)
    }

    func selectPaletteSlot(_ index: Int, extend: Bool) {
        bridge.selectPaletteSlot(index, extend: extend)
        documentVersion &+= 1
    }

    func beginPaletteEdit()  { bridge.beginPaletteEdit() }
    func applyPaletteColor(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        bridge.applyPaletteColor(r: r, g: g, b: b, a: a)
    }
    func commitPaletteEdit() { bridge.commitPaletteEdit() }

    // ---- Material editor ----

    var selectedSlotCount: Int {
        _ = tick; return bridge.selectedSlotCount
    }
    var activeMaterialType: BridgeMaterialType {
        _ = tick; return bridge.activeMaterialType
    }
    var activeMaterialRoughness: Float    { _ = tick; return bridge.activeMaterialRoughness }
    var activeMaterialMetallic: Float     { _ = tick; return bridge.activeMaterialMetallic }
    var activeMaterialEmission: Float     { _ = tick; return bridge.activeMaterialEmission }
    var activeMaterialEmissionPower: Int  { _ = tick; return bridge.activeMaterialEmissionPower }
    var activeMaterialTransparency: Float { _ = tick; return bridge.activeMaterialTransparency }
    var activeMaterialIor: Float          { _ = tick; return bridge.activeMaterialIor }

    func beginMaterialEdit()  { bridge.beginMaterialEdit() }
    func applyMaterialType(_ t: BridgeMaterialType)        { bridge.applyMaterialType(t) }
    func applyMaterialRoughness(_ v: Float)                { bridge.applyMaterialRoughness(v) }
    func applyMaterialMetallic(_ v: Float)                 { bridge.applyMaterialMetallic(v) }
    func applyMaterialEmission(_ v: Float)                 { bridge.applyMaterialEmission(v) }
    func applyMaterialEmissionPower(_ v: Int)              { bridge.applyMaterialEmissionPower(v) }
    func applyMaterialTransparency(_ v: Float)             { bridge.applyMaterialTransparency(v) }
    func applyMaterialIor(_ v: Float)                      { bridge.applyMaterialIor(v) }
    func commitMaterialEdit() { bridge.commitMaterialEdit() }

    func saveRenderDialog() {
        let panel = NSSavePanel()
        panel.title = "Save render"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "render.png"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try scene?.exportRender(to: url)
            } catch {
                presentError(title: "Couldn't save render", error: error)
            }
        }
    }

    // ---- Plumbing ----

    private func afterMutation(reframeCamera: Bool) {
        documentTitle = bridge.documentTitle
        documentVersion &+= 1
        tick &+= 1
        scene?.invalidateRenderers()
        if reframeCamera {
            scene?.frameCameraToDocument()
        }
    }

    private func presentError(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = (error as NSError).localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// .vox UTType reachable from both NSOpenPanel/NSSavePanel and
// .onOpenURL routing. Wrapped as a static accessor so we lazy-resolve
// once and tolerate the (very unlikely) missing-UTType case.
enum MacVoxelDocumentType {
    static let contentTypes: [UTType] = {
        if let t = UTType(filenameExtension: "vox") { return [t] }
        return []
    }()
}
