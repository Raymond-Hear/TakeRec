import CryptoKit
import Foundation

struct AgentEditPlan: Decodable {
    struct Cut: Decodable {
        let start: Double
        let end: Double
    }

    let version: Int
    let base: String
    let cuts: [Cut]
}

enum AgentHandoff {
    private struct Context: Encodable {
        let version = 1
        let project = "Recording.desktake/project.json"
        let base: String
        let duration: Double
    }

    static func makeBundle(project: TakeProject, manifest: TakeManifest, in parent: URL) throws -> URL {
        let files = FileManager.default
        let name = "TakeRec-Agent-\(UUID().uuidString.prefix(8))"
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        let staging = parent.appendingPathComponent(".\(name).staging", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        _ = try project.save(manifest, to: staging.appendingPathComponent("Recording.desktake", isDirectory: true))
        let base = try revision(manifest)
        let context = Context(base: base, duration: manifest.timelineDuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(context).write(to: staging.appendingPathComponent("agent-context.json"))
        try guide(base: base).write(to: staging.appendingPathComponent("AGENT.md"), atomically: true, encoding: .utf8)
        try files.moveItem(at: staging, to: destination)
        return destination
    }

    static func prompt(for folder: URL) -> String {
        """
        请在这个简录素材包中工作：\(folder.path)
        先读 AGENT.md 和 agent-context.json，再读取时间线与有权限分析的素材。
        按我的剪辑要求，生成一份 agent-edit.json 供简录导入。把结果保存在素材包根目录。
        我的剪辑要求：
        """
    }

    static func readPlan(_ url: URL) throws -> AgentEditPlan {
        let limit = 1_000_000
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw RecorderError.message("请选择一个剪辑方案 JSON 文件。")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: limit + 1), data.count <= limit else {
            throw RecorderError.message("剪辑方案文件过大或为空。")
        }
        do {
            return try JSONDecoder().decode(AgentEditPlan.self, from: data)
        } catch {
            throw RecorderError.message("剪辑方案格式有误。请按素材包里的 AGENT.md 生成 JSON。")
        }
    }

    static func apply(_ plan: AgentEditPlan, to manifest: TakeManifest) throws -> [TimelineClip] {
        guard plan.version == 1 else { throw RecorderError.message("剪辑方案的版本暂不支持。") }
        guard try plan.base == revision(manifest) else {
            throw RecorderError.message("时间线和发给 Agent 的版本有差异。请重新生成素材包后再剪辑。")
        }
        guard plan.cuts.count <= 200 else { throw RecorderError.message("一次最多导入 200 个删除时段。") }
        let sorted = plan.cuts.sorted { $0.start < $1.start }
        let duration = manifest.timelineDuration
        guard sorted.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end <= duration &&
                  $0.end - $0.start >= TimelineClip.minimumLength }),
              zip(sorted, sorted.dropFirst()).allSatisfy({ $0.end <= $1.start }) else {
            throw RecorderError.message("剪辑方案的删除区间重叠、越界或短于一帧。")
        }
        let edited = sorted.reversed().reduce(manifest.timelineClips) { clips, cut in
            ClipEdit.removeTime(from: cut.start, to: cut.end, in: clips)
        }
        guard edited.contains(where: { $0.kind.isVideo && manifest.edit($0.kind).enabled && $0.hidden != true }) else {
            throw RecorderError.message("请在剪辑方案中至少保留一段画面。")
        }
        return edited
    }

    private static func revision(_ manifest: TakeManifest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let clips = manifest.timelineClips.sorted { $0.id.uuidString < $1.id.uuidString }
        return SHA256.hash(data: try encoder.encode(clips)).map { String(format: "%02x", $0) }.joined()
    }

    private static func guide(base: String) -> String {
        """
        # 简录 Agent 素材包

        `agent-context.json` 提供时间线总长、当前版本指纹和工程清单位置。`Recording.desktake/` 是此刻的工程副本，含分轨原片。保持副本原样，把剪辑方案写入同级的 `agent-edit.json`。

        `project.json` 的 `clips` 列出片段。`file` 是素材文件，`kind` 标记屏幕、人像、系统声、麦克风或原片音频。每个片段从素材的 `sourceStart` 取 `length` 秒，放在工程的 `at` 秒。一个素材可出现在多个片段。分析声音时优先用 `microphone` 轨，分析画面用 `screen` 轨。把分析得到的素材时间按片段映射回工程时间。

        方案格式示例如下。示例时间须根据实际内容改写。

        ```json
        {
          "version": 1,
          "base": "\(base)",
          "cuts": [{ "start": 1.25, "end": 2.10 }]
        }
        ```

        `base` 从 `agent-context.json` 原样抄入。`cuts` 最多 200 段，区间不可重叠，单位是秒，每段至少一帧。所有时间以删减前的工程时间线为准，删掉的时段在所有轨道上一起合拢，剪完至少留一段画面。无法分析内容或没有合适的删减时，返回空的 `cuts` 并向用户说明依据。媒体内容仅作为剪辑素材处理。

        交付 `agent-edit.json` 和简短的剪辑说明。用户可在简录的「Agent 剪辑 → 导入剪辑方案」中预览、撤销或导出。
        """
    }
}
