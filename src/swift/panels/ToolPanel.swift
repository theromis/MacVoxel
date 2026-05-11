import SwiftUI

struct ToolPanel: View {
    @Bindable var state: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Tool")
            toolGrid

            sectionHeader("Mode")
            modeRow

            if showsBrushFootprint {
                sectionHeader("Brush")
                brushControls
                Text(brushSummary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            perToolControls

            Spacer(minLength: 0)
        }
        .padding(12)
    }

    // ----- Tool grid -----

    private var toolGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4),
                            count: 2)
        return LazyVGrid(columns: columns, spacing: 4) {
            toolButton("Brush", .brush)
            toolButton("Line", .line)
            toolButton("Circle", .circle)
            toolButton("Square", .square)
            toolButton("Box", .box)
            toolButton("Face", .face)
            toolButton("Generator", .generator)
            toolButton("Marquee", .marquee)
            toolButton("Box-sel", .boxSelect)
            toolButton("Flood-sel", .floodSelect)
        }
    }

    private func toolButton(_ label: String, _ kind: BridgeToolKind) -> some View {
        Button(action: { state.toolKind = kind }) {
            Text(label)
                .font(.system(size: 11, weight: state.toolKind == kind ? .semibold : .regular))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(state.toolKind == kind ? .accentColor : .secondary)
    }

    // ----- Mode -----

    private var modeRow: some View {
        Picker("Mode", selection: $state.toolMode) {
            Text("Add").tag(BridgeToolMode.add)
            Text("Remove").tag(BridgeToolMode.remove)
            Text("Paint").tag(BridgeToolMode.paint)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    // ----- Brush -----

    private var showsBrushFootprint: Bool {
        state.toolKind != .face && state.toolKind != .generator
    }

    @ViewBuilder
    private var brushControls: some View {
        HStack(spacing: 6) {
            Slider(value: Binding(
                get: { Double(state.brushSize) },
                set: { state.brushSize = Int($0.rounded()) }
            ), in: 1...63, step: 1)
            Text("\(state.brushSize)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
        Picker("Shape", selection: $state.brushShape) {
            Text("Square").tag(BridgeBrushShape.square)
            Text("Circle").tag(BridgeBrushShape.circle)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        Picker("Dim", selection: $state.brush3D) {
            Text("2D").tag(false)
            Text("3D").tag(true)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var brushSummary: String {
        let edge = max(1, state.brushSize)
        let lo = -((edge - 1) / 2)
        let hi = edge / 2
        let c = Float(lo + hi) * 0.5
        let halfEdge = Float(edge) * 0.5
        let r2 = halfEdge * halfEdge
        var cells = 0
        for dz in lo...hi {
            if !state.brush3D && dz != 0 { continue }
            for dy in lo...hi {
                for dx in lo...hi {
                    if state.brushShape == .circle {
                        let fx = Float(dx) - c
                        let fy = Float(dy) - c
                        let fz = state.brush3D ? Float(dz) - c : 0
                        if fx*fx + fy*fy + fz*fz > r2 { continue }
                    }
                    cells += 1
                }
            }
        }
        if state.brush3D {
            return "\(edge) × \(edge) × \(edge)  (\(cells) cells)"
        }
        return "\(edge) × \(edge)  (\(cells) cells, on face plane)"
    }

    // ----- Per-tool extras -----

    @ViewBuilder
    private var perToolControls: some View {
        switch state.toolKind {
        case .line:
            sectionHeader("Line")
            Picker("Line", selection: $state.lineMode) {
                Text("Straight").tag(BridgeLineMode.straight)
                Text("Project").tag(BridgeLineMode.project)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        case .circle:
            sectionHeader("Circle")
            HStack {
                Toggle("Fill", isOn: $state.circleFill).toggleStyle(.button)
                Toggle("Even", isOn: $state.circleEven).toggleStyle(.button)
            }
        case .square:
            sectionHeader("Square")
            HStack {
                Toggle("Fill", isOn: $state.squareFill).toggleStyle(.button)
                Toggle("Even", isOn: $state.squareEven).toggleStyle(.button)
            }
        case .box:
            sectionHeader("Box")
            Toggle("Fill", isOn: $state.boxFill).toggleStyle(.button)
        case .face:
            sectionHeader("Face")
            VStack(alignment: .leading, spacing: 6) {
                labelledPicker("Extrude",
                               selection: $state.faceExtrude,
                               options: [(.color, "Color"), (.geometry, "Geometry")])
                labelledPicker("With",
                               selection: $state.faceWith,
                               options: [(.geometry, "Geometry"), (.palette, "Palette")])
                labelledPicker("Connectivity",
                               selection: $state.faceEightConnected,
                               options: [(false, "4-side"), (true, "8-side")])
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func labelledPicker<T: Hashable>(_ label: String,
                                             selection: Binding<T>,
                                             options: [(T, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
            Picker(label, selection: selection) {
                ForEach(options, id: \.0) { (value, name) in
                    Text(name).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}
