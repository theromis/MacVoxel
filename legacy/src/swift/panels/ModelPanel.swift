import SwiftUI

struct ModelPanel: View {
    @Environment(EditorState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Document")
            Text(documentPathDisplay)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Divider().padding(.vertical, 2)

            sectionHeader("Statistics")
            if state.gridIsEmpty {
                Text("empty")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                let size = state.gridSize
                statRow(label: "Voxels",
                        value: formattedCount(state.gridFilledCount))
                statRow(label: "Size",
                        value: "\(size.x) × \(size.y) × \(size.z)")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var documentPathDisplay: String {
        state.documentPath.isEmpty ? "Untitled" : state.documentPath
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    private func statRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private func formattedCount(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
}
