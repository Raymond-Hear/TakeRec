import SwiftUI

enum FirstTakeStep {
    case prepare, recording, review, export, complete
}

enum FirstTakeTarget: Hashable {
    case chooseSource, start, stop, play, export

    var number: Int {
        switch self {
        case .chooseSource: 1
        case .start: 2
        case .stop: 3
        case .play: 4
        case .export: 5
        }
    }

    var title: String {
        switch self {
        case .chooseSource: "点这里，选一个窗口"
        case .start: "开始录一小段"
        case .stop: "做完一个操作，点结束"
        case .play: "回看刚才的录制"
        case .export: "导出你的第一个视频"
        }
    }

    var instruction: String {
        switch self {
        case .chooseSource: "在 macOS 的选择器里点一个窗口并确认共享。这次练习只录画面。"
        case .start: "点亮着的按钮，切到刚选的窗口，做一个简单的操作。"
        case .stop: "比如打一行字。停两秒，再点高亮的结束按钮。"
        case .play: "点三角形按钮回看。确认画面后，跟着箭头导出。"
        case .export: "点「导出 MP4…」，选一个保存位置，再点「导出 MP4」。"
        }
    }
}

private struct FirstTakeAnchors: PreferenceKey {
    static let defaultValue: [FirstTakeTarget: Anchor<CGRect>] = [:]

    static func reduce(value: inout [FirstTakeTarget: Anchor<CGRect>], nextValue: () -> [FirstTakeTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func firstTakeTarget(_ target: FirstTakeTarget) -> some View {
        anchorPreference(key: FirstTakeAnchors.self, value: .bounds) { [target: $0] }
    }

    func firstTakeSpotlight(_ target: FirstTakeTarget?, note: String? = nil, shade: Double = 0.46) -> some View {
        overlayPreferenceValue(FirstTakeAnchors.self) { anchors in
            if let target, let anchor = anchors[target] {
                GeometryReader { geometry in
                    let button = geometry[anchor]
                    if button.intersects(CGRect(origin: .zero, size: geometry.size)) {
                        FirstTakeSpotlight(target: target, button: button, size: geometry.size, note: note, shade: shade)
                    }
                }
            }
        }
    }
}

private struct FirstTakeSpotlight: View {
    let target: FirstTakeTarget
    let button: CGRect
    let size: CGSize
    let note: String?
    let shade: Double
    @State private var tipHeight: CGFloat = 98

    var body: some View {
        let canvas = CGRect(origin: .zero, size: size)
        let focus = button.insetBy(dx: -5, dy: -5).intersection(canvas)
        let width = min(290, max(0, size.width - 24))
        let left = min(max(12, focus.midX - width / 2), size.width - width - 12)
        let above = focus.minY > size.height - focus.maxY
        let edge = above ? focus.minY : focus.maxY
        let top = above ? edge - tipHeight - 12 : edge + 12
        let arrowX = min(max(left + 14, focus.midX), left + width - 14)
        let tipY = above ? edge - 2 : edge + 2
        let baseY = above ? top + tipHeight - 1 : top + 1

        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(canvas)
                path.addRoundedRect(in: focus, cornerSize: CGSize(width: 9, height: 9))
            }
            .fill(.black.opacity(shade), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            // Four separate views leave the original button clickable inside the opening.
            ForEach(Array(shadedRegions(around: focus).enumerated()), id: \.offset) { _, region in
                Color.clear
                    .frame(width: region.width, height: region.height)
                    .contentShape(Rectangle())
                    .position(x: region.midX, y: region.midY)
                    .onTapGesture {}
                    .accessibilityHidden(true)
            }

            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(WorkbenchStyle.accent, lineWidth: 2.5)
                .frame(width: focus.width, height: focus.height)
                .position(x: focus.midX, y: focus.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            Path { path in
                path.move(to: CGPoint(x: arrowX - 9, y: baseY))
                path.addLine(to: CGPoint(x: focus.midX, y: tipY))
                path.addLine(to: CGPoint(x: arrowX + 9, y: baseY))
                path.closeSubpath()
            }
            .fill(WorkbenchStyle.panel)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("第一次录制 · \(target.number)/5")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WorkbenchStyle.accent)
                Text(target.title).font(.headline)
                Text(target.instruction)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.orange).lineLimit(3)
                }
            }
            .padding(12)
            .frame(width: width, alignment: .leading)
            .background(WorkbenchStyle.panel, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { tipHeight = $0 }
            .position(x: left + width / 2, y: top + tipHeight / 2)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func shadedRegions(around focus: CGRect) -> [CGRect] {
        [
            CGRect(x: 0, y: 0, width: size.width, height: focus.minY),
            CGRect(x: 0, y: focus.maxY, width: size.width, height: size.height - focus.maxY),
            CGRect(x: 0, y: focus.minY, width: focus.minX, height: focus.height),
            CGRect(x: focus.maxX, y: focus.minY, width: size.width - focus.maxX, height: focus.height)
        ]
    }
}
