import SwiftUI

struct SelectionPanel: View {
    @Environment(EditorState.self) private var state

    var body: some View {
        let enabled = state.canTransformSelection
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Rotate 90°")
            axisRow { axis in
                state.rotateSelection(axis: axis, clockwise: false)
            }
            Text("CCW (right-hand rule)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            axisRow { axis in
                state.rotateSelection(axis: axis, clockwise: true)
            }
            Text("CW")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Divider().padding(.vertical, 2)

            sectionHeader("Flip")
            axisRow { axis in
                state.flipSelection(axis: axis)
            }
            Text("Mirror across axis-perpendicular plane")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
        }
        .padding(12)
        .disabled(!enabled)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    private func axisRow(action: @escaping (BridgeAxis) -> Void) -> some View {
        HStack(spacing: 6) {
            axisButton("X") { action(.x) }
            axisButton("Y") { action(.y) }
            axisButton("Z") { action(.z) }
        }
    }

    private func axisButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 36)
        }
    }
}
