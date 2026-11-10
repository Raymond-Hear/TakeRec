import SwiftUI

struct AgentEditingPanel: View {
    let canCreateBundle: Bool
    let lastBundle: URL?
    let createBundle: () -> Void
    let importPlan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Agent 剪辑", systemImage: "sparkles").font(.headline)
            Text("把当前工程和分轨原片打包到你选的文件夹，再把提示词粘贴给你的 Agent。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("生成素材包并复制提示词…", action: createBundle)
                .buttonStyle(DeskPrimaryButton(color: WorkbenchStyle.action))
                .disabled(!canCreateBundle)
            if !canCreateBundle {
                Text("时间线里需要保留一段画面。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let lastBundle {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([lastBundle])
                } label: {
                    Label("在访达中显示上次的素材包", systemImage: "folder")
                }
                .buttonStyle(.link)
                .help(lastBundle.path)
            }

            Divider()
            Text("拿到 agent-edit.json 后，可以导入、预览并撤销方案。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("导入剪辑方案…", action: importPlan)
        }
        .font(.callout)
        .controlSize(.regular)
        .padding(16)
        .frame(width: 310, alignment: .leading)
    }
}
