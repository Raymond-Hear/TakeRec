import CoreImage
import SwiftUI

struct PortraitLighting: Codable, Equatable, Sendable {
    var exposure = 0.0
    var highlights = 0.0
    var sharpness = 0.0

    func apply(to image: CIImage) -> CIImage {
        guard self != Self() else { return image }
        var result = image
        if highlights > 0 {
            result = result.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 - clamp(highlights, 0, 1)
            ])
        }
        if exposure != 0 {
            result = result.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: clamp(exposure, -1.5, 1.5)
            ])
        }
        if sharpness > 0 {
            result = result.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: clamp(sharpness, 0, 1) * 0.6
            ])
        }
        return result.cropped(to: image.extent)
    }
}

struct PortraitLightingControls: View {
    @Binding var lighting: PortraitLighting

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("人像调光").font(.subheadline.weight(.semibold))
                Spacer()
                Button("还原") { lighting = PortraitLighting() }
                    .controlSize(.small).disabled(lighting == PortraitLighting())
            }
            slider("曝光", value: $lighting.exposure, in: -1.5...1.5, step: 0.1,
                   label: String(format: "%+.1f", lighting.exposure))
            slider("压高光", value: $lighting.highlights, in: 0...1, step: 0.05, label: percent(lighting.highlights))
            slider("清晰度", value: $lighting.sharpness, in: 0...1, step: 0.05, label: percent(lighting.sharpness))
        }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
                        label: String) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 48, alignment: .leading)
            Slider(value: value, in: range, step: step).controlSize(.small).accessibilityLabel(title)
            Text(label).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
        .font(.caption)
    }

    private func percent(_ value: Double) -> String { "\(Int((clamp(value, 0, 1) * 100).rounded()))%" }
}
