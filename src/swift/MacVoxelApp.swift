import SwiftUI

struct MacVoxelApp: App {
    @State private var state = EditorState()

    var body: some Scene {
        WindowGroup {
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
