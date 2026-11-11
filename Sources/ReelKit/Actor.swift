import AppKit
import ApplicationServices
import Foundation

/// Performs a cursor script with real mouse and keyboard events (`reel act`).
/// Optional: needs Accessibility. Takes over the pointer while it runs and
/// aborts the moment the user moves the mouse or presses Esc.
public struct ActOptions: Sendable {
    public var script: CursorScript
    public var pid: Int32?
    public var windowID: UInt32?
    /// Start the script clock now instead of at the running recording's t=0.
    public var now = false
    /// Characters per second for "type" steps.
    public var typeRate = 14.0
    /// How far (points) the pointer may drift from where reel put it before aborting.
    public var tolerance = 6.0
    public init(script: CursorScript) { self.script = script }
}

public struct ActResult: Codable, Sendable {
    public var steps: Int
    public var completed: Int
    public var aborted: String?
    public var duration: Double
    public var markers: [RecordingEvents.Marker]
    public var window: RecordingEvents.Rect
    public var pid: Int32
}

public enum Actor {
    struct Aborted: Error { var reason: String }

    public static func perform(_ o: ActOptions, log: @escaping (String) -> Void) async throws -> ActResult {
        try Accessibility.require("reel act")
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
            throw ReelError.message("reel act can't post input events. Allow your terminal under Accessibility, then restart it.")
        }
        await AppKitSession.ensure()

        // Target window and clock: the running recording unless told otherwise.
        var state = try? RecordingState.current()
        let window: Accessibility.WindowRef
        if o.pid != nil || o.windowID != nil {
            window = try Accessibility.window(pid: o.pid, windowID: o.windowID)
        } else if let state, let id = state.windowID {
            window = try Accessibility.window(pid: state.targetPID, windowID: id)
        } else {
            throw ReelError.message("No target: start `reel record` first, or pass --pid / --window-id")
        }
        // Setup steps run first on act's own clock; the main steps then follow the
        // recording's clock (or a fresh one with --now / no recording).
        var clockStart = Date().timeIntervalSince1970
        let setupSteps = try CursorScript(steps: o.script.setup ?? []).timeline(markers: [])
        var steps = try o.script.timeline(markers: o.script.markers(base: state?.readMarks() ?? []))
        let wf = window.frame
        func screen(_ p: (Double, Double)) -> CGPoint { CGPoint(x: wf.minX + p.0 * wf.width, y: wf.minY + p.1 * wf.height) }
        func now() -> Double { Date().timeIntervalSince1970 - clockStart }

        if o.script.setup == nil, let st = state, !o.now {
            if st.t0 == nil {
                // The recording is waiting for its start marker: wait for capture, then
                // follow its clock (the marker comes from the harness or `reel mark`).
                if let label = st.startOn { log("Waiting for the recording to start (marker \"\(label)\")…") }
                while true {
                    guard let cur = try? RecordingState.current() else {
                        throw ReelError.message("The recording ended before capture started")
                    }
                    if let t0 = cur.captureStartedAt { clockStart = t0; state = cur; break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                steps = try o.script.timeline(markers: o.script.markers(base: state?.readMarks() ?? []))
            } else if let t0 = st.t0 { clockStart = t0 }
            if let first = steps.first, first.t < now() - 0.05 {
                throw ReelError.message(String(format: "The recording is already at %.2fs but the script starts at %.2fs. Use --now to start the script clock now, or put the early steps under \"setup\".", now(), first.t))
            }
        }

        // Point targets: 0–1 of the recorded frame (the window for window recordings), or of
        // the app window with "coordinates": "window". Elements are always window-relative.
        let cr = (o.script.windowCoordinates || o.pid != nil || o.windowID != nil) ? nil : state?.captureRect
        let capture = cr.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } ?? wf
        func screenPoint(_ target: CursorScript.Target, _ t: Double, _ what: String) throws -> CGPoint {
            let p = try resolver.point(target, at: t, what)
            if case .point = target {
                return CGPoint(x: capture.minX + p.0 * capture.width, y: capture.minY + p.1 * capture.height)
            }
            return screen(p)
        }
        let resolver = CursorScript.Resolver(width: capture.width, height: capture.height, scale: 1, element: { ref, _ in
            let found = Accessibility.find(try Accessibility.elements(in: window), label: ref.label, role: ref.role)
            guard found.indices.contains(ref.index ?? 0) else { throw ReelError.message("no element \"\(ref.label)\" on screen") }
            return CursorScript.Resolver.anchor(ref, in: found[ref.index ?? 0].frame)
        })

        // Input state, so an abort can release anything held.
        var pos = CGEvent(source: nil)?.location ?? screen((0.5, 0.5))
        var buttonDown = false
        var marks: [RecordingEvents.Marker] = []
        var completed = 0
        let started = now()

        func checkUser() throws {
            if CGEventSource.keyState(.combinedSessionState, key: 53) { throw Aborted(reason: "Esc pressed") }
            if let actual = CGEvent(source: nil)?.location, hypot(actual.x - pos.x, actual.y - pos.y) > o.tolerance {
                throw Aborted(reason: String(format: "the mouse moved (%.0f,%.0f → %.0f,%.0f)", pos.x, pos.y, actual.x, actual.y))
            }
        }
        func wait(until t: Double) async throws {
            while now() < t {
                try checkUser()
                try await Task.sleep(for: .milliseconds(min(15, max(1, Int((t - now()) * 1000)))))
            }
        }
        func post(_ type: CGEventType, at p: CGPoint, clickState: Int64 = 1) {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            if type == .leftMouseDown || type == .leftMouseUp { e?.setIntegerValueField(.mouseEventClickState, value: clickState) }
            e?.post(tap: .cghidEventTap)
            pos = p
        }
        /// Human-paced glide: eased, with a slight arc, arriving at `t1`.
        func glide(to target: CGPoint, from t0: Double, to t1: Double, linear: Bool = false) async throws {
            try checkUser()
            let a = pos
            let d = hypot(target.x - a.x, target.y - a.y)
            guard d > 0.5 else { return }
            let start = max(now(), t0)
            let dur = max(0.05, t1 - start)
            let bend = linear ? 0 : min(40, d * 0.06)   // perpendicular bow, points
            let nx = -(target.y - a.y) / d, ny = (target.x - a.x) / d
            while true {
                try checkUser()
                let u = min(1, (now() - start) / dur)
                let e = linear ? u : (u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2)
                let arc = sin(.pi * e) * bend
                let p = CGPoint(x: a.x + (target.x - a.x) * e + nx * arc, y: a.y + (target.y - a.y) * e + ny * arc)
                post(buttonDown ? .leftMouseDragged : .mouseMoved, at: p)
                if u >= 1 { break }
                try await Task.sleep(for: .milliseconds(8))
            }
        }
        func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }

        if let app = NSRunningApplication(processIdentifier: window.pid) { app.activate() }
        log(String(format: "Acting on %@ (pid %d): %@%d steps. Move the mouse or press Esc to abort.",
                   window.title ?? "window", window.pid,
                   setupSteps.isEmpty ? "" : "\(setupSteps.count) setup + ", steps.count))

        func run(_ list: [(t: Double, index: Int, step: CursorScript.Step)], prefix: String) async throws {
            for (t, i, s) in list {
                let label = "\(prefix) \(i + 1)"
                let lead = s.move != nil ? (s.over ?? CursorScript.defaultMove)
                    : (s.click.map { if case .at = $0 { return s.over ?? 0.35 } else { return 0 } } ?? 0)
                try await wait(until: t - lead)

                if let m = s.move {
                    let p = try screenPoint(m, t, "\(label) move")
                    try await glide(to: p, from: t - (s.over ?? CursorScript.defaultMove), to: t)
                }
                if let c = s.click {
                    if case .at(let target) = c {
                        let p = try screenPoint(target, t, "\(label) click")
                        try await glide(to: p, from: t - (s.over ?? 0.35), to: t)
                    }
                    try await wait(until: t)
                    for k in 1...max(1, s.count ?? 1) {
                        try checkUser()
                        post(.leftMouseDown, at: pos, clickState: Int64(k)); buttonDown = true
                        try await Task.sleep(for: .milliseconds(70))
                        post(.leftMouseUp, at: pos, clickState: Int64(k)); buttonDown = false
                        if k < (s.count ?? 1) { try await Task.sleep(for: .milliseconds(90)) }
                    }
                }
                if let d = s.drag {
                    let pts = try d.map { try screenPoint($0, t, "\(label) drag") }
                    guard pts.count >= 2 else { throw ReelError.message("\(label) drag needs at least two points") }
                    try await glide(to: pts[0], from: t - 0.35, to: t)
                    try await wait(until: t)
                    post(.leftMouseDown, at: pts[0]); buttonDown = true
                    let leg = (s.over ?? 0.8) / Double(pts.count - 1)
                    for k in 1..<pts.count {
                        let a = t + leg * Double(k - 1)
                        try await glide(to: pts[k], from: a, to: a + leg, linear: true)
                    }
                    post(.leftMouseUp, at: pos); buttonDown = false
                }
                if s.down == true { try await wait(until: t); post(.leftMouseDown, at: pos); buttonDown = true }
                if s.up == true { try await wait(until: t); post(.leftMouseUp, at: pos); buttonDown = false }
                if let sc = s.scroll {
                    try await wait(until: t)
                    let over = s.over ?? 0.4, n = max(1, Int(over * 60))
                    for _ in 0..<n {
                        try checkUser()
                        let dx = Int32((sc.count > 0 ? sc[0] : 0) / Double(n)), dy = Int32((sc.count > 1 ? sc[1] : 0) / Double(n))
                        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0)?
                            .post(tap: .cghidEventTap)
                        try await Task.sleep(for: .milliseconds(Int(1000 * over / Double(n))))
                    }
                }
                if let text = s.type {
                    try await wait(until: t)
                    for ch in text {
                        try checkUser()
                        let utf16 = Array(String(ch).utf16)
                        for down in [true, false] {
                            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                            e?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                            e?.post(tap: .cghidEventTap)
                        }
                        // Human-ish rhythm: ±35% around the rate, a little longer after spaces.
                        let base = 1 / o.typeRate * Double.random(in: 0.65...1.35) * (ch == " " ? 1.4 : 1)
                        try await Task.sleep(for: .milliseconds(Int(base * 1000)))
                    }
                }
                if let combo = s.key {
                    try await wait(until: t)
                    let (code, flags) = try Keys.parse(combo)
                    try checkUser()
                    key(code, down: true, flags: flags)
                    try await Task.sleep(for: .milliseconds(40))
                    key(code, down: false, flags: flags)
                }
                if let m = s.mark, let state {
                    marks.append(try state.mark(m))
                }
                completed += 1
            }
        }

        var aborted: String?
        do {
            if !setupSteps.isEmpty { try await run(setupSteps, prefix: "setup step") }
            if o.script.setup != nil, let st = state, !o.now {
                if st.t0 == nil, let label = st.startOn {
                    // The recording is waiting for its start marker: setup is done, so send it.
                    if !st.readMarks().contains(where: { $0.label == label }) {
                        marks.append(try st.mark(label))
                        log("Setup done; sent start marker \"\(label)\"")
                    }
                    let deadline = Date().addingTimeInterval(30)
                    var t0: Double?
                    while t0 == nil {
                        t0 = (try? RecordingState.current())?.captureStartedAt
                        if t0 == nil {
                            guard (try? RecordingState.current()) != nil else { throw ReelError.message("The recording ended before capture started") }
                            guard Date() < deadline else { throw ReelError.message("Capture didn't start within 30s of the start marker") }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                    }
                    clockStart = t0!
                    // Report markers on the capture clock from here on.
                    if let fresh = try? RecordingState.current() {
                        state = fresh
                        let now = fresh.readMarks()
                        marks = marks.map { m in now.first { $0.label == m.label } ?? m }
                    }
                } else {
                    // Armed but still setting up: wait for capture to begin.
                    while true {
                        guard let cur = try? RecordingState.current() else { throw ReelError.message("The recording ended before capture started") }
                        if let t0 = cur.t0 { clockStart = t0; state = cur; break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                steps = try o.script.timeline(markers: o.script.markers(base: (try? RecordingState.current())?.readMarks() ?? []))
                if let first = steps.first, first.t < now() - 0.05 {
                    log(String(format: "warning: the recording is at %.2fs; steps before that run immediately", now()))
                }
            } else if o.script.setup != nil {
                clockStart = Date().timeIntervalSince1970
            }
            try await run(steps, prefix: "step")
        } catch let a as Aborted {
            aborted = a.reason
        }
        if buttonDown { CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pos, mouseButton: .left)?.post(tap: .cghidEventTap) }
        if let aborted { log("Aborted: \(aborted). Released the mouse.") }
        return ActResult(steps: setupSteps.count + steps.count, completed: completed, aborted: aborted, duration: now() - started,
                         markers: marks, window: .init(x: wf.minX, y: wf.minY, width: wf.width, height: wf.height), pid: window.pid)
    }
}

/// "cmd+shift+s", "return", "esc", "left", "f5" → key code and modifiers (US layout).
public enum Keys {
    static let codes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "forwarddelete": 117,
            "esc": 53, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "\\": 42, "`": 50,
        ]
        let letters: [(String, CGKeyCode)] = [("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
            ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31),
            ("u", 32), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46)]
        for (k, v) in letters { m[k] = v }
        let digits: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (i, v) in digits.enumerated() { m["\(i)"] = v }
        let fkeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, v) in fkeys.enumerated() { m["f\(i + 1)"] = v }
        return m
    }()

    public static func parse(_ combo: String) throws -> (CGKeyCode, CGEventFlags) {
        var flags: CGEventFlags = []
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, !keyName.isEmpty else { throw ReelError.message("Empty key \"\(combo)\"") }
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: throw ReelError.message("Unknown modifier \"\(m)\" in \"\(combo)\" (cmd, shift, opt, ctrl, fn)")
            }
        }
        guard let code = codes[keyName] else { throw ReelError.message("Unknown key \"\(keyName)\" in \"\(combo)\"") }
        return (code, flags)
    }
}
