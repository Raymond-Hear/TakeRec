import CoreImage.CIFilterBuiltins
import SwiftUI

struct PhonePairingView: View {
    @ObservedObject var link: PhoneLink
    let useInputs: () -> Void
    let renew: () -> Void
    let disconnect: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("手机扫码").font(.title2.bold())
            Text("需要手机机位时，可以用手机浏览器连接。")
                .font(.callout)
            VStack(alignment: .leading, spacing: 5) {
                Text("生成二维码会连接第三方 VDO.Ninja。手机浏览器会请求相机和麦克风权限，音画实时传给 Mac，必要时走加密中继。服务可能处理 IP 和连接信息。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("VDO.Ninja 隐私说明", destination: URL(string: "https://docs.vdo.ninja/help/privacy-and-security-details/vdo.ninja-privacy-policy")!)
            }
            .font(.callout)
            if let url = link.url, let code = qrImage(for: url) {
                Image(decorative: code, scale: 1)
                    .resizable().interpolation(.none)
                    .frame(width: 202, height: 202)
                    .padding(13)
                    .background(.white, in: RoundedRectangle(cornerRadius: 11))
                    .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.black.opacity(0.10)) }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("手机连接二维码")
            }
            if link.active {
                HStack(spacing: 16) {
                    signal("相机", ready: link.hasVideo)
                    signal("麦克风", ready: link.hasAudio)
                }
                Text("二维码只留给自己，使用完请关闭手机网页。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if link.active || link.status != PhoneLink.waitingToPair {
                Text(link.status).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if link.active {
                    Button("重新生成", action: renew)
                    Button("断开") {
                        disconnect()
                        dismiss()
                    }
                }
                Spacer()
                Button("关闭") { dismiss() }
                if link.active {
                    Button("使用手机输入") {
                        useInputs()
                        dismiss()
                    }
                    .buttonStyle(DeskPrimaryButton())
                    .disabled(!link.hasVideo && !link.hasAudio)
                } else {
                    Button("生成二维码", action: renew)
                        .buttonStyle(DeskPrimaryButton())
                }
            }
        }
        .padding(22)
        .frame(width: 444)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func signal(_ label: String, ready: Bool) -> some View {
        Label("\(label)\(ready ? "已连接" : "待连接")", systemImage: ready ? "checkmark.circle.fill" : "circle")
            .font(.caption).foregroundStyle(ready ? Color.teal : Color.secondary)
    }

    private func qrImage(for url: URL) -> CGImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(url.absoluteString.utf8)
        generator.correctionLevel = "M"
        guard let output = generator.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
