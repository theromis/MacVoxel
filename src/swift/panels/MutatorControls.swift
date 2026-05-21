import SwiftUI

// Embedded content view used inside ToolPanel's per-tool section when
// the Mutator tool is active. Same layout convention as
// GeneratorControls — no outer chrome; the host supplies the section
// header + padding.
struct MutatorControls: View {
    @Bindable var state: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Kind is currently fixed to Foliage; the picker still
            // renders so the panel has the same shape as Generator's
            // and the eventual second-kind addition slots in cleanly.
            kindRow
            foliageRows
        }
    }

    private var kindRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Kind")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            // Single-option Picker: keep it as a Picker (not a Text)
            // so the shape matches Generator's panel — the moment a
            // second Mutator kind ships, this row already has the
            // right control type.
            Picker("Kind", selection: .constant(0)) {
                Text("Foliage").tag(0)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(true)
        }
    }

    @ViewBuilder
    private var foliageRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Seed color")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                Slider(value: Binding(
                    get: { Double(state.mutatorFoliageSeedColor) },
                    set: { state.mutatorFoliageSeedColor = Int($0.rounded()) }
                ), in: 1...255)
                paletteSwatch(index: state.mutatorFoliageSeedColor)
                Text("\(state.mutatorFoliageSeedColor)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
            Button("Use active palette slot") {
                state.mutatorFoliageSeedColor = state.activePaletteSlot
            }
            .controlSize(.small)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Density")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                Slider(value: Binding(
                    get: { Double(state.mutatorFoliageDensity) },
                    set: { state.mutatorFoliageDensity = Float($0) }
                ), in: 0.0...1.0)
                Text(String(format: "%.2f", state.mutatorFoliageDensity))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
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

    private func paletteColor(index: Int) -> Color {
        let rgba = state.bridge.paletteColor(at: index)
        let r = Double((rgba >> 0)  & 0xff) / 255.0
        let g = Double((rgba >> 8)  & 0xff) / 255.0
        let b = Double((rgba >> 16) & 0xff) / 255.0
        let a = Double((rgba >> 24) & 0xff) / 255.0
        return Color(red: r, green: g, blue: b, opacity: a)
    }
}
