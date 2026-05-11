import AppKit
import SwiftUI

struct PalettePanel: View {
    @Bindable var state: EditorState

    @State private var coalesceTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Palette")
            swatchGrid
            HStack(spacing: 8) {
                Text("Active")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("\(state.activePaletteSlot)")
                    .font(.system(size: 11, design: .monospaced))
                ColorPicker("", selection: activeColorBinding,
                            supportsOpacity: false)
                    .labelsHidden()
            }
            .disabled(state.activePaletteSlot == 0)
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var swatchGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(14), spacing: 2),
                            count: 16)
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(0..<state.paletteSize, id: \.self) { i in
                Swatch(index: i, state: state)
            }
        }
    }

    private var activeColorBinding: Binding<Color> {
        Binding(
            get: {
                let c = state.paletteColor(at: state.activePaletteSlot)
                return Color(rgba: c)
            },
            set: { newColor in
                if state.activePaletteSlot == 0 { return }
                let (r, g, b, a) = NSColorComponents(newColor)
                state.beginPaletteEdit()
                state.applyPaletteColor(r: r, g: g, b: b, a: a)
                coalesceTimer?.invalidate()
                coalesceTimer = Timer.scheduledTimer(withTimeInterval: 0.4,
                                                    repeats: false) { _ in
                    state.commitPaletteEdit()
                }
            }
        )
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}

private struct Swatch: View {
    let index: Int
    @Bindable var state: EditorState

    var body: some View {
        let isActive = state.activePaletteSlot == index
        let isSelected = state.isPaletteSlotSelected(index)
        let color = Color(rgba: state.paletteColor(at: index))
        ZStack {
            // Index 0 = empty slot: render a faded checkerboard hint
            // so it reads as non-paintable.
            if index == 0 {
                Rectangle()
                    .fill(.tertiary.opacity(0.3))
                Image(systemName: "xmark")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            } else {
                Rectangle().fill(color)
            }
        }
        .frame(width: 14, height: 14)
        .overlay(
            RoundedRectangle(cornerRadius: 1)
                .strokeBorder(
                    isActive ? Color.accentColor :
                        isSelected ? Color.white.opacity(0.7) :
                        Color.black.opacity(0.18),
                    lineWidth: isActive ? 2 : (isSelected ? 1.5 : 0.5))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let shift = NSEvent.modifierFlags.contains(.shift)
            state.selectPaletteSlot(index, extend: shift)
        }
    }
}

private extension Color {
    init(rgba: UInt32) {
        let a = Double((rgba >> 24) & 0xff) / 255.0
        let r = Double((rgba >> 16) & 0xff) / 255.0
        let g = Double((rgba >>  8) & 0xff) / 255.0
        let b = Double( rgba        & 0xff) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

private func NSColorComponents(_ color: Color) -> (UInt8, UInt8, UInt8, UInt8) {
    let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
    let clamp: (CGFloat) -> UInt8 = { v in
        UInt8(max(0, min(255, Int((v * 255.0).rounded()))))
    }
    return (clamp(ns.redComponent),
            clamp(ns.greenComponent),
            clamp(ns.blueComponent),
            clamp(ns.alphaComponent))
}
