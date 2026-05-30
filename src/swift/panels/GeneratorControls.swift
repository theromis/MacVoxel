import SwiftUI

// Embedded content view used inside ToolPanel's per-tool section when
// the Generator tool is active. Owns no outer chrome (no padding, no
// Spacer, no section header) — the host supplies that.
struct GeneratorControls: View {
    @Bindable var state: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state.generatorKind {
            case .ellipsoid:
                Text("(shape derives from bounds)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            case .cylinder:
                axisRow
            case .cone, .pyramid:
                axisRow
                apexRow
            case .torus:
                axisRow
                torusRows
            case .perlin:
                perlinRows
            case .tree:
                axisRow
                treeRows
            case .helix:
                axisRow
                helixRows
            case .conifer:
                axisRow
                coniferRows
            @unknown default:
                EmptyView()
            }
        }
    }

    private var axisRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Axis").font(.system(size: 10)).foregroundStyle(.tertiary)
            Picker("Axis", selection: axisBinding) {
                Text("X").tag(BridgeAxis.x)
                Text("Y").tag(BridgeAxis.y)
                Text("Z").tag(BridgeAxis.z)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var apexRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Apex at").font(.system(size: 10)).foregroundStyle(.tertiary)
            Picker("Apex", selection: apexBinding) {
                Text("Min").tag(false)
                Text("Max").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var torusRows: some View {
        labeled("Tube") {
            FloatSliderRow(
                value: Binding(
                    get: { state.generatorTorusTube },
                    set: { state.generatorTorusTube = $0 }
                ),
                range: 0.05...1.0,
                format: "%.2f")
        }
    }

    @ViewBuilder
    private var treeRows: some View {
        labeled("Depth") {
            IntSliderRow(
                value: Binding(
                    get: { state.generatorPerlinOctaves },
                    set: { state.generatorPerlinOctaves = $0 }
                ),
                range: 1...5)
        }
        labeled("Wildness") {
            FloatSliderRow(
                value: Binding(
                    get: { state.generatorPerlinThreshold },
                    set: { state.generatorPerlinThreshold = $0 }
                ),
                range: 0.0...1.0,
                format: "%.2f")
        }
        labeled("Trunk radius") {
            FloatSliderRow(
                value: Binding(
                    get: { state.generatorTorusTube },
                    set: { state.generatorTorusTube = $0 }
                ),
                range: 0.20...1.50,
                format: "%.2f")
        }
        labeled("Leaf color") {
            paletteIndexRow(binding: Binding(
                get: { state.generatorPerlinPaletteHi },
                set: { state.generatorPerlinPaletteHi = $0 }
            ))
        }
        labeled("Seed") {
            HStack(spacing: 6) {
                TextField("", value: Binding(
                    get: { state.generatorPerlinSeed },
                    set: { state.generatorPerlinSeed = $0 }
                ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("Randomize") {
                    state.generatorPerlinSeed = Int.random(in: 1...Int(Int32.max))
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var coniferRows: some View {
        labeled("Tiers") {
            IntSliderRow(
                value: Binding(
                    get: { state.generatorPerlinOctaves },
                    set: { state.generatorPerlinOctaves = $0 }
                ),
                range: 2...5)
        }
        labeled("Raggedness") {
            FloatSliderRow(
                value: Binding(
                    get: { state.generatorPerlinThreshold },
                    set: { state.generatorPerlinThreshold = $0 }
                ),
                range: 0.0...1.0,
                format: "%.2f")
        }
        labeled("Clump size") {
            FloatSliderRow(
                value: Binding(
                    get: { state.generatorPerlinScale },
                    set: { state.generatorPerlinScale = $0 }
                ),
                range: 2.0...24.0,
                format: "%.1f")
        }
        labeled("Trunk radius") {
            FloatSliderRow(
                value: Binding(
                    get: { state.generatorTorusTube },
                    set: { state.generatorTorusTube = $0 }
                ),
                range: 0.20...1.50,
                format: "%.2f")
        }
        labeled("Crown blend") {
            FloatSliderRow(
                value: Binding(
                    get: { state.generatorHelixRadius },
                    set: { state.generatorHelixRadius = $0 }
                ),
                range: 0.0...1.0,
                format: "%.2f")
        }
        labeled("Needle color") {
            paletteIndexRow(binding: Binding(
                get: { state.generatorPerlinPaletteHi },
                set: { state.generatorPerlinPaletteHi = $0 }
            ))
        }
        labeled("Seed") {
            HStack(spacing: 6) {
                TextField("", value: Binding(
                    get: { state.generatorPerlinSeed },
                    set: { state.generatorPerlinSeed = $0 }
                ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("Randomize") {
                    state.generatorPerlinSeed = Int.random(in: 1...Int(Int32.max))
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var helixRows: some View {
        labeled("Turns") {
            FloatSliderRow(
                value: Binding(
                    get: { state.generatorHelixTurns },
                    set: { state.generatorHelixTurns = $0 }
                ),
                range: 0.25...12.0,
                format: "%.2f")
        }
        labeled("Radius") {
            FloatSliderRow(
                value: Binding(
                    get: { state.generatorHelixRadius },
                    set: { state.generatorHelixRadius = $0 }
                ),
                range: 0.0...1.0,
                format: "%.2f")
        }
        labeled("Tube") {
            FloatSliderRow(
                value: Binding(
                    get: { state.generatorHelixTube },
                    set: { state.generatorHelixTube = $0 }
                ),
                range: 0.02...0.90,
                format: "%.2f")
        }
        labeled("Winding") {
            Picker("Winding", selection: helixClockwiseBinding) {
                Text("CCW").tag(false)
                Text("CW").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var perlinRows: some View {
        labeled("Scale") {
            FloatSliderRow(
                value: Binding(
                    get: { state.generatorPerlinScale },
                    set: { state.generatorPerlinScale = $0 }
                ),
                range: 1.0...64.0,
                format: "%.1f")
        }
        labeled("Threshold") {
            FloatSliderRow(
                value: Binding(
                    get: { state.generatorPerlinThreshold },
                    set: { state.generatorPerlinThreshold = $0 }
                ),
                range: 0.0...1.0,
                format: "%.2f")
        }
        labeled("Octaves") {
            IntSliderRow(
                value: Binding(
                    get: { state.generatorPerlinOctaves },
                    set: { state.generatorPerlinOctaves = $0 }
                ),
                range: 1...6)
        }
        labeled("Seed") {
            HStack(spacing: 6) {
                TextField("", value: Binding(
                    get: { state.generatorPerlinSeed },
                    set: { state.generatorPerlinSeed = $0 }
                ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("Randomize") {
                    state.generatorPerlinSeed = Int.random(in: 1...Int(Int32.max))
                }
                .controlSize(.small)
            }
        }
        labeled("Palette range") {
            paletteIndexRow(binding: Binding(
                get: { state.generatorPerlinPaletteLo },
                set: { state.generatorPerlinPaletteLo = $0 }
            ))
            paletteIndexRow(binding: Binding(
                get: { state.generatorPerlinPaletteHi },
                set: { state.generatorPerlinPaletteHi = $0 }
            ))
            gradientStrip
                .frame(height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    private func paletteIndexRow(binding: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Slider(value: Binding(
                get: { Double(binding.wrappedValue) },
                set: { binding.wrappedValue = Int($0.rounded()) }
            ), in: 0...255)
            paletteSwatch(index: binding.wrappedValue)
            Text("\(binding.wrappedValue)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    private func paletteSwatch(index: Int) -> some View {
        Rectangle()
            .fill(paletteColor(index: index))
            .frame(width: 14, height: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.primary.opacity(0.2), lineWidth: 0.5)
            )
    }

    private var gradientStrip: some View {
        let lo = state.generatorPerlinPaletteLo
        let hi = state.generatorPerlinPaletteHi
        let count = abs(hi - lo) + 1
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                let idx = lo + (hi >= lo ? i : -i)
                paletteColor(index: idx)
            }
        }
    }

    private func paletteColor(index: Int) -> Color {
        let rgba = state.bridge.paletteColor(at: index)
        let r = Double((rgba >> 0)  & 0xff) / 255.0
        let g = Double((rgba >> 8)  & 0xff) / 255.0
        let b = Double((rgba >> 16) & 0xff) / 255.0
        let a = Double((rgba >> 24) & 0xff) / 255.0
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    private func labeled<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(.tertiary)
            content()
        }
    }

    private var axisBinding: Binding<BridgeAxis> {
        Binding(get: { state.generatorAxis },
                set: { state.generatorAxis = $0 })
    }

    private var apexBinding: Binding<Bool> {
        Binding(get: { state.generatorApexAtMax },
                set: { state.generatorApexAtMax = $0 })
    }

    private var helixClockwiseBinding: Binding<Bool> {
        Binding(get: { state.generatorHelixClockwise },
                set: { state.generatorHelixClockwise = $0 })
    }
}

private struct FloatSliderRow: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: String

    var body: some View {
        HStack(spacing: 6) {
            Slider(value: Binding(
                get: { Double(value) },
                set: { value = Float($0) }
            ), in: Double(range.lowerBound)...Double(range.upperBound))
            Text(String(format: format, value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

private struct IntSliderRow: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 6) {
            Slider(value: Binding(
                get: { Double(value) },
                set: { value = Int($0.rounded()) }
            ), in: Double(range.lowerBound)...Double(range.upperBound),
            step: 1)
            Text("\(value)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }
}
