import SwiftUI

struct RenderPanel: View {
    @Bindable var state: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Mode")
            Picker("Mode", selection: Binding(
                get: { state.pathTraced },
                set: { state.pathTraced = $0 }
            )) {
                Text("Edit").tag(false)
                Text("Render").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

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
                    ), in: 16...8192)
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

            Divider().padding(.vertical, 4)
            MaterialEditor(state: state)

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

private struct MaterialEditor: View {
    @Bindable var state: EditorState
    @State private var coalesceTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Material")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            indexLabel

            HStack(spacing: 8) {
                Text("Type")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Picker("Type", selection: typeBinding) {
                    Text("Diffuse").tag(BridgeMaterialType.diffuse)
                    Text("Metal").tag(BridgeMaterialType.metal)
                    Text("Emissive").tag(BridgeMaterialType.emissive)
                    Text("Glass").tag(BridgeMaterialType.glass)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            slider("Roughness", value: floatBinding(get: { state.activeMaterialRoughness },
                                                    apply: state.applyMaterialRoughness),
                   range: 0...1, format: "%.2f")
            slider("Metallic", value: floatBinding(get: { state.activeMaterialMetallic },
                                                   apply: state.applyMaterialMetallic),
                   range: 0...1, format: "%.2f")
            slider("Emission",
                   value: floatBinding(
                       get: { state.activeMaterialEmission * 100.0 },
                       apply: { state.applyMaterialEmission($0 * 0.01) }),
                   range: 0...100, format: "%.0f")
            slider("Power",
                   value: floatBinding(
                       get: { Float(state.activeMaterialEmissionPower) },
                       apply: { state.applyMaterialEmissionPower(Int($0.rounded())) }),
                   range: 1...5, format: "%.0f", step: 1)
            slider("Transparency",
                   value: floatBinding(get: { state.activeMaterialTransparency },
                                       apply: state.applyMaterialTransparency),
                   range: 0...1, format: "%.2f")
            slider("IoR",
                   value: floatBinding(get: { state.activeMaterialIor },
                                       apply: state.applyMaterialIor),
                   range: 1...3, format: "%.2f")
        }
        .disabled(state.activePaletteSlot == 0)
    }

    private var indexLabel: some View {
        let n = state.selectedSlotCount
        let active = state.activePaletteSlot
        return Group {
            if n > 1 {
                Text("Index \(active)  (+\(n - 1) more selected)")
            } else {
                Text("Index \(active)")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }

    private func slider(_ label: String, value: Binding<Float>,
                        range: ClosedRange<Float>, format: String,
                        step: Float = 0) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            sliderControl(value: value, range: range, step: step)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func sliderControl(value: Binding<Float>,
                               range: ClosedRange<Float>, step: Float) -> some View {
        let binding = Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = Float($0) }
        )
        let lo = Double(range.lowerBound)
        let hi = Double(range.upperBound)
        // Slider's `step:` requires > 0; pass it only when the caller
        // wants quantised values.
        if step > 0 {
            Slider(value: binding, in: lo...hi, step: Double(step))
        } else {
            Slider(value: binding, in: lo...hi)
        }
    }

    private var typeBinding: Binding<BridgeMaterialType> {
        Binding(
            get: { state.activeMaterialType },
            set: { newType in
                state.beginMaterialEdit()
                state.applyMaterialType(newType)
                scheduleCommit()
            }
        )
    }

    private func floatBinding(get: @escaping () -> Float,
                              apply: @escaping (Float) -> Void) -> Binding<Float> {
        Binding(
            get: get,
            set: { newValue in
                state.beginMaterialEdit()
                apply(newValue)
                scheduleCommit()
            }
        )
    }

    private func scheduleCommit() {
        coalesceTimer?.invalidate()
        coalesceTimer = Timer.scheduledTimer(withTimeInterval: 0.4,
                                             repeats: false) { _ in
            state.commitMaterialEdit()
        }
    }
}
