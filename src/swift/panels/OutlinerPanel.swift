import SwiftUI

// Scene-graph object list: click selects, double-click makes the
// object active (edits bind to it), context menu renames. Works in
// both modes; the viewport outline only shows in Object mode.
struct OutlinerPanel: View {
    @Bindable var state: EditorState

    @State private var renameIndex: Int? = nil
    @State private var renameText: String = ""

    var body: some View {
        let names = state.objectNames
        let selected = state.selectedObjectIndex
        let active = state.activeObjectIndex

        VStack(alignment: .leading, spacing: 8) {
            Text("Objects")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            VStack(spacing: 1) {
                ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                    row(index: i, name: name,
                        isSelected: i == selected, isActive: i == active)
                }
            }

            HStack(spacing: 6) {
                Button("New") { state.newEmptyObject() }
                Button("Duplicate") { state.duplicateObject() }
                    .disabled(!state.canDuplicateObject)
                Button("Delete") { state.deleteSelectedObject() }
                    .disabled(!state.canDeleteSelectedObject)
            }
            .font(.system(size: 11))

            // Selected object's box size, shown as world-axis extents.
            HStack(spacing: 4) {
                Text("Size")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                sizeField(value: $state.selectedObjectSizeX)
                sizeField(value: $state.selectedObjectSizeY)
                sizeField(value: $state.selectedObjectSizeZ)
            }
            .disabled(!state.canResizeSelectedObject)
        }
        .padding(12)
        .alert("Rename Object", isPresented: renameBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let i = renameIndex {
                    state.renameObject(at: i, name: renameText)
                }
                renameIndex = nil
            }
            Button("Cancel", role: .cancel) { renameIndex = nil }
        }
    }

    private func sizeField(value: Binding<Int>) -> some View {
        TextField("", value: Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = max(1, min($0, 256)) }
        ), formatter: NumberFormatter())
            .textFieldStyle(.roundedBorder)
            .frame(width: 46)
            .font(.system(size: 11, design: .monospaced))
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameIndex != nil },
                set: { if !$0 { renameIndex = nil } })
    }

    private func row(index: Int, name: String,
                     isSelected: Bool, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Color.accentColor : Color.clear)
                .frame(width: 6, height: 6)
            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.25)
                                 : Color.clear)
        )
        .contentShape(Rectangle())
        // Double-tap declared first so it wins over the single-tap.
        .onTapGesture(count: 2) {
            state.selectedObjectIndex = index
            state.activateObject(at: index)
        }
        .onTapGesture {
            state.selectedObjectIndex = index
        }
        .contextMenu {
            Button("Rename\u{2026}") {
                renameText = name
                renameIndex = index
            }
            Button("Make Active") {
                state.selectedObjectIndex = index
                state.activateObject(at: index)
            }
        }
    }
}
