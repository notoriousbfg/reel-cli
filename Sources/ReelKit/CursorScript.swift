import Foundation

public enum CursorShape: String, Codable, Sendable, CaseIterable {
    case arrow, ibeam, hand, crosshair
}

/// Time references used by cursor scripts and `--zoom`: plain seconds, or a
/// marker label with an optional signed offset (`step-2`, `step-2+0.4`, `step-2-0.3`).
public enum TimeRef {
    public static func resolve(_ ref: String, markers: [RecordingEvents.Marker]) throws -> Double {
        let s = ref.trimmingCharacters(in: .whitespaces)
        if let v = Double(s) { return v }
        // Longest label first, so `step-1` wins over `step` for "step-1-0.3".
        for m in markers.sorted(by: { $0.label.count > $1.label.count }) where s.hasPrefix(m.label) {
            let rest = s.dropFirst(m.label.count)
            if rest.isEmpty { return m.t }
            if let off = Double(rest), rest.first == "+" || rest.first == "-" { return m.t + off }
        }
        let known = markers.map(\.label)
        throw ReelError.message("Unknown time or marker '\(ref)'" + (known.isEmpty ? " (this clip has no markers)" : ". Markers: \(known.joined(separator: ", "))"))
    }
}

/// A hand-authored cursor track. Generates the same sample stream `reel record`
/// writes, so everything that reads events (drawn cursor, @cursor zooms,
/// --auto-zoom, contact-sheet click rings) works on scripted footage.
///
/// Steps (times in source-clip seconds, or marker references):
///   {"at": 4.3, "move": [0.435, 0.025], "over": 0.8}   ease in/out, arriving at `at`
///   {"at": 4.35, "click": true}                         press and release in place
///   {"at": 4.35, "click": [0.5, 0.2]}                   move there quickly, then click
///   {"at": 14.6, "drag": [[0.35,0.37],[0.55,0.37]], "over": 1.0}   press at `at`, linear, release
///   {"at": 9.0, "down": true} / {"at": 9.4, "up": true}
///   {"at": 12.0, "shape": "ibeam"}                      arrow | ibeam | hand | crosshair
///   {"at": 0, "hide": true} / {"at": 2, "show": true}   (cursor visible by default)
/// Coordinates: 0–1 of the captured frame, or strings with a unit: "640pt", "1280px".
public struct CursorScript: Sendable {
    public struct Step: Codable, Sendable {
        public var at: TimeValue
        public var move: Target?
        public var over: Double?
        public var click: ClickValue?
        public var drag: [Target]?
        public var count: Int?          // click count (2 = double-click)
        public var button: String?      // click: "left" (default) or "right"
        public var modifiers: [String]? // click: keys held, e.g. ["option"] (performed by reel act)
        public var caption: String?     // drawn only: a keystroke caption, shown for "over" seconds
        public var type: String?        // reel act: text to type
        public var key: String?         // reel act: e.g. "cmd+s", "return"
        public var scroll: [Double]?    // reel act: [dx, dy] in points (positive dy scrolls down)
        public var down: Bool?
        public var up: Bool?
        public var shape: CursorShape?
        public var hide: Bool?
        public var show: Bool?
        public var mark: String?
    }

    /// `at` may be a number or a marker string.
    public enum TimeValue: Codable, Sendable {
        case seconds(Double), ref(String)
        public init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let v = try? c.decode(Double.self) { self = .seconds(v) } else { self = .ref(try c.decode(String.self)) }
        }
        public func encode(to e: Encoder) throws {
            var c = e.singleValueContainer()
            switch self { case .seconds(let v): try c.encode(v); case .ref(let s): try c.encode(s) }
        }
        func resolve(_ markers: [RecordingEvents.Marker]) throws -> Double {
            switch self { case .seconds(let v): return v; case .ref(let s): return try TimeRef.resolve(s, markers: markers) }
        }
    }

    /// A coordinate: a 0–1 number, or "<n>pt" / "<n>px".
    public enum Coord: Codable, Sendable {
        case unit(Double), points(Double), pixels(Double)
        public init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let v = try? c.decode(Double.self) { self = .unit(v); return }
            let s = try c.decode(String.self).trimmingCharacters(in: .whitespaces).lowercased()
            if s.hasSuffix("pt"), let v = Double(s.dropLast(2)) { self = .points(v) }
            else if s.hasSuffix("px"), let v = Double(s.dropLast(2)) { self = .pixels(v) }
            else if let v = Double(s) { self = .unit(v) }
            else { throw ReelError.message("Bad coordinate '\(s)': use 0–1, \"640pt\" or \"1280px\"") }
        }
        public func encode(to e: Encoder) throws {
            var c = e.singleValueContainer()
            switch self {
            case .unit(let v): try c.encode(v)
            case .points(let v): try c.encode("\(v)pt")
            case .pixels(let v): try c.encode("\(v)px")
            }
        }
        /// Normalized value along an axis `points` long, at `scale` pixels per point.
        func normalized(points: Double, scale: Double) -> Double {
            switch self {
            case .unit(let v): return v
            case .points(let v): return v / points
            case .pixels(let v): return v / (points * scale)
            }
        }
    }

    /// A UI element by accessibility label, resolved from snapshots (drawing)
    /// or live (reel act). `anchor` is the point inside it, 0–1 (default centre).
    public struct ElementRef: Codable, Sendable, Equatable {
        public var label: String
        public var role: String?
        public var index: Int?
        public var anchor: [Double]?
    }

    /// Where to put the cursor: [x, y] or {"label": …}.
    public enum Target: Codable, Sendable {
        case point([Coord]), element(ElementRef)
        public init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let p = try? c.decode([Coord].self) { self = .point(p); return }
            do { self = .element(try c.decode(ElementRef.self)) }
            catch { throw ReelError.message("expected [x, y] or {\"label\": \"…\"}") }
        }
        public func encode(to e: Encoder) throws {
            var c = e.singleValueContainer()
            switch self { case .point(let p): try c.encode(p); case .element(let r): try c.encode(r) }
        }
    }

    public enum ClickValue: Codable, Sendable {
        case here, at(Target)
        public init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let b = try? c.decode(Bool.self) {
                guard b else { throw ReelError.message("\"click\": false does nothing; remove the step") }
                self = .here
            } else { self = .at(try c.decode(Target.self)) }
        }
        public func encode(to e: Encoder) throws {
            var c = e.singleValueContainer()
            switch self { case .here: try c.encode(true); case .at(let p): try c.encode(p) }
        }
    }

    /// Resolves coordinates and element targets to normalized window points.
    public struct Resolver {
        public var width: Double, height: Double, scale: Double
        /// (element, time) → normalized point; nil = element targets unsupported here.
        public var element: ((ElementRef, Double) throws -> (Double, Double))?

        public func point(_ target: Target, at t: Double, _ what: String) throws -> (Double, Double) {
            switch target {
            case .point(let c):
                guard c.count == 2 else { throw ReelError.message("\(what) needs [x, y]") }
                return (c[0].normalized(points: width, scale: scale), c[1].normalized(points: height, scale: scale))
            case .element(let ref):
                guard let element else { throw ReelError.message("\(what): element targets aren't available here") }
                do { return try element(ref, t) } catch { throw ReelError.message("\(what): \(error.localizedDescription)") }
            }
        }

        /// Element centre (or anchor) from a frame normalized to the window.
        public static func anchor(_ ref: ElementRef, in f: RecordingEvents.Rect) -> (Double, Double) {
            let a = ref.anchor ?? [0.5, 0.5]
            return (f.x + f.width * (a.count > 0 ? a[0] : 0.5), f.y + f.height * (a.count > 1 ? a[1] : 0.5))
        }
    }

    /// Markers available to `at` references: recorded ones plus script `mark` steps.
    public func markers(base: [RecordingEvents.Marker]) -> [RecordingEvents.Marker] {
        var m = base
        for s in steps { if let l = s.mark, case .seconds(let t) = s.at { m.append(.init(label: l, t: t)) } }
        return m
    }

    /// Steps with resolved times, in order.
    public func timeline(markers: [RecordingEvents.Marker]) throws -> [(t: Double, index: Int, step: Step)] {
        try steps.enumerated().map { (i, s) -> (t: Double, index: Int, step: Step) in
            do { return (try s.at.resolve(markers), i, s) }
            catch { throw ReelError.message("step \(i + 1): \(error.localizedDescription)") }
        }.sorted { ($0.t, $0.index) < ($1.t, $1.index) }
    }

    public var steps: [Step]
    /// `reel act` only: steps performed before the recording starts (ignored when drawing).
    public var setup: [Step]?
    /// "capture" (default): coordinates are 0–1 of the recorded frame. "window": 0–1 of
    /// the app's window (sidecar `window`), so one script fits window and display
    /// recordings, drawn or performed. Element targets are always window-relative.
    public var coordinates: String?
    var windowCoordinates: Bool { coordinates == "window" }

    public init(steps: [Step], setup: [Step]? = nil, coordinates: String? = nil) {
        self.steps = steps; self.setup = setup; self.coordinates = coordinates
    }

    /// Accepts a JSON array of steps, or {"setup": [...], "steps": [...]}.
    public static func load(_ url: URL) throws -> CursorScript {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ReelError.message("Cannot read cursor script \(url.path)") }
        return try parse(data, name: url.lastPathComponent)
    }

    public static func parse(_ data: Data, name: String = "cursor script") throws -> CursorScript {
        struct Wrapped: Decodable { var steps: [Step]?; var setup: [Step]?; var coordinates: String? }
        do {
            if let steps = try? JSONDecoder().decode([Step].self, from: data) {
                try validate(steps, name: name)
                return .init(steps: steps)
            }
            let w = try JSONDecoder().decode(Wrapped.self, from: data)
            guard w.steps != nil || w.setup != nil else { throw ReelError.message("\(name): expected an array of steps or {\"steps\": [...]}") }
            if let c = w.coordinates, c != "window", c != "capture" {
                throw ReelError.message("\(name): \"coordinates\" is \"window\" or \"capture\" (got \"\(c)\")")
            }
            try validate(w.steps ?? [], name: name)
            try validate(w.setup ?? [], name: name + " setup")
            return .init(steps: w.steps ?? [], setup: w.setup, coordinates: w.coordinates)
        } catch let e as DecodingError {
            throw ReelError.message("\(name): \(Self.describe(e))")
        }
    }

    static func validate(_ steps: [Step], name: String) throws {
        for (i, s) in steps.enumerated() {
            let at = "\(name) step \(i + 1)"
            if let b = s.button {
                guard b == "left" || b == "right" else { throw ReelError.message("\(at): \"button\" is \"left\" or \"right\" (got \"\(b)\")") }
                guard s.click != nil else { throw ReelError.message("\(at): \"button\" goes with \"click\"") }
            }
            if let m = s.modifiers {
                guard s.click != nil else { throw ReelError.message("\(at): \"modifiers\" goes with \"click\"") }
                do { _ = try Keys.flags(m) } catch { throw ReelError.message("\(at): \(error.localizedDescription)") }
            }
            if let c = s.caption, c.isEmpty { throw ReelError.message("\(at): \"caption\" is empty") }
        }
    }

    static func describe(_ e: DecodingError) -> String {
        switch e {
        case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c):
            let path = c.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            let under = (c.underlyingError as? LocalizedError)?.errorDescription
            return "\(path.isEmpty ? "" : path + ": ")\(under ?? c.debugDescription)"
        @unknown default: return "\(e)"
        }
    }

    public static let defaultCaption = 1.6
    public static let clickHold = 0.09
    public static let defaultMove = 0.6
    public static let sampleRate = 120.0

    /// Builds an events track.
    /// - Parameters:
    ///   - base: the recorded sidecar, if any. Its capture rect, scale, markers and
    ///     start time are kept; its samples are replaced.
    ///   - pointsSize/pointPixelScale: used when there is no base sidecar.
    ///   - duration: clip length; samples cover 0…duration.
    public func events(base: RecordingEvents?, pointsSize: (w: Double, h: Double), pointPixelScale: Double,
                       duration: Double, warn: ((String) -> Void)? = nil) throws -> RecordingEvents {
        let scale = base?.pointPixelScale ?? pointPixelScale
        let W = base?.captureRect.width ?? pointsSize.w, H = base?.captureRect.height ?? pointsSize.h
        // Script-defined marks first, so later steps can reference them.
        let markers = self.markers(base: base?.markers ?? [])
        // Window-relative points (elements, "coordinates": "window") → captured frame.
        let win = base?.window, cap = base?.captureRect
        func toCapture(_ p: (Double, Double)) -> (Double, Double) {
            guard let win, let cap, cap.width > 0, cap.height > 0 else { return p }
            return ((win.x + p.0 * win.width - cap.x) / cap.width, (win.y + p.1 * win.height - cap.y) / cap.height)
        }
        let resolver = Resolver(width: windowCoordinates ? (win?.width ?? W) : W,
                                height: windowCoordinates ? (win?.height ?? H) : H, scale: scale, element: { ref, t in
            guard let base else { throw ReelError.message("element \"\(ref.label)\" needs a recording made with --ax-snapshots") }
            let e = try base.element(ref.label, role: ref.role, index: ref.index ?? 0, at: t)
            return toCapture(Resolver.anchor(ref, in: e.frame))
        })
        func point(_ c: Target, _ what: String, _ t: Double) throws -> (Double, Double) {
            let p = try resolver.point(c, at: t, what)
            if case .point = c, windowCoordinates { return toCapture(p) }
            return p
        }

        enum Ease { case inOut, linear }
        struct Segment { var t0, t1: Double; var a, b: (Double, Double); var ease: Ease }
        var segments: [Segment] = []
        var downs: [(Double, Double)] = []      // pressed intervals
        var shapes: [RecordingEvents.ShapeChange] = []
        var visibility: [(Double, Bool)] = []
        var captions: [RecordingEvents.Caption] = []
        var pos: (Double, Double)? = nil
        var posT = 0.0
        var openDown: Double? = nil

        let resolved = try timeline(markers: markers).map { ($0.t, $0.index, $0.step) }

        var current = ""
        func travel(to p: (Double, Double), arriving t: Double, over: Double, ease: Ease = .inOut) {
            guard let from = pos else { pos = p; posT = t; return }   // first position: appear there
            var start = max(posT, t - max(0, over)), end = t
            if end <= start + 1e-6 && (from.0 != p.0 || from.1 != p.1) {
                // The previous step is still running: glide as soon as it ends instead of jumping.
                end = start + max(0.15, min(over, 0.4))
                warn?(String(format: "%@ starts before the previous step ends (%.2fs); it arrives at %.2fs instead of %.2fs",
                             current, posT, end, t))
            }
            if end > start { segments.append(.init(t0: start, t1: end, a: from, b: p, ease: ease)) }
            start = end
            pos = p; posT = max(posT, end)
        }

        for (t, i, s) in resolved {
            let label = "step \(i + 1)"
            current = label
            if let m = s.move { travel(to: try point(m, "\(label) move", t), arriving: t, over: s.over ?? Self.defaultMove) }
            if let c = s.click {
                if case .at(let p) = c { travel(to: try point(p, "\(label) click", t), arriving: t, over: s.over ?? 0.35) }
                for k in 0..<max(1, s.count ?? 1) {
                    let t0 = t + Double(k) * 0.16
                    downs.append((t0, t0 + Self.clickHold))
                }
            }
            if let d = s.drag {
                guard d.count >= 2 else { throw ReelError.message("\(label) drag needs at least two points") }
                let pts = try d.map { try point($0, "\(label) drag", t) }
                let over = s.over ?? 0.8
                travel(to: pts[0], arriving: t, over: 0.35)
                // Linear through each point, evenly spaced in time.
                let leg = over / Double(pts.count - 1)
                for k in 1..<pts.count {
                    segments.append(.init(t0: t + leg * Double(k - 1), t1: t + leg * Double(k), a: pts[k - 1], b: pts[k], ease: .linear))
                }
                pos = pts.last!; posT = t + over
                downs.append((t, t + over))
            }
            if s.down == true { openDown = t }
            if s.up == true, let d0 = openDown { downs.append((d0, t)); openDown = nil }
            if let sh = s.shape { shapes.append(.init(t: t, shape: sh)) }
            if let text = s.caption { captions.append(.init(t: t, text: text, duration: s.over ?? Self.defaultCaption)) }
            if s.hide == true { visibility.append((t, false)) }
            if s.show == true { visibility.append((t, true)) }
        }
        if let d0 = openDown { downs.append((d0, .infinity)) }
        guard let firstPos = segments.first?.a ?? pos ?? (captions.isEmpty ? nil : (-1, -1)) else {
            throw ReelError.message("Cursor script never places the cursor: add a step with \"move\": [x, y]")
        }

        let segs = segments.sorted { $0.t0 < $1.t0 }
        func position(_ t: Double) -> (Double, Double) {
            var p = firstPos
            for s in segs {
                if t >= s.t1 { p = s.b; continue }
                if t <= s.t0 { break }
                let u = (t - s.t0) / (s.t1 - s.t0)
                let e = s.ease == .linear ? u : (u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2)
                return (s.a.0 + (s.b.0 - s.a.0) * e, s.a.1 + (s.b.1 - s.a.1) * e)
            }
            // Before any motion, a later "first placement" still applies from t=0.
            return segs.isEmpty ? (pos ?? firstPos) : p
        }
        func visible(_ t: Double) -> Bool {
            var v = true
            for (vt, on) in visibility.sorted(by: { $0.0 < $1.0 }) { if vt <= t { v = on } else { break } }
            return v
        }

        let end = max(duration, (resolved.last?.0 ?? 0))
        let n = Int((end * Self.sampleRate).rounded(.up))
        let r = { (v: Double) in (v * 10000).rounded() / 10000 }
        var samples: [RecordingEvents.CursorSample] = []
        samples.reserveCapacity(n + 1)
        for k in 0...n {
            let t = Double(k) / Self.sampleRate
            var p = position(t)
            // Hidden cursors are parked outside the frame; everything treats that as "not visible".
            if !visible(t) { p = (-1, -1) }
            let down = downs.contains { t >= $0.0 && t < $0.1 }
            samples.append(.init(t: r(t), x: r(p.0), y: r(p.1), down: down))
        }

        var ev = RecordingEvents(
            captureRect: base?.captureRect ?? .init(x: 0, y: 0, width: W, height: H),
            pointPixelScale: scale, samples: samples, cursorInVideo: base?.cursorInVideo)
        ev.startedAt = base?.startedAt
        ev.markers = markers.isEmpty ? nil : markers
        ev.shapes = shapes.isEmpty ? nil : shapes.sorted { $0.t < $1.t }
        ev.captions = captions.isEmpty ? nil : captions.sorted { $0.t < $1.t }
        ev.synthetic = true
        ev.window = base?.window
        return ev
    }
}
