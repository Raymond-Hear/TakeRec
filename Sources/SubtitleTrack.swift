import Foundation
import CoreFoundation
import CoreImage
import CoreText

struct SubtitleCue: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String

    static let minimumDuration = 1.0 / 30

    func placed(start: Double, end: Double, duration: Double) -> Self {
        let lower = clamp(start, 0, max(0, duration - Self.minimumDuration))
        var value = self
        value.start = lower
        value.end = min(duration, max(lower + Self.minimumDuration, end))
        return value
    }

    func removingTime(from lower: Double, to upper: Double) -> Self? {
        var value = self
        value.start -= clamp(start - lower, 0, upper - lower)
        value.end -= clamp(end - lower, 0, upper - lower)
        return value.end > value.start ? value : nil
    }
}

struct SubtitleStyle: Codable, Equatable, Sendable {
    var enabled = true
    var fontFamily = ""
    var size = 46.0
    var bold = true
    var backdrop = 0.66
}

enum SubtitleImport {
    static func read(_ url: URL, duration: Double) throws -> (cues: [SubtitleCue], needsTiming: Bool) {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 10 * 1024 * 1024 else { throw RecorderError.message("字幕文件请控制在 10 MB 以内。") }
        let bytes = try Data(contentsOf: url)
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let hasUTF16BOM = bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff])
        guard let decoded = (hasUTF16BOM ? String(data: bytes, encoding: .utf16) : nil)
            ?? String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: gb18030) else {
            throw RecorderError.message("无法读取字幕文字。请保存为 UTF-8、UTF-16 或 GB18030。")
        }
        return try parse(decoded, isSRT: url.pathExtension.lowercased() == "srt", duration: duration)
    }

    static func parse(_ text: String, isSRT: Bool, duration: Double) throws -> (cues: [SubtitleCue], needsTiming: Bool) {
        let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
        let lines = cleaned.components(separatedBy: "\n")
        let timed = timedCues(lines)
        if isSRT || !timed.isEmpty {
            let clipped = timed.filter { $0.start < duration }.map {
                SubtitleCue(start: $0.start, end: min(duration, $0.end), text: $0.text)
            }
            guard !clipped.isEmpty else { throw RecorderError.message("没有读到与当前视频时长重叠的 SRT 时间码。") }
            return (clipped.sorted { $0.start < $1.start }, false)
        }
        let parts = lines.flatMap { line -> [String] in
            var rest = line.trimmingCharacters(in: .whitespacesAndNewlines)[...]
            var pieces: [String] = []
            while !rest.isEmpty {
                let slice = rest.prefix(42)
                pieces.append(String(slice).trimmingCharacters(in: .whitespaces))
                rest = rest.dropFirst(slice.count)
            }
            return pieces.filter { !$0.isEmpty }
        }
        guard !parts.isEmpty, duration > 0 else { throw RecorderError.message("字幕文件中没有可导入的文字。") }
        let weights = parts.map { Double(max(5, $0.count)) }
        let total = weights.reduce(0, +)
        var offset = 0.0
        let cues = zip(parts, weights).map { text, weight in
            let start = duration * offset / total
            offset += weight
            return SubtitleCue(start: start, end: min(duration, duration * offset / total), text: text)
        }
        return (cues, true)
    }

    private static func timedCues(_ lines: [String]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var pending: (start: Double, end: Double)?
        var body: [String] = []
        func flush() {
            if let pending, !body.isEmpty {
                cues.append(SubtitleCue(start: pending.start, end: pending.end, text: body.joined(separator: "\n")))
            }
            pending = nil
            body.removeAll()
        }
        for line in lines {
            let line = line.trimmingCharacters(in: .whitespaces)
            let arrow = line.components(separatedBy: "-->")
            if arrow.count == 2, let start = seconds(arrow[0]), let end = seconds(arrow[1]), end > start {
                flush()
                pending = (start, end)
            } else if line.isEmpty {
                flush()
            } else if pending != nil {
                body.append(line)
            }
        }
        flush()
        return cues
    }

    private static func seconds(_ raw: String) -> Double? {
        guard let token = raw.split(whereSeparator: \.isWhitespace).first else { return nil }
        let pieces = token.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard pieces.count == 3, let h = Int(pieces[0]), let m = Int(pieces[1]), let s = Double(pieces[2]),
              h >= 0, (0..<60).contains(m), s >= 0, s < 60 else { return nil }
        return Double(h) * 3600 + Double(m) * 60 + s
    }
}

final class SubtitleArtwork: @unchecked Sendable {
    private let cues: [SubtitleCue]
    private let maximumEnds: [Double]
    private let style: SubtitleStyle
    private let cache = NSCache<NSString, CIImage>()

    init(cues: [SubtitleCue], style: SubtitleStyle) {
        self.cues = cues.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var maxEnd = 0.0
        maximumEnds = self.cues.map {
            maxEnd = max(maxEnd, $0.end)
            return maxEnd
        }
        self.style = style
        cache.countLimit = 36
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func overlay(at time: Double, in canvas: CGRect, portrait: Bool) -> CIImage? {
        guard style.enabled, let cue = activeCue(at: time) else { return nil }
        let key = "\(cue.id)/\(Int(canvas.width))x\(Int(canvas.height))/\(portrait)" as NSString
        let image: CIImage
        if let cached = cache.object(forKey: key) {
            image = cached
        } else {
            guard let drawn = draw(cue.text, canvas: canvas, portrait: portrait) else { return nil }
            cache.setObject(drawn, forKey: key, cost: Int(drawn.extent.width * drawn.extent.height * 4))
            image = drawn
        }
        let bottom = portrait ? canvas.height * 0.417 - image.extent.height : canvas.height * 0.07
        return image.transformed(by: CGAffineTransform(translationX: (canvas.width - image.extent.width) / 2, y: bottom))
    }

    private func activeCue(at time: Double) -> SubtitleCue? {
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= time { low = middle + 1 }
            else { high = middle }
        }
        while low > 0, maximumEnds[low - 1] > time {
            low -= 1
            if cues[low].end > time { return cues[low] }
        }
        return nil
    }

    private func draw(_ text: String, canvas: CGRect, portrait: Bool) -> CIImage? {
        let scale = min(canvas.width, canvas.height) / 1080
        let inset = max(3, round(12 * scale))
        let maxWidth = floor(canvas.width * 0.90) - 2 * inset
        let maxHeight = floor(canvas.height * (portrait ? 0.14 : 0.30)) - 2 * inset
        guard maxWidth > 0, maxHeight > 0 else { return nil }
        var size = max(7, clamp(style.size, 20, 104) * scale)
        var measured = CGSize.zero
        var framesetter = makeFramesetter(text, size: size)
        // Keep imported multiline cues inside the caption area at each export size.
        for attempt in 0...5 {
            measured = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
                                                                  CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
            if measured.height + 2 <= maxHeight || size <= 7 || attempt == 5 { break }
            size = max(7, size * 0.80)
            framesetter = makeFramesetter(text, size: size)
        }
        let width = Int(ceil(min(maxWidth, measured.width + 2) + 2 * inset))
        let height = Int(ceil(min(maxHeight, measured.height + 3) + 2 * inset))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let plate = CGRect(x: 0, y: 0, width: width, height: height)
        if style.backdrop > 0 {
            context.setFillColor(gray: 0.04, alpha: clamp(style.backdrop, 0, 1))
            context.addPath(CGPath(roundedRect: plate, cornerWidth: inset, cornerHeight: inset, transform: nil))
            context.fillPath()
        } else {
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: max(1, inset / 3), color: CGColor(gray: 0, alpha: 0.85))
        }
        let path = CGPath(rect: plate.insetBy(dx: inset, dy: inset), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        return context.makeImage().map { CIImage(cgImage: $0) }
    }

    private func makeFramesetter(_ text: String, size: CGFloat) -> CTFramesetter {
        let base: CTFont
        if style.fontFamily.isEmpty {
            base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        } else {
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute as String: style.fontFamily] as CFDictionary)
            base = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
        let font = style.bold ? CTFontCreateCopyWithSymbolicTraits(base, 0, nil, .traitBold, .traitBold) ?? base : base
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { value in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: value)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ])
        return CTFramesetterCreateWithAttributedString(attributed)
    }
}
