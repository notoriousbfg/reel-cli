import CoreGraphics
import Foundation

/// A fully-resolved description of an edit. Built from CLI flags by
/// `EditPlan.parse…` helpers, then rendered by `Exporter` or `Preview`.
public struct EditPlan: Codable, Sendable {
    public var clips: [Clip]
    /// transitions[i] sits between clips[i] and clips[i+1].
    public var transitions: [Transition]
    public var zooms: [Zoom]
    public var zoomEase: Double
    public var canvas: Canvas
    public var fadeIn: Double
    public var fadeOut: Double
    public var fps: Int
    public var mute: Bool
    /// Cursor drawn from recorded events (nil = none).
    public var cursor: CursorStyle? = nil
    /// Keystroke captions on the output timeline.
    public var captions: [Caption] = []

    public struct Caption: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var text: String
    }

    public struct CursorStyle: Codable, Sendable, Equatable {
        /// Size relative to the real macOS cursor.
        public var scale: Double
        /// Show a halo where the user clicks.
        public var clickEffect: Bool
        public init(scale: Double, clickEffect: Bool) { self.scale = scale; self.clickEffect = clickEffect }
    }

    public struct Clip: Codable, Sendable {
        public var path: String
        public var trimStart: Double
        public var trimEnd: Double
        /// Crop in source pixels, top-left origin.
        public var crop: PixelRect
        public var sourceWidth: Double
        public var sourceHeight: Double
        public var speed: Double
        public var hasEvents: Bool
        /// Events file to use instead of the `<clip>.events.json` sidecar.
        public var eventsPath: String? = nil
        /// Cursor script that replaces the recorded cursor track.
        public var cursorScript: String? = nil
        /// Full length of the source media.
        public var sourceDuration: Double? = nil
        /// Which input clip this is (0-based). Cuts and speed ranges split one input
        /// into several consecutive clips of the same file.
        public var input: Int = 0
        /// Images drawn over the source before crop and zoom (absolute image paths).
        public var patches: [RecordingEvents.Patch] = []
        /// Duration on the output timeline.
        public var duration: Double { (trimEnd - trimStart) / speed }

        /// The cursor/click/marker track for this clip: a cursor script if given
        /// (built on the recorded track's geometry and markers), else `eventsPath`,
        /// else the sidecar next to the video.
        public func loadEvents(warn: ((String) -> Void)? = nil) throws -> RecordingEvents? {
            let base = try eventsPath.map { try RecordingEvents.read(URL(fileURLWithPath: $0)) }
                ?? RecordingEvents.load(for: URL(fileURLWithPath: path))
            guard let cursorScript else { return base }
            let script = try CursorScript.load(URL(fileURLWithPath: cursorScript))
            let scale = base?.pointPixelScale ?? 2
            return try script.events(base: base, pointsSize: (sourceWidth / scale, sourceHeight / scale),
                                     pointPixelScale: scale, duration: sourceDuration ?? trimEnd, warn: warn)
        }
    }

    public struct PixelRect: Codable, Sendable, Equatable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    public enum TransitionKind: String, Codable, Sendable, CaseIterable {
        case cut, crossfade, fade
        case slideLeft = "slide-left", slideRight = "slide-right", slideUp = "slide-up", slideDown = "slide-down"
        case wipe
        case zoom
    }

    public struct Transition: Codable, Sendable, Equatable {
        public var kind: TransitionKind
        public var duration: Double
    }

    public enum ZoomTarget: Codable, Sendable, Equatable {
        case point(x: Double, y: Double)  // normalized output-frame coords, top-left origin
        case cursor
    }

    public struct Zoom: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var scale: Double
        public var target: ZoomTarget
    }

    public struct Canvas: Codable, Sendable {
        public var width: Int
        public var height: Int
        public var padding: Double
        public var background: [String]  // 1 hex = solid, 2 = vertical gradient
        public var cornerRadius: Double
        public var shadow: Bool
    }

    // MARK: - Timeline

    /// Start time of each clip on the output timeline.
    public var clipStarts: [Double] {
        var starts: [Double] = []
        var t = 0.0
        for (i, c) in clips.enumerated() {
            starts.append(t)
            t += c.duration - (i < transitions.count ? transitions[i].duration : 0)
        }
        return starts
    }

    public var totalDuration: Double {
        guard let last = clips.indices.last else { return 0 }
        return clipStarts[last] + clips[last].duration
    }

    /// Clips visible at output time `t` (at most two, during a transition).
    public func activeClips(at t: Double) -> [Int] {
        let starts = clipStarts
        return clips.indices.filter { t >= starts[$0] - 1e-6 && t < starts[$0] + clips[$0].duration }
    }

    /// Output time of source time `s` in input clip `g` (0-based). Times inside a
    /// cut map to the start of what follows it; times outside the trim clamp.
    public func outputTime(input g: Int, source s: Double) -> Double {
        let idx = clips.indices.filter { clips[$0].input == g }
        guard let last = idx.last else { return 0 }
        let starts = clipStarts
        for i in idx {
            let c = clips[i]
            if s < c.trimStart { return starts[i] }
            if s <= c.trimEnd { return starts[i] + (s - c.trimStart) / c.speed }
        }
        return starts[last] + clips[last].duration
    }

    /// First plan clip of input clip `g`.
    public func firstClip(ofInput g: Int) -> Int? { clips.firstIndex { $0.input == g } }
    public var inputCount: Int { (clips.map(\.input).max() ?? -1) + 1 }

    /// Source-media time for clip `i` at output time `t`.
    public func sourceTime(clip i: Int, at t: Double) -> Double {
        clips[i].trimStart + max(0, t - clipStarts[i]) * clips[i].speed
    }
}

// MARK: - Parsing helpers (shared by the CLI and tests)

public enum Parse {
    /// `file.mov`, `file.mov:2.5-8`, `file.mov:3-`, `file.mov:-10`
    public static func clipSpec(_ s: String) -> (path: String, start: Double?, end: Double?) {
        let pattern = #"^(.*):(\d*\.?\d*)-(\d*\.?\d*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let p = Range(m.range(at: 1), in: s), let a = Range(m.range(at: 2), in: s), let b = Range(m.range(at: 3), in: s),
              !(s[a].isEmpty && s[b].isEmpty)
        else { return (s, nil, nil) }
        return (String(s[p]), Double(s[a]), Double(s[b]))
    }

    /// `A..B` source range (seconds or marker references) for --cut and --speed.
    public static func sourceRange(_ s: String, markers: [RecordingEvents.Marker]) throws -> (Double, Double) {
        guard let r = s.range(of: "..") else { throw ReelError.message("Expected START..END, got \(s)") }
        let a = try TimeRef.resolve(String(s[..<r.lowerBound]), markers: markers)
        let b = try TimeRef.resolve(String(s[r.upperBound...]), markers: markers)
        guard b > a else { throw ReelError.message(String(format: "%@: end (%.2fs) must be after start (%.2fs)", s, b, a)) }
        return (a, b)
    }

    /// `image.png@x,y[,w,h][:START-END]` (source pixels, source seconds).
    public static func patch(_ s: String) throws -> RecordingEvents.Patch {
        guard let at = s.lastIndex(of: "@") else { throw ReelError.message("--patch expects IMAGE@x,y[,w,h][:START-END], got \(s)") }
        let path = String(s[..<at])
        var rest = String(s[s.index(after: at)...])
        var start: Double?, end: Double?
        if let colon = rest.firstIndex(of: ":") {
            let times = rest[rest.index(after: colon)...]
            rest = String(rest[..<colon])
            let parts = times.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].isEmpty || Double(parts[0]) != nil, parts[1].isEmpty || Double(parts[1]) != nil
            else { throw ReelError.message("--patch \(s): times are START-END in source seconds") }
            start = Double(parts[0]); end = Double(parts[1])
        }
        let n = rest.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 2 || n.count == 4, n.allSatisfy({ $0 != nil }) else {
            throw ReelError.message("--patch \(s): position is x,y or x,y,w,h in source pixels")
        }
        return .init(image: path, x: n[0]!, y: n[1]!, width: n.count == 4 ? n[2]! : -1, height: n.count == 4 ? n[3]! : -1,
                     start: start, end: end)
    }

    /// `TEXT@START` or `TEXT@START..END` (source seconds or marker references).
    public static func caption(_ s: String) throws -> (text: String, start: String, end: String?) {
        guard let at = s.lastIndex(of: "@"), at != s.startIndex else {
            throw ReelError.message("--caption expects TEXT@START or TEXT@START..END, e.g. '⌃⌥Space@1.0' (got \(s))")
        }
        let text = String(s[..<at]), time = String(s[s.index(after: at)...]).trimmingCharacters(in: .whitespaces)
        guard !time.isEmpty else { throw ReelError.message("--caption \(s): missing time after @") }
        if let r = time.range(of: "..") { return (text, String(time[..<r.lowerBound]), String(time[r.upperBound...])) }
        return (text, time, nil)
    }

    /// `window`, `window+12`, `window-8` → the margin in source pixels (nil = not a window crop).
    public static func windowCrop(_ s: String) throws -> Double? {
        let v = s.lowercased().trimmingCharacters(in: .whitespaces)
        guard v.hasPrefix("window") else { return nil }
        let rest = v.dropFirst(6)
        if rest.isEmpty { return 0 }
        guard rest.first == "+" || rest.first == "-", let m = Double(rest) else {
            throw ReelError.message("--crop \(s): use window, window+12 or window-8 (margin in source pixels)")
        }
        return m
    }

    /// Optional `N=` prefix used to target a specific clip (1-based) or boundary.
    public static func indexed(_ s: String) -> (index: Int?, value: String) {
        if let eq = s.firstIndex(of: "="), let n = Int(s[..<eq]) { return (n, String(s[s.index(after: eq)...])) }
        return (nil, s)
    }

    /// `x,y,w,h` in pixels, or with `%` suffixes relative to the source size.
    public static func crop(_ s: String, sourceWidth: Double, sourceHeight: Double) throws -> EditPlan.PixelRect {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4 else { throw ReelError.message("--crop expects x,y,w,h (got \(s))") }
        let dims = [sourceWidth, sourceHeight, sourceWidth, sourceHeight]
        var v: [Double] = []
        for (i, p) in parts.enumerated() {
            if p.hasSuffix("%"), let n = Double(p.dropLast()) { v.append(n / 100 * dims[i]) }
            else if let n = Double(p) { v.append(n) }
            else { throw ReelError.message("Bad --crop value \(p)") }
        }
        let x = max(0, v[0]), y = max(0, v[1])
        let r = EditPlan.PixelRect(x: x, y: y, width: min(v[2], sourceWidth - x), height: min(v[3], sourceHeight - y))
        guard r.width >= 16, r.height >= 16 else { throw ReelError.message("--crop \(s) is outside the \(Int(sourceWidth))×\(Int(sourceHeight)) source") }
        return r
    }

    /// `START-END:SCALE[@X,Y|@cursor]`, e.g. `2-5.5:2@0.7,0.3` or `8-12:1.6@cursor`
    public static func zoom(_ s: String) throws -> EditPlan.Zoom {
        let bad = ReelError.message("--zoom expects START-END:SCALE[@X,Y|@cursor] (got \(s))")
        let atSplit = s.split(separator: "@", maxSplits: 1).map(String.init)
        let head = atSplit[0].split(separator: ":").map(String.init)
        guard head.count == 2, let scale = Double(head[1]), scale >= 1 else { throw bad }
        let range = head[0].split(separator: "-").compactMap { Double($0) }
        guard range.count == 2, range[1] > range[0] else { throw bad }
        var target = EditPlan.ZoomTarget.point(x: 0.5, y: 0.5)
        if atSplit.count == 2 {
            if atSplit[1] == "cursor" { target = .cursor }
            else {
                let xy = atSplit[1].split(separator: ",").compactMap { Double($0) }
                guard xy.count == 2 else { throw bad }
                target = .point(x: xy[0], y: xy[1])
            }
        }
        return .init(start: range[0], end: range[1], scale: scale, target: target)
    }

    /// A zoom as written on the command line, before it is placed on the timeline.
    ///   [N=][src:]A-B:SCALE[@X,Y|@cursor]     [N=][src:]A-B:rect=X,Y,W,H
    /// `A..B` allows marker names (`step-1..step-2+0.5`), which implies source time.
    public struct ZoomSpec: Sendable, Equatable {
        public enum Target: Sendable, Equatable { case point(Double, Double), cursor, rect(Double, Double, Double, Double) }
        public var clip: Int?          // 1-based, from N=
        public var source: Bool        // times/positions are in the source clip
        public var start: String
        public var end: String
        public var scale: Double?      // nil for rect (computed)
        public var target: Target
    }

    public static func zoomSpec(_ raw: String) throws -> ZoomSpec {
        let bad = ReelError.message("--zoom expects [N=][src:]START-END:SCALE[@X,Y|@cursor] or …:rect=X,Y,W,H (got \(raw))")
        let (idx, rest0) = indexed(raw)
        var rest = rest0
        var source = false
        if rest.hasPrefix("src:") { source = true; rest.removeFirst(4) }
        guard let colon = rest.firstIndex(of: ":") else { throw bad }
        let time = String(rest[..<colon]), body = String(rest[rest.index(after: colon)...])
        var a: String, b: String
        if let r = time.range(of: "..") {
            a = String(time[..<r.lowerBound]); b = String(time[r.upperBound...])
        } else {
            let parts = time.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, Double(parts[0]) != nil, Double(parts[1]) != nil else {
                throw ReelError.message("--zoom \(raw): use START..END when times are marker names")
            }
            a = parts[0]; b = parts[1]
        }
        a = a.trimmingCharacters(in: .whitespaces); b = b.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !b.isEmpty else { throw bad }
        if Double(a) == nil || Double(b) == nil { source = true }  // marker refs are source times
        if let x = Double(a), let y = Double(b), y <= x { throw bad }

        if body.hasPrefix("rect=") {
            let v = body.dropFirst(5).split(separator: ",").compactMap { Double($0) }
            guard v.count == 4, v[2] > 0, v[3] > 0 else { throw bad }
            return .init(clip: idx, source: source, start: a, end: b, scale: nil, target: .rect(v[0], v[1], v[2], v[3]))
        }
        let at = body.split(separator: "@", maxSplits: 1).map(String.init)
        guard let scale = Double(at[0]), scale >= 1 else { throw bad }
        var target = ZoomSpec.Target.point(0.5, 0.5)
        if at.count == 2 {
            if at[1] == "cursor" { target = .cursor }
            else {
                let xy = at[1].split(separator: ",").compactMap { Double($0) }
                guard xy.count == 2 else { throw bad }
                target = .point(xy[0], xy[1])
            }
        }
        return .init(clip: idx, source: source, start: a, end: b, scale: scale, target: target)
    }

    /// `crossfade`, `crossfade:0.8`, `slide-left:0.5`, `cut`
    public static func transition(_ s: String, defaultDuration: Double = 0.6) throws -> EditPlan.Transition {
        let parts = s.split(separator: ":").map(String.init)
        guard let kind = EditPlan.TransitionKind(rawValue: parts[0]) else {
            throw ReelError.message("Unknown transition \(parts[0]). Options: \(EditPlan.TransitionKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let d = parts.count > 1 ? (Double(parts[1]) ?? defaultDuration) : defaultDuration
        return .init(kind: kind, duration: kind == .cut ? 0 : d)
    }

    public static func size(_ s: String) throws -> (Int, Int) {
        let p = s.lowercased().split(separator: "x").compactMap { Int($0) }
        guard p.count == 2, p[0] > 0, p[1] > 0 else { throw ReelError.message("--size expects WxH (got \(s))") }
        return (p[0] & ~1, p[1] & ~1)
    }

    public static func color(_ hex: String) throws -> CGColor {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { throw ReelError.message("Bad color \(hex)") }
        let has = h.count == 8
        let r = Double((v >> (has ? 24 : 16)) & 0xff) / 255
        let g = Double((v >> (has ? 16 : 8)) & 0xff) / 255
        let b = Double((v >> (has ? 8 : 0)) & 0xff) / 255
        let a = has ? Double(v & 0xff) / 255 : 1
        return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

extension EditPlan {
    /// Builds zoom segments from recorded clicks: one zoom per burst of clicks,
    /// following the cursor while zoomed.
    public static func autoZooms(clicks: [(t: Double, x: Double, y: Double)], scale: Double,
                                 lead: Double = 0.6, hold: Double = 1.8) -> [Zoom] {
        var zooms: [Zoom] = []
        for c in clicks.sorted(by: { $0.t < $1.t }) {
            let start = max(0, c.t - lead), end = c.t + hold
            if var last = zooms.last, start <= last.end + 0.5 {
                last.end = max(last.end, end)
                last.target = .cursor
                zooms[zooms.count - 1] = last
            } else {
                zooms.append(.init(start: start, end: end, scale: scale, target: .point(x: c.x, y: c.y)))
            }
        }
        return zooms
    }
}
