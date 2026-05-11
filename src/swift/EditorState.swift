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

    init() {
        self.bridge = EditorContextBridge()
        self.documentTitle = bridge.documentTitle
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
        _ = documentVersion
        return bridge.canUndo
    }

    var canRedo: Bool {
        _ = documentVersion
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
        _ = documentVersion
        return bridge.canCutOrCopyOrDelete
    }

    var canPaste: Bool {
        _ = documentVersion
        return bridge.canPaste
    }

    var canDeselect: Bool {
        _ = documentVersion
        return bridge.canDeselect
    }

    func cut()             { bridge.cut();             afterMutation(reframeCamera: false) }
    func copy()            { bridge.copy();            afterMutation(reframeCamera: false) }
    func paste()           { bridge.paste();           afterMutation(reframeCamera: false) }
    func deleteSelection() { bridge.deleteSelection(); afterMutation(reframeCamera: false) }
    func deselect()        { bridge.deselect();        afterMutation(reframeCamera: false) }

    // ---- Plumbing ----

    private func afterMutation(reframeCamera: Bool) {
        documentTitle = bridge.documentTitle
        documentVersion &+= 1
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
