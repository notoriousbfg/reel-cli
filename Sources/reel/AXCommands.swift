import AppKit
import ArgumentParser
import Foundation
import ReelKit

// MARK: - accessibility (optional)

struct Locate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find UI elements by label and print their frames, normalized to the window. Needs Accessibility.",
        discussion: """
            reel locate --app MyApp --label "Highlight" --role button
            reel locate --window-id 22987 --list            # every labelled element
            Coordinates match cursor scripts and --zoom: 0–1 of the window, top-left origin.
            With a recording running and no target given, the recorded window is used.
            """)
    @Option(help: "Process id.") var pid: Int32?
    @Option(help: "Window id (see `reel windows`).") var windowID: UInt32?
    @Option(help: "App name or bundle id (its largest window).") var app: String?
    @Option(help: "Text to match against title, description, value or identifier.") var label: String?
    @Option(help: "Accessibility role, e.g. button, textfield, statictext, link, checkbox.") var role: String?
    @Flag(help: "List every labelled element instead of searching.") var list = false

    func run() async throws {
        try Accessibility.require("reel locate")
        await AppKitSession.ensure()
        var pid = self.pid, windowID = self.windowID
        if let app, pid == nil {
            let a = app.lowercased()
            guard let running = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.lowercased() == a || $0.bundleIdentifier?.lowercased() == a
            }) else { throw ReelError.message("\(app) isn't running") }
            pid = running.processIdentifier
        }
        if pid == nil && windowID == nil, let state = try? RecordingState.current() {
            pid = state.targetPID; windowID = state.windowID
        }
        guard pid != nil || windowID != nil else { throw ReelError.message("Pass --app, --pid or --window-id") }
        let window = try Accessibility.window(pid: pid, windowID: windowID)
        let all = try Accessibility.elements(in: window)
        struct Out: Encodable { var windowID: UInt32?; var pid: Int32; var title: String?; var count: Int; var elements: [Accessibility.Element] }
        func out(_ e: [Accessibility.Element]) throws {
            try printJSON(Out(windowID: window.windowID, pid: window.pid, title: window.title, count: e.count, elements: e))
        }
        guard let label, !list else {
            let r = role.map { r in r.lowercased().hasPrefix("ax") ? r.lowercased() : "ax" + r.lowercased() }
            try out(r.map { r in all.filter { $0.role.lowercased() == r } } ?? all)
            return
        }
        let found = Accessibility.find(all, label: label, role: role)
        if found.isEmpty {
            throw ReelError.message("No element matching \"\(label)\"\(role.map { " with role \($0)" } ?? ""). Try `reel locate --list`.")
        }
        try out(found)
    }
}

struct Act: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Perform a cursor script with real mouse and keyboard input. Needs Accessibility.",
        discussion: """
            Uses the same script as `reel cursor` / --cursor-script, plus act-only steps:
              {"at": 3, "type": "Hello"}   {"at": 5, "key": "cmd+s"}   {"at": 6, "scroll": [0, 400]}
              {"at": 2, "click": {"label": "Highlight", "role": "button"}}   (found live on screen)
              {"at": 2, "click": true, "count": 2}                          (double-click)
              {"at": 2, "click": true, "button": "right"}                   (context menu)
              {"at": 3, "click": {"label": "Show in Finder", "role": "menuitem"}}
              {"at": 2, "click": [0.4, 0.3], "modifiers": ["option"]}
            Element targets are looked for in the app's open menus and its window, for up
            to 1.5s. The JSON's "performed" lists where each click landed (screen points)
            and which element it matched.
            With `reel record` running, times are on the recording's clock and the recorded
            window is the target, so one script can be performed for real or only drawn.
            It takes over the pointer and aborts as soon as you move the mouse or press Esc.

              reel record --app MyApp --launch -o raw.mov &
              reel act --script demo.json
              reel stop
            With --stop-recording-on-error, a script that fails or is aborted ends the
            running recording as a failed take (exit 5 from `reel record`) instead of
            leaving it to run to its timeout.
            """)
    @Option(help: "Cursor script JSON.") var script: String
    @Option(help: "Target process (default: the running recording's).") var pid: Int32?
    @Option(help: "Target window (default: the running recording's).") var windowID: UInt32?
    @Flag(help: "Start the script clock now rather than at the recording's t=0.") var now = false
    @Option(help: "Typing speed, characters per second.") var typeRate: Double = 14
    @Option(help: "Abort if the pointer is this many points from where reel put it.") var tolerance: Double = 6
    @Flag(help: "If the script fails or is aborted, end the running recording as a failed take.") var stopRecordingOnError = false

    func run() async throws {
        func failTake(_ reason: String) {
            guard stopRecordingOnError, (try? RecordingState.failRunning("reel act: " + reason)) != nil else { return }
            log("Ended the recording as a failed take")
        }
        let r: ActResult
        do {
            var o = ActOptions(script: try CursorScript.load(absURL(script)))
            o.pid = pid; o.windowID = windowID; o.now = now; o.typeRate = typeRate; o.tolerance = tolerance
            r = try await Actor.perform(o, log: log)
        } catch {
            failTake(error.localizedDescription)
            throw error
        }
        try printJSON(r)
        if let reason = r.aborted {
            failTake("aborted: " + reason)
            throw ExitCode(2)
        }
    }
}
