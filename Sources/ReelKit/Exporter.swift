import AppKit
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct EditOptions: Sendable {
    public var inputs: [String] = []
    public var crops: [String] = []         // "x,y,w,h" or "N=x,y,w,h"
    public var zooms: [String] = []
    public var autoZoom: Double?            // scale, if enabled
    public var zoomEase = 0.6
    public var transitions: [String] = []   // "kind[:dur]" or "N=kind[:dur]"
    public var speeds: [String] = []        // "1.5" or "N=1.5"
    public var size: String?
    public var padding = 0.0
    public var background: String = "#000000"
    public var cornerRadius = 0.0
    public var shadow = false
    public var fadeIn = 0.0
    public var fadeOut = 0.0
    public var fps = 60
    public var mute = false
    public var cursor: Double?              // draw a cursor at this scale
    public var clickEffect = true
    public var events: [String] = []        // "file.json" or "N=file.json"
    public var cursorScripts: [String] = [] // "moves.json" or "N=moves.json"
    public init() {}
}

public enum Planner {
    /// Loads input media and resolves CLI-style options into an `EditPlan`.
    public static func plan(_ o: EditOptions) async throws -> EditPlan {
        guard !o.inputs.isEmpty else { throw ReelError.message("No input clips") }
        // NSCursor images (for --cursor) only render once AppKit has a window-server session.
        if o.cursor != nil { await AppKitSession.ensure() }
        var clips: [EditPlan.Clip] = []
        for (n, spec) in o.inputs.enumerated() {
            let (path, start, end) = Parse.clipSpec(spec)
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ReelError.message("No such file: \(path)") }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ReelError.message("\(path) has no video track")
            }
            let size = try await track.load(.naturalSize)
            let dur = try await asset.load(.duration).seconds
            let a = max(0, start ?? 0), b = min(dur, end ?? dur)
            guard b - a > 0.05 else { throw ReelError.message("Trim \(spec) leaves nothing (clip is \(String(format: "%.2f", dur))s)") }

            var crop = EditPlan.PixelRect(x: 0, y: 0, width: size.width, height: size.height)
            for c in o.crops {
                let (idx, v) = Parse.indexed(c)
                if idx == nil || idx == n + 1 { crop = try Parse.crop(v, sourceWidth: size.width, sourceHeight: size.height) }
            }
            var speed = 1.0
            for s in o.speeds {
                let (idx, v) = Parse.indexed(s)
                guard let x = Double(v), x > 0 else { throw ReelError.message("Bad --speed \(s)") }
                if idx == nil || idx == n + 1 { speed = x }
            }
            var clip = EditPlan.Clip(path: url.path, trimStart: a, trimEnd: b, crop: crop,
                                     sourceWidth: size.width, sourceHeight: size.height, speed: speed,
                                     hasEvents: false, sourceDuration: dur)
            for e in o.events {
                let (idx, v) = Parse.indexed(e)
                if idx == nil || idx == n + 1 { clip.eventsPath = v }
            }
            for c in o.cursorScripts {
                let (idx, v) = Parse.indexed(c)
                if idx == nil || idx == n + 1 { clip.cursorScript = v }
            }
            let scriptName = clip.cursorScript.map { ($0 as NSString).lastPathComponent } ?? ""
            clip.hasEvents = try clip.loadEvents(warn: {
                FileHandle.standardError.write(Data("warning: \(scriptName): \($0)\n".utf8))
            }) != nil
            clips.append(clip)
        }

        var transitions = Array(repeating: EditPlan.Transition(kind: .cut, duration: 0), count: max(0, clips.count - 1))
        for t in o.transitions {
            let (idx, v) = Parse.indexed(t)
            let tr = try Parse.transition(v)
            for i in transitions.indices where idx == nil || idx == i + 1 { transitions[i] = tr }
        }
        for i in transitions.indices {
            let limit = min(clips[i].duration, clips[i + 1].duration) / 2
            transitions[i].duration = min(transitions[i].duration, limit)
        }

        let pad = max(0, o.padding)
        var w: Int, h: Int
        if let s = o.size { (w, h) = try Parse.size(s) }
        else {
            w = Int(clips[0].crop.width + pad * 2) & ~1
            h = Int(clips[0].crop.height + pad * 2) & ~1
        }
        let bg = o.background.split(separator: ",").map { String($0) }
        for c in bg { _ = try Parse.color(c) }

        let zoomSpecs = try o.zooms.map(Parse.zoomSpec)
        var plan = EditPlan(clips: clips, transitions: transitions, zooms: [],
                            zoomEase: o.zoomEase,
                            canvas: .init(width: w, height: h, padding: pad, background: bg,
                                          cornerRadius: o.cornerRadius, shadow: o.shadow),
                            fadeIn: o.fadeIn, fadeOut: o.fadeOut, fps: o.fps, mute: o.mute)
        if let s = o.cursor {
            guard s > 0 else { throw ReelError.message("--cursor expects a positive scale, e.g. 1.6") }
            guard clips.contains(where: \.hasEvents) else {
                throw ReelError.message("--cursor needs the .events.json sidecar that `reel record` writes next to the video")
            }
            plan.cursor = .init(scale: s, clickEffect: o.clickEffect)
        }

        if !zoomSpecs.isEmpty {
            let composer = try Composer(plan: plan)
            plan.zooms = try zoomSpecs.map { try resolve($0, plan: plan, composer: composer) }
        }
        if plan.zooms.contains(where: { $0.target == .cursor }) && !clips.contains(where: \.hasEvents) {
            throw ReelError.message("@cursor zoom needs an .events.json sidecar (recorded by `reel record`)")
        }
        if let scale = o.autoZoom {
            let composer = try Composer(plan: plan)
            let clicks = composer.outputClicks()
            if clicks.isEmpty { FileHandle.standardError.write(Data("warning: --auto-zoom found no recorded clicks\n".utf8)) }
            plan.zooms += EditPlan.autoZooms(clicks: clicks, scale: scale)
        }
        return plan
    }

    public static let maxFitScale = 3.0

    /// Places a zoom on the output timeline/frame.
    static func resolve(_ z: Parse.ZoomSpec, plan: EditPlan, composer: Composer) throws -> EditPlan.Zoom {
        let raw = "\(z.start)…\(z.end)"
        var a: Double, b: Double
        var clip = (z.clip ?? 1) - 1
        guard plan.clips.indices.contains(clip) else { throw ReelError.message("--zoom \(raw): there is no clip \(clip + 1)") }
        if z.source {
            // Marker names: use the given clip, else the first clip that has them.
            func times(_ i: Int) throws -> (Double, Double) {
                let ev = try plan.clips[i].loadEvents()
                let m = ev?.markers ?? []
                return (try TimeRef.resolve(z.start, markers: m), try TimeRef.resolve(z.end, markers: m))
            }
            var resolved: (Double, Double)?
            var lastError: Error?
            for i in (z.clip != nil ? [clip] : Array(plan.clips.indices)) {
                do { resolved = try times(i); clip = i; break } catch { lastError = error }
            }
            guard let (sa, sb) = resolved else { throw lastError ?? ReelError.message("--zoom \(raw): cannot resolve times") }
            guard sb > sa else { throw ReelError.message("--zoom \(raw): end must be after start") }
            let c = plan.clips[clip], start = plan.clipStarts[clip]
            a = start + (sa - c.trimStart) / c.speed
            b = start + (sb - c.trimStart) / c.speed
            let lo = start, hi = start + c.duration
            if b <= lo || a >= hi {
                throw ReelError.message(String(format: "--zoom %@ falls outside clip %d's trim (source %.2f–%.2f)", raw, clip + 1, c.trimStart, c.trimEnd))
            }
            a = max(lo, a); b = min(hi, b)
        } else {
            guard let x = Double(z.start), let y = Double(z.end) else { throw ReelError.message("--zoom \(raw): bad times") }
            a = x; b = y
        }

        func out(_ x: Double, _ y: Double) -> (Double, Double) {
            guard z.source else { return (x, y) }
            let p = composer.outputPoint(clip: clip, sourceX: x, sourceY: y)
            return (p.x, p.y)
        }
        switch z.target {
        case .cursor:
            return .init(start: a, end: b, scale: z.scale ?? 2, target: .cursor)
        case .point(let x, let y):
            let p = out(x, y)
            return .init(start: a, end: b, scale: z.scale ?? 2, target: .point(x: p.0, y: p.1))
        case .rect(let x, let y, let w, let h):
            let p0 = out(x, y), p1 = out(x + w, y + h)
            let ow = abs(p1.0 - p0.0), oh = abs(p1.1 - p0.1)
            // Fit the region with a little breathing room, capped so tiny regions
            // don't blow the frame (and the cursor) up absurdly.
            let fit = min(1 / ow, 1 / oh) * 0.92
            let scale = max(1, min(Self.maxFitScale, fit))
            return .init(start: a, end: b, scale: (scale * 100).rounded() / 100,
                         target: .point(x: (p0.0 + p1.0) / 2, y: (p0.1 + p1.1) / 2))
        }
    }
}

/// NSCursor images and window-server calls need NSApplication to exist.
public enum AppKitSession {
    public static func ensure() async {
        await MainActor.run { _ = NSApplication.shared }
    }
}

// MARK: - Export

public enum Exporter {
    public static func export(_ plan: EditPlan, to output: URL, hevc: Bool,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let composer = try Composer(plan: plan)
        let comp = AVMutableComposition()
        let videoTracks = (0..<min(2, plan.clips.count)).map { _ in
            comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        }
        var audioTracks: [AVMutableCompositionTrack] = []
        let starts = plan.clipStarts
        let ts: CMTimeScale = 6000
        func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: ts) }

        for (i, clip) in plan.clips.enumerated() {
            let asset = AVURLAsset(url: URL(fileURLWithPath: clip.path))
            let src = CMTimeRange(start: cm(clip.trimStart), end: cm(clip.trimEnd))
            let at = cm(starts[i])
            let outDur = cm(clip.duration)

            let vt = videoTracks[i % 2]
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                try insert(v, src, into: vt, at: at, scaledTo: outDur)
            }
            if !plan.mute, let a = try await asset.loadTracks(withMediaType: .audio).first {
                while audioTracks.count <= i % 2 {
                    audioTracks.append(comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!)
                }
                try insert(a, src, into: audioTracks[i % 2], at: at, scaledTo: outDur)
            }
        }

        // One instruction per span with a constant set of visible clips.
        var cuts = Set<Double>([0, plan.totalDuration])
        for (i, c) in plan.clips.enumerated() { cuts.insert(starts[i]); cuts.insert(starts[i] + c.duration) }
        let times = cuts.sorted()
        var instructions: [ReelInstruction] = []
        for (a, b) in zip(times, times.dropFirst()) where b - a > 1e-4 {
            let mid = (a + b) / 2
            let layers = plan.activeClips(at: mid).map { (trackID: videoTracks[$0 % 2].trackID, clip: $0) }
            instructions.append(ReelInstruction(range: CMTimeRange(start: cm(a), end: cm(b)), layers: layers, composer: composer))
        }

        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = ReelCompositor.self
        vc.renderSize = CGSize(width: plan.canvas.width, height: plan.canvas.height)
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(plan.fps))
        vc.instructions = instructions

        let preset = hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: comp, presetName: preset) else {
            throw ReelError.message("Could not create export session")
        }
        session.videoComposition = vc
        try? FileManager.default.removeItem(at: output)
        let type: AVFileType = output.pathExtension.lowercased() == "mov" ? .mov : .mp4

        let monitor = Task {
            guard let progress else { return }
            for await state in session.states(updateInterval: 0.5) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: output, as: type)
    }

    private static func insert(_ track: AVAssetTrack, _ range: CMTimeRange, into dest: AVMutableCompositionTrack,
                               at: CMTime, scaledTo duration: CMTime) throws {
        let end = dest.timeRange.end
        if end.isValid, at > end {
            dest.insertEmptyTimeRange(CMTimeRange(start: end, end: at))
        }
        try dest.insertTimeRange(range, of: track, at: at)
        if abs(range.duration.seconds - duration.seconds) > 1e-3 {
            dest.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: duration)
        }
    }
}

final class ReelInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let layers: [(trackID: CMPersistentTrackID, clip: Int)]
    let composer: Composer

    init(range: CMTimeRange, layers: [(trackID: CMPersistentTrackID, clip: Int)], composer: Composer) {
        timeRange = range
        self.layers = layers
        self.composer = composer
        requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
    }
}

final class ReelCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let attrs: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
    ]
    let sourcePixelBufferAttributes: [String: any Sendable]? = ReelCompositor.attrs
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = ReelCompositor.attrs
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instr = request.videoCompositionInstruction as? ReelInstruction,
              let out = request.renderContext.newPixelBuffer() else {
            request.finish(with: ReelError.message("compositor setup failed"))
            return
        }
        var sources: [Int: CIImage] = [:]
        for l in instr.layers {
            if let pb = request.sourceFrame(byTrackID: l.trackID) { sources[l.clip] = CIImage(cvPixelBuffer: pb) }
        }
        let img = instr.composer.image(at: request.compositionTime.seconds, sources: sources)
        let size = request.renderContext.size
        context.render(img, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: out)
    }
}

// MARK: - Stills (previews, frames, contact sheets)

public enum Stills {
    static let context = CIContext()

    public static func sourceFrame(path: String, at t: Double) async throws -> CIImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        gen.appliesPreferredTrackTransform = true
        let (cg, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 6000))
        return CIImage(cgImage: cg)
    }

    /// Renders the edited output at time `t` without exporting video.
    public static func preview(_ plan: EditPlan, at t: Double) async throws -> CGImage {
        let composer = try Composer(plan: plan)
        let tt = min(max(0, t), max(0, plan.totalDuration - 1e-3))
        var sources: [Int: CIImage] = [:]
        for i in plan.activeClips(at: tt) {
            sources[i] = try await sourceFrame(path: plan.clips[i].path, at: plan.sourceTime(clip: i, at: tt))
        }
        let img = composer.image(at: tt, sources: sources)
        return context.createCGImage(img, from: CGRect(x: 0, y: 0, width: plan.canvas.width, height: plan.canvas.height))!
    }

    public static func frame(path: String, at t: Double) async throws -> CGImage {
        let img = try await sourceFrame(path: path, at: t)
        return context.createCGImage(img, from: img.extent)!
    }

    public static func writePNG(_ image: CGImage, to url: URL, maxWidth: Int? = nil) throws {
        try writeImage(image, to: url, maxWidth: maxWidth)
    }

    /// PNG, or JPEG for .jpg/.jpeg (at `quality`, 0–1).
    public static func writeImage(_ image: CGImage, to url: URL, maxWidth: Int? = nil, quality: Double = 0.9) throws {
        var img = image
        if let maxWidth, image.width > maxWidth {
            let h = Int(Double(image.height) * Double(maxWidth) / Double(image.width))
            let ctx = CGContext(data: nil, width: maxWidth, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: h))
            img = ctx.makeImage()!
        }
        let jpeg = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else {
            throw ReelError.message("Cannot write \(url.path)")
        }
        let props = jpeg ? [kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality))] as CFDictionary : nil
        CGImageDestinationAddImage(dest, img, props)
        guard CGImageDestinationFinalize(dest) else { throw ReelError.message("Cannot write \(url.path)") }
    }
}

extension Stills {
    /// Crops a frame by a `--crop`-style spec (source pixels or %).
    public static func crop(_ image: CGImage, _ spec: String) throws -> CGImage {
        let r = try Parse.crop(spec, sourceWidth: Double(image.width), sourceHeight: Double(image.height))
        guard let c = image.cropping(to: CGRect(x: r.x, y: r.y, width: r.width, height: r.height)) else {
            throw ReelError.message("--crop \(spec) is outside the frame")
        }
        return c
    }
}

/// Splits a launch-arguments string like a shell would (quotes and backslashes).
public enum ShellWords {
    public static func split(_ s: String) throws -> [String] {
        var out: [String] = [], cur = "", quote: Character? = nil, escaping = false, has = false
        for ch in s {
            if escaping { cur.append(ch); escaping = false; continue }
            if ch == "\\" && quote != "'" { escaping = true; has = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; has = true; continue }
            if ch.isWhitespace { if has { out.append(cur); cur = ""; has = false }; continue }
            cur.append(ch); has = true
        }
        if quote != nil { throw ReelError.message("Unbalanced quote in --args") }
        if has { out.append(cur) }
        return out
    }
}
