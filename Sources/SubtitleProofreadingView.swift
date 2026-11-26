import SwiftUI

struct SubtitleProofreadingView: View {
    @ObservedObject var editor: TakeEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var corrections: [SubtitleCorrection] = []
    @State private var selected: Set<UUID> = []
    @State private var feedback: String?
    @State private var showsError = false
    @State private var progress = 0
    @State private var running = true
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI 校对字幕").font(.title3.weight(.semibold))
            if running {
                ProgressView(value: Double(progress), total: Double(max(1, editor.manifest.subtitleCues.count))) {
                    Text("正在本机校对 · \(progress) / \(editor.manifest.subtitleCues.count)")
                }
            } else if let feedback {
                Text(feedback).font(.callout)
                    .foregroundStyle(showsError ? WorkbenchStyle.marker : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if corrections.isEmpty {
                Spacer(minLength: 0)
            } else {
                review
            }
            HStack {
                Button(running ? "取消" : "关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if showsError {
                    Button("重试") { attempt += 1 }
                } else if !corrections.isEmpty {
                    Button("应用修改（\(selected.count) 条）") { applySelected() }
                        .buttonStyle(DeskPrimaryButton(color: WorkbenchStyle.action))
                        .disabled(selected.isEmpty)
                }
            }
        }
        .padding(18)
        .frame(width: 600, height: 400)
        .task(id: attempt) { await proofread() }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(corrections.count) 条修改建议").font(.headline)
                Spacer()
                Button("全选") { selected = Set(corrections.map(\.id)) }
                    .disabled(selected.count == corrections.count)
                Button("取消全选") { selected.removeAll() }.disabled(selected.isEmpty)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(corrections) { correction in
                        Toggle(isOn: Binding(
                            get: { selected.contains(correction.id) },
                            set: { value in
                                if value { selected.insert(correction.id) }
                                else { selected.remove(correction.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(timelineTime(correction.cue.start))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(correction.cue.text).foregroundStyle(.secondary)
                                Text(correction.replacement)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .padding(.vertical, 7)
                        Divider()
                    }
                }
                .padding(.trailing, 9)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func proofread() async {
        running = true
        showsError = false
        feedback = nil
        progress = 0
        corrections = []
        selected = []
        defer { running = false }
        do {
            corrections = try await SubtitleProofreading.corrections(in: editor.manifest.subtitleCues) { progress = $0 }
            selected = Set(corrections.map(\.id))
            if corrections.isEmpty { feedback = "没有发现需要修改的字幕。" }
        } catch is CancellationError {
            return
        } catch {
            showsError = true
            feedback = error.localizedDescription
        }
    }

    private func applySelected() {
        let chosen = corrections.filter { selected.contains($0.id) }
        if editor.applySubtitleCorrections(chosen) > 0 {
            dismiss()
        } else {
            corrections = []
            selected = []
            showsError = true
            feedback = "这些字幕已变动。请重新校对。"
        }
    }
}
