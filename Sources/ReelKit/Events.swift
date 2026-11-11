import Foundation

/// Cursor and click data captured alongside a recording, stored as a sidecar
/// `<name>.events.json` next to the video. Coordinates are normalized (0–1) to
/// the captured content with a top-left origin, so they map directly onto the
/// video frame. Values outside 0–1 mean the cursor was outside the capture.
public struct RecordingEvents: Codable, Sendable {
    public var version: Int = 1
    /// Captured region in global screen points (top-left origin).
    public var captureRect: Rect
    public var pointPixelScale: Double
    public var samples: [CursorSample]
    /// Whether the system cursor was captured into the video (nil in older sidecars).
    public var cursorInVideo: Bool?
    /// Wall-clock time (Unix seconds) of t=0, so other processes can timestamp events.
    public var startedAt: Double?
    /// Named moments in source time, from `reel mark` or a cursor script.
    public var markers: [Marker]?
    /// Cursor shape changes (arrow until the first one). Nil = always an arrow.
    public var shapes: [ShapeChange]?
    /// True when the track was generated from a cursor script, not recorded.
    public var synthetic: Bool?
    /// Labelled UI element frames (record --ax-snapshots), at the start and at each marker.
    public var snapshots: [ElementSnapshot]?
    /// The app's window in global points, when known. Equals captureRect for window
    /// recordings; inside it for --display --app. Window-relative script coordinates
    /// and element targets map through it.
    public var window: Rect?
    /// Images to draw over the source (record --clean-titlebar), applied by `reel edit`.
    public var patches: [Patch]?
    /// Keystroke captions (cursor-script "caption" steps), drawn by `reel edit`.
    public var captions: [Caption]?

    public struct Caption: Codable, Sendable, Equatable {
        public var t: Double              // source seconds
        public var text: String
        public var duration: Double?      // seconds on screen (default 1.6)
        public init(t: Double, text: String, duration: Double? = nil) { self.t = t; self.text = text; self.duration = duration }
    }

    /// An image drawn over a rectangle of the source video, in source pixels
    /// (top-left origin), for source times start…end (nil = open-ended).
    public struct Patch: Codable, Sendable, Equatable {
        public var image: String          // relative to the sidecar's folder, or absolute
        public var x, y, width, height: Double
        public var start: Double?
        public var end: Double?
        /// Pixels over which the right and bottom edges blend into the footage.
        public var feather: Double?
        /// Shift the image's tone as the footage at its right edge has changed since the
        /// still was taken (a sheet or modal's scrim over the window). Recorded patches default to true.
        public var matchTone: Bool?
        public init(image: String, x: Double, y: Double, width: Double, height: Double,
                    start: Double? = nil, end: Double? = nil, feather: Double? = nil, matchTone: Bool? = nil) {
            self.image = image; self.x = x; self.y = y; self.width = width; self.height = height
            self.start = start; self.end = end; self.feather = feather; self.matchTone = matchTone
        }
    }

    public init(captureRect: Rect, pointPixelScale: Double, samples: [CursorSample], cursorInVideo: Bool? = nil) {
        self.captureRect = captureRect
        self.pointPixelScale = pointPixelScale
        self.samples = samples
        self.cursorInVideo = cursorInVideo
    }

    public struct Rect: Codable, Sendable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    public struct CursorSample: Codable, Sendable {
        public var t: Double
        public var x: Double
        public var y: Double
        public var down: Bool
    }

    public struct Marker: Codable, Sendable, Equatable {
        public var label: String
        public var t: Double
        public init(label: String, t: Double) { self.label = label; self.t = t }
    }

    public struct ShapeChange: Codable, Sendable, Equatable {
        public var t: Double
        public var shape: CursorShape
        public init(t: Double, shape: CursorShape) { self.t = t; self.shape = shape }
    }

    /// Shape in effect at source time `t`.
    public func shape(at t: Double) -> CursorShape {
        guard let shapes else { return .arrow }
        var current = CursorShape.arrow
        for s in shapes { if s.t <= t { current = s.shape } else { break } }
        return current
    }

    /// Resolves a time reference: a number, a marker label, or `label+0.3` / `label-0.3`.
    public func resolveTime(_ ref: String) throws -> Double {
        try TimeRef.resolve(ref, markers: markers ?? [])
    }

    public struct Click: Codable, Sendable {
        public var t: Double
        public var x: Double
        public var y: Double
    }

    /// Mouse-down transitions that happened inside the captured area.
    public var clicks: [Click] {
        var result: [Click] = []
        var wasDown = false
        for s in samples {
            if s.down && !wasDown, (0...1).contains(s.x), (0...1).contains(s.y) {
                result.append(Click(t: s.t, x: s.x, y: s.y))
            }
            wasDown = s.down
        }
        return result
    }

    /// Cursor position averaged over a window around `t`, which removes jitter
    /// so a zoom that follows the cursor glides instead of shaking.
    public func smoothedCursor(at t: Double, window: Double = 0.35) -> (x: Double, y: Double)? {
        guard !samples.isEmpty else { return nil }
        let lo = lowerBound(t - window), hi = lowerBound(t + window)
        if hi > lo {
            var sx = 0.0, sy = 0.0
            for s in samples[lo..<hi] { sx += s.x; sy += s.y }
            let n = Double(hi - lo)
            return (sx / n, sy / n)
        }
        let s = samples[min(lo, samples.count - 1)]
        return (s.x, s.y)
    }

    /// The raw sample at or just after `t`.
    public func sample(at t: Double) -> CursorSample? {
        samples.isEmpty ? nil : samples[min(lowerBound(t), samples.count - 1)]
    }

    private func lowerBound(_ t: Double) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    public static func sidecarURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("events.json")
    }

    /// Reads an events file, with a useful error if it is missing or malformed.
    public static func read(_ url: URL) throws -> RecordingEvents {
        guard let data = try? Data(contentsOf: url) else { throw ReelError.message("Cannot read events file \(url.path)") }
        do { return try JSONDecoder().decode(RecordingEvents.self, from: data) }
        catch let e as DecodingError { throw ReelError.message("\(url.lastPathComponent): \(CursorScript.describe(e))") }
    }

    public func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(self).write(to: url)
    }

    public static func load(for video: URL) -> RecordingEvents? {
        let url = sidecarURL(for: video)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordingEvents.self, from: data)
    }

    public func write(for video: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(self).write(to: Self.sidecarURL(for: video))
    }
}
