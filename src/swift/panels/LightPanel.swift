import AppKit
import SwiftUI

struct LightPanel: View {
    @Bindable var state: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Path tracer")
            row(label: "Bounces") {
                IntSliderRow(value: $state.maxBounces, range: 1...8)
            }
            Toggle("Power-weighted NEE", isOn: $state.powerWeightedNEE)
                .help("Pick direct-light samples weighted by per-light power. Off = uniform.")
            row(label: "RIS samples") {
                IntSliderRow(value: $state.neeRisCount, range: 1...32)
            }

            sectionHeader("Sky")
            Toggle("Atmospheric sky", isOn: $state.atmosphericSky)
                .help("Nishita scattering. Off = flat sky_intensity tint.")
            row(label: "Intensity") {
                FloatSliderRow(value: $state.skyIntensity, range: 0...4,
                               format: "%.2f")
            }
            .disabled(state.atmosphericSky)
            row(label: "Horizon") {
                FloatSliderRow(value: $state.horizonSoftnessDeg, range: 0...15,
                               format: "%.1f°")
            }
            .help("Aerial-perspective fade at the ground/sky meeting line. 0 = sharp.")

            sectionHeader("Sun")
            row(label: "Elevation") {
                FloatSliderRow(value: $state.sunElevationDeg, range: -90...90,
                               format: "%.0f°")
            }
            row(label: "Azimuth") {
                FloatSliderRow(value: $state.sunAzimuthDeg, range: 0...360,
                               format: "%.0f°")
            }
            row(label: "Disc size") {
                FloatSliderRow(value: $state.sunAngularDiameterDeg,
                               range: 0.1...30, format: "%.1f°")
            }
            row(label: "Intensity") {
                FloatSliderRow(value: $state.sunIntensity, range: 0...10,
                               format: "%.2f")
            }
            HStack {
                Text("Color")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                ColorPicker("Color", selection: sunColorBinding, supportsOpacity: false)
                    .labelsHidden()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var sunColorBinding: Binding<Color> {
        Binding(
            get: {
                let (r, g, b) = state.sunColor
                return Color(red: Double(r), green: Double(g), blue: Double(b))
            },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? .white
                state.sunColor = (Float(ns.redComponent),
                                  Float(ns.greenComponent),
                                  Float(ns.blueComponent))
            }
        )
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func row<Content: View>(label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            content()
        }
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
