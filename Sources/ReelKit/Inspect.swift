import AVFoundation
import CoreText
import Foundation

public struct MediaInfo: Codable, Sendable {
    public var path: String
    public var duration: Double
    public var width: Int
    public var height: Int
    public var fps: Double
    public var hasAudio: Bool
    public var events: EventsSummary?

    public struct EventsSummary: Codable, Sendable {
        public var sidecar: String
        public var samples: Int
        /// Clicks in source time; x/y normalized to the video frame (top-left origin).
        public var clicks: [RecordingEvents.Click]
        public var markers: [RecordingEvents.Marker]?
        public var shapes: [RecordingEvents.ShapeChange]?
        public var synthetic: Bool?
        public var cursorInVideo: Bool?
    }
}

public enum Inspect {
    public static func info(path: String) async throws -> MediaInfo {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ReelError.message("No such file: \(path)") }
        let asset = AVURLAsset(url: url)
        guard let v = try await asset.loadTracks(withMediaType: .video).first else {
            throw ReelError.message("\(path) has no video track")
        }
        let size = try await v.load(.naturalSize)
        let fps = try await v.load(.nominalFrameRate)
        let dur = try await asset.load(.duration).seconds
        let audio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        var summary: MediaInfo.EventsSummary?
        if let ev = RecordingEvents.load(for: url) {
            summary = .init(sidecar: RecordingEvents.sidecarURL(for: url).path, samples: ev.samples.count, clicks: ev.clicks,
                            markers: ev.markers, shapes: ev.shapes, synthetic: ev.synthetic, cursorInVideo: ev.cursorInVideo)
        }
        return MediaInfo(path: url.path, duration: dur, width: Int(size.width), height: Int(size.height),
                         fps: Double(fps), hasAudio: audio, events: summary)
    }

    /// A grid of timestamped thumbnails, so an agent can "watch" a recording
    /// in one image. Recorded clicks are marked with a red ring.
    /// A 10% grid can be overlaid to help read off zoom/crop coordinates.
    public static func contactSheet(times: [Double], frame: (Double) async throws -> CGImage,
                                    clicks: [(t: Double, x: Double, y: Double)] = [],
                                    columns: Int, width: Int, grid: Bool, to url: URL) async throws {
        guard !times.isEmpty else { throw ReelError.message("No frames to render") }
        let first = try await frame(times[0])
        let gap = 8, label = 26
        let cols = max(1, min(columns, times.count))
        let rows = (times.count + cols - 1) / cols
        let cellW = (width - gap * (cols + 1)) / cols
        let cellH = Int(Double(cellW) * Double(first.height) / Double(first.width))
        let H = rows * (cellH + label) + gap * (rows + 1)
        let ctx = CGContext(data: nil, width: width, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: H))
        ctx.interpolationQuality = .high
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 15, nil)

        for (n, t) in times.enumerated() {
            let img = n == 0 ? first : try await frame(t)
            let col = n % cols, row = n / cols
            let x = gap + col * (cellW + gap)
            let yTop = gap + row * (cellH + label + gap)
            let rect = CGRect(x: x, y: H - yTop - label - cellH, width: cellW, height: cellH)
            ctx.draw(img, in: rect)

            if grid {
                ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 0, alpha: 0.35))
                ctx.setLineWidth(1)
                for k in 1..<10 {
                    let fx = rect.minX + rect.width * Double(k) / 10, fy = rect.minY + rect.height * Double(k) / 10
                    ctx.strokeLineSegments(between: [CGPoint(x: fx, y: rect.minY), CGPoint(x: fx, y: rect.maxY),
                                                     CGPoint(x: rect.minX, y: fy), CGPoint(x: rect.maxX, y: fy)])
                }
            }
            let window = n + 1 < times.count ? times[n + 1] - t : 1
            for c in clicks where c.t >= t - 0.05 && c.t < t + window - 0.05 {
                let p = CGPoint(x: rect.minX + c.x * rect.width, y: rect.maxY - c.y * rect.height)
                ctx.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.95))
                ctx.setLineWidth(3)
                ctx.strokeEllipse(in: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20))
            }

            let text = String(format: "#%d  t=%.2fs", n + 1, t)
            let attr = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.95, alpha: 1),
            ])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: Double(x) + 2, y: Double(H - yTop - label) + 7)
            CTLineDraw(line, ctx)
        }
        try Stills.writePNG(ctx.makeImage()!, to: url)
    }

    public static func sampleTimes(duration: Double, every: Double?, count: Int?) -> [Double] {
        let end = max(0, duration - 0.05)
        if let every, every > 0 { return stride(from: 0, through: end, by: every).map { $0 } }
        let n = max(1, count ?? 12)
        if n == 1 { return [0] }
        return (0..<n).map { end * Double($0) / Double(n - 1) }
    }
}
