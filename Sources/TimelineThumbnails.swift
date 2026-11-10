@preconcurrency import AVFoundation
import SwiftUI

struct TimelineThumbnail: Hashable, Sendable {
    let file: String
    let tick: Int64

    var time: CMTime { CMTime(value: tick, timescale: 600) }
    var cacheKey: NSString { "\(file):\(tick)" as NSString }
}

struct TimelineFilmstrip: View {
    struct Cell {
        let thumbnail: TimelineThumbnail
        let x: Double
        let width: Double
    }

    let cells: [Cell]
    let images: [TimelineThumbnail: CGImage]

    static func cells(for clip: TimelineClip, in viewport: TimelineViewport) -> [Cell] {
        guard clip.kind.isVideo, viewport.shows(clip), clip.length * viewport.scale >= 14 else { return [] }
        // Align the grid to source time so dragging and horizontal scrolling can reuse frames.
        let interval = max(1.0 / 30, exp2(log2(72 / viewport.scale).rounded()))
        let visibleStart = max(clip.sourceStart, clip.sourceStart + viewport.start - clip.at)
        let visibleEnd = min(clip.sourceEnd, clip.sourceStart + viewport.end - clip.at)
        let gridStart = floor(visibleStart / interval) * interval
        let count = min(128, Int(ceil(viewport.width / (interval * viewport.scale))) + 2)
        return (0..<count).compactMap { index in
            let grid = gridStart + Double(index) * interval
            let left = max(clip.sourceStart, grid)
            let right = min(clip.sourceEnd, grid + interval)
            guard right > visibleStart, left < visibleEnd, right > left else { return nil }
            let time = CMTime(seconds: (left + right) / 2, preferredTimescale: 600)
            guard time.isNumeric else { return nil }
            return Cell(thumbnail: TimelineThumbnail(file: clip.file, tick: time.value),
                        x: (left - visibleStart) * viewport.scale, width: (right - left) * viewport.scale)
        }
    }

    var body: some View {
        Canvas { context, size in
            for cell in cells {
                guard let image = images[cell.thumbnail] else { continue }
                let frame = CGRect(x: cell.x, y: 0, width: max(0, cell.width - 1), height: size.height)
                let factor = max(frame.width / Double(image.width), frame.height / Double(image.height))
                let width = Double(image.width) * factor
                let height = Double(image.height) * factor
                var clipped = context
                clipped.clip(to: Path(frame))
                clipped.draw(Image(decorative: image, scale: 1),
                             in: CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2,
                                        width: width, height: height))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

actor TimelineThumbnailCache {
    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.countLimit = 250
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func images(for keys: [TimelineThumbnail], in project: TakeProject) async -> [TimelineThumbnail: CGImage] {
        var images: [TimelineThumbnail: CGImage] = [:]
        var missing: [String: [TimelineThumbnail]] = [:]
        for key in keys {
            if let image = cache.object(forKey: key.cacheKey) { images[key] = image }
            else { missing[key.file, default: []].append(key) }
        }
        for (file, frames) in missing {
            guard !Task.isCancelled else { return images }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: project.source(file)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 192, height: 128)
            // Use a wider tolerance for sparse or variable-frame-rate imports.
            for tolerance in [CMTime(value: 1, timescale: 5), .positiveInfinity] {
                let pending = frames.filter { images[$0] == nil }
                if pending.isEmpty { break }
                generator.requestedTimeToleranceBefore = tolerance
                generator.requestedTimeToleranceAfter = tolerance
                for await result in generator.images(for: pending.map(\.time)) {
                    if Task.isCancelled {
                        generator.cancelAllCGImageGeneration()
                        return images
                    }
                    if case .success(let requested, let image, _) = result {
                        let tick = CMTimeConvertScale(requested, timescale: 600, method: .default).value
                        let key = TimelineThumbnail(file: file, tick: tick)
                        cache.setObject(image, forKey: key.cacheKey, cost: image.bytesPerRow * image.height)
                        images[key] = image
                    }
                }
            }
        }
        return images
    }
}
