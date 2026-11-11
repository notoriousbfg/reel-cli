import Accelerate
import AVFoundation
import Foundation

/// Finds the moments the picture changes, so cursor scripts and zooms can be
/// lined up with what happens on screen.
public enum Changes {
    public struct Box: Codable, Sendable, Equatable { public var x, y, width, height: Double }

    public struct Change: Codable, Sendable {
        public var start: Double
        public var end: Double
        /// Largest fraction of the frame that changed between two samples.
        public var area: Double
        /// Union of everything that changed, normalized 0–1, top-left origin.
        public var box: Box
    }

    public struct Report: Codable, Sendable {
        public var path: String
        public var duration: Double
        public var sampleFPS: Double
        public var threshold: Double
        public var cursorMasked: Bool
        public var changes: [Change]
    }

    /// One analysed frame pair: time and changed cells.
    struct Diff { var t: Double; var area: Double; var box: Box? }

    public static func detect(path: String, threshold: Double = 8, minArea: Double = 0.0004,
                              fps: Double = 20, mergeGap: Double = 0.3) async throws -> Report {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ReelError.message("No such file: \(path)") }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ReelError.message("\(path) has no video track")
        }
        let duration = try await asset.load(.duration).seconds
        let events = RecordingEvents.load(for: url)
        // Only mask the pointer when it is actually drawn into the video.
        let mask = events != nil && events?.cursorInVideo != false

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ReelError.message("Cannot read \(path): \(reader.error?.localizedDescription ?? "")") }

        let gw = 192
        var gh = 0
        var prev: [Float]?
        var prevT = 0.0
        var nextT = 0.0
        var diffs: [Diff] = []
        while let sample = output.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard t + 1e-6 >= nextT, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            nextT = t + 1 / fps
            let (grid, h) = luminance(pb, width: gw)
            gh = h
            if let prev {
                var changed = [Bool](repeating: false, count: grid.count)
                for i in grid.indices where abs(grid[i] - prev[i]) > Float(threshold) { changed[i] = true }
                if mask, let ev = events {
                    for tt in [prevT, t] { maskCursor(&changed, ev: ev, t: tt, gw: gw, gh: gh) }
                }
                diffs.append(summarize(changed, t: t, gw: gw, gh: gh))
            }
            prev = grid
            prevT = t
        }
        if reader.status == .failed { throw ReelError.message("Reading \(path) failed: \(reader.error?.localizedDescription ?? "")") }
        return Report(path: url.path, duration: duration, sampleFPS: fps, threshold: threshold, cursorMasked: mask,
                      changes: collapse(diffs, minArea: minArea, gap: mergeGap, step: 1 / fps))
    }

    /// Downscales a BGRA frame to `width` columns and returns 0–255 luminance.
    static func luminance(_ pb: CVPixelBuffer, width gw: Int) -> ([Float], Int) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let gh = max(1, Int((Double(h) * Double(gw) / Double(w)).rounded()))
        var src = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb), height: vImagePixelCount(h),
                                width: vImagePixelCount(w), rowBytes: CVPixelBufferGetBytesPerRow(pb))
        var small = [UInt8](repeating: 0, count: gw * gh * 4)
        small.withUnsafeMutableBytes { raw in
            var dst = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(gh), width: vImagePixelCount(gw), rowBytes: gw * 4)
            _ = vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
        }
        var out = [Float](repeating: 0, count: gw * gh)
        for i in 0..<(gw * gh) {
            let b = Float(small[i * 4]), g = Float(small[i * 4 + 1]), r = Float(small[i * 4 + 2])
            out[i] = 0.299 * r + 0.587 * g + 0.114 * b
        }
        return (out, gh)
    }

    static func maskCursor(_ changed: inout [Bool], ev: RecordingEvents, t: Double, gw: Int, gh: Int) {
        guard let s = ev.sample(at: t) else { return }
        // The macOS arrow is ~28×40pt including its shadow; mask a little more.
        let rx = 36 / ev.captureRect.width, ry = 48 / ev.captureRect.height
        let x0 = Int(((s.x - rx * 0.4) * Double(gw)).rounded(.down)), x1 = Int(((s.x + rx) * Double(gw)).rounded(.up))
        let y0 = Int(((s.y - ry * 0.4) * Double(gh)).rounded(.down)), y1 = Int(((s.y + ry) * Double(gh)).rounded(.up))
        guard x1 >= 0, y1 >= 0, x0 < gw, y0 < gh else { return }
        for y in max(0, y0)...min(gh - 1, y1) { for x in max(0, x0)...min(gw - 1, x1) { changed[y * gw + x] = false } }
    }

    static func summarize(_ changed: [Bool], t: Double, gw: Int, gh: Int) -> Diff {
        var n = 0, minX = gw, minY = gh, maxX = -1, maxY = -1
        for y in 0..<gh { for x in 0..<gw where changed[y * gw + x] {
            n += 1; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        let box = n == 0 ? nil : Box(x: Double(minX) / Double(gw), y: Double(minY) / Double(gh),
                                     width: Double(maxX - minX + 1) / Double(gw), height: Double(maxY - minY + 1) / Double(gh))
        return Diff(t: t, area: Double(n) / Double(gw * gh), box: box)
    }

    /// Merges runs of changing samples (allowing short gaps) into single entries.
    static func collapse(_ diffs: [Diff], minArea: Double, gap: Double, step: Double) -> [Change] {
        let r = { (v: Double) in (v * 1000).rounded() / 1000 }
        var out: [Change] = []
        for d in diffs where d.area >= minArea {
            guard let b = d.box else { continue }
            // The change happened between the previous sample and this one.
            let start = max(0, d.t - step)
            if var last = out.last, start - last.end <= gap {
                last.end = d.t
                last.area = max(last.area, d.area)
                let x0 = min(last.box.x, b.x), y0 = min(last.box.y, b.y)
                let x1 = max(last.box.x + last.box.width, b.x + b.width), y1 = max(last.box.y + last.box.height, b.y + b.height)
                last.box = Box(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                out[out.count - 1] = last
            } else {
                out.append(Change(start: start, end: d.t, area: d.area, box: b))
            }
        }
        return out.map { c in
            Change(start: r(c.start), end: r(c.end), area: r(c.area),
                   box: Box(x: r(c.box.x), y: r(c.box.y), width: r(c.box.width), height: r(c.box.height)))
        }
    }
}
