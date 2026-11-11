import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore
import ScreenCaptureKit

public enum ReelError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

public struct RecordOptions: Sendable {
    public var app: String?            // bundle id, app name, or .app path (that exact bundle)
    public var launch = false
    public var newInstance = false     // always start a fresh process
    public var environment: [String: String] = [:]
    public var arguments: [String] = []
    public var background = false      // launch without activating
    public var pid: Int32?             // record a window of this running process
    public var untilExit = false       // stop when the recorded process quits
    public var quitAfter = false       // quit the recorded process when recording ends
    public var axSnapshots = false     // store labelled UI element frames at start and each marker (Accessibility)
    public var cursorShapes = true     // note the on-screen cursor shape (I-beam, hand…) in the sidecar
    public var marksFile: URL?         // watch this file for "<label> <unix time>" lines (sandboxed harnesses)
    public var maxRestarts = 5         // restart capture this many times if macOS stops the stream
    public var startOn: String?        // launch, but start capturing when this marker arrives (t=0)
    public var stopOn: String?         // stop when this marker arrives (+ tail)
    public var failOn: String?         // end the take at once, as failed, when this marker arrives
    public var also: [String] = []     // --display --app: other apps whose windows are recorded too
    public var tail: Double = 0        // seconds to keep recording after the stop marker
    public var markerTimeout: Double?  // bound on each marker wait; fails the take
    public var cleanTitlebar = false
    public var forceQuit = false       // if the app won't quit (a sheet is open), force it
    public var includeChildWindows = false // also capture the app's popovers, menus and drag images over the window   // store a still of the traffic-light corner to patch over the capture pill
    public var openURL: String?        // URL/file to open in the app (e.g. localhost for web devs)
    public var windowTitle: String?    // substring match on window title
    public var windowID: UInt32?
    public var display = false         // capture the whole main display
    public var duration: Double?       // nil = until SIGINT/SIGTERM or `reel stop`
    public var countdown: Double = 0
    public var fps = 60
    public var showsCursor = true
    public var trackCursor = true
    public var hevc = true
    public var output: URL
    public var windowTimeout: Double = 15

    public init(output: URL) { self.output = output }

    /// Whether reel starts or activates the app itself.
    var wantsLaunch: Bool { launch || newInstance || openURL != nil || !environment.isEmpty || !arguments.isEmpty }
}

public struct RecordResult: Codable, Sendable {
    public var output: String
    public var events: String?
    public var width: Int
    public var height: Int
    public var duration: Double
    public var app: String?
    public var windowTitle: String?
    public var pid: Int32?
    public var windowID: UInt32?
    public var markers: [RecordingEvents.Marker]?
    /// Set when the recording ended before it was asked to (e.g. the window closed).
    public var stoppedEarly: String?
    /// The error behind the last stream stop (domain, code, description).
    public var stopError: ErrorInfo?
    /// How many times capture was restarted after macOS stopped the stream.
    public var restarts: Int = 0
    /// Seconds of the take with no new frames (sum of `gaps`; a held frame shows).
    public var lostSeconds: Double = 0
    /// Seconds with no new frames while capture restarted (held frame in the video).
    public var gaps: [[Double]]?
    /// Set when --quit-after asked the app to quit: true only once the process has exited.
    public var quit: Bool?
    /// True when the app had to be force-quit (--force-quit).
    public var forcedQuit: Bool?
    /// What ended the take: duration, stop-marker, stop (Ctrl-C / reel stop), app-exit,
    /// stream-error or timeout.
    public var endedBy: String?
    /// Set when --timeout expired waiting for the stop marker (the file is still finalised).
    public var timedOut: String?
    /// Set when the take was ended as failed (--fail-on's marker, `reel stop --fail`,
    /// `reel act --stop-recording-on-error`). The file is kept; `reel record` exits 5.
    public var failed: String?
}

public struct ShotOptions: Sendable {
    public var settle: Double = 0      // seconds to wait after the start marker (or the window appearing)
    public var crop: String?
    public var width: Int?
    public var quality: Double = 0.9   // JPEG
    public var keepOpen = false        // don't quit an app reel launched
    public init() {}
}

public struct ShotResult: Codable, Sendable {
    public var output: String
    public var width: Int
    public var height: Int
    public var pid: Int32?
    public var windowID: UInt32?
    public var windowTitle: String?
    public var markers: [RecordingEvents.Marker]?
    public var quit: Bool?
    public var forcedQuit: Bool?
}

public struct WindowInfo: Codable, Sendable {
    public var id: UInt32
    public var app: String
    public var bundleID: String
    public var title: String
    public var x, y, width, height: Double
}

public enum Permissions {
    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt (first time only) and returns a helpful error.
    public static func requireScreenRecording() throws {
        if CGPreflightScreenCaptureAccess() { return }
        CGRequestScreenCaptureAccess()
        throw ReelError.message("""
            Screen Recording permission is required for `reel record` / `reel windows`.
            Grant it to your terminal app in System Settings › Privacy & Security ›
            Screen & System Audio Recording, then restart the terminal.
            (Editing, `info`, `frame` and `sheet` need no permissions.)
            """)
    }
}

public enum Windows {
    public static func list() async throws -> [WindowInfo] {
        try Permissions.requireScreenRecording()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows
            .filter { $0.windowLayer == 0 && $0.frame.width > 50 && $0.frame.height > 50 && $0.owningApplication != nil }
            .map { w in
                WindowInfo(id: w.windowID,
                           app: w.owningApplication?.applicationName ?? "",
                           bundleID: w.owningApplication?.bundleIdentifier ?? "",
                           title: w.title ?? "",
                           x: w.frame.minX, y: w.frame.minY, width: w.frame.width, height: w.frame.height)
            }
    }
}

public final class Recorder: @unchecked Sendable {
    private let opts: RecordOptions
    /// When this take began (before the app is launched). Marks-file lines stamped earlier
    /// belong to an older take and are ignored.
    private let began = Date().timeIntervalSince1970

    public init(options: RecordOptions) { self.opts = options }

    public func run(log: @escaping (String) -> Void) async throws -> RecordResult {
        self.log = log
        try Permissions.requireScreenRecording()
        // A bare CLI has no window-server (CGS) connection; SCShareableContent.info(for:),
        // SCStream and CGEvent assert without one. NSApplication.shared establishes it.
        await MainActor.run { _ = NSApplication.shared }

        if opts.startOn != nil && opts.countdown > 0 {
            throw ReelError.message("--countdown and --start-on don't mix: t=0 is the moment the start marker arrives")
        }
        if opts.axSnapshots {
            try Accessibility.require("--ax-snapshots")
            if opts.display && opts.app == nil && opts.pid == nil {
                throw ReelError.message("--ax-snapshots with --display needs --app or --pid to know which window")
            }
        }
        if !opts.also.isEmpty && !(opts.display && (opts.app != nil || opts.pid != nil)) {
            throw ReelError.message("--also adds other apps' windows to a display take of one app: use it with --display and --app or --pid")
        }
        if opts.includeChildWindows && opts.display {
            throw ReelError.message("--include-child-windows records one window (with its popovers); drop --display")
        }
        if opts.cleanTitlebar {
            if opts.display && opts.app == nil && opts.pid == nil {
                throw ReelError.message("--clean-titlebar with --display needs --app or --pid to know which window")
            }
            if !opts.trackCursor { throw ReelError.message("--clean-titlebar stores its patch in the events sidecar; drop --no-events") }
        }
        try FileManager.default.createDirectory(at: opts.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (target, targetPID, _) = try await prepareTarget(log: log)
        let signals = StopSignals(exitOf: targetPID)
        defer { signals.cancel() }
        var (state, marksWatcher) = try arm(target: target, pid: targetPID, log: log)
        defer { RecordingState.remove() }
        defer { marksWatcher?.stop() }
        if let label = opts.startOn {
            do { try await waitForStart(label, state: state, pid: targetPID, signals: signals, log: log) }
            catch { _ = await quitIfAsked(targetPID, log: log); throw error }
            if let pid = targetPID, !Self.alive(pid) {
                throw ReelError.message("The app exited before capture started")
            }
        }
        // Measured now, after any setup that moved or resized the window.
        let geo: Geometry
        do { geo = try await geometry(target) }
        catch { _ = await quitIfAsked(targetPID, log: log); throw error }
        let filter = geo.filter
        let scale = geo.scale
        let rect = geo.rect
        let windowRect = geo.window?.frame
        if (opts.axSnapshots || opts.cleanTitlebar) && geo.window == nil {
            throw ReelError.message("Couldn't find the app's window for --ax-snapshots / --clean-titlebar")
        }
        let width = Int((rect.width * scale).rounded()) & ~1
        let height = Int((rect.height * scale).rounded()) & ~1

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if let src = geo.sourceRect { config.sourceRect = src }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(opts.fps))
        config.showsCursor = opts.showsCursor
        config.captureResolution = .best
        config.queueDepth = 6
        config.capturesAudio = false

        // Segments are written next to the output and joined (or renamed) at the end.
        let dir = opts.output.deletingLastPathComponent()
        let base = opts.output.deletingPathExtension().lastPathComponent
        let ext = opts.output.pathExtension.isEmpty ? "mov" : opts.output.pathExtension
        func partURL(_ n: Int) -> URL { dir.appendingPathComponent(".\(base).part\(n).\(ext)") }
        try? FileManager.default.removeItem(at: opts.output)

        if opts.countdown > 0 {
            var remaining = Int(opts.countdown.rounded(.up))
            while remaining > 0 {
                log("Recording in \(remaining)…")
                try await Task.sleep(for: .seconds(1))
                remaining -= 1
            }
        }

        // --clean-titlebar: a still of the traffic-light corner, taken before each
        // stream starts (stills don't show the "being shared" pill).
        var titlebars: [RecordingEvents.Patch] = []
        func titlebarStill(at t: Double?) async {
            guard opts.cleanTitlebar else { return }
            let name = "\(base).titlebar\(titlebars.isEmpty ? "" : "-\(titlebars.count + 1)").png"
            guard let win = geo.window else { return }
            let stillFilter = SCContentFilter(desktopIndependentWindow: win)
            do {
                let w = min(90, win.frame.width), h = min(40, win.frame.height)
                let c = SCStreamConfiguration()
                c.sourceRect = CGRect(x: 0, y: 0, width: w, height: h)
                c.width = Int((w * scale).rounded()); c.height = Int((h * scale).rounded())
                c.showsCursor = false
                c.captureResolution = .best
                var img = try await SCScreenshotManager.captureImage(contentFilter: stillFilter, configuration: c)
                if t != nil {
                    // After a stream stops, macOS fades the traffic lights back in; wait
                    // (up to 1s) until two stills ~0.12s apart match.
                    let deadline = Date().addingTimeInterval(1)
                    while Date() < deadline {
                        try await Task.sleep(for: .milliseconds(120))
                        let next = try await SCScreenshotManager.captureImage(contentFilter: stillFilter, configuration: c)
                        let settled = Self.meanDifference(img, next) < 0.004
                        img = next
                        if settled { break }
                    }
                }
                try Stills.writeImage(img, to: dir.appendingPathComponent(name))
                if !titlebars.isEmpty { titlebars[titlebars.count - 1].end = t }
                // Where the window's corner sits in the video (0,0 for window captures).
                let ox = ((win.frame.minX - rect.minX) * scale).rounded(), oy = ((win.frame.minY - rect.minY) * scale).rounded()
                titlebars.append(.init(image: name, x: ox, y: oy, width: Double(img.width), height: Double(img.height),
                                       start: t, feather: (8 * scale).rounded(), matchTone: true))
            } catch {
                log("warning: --clean-titlebar still failed: \(ErrorInfo(error).summary)")
            }
        }
        await titlebarStill(at: nil)

        var current = try CaptureSegment(filter: filter, config: config, url: partURL(0), hevc: opts.hevc)
        try await current.start()
        let t0 = CACurrentMediaTime()
        let startedAt = Date().timeIntervalSince1970
        state.captureStartedAt = startedAt
        state.captureRect = .init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        state.windowRect = windowRect.map { .init(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
        state.windowID = target.appWindowID
        try state.update()
        var parts: [(segment: CaptureSegment, offset: Double)] = [(current, 0)]
        let tracker = opts.trackCursor ? CursorTracker(captureRect: rect, start: t0, shapes: opts.cursorShapes) : nil
        tracker?.start()
        log("Recording \(target.label) at \(width)×\(height) → \(opts.output.path)")
        log(opts.stopOn.map { "Stopping at marker \"\($0)\"" + (opts.tail > 0 ? String(format: " + %.1fs", opts.tail) : "") }
            ?? opts.duration.map { "Stopping after \(String(format: "%.1f", $0))s (Ctrl-C to stop early)" }
            ?? (opts.untilExit ? "Stopping when the app quits (Ctrl-C or `reel stop` to stop early)"
                               : "Press Ctrl-C or run `reel stop` to finish"))
        var snapper: Snapshotter?
        if opts.axSnapshots, let pid = targetPID {
            snapper = Snapshotter(window: .init(pid: pid, windowID: target.appWindowID, frame: windowRect ?? rect, title: target.title),
                                  state: state, log: log)
            snapper?.start()
        }

        // Control loop: stop requests, duration, markers, app exit, and stream stops (restart if we can).
        var endedBy = "stop"
        var timedOut: String?
        var failed: String?
        var stopAt: Double?
        var tick = 0
        var lastError: ErrorInfo?
        var endedEarly: ErrorInfo?
        var restarts = 0
        var gaps: [[Double]] = []
        // Test hook: REEL_SIMULATE_STOP="2,5" stops the stream at those seconds.
        var simulated = (ProcessInfo.processInfo.environment["REEL_SIMULATE_STOP"] ?? "")
            .split(separator: ",").compactMap { Double($0) }.sorted()
        while true {
            let elapsed = CACurrentMediaTime() - t0
            if let s = simulated.first, elapsed >= s, current.error == nil {
                simulated.removeFirst()
                await current.simulateStop()
            }
            if signals.requested { endedBy = "stop"; break }
            if signals.appExited {
                endedBy = "app-exit"
                if !opts.untilExit { endedEarly = appGone(signals, t0: t0) }
                break
            }
            if let d = opts.duration, elapsed >= d { endedBy = "duration"; break }
            tick += 1
            if tick % 5 == 0, let reason = failure(state) {
                failed = reason
                log(String(format: "Take failed at %.2fs: %@", elapsed, reason))
                endedBy = "failed"; break
            }
            if let label = opts.stopOn {
                if stopAt == nil, tick % 5 == 0,
                   let m = state.readMarks().first(where: { $0.label == label && $0.t >= 0 }) {
                    stopAt = m.t + opts.tail
                    log(String(format: "Marker \"%@\" at %.2fs; stopping at %.2fs", label, m.t, m.t + opts.tail))
                }
                if let stopAt, elapsed >= stopAt { endedBy = "stop-marker"; break }
                if stopAt == nil, let to = opts.markerTimeout, elapsed > to {
                    timedOut = String(format: "No \"%@\" marker within %.0fs of the start; recording stopped", label, to)
                    log(timedOut!)
                    endedBy = "timeout"; break
                }
            }
            if let err = current.error {
                let info = ErrorInfo(err)
                lastError = info
                let gapStart = elapsed
                log(String(format: "Capture stopped at %.2fs: %@", elapsed, info.summary))
                _ = await current.waitFinished(timeout: 5)     // keep what it wrote
                let remaining = opts.duration.map { $0 - (CACurrentMediaTime() - t0) } ?? .infinity
                let windowAlive = await Self.windowExists(target.windowID)
                if !windowAlive, let pid = targetPID {
                    // The window vanished: usually the app quit or crashed (a crash report can
                    // keep the process alive briefly), so wait a moment for it to go.
                    let deadline = Date().addingTimeInterval(3)
                    while Self.alive(pid) && !signals.appExited && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                    if !Self.alive(pid) || signals.appExited {
                        endedBy = "app-exit"
                        if !opts.untilExit { endedEarly = appGone(signals, t0: t0, fallback: elapsed) }
                        break
                    }
                }
                if signals.appExited || signals.requested || remaining < 0.5 {
                    endedBy = signals.appExited ? "app-exit" : signals.requested ? "stop" : "stream-error"
                    if signals.appExited && !opts.untilExit { endedEarly = appGone(signals, t0: t0, fallback: elapsed) }
                    break
                }
                guard restarts < opts.maxRestarts, windowAlive else {
                    endedEarly = windowAlive ? info
                        : ErrorInfo(domain: "reel", code: 2, description: String(format: "The window closed at %.2fs (the app is still running)", elapsed))
                    endedBy = windowAlive ? "stream-error" : "window-closed"
                    log(windowAlive ? "Giving up after \(restarts) restarts" : endedEarly!.description)
                    break
                }
                do {
                    await titlebarStill(at: (gapStart * 1000).rounded() / 1000)
                    let next = try CaptureSegment(filter: filter, config: config, url: partURL(parts.count), hevc: opts.hevc)
                    try await next.start()
                    let offset = CACurrentMediaTime() - t0
                    current = next
                    parts.append((next, offset))
                    restarts += 1
                    gaps.append([(gapStart * 1000).rounded() / 1000, (offset * 1000).rounded() / 1000])
                    log(String(format: "Capture restarted at %.2fs (restart %d of %d)", offset, restarts, opts.maxRestarts))
                } catch {
                    if let pid = targetPID, !Self.alive(pid) || signals.appExited {
                        endedBy = "app-exit"
                        if !opts.untilExit { endedEarly = appGone(signals, t0: t0, fallback: elapsed) }
                    } else {
                        endedEarly = ErrorInfo(error)
                        endedBy = "stream-error"
                        log("Could not restart capture: \(endedEarly!.summary)")
                    }
                    break
                }
                continue
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let elapsed = CACurrentMediaTime() - t0
        await current.stop()
        signals.cancel()
        tracker?.stop()
        marksWatcher?.stop()
        marksWatcher = nil
        let snapshots = snapper?.stop() ?? []
        let markers = state.collectMarks()
        let before = markers.filter { $0.t < 0 }
        if !before.isEmpty {
            log("\(before.count) marker(s) arrived before t=0 and are kept with negative times: "
                + before.map { String(format: "%@ %.2fs", $0.label, $0.t) }.joined(separator: ", "))
        }

        // --quit-after applies however the recording ended.
        let (quit, forced) = await quitIfAsked(targetPID, log: log)

        // Finalise: one segment is renamed into place; several are joined on the t=0 timeline.
        let written = parts.filter { FileManager.default.fileExists(atPath: $0.segment.url.path) }
        if written.isEmpty {
            throw ReelError.message("No video was written" + (lastError.map { ": \($0.summary)" } ?? ""))
        }
        if written.count == 1 && written[0].offset == 0 {
            try FileManager.default.moveItem(at: written[0].segment.url, to: opts.output)
        } else {
            log("Joining \(written.count) segments…")
            do {
                try await SegmentJoiner.join(written.map { ($0.segment.url, $0.offset) }, to: opts.output)
                for p in written { try? FileManager.default.removeItem(at: p.segment.url) }
            } catch {
                throw ReelError.message("Could not join segments (\(ErrorInfo(error).summary)). They are kept: "
                                        + written.map(\.segment.url.path).joined(separator: ", "))
            }
        }

        var eventsPath: String?
        if let tracker {
            var events = RecordingEvents(
                captureRect: .init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
                pointPixelScale: scale, samples: tracker.samples, cursorInVideo: opts.showsCursor)
            events.startedAt = startedAt
            events.markers = markers.isEmpty ? nil : markers
            events.shapes = tracker.shapes.isEmpty ? nil : tracker.shapes
            events.snapshots = snapshots.isEmpty ? nil : snapshots
            events.patches = titlebars.isEmpty ? nil : titlebars
            events.window = windowRect.map { .init(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
            try events.write(for: opts.output)
            eventsPath = RecordingEvents.sidecarURL(for: opts.output).path
        }
        // An app quitting under --until-exit is the expected way to finish.
        if opts.untilExit && signals.appExited { endedEarly = nil }
        if let endedEarly { log("Capture stopped early: \(endedEarly.summary)") }
        return RecordResult(output: opts.output.path, events: eventsPath, width: width, height: height,
                            duration: elapsed, app: opts.app, windowTitle: target.title, pid: targetPID,
                            windowID: target.windowID, markers: markers.isEmpty ? nil : markers,
                            stoppedEarly: endedEarly?.summary, stopError: lastError,
                            restarts: restarts, lostSeconds: (gaps.reduce(0) { $0 + $1[1] - $1[0] } * 1000).rounded() / 1000,
                            gaps: gaps.isEmpty ? nil : gaps, quit: quit, forcedQuit: forced,
                            endedBy: endedBy, timedOut: timedOut, failed: failed)
    }

    /// Why the take should end as failed, if it should: a `reel stop --fail` request
    /// or --fail-on's marker.
    private func failure(_ state: RecordingState) -> String? {
        if let reason = state.failRequest() { return reason }
        if let label = opts.failOn, state.readMarks().contains(where: { $0.label == label }) { return "marker \"\(label)\" arrived" }
        return nil
    }

    // MARK: - Shared phases (record and shot)

    /// Launches or finds the app and resolves the window to capture.
    private func prepareTarget(log: @escaping (String) -> Void) async throws -> (Target, Int32?, Bool) {
        try Permissions.requireScreenRecording()
        // A bare CLI has no window-server (CGS) connection; SCShareableContent.info(for:),
        // SCStream and CGEvent assert without one. NSApplication.shared establishes it.
        await MainActor.run { _ = NSApplication.shared }
        var targetPID = opts.pid
        var launchedNew = false
        if let pid = opts.pid, NSRunningApplication(processIdentifier: pid) == nil {
            throw ReelError.message("No running app with pid \(pid)")
        }
        if opts.pid == nil, let app = opts.app, opts.wantsLaunch {
            let (running, isNew) = try await launch(app: app, log: log)
            targetPID = running.processIdentifier
            launchedNew = isNew
            log("\(isNew ? "Launched" : "Activated") \(running.localizedName ?? app) (pid \(running.processIdentifier))")
        }
        let target = try await resolveTarget(pid: targetPID, launchedNew: launchedNew, log: log)
        return (target, targetPID ?? target.pid, launchedNew)
    }

    /// Publishes the recording state before capture, so `reel mark`, --marks-file
    /// and `reel act` (setup steps, start marker) work while reel waits.
    private func arm(target: Target, pid: Int32?, log: @escaping (String) -> Void) throws -> (RecordingState, MarksFileWatcher?) {
        var state = RecordingState(pid: getpid(), output: opts.output.path, startedAt: Date().timeIntervalSince1970)
        state.targetPID = pid
        state.windowID = target.appWindowID
        state.startOn = opts.startOn
        let r = SCShareableContent.info(for: target.filter).contentRect
        state.captureRect = .init(x: r.minX, y: r.minY, width: r.width, height: r.height)
        try state.write()
        let watcher = opts.marksFile.map { MarksFileWatcher(file: $0, state: state, since: began, log: log) }
        watcher?.start()
        return (state, watcher)
    }

    private func waitForStart(_ label: String, state: RecordingState, pid: Int32?, signals: StopSignals,
                              log: (String) -> Void) async throws {
        log("Waiting for marker \"\(label)\"" + (opts.markerTimeout.map { String(format: " (timeout %.0fs)", $0) } ?? "")
            + ": `reel mark \(label)`, --marks-file, or a `reel act` script with setup steps")
        let start = Date()
        while true {
            if state.readMarks().contains(where: { $0.label == label }) { return }
            if let reason = failure(state) { throw ReelError.message("The take failed before capture started (\(reason)); nothing was recorded") }
            if signals.requested { throw ReelError.message("Stopped before marker \"\(label)\" arrived; nothing was recorded") }
            if let pid, kill(pid, 0) != 0 { throw ReelError.message("The app quit before marker \"\(label)\" arrived") }
            if let to = opts.markerTimeout, Date().timeIntervalSince(start) > to {
                throw ReelError.message(String(format: "Timed out after %.0fs waiting for marker \"%@\"; nothing was recorded", to, label))
            }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    struct Geometry {
        var filter: SCContentFilter
        var sourceRect: CGRect?     // within the display, for --include-child-windows
        var rect: CGRect            // captured area, global points (top-left origin)
        var scale: Double
        var window: SCWindow?       // the app's window, as it is now
    }

    /// What to capture, measured now. --include-child-windows captures the display
    /// through a filter of the app's windows, cropped to the target window's frame,
    /// so popovers, menus and drag images appear in place.
    private func geometry(_ target: Target) async throws -> Geometry {
        let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let win = target.appWindowID.flatMap { id in content?.windows.first { $0.windowID == id } }
        if opts.includeChildWindows {
            guard let win, let app = win.owningApplication, let content else {
                throw ReelError.message("The window is no longer on screen")
            }
            let mid = CGPoint(x: win.frame.midX, y: win.frame.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(mid) }) ?? content.displays.first else {
                throw ReelError.message("No display found")
            }
            let f = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            let info = SCShareableContent.info(for: f)
            let d = display.frame
            let src = CGRect(x: win.frame.minX - d.minX, y: win.frame.minY - d.minY, width: win.frame.width, height: win.frame.height)
                .intersection(CGRect(origin: .zero, size: d.size))
            return Geometry(filter: f, sourceRect: src,
                            rect: CGRect(x: src.minX + d.minX, y: src.minY + d.minY, width: src.width, height: src.height),
                            scale: Double(info.pointPixelScale), window: win)
        }
        var f = (target.windowID != nil ? win.map { SCContentFilter(desktopIndependentWindow: $0) } : nil) ?? target.filter
        if opts.display, !target.appPIDs.isEmpty, let content,
           let display = content.displays.first(where: { $0.displayID == target.displayID }) {
            // The apps as they are now: an --also app may have started during setup.
            var apps = content.applications.filter { target.appPIDs.contains($0.processID) }
            let extra = try await alsoApps(required: true)
            apps += extra.apps.filter { m in !apps.contains { $0.processID == m.processID } }
            if !apps.isEmpty { f = SCContentFilter(display: display, including: apps, exceptingWindows: extra.desktop) }
        }
        let info = SCShareableContent.info(for: f)
        return Geometry(filter: f, sourceRect: nil, rect: info.contentRect, scale: Double(info.pointPixelScale), window: win)
    }

    /// A filter for the window as it is now (setup may have moved or resized it).
    private func freshFilter(_ target: Target) async -> SCContentFilter? {
        guard !opts.display, let id = target.windowID,
              let c = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let w = c.windows.first(where: { $0.windowID == id }) else { return nil }
        return SCContentFilter(desktopIndependentWindow: w)
    }

    /// Whether a process still exists (EPERM means it exists but isn't ours).
    static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// "The app exited or crashed at 2.00s", timed from the process-exit event.
    private func appGone(_ signals: StopSignals, t0: CFTimeInterval, fallback: Double? = nil) -> ErrorInfo {
        let at = signals.exitedAt.map { max(0, $0 - t0) } ?? fallback ?? (CACurrentMediaTime() - t0)
        let info = ErrorInfo(domain: "reel", code: 1, description: String(format: "The app exited or crashed at %.2fs", at))
        log?(info.description)
        return info
    }
    private var log: ((String) -> Void)?

    /// --quit-after / --force-quit: asks the app to quit, and reports success only once
    /// the process has really exited. Returns (quit, forced).
    private func quitIfAsked(_ pid: Int32?, force: Bool = false, log: (String) -> Void) async -> (Bool?, Bool?) {
        guard opts.quitAfter || opts.forceQuit || force, let pid, Self.alive(pid) else { return (nil, nil) }
        let app = NSRunningApplication(processIdentifier: pid)
        let name = app?.localizedName ?? "pid \(pid)"
        func waitGone(_ seconds: Double) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Self.alive(pid) && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            return !Self.alive(pid)
        }
        _ = app?.terminate()
        if await waitGone(5) { log("Quit \(name)"); return (true, nil) }
        guard opts.forceQuit else {
            log("warning: \(name) is still running (pid \(pid)) 5s after being asked to quit; a sheet or dialog is probably open. Use --force-quit to force it.")
            return (false, nil)
        }
        _ = app?.forceTerminate()
        if !(await waitGone(2)) { kill(pid, SIGKILL); _ = await waitGone(2) }
        let gone = !Self.alive(pid)
        log(gone ? "\(name) didn't quit (a sheet or dialog was probably open); force-quit it"
                 : "warning: could not force-quit \(name) (pid \(pid))")
        return (gone, true)
    }

    // MARK: - Still image (reel shot)

    public func shot(_ s: ShotOptions, log: @escaping (String) -> Void) async throws -> ShotResult {
        try FileManager.default.createDirectory(at: opts.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (target, targetPID, launchedNew) = try await prepareTarget(log: log)
        let signals = StopSignals(exitOf: nil)
        defer { signals.cancel() }
        var (state, watcher) = try arm(target: target, pid: targetPID, log: log)
        defer { RecordingState.remove() }
        defer { watcher?.stop() }
        let quitAtEnd = !s.keepOpen && (opts.quitAfter || opts.forceQuit || launchedNew)
        do {
            if let label = opts.startOn {
                try await waitForStart(label, state: state, pid: targetPID, signals: signals, log: log)
            }
            if s.settle > 0 { try await Task.sleep(for: .seconds(s.settle)) }
            let filter = await freshFilter(target) ?? target.filter
            let info = SCShareableContent.info(for: filter)
            let scale = Double(info.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = Int((info.contentRect.width * scale).rounded())
            config.height = Int((info.contentRect.height * scale).rounded())
            config.showsCursor = opts.showsCursor
            config.captureResolution = .best
            var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            state.captureStartedAt = Date().timeIntervalSince1970
            try? state.update()
            if let crop = s.crop { image = try Stills.crop(image, crop) }
            try Stills.writeImage(image, to: opts.output, maxWidth: s.width, quality: s.quality)
            let written = (CGImageSourceCreateWithURL(opts.output as CFURL, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }) ?? [:]
            log("Saved \(target.label) → \(opts.output.path)")
            let markers = state.collectMarks()
            watcher?.stop(); watcher = nil
            let (quit, forced) = quitAtEnd ? await quitIfAsked(targetPID, force: true, log: log) : (nil, nil)
            return ShotResult(output: opts.output.path,
                              width: written[kCGImagePropertyPixelWidth] as? Int ?? image.width,
                              height: written[kCGImagePropertyPixelHeight] as? Int ?? image.height,
                              pid: targetPID, windowID: target.windowID, windowTitle: target.title,
                              markers: markers.isEmpty ? nil : markers, quit: quit, forcedQuit: forced)
        } catch {
            if quitAtEnd { _ = await quitIfAsked(targetPID, force: true, log: log) }
            throw error
        }
    }

    /// Mean absolute RGB difference (0–1) between two same-size images.
    static func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        let w = min(a.width, b.width, 128), h = min(a.height, b.height, 64)
        guard w > 0, h > 0 else { return 1 }
        func pixels(_ img: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            buf.withUnsafeMutableBytes { p in
                let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return buf
        }
        let pa = pixels(a), pb = pixels(b)
        var sum = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            sum += abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2]))
        }
        return Double(sum) / Double(w * h * 3 * 255)
    }

    static func windowExists(_ id: UInt32?) async -> Bool {
        guard let id else { return true }   // display capture
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return true }
        return content.windows.contains { $0.windowID == id }
    }

    // MARK: - Target resolution

    /// Finds the app bundle on disk for a name, bundle id or path.
    private func appURL(_ app: String) throws -> URL {
        let expanded = (app as NSString).expandingTildeInPath
        if expanded.hasSuffix(".app") || expanded.contains("/") {
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { throw ReelError.message("No app at \(url.path)") }
            return url
        }
        if let running = runningApp(app), let url = running.bundleURL { return url }
        if app.contains("."), !app.contains(" "), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
            return url
        }
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", "~/Applications"].map { ($0 as NSString).expandingTildeInPath }
        for d in dirs {
            let url = URL(fileURLWithPath: d).appendingPathComponent("\(app).app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw ReelError.message("Can't find an app called \(app). Pass its bundle id or the path to the .app.")
    }

    /// Launches (or activates) the app and returns the process to record.
    /// A path means that exact bundle: a different copy with the same bundle id
    /// (e.g. /Applications vs an Xcode build) is never picked instead.
    private func launch(app: String, log: (String) -> Void) async throws -> (NSRunningApplication, Bool) {
        let url = try appURL(app)
        let path = url.resolvingSymlinksInPath().path
        let sameBundle = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.resolvingSymlinksInPath().path == path
        }
        let otherCopies = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier != nil && $0.bundleIdentifier == Bundle(url: url)?.bundleIdentifier
                && $0.bundleURL?.resolvingSymlinksInPath().path != path
        }

        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = !opts.background
        cfg.addsToRecentItems = false
        cfg.arguments = opts.arguments
        cfg.environment = opts.environment
        // Another copy of the same app is running: force a separate process of *this* bundle.
        cfg.createsNewApplicationInstance = opts.newInstance || (sameBundle.isEmpty && !otherCopies.isEmpty)
        if let existing = sameBundle.first, !cfg.createsNewApplicationInstance,
           !opts.environment.isEmpty || !opts.arguments.isEmpty {
            log("Note: \(existing.localizedName ?? app) is already running, so --env/--args are ignored. Use --new-instance to start a fresh process.")
        }
        let before = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))

        let running: NSRunningApplication
        do {
            if let target = opts.openURL {
                let u = target.contains("://") ? URL(string: target) : URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
                guard let u else { throw ReelError.message("Bad --open value \(target)") }
                running = try await NSWorkspace.shared.open([u], withApplicationAt: url, configuration: cfg)
            } else {
                running = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            }
        } catch let e as ReelError { throw e }
        catch { throw ReelError.message("Could not open \(url.path): \(error.localizedDescription)") }
        return (running, !before.contains(running.processIdentifier))
    }

    /// The resolved bundle path when `app` names a .app on disk.
    private func bundlePath(_ app: String) -> String? {
        let expanded = (app as NSString).expandingTildeInPath
        guard expanded.hasSuffix(".app") || expanded.contains("/") else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func runningApp(_ app: String) -> NSRunningApplication? {
        let needle = app.lowercased()
        let name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier?.lowercased() == needle
                || $0.localizedName?.lowercased() == needle
                || $0.localizedName?.lowercased() == name
                || $0.bundleURL?.path == app
        }
    }

    private func matches(_ w: SCWindow, app: String) -> Bool {
        guard let owner = w.owningApplication else { return false }
        let needle = app.lowercased()
        let appName = ((app as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        return owner.bundleIdentifier.lowercased() == needle
            || owner.applicationName.lowercased() == needle
            || owner.applicationName.lowercased() == appName
    }

    /// Running apps matching a name, bundle id or .app path (that exact bundle).
    private func scApps(_ content: SCShareableContent, matching app: String) -> [SCRunningApplication] {
        if let path = bundlePath(app) {
            let pids = Set(NSWorkspace.shared.runningApplications
                .filter { $0.bundleURL?.resolvingSymlinksInPath().path == path }.map(\.processIdentifier))
            return content.applications.filter { pids.contains($0.processID) }
        }
        let needle = app.lowercased()
        return content.applications.filter { $0.bundleIdentifier.lowercased() == needle || $0.applicationName.lowercased() == needle }
    }

    /// The --also apps, and their desktop-level windows (Finder's icons), which stay out
    /// of the picture. Looked up among all apps, not only those with a window on screen:
    /// Finder with no window open still counts, and shows up when one opens mid-take.
    private func alsoApps(required: Bool) async throws -> (apps: [SCRunningApplication], desktop: [SCWindow]) {
        guard !opts.also.isEmpty else { return ([], []) }
        let all = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        var apps: [SCRunningApplication] = []
        for name in opts.also {
            let more = scApps(all, matching: name)
            if more.isEmpty && required { throw ReelError.message("--also \(name): no running app by that name, bundle id or path") }
            apps += more.filter { m in !apps.contains { $0.processID == m.processID } }
        }
        let pids = Set(apps.map(\.processID))
        let desktop = all.windows.filter { $0.windowLayer < 0 && ($0.owningApplication.map { pids.contains($0.processID) } ?? false) }
        return (apps, desktop)
    }

    struct Target {
        var filter: SCContentFilter; var label: String; var title: String?; var pid: Int32?; var windowID: UInt32?
        /// Display recordings of an app: the display and the app's processes, so the
        /// filter can be rebuilt (with --also apps) when capture starts.
        var displayID: CGDirectDisplayID? = nil
        var appPIDs: [Int32] = []
        /// The app's window, also for display recordings with --app/--pid (for AX snapshots,
        /// --clean-titlebar, `reel act` and window-relative coordinates).
        var appWindowID: UInt32?
    }

    private func resolveTarget(pid: Int32?, launchedNew: Bool, log: (String) -> Void) async throws -> Target {
        let deadline = Date().addingTimeInterval(opts.windowTimeout)
        var announced = false
        var settling: UInt32?
        while true {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

            if opts.display {
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
                else { throw ReelError.message("No display found") }
                if pid != nil || opts.app != nil {
                    let main = pid.map { p in content.applications.filter { $0.processID == p } } ?? scApps(content, matching: opts.app!)
                    if !main.isEmpty {
                        // --also apps join when capture starts (geometry), once setup is done.
                        let apps = main
                        // The app's main window: by id/title if given, else its largest.
                        let ids = Set(main.map(\.processID))
                        var wins = content.windows.filter {
                            $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width > 50 && $0.frame.height > 50
                                && ($0.owningApplication.map { ids.contains($0.processID) } ?? false)
                        }
                        if let id = opts.windowID { wins = wins.filter { $0.windowID == id } }
                        if let t = opts.windowTitle?.lowercased() { wins = wins.filter { ($0.title ?? "").lowercased().contains(t) } }
                        let mainWin = wins.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                        let name = ([opts.app ?? "pid \(pid!)"] + opts.also).joined(separator: " + ")
                        return Target(filter: SCContentFilter(display: display, including: apps, exceptingWindows: []),
                                      label: "\(name) on display", title: mainWin?.title,
                                      pid: pid ?? mainWin?.owningApplication?.processID ?? main.first?.processID, windowID: nil,
                                      displayID: display.displayID, appPIDs: main.map(\.processID), appWindowID: mainWin?.windowID)
                    }
                } else {
                    return Target(filter: SCContentFilter(display: display, excludingWindows: []),
                                  label: "main display", title: nil, pid: nil, windowID: nil)
                }
            } else {
                if opts.app == nil && opts.windowID == nil && opts.windowTitle == nil && pid == nil {
                    throw ReelError.message("Specify --app, --pid, --window-id, --window-title or --display")
                }
                var candidates = content.windows.filter {
                    $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width > 50 && $0.frame.height > 50
                }
                if let id = opts.windowID { candidates = candidates.filter { $0.windowID == id } }
                // A known process wins over name matching, so other copies of the app are never picked.
                if let pid { candidates = candidates.filter { $0.owningApplication?.processID == pid } }
                else if let app = opts.app, let path = bundlePath(app) {
                    // A .app path means that exact bundle, never another copy with the same id.
                    let pids = Set(NSWorkspace.shared.runningApplications
                        .filter { $0.bundleURL?.resolvingSymlinksInPath().path == path }.map(\.processIdentifier))
                    candidates = candidates.filter { $0.owningApplication.map { pids.contains($0.processID) } ?? false }
                }
                else if let app = opts.app { candidates = candidates.filter { matches($0, app: app) } }
                if let t = opts.windowTitle?.lowercased() {
                    candidates = candidates.filter { ($0.title ?? "").lowercased().contains(t) }
                }
                // A process reel just started: its first window (front-most). Otherwise the largest.
                let pick = launchedNew ? candidates.first
                    : candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
                if let w = pick {
                    // Let a newly appeared window finish opening before capturing it.
                    if launchedNew && settling != w.windowID {
                        settling = w.windowID
                        try await Task.sleep(for: .milliseconds(700))
                        continue
                    }
                    let name = w.owningApplication?.applicationName ?? "window"
                    return Target(filter: SCContentFilter(desktopIndependentWindow: w), label: "\(name) “\(w.title ?? "")”",
                                  title: w.title, pid: w.owningApplication?.processID, windowID: w.windowID, appWindowID: w.windowID)
                }
            }
            if Date() > deadline {
                throw ReelError.message("No matching window found within \(Int(opts.windowTimeout))s. Run `reel windows` to see what is capturable.")
            }
            if !announced { log("Waiting for window…"); announced = true }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

}

/// Ctrl-C, SIGTERM (`reel stop`) and, with --until-exit, the app quitting.
final class StopSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var _requested = false, _appExited = false
    private var _exitedAt: CFTimeInterval?
    private var sources: [DispatchSourceProtocol] = []
    var requested: Bool { lock.withLock { _requested } }
    var appExited: Bool { lock.withLock { _appExited } }
    /// CACurrentMediaTime() when the app's process exited.
    var exitedAt: CFTimeInterval? { lock.withLock { _exitedAt } }

    init(exitOf pid: Int32?) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            s.setEventHandler { [weak self] in self?.lock.withLock { self?._requested = true } }
            s.resume()
            sources.append(s)
        }
        if let pid {
            let p = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
            p.setEventHandler { [weak self] in
                let now = CACurrentMediaTime()
                self?.lock.withLock { self?._appExited = true; self?._exitedAt = now }
            }
            p.resume()
            sources.append(p)
            if !Recorder.alive(pid) { _appExited = true; _exitedAt = CACurrentMediaTime() }
        }
    }

    func cancel() { for s in sources { s.cancel() } }
}

/// Watches a file a sandboxed harness can write to: lines of "<label> <unix time>".
final class MarksFileWatcher: @unchecked Sendable {
    private let file: URL
    private let state: RecordingState
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "reel.marks")
    private var timer: DispatchSourceTimer?
    private var consumed = 0
    private let since: Double

    /// The whole file is read, and lines stamped before `since` (when this take began)
    /// are skipped: a reused file's old lines can't start or stop the new take, while a
    /// marker the app writes as soon as it launches still counts.
    init(file: URL, state: RecordingState, since: Double, log: @escaping (String) -> Void) {
        self.file = file; self.state = state; self.since = since; self.log = log
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { queue.sync { timer?.cancel(); timer = nil; poll() } }

    private func poll() {
        guard let data = try? Data(contentsOf: file) else { return }
        if data.count < consumed { consumed = 0 }   // the file was truncated or replaced
        guard data.count > consumed else { return }
        let chunk = data[consumed...]
        // Only complete lines; a half-written last line waits for the next poll.
        guard let lastNL = chunk.lastIndex(of: 0x0A) else { return }
        let text = String(decoding: data[consumed...lastNL], as: UTF8.self)
        consumed = lastNL + 1
        var stale = 0
        for line in text.split(separator: "\n") {
            do {
                guard let (label, unix) = try MarkLine.parse(String(line)) else { continue }
                if unix < since { stale += 1; continue }
                try state.append(.init(label: label, t: ((unix - state.startedAt) * 1000).rounded() / 1000))
            } catch { log("warning: marks file: \(error.localizedDescription)") }
        }
        if stale > 0 { log("Marks file: ignored \(stale) line\(stale == 1 ? "" : "s") stamped before this take began") }
    }
}

/// "<label> <unix time>" (label may contain spaces; # comments and blank lines skipped).
public enum MarkLine {
    public static func parse(_ line: String) throws -> (String, Double)? {
        let s = line.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.hasPrefix("#") { return nil }
        guard let sp = s.lastIndex(where: { $0 == " " || $0 == "\t" }),
              let t = Double(s[s.index(after: sp)...]) else {
            throw ReelError.message("expected \"<label> <unix time>\", got \"\(s)\"")
        }
        let label = s[..<sp].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { throw ReelError.message("missing label in \"\(s)\"") }
        return (label, t)
    }
}

/// Polls cursor position and button state. Reading this state needs no
/// Accessibility or Input Monitoring permission (unlike an event tap).
final class CursorTracker: @unchecked Sendable {
    private let rect: CGRect
    private let t0: CFTimeInterval
    private let queue = DispatchQueue(label: "reel.cursor")
    private var timer: DispatchSourceTimer?
    private(set) var samples: [RecordingEvents.CursorSample] = []
    private(set) var shapes: [RecordingEvents.ShapeChange] = []

    private let trackShapes: Bool
    private var shapeTimer: DispatchSourceTimer?

    init(captureRect: CGRect, start: CFTimeInterval, shapes: Bool = true) {
        self.rect = captureRect
        self.t0 = start
        self.trackShapes = shapes
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(8))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
        guard trackShapes else { return }
        // NSCursor is AppKit: query it on the main thread only, ~10× a second.
        let s = DispatchSource.makeTimerSource(queue: .main)
        s.schedule(deadline: .now(), repeating: .milliseconds(100))
        s.setEventHandler { [weak self] in autoreleasepool { self?.sampleShape() } }
        s.resume()
        shapeTimer = s
    }

    func stop() {
        shapeTimer?.cancel(); shapeTimer = nil
        queue.sync { timer?.cancel(); timer = nil }
    }

    private lazy var signatures: [(CursorShape, CGPoint, CGSize)] = CursorShape.allCases.map {
        let c = CursorSprite.nsCursor($0); return ($0, c.hotSpot, c.image.size)
    }

    private func sampleShape() {
        guard let c = NSCursor.currentSystem else { return }
        let t = ((CACurrentMediaTime() - t0) * 10000).rounded() / 10000
        let hs = c.hotSpot, size = c.image.size
        guard let match = signatures.first(where: { $0.1 == hs && $0.2 == size })?.0 else { return }
        queue.async {
            if match != (self.shapes.last?.shape ?? .arrow) { self.shapes.append(.init(t: t, shape: match)) }
        }
    }

    private func sample() {
        guard let loc = CGEvent(source: nil)?.location else { return }  // global, top-left origin
        // Either button: a right-click gets a click ring and halo like any other.
        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right)
        let r = { (v: Double) in (v * 10000).rounded() / 10000 }
        let t = r(CACurrentMediaTime() - t0)
        samples.append(.init(t: t,
                             x: r((loc.x - rect.minX) / rect.width),
                             y: r((loc.y - rect.minY) / rect.height),
                             down: down))
    }
}

/// Shared between a running `reel record` and `reel stop` / `reel mark`.
public struct RecordingState: Codable, Sendable {
    public var pid: Int32
    public var output: String
    /// Unix time of recording t=0.
    public var startedAt: Double
    /// The recorded app and window, so `reel act` can find them.
    public var targetPID: Int32?
    public var windowID: UInt32?
    public var captureRect: RecordingEvents.Rect?
    /// The app's window (global points); differs from captureRect for display recordings.
    public var windowRect: RecordingEvents.Rect?
    /// With --start-on: the marker capture waits for, and the Unix time capture began.
    /// `startedAt` is then the time reel armed; marks are stored relative to it and
    /// shifted onto the capture clock (earlier ones become negative).
    public var startOn: String?
    public var captureStartedAt: Double?

    /// Unix time of the capture's t=0 (nil until capture starts: while waiting for the
    /// start marker, and while reel is still setting up after arming).
    public var t0: Double? { captureStartedAt }
    var shift: Double { (captureStartedAt ?? startedAt) - startedAt }

    public init(pid: Int32, output: String, startedAt: Double) {
        self.pid = pid; self.output = output; self.startedAt = startedAt
    }

    static var url: URL { FileManager.default.temporaryDirectory.appendingPathComponent("reel-record.json") }
    var marksURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("reel-marks-\(pid).jsonl") }

    var failURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("reel-fail-\(pid).txt") }

    func write() throws {
        try? FileManager.default.removeItem(at: marksURL)
        try? FileManager.default.removeItem(at: failURL)
        try update()
    }

    /// Asks the running `reel record` to end the take now and report it as failed.
    public static func failRunning(_ reason: String) throws -> Int32 {
        let s = try current()
        try Data((reason.isEmpty ? "failed" : reason).utf8).write(to: s.failURL, options: .atomic)
        return s.pid
    }

    func failRequest() -> String? {
        guard let text = try? String(contentsOf: failURL, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Rewrites the state, keeping markers.
    func update() throws { try JSONEncoder().encode(self).write(to: Self.url, options: .atomic) }
    static func remove() { try? FileManager.default.removeItem(at: url) }

    /// The recording in progress, if its process is still alive.
    public static func current() throws -> RecordingState {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(RecordingState.self, from: data)
        else { throw ReelError.message("No recording in progress") }
        guard kill(s.pid, 0) == 0 else {
            remove()
            throw ReelError.message("No recording in progress (process \(s.pid) has exited)")
        }
        return s
    }

    /// Signals a running `reel record` to finish cleanly.
    public static func stopRunning() throws -> Int32 {
        let s = try current()
        guard kill(s.pid, SIGINT) == 0 else { throw ReelError.message("Could not signal process \(s.pid)") }
        return s.pid
    }

    /// Appends a marker at the current moment of the running recording.
    public func mark(_ label: String, offset: Double = 0) throws -> RecordingEvents.Marker {
        let raw = Date().timeIntervalSince1970 - startedAt + offset
        try append(.init(label: label, t: (raw * 1000).rounded() / 1000))
        return .init(label: label, t: ((raw - shift) * 1000).rounded() / 1000)
    }

    /// Appends a marker with an explicit time (e.g. from a marks file).
    public func append(_ m: RecordingEvents.Marker) throws {
        var line = try JSONEncoder().encode(m)
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: marksURL) {
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } else {
            try line.write(to: marksURL)
        }
    }

    /// Markers so far on the capture clock (leaves them in place).
    public func readMarks() -> [RecordingEvents.Marker] {
        guard let text = try? String(contentsOf: marksURL, encoding: .utf8) else { return [] }
        let d = shift
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(RecordingEvents.Marker.self, from: Data($0.utf8)) }
            .map { .init(label: $0.label, t: (($0.t - d) * 1000).rounded() / 1000) }
            .sorted { $0.t < $1.t }
    }

    func collectMarks() -> [RecordingEvents.Marker] {
        defer { try? FileManager.default.removeItem(at: marksURL); try? FileManager.default.removeItem(at: failURL) }
        return readMarks()
    }
}

/// Takes accessibility snapshots of the recorded window at the start and
/// whenever a new `reel mark` arrives.
final class Snapshotter: @unchecked Sendable {
    private let window: Accessibility.WindowRef
    private let state: RecordingState
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "reel.ax")
    private var timer: DispatchSourceTimer?
    private var seen = 0
    private var snapshots: [ElementSnapshot] = []

    init(window: Accessibility.WindowRef, state: RecordingState, log: @escaping (String) -> Void) {
        self.window = window; self.state = state; self.log = log
    }

    func start() {
        seen = state.readMarks().count   // markers from before t=0 don't get snapshots
        queue.async { self.snap(t: 0, marker: nil) }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.15, repeating: .milliseconds(120))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func poll() {
        let marks = state.readMarks()
        guard marks.count > seen else { return }
        for m in marks[seen...] { snap(t: m.t, marker: m.label) }
        seen = marks.count
    }

    private func snap(t: Double, marker: String?) {
        do {
            // Open menus too, so a drawn script can target a menu item at a marker.
            let els = try Accessibility.elements(in: window) + Accessibility.menuElements(pid: window.pid, relativeTo: window.frame)
            snapshots.append(.init(t: t, marker: marker, elements: els))
        } catch {
            log("warning: UI snapshot\(marker.map { " at \($0)" } ?? "") failed: \(error.localizedDescription)")
        }
    }

    /// Stops polling, takes snapshots for any last markers, and returns them all.
    func stop() -> [ElementSnapshot] {
        queue.sync {
            timer?.cancel(); timer = nil
            poll()
            return snapshots.sorted { $0.t < $1.t }
        }
    }
}
