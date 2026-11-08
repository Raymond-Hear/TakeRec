import SwiftUI

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
        case .camera: "video"
        case .microphone: "mic"
        case .system, .originalAudio: "audio-lines"
        }
    }

    var color: Color {
        switch self {
        case .screen: .blue
        case .camera: .purple
        case .system: .teal
        case .microphone: .green
        case .originalAudio: .indigo
        }
    }
}

func timelineTime(_ time: Double) -> String {
    let ticks = Int(clamp((time * 100).rounded(), 0, Double(Int32.max)))
    return String(format: "%02d:%02d.%02d", ticks / 6000, ticks / 100 % 60, ticks % 100)
}
