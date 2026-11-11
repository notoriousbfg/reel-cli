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
    /// Set when macOS ended the capture before it was asked to (e.g. the window closed).
    public var stoppedEarly: String?
    /// Set when --quit-after asked the app to quit.
    public var quit: Bool?
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

public final class Recorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, @unchecked Sendable {
    private let opts: RecordOptions
    private var started: CheckedContinuation<Void, Error>?
    private var finished: CheckedContinuation<Void, Error>?
    private var streamError: Error?
    private var stopNow: (() -> Void)?

    public init(options: RecordOptions) { self.opts = options }

    public func run(log: @escaping (String) -> Void) async throws -> RecordResult {
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

        if opts.axSnapshots {
            try Accessibility.require("--ax-snapshots")
            if opts.display { throw ReelError.message("--ax-snapshots records one window; drop --display") }
        }
        let target = try await resolveTarget(pid: targetPID, launchedNew: launchedNew, log: log)
        let filter = target.filter
        targetPID = targetPID ?? target.pid
        let info = SCShareableContent.info(for: filter)
        let scale = Double(info.pointPixelScale)
        let rect = info.contentRect
        let width = Int((rect.width * scale).rounded()) & ~1
        let height = Int((rect.height * scale).rounded()) & ~1

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(opts.fps))
        config.showsCursor = opts.showsCursor
        config.captureResolution = .best
        config.queueDepth = 6
        config.capturesAudio = false

        let recConfig = SCRecordingOutputConfiguration()
        try? FileManager.default.removeItem(at: opts.output)
        recConfig.outputURL = opts.output
        recConfig.outputFileType = opts.output.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        recConfig.videoCodecType = opts.hevc ? .hevc : .h264
        let recording = SCRecordingOutput(configuration: recConfig, delegate: self)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(recording)

        if opts.countdown > 0 {
            var remaining = Int(opts.countdown.rounded(.up))
            while remaining > 0 {
                log("Recording in \(remaining)…")
                try await Task.sleep(for: .seconds(1))
                remaining -= 1
            }
        }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            started = c
            stream.startCapture { [weak self] err in
                if let err { self?.resumeStart(err) }
            }
        }
        let t0 = CACurrentMediaTime()
        let startedAt = Date().timeIntervalSince1970
        let tracker = opts.trackCursor ? CursorTracker(captureRect: rect, start: t0) : nil
        tracker?.start()
        log("Recording \(target.label) at \(width)×\(height) → \(opts.output.path)")
        log(opts.duration.map { "Stopping after \(String(format: "%.1f", $0))s (Ctrl-C to stop early)" }
            ?? (opts.untilExit ? "Stopping when the app quits (Ctrl-C or `reel stop` to stop early)"
                               : "Press Ctrl-C or run `reel stop` to finish"))

        var state = RecordingState(pid: getpid(), output: opts.output.path, startedAt: startedAt)
        state.targetPID = targetPID
        state.windowID = target.windowID
        state.captureRect = .init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        try state.write()
        defer { RecordingState.remove() }
        var snapper: Snapshotter?
        if opts.axSnapshots, let pid = targetPID {
            snapper = Snapshotter(window: .init(pid: pid, windowID: target.windowID, frame: rect, title: target.title),
                                  state: state, log: log)
            snapper?.start()
        }
        await waitForStop(duration: opts.duration, exitOf: opts.untilExit ? targetPID : nil)
        let elapsed = CACurrentMediaTime() - t0
        tracker?.stop()
        let snapshots = snapper?.stop() ?? []
        let markers = state.collectMarks()

        if let streamError {
            // macOS already stopped the stream and finalised the file; stopCapture would fail.
            if !(opts.untilExit && appExited) {
                log("Capture stopped early: \(streamError.localizedDescription)")
            }
            if !FileManager.default.fileExists(atPath: opts.output.path) { throw streamError }
        } else {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                finished = c
                stream.stopCapture { [weak self] err in
                    if let err { self?.resumeFinish(err) }
                }
            }
        }

        var quit: Bool?
        if opts.quitAfter, let pid = targetPID, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            let name = app.localizedName ?? "the app"
            var ok = app.terminate()
            if ok {
                // terminate() only asks; wait for the process to go so the result is true to its word.
                let deadline = Date().addingTimeInterval(5)
                while !app.isTerminated && kill(pid, 0) == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
                ok = app.isTerminated || kill(pid, 0) != 0
            }
            quit = ok
            log(ok ? "Quit \(name)" : "\(name) did not quit (it may be showing a dialog)")
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
            try events.write(for: opts.output)
            eventsPath = RecordingEvents.sidecarURL(for: opts.output).path
        }
        // An app quitting under --until-exit is the expected way to finish.
        let early = (opts.untilExit && appExited) ? nil : streamError?.localizedDescription
        return RecordResult(output: opts.output.path, events: eventsPath, width: width, height: height,
                            duration: elapsed, app: opts.app, windowTitle: target.title, pid: targetPID,
                            windowID: target.windowID, markers: markers.isEmpty ? nil : markers,
                            stoppedEarly: early, quit: quit)
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

    struct Target { var filter: SCContentFilter; var label: String; var title: String?; var pid: Int32?; var windowID: UInt32? }

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
                    let apps = content.applications.filter { a in
                        if let pid { return a.processID == pid }
                        let app = opts.app!.lowercased()
                        return a.bundleIdentifier.lowercased() == app || a.applicationName.lowercased() == app
                    }
                    if !apps.isEmpty {
                        return Target(filter: SCContentFilter(display: display, including: apps, exceptingWindows: []),
                                      label: "\(opts.app ?? "pid \(pid!)") on display", title: nil, pid: pid, windowID: nil)
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
                                  title: w.title, pid: w.owningApplication?.processID, windowID: w.windowID)
                }
            }
            if Date() > deadline {
                throw ReelError.message("No matching window found within \(Int(opts.windowTimeout))s. Run `reel windows` to see what is capturable.")
            }
            if !announced { log("Waiting for window…"); announced = true }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    // MARK: - Stop handling

    private var appExited = false

    private func waitForStop(duration: Double?, exitOf pid: Int32?) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            let fire = { if once.claim() { c.resume() } }
            stopNow = fire
            var sources: [DispatchSourceProtocol] = []
            for sig in [SIGINT, SIGTERM] {
                signal(sig, SIG_IGN)
                let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                s.setEventHandler { fire() }
                s.resume()
                sources.append(s)
            }
            if let pid {
                let p = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
                p.setEventHandler { [weak self] in self?.appExited = true; fire() }
                p.resume()
                sources.append(p)
                if kill(pid, 0) != 0 { appExited = true; fire() }
            }
            if let duration {
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { fire() }
            }
            // Keep sources alive until the process exits.
            SignalHolder.shared.sources = sources
        }
    }

    private func resumeStart(_ error: Error?) {
        guard let c = started else { return }
        started = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    private func resumeFinish(_ error: Error?) {
        guard let c = finished else { return }
        finished = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    // MARK: - Delegates

    public func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) { resumeStart(nil) }
    public func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { resumeFinish(nil) }
    public func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        streamError = error
        resumeStart(error)
        resumeFinish(error)
    }
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamError = error
        resumeStart(error)
        resumeFinish(error)
        stopNow?()
    }
}

private final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

private final class SignalHolder: @unchecked Sendable {
    static let shared = SignalHolder()
    var sources: [DispatchSourceProtocol] = []
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
    private var tick = 0
    /// (hotspot, size) of each system cursor, used to recognise the cursor on screen.
    private let signatures: [(CursorShape, CGPoint, CGSize)] = CursorShape.allCases.map {
        let c = CursorSprite.nsCursor($0); return ($0, c.hotSpot, c.image.size)
    }

    init(captureRect: CGRect, start: CFTimeInterval) {
        self.rect = captureRect
        self.t0 = start
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(8))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    func stop() { queue.sync { timer?.cancel(); timer = nil } }

    private func sample() {
        guard let loc = CGEvent(source: nil)?.location else { return }  // global, top-left origin
        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let r = { (v: Double) in (v * 10000).rounded() / 10000 }
        let t = r(CACurrentMediaTime() - t0)
        tick += 1
        // The shape on screen (I-beam over text, hand over links), checked ~20× a second.
        if tick % 6 == 1, let c = NSCursor.currentSystem {
            let hs = c.hotSpot, size = c.image.size
            if let match = signatures.first(where: { $0.1 == hs && $0.2 == size })?.0,
               match != (shapes.last?.shape ?? .arrow) || (shapes.isEmpty && match != .arrow) {
                shapes.append(.init(t: t, shape: match))
            }
        }
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

    public init(pid: Int32, output: String, startedAt: Double) {
        self.pid = pid; self.output = output; self.startedAt = startedAt
    }

    static var url: URL { FileManager.default.temporaryDirectory.appendingPathComponent("reel-record.json") }
    var marksURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("reel-marks-\(pid).jsonl") }

    func write() throws {
        try? FileManager.default.removeItem(at: marksURL)
        try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
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
        let m = RecordingEvents.Marker(label: label, t: ((Date().timeIntervalSince1970 - startedAt + offset) * 1000).rounded() / 1000)
        var line = try JSONEncoder().encode(m)
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: marksURL) {
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } else {
            try line.write(to: marksURL)
        }
        return m
    }

    /// Markers so far (leaves them in place).
    public func readMarks() -> [RecordingEvents.Marker] {
        guard let text = try? String(contentsOf: marksURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(RecordingEvents.Marker.self, from: Data($0.utf8)) }
            .sorted { $0.t < $1.t }
    }

    func collectMarks() -> [RecordingEvents.Marker] {
        defer { try? FileManager.default.removeItem(at: marksURL) }
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
            let els = try Accessibility.elements(in: window)
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
