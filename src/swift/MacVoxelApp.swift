import SwiftUI

struct MacVoxelApp: App {
    @State private var state = EditorState()

    var body: some Scene {
        // Single-document app: `Window` enforces one window, so a
        // Finder "Open With" routes `.onOpenURL` into the existing
        // window's `state` (replacing the current document) rather
        // than spawning a second window with its own EditorState.
        // The data model assumes one in-flight render at a time;
        // letting WindowGroup spin up a second window had two
        // path-tracers fighting over the same UI.
        Window("MacVoxel", id: "main") {
            ContentView()
                .environment(state)
                .navigationTitle(state.documentTitle)
                .frame(minWidth: 1280, minHeight: 800)
                .onOpenURL { url in
                    state.openDocument(at: url)
                }
        }
        .commands {
            MacVoxelCommands(state: state)
        }
    }
}
