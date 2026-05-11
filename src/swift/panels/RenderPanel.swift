import SwiftUI

struct RenderPanel: View {
    @Bindable var state: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Mode")
            Toggle("Path traced", isOn: $state.pathTraced)

            if state.pathTraced {
                Toggle("ACES tonemap", isOn: $state.acesTonemap)

                HStack(spacing: 8) {
                    Text("Glass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Picker("Glass", selection: $state.glassMode) {
                        Text("Probabilistic").tag(BridgeGlassMode.probabilistic)
                        Text("Absorption").tag(BridgeGlassMode.absorption)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .help("Probabilistic: transparency picks refract vs diffuse, tint = surface color regardless.\nAbsorption: always refracts; transparency interpolates tint from full color (0) to clear (1).")

                Toggle("Match window resolution",
                       isOn: $state.resolutionMatchWindow)

                HStack(spacing: 8) {
                    Text("Resolution")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    intField(value: $state.renderWidth, range: 16...16384)
                    Text("×").foregroundStyle(.secondary)
                    intField(value: $state.renderHeight, range: 16...16384)
                }
                .disabled(state.resolutionMatchWindow)

                HStack(spacing: 6) {
                    Text("Samples")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(state.maxSamples) },
                        set: { state.maxSamples = Int($0.rounded()) }
                    ), in: 16...8192, step: 1)
                    Text("\(state.maxSamples)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }

                ProgressView(value: progressFraction) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(state.sampleCount) / \(state.maxSamples)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if state.sampleCount >= state.maxSamples {
                    Text("converged — adjust target or move camera to keep sampling")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Button("Save render\u{2026}") { state.saveRenderDialog() }
                    .disabled(state.sampleCount == 0)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var progressFraction: Double {
        let target = max(1, state.maxSamples)
        return min(1.0, Double(state.sampleCount) / Double(target))
    }

    private func intField(value: Binding<Int>,
                          range: ClosedRange<Int>) -> some View {
        TextField("", value: Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = max(range.lowerBound,
                                            min($0, range.upperBound)) }
        ), formatter: NumberFormatter())
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
            .font(.system(size: 11, design: .monospaced))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}
