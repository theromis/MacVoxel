import SwiftUI

struct GeneratorPanel: View {
    @Bindable var state: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Generator")
            Picker("Kind", selection: kindBinding) {
                Text("Ellipsoid").tag(BridgeGeneratorKind.ellipsoid)
                Text("Cylinder").tag(BridgeGeneratorKind.cylinder)
                Text("Cone").tag(BridgeGeneratorKind.cone)
                Text("Pyramid").tag(BridgeGeneratorKind.pyramid)
                Text("Perlin").tag(BridgeGeneratorKind.perlin)
            }
            .labelsHidden()
            .pickerStyle(.menu)

            parameters

            Spacer(minLength: 0)
        }
        .padding(12)
    }

    @ViewBuilder
    private var parameters: some View {
        let kind = state.generatorKind
        sectionHeader("Parameters")
        switch kind {
        case .ellipsoid:
            Text("(shape derives from bounds)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        case .cylinder:
            axisRow
        case .cone, .pyramid:
            axisRow
            apexRow
        case .perlin:
            perlinRows
        @unknown default:
            EmptyView()
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

    private var kindBinding: Binding<BridgeGeneratorKind> {
        Binding(get: { state.generatorKind },
                set: { state.generatorKind = $0 })
    }

    private var axisBinding: Binding<BridgeAxis> {
        Binding(get: { state.generatorAxis },
                set: { state.generatorAxis = $0 })
    }

    private var apexBinding: Binding<Bool> {
        Binding(get: { state.generatorApexAtMax },
                set: { state.generatorApexAtMax = $0 })
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
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
