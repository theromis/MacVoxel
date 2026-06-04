import SwiftUI

struct ContentView: View {
    @Environment(EditorState.self) private var state

    var body: some View {
        @Bindable var state = state
        return HSplitView {
            ScrollView {
                VStack(spacing: 0) {
                    ToolPanel(state: state)
                    Divider()
                    PalettePanel(state: state)
                }
            }
            .frame(minWidth: 170, idealWidth: 200, maxWidth: 280)

            MetalSceneView(state: state)
                .overlay {
                    SceneOverlay()
                        .corner(.topTrailing) {
                            Picker("Mode", selection: $state.renderMode) {
                                Text("Edit").tag(BridgeRenderMode.edit)
                                Text("Render").tag(BridgeRenderMode.render)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 150)
                            .hudPanel()
                        }
                }
                .frame(minWidth: 500, idealWidth: 900)
                .layoutPriority(1)

            ScrollView {
                VStack(spacing: 0) {
                    ModelPanel()
                    Divider()
                    RenderPanel(state: state)
                    Divider()
                    LightPanel(state: state)
                    Divider()
                    SelectionPanel()
                }
            }
            .frame(minWidth: 270, idealWidth: 280, maxWidth: 360)
        }
    }
}
