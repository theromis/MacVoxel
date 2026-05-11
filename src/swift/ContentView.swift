import SwiftUI

struct ContentView: View {
    @Environment(EditorState.self) private var state

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(spacing: 0) {
                    ToolPanel(state: state)
                    Divider()
                    PalettePanel(state: state)
                }
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)

            MetalSceneView(state: state)
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
                    GeneratorPanel(state: state)
                    Divider()
                    SelectionPanel()
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 400)
        }
    }
}
