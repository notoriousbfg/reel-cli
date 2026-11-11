import ArgumentParser
import Foundation
import ReelKit

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func printJSON<T: Encodable>(_ value: T) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try enc.encode(value), as: UTF8.self))
}

func absURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

/// "5.5,25.3,27" → [5.5, 25.3, 27]
func parseTimes(_ s: String) throws -> [Double] {
    let v = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let times = v.compactMap(Double.init)
    guard !times.isEmpty, times.count == v.count else { throw ReelError.message("Expected comma-separated seconds, got \(s)") }
    return times
}

@main
struct Reel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reel",
        abstract: "Record and edit polished screen recordings from the command line.",
        discussion: """
            Typical agent loop:
              reel record --app Grasmere --launch --no-cursor --duration 20 -o raw.mov
              reel sheet raw.mov -o sheet.png --grid        # look at the footage
              reel changes raw.mov                          # when does the screen change?
              reel edit raw.mov:1.5-18 --cursor 1.8 --zoom src:4-8:rect=0.5,0.1,0.4,0.3 \\
                   --preset promo --preview-at 3,6,9 -o check.png   # check the edit
              reel edit raw.mov:1.5-18 ... -o promo.mp4      # export
              reel run scene.json                           # or describe a whole take in one file

            stdout is JSON; progress and messages go to stderr.
            Only `record` and `windows` need a permission (Screen Recording). The optional
            `locate`, `act` and `record --ax-snapshots` also need Accessibility.
            File formats (events sidecar, cursor scripts, presets, scenes): reel help formats
            """,
        version: "0.5.1",
        subcommands: [Record.self, Shot.self, Stop.self, Mark.self, Windows.self, Edit.self, Run.self, Cursor.self,
                      Changes.self, Info.self, Frame.self, Sheet.self, Locate.self, Act.self, Doctor.self, Formats.self]
    )
}

// MARK: - record

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record a single app window (or the display) to a video file.",
        discussion: """
            Captures only the chosen window, so notifications and other apps never
            appear. Writes <output>.events.json with cursor positions, clicks, cursor
            shapes and `reel mark` markers.
            Without --duration, recording runs until Ctrl-C, SIGTERM, `reel stop`,
            --stop-on's marker (+ --tail), or (with --until-exit) the app quitting.
            With --start-on, reel launches the app but starts capturing only when that
            marker arrives (t=0); earlier markers get negative times. --timeout bounds
            each marker wait. --duration remains a hard cap.

            --app with a .app path records that exact bundle, even when another copy
            with the same bundle id is running (e.g. /Applications vs an Xcode build).
            When reel launches the app, it records that process's first window.

            Examples:
              reel record --app Grasmere --launch --duration 20 -o raw.mov
              reel record --app ~/build/Debug/Grasmere.app --new-instance \\
                   --env DEMO_MODE=1 --args "-AppleLanguages (en)" --until-exit --quit-after -o raw.mov
              reel record --pid 4242 --window-title Chapter -o raw.mov
              reel record --app Grasmere --new-instance --start-on ready --stop-on done \\
                   --tail 1.5 --timeout 60 --quit-after -o raw.mov
            """)

    @OptionGroup var target: TargetOptions
    @Option(help: "Stop when this marker arrives (plus --tail).")
    var stopOn: String?
    @Option(help: "Seconds to keep recording after the --stop-on marker.")
    var tail: Double = 0
    @Option(help: "Seconds to record.")
    var duration: Double?
    @Flag(help: "Stop when the recorded app quits.")
    var untilExit = false
    @Flag(help: "Store labelled UI element frames at the start and at each `reel mark`, so cursor scripts can target {\"label\": …}. Needs Accessibility.")
    var axSnapshots = false
    @Flag(help: "Don't note the on-screen cursor shape (I-beam, hand…) in the sidecar.")
    var noCursorShapes = false
    @Option(help: "Restart capture up to this many times if macOS stops the stream.")
    var maxRestarts = 5
    @Flag(help: "Also capture the app's popovers, menus, sheets and drag images over the window (composited in place; the picture stays the window's frame).")
    var includeChildWindows = false
    @Flag(help: "Hide macOS's purple \"being shared\" pill over the window's traffic lights: store a still of that corner, which `reel edit` draws over it.")
    var cleanTitlebar = false
    @Option(help: "Seconds to count down before recording.")
    var countdown: Double = 0
    @Option(help: "Frames per second.")
    var fps = 60
    @Flag(help: "Hide the mouse cursor in the video (add a drawn one later with `edit --cursor`).")
    var noCursor = false
    @Flag(help: "Don't write the cursor/click events sidecar.")
    var noEvents = false
    @Flag(help: "Encode H.264 instead of HEVC.")
    var h264 = false
    @Option(name: .shortAndLong, help: "Output .mov or .mp4.")
    var output: String = "recording.mov"

    func run() async throws {
        var o = try target.options(output: absURL(output))
        o.untilExit = untilExit; o.axSnapshots = axSnapshots
        o.cursorShapes = !noCursorShapes; o.maxRestarts = max(0, maxRestarts)
        o.stopOn = stopOn; o.tail = max(0, tail); o.cleanTitlebar = cleanTitlebar; o.includeChildWindows = includeChildWindows
        o.duration = duration; o.countdown = countdown; o.fps = fps
        o.showsCursor = !noCursor; o.trackCursor = !noEvents; o.hevc = !h264
        if untilExit && target.pid == nil && target.app == nil && target.windowID == nil && target.windowTitle == nil {
            throw ReelError.message("--until-exit needs a target: --app, --pid, --window-id or --window-title")
        }
        let result = try await Recorder(options: o).run(log: log)
        try printJSON(result)
        if result.timedOut != nil { throw ExitCode(4) }
        // A --duration take that ended short is a failure, even though the file is usable.
        let expected = result.endedBy == "stop-marker" || (untilExit && result.endedBy == "app-exit")
        if let duration, !expected, result.duration < duration - 0.25 {
            log(String(format: "Recording is %.2fs of the requested %.2fs", result.duration, duration))
            throw ExitCode(3)
        }
    }
}

/// Launch and target flags shared by `record` and `shot`.
struct TargetOptions: ParsableArguments {
    @Option(help: "App to capture: name (Grasmere), bundle id (com.example.Grasmere) or .app path (that exact bundle).")
    var app: String?
    @Option(help: "Capture a window of this running process instead of looking the app up.")
    var pid: Int32?
    @Flag(help: "Launch/activate the app first.")
    var launch = false
    @Flag(help: "Start a fresh process even if the app is running (implies --launch).")
    var newInstance = false
    @Option(parsing: .singleValue, help: "Environment variable for the launched app, KEY=VALUE (repeatable; implies --launch).")
    var env: [String] = []
    @Option(parsing: .unconditional, help: "Launch arguments for the app, as one shell-style string, e.g. --args \"-AppleLanguages (fr)\" (implies --launch).")
    var args: String?
    @Flag(help: "Launch without bringing the app to the front.")
    var background = false
    @Option(name: .customLong("open"), help: "URL or file to open in the app (e.g. http://localhost:3000 with --app Safari).")
    var openURL: String?
    @Option(help: "Pick the window whose title contains this text.")
    var windowTitle: String?
    @Option(help: "Exact window id (see `reel windows`).")
    var windowID: UInt32?
    @Flag(help: "Capture the whole main display (only the app's windows if --app/--pid is given).")
    var display = false
    @Option(help: "Seconds to wait for the app window to appear.")
    var windowTimeout: Double = 15
    @Flag(help: "Quit the app when done (reported only once its process has exited).")
    var quitAfter = false
    @Flag(help: "Like --quit-after, but force-quit the app if it hasn't gone 5s later (e.g. a save sheet is open).")
    var forceQuit = false
    @Option(help: "Launch, then start capturing only when this marker arrives (`reel mark`, --marks-file, or `reel act` setup); t=0 is that moment.")
    var startOn: String?
    @Option(help: "Seconds to wait for each marker (--start-on, --stop-on) before failing the take.")
    var timeout: Double?
    @Option(help: "Watch this file for markers: lines of \"<label> <unix time>\" (for harnesses in a sandbox that can't run `reel mark`).")
    var marksFile: String?

    func options(output: URL) throws -> RecordOptions {
        var o = RecordOptions(output: output)
        o.app = app; o.pid = pid; o.launch = launch; o.newInstance = newInstance
        o.background = background; o.openURL = openURL; o.quitAfter = quitAfter || forceQuit; o.forceQuit = forceQuit
        o.marksFile = marksFile.map(absURL)
        o.startOn = startOn; o.markerTimeout = timeout
        for e in env {
            guard let eq = e.firstIndex(of: "="), eq != e.startIndex else { throw ReelError.message("--env expects KEY=VALUE (got \(e))") }
            o.environment[String(e[..<eq])] = String(e[e.index(after: eq)...])
        }
        if let args { o.arguments = try ShellWords.split(args) }
        o.windowTitle = windowTitle; o.windowID = windowID; o.display = display
        o.windowTimeout = windowTimeout
        return o
    }
}

// MARK: - shot

struct Shot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Capture one still of an app window (PNG or JPEG).",
        discussion: """
            Launches like `reel record`, optionally waits for a marker and --settle seconds,
            captures the window, then quits the app if reel launched it (--keep-open to leave it).

              reel shot --app build/Grasmere.app --new-instance --env DEMO=1 \
                   --start-on ready --settle 0.5 --width 1600 -o hero.png
            """)
    @OptionGroup var target: TargetOptions
    @Option(help: "Seconds to wait after the start marker (or the window appearing) before capturing.")
    var settle: Double = 0
    @Option(help: "Crop x,y,w,h in image px (or %).")
    var crop: String?
    @Option(help: "Downscale to at most this width.")
    var width: Int?
    @Option(help: "JPEG quality, 0–1.")
    var quality: Double = 0.9
    @Flag(help: "Include the mouse cursor.")
    var showCursor = false
    @Flag(help: "Leave an app reel launched running.")
    var keepOpen = false
    @Option(name: .shortAndLong, help: "Output .png, .jpg or .jpeg.")
    var output: String = "shot.png"

    func run() async throws {
        let out = absURL(output)
        guard ["png", "jpg", "jpeg"].contains(out.pathExtension.lowercased()) else {
            throw ReelError.message("--output must end in .png, .jpg or .jpeg")
        }
        var o = try target.options(output: out)
        o.showsCursor = showCursor
        var s = ShotOptions()
        s.settle = max(0, settle); s.crop = crop; s.width = width; s.quality = quality; s.keepOpen = keepOpen
        try printJSON(try await Recorder(options: o).shot(s, log: log))
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop a running `reel record`.")
    func run() throws {
        let pid = try RecordingState.stopRunning()
        log("Sent stop to recording process \(pid)")
    }
}

struct Mark: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add a named marker to the running recording (or to a clip's sidecar).",
        discussion: """
            Call it from a test harness as each step happens:
              reel mark open-palette
            The marker lands in the recording's events sidecar. Cursor scripts and
            --zoom can then use it as a time: "at": "open-palette+0.2",
            --zoom open-palette..close-palette:1.7@0.5,0.3

            To add one after the fact: reel mark intro --clip raw.mov --at 2.5

            A sandboxed app can't run reel, so let it append "<label> <unix time>" lines
            to a file instead: watch it live with `reel record --marks-file <file>`, or
            import it afterwards with `reel mark --import <file> --clip raw.mov` (times
            are placed using the sidecar's startedAt).
            """)
    @Argument(help: "Marker name (letters, digits, - and _ read best in time references).")
    var label: String?
    @Option(help: "Import markers from a file of \"<label> <unix time>\" lines (needs --clip).")
    var `import`: String?
    @Option(parsing: .unconditional, help: "Shift the marker by this many seconds (e.g. -0.2 when the call comes just after the action).")
    var offset: Double = 0
    @Option(help: "Add to this clip's sidecar instead of the running recording.")
    var clip: String?
    @Option(help: "With --clip: source time in seconds.")
    var at: Double?

    func run() throws {
        if let file = `import` {
            guard let clip else { throw ReelError.message("--import needs --clip <recording>") }
            let url = absURL(clip)
            var ev = try RecordingEvents.read(RecordingEvents.sidecarURL(for: url))
            guard let startedAt = ev.startedAt else {
                throw ReelError.message("\(url.lastPathComponent)'s sidecar has no startedAt (recorded before reel 0.2), so Unix times can't be placed")
            }
            guard let text = try? String(contentsOf: absURL(file), encoding: .utf8) else { throw ReelError.message("Cannot read \(file)") }
            var added: [RecordingEvents.Marker] = []
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                do {
                    guard let (label, unix) = try MarkLine.parse(String(line)) else { continue }
                    added.append(.init(label: label, t: ((unix - startedAt + offset) * 1000).rounded() / 1000))
                } catch { throw ReelError.message("\(file) line \(n + 1): \(error.localizedDescription)") }
            }
            let duration = ev.samples.last?.t ?? .infinity
            for m in added where m.t < 0 || m.t > duration {
                log(String(format: "warning: marker %@ at %.2fs is outside the recording (0–%.2fs)", m.label, m.t, duration))
            }
            // Re-importing replaces markers with the same label and time.
            var markers = (ev.markers ?? []).filter { m in !added.contains { $0.label == m.label && abs($0.t - m.t) < 0.0005 } }
            markers += added
            ev.markers = markers.sorted { $0.t < $1.t }
            try ev.write(for: url)
            try printJSON(added)
            return
        }
        guard let label else { throw ReelError.message("Give a marker name, or --import <file> --clip <recording>") }
        guard !label.isEmpty, Double(label) == nil else { throw ReelError.message("Marker names can't be plain numbers") }
        if let clip {
            guard let at else { throw ReelError.message("--clip needs --at SECONDS") }
            let url = absURL(clip)
            let sidecar = RecordingEvents.sidecarURL(for: url)
            var ev = try RecordingEvents.read(sidecar)
            var markers = (ev.markers ?? []).filter { $0.label != label }
            let m = RecordingEvents.Marker(label: label, t: at + offset)
            markers.append(m)
            ev.markers = markers.sorted { $0.t < $1.t }
            try ev.write(for: url)
            try printJSON(m)
            return
        }
        try printJSON(try RecordingState.current().mark(label, offset: offset))
    }
}

struct Windows: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List capturable windows as JSON.")
    @Option(help: "Only windows of this app (name or bundle id).")
    var app: String?
    func run() async throws {
        var list = try await ReelKit.Windows.list()
        if let app = app?.lowercased() {
            list = list.filter { $0.app.lowercased() == app || $0.bundleID.lowercased() == app }
        }
        try printJSON(list)
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Report permissions and environment.")
    func run() throws {
        struct Report: Encodable {
            var screenRecording: Bool; var accessibility: Bool; var accessibilityNote: String
            var note: String; var presetFiles: [String]
        }
        try printJSON(Report(
            screenRecording: Permissions.screenRecording,
            accessibility: Accessibility.trusted,
            accessibilityNote: "Optional: only `reel locate`, `reel act` and `record --ax-snapshots` use it.",
            note: Permissions.screenRecording
                ? "Ready to record. Nothing else needs Accessibility, Input Monitoring or Automation."
                : "Grant Screen Recording to this terminal in System Settings › Privacy & Security to use `record`/`windows`. Editing works without it.",
            presetFiles: [Presets.userFile, Presets.projectFile].map(\.path)
                .filter { FileManager.default.fileExists(atPath: $0) }))
    }
}

// MARK: - edit

struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Trim, crop, zoom, join and style clips into a finished video.",
        discussion: """
            CLIPS   file.mov  |  file.mov:START-END  (trim, seconds; either side optional)
            --zoom and --fade-* times are on the OUTPUT timeline (after trims/transitions),
            and --zoom positions are 0–1 of the OUTPUT frame, unless you write src:,
            which means source-clip seconds and 0–1 of the source frame (no arithmetic
            after re-trimming). Marker names (from `reel mark`) are source times.
            --crop is in SOURCE pixels. Prefix N= to target clip N (crop, speed, events,
            cursor-script, zoom, cut, patch) or the Nth join (transition).

            Dead time, by source time or marker:
              --cut asked+1.0..answered-0.3          remove it (0.3s crossfade, --cut-fade)
              --speed asked+1.0..answered-0.3=6      play it 6× faster
            Markers, cursor, clicks and src: zooms after a cut still land on the right frames.
            --patch logo.png@0,0,180,80[:0-12]     draw over source pixels (before crop/zoom);
            patches stored by `record --clean-titlebar` apply automatically.

            Zoom forms:
              3-7:2@0.25,0.4                 output time, point
              src:12.2-22.5:1.8@0.3,0.2      source time + source point
              src:12.2-22.5:rect=0.28,0.1,0.48,0.5   fit this source region (scale computed, max 3×)
              step-1..step-2+0.5:1.7@cursor  between markers, following the cursor
              2=src:1-4:2@0.5,0.5            clip 2

            Examples:
              --crop 0,56,2400,1500          --crop 10%,10%,80%,80%     --crop 2=0,0,1280,800
              --crop window                  the app window of a `record --display --app` take
              --auto-zoom 2                  --transition crossfade:0.8 --transition 2=slide-left:0.5
              --padding 96 --background '#0f2027,#2c5364' --corner-radius 22 --shadow
              --cursor 1.8 --cursor-script moves.json      --preset promo
            """)

    @Argument(help: "Input clips, in order.")
    var clips: [String]
    @Option(name: .shortAndLong, help: "Output video (.mp4/.mov), or .png with --preview-at / --preview-sheet.")
    var output: String
    @Option(help: "Named settings from ~/.config/reel/presets.json or ./reel.json (and, under `reel run`, reel.json beside the scene). Flags override it.")
    var preset: String?
    @Option(parsing: .singleValue, help: "Crop x,y,w,h in source px (or %). Repeatable; N= for one clip.")
    var crop: [String] = []
    @Option(parsing: .singleValue, help: "Zoom; see the forms above. Repeatable. Touching zooms pan between targets.")
    var zoom: [String] = []
    @Option(help: "Zoom in on each burst of recorded clicks at this scale (needs events).")
    var autoZoom: Double?
    @Option(help: "Seconds to ease into/out of each zoom (default 0.6).")
    var zoomEase: Double?
    @Option(parsing: .singleValue, help: "cut|crossfade|fade|slide-left|slide-right|slide-up|slide-down|wipe|zoom[:SECONDS]. Repeatable; N= for one join.")
    var transition: [String] = []
    @Option(parsing: .singleValue, help: "Playback speed: 2, 2=1.5 (clip 2), or a source stretch A..B=6 (seconds or markers, e.g. asked+1..answered-0.3=6). Repeatable.")
    var speed: [String] = []
    @Option(parsing: .singleValue, help: "Remove a source stretch A..B (seconds or markers, e.g. asked+1.0..answered-0.3), with a short crossfade across the join. Repeatable; N= for one clip.")
    var cut: [String] = []
    @Option(help: "Crossfade seconds across each --cut (0 = hard cut; default 0.3).")
    var cutFade: Double?
    @Option(parsing: .singleValue, help: "Draw IMAGE over a source rectangle: IMAGE@x,y[,w,h][:START-END] (source px and seconds), before crop and zoom. Repeatable; N= for one clip.")
    var patch: [String] = []
    @Flag(help: "Ignore patches stored by `record --clean-titlebar`.")
    var noRecordedPatches = false
    @Option(help: "Output size WxH (default: cropped size of first clip + padding).")
    var size: String?
    @Option(help: "Pixels of background around the content.")
    var padding: Double?
    @Option(help: "Background hex color, or two for a gradient: '#101020,#3a1c71'.")
    var background: String?
    @Option(help: "Round the content's corners (px).")
    var cornerRadius: Double?
    @Flag(inversion: .prefixedNo, help: "Drop shadow under the content (use with --padding).")
    var shadow: Bool?
    @Option(help: "Fade in from black (seconds).")
    var fadeIn: Double?
    @Option(help: "Fade out to black (seconds).")
    var fadeOut: Double?
    @Option(help: "Output frame rate (default 60).")
    var fps: Int?
    @Flag(help: "Drop audio.")
    var mute = false
    @Option(help: "Draw a smooth macOS cursor from the events at this size (1 = real size; 1.5–2 reads well in promos). Record with --no-cursor so it isn't doubled.")
    var cursor: Double?
    @Flag(inversion: .prefixedNo, help: "With --cursor: a halo on clicks (default on).")
    var clickEffect: Bool?
    @Option(parsing: .singleValue, help: "Events file to use instead of <clip>.events.json (N= for one clip). The sidecar is never modified.")
    var events: [String] = []
    @Option(parsing: .singleValue, help: "Cursor script (JSON steps) that replaces the recorded cursor track (N= for one clip). See `reel help formats`.")
    var cursorScript: [String] = []
    @Option(help: "hevc or h264 (default hevc).")
    var codec: String?
    @Flag(help: "Same as --codec h264.")
    var h264 = false
    @Option(help: "Render PNG(s) of the edited output instead of exporting: one time, or a comma list for a contact sheet.")
    var previewAt: String?
    @Flag(help: "Render a contact sheet PNG of the edited output instead of exporting.")
    var previewSheet = false
    @Option(help: "Seconds between --preview-sheet frames (default: 12 evenly spaced).")
    var every: Double?
    @Flag(help: "Overlay a 10% grid on preview sheets.")
    var grid = false
    @Flag(help: "Print the resolved edit plan as JSON and exit.")
    var dryRun = false

    func run() async throws {
        let p = try preset.map { try Presets.named($0) } ?? Preset()
        var o = EditOptions()
        o.inputs = clips.map { spec in
            let c = Parse.clipSpec(spec)
            let path = absURL(c.path).path
            return c.start == nil && c.end == nil ? path
                : "\(path):\(c.start.map { "\($0)" } ?? "")-\(c.end.map { "\($0)" } ?? "")"
        }
        o.crops = crop.isEmpty ? (p.crop.map { [$0] } ?? []) : crop
        o.zooms = zoom; o.autoZoom = autoZoom; o.zoomEase = zoomEase ?? p.zoomEase ?? 0.6
        o.transitions = transition.isEmpty ? (p.transition.map { [$0] } ?? []) : transition
        o.speeds = speed; o.size = size ?? p.size
        o.cuts = cut; o.cutFade = cutFade ?? 0.3; o.patches = patch; o.recordedPatches = !noRecordedPatches
        o.padding = padding ?? p.padding ?? 0
        o.background = background ?? p.background ?? "#000000"
        o.cornerRadius = cornerRadius ?? p.cornerRadius ?? 0
        o.shadow = shadow ?? p.shadow ?? false
        o.fadeIn = fadeIn ?? p.fadeIn ?? 0; o.fadeOut = fadeOut ?? p.fadeOut ?? 0
        o.fps = fps ?? p.fps ?? 60; o.mute = mute
        o.cursor = cursor ?? p.cursor; o.clickEffect = clickEffect ?? p.clickEffect ?? true
        o.events = events.map { e in let (i, v) = Parse.indexed(e); return (i.map { "\($0)=" } ?? "") + absURL(v).path }
        o.cursorScripts = cursorScript.map { e in let (i, v) = Parse.indexed(e); return (i.map { "\($0)=" } ?? "") + absURL(v).path }
        let codecName = h264 ? "h264" : (codec ?? p.codec ?? "hevc").lowercased()
        guard ["hevc", "h264"].contains(codecName) else { throw ReelError.message("--codec is hevc or h264 (got \(codecName))") }

        let plan = try await Planner.plan(o)
        if plan.cursor != nil, try plan.clips.contains(where: {
            let ev = try $0.loadEvents()
            return ev?.cursorInVideo == true
        }) {
            log("Note: the recording already shows the system cursor, so there will be two. Record with --no-cursor when using --cursor.")
        }
        let out = absURL(output)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        if dryRun {
            struct DryRun: Encodable { var duration: Double; var clipStarts: [Double]; var plan: EditPlan }
            try printJSON(DryRun(duration: plan.totalDuration, clipStarts: plan.clipStarts, plan: plan))
            return
        }
        struct Result: Encodable { var output: String; var duration: Double; var width: Int; var height: Int; var kind: String }
        let times: [Double]? = try previewAt.map(parseTimes)
        if let times, times.count == 1 {
            try Stills.writePNG(try await Stills.preview(plan, at: times[0]), to: out)
            try printJSON(Result(output: out.path, duration: plan.totalDuration, width: plan.canvas.width, height: plan.canvas.height, kind: "preview"))
            return
        }
        if previewSheet || times != nil {
            let composer = try Composer(plan: plan)
            try await Inspect.contactSheet(
                times: times ?? Inspect.sampleTimes(duration: plan.totalDuration, every: every, count: nil),
                frame: { try await Stills.preview(plan, at: $0) },
                clicks: composer.outputClicks().map { c in
                    let p = composer.zoomedPoint(at: c.t, x: c.x, y: c.y); return (t: c.t, x: p.x, y: p.y)
                }.filter { (0...1).contains($0.x) && (0...1).contains($0.y) }, columns: 4, width: 1800, grid: grid, to: out)
            try printJSON(Result(output: out.path, duration: plan.totalDuration, width: plan.canvas.width, height: plan.canvas.height, kind: "sheet"))
            return
        }
        log(String(format: "Exporting %.1fs at %d×%d…", plan.totalDuration, plan.canvas.width, plan.canvas.height))
        try await Exporter.export(plan, to: out, hevc: codecName == "hevc") { p in
            log(String(format: "  %3.0f%%", p * 100))
        }
        try printJSON(Result(output: out.path, duration: plan.totalDuration, width: plan.canvas.width, height: plan.canvas.height, kind: "video"))
    }
}

// MARK: - cursor scripts

struct Cursor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Turn a cursor script into an events file (for apps driven by a test harness).",
        discussion: """
            Writes the same format `reel record` does, so --cursor, @cursor zooms,
            --auto-zoom and sheet click rings all work. Times may name markers.
            Use the result with `reel edit clip.mov --events <file>`, or skip this step
            with `reel edit clip.mov --cursor-script moves.json`.

            Script steps (see `reel help formats` for all of them):
              {"at": 4.3, "move": [0.435, 0.025], "over": 0.8}
              {"at": 4.35, "click": true}
              {"at": 14.6, "drag": [[0.352, 0.37], [0.545, 0.37]], "over": 1.0}
              {"at": "rename+0.2", "shape": "ibeam"}
            """)
    @Argument(help: "The clip the cursor belongs to (its sidecar supplies geometry and markers, if present).")
    var clip: String
    @Option(help: "Cursor script JSON.")
    var script: String
    @Option(help: "Points-to-pixels scale when the clip has no sidecar.")
    var scale: Double = 2
    @Option(name: .shortAndLong, help: "Events file to write (default <clip>.cursor.events.json).")
    var output: String?
    @Flag(help: "Allow overwriting the clip's recorded sidecar.")
    var force = false

    func run() async throws {
        let url = absURL(clip)
        let info = try await Inspect.info(path: url.path)
        let base = RecordingEvents.load(for: url)
        let script = try CursorScript.load(absURL(self.script))
        let s = base?.pointPixelScale ?? scale
        let ev = try script.events(base: base, pointsSize: (Double(info.width) / s, Double(info.height) / s),
                                   pointPixelScale: s, duration: info.duration, warn: { log("warning: \($0)") })
        let out = output.map(absURL) ?? url.deletingPathExtension().appendingPathExtension("cursor.events.json")
        let sidecar = RecordingEvents.sidecarURL(for: url).standardizedFileURL
        if out.standardizedFileURL == sidecar, let base, base.synthetic != true, !force {
            throw ReelError.message("\(out.lastPathComponent) holds the recorded cursor track. Write elsewhere, or pass --force to replace it.")
        }
        try ev.write(to: out)
        struct Summary: Encodable {
            var output: String; var samples: Int; var duration: Double
            var clicks: [RecordingEvents.Click]; var markers: [RecordingEvents.Marker]?; var shapes: [RecordingEvents.ShapeChange]?
            var use: String
        }
        try printJSON(Summary(output: out.path, samples: ev.samples.count, duration: ev.samples.last?.t ?? 0,
                              clicks: ev.clicks, markers: ev.markers, shapes: ev.shapes,
                              use: "reel edit \(clip) --events \(out.path) --cursor 1.8 …"))
    }
}

// MARK: - run (scene files)

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Prepare, record (or shoot) and edit a whole take described in one JSON scene file.",
        discussion: """
            {
              "prepare": ["./scripts/seed-demo-data.sh"],   // stdout KEY=VALUE lines become ${KEY}
              "record": {"app": "build/Grasmere.app", "newInstance": true, "noCursor": true,
                         "env": {"DEMO": "1"}, "untilExit": true, "quitAfter": true, "output": "raw.mov"},
              "cursorScript": "moves.json",          // or an inline array of steps
              "edit": {"trim": "1.2-22", "preset": "promo", "cursor": 1.8,
                       "zoom": ["src:12.2-22.5:rect=0.28,0.1,0.48,0.5"], "output": "promo.mp4"},
              "teardown": ["rm -rf \\"$DEMO_DIR\\""]           // always runs, after quitAfter
            }
            A still instead of a video: {"shot": {<reel shot flags>, "output": "hero.png"}}.
            ${SCENE_DIR}, ${SCENE_NAME}, ${OUT} (the final output file), ${OUT_DIR} and
            prepare's KEY=VALUE values can be used in any string; prepare/teardown commands
            get them as environment variables. Start/stop on markers with
            "record": {"startOn": "ready", "stopOn": "done", "tail": 1.5, "timeout": 60}.
            Keys are the long flags of `reel record` / `reel edit` in camelCase. Lists
            repeat a flag; true sets a flag; false sets --no-… where one exists.
            "act": "act.json" (or inline) performs a script with real input during the
            recording (needs Accessibility); without a stop condition the take ends after it.
            "actCountdown": 3 shows a hands-off banner (with a tick) before the take;
            "actRetries": 2 redoes the take from prepare if act aborts because the pointer was
            moved (after the mouse has been still for 2s). Esc never retries.
            The edit then draws the recorded pointer; "cursorFrom": "script" draws "cursorScript".
            Paths are relative to the scene file. Presets come from ~/.config/reel/presets.json,
            then reel.json in the working directory, then reel.json beside the scene file
            (later files win, field by field).
            """)
    @Argument(help: "Scene JSON file.")
    var scene: String
    @Flag(help: "Skip recording and redo the edit from the existing recording.")
    var editOnly = false
    @Flag(help: "Record only.")
    var recordOnly = false
    @Option(help: "Write a preview contact sheet PNG here instead of exporting.")
    var preview: String?
    @Option(help: "With --preview: seconds between frames.")
    var every: Double?

    func run() async throws {
        let url = absURL(scene)
        guard let data = try? Data(contentsOf: url) else { throw ReelError.message("Cannot read \(url.path)") }
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReelError.message("\(url.lastPathComponent) must be a JSON object with \"record\", \"shot\" and/or \"edit\"")
        }
        let unknown = Set(json.keys).subtracting(["record", "shot", "edit", "cursorScript", "act", "actCountdown", "actRetries", "cursorFrom", "prepare", "teardown", "name", "notes"])
        if !unknown.isEmpty { throw ReelError.message("Unknown scene keys: \(unknown.sorted().joined(separator: ", "))") }
        if json["shot"] != nil && (json["record"] != nil || json["edit"] != nil) {
            throw ReelError.message("A scene makes a still (\"shot\") or a video (\"record\"/\"edit\"), not both")
        }
        let previewURL = preview.map(absURL)
        // Presets: ./reel.json in the working directory, then reel.json beside the scene.
        let sceneDir = url.deletingLastPathComponent()
        Presets.projectFiles = [Presets.projectFile, sceneDir.appendingPathComponent("reel.json")]
        FileManager.default.changeCurrentDirectoryPath(sceneDir.path)

        // Variables: built-ins, then whatever prepare exports.
        var vars = SceneVars(builtins: ["SCENE_DIR": sceneDir.path,
                                        "SCENE_NAME": url.deletingPathExtension().lastPathComponent])
        let rawOut = ((json["edit"] as? [String: Any])?["output"] ?? (json["shot"] as? [String: Any])?["output"]
                      ?? (json["record"] as? [String: Any])?["output"]) as? String ?? "recording.mov"
        let out = absURL(try vars.expand(rawOut, strict: false))
        vars.values["OUT"] = out.path
        vars.values["OUT_DIR"] = out.deletingLastPathComponent().path

        let doTake = !editOnly
        // prepare's values from the last full run, so --edit-only can resolve them.
        let cache = sceneDir.appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).vars.json")
        if !doTake {
            if let data = try? Data(contentsOf: cache), let saved = try? JSONDecoder().decode([String: String].self, from: data) {
                for (k, v) in saved where vars.values[k] == nil { vars.values[k] = v }
            }
            vars.hint = "With --edit-only, prepare doesn't run: its values come from the last full run (\(cache.lastPathComponent)). Run the full take once."
        }
        let prepare = try SceneVars.commands(json["prepare"], key: "prepare")
        let teardown = try SceneVars.commands(json["teardown"], key: "teardown")
        let retries = json["act"] == nil ? 0 : ((json["actRetries"] as? NSNumber)?.intValue ?? 0)
        guard retries >= 0 else { throw ReelError.message("\"actRetries\" is a count, 0 or more") }
        let original = json, baseVars = vars
        var attempt = 0
        while true {
            json = original; vars = baseVars
            do {
                try await attemptTake(&json, vars: &vars, prepare: prepare, teardown: teardown, cache: cache,
                                      sceneDir: sceneDir, rawOut: rawOut, doTake: doTake, previewURL: previewURL)
                return
            } catch let a as ActAborted where a.cause != "esc" && attempt < retries {
                attempt += 1
                log("Act aborted: \(a.reason). Retrying the take (\(attempt) of \(retries)).")
                await InputWatch.waitForStillness(2, log: log)
            } catch let a as ActAborted {
                log("Error: act aborted: \(a.reason)" + (attempt > 0 ? " (after \(attempt) retr\(attempt == 1 ? "y" : "ies"))" : ""))
                throw ExitCode(2)
            }
        }
    }

    private func attemptTake(_ json: inout [String: Any], vars: inout SceneVars, prepare: [String], teardown: [String],
                             cache: URL, sceneDir: URL, rawOut: String, doTake: Bool, previewURL: URL?) async throws {
        if doTake && !prepare.isEmpty {
            log("── prepare")
            do {
                for (i, cmd) in prepare.enumerated() {
                    let exported = try vars.run(cmd, dir: sceneDir, label: "prepare[\(i)]", exportValues: true)
                    if !exported.isEmpty { log("   exported \(exported.joined(separator: ", "))") }
                }
                if let data = try? JSONEncoder().encode(vars.values) { try? data.write(to: cache) }
            } catch {
                runTeardown(teardown, vars: vars, dir: sceneDir)
                throw error
            }
        }
        do {
            // OUT may use prepare's values, so settle it now, then expand the take.
            let finalOut = absURL(try vars.expand(rawOut))
            vars.values["OUT"] = finalOut.path
            vars.values["OUT_DIR"] = finalOut.deletingLastPathComponent().path
            // An edit-only run needs the edit, the cursor script and the recording's
            // name, not the record block's launch settings.
            for key in (doTake ? ["record", "shot", "edit", "cursorScript", "act"] : ["edit", "cursorScript"]) where json[key] != nil {
                json[key] = try vars.expandAny(json[key]!)
            }
            if !doTake, var rec = json["record"] as? [String: Any], let o = rec["output"] {
                rec["output"] = try vars.expandAny(o)
                json["record"] = rec
            }
            try await take(json, doTake: doTake, previewURL: previewURL)
        } catch {
            if doTake { runTeardown(teardown, vars: vars, dir: sceneDir) }
            throw error
        }
        if doTake { runTeardown(teardown, vars: vars, dir: sceneDir) }
    }

    private func runTeardown(_ cmds: [String], vars: SceneVars, dir: URL) {
        var vars = vars
        guard !cmds.isEmpty else { return }
        log("── teardown")
        for (i, cmd) in cmds.enumerated() {
            do { _ = try vars.run(cmd, dir: dir, label: "teardown[\(i)]", exportValues: false) }
            catch { log("warning: \(error.localizedDescription)") }
        }
    }

    private func take(_ json: [String: Any], doTake: Bool, previewURL: URL?) async throws {
        if let shot = json["shot"] as? [String: Any] {
            guard doTake else { throw ReelError.message("A shot scene has no edit to redo") }
            log("── shot")
            var cmd = try Shot.parse(try SceneArgs.flags(shot, invertible: []))
            try await cmd.run()
            return
        }
        let rec = json["record"] as? [String: Any]
        let recOutput = rec?["output"] as? String ?? "recording.mov"
        if doTake, let rec {
            if json["act"] != nil, let n = (json["actCountdown"] as? NSNumber)?.intValue, n > 0 {
                try Accessibility.require("A scene \"act\"")
                await HandsOffCountdown.run(seconds: n, log: log)
            }
            log("── record")
            var cmd = try Record.parse(try SceneArgs.flags(rec, invertible: []))
            if let act = json["act"] {
                try await recordWithAct(&cmd, rec: rec, act: act)
            } else {
                try await cmd.run()
            }
        } else if doTake && json["edit"] == nil {
            throw ReelError.message("Scene has nothing to do")
        }
        guard !recordOnly, var edit = json["edit"] as? [String: Any] else { return }

        log("── edit")
        var input = edit.removeValue(forKey: "input") as? String ?? recOutput
        if let trim = edit.removeValue(forKey: "trim") {
            if let s = trim as? String { input += ":\(s)" }
            else if let a = trim as? [Double], a.count == 2 { input += ":\(a[0])-\(a[1])" }
            else { throw ReelError.message("\"trim\" is \"START-END\" or [start, end]") }
        }
        guard FileManager.default.fileExists(atPath: absURL(Parse.clipSpec(input).path).path) else {
            throw ReelError.message("No recording at \(Parse.clipSpec(input).path); run without --edit-only first")
        }
        // When act drove the real pointer, draw what was recorded so drawn and real can't drift.
        let drawScript = json["act"] == nil || (json["cursorFrom"] as? String) == "script"
        if json["cursorScript"] != nil && !drawScript {
            log("Note: drawing the recorded pointer (act drove it); set \"cursorFrom\": \"script\" to draw the cursor script instead")
        }
        if drawScript, let script = json["cursorScript"] {
            if let path = script as? String { edit["cursorScript"] = path }
            else if JSONSerialization.isValidJSONObject(script) {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reel-scene-\(getpid()).cursor.json")
                try JSONSerialization.data(withJSONObject: script).write(to: tmp)
                edit["cursorScript"] = tmp.path
            }
        }
        if let previewURL {
            edit["output"] = previewURL.path
            edit["previewSheet"] = true
            if let every { edit["every"] = every }
        }
        guard edit["output"] != nil else { throw ReelError.message("\"edit\" needs an \"output\"") }
        var cmd = try Edit.parse([input] + (try SceneArgs.flags(edit, invertible: ["shadow", "clickEffect"])))
        try await cmd.run()
    }
}

extension Run {
    /// Records while performing the scene's "act" script with real input. Act starts once
    /// the recording is armed (so its setup steps and start marker work), and stops the
    /// recording when it ends if the record block has no stop condition of its own.
    func recordWithAct(_ cmd: inout Record, rec: [String: Any], act: Any) async throws {
        try Accessibility.require("A scene \"act\"")
        let script: CursorScript
        if let path = act as? String { script = try CursorScript.load(absURL(path)) }
        else if JSONSerialization.isValidJSONObject(act) { script = try CursorScript.parse(try JSONSerialization.data(withJSONObject: act), name: "scene act") }
        else { throw ReelError.message("\"act\" is a script file or an inline script") }
        let hasStop = rec["duration"] != nil || rec["stopOn"] != nil || (rec["untilExit"] as? Bool) == true
        let tail = (rec["tail"] as? NSNumber)?.doubleValue ?? 1.0
        let recordDone = SharedBool()
        let actTask = Task { () -> Result<ActResult, Error> in
            // Wait for this process's recording to be armed.
            while !recordDone.value {
                if let st = try? RecordingState.current(), st.pid == getpid() { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if recordDone.value { return .failure(ReelError.message("The recording ended before act could start")) }
            log("── act")
            let result: Result<ActResult, Error>
            do { result = .success(try await Actor.perform(ActOptions(script: script), log: log)) }
            catch { result = .failure(error) }
            var stop = !hasStop
            if case .success(let r) = result, r.aborted != nil { stop = true }
            if case .failure = result { stop = true }
            if stop && !recordDone.value {
                if case .success(let r) = result, r.aborted == nil { try? await Task.sleep(for: .seconds(tail)) }
                kill(getpid(), SIGINT)   // ends the recording cleanly
            }
            return result
        }
        var recordError: Error?
        do { try await cmd.run() } catch { recordError = error }
        recordDone.value = true
        switch await actTask.value {
        case .success(let r):
            try printJSON(r)
            if let e = recordError { throw e }
            if let reason = r.aborted { throw ActAborted(reason: reason, cause: r.abortCause ?? "unknown") }
        case .failure(let e):
            if let r = recordError { throw r }
            throw ReelError.message("act: \(e.localizedDescription)")
        }
    }
}

/// Act gave up mid-take; `reel run` may retry (actRetries), else exits with code 2.
struct ActAborted: Error, LocalizedError {
    var reason: String, cause: String
    var errorDescription: String? { "act aborted: \(reason)" }
}

final class SharedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}

/// ${NAME} values for scene files: built-ins plus KEY=VALUE lines from prepare commands.
struct SceneVars {
    var values: [String: String]
    var hint: String?
    init(builtins: [String: String]) { values = builtins }

    static func commands(_ v: Any?, key: String) throws -> [String] {
        guard let v else { return [] }
        if let s = v as? String { return [s] }
        guard let list = v as? [String] else { throw ReelError.message("\"\(key)\" is a list of shell commands") }
        return list
    }

    /// Replaces ${NAME} (scene values, then the environment). Unknown names are an error when strict.
    func expand(_ s: String, strict: Bool = true) throws -> String {
        var out = "", rest = Substring(s)
        while let open = rest.range(of: "${") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else { out += rest[open.lowerBound...]; return out }
            let name = String(rest[open.upperBound..<close])
            if let v = values[name] ?? ProcessInfo.processInfo.environment[name] { out += v }
            else if strict {
                throw ReelError.message("Unknown ${\(name)} in the scene. Built-ins: SCENE_DIR, SCENE_NAME, OUT, OUT_DIR; "
                                        + "prepare commands can define more by printing \(name)=value" + (hint.map { ". " + $0 } ?? ""))
            } else { out += "${\(name)}" }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    func expandAny(_ v: Any) throws -> Any {
        switch v {
        case let s as String: return try expand(s)
        case let a as [Any]: return try a.map { try expandAny($0) }
        case let d as [String: Any]: return try d.mapValues { try expandAny($0) }
        default: return v
        }
    }

    /// Runs `sh -c cmd` in `dir` with the values in its environment. stdout lines
    /// of KEY=VALUE are exported (when asked); everything else is echoed to stderr.
    @discardableResult
    mutating func run(_ cmd: String, dir: URL, label: String, exportValues: Bool) throws -> [String] {
        log("$ \(cmd)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = dir
        p.environment = ProcessInfo.processInfo.environment.merging(values) { _, new in new }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.standardError
        do { try p.run() } catch { throw ReelError.message("\(label): cannot run \(cmd): \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var exported: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if exportValues, let eq = line.firstIndex(of: "="),
               line[..<eq].range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil {
                let key = String(line[..<eq])
                values[key] = String(line[line.index(after: eq)...])
                exported.append(key)
            } else if !line.isEmpty {
                log("   \(line)")
            }
        }
        guard p.terminationStatus == 0 else {
            throw ReelError.message("\(label) failed (exit \(p.terminationStatus)): \(cmd)")
        }
        return exported
    }
}

enum SceneArgs {
    static func kebab(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isUppercase { out += "-" + ch.lowercased() } else { out.append(ch) }
        }
        return out
    }

    static func scalar(_ v: Any, key: String) throws -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: throw ReelError.message("Scene key \"\(key)\" has an unsupported value")
        }
    }

    /// {"newInstance": true, "env": {"A": "1"}, "zoom": ["…", "…"], "duration": 5}
    /// → ["--new-instance", "--env", "A=1", "--zoom", "…", "--zoom", "…", "--duration", "5"]
    static func flags(_ dict: [String: Any], invertible: Set<String>) throws -> [String] {
        var args: [String] = []
        for key in dict.keys.sorted() {
            let flag = "--" + kebab(key)
            let v = dict[key]!
            if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
                if n.boolValue { args.append(flag) }
                else if invertible.contains(key) { args.append("--no-" + kebab(key)) }
            } else if let list = v as? [Any] {
                for item in list { args += [flag, try scalar(item, key: key)] }
            } else if let map = v as? [String: Any] {
                for k in map.keys.sorted() { args += [flag, "\(k)=\(try scalar(map[k]!, key: key))"] }
            } else {
                args += [flag, try scalar(v, key: key)]
            }
        }
        return args
    }
}

// MARK: - inspection

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print duration, size, fps, clicks and markers as JSON.")
    @Argument var file: String
    func run() async throws { try printJSON(try await Inspect.info(path: absURL(file).path)) }
}

struct Changes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the moments the picture changes (JSON), ignoring the cursor.",
        discussion: """
            Each entry has start/end (source seconds), area (largest fraction of the
            frame that changed between samples) and box (normalized x,y,width,height of
            everything that changed). Use it to time cursor scripts and zooms, e.g.
            --zoom src:START-END:rect=X,Y,W,H straight from an entry.
            """)
    @Argument var file: String
    @Option(help: "Brightness difference (0–255) a cell must change by to count.")
    var threshold: Double = 8
    @Option(help: "Ignore changes smaller than this fraction of the frame.")
    var minArea: Double = 0.0004
    @Option(help: "Frames per second to compare.")
    var fps: Double = 20
    @Option(help: "Merge changes separated by less than this many seconds.")
    var gap: Double = 0.3
    func run() async throws {
        try printJSON(try await ReelKit.Changes.detect(path: absURL(file).path, threshold: threshold,
                                                       minArea: minArea, fps: fps, mergeGap: gap))
    }
}

struct Frame: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save one source frame as PNG.")
    @Argument var file: String
    @Option(help: "Time in seconds.") var at: Double = 0
    @Option(help: "Crop x,y,w,h in source px (or %) to read small text.") var crop: String?
    @Option(help: "Downscale to at most this width.") var width: Int?
    @Option(name: .shortAndLong) var output: String = "frame.png"
    func run() async throws {
        let out = absURL(output)
        var img = try await Stills.frame(path: absURL(file).path, at: at)
        if let crop { img = try Stills.crop(img, crop) }
        try Stills.writePNG(img, to: out, maxWidth: width)
        print(out.path)
    }
}

struct Sheet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save a contact sheet of timestamped thumbnails (clicks circled in red).")
    @Argument var file: String
    @Option(help: "Seconds between frames.") var every: Double?
    @Option(help: "Number of frames (default 12).") var count: Int?
    @Option(help: "Exact times, comma-separated (e.g. 5.5,25.3,27).") var at: String?
    @Option(help: "Crop x,y,w,h in source px (or %) to read small text.") var crop: String?
    @Option(help: "Columns.") var columns = 4
    @Option(help: "Sheet width in px.") var width = 1800
    @Flag(help: "Overlay a 10% coordinate grid.") var grid = false
    @Option(name: .shortAndLong) var output: String = "sheet.png"
    func run() async throws {
        let path = absURL(file).path
        let info = try await Inspect.info(path: path)
        var clicks = (info.events?.clicks ?? []).map { (t: $0.t, x: $0.x, y: $0.y) }
        if let crop {
            // Re-map click rings into the cropped frame.
            let r = try Parse.crop(crop, sourceWidth: Double(info.width), sourceHeight: Double(info.height))
            clicks = clicks.map { c in
                (t: c.t, x: (c.x * Double(info.width) - r.x) / r.width, y: (c.y * Double(info.height) - r.y) / r.height)
            }.filter { (0...1).contains($0.x) && (0...1).contains($0.y) }
        }
        let out = absURL(output)
        let times = try at.map(parseTimes) ?? Inspect.sampleTimes(duration: info.duration, every: every, count: count)
        try await Inspect.contactSheet(
            times: times,
            frame: { t in
                let img = try await Stills.frame(path: path, at: t)
                return try crop.map { try Stills.crop(img, $0) } ?? img
            },
            clicks: clicks, columns: columns, width: width, grid: grid, to: out)
        print(out.path)
    }
}

struct Formats: ParsableCommand {
    static let text = """
        EVENTS SIDECAR  (<clip>.events.json, written by `reel record`, `reel cursor`)
          {
            "version": 1,
            "captureRect": {"x","y","width","height"},  // captured area, screen points
            "window": {"x","y","width","height"},       // the app window (= captureRect, or inside it for --display --app)
            "pointPixelScale": 2,                       // video pixels per point
            "samples": [{"t": 0.008, "x": 0.41, "y": 0.22, "down": false}, …],
                // ~120/s. t = source seconds; x/y = 0–1 of the frame, top-left origin;
                // outside 0–1 = pointer not over the capture. down = left button held.
            "shapes": [{"t": 3.2, "shape": "ibeam"}],   // arrow|ibeam|hand|crosshair (arrow before first)
            "markers": [{"label": "open-palette", "t": 4.1}],   // reel mark, --marks-file, mark --import
            "snapshots": [{"t": 4.1, "marker": "open-palette", "elements": [
                {"role": "AXButton", "label": "Highlight", "frame": {…}, "center": [x, y], …}]}],
                // record --ax-snapshots: at t=0 and each marker; frames are 0–1 of the window
            "patches": [{"image": "raw.titlebar.png", "x": 0, "y": 0, "width": 180, "height": 80,
                         "start": 2.01, "end": null, "feather": 16}],
                // record --clean-titlebar: drawn over the source (px) by `reel edit`, before crop
                // and zoom; one per capture segment; --no-recorded-patches to skip
            "startedAt": 1762859000.12,                 // Unix time of t=0
            "cursorInVideo": false,                     // was the system cursor captured?
            "synthetic": true                           // generated from a cursor script
          }
          Clicks are derived from samples (each false→true of "down" inside the frame).

        CURSOR SCRIPT  (`reel cursor --script`, `edit --cursor-script`, scene "cursorScript")
          A JSON array of steps (or {"steps": [...]}, plus "setup": [...] for reel act). "at" is source seconds or a marker
          reference: "name", "name+0.3", "name-0.2".
            {"at": 1.0, "move": [0.5, 0.5], "over": 0}       first move places the cursor
            {"at": 4.3, "move": [0.435, 0.025], "over": 0.8} eased, arriving at "at"
            {"at": 4.35, "click": true}                      press+release where it is
            {"at": 6.0, "click": [0.6, 0.4]}                 glide there (0.35s), then click
            {"at": 14.6, "drag": [[0.35,0.37],[0.55,0.37]], "over": 1.0}
                                                             press at "at", linear, release
            {"at": 9.0, "down": true}   {"at": 9.4, "up": true}
            {"at": 12.0, "shape": "ibeam"}                   arrow | ibeam | hand | crosshair
            {"at": 20.0, "hide": true}  {"at": 21.0, "show": true}
            {"at": 3.0, "mark": "intro-done"}                define a marker (numeric "at")
            {"at": 5, "click": {"label": "Highlight", "role": "button", "anchor": [0.5, 0.5]}}
                element target: from record --ax-snapshots (drawing) or found live (reel act)
            {"at": 6, "click": true, "count": 2}             double-click
          reel act only (ignored when drawing):
            {"at": 7, "type": "Hello"}  {"at": 8, "key": "cmd+s"}  {"at": 9, "scroll": [0, 400]}
            {"setup": [steps…], "steps": [steps…]}   setup runs first on act's own clock, before
                capture; if the recording waits on --start-on, act then sends that marker and
                the steps follow the recording's clock. "setup": [] = send it right away.
          Coordinates: 0–1 of the captured frame, or strings "640pt" / "1280px".
          {"coordinates": "window", "steps": [...]} makes them 0–1 of the app's window instead
            (the sidecar "window" rect), so one script fits window and `--display --app` takes,
            drawn or performed. Element targets are always found in the app window.
          reel act without --now follows the recording's clock; if the recording is waiting
            on --start-on, act waits for capture to start.
          Defaults: move "over" 0.6s, drag "over" 0.8s.

        PRESETS  read in order, later files winning field by field:
          ~/.config/reel/presets.json, then ./reel.json (working directory),
          then, under `reel run`, reel.json beside the scene file.
          {"promo": {"padding": 96, "background": "#1d2b64,#f8cdda", "cornerRadius": 24,
                     "shadow": true, "size": "1920x1080", "cursor": 1.8, "clickEffect": true,
                     "fadeIn": 0.4, "fadeOut": 0.6, "fps": 60, "codec": "h264",
                     "zoomEase": 0.6, "transition": "crossfade:0.6", "crop": "0,104,2940,1742"}}
          or the same under {"presets": {...}}. Use with `reel edit --preset promo`.

        SCENE  (`reel run scene.json`)
          {"prepare": ["shell command", …],      // before launch; a failure fails the take
           "record": {<reel record flags, camelCase>,
                      "startOn": "ready", "stopOn": "done", "tail": 1.5, "timeout": 60},
           "cursorScript": "moves.json" | [steps…],
           "act": "act.json" | {"steps": […]},   // performed with real input while recording
           "cursorFrom": "script",                // with "act": draw cursorScript, not the recorded pointer
           "actCountdown": 3, "actRetries": 2,    // with "act": hands-off banner; redo aborted takes
           "edit": {"trim": "1.2-22" | [1.2, 22], "input": "raw.mov", <reel edit flags>,
                    "cut": ["asked+1..answered-0.3"], "speed": ["a..b=6"], "patch": ["img.png@0,0"]},
           "teardown": ["shell command", …]}     // always runs, after quitAfter
          or, for a still: {"prepare": …, "shot": {<reel shot flags>}, "teardown": …}
          Commands run with sh in the scene's folder. stdout lines KEY=VALUE from prepare
          become ${KEY} in any later string (and $KEY in later commands); other output is
          shown. Built-ins: ${SCENE_DIR}, ${SCENE_NAME} (file name without .json), ${OUT}
          (the final output: edit, shot or record "output"), ${OUT_DIR}. Unknown names fall
          back to the environment, else the scene fails (teardown still runs).
          `reel run scene.json --edit-only` redoes the edit (no prepare/teardown); it expands
          only the edit, cursor script and record "output", using prepare's values saved by
          the last full run in .<scene>.vars.json beside the scene;
          `--preview check.png` renders a contact sheet instead of exporting.

        MARKER TIMING  (record/shot --start-on)
          reel launches the app and waits; t=0 is when capture starts after the start
          marker (about 0.15s after it). Markers sent while waiting are kept with negative
          times (the start marker itself included); references to them still work, and
          zooms clamp to 0. Exit codes: 1 start marker timed out (nothing recorded),
          3 a --duration take ended short, 4 the stop marker timed out (file kept).
        """
    static let configuration = CommandConfiguration(
        abstract: "Describe reel's JSON files: events sidecar, cursor scripts, presets, scenes.",
        discussion: text)
    func run() throws { print(Self.text) }
}
