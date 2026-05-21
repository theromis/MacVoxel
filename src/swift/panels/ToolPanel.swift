import SwiftUI

struct ToolPanel: View {
    @Bindable var state: EditorState

    // Cached brush cell count. Recomputing inline every body run was an
    // O(edge³) Swift loop firing 10×/sec via the EditorState tick timer
    // — at brush_size=63 that's 2.5M iterations/sec on the main thread,
    // enough to stall MTKView's draw and tank camera-orbit framerate.
    // Now recomputed only when one of the brush settings actually
    // changes.
    @State private var cachedBrushCells: Int = 0

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
                    .onAppear { recomputeBrushCells() }
                    .onChange(of: state.brushSize) { _, _ in recomputeBrushCells() }
                    .onChange(of: state.brush3D) { _, _ in recomputeBrushCells() }
                    .onChange(of: state.brushShape) { _, _ in recomputeBrushCells() }
            }

            perToolControls

            Spacer(minLength: 0)
        }
        .padding(12)
    }

    // ----- Tool grid -----

    private struct ToolDef {
        let kind: BridgeToolKind
        let symbol: String
        let label: String
        let key: String?
    }

    private static let tools: [ToolDef] = [
        .init(kind: .brush,       symbol: "paintbrush.pointed.fill",                  label: "Brush",       key: "V"),
        .init(kind: .line,        symbol: "pencil.line",                              label: "Line",        key: "L"),
        .init(kind: .circle,      symbol: "circle.fill",                              label: "Circle",      key: nil),
        .init(kind: .square,      symbol: "square.fill",                              label: "Square",      key: nil),
        .init(kind: .box,         symbol: "cube.fill",                                label: "Box",         key: "B"),
        .init(kind: .face,        symbol: "rectangle.portrait.and.arrow.right.fill",  label: "Face",        key: "F"),
        .init(kind: .generator,   symbol: "gearshape.2.fill",                         label: "Generator",   key: nil),
        .init(kind: .mutator,     symbol: "leaf.fill",                                label: "Mutator",     key: "U"),
        .init(kind: .marquee,     symbol: "square.dashed",                            label: "Marquee",     key: "M"),
        .init(kind: .boxSelect,   symbol: "cube.transparent.fill",                    label: "Box Select",  key: nil),
        .init(kind: .floodSelect, symbol: "paintbrush.fill",                          label: "Flood Select", key: nil),
    ]

    private var toolGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4),
                            count: 2)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Self.tools, id: \.kind) { tool in
                toolButton(tool)
            }
        }
    }

    private func toolButton(_ tool: ToolDef) -> some View {
        let selected = state.toolKind == tool.kind
        let tooltip = tool.key.map { "\(tool.label) (\($0))" } ?? tool.label
        return Button(action: { state.toolKind = tool.kind }) {
            Image(systemName: tool.symbol)
                .font(.system(size: 16))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.accentColor
                                       : Color.gray.opacity(0.12))
                )
                .contentShape(Rectangle())
                .help(tooltip)
        }
        .buttonStyle(.plain)
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
    // Mutator falls into the showsBrushFootprint=true branch above
    // because it reuses the brush AOE controls — no extra wiring here.

    @ViewBuilder
    private var brushControls: some View {
        HStack(spacing: 6) {
            Slider(value: Binding(
                get: { Double(state.brushSize) },
                set: { state.brushSize = Int($0.rounded()) }
            ), in: 1...63)
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
        if state.brush3D {
            return "\(edge) × \(edge) × \(edge)  (\(cachedBrushCells) cells)"
        }
        return "\(edge) × \(edge)  (\(cachedBrushCells) cells, on face plane)"
    }

    private func recomputeBrushCells() {
        let edge = max(1, state.brushSize)
        let lo = -((edge - 1) / 2)
        let hi = edge / 2
        let c = Float(lo + hi) * 0.5
        let halfEdge = Float(edge) * 0.5
        let r2 = halfEdge * halfEdge
        let isCircle = state.brushShape == .circle
        let is3D = state.brush3D
        var cells = 0
        for dz in lo...hi {
            if !is3D && dz != 0 { continue }
            for dy in lo...hi {
                for dx in lo...hi {
                    if isCircle {
                        let fx = Float(dx) - c
                        let fy = Float(dy) - c
                        let fz = is3D ? Float(dz) - c : 0
                        if fx*fx + fy*fy + fz*fz > r2 { continue }
                    }
                    cells += 1
                }
            }
        }
        cachedBrushCells = cells
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
        case .generator:
            sectionHeader("Generator")
            Picker("Kind", selection: $state.generatorKind) {
                Text("Ellipsoid").tag(BridgeGeneratorKind.ellipsoid)
                Text("Cylinder").tag(BridgeGeneratorKind.cylinder)
                Text("Cone").tag(BridgeGeneratorKind.cone)
                Text("Pyramid").tag(BridgeGeneratorKind.pyramid)
                Text("Torus").tag(BridgeGeneratorKind.torus)
                Text("Perlin").tag(BridgeGeneratorKind.perlin)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            GeneratorControls(state: state)
        case .mutator:
            sectionHeader("Mutator")
            MutatorControls(state: state)
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
