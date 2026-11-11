import Foundation
import Testing
@testable import ReelKit

@Suite struct ParseTests {
    @Test func clipSpecs() {
        #expect(Parse.clipSpec("a.mov").start == nil)
        let t = Parse.clipSpec("/x/a.mov:2.5-8")
        #expect(t.path == "/x/a.mov" && t.start == 2.5 && t.end == 8)
        #expect(Parse.clipSpec("a.mov:3-").end == nil)
        #expect(Parse.clipSpec("a.mov:-10").start == nil)
        #expect(Parse.clipSpec("a.mov:-10").end == 10)
    }

    @Test func zoomSpecs() throws {
        let z = try Parse.zoom("2-5.5:2@0.7,0.3")
        #expect(z == .init(start: 2, end: 5.5, scale: 2, target: .point(x: 0.7, y: 0.3)))
        #expect(try Parse.zoom("1-2:1.5@cursor").target == .cursor)
        #expect(try Parse.zoom("1-2:1.5").target == .point(x: 0.5, y: 0.5))
        #expect(throws: (any Error).self) { try Parse.zoom("5-2:2") }
        #expect(throws: (any Error).self) { try Parse.zoom("1-2:0.5") }
    }

    @Test func crops() throws {
        let c = try Parse.crop("10%,0,50%,100%", sourceWidth: 2000, sourceHeight: 1000)
        #expect(c == .init(x: 200, y: 0, width: 1000, height: 1000))
        // Clamped to the source bounds.
        #expect(try Parse.crop("1800,0,900,900", sourceWidth: 2000, sourceHeight: 1000).width == 200)
    }

    @Test func indexedAndTransitions() throws {
        #expect(Parse.indexed("2=slide-left:0.5").index == 2)
        #expect(Parse.indexed("crossfade").index == nil)
        #expect(try Parse.transition("cut:3").duration == 0)
        #expect(try Parse.transition("wipe").duration == 0.6)
    }
}

@Suite struct TimelineTests {
    func plan(_ durations: [Double], transition: Double) -> EditPlan {
        EditPlan(
            clips: durations.map { .init(path: "", trimStart: 0, trimEnd: $0, crop: .init(x: 0, y: 0, width: 100, height: 100),
                                         sourceWidth: 100, sourceHeight: 100, speed: 1, hasEvents: false) },
            transitions: Array(repeating: .init(kind: .crossfade, duration: transition), count: durations.count - 1),
            zooms: [], zoomEase: 0.5,
            canvas: .init(width: 100, height: 100, padding: 0, background: ["#000000"], cornerRadius: 0, shadow: false),
            fadeIn: 0, fadeOut: 0, fps: 30, mute: true)
    }

    @Test func overlapsShortenTimeline() {
        let p = plan([5, 4, 3], transition: 1)
        #expect(p.clipStarts == [0, 4, 7])
        #expect(p.totalDuration == 10)
        #expect(p.activeClips(at: 4.5) == [0, 1])
        #expect(p.activeClips(at: 6) == [1])
        #expect(p.sourceTime(clip: 1, at: 6) == 2)
    }

    @Test func zoomKeyframesPanBetweenTouchingZooms() throws {
        var p = plan([10], transition: 0)
        p.zooms = [.init(start: 1, end: 3, scale: 2, target: .point(x: 0.2, y: 0.2)),
                   .init(start: 3, end: 6, scale: 2, target: .point(x: 0.8, y: 0.8))]
        let c = try Composer(plan: p)
        #expect(c.zoomState(at: 0.5).scale == 1)
        #expect(c.zoomState(at: 2).scale == 2)
        // Joined zooms never drop back to 1× between targets.
        let mid = c.zoomState(at: 3)
        #expect(mid.scale == 2 && mid.x > 0.2 && mid.x < 0.8)
        #expect(c.zoomState(at: 7).scale == 1)
    }

    @Test func autoZoomMergesClickBursts() {
        let z = EditPlan.autoZooms(clicks: [(1, 0.1, 0.1), (2, 0.2, 0.2), (9, 0.5, 0.5)], scale: 2)
        #expect(z.count == 2)
        #expect(z[0].target == .cursor)
        #expect(z[1].target == .point(x: 0.5, y: 0.5))
    }
}

@Suite struct MarkerAndZoomSpecTests {
    let markers: [RecordingEvents.Marker] = [.init(label: "step", t: 2), .init(label: "step-1", t: 5)]

    @Test func timeRefs() throws {
        #expect(try TimeRef.resolve("3.5", markers: markers) == 3.5)
        #expect(try TimeRef.resolve("step", markers: markers) == 2)
        #expect(try TimeRef.resolve("step-1", markers: markers) == 5)          // longest label wins
        #expect(try TimeRef.resolve("step-1-0.5", markers: markers) == 4.5)
        #expect(try TimeRef.resolve("step+0.25", markers: markers) == 2.25)
        #expect(throws: (any Error).self) { try TimeRef.resolve("nope", markers: markers) }
    }

    @Test func zoomSpecs() throws {
        let a = try Parse.zoomSpec("src:12.2-22.5:rect=0.28,0.1,0.48,0.5")
        #expect(a.source && a.start == "12.2" && a.end == "22.5" && a.scale == nil)
        #expect(a.target == .rect(0.28, 0.1, 0.48, 0.5))
        let b = try Parse.zoomSpec("highlight-1..highlight-2+0.5:1.7@cursor")
        #expect(b.source && b.start == "highlight-1" && b.end == "highlight-2+0.5" && b.target == .cursor)
        let c = try Parse.zoomSpec("2=3-7:2@0.25,0.4")
        #expect(c.clip == 2 && !c.source && c.scale == 2 && c.target == .point(0.25, 0.4))
        #expect(throws: (any Error).self) { try Parse.zoomSpec("a-b:2") }   // marker names need ..
        #expect(throws: (any Error).self) { try Parse.zoomSpec("5-2:2") }
    }

    func plan(trimStart: Double, padding: Double = 0) -> EditPlan {
        EditPlan(
            clips: [.init(path: "", trimStart: trimStart, trimEnd: 20, crop: .init(x: 0, y: 0, width: 1000, height: 500),
                          sourceWidth: 1000, sourceHeight: 500, speed: 1, hasEvents: false)],
            transitions: [], zooms: [], zoomEase: 0.5,
            canvas: .init(width: Int(1000 + 2 * padding), height: Int(500 + 2 * padding), padding: padding,
                          background: ["#000000"], cornerRadius: 0, shadow: false),
            fadeIn: 0, fadeOut: 0, fps: 30, mute: true)
    }

    @Test func sourceZoomsSurviveRetrims() throws {
        for trim in [0.0, 4.0] {
            let p = plan(trimStart: trim, padding: 100)
            let z = try Planner.resolve(try Parse.zoomSpec("src:10-12:2@0.5,0.5"), plan: p, composer: try Composer(plan: p))
            #expect(abs(z.start - (10 - trim)) < 1e-9 && abs(z.end - (12 - trim)) < 1e-9)
            // Source centre → output centre even with padding.
            #expect(z.target == .point(x: 0.5, y: 0.5))
        }
    }

    @Test func rectZoomFitsRegion() throws {
        let p = plan(trimStart: 0)
        let z = try Planner.resolve(try Parse.zoomSpec("src:1-3:rect=0.25,0.25,0.5,0.5"), plan: p, composer: try Composer(plan: p))
        #expect(z.scale == 1.84)    // 1/0.5 with 8% breathing room
        #expect(z.target == .point(x: 0.5, y: 0.5))
    }
}

@Suite struct CursorScriptTests {
    func events(_ json: String, duration: Double = 6) throws -> RecordingEvents {
        try CursorScript.parse(Data(json.utf8)).events(base: nil, pointsSize: (1000, 500), pointPixelScale: 2, duration: duration)
    }

    func at(_ ev: RecordingEvents, _ t: Double) -> RecordingEvents.CursorSample { ev.sample(at: t)! }

    @Test func movesEaseAndArrive() throws {
        let ev = try events("""
            [{"at": 0, "move": [0.1, 0.1], "over": 0},
             {"at": 2, "move": [0.9, 0.5], "over": 1}]
            """)
        #expect(at(ev, 0.5).x == 0.1)                       // before the move starts
        let mid = at(ev, 1.5)
        #expect(abs(mid.x - 0.5) < 0.01)                    // eased, symmetric midpoint
        #expect(at(ev, 1.1).x < 0.12)                       // slow start
        #expect(at(ev, 2.5).x == 0.9 && at(ev, 2.5).y == 0.5)
        #expect(ev.synthetic == true)
    }

    @Test func clicksDragsUnitsAndShapes() throws {
        let ev = try events("""
            [{"at": 0, "move": ["500pt", "250pt"], "over": 0},
             {"at": 1, "click": true},
             {"at": 2, "drag": [[0.2, 0.2], ["1600px", 0.2]], "over": 1},
             {"at": 2.5, "shape": "ibeam"},
             {"at": 4, "mark": "done"},
             {"at": "done+0.5", "click": [0.3, 0.3]}]
            """)
        #expect(at(ev, 0.5).x == 0.5 && at(ev, 0.5).y == 0.5)   // points → normalized
        #expect(ev.clicks.count == 3)
        #expect(at(ev, 2.5).down && abs(at(ev, 2.5).x - 0.5) < 0.01)   // linear drag, half way
        #expect(abs(at(ev, 3.2).x - 0.8) < 1e-6)                        // 1600px = 800pt = 0.8
        #expect(ev.shape(at: 2) == .arrow && ev.shape(at: 3) == .ibeam)
        #expect(ev.markers?.first?.label == "done")
        #expect(abs(ev.clicks.last!.t - 4.5) < 0.01 && ev.clicks.last!.x == 0.3)
    }

    @Test func overlappingMoveGlidesAfterPreviousStep() throws {
        var warnings: [String] = []
        let ev = try CursorScript.parse(Data("""
            [{"at": 0, "move": [0.1, 0.1], "over": 0},
             {"at": 1, "drag": [[0.1, 0.1], [0.5, 0.1]], "over": 1},
             {"at": 1.5, "move": [0.9, 0.9], "over": 0.4}]
            """.utf8)).events(base: nil, pointsSize: (1000, 500), pointPixelScale: 2, duration: 4) { warnings.append($0) }
        #expect(warnings.count == 1)
        #expect(at(ev, 2.0).x == 0.5)                      // drag finished first
        let mid = at(ev, 2.2).x
        #expect(mid > 0.5 && mid < 0.9)                     // then glides, no jump
        #expect(at(ev, 2.5).x == 0.9)
    }

    @Test func hideParksOutsideFrame() throws {
        let ev = try events("""
            [{"at": 0, "move": [0.5, 0.5], "over": 0}, {"at": 1, "hide": true}, {"at": 2, "show": true}]
            """)
        #expect(at(ev, 1.5).x < 0 && at(ev, 2.5).x == 0.5)
    }

    @Test func errorsNameTheStep() {
        #expect(throws: (any Error).self) { try events(#"[{"at": "missing", "click": true}]"#) }
        #expect(throws: (any Error).self) { try events(#"[{"at": 1, "click": true}]"#) }   // never placed
        #expect(throws: (any Error).self) { try events(#"[{"at": 1, "move": ["5em", 0]}]"#) }
    }
}

@Suite struct MiscTests {
    @Test func presetsOverlayFieldByField() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reel-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let user = dir.appendingPathComponent("user.json"), project = dir.appendingPathComponent("reel.json")
        try #"{"promo": {"padding": 96, "shadow": true, "codec": "hevc"}}"#.write(to: user, atomically: true, encoding: .utf8)
        try #"{"presets": {"promo": {"codec": "h264"}}}"#.write(to: project, atomically: true, encoding: .utf8)
        let p = try Presets.named("promo", files: [user, project])
        #expect(p.padding == 96 && p.shadow == true && p.codec == "h264")
        #expect(throws: (any Error).self) { try Presets.named("missing", files: [user]) }
    }

    @Test func shellWords() throws {
        #expect(try ShellWords.split(#"-AppleLanguages "(en)" --name 'a b' x\ y"#) == ["-AppleLanguages", "(en)", "--name", "a b", "x y"])
        #expect(throws: (any Error).self) { try ShellWords.split("\"open") }
    }

    @Test func changesCollapse() {
        let d: [Changes.Diff] = [
            .init(t: 1.0, area: 0.01, box: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1)),
            .init(t: 1.05, area: 0.02, box: .init(x: 0.15, y: 0.1, width: 0.2, height: 0.1)),
            .init(t: 1.1, area: 0, box: nil),
            .init(t: 3.0, area: 0.0001, box: .init(x: 0, y: 0, width: 0.01, height: 0.01)),   // below minArea
            .init(t: 5.0, area: 0.05, box: .init(x: 0.5, y: 0.5, width: 0.1, height: 0.1)),
        ]
        let c = Changes.collapse(d, minArea: 0.001, gap: 0.3, step: 0.05)
        #expect(c.count == 2)
        #expect(c[0].start == 0.95 && c[0].end == 1.05 && c[0].area == 0.02)
        #expect(c[0].box == .init(x: 0.1, y: 0.1, width: 0.25, height: 0.1))
    }
}

@Suite struct AccessibilityScriptTests {
    func element(_ label: String, _ role: String, x: Double, y: Double, w: Double, h: Double) -> Accessibility.Element {
        .init(role: role, subrole: nil, label: label, title: label, description: nil, value: nil, identifier: nil,
              frame: .init(x: x, y: y, width: w, height: h), center: [x + w / 2, y + h / 2],
              screenFrame: .init(x: 0, y: 0, width: 1, height: 1), enabled: true)
    }

    @Test func elementTargetsResolveFromSnapshots() throws {
        var base = RecordingEvents(captureRect: .init(x: 0, y: 0, width: 1000, height: 500), pointPixelScale: 2, samples: [])
        base.snapshots = [
            .init(t: 0, marker: nil, elements: [element("Highlight", "AXButton", x: 0.1, y: 0.1, w: 0.2, h: 0.1)]),
            .init(t: 3, marker: "moved", elements: [element("Highlight", "AXButton", x: 0.6, y: 0.6, w: 0.2, h: 0.1)]),
        ]
        let script = try CursorScript.parse(Data("""
            [{"at": 0, "move": [0.5, 0.5], "over": 0},
             {"at": 1, "click": {"label": "highlight", "role": "button"}, "count": 2},
             {"at": 4, "move": {"label": "Highlight", "anchor": [0, 0]}, "over": 0.5}]
            """.utf8))
        let ev = try script.events(base: base, pointsSize: (1000, 500), pointPixelScale: 2, duration: 5)
        #expect(ev.clicks.count == 2)                                   // double-click
        #expect(abs(ev.clicks[0].x - 0.2) < 1e-6 && abs(ev.clicks[0].y - 0.15) < 1e-6)
        let p = ev.sample(at: 4.2)!
        #expect(abs(p.x - 0.6) < 1e-6 && abs(p.y - 0.6) < 1e-6)        // later snapshot, anchor top-left
        #expect(throws: (any Error).self) {
            try CursorScript.parse(Data(#"[{"at": 0, "move": {"label": "Nope"}}]"#.utf8))
                .events(base: base, pointsSize: (1000, 500), pointPixelScale: 2, duration: 1)
        }
    }

    @Test func findPrefersExactAndSmallest() {
        let els = [element("Highlight toolbar", "AXGroup", x: 0, y: 0, w: 1, h: 0.2),
                   element("Highlight", "AXButton", x: 0.1, y: 0.1, w: 0.1, h: 0.05)]
        #expect(Accessibility.find(els, label: "highlight").first?.role == "AXButton")
        #expect(Accessibility.find(els, label: "high", role: "group").count == 1)
    }

    @Test func keyCombos() throws {
        let (c, f) = try Keys.parse("cmd+shift+S")
        #expect(c == 1 && f.contains(.maskCommand) && f.contains(.maskShift))
        #expect(try Keys.parse("return").0 == 36)
        #expect(throws: (any Error).self) { try Keys.parse("hyper+x") }
        #expect(throws: (any Error).self) { try Keys.parse("cmd+nope") }
    }

    @Test func actStepsAreIgnoredWhenDrawing() throws {
        let ev = try CursorScript.parse(Data("""
            [{"at": 0, "move": [0.5, 0.5], "over": 0}, {"at": 1, "type": "hi"}, {"at": 2, "key": "cmd+s"}, {"at": 3, "scroll": [0, 200]}]
            """.utf8)).events(base: nil, pointsSize: (100, 100), pointPixelScale: 2, duration: 4)
        #expect(ev.clicks.isEmpty && ev.sample(at: 3.5)!.x == 0.5)
    }
}

@Suite struct RecordingRobustnessTests {
    @Test func markLines() throws {
        #expect(try MarkLine.parse("open palette 1762862400.25")! == ("open palette", 1762862400.25))
        #expect(try MarkLine.parse("saved\t12.5")! == ("saved", 12.5))
        #expect(try MarkLine.parse("  # comment") == nil)
        #expect(try MarkLine.parse("") == nil)
        #expect(throws: (any Error).self) { try MarkLine.parse("no-time-here") }
        #expect(throws: (any Error).self) { try MarkLine.parse("12.5") }
    }

    @Test func errorInfoKeepsDomainCodeAndChain() {
        let inner = NSError(domain: "inner", code: 7, userInfo: [NSLocalizedDescriptionKey: "deep"])
        let e = NSError(domain: "SCStreamErrorDomain", code: -3805,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown stream error", NSUnderlyingErrorKey: inner])
        let info = ErrorInfo(e)
        #expect(info.domain == "SCStreamErrorDomain" && info.code == -3805)
        #expect(info.underlying == ["inner 7: deep"])
        #expect(info.summary.contains("SCStreamErrorDomain -3805") && info.summary.contains("inner 7: deep"))
    }
}

@Suite struct SetupPhaseTests {
    @Test func marksShiftOntoCaptureClock() throws {
        var st = RecordingState(pid: 999_991, output: "/tmp/x.mov", startedAt: 1000)
        st.startOn = "ready"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reel-marks-999991.jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try? FileManager.default.removeItem(at: file)
        try st.append(.init(label: "early", t: 1.0))     // relative to arming
        try st.append(.init(label: "ready", t: 2.5))
        #expect(st.t0 == nil)
        #expect(st.readMarks().map(\.t) == [1.0, 2.5])
        st.captureStartedAt = 1002.6                     // capture began 2.6s after arming
        #expect(st.t0 == 1002.6)
        #expect(st.readMarks().map(\.t) == [-1.6, -0.1])
        // Negative markers still resolve as references.
        #expect(abs(try TimeRef.resolve("early+0.5", markers: st.readMarks()) + 1.1) < 1e-9)
    }

    @Test func scriptWithSetup() throws {
        let s = try CursorScript.parse(Data(#"{"setup": [{"at": 0, "key": "cmd+n"}], "steps": [{"at": 0, "move": [0.5, 0.5], "over": 0}, {"at": 1, "click": true}]}"#.utf8))
        #expect(s.setup?.count == 1 && s.steps.count == 2)
        // Drawing ignores setup.
        let ev = try s.events(base: nil, pointsSize: (100, 100), pointPixelScale: 2, duration: 2)
        #expect(ev.clicks.count == 1)
        #expect(try CursorScript.parse(Data(#"{"setup": []}"#.utf8)).steps.isEmpty)
        #expect(throws: (any Error).self) { try CursorScript.parse(Data(#"{"nope": 1}"#.utf8)) }
    }
}
