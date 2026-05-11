import AppKit
import SwiftUI

// SwiftUI wrapper around MetalScene (the MTKView-derived NSView with
// renderer + dispatch + camera). The bridge identity carries the
// EditorContext through to the Obj-C++ side; SwiftUI never sees C++.
//
// We also set a weak back-reference on EditorState so menu commands
// can ask the scene to invalidate renderer caches / reframe the
// camera after a doc-replacing mutation.
struct MetalSceneView: NSViewRepresentable {
    let state: EditorState

    func makeNSView(context: Context) -> MetalScene {
        let scene = MetalScene(frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
                               bridge: state.bridge)!
        scene.frameCameraToDocument()
        state.scene = scene
        return scene
    }

    func updateNSView(_ nsView: MetalScene, context: Context) {}
}
