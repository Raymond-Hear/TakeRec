import SwiftUI

struct TakeRecAboutButton: View {
    @State private var showing = false

    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Label(version, systemImage: "info.circle")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.secondary)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help("关于简录、项目仓库和创作者")
        .accessibilityLabel("关于简录，版本 \(version)")
        .popover(isPresented: $showing) {
            TakeRecAboutView(version: version)
        }
    }
}

struct TakeRecAboutView: View {
    let version: String
    @State private var hoveringChannel = false
    @State private var pinnedCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: TakeRecBrand.icon)
                    .resizable().scaledToFit()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("简录 TakeRec").font(.headline)
                    Text("版本 \(version)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Link(destination: URL(string: "https://github.com/Raymond-Hear/TakeRec")!) {
                Label("打开 TakeRec 项目仓库", systemImage: "arrow.up.right")
            }
            Divider()
            HStack(spacing: 14) {
                contactDetails
                Divider().frame(height: 132)
                channelCode
            }
        }
        .padding(16)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var contactDetails: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            GridRow {
                Text("创作者").foregroundStyle(.secondary)
                Text("聆风Raymond").fontWeight(.semibold)
            }
            GridRow {
                Text("公众号").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("聆风Raymond").textSelection(.enabled)
                    Button {
                        pinnedCode.toggle()
                    } label: {
                        Image(systemName: "qrcode").foregroundStyle(WorkbenchStyle.accent)
                    }
                    .buttonStyle(.plain)
                    .help(pinnedCode ? "取消固定公众号二维码" : "固定显示公众号二维码")
                    .accessibilityLabel(pinnedCode ? "取消固定公众号二维码" : "显示公众号二维码")
                }
                .onHover { hoveringChannel = $0 }
            }
            GridRow {
                Text("邮箱").foregroundStyle(.secondary)
                Link("heylingfeng@111.com", destination: URL(string: "mailto:heylingfeng@111.com")!)
            }
            GridRow {
                Text("GitHub").foregroundStyle(.secondary)
                Link("@Raymond-Hear", destination: URL(string: "https://github.com/Raymond-Hear")!)
            }
        }
        .font(.callout)
    }

    private var channelCode: some View {
        Group {
            if hoveringChannel || pinnedCode {
                Image("WeChatFollowQRCode")
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .accessibilityLabel("聆风Raymond公众号关注二维码")
            } else {
                VStack(spacing: 7) {
                    Image(systemName: "qrcode").font(.title2)
                    Text("悬停公众号名称扫码").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: 132, height: 132)
    }
}
