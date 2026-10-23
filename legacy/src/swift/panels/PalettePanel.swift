import AppKit
import SwiftUI

struct PalettePanel: View {
    @Bindable var state: EditorState

    @State private var coalesceTimer: Timer?

    // Drag-rect state. `dragStart` is captured on the first
    // DragGesture event; `dragShift` snapshots the shift modifier at
    // press time so a release-without-shift on a started-with-shift
    // drag still toggles. `dragCurrent` updates per event for the live
    // rectangle overlay.
    @State private var dragStart: GridCell? = nil
    @State private var dragCurrent: GridCell? = nil
    @State private var dragShift: Bool = false

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

    // 8 cols × 32 rows of 14-pt swatches with 2-pt spacing. Total size
    // is fixed so a parent DragGesture can map cursor → (col, row) via
    // integer division on the pitch (16 pt per cell). Slot indexing
    // ascends left→right then bottom→top; the top-right corner is the
    // unpaintable "empty" sentinel (rendered blank).
    private static let cellSize: CGFloat = 14
    private static let spacing: CGFloat = 2
    private static let pitch: CGFloat = cellSize + spacing  // 16
    private static let cols = 8
    private static let rows = 32
    private static var gridWidth: CGFloat {
        CGFloat(cols) * cellSize + CGFloat(cols - 1) * spacing
    }
    private static var gridHeight: CGFloat {
        CGFloat(rows) * cellSize + CGFloat(rows - 1) * spacing
    }

    private var swatchGrid: some View {
        let columns = Array(
            repeating: GridItem(.fixed(Self.cellSize), spacing: Self.spacing),
            count: Self.cols)
        return ZStack(alignment: .topLeading) {
            LazyVGrid(columns: columns, spacing: Self.spacing) {
                ForEach(0..<state.paletteSize, id: \.self) { pos in
                    let row = pos / Self.cols
                    let col = pos % Self.cols
                    let slot = (Self.rows - 1 - row) * Self.cols + col + 1
                    if slot <= 255 {
                        Swatch(index: slot, state: state)
                    } else {
                        Color.clear
                            .frame(width: Self.cellSize, height: Self.cellSize)
                    }
                }
            }
            .frame(width: Self.gridWidth, height: Self.gridHeight,
                   alignment: .topLeading)
            // Live drag-rect overlay: a thin yellow stroke spanning the
            // cells the gesture currently covers. Drawn above the grid
            // so it sits on top of the swatches.
            if let s = dragStart, let c = dragCurrent {
                let rect = pixelRect(from: s, to: c)
                Rectangle()
                    .strokeBorder(Color.yellow, lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: Self.gridWidth, height: Self.gridHeight,
               alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(dragSelect)
    }

    private var dragSelect: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let cur = cellAt(point: value.location)
                if dragStart == nil {
                    let start = cellAt(point: value.startLocation)
                    dragStart = start
                    dragShift = NSEvent.modifierFlags.contains(.shift)
                }
                dragCurrent = cur
            }
            .onEnded { value in
                let end = cellAt(point: value.location)
                let start = dragStart ?? end
                if start == end {
                    // Single-cell click: keep the proper shift-toggle
                    // semantic (toggling the only selected slot is a
                    // no-op, not an empty selection).
                    let slot = slotIndex(at: start)
                    if slot > 0 {
                        state.selectPaletteSlot(slot, extend: dragShift)
                    }
                } else {
                    state.selectPaletteRange(
                        fromCol: start.col, row: start.row,
                        toCol: end.col,   row: end.row,
                        shift: dragShift)
                }
                dragStart = nil
                dragCurrent = nil
                dragShift = false
            }
    }

    private func cellAt(point: CGPoint) -> GridCell {
        let col = max(0, min(Self.cols - 1,
                             Int(point.x / Self.pitch)))
        let row = max(0, min(Self.rows - 1,
                             Int(point.y / Self.pitch)))
        return GridCell(col: col, row: row)
    }

    private func slotIndex(at cell: GridCell) -> Int {
        let n = (Self.rows - 1 - cell.row) * Self.cols + cell.col + 1
        return n >= 256 ? 0 : n
    }

    private func pixelRect(from a: GridCell, to b: GridCell) -> CGRect {
        let minC = min(a.col, b.col)
        let maxC = max(a.col, b.col)
        let minR = min(a.row, b.row)
        let maxR = max(a.row, b.row)
        let x = CGFloat(minC) * Self.pitch
        let y = CGFloat(minR) * Self.pitch
        let w = CGFloat(maxC - minC + 1) * Self.cellSize
            + CGFloat(maxC - minC) * Self.spacing
        let h = CGFloat(maxR - minR + 1) * Self.cellSize
            + CGFloat(maxR - minR) * Self.spacing
        return CGRect(x: x, y: y, width: w, height: h)
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

private struct GridCell: Equatable {
    let col: Int
    let row: Int
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
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        // Compute effective selection size *as the menu would see it
        // post-fixup* — if the right-clicked slot isn't part of the
        // current selection, every action will operate on just {index}.
        let effCount = state.effectiveSelectedSlotCount(anchor: index)
        let hasVoxels = state.hasVoxelSelection
        let hasClipboard = state.hasColorClipboard

        Button("Copy color") {
            state.copyPaletteColor(from: index)
        }
        Button("Paste color") {
            state.pastePaletteColor(anchor: index)
        }.disabled(!hasClipboard)

        Divider()

        Button("Select voxels by color") {
            state.selectVoxelsByColor(anchor: index)
        }.disabled(effCount == 0)
        Button("Paint voxels with selected color") {
            state.paintSelectedVoxelsWithColor(anchor: index)
        }.disabled(!hasVoxels || effCount != 1)
        Button("Paint voxels with random selected colors") {
            state.paintSelectedVoxelsWithRandomColors(anchor: index)
        }.disabled(!hasVoxels || effCount < 2)

        Divider()

        Button("Make gradient") {
            state.makePaletteGradient(anchor: index)
        }.disabled(effCount < 3)
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
