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
