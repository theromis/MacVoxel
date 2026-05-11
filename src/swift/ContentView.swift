import SwiftUI

struct ContentView: View {
    @Environment(EditorState.self) private var state

    var body: some View {
        MetalSceneView(state: state)
            .ignoresSafeArea()
    }
}
