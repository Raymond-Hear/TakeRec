import AppKit
import SwiftUI

enum WorkbenchStyle {
    static let workspace = adaptive(0xF1F2F5, 0x1C1E24)
    static let panel = adaptive(0xFCFCFD, 0x25272E)
    static let canvas = adaptive(0xE3E5EB, 0x14161B)
    static let lane = adaptive(0xF1F2F6, 0x1D1F26)
    static let line = adaptive(0xD9DBE3, 0x3D404A)
    static let accent = adaptive(0x6546B5, 0xC0ABFF)
    static let action = adaptive(0x6546B5, 0x7554B7)
    static let record = adaptive(0xB5394B, 0xAC3949)
    static let marker = adaptive(0xA45522, 0xF4AD72)

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let color = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((color >> 16) & 255) / 255,
                           green: CGFloat((color >> 8) & 255) / 255,
                           blue: CGFloat(color & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func workbenchPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        return background(WorkbenchStyle.panel, in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(WorkbenchStyle.line).allowsHitTesting(false) }
    }
}

struct DeskIcon: View {
    let name: String
    var size: CGFloat = 16

    init(_ name: String, size: CGFloat = 16) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image("icon-\(name)")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct DeskPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var color = Color.accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(enabled ? Color.white : Color.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(enabled ? color.opacity(configuration.isPressed ? 0.76 : 1) : Color.secondary.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

extension TrackKind {
    var icon: String {
        switch self {
        case .screen: "monitor"
        case .camera, .camera2, .camera3: "video"
        case .microphone: "mic"
        case .system, .originalAudio: "audio-lines"
        }
    }

    var color: Color {
        switch self {
        case .screen: WorkbenchStyle.adaptive(0x4A68AC, 0xA1B8FC)
        case .camera: WorkbenchStyle.adaptive(0x8354AA, 0xD6A9F2)
        case .camera2: WorkbenchStyle.adaptive(0xAE5B72, 0xF1AFC1)
        case .camera3: WorkbenchStyle.adaptive(0x896720, 0xE9CB81)
        case .system: WorkbenchStyle.adaptive(0x2D797D, 0x8BD8D7)
        case .microphone: WorkbenchStyle.adaptive(0x46753F, 0xA8D38E)
        case .originalAudio: WorkbenchStyle.adaptive(0x675A9C, 0xB8ACE9)
        }
    }
}

func timelineTime(_ time: Double) -> String {
    let ticks = Int(clamp((time * 100).rounded(), 0, Double(Int32.max)))
    return String(format: "%02d:%02d.%02d", ticks / 6000, ticks / 100 % 60, ticks % 100)
}
