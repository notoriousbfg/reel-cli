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

@Suite struct CutSpeedPatchTests {
    let markers: [RecordingEvents.Marker] = [.init(label: "asked", t: 2), .init(label: "answered", t: 6)]
    func clip() -> EditPlan.Clip {
        .init(path: "/x.mov", trimStart: 0, trimEnd: 9, crop: .init(x: 0, y: 0, width: 100, height: 100),
              sourceWidth: 100, sourceHeight: 100, speed: 1, hasEvents: true)
    }
    func plan(_ o: EditOptions) throws -> EditPlan {
        let pieces = try Planner.split(clip(), n: 0, markers: markers, o)
        return EditPlan(clips: pieces.map(\.clip), transitions: pieces.dropFirst().map(\.join), zooms: [], zoomEase: 0.6,
                        canvas: .init(width: 100, height: 100, padding: 0, background: ["#000"], cornerRadius: 0, shadow: false),
                        fadeIn: 0, fadeOut: 0, fps: 60, mute: true)
    }

    @Test func rangesAndPatches() throws {
        #expect(try Parse.sourceRange("asked+1.0..answered-0.3", markers: markers) == (3.0, 5.7))
        #expect(try Parse.sourceRange("1.5..4", markers: []) == (1.5, 4))
        #expect(throws: (any Error).self) { try Parse.sourceRange("4..1", markers: []) }
        #expect(throws: (any Error).self) { try Parse.sourceRange("nope..4", markers: markers) }
        let p = try Parse.patch("/a/b@c.png@10,20,30,40:1.5-")
        #expect(p.image == "/a/b@c.png" && p.x == 10 && p.height == 40 && p.start == 1.5 && p.end == nil)
        #expect(try Parse.patch("i.png@5,6").width == -1)
        #expect(throws: (any Error).self) { try Parse.patch("i.png@5") }
    }

    @Test func cutKeepsSourceTime() throws {
        var o = EditOptions(); o.cuts = ["asked+1.0..answered-0.3"]
        let p = try plan(o)
        #expect(p.clips.map(\.trimStart) == [0, 5.7] && p.transitions.first?.kind == .crossfade)
        #expect(abs(p.totalDuration - (9 - 2.7 - 0.3)) < 1e-9)
        #expect(abs(p.outputTime(input: 0, source: 6.0) - 3.0) < 1e-9)       // after the cut
        #expect(abs(p.outputTime(input: 0, source: 4.0) - 2.7) < 1e-9)       // inside it → join
        #expect(abs(p.sourceTime(clip: 1, at: 3.0) - 6.0) < 1e-9)
    }

    @Test func speedRange() throws {
        var o = EditOptions(); o.speeds = ["asked+1.0..answered-0.3=6"]
        let p = try plan(o)
        #expect(p.clips.map(\.speed) == [1, 6, 1])
        #expect(abs(p.outputTime(input: 0, source: 5.7) - 3.45) < 1e-9)
        #expect(abs(p.sourceTime(clip: 1, at: 3.2) - 4.2) < 1e-9)
        var bad = EditOptions(); bad.cuts = ["2..4"]; bad.speeds = ["3..5=2"]
        #expect(throws: (any Error).self) { try plan(bad) }                 // overlap
        var start = EditOptions(); start.cuts = ["0..1"]
        #expect(try plan(start).clips.count == 1)                           // a cut at the start is a trim
    }
}

import AVFoundation
import CoreImage

@Suite struct SmoothZoomTests {
    /// A clip with frames only at `times` (like ScreenCaptureKit over a static window).
    static func sparseClip(_ url: URL, times: [Double], w: Int = 320, h: Int = 200) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        // Detailed picture (checkerboard + gradient) so any zoom change moves pixels.
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 9, "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!
        let grad = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputColor0": CIColor.red,
                                                                   "inputPoint1": CIVector(x: CGFloat(w), y: CGFloat(h)), "inputColor1": CIColor.blue])!.outputImage!
        let img = checker.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: grad]).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let ctx = CIContext()
        for t in times {
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
            ctx.render(img, to: pb!)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            ad.append(pb!, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: times.last! + 0.5, preferredTimescale: 600))
        await writer.finishWriting()
    }

    /// Mean absolute difference between consecutive output frames in [from, to].
    static func frameDiffs(_ url: URL, from: Double, to: Double) async throws -> (diffs: [Double], fps: Double) {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out); reader.startReading()
        var prev: [UInt8]?, diffs: [Double] = [], times: [Double] = []
        while let sb = out.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            times.append(t)
            guard t >= from, t <= to, let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            var cur: [UInt8] = []
            for y in stride(from: 0, to: h, by: 2) { for x in stride(from: 0, to: w, by: 2) { cur.append(base[y * bpr + x * 4 + 1]) } }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            if let p = prev { diffs.append(Double(zip(p, cur).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(cur.count)) }
            prev = cur
        }
        return (diffs, Double(times.count - 1) / ((times.last ?? 1) - (times.first ?? 0)))
    }

    @Test(arguments: [true, false]) func zoomOverStillClipChangesEveryFrame(hevc: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reel-smooth-\(getpid())-\(hevc ? "hevc" : "h264")")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("still.mov"), out = dir.appendingPathComponent("zoom.mp4")
        try await Self.sparseClip(clip, times: [0, 1.6, 2.8])            // 3 frames in 3.3s
        var o = EditOptions()
        o.inputs = [clip.path]; o.zooms = ["0.5-2.5:2@0.4,0.4"]; o.zoomEase = 0.6; o.fps = 60
        let plan = try await Planner.plan(o)
        try await Exporter.export(plan, to: out, hevc: hevc)
        // Ease in (0.5–1.1s) and ease out (1.9–2.5s): every output frame must differ.
        let (easeIn, fps) = try await Self.frameDiffs(out, from: 0.5 + 1.0 / 60, to: 1.1 - 1.0 / 60)
        let (easeOut, _) = try await Self.frameDiffs(out, from: 1.9 + 1.0 / 60, to: 2.5 - 1.0 / 60)
        #expect(abs(fps - 60) < 0.5)
        #expect(easeIn.count >= 30 && easeOut.count >= 30)
        #expect(easeIn.allSatisfy { $0 > 0.05 }, "identical frames during ease-in: \(easeIn.map { String(format: "%.2f", $0) })")
        #expect(easeOut.allSatisfy { $0 > 0.05 }, "identical frames during ease-out: \(easeOut.map { String(format: "%.2f", $0) })")
    }
}

@Suite struct WindowCoordinateTests {
    @Test func windowCoordinatesMapIntoDisplayCapture() throws {
        // Display capture 1000×800 pt at origin; app window at (200,100) 400×300.
        var base = RecordingEvents(captureRect: .init(x: 0, y: 0, width: 1000, height: 800), pointPixelScale: 2, samples: [], cursorInVideo: false)
        base.window = .init(x: 200, y: 100, width: 400, height: 300)
        let json = #"{"coordinates": "window", "steps": [{"at": 0, "move": [0.5, 0.5]}, {"at": 1, "move": [1, 1], "over": 0.5}]}"#
        let script = try CursorScript.parse(Data(json.utf8), name: "t")
        let ev = try script.events(base: base, pointsSize: (1000, 800), pointPixelScale: 2, duration: 2)
        let first = try #require(ev.samples.first), last = try #require(ev.samples.last)
        #expect(abs(first.x - 0.4) < 1e-3 && abs(first.y - 0.3125) < 1e-3)    // (400,250)
        #expect(abs(last.x - 0.6) < 1e-3 && abs(last.y - 0.5) < 1e-3)         // (600,400)
        #expect(ev.window?.x == 200 && ev.window?.width == 400)
    }

    @Test func badCoordinatesValueRejected() {
        #expect(throws: (any Error).self) { try CursorScript.parse(Data(#"{"coordinates": "screen", "steps": []}"#.utf8), name: "t") }
    }
}

@Suite struct ZoomFocusTests {
    /// A zoom towards a region near the frame's edge must grow about one fixed point
    /// for the whole ease, not head for the corner and then slide.
    @Test func edgeZoomKeepsOneFocalPoint() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reel-focus-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("still.mov")
        try await SmoothZoomTests.sparseClip(clip, times: [0, 2, 4])
        var o = EditOptions()
        o.inputs = [clip.path]; o.zooms = ["1-4:1.4@0.47,0.29"]; o.zoomEase = 0.6
        let composer = try Composer(plan: try await Planner.plan(o))
        var focus: [(Double, Double)] = []
        for k in 1..<36 {
            let z = composer.zoomState(at: 1 + 0.6 * Double(k) / 36)
            let w = 1 / z.scale
            #expect(z.x - w / 2 >= -1e-9 && z.x + w / 2 <= 1 + 1e-9 && z.y - w / 2 >= -1e-9)
            focus.append(((z.x - w / 2) / (1 - w), (z.y - w / 2) / (1 - w)))   // the point that stays put
        }
        let fx = focus.map(\.0), fy = focus.map(\.1)
        #expect(fx.max()! - fx.min()! < 1e-6, "focal x drifts: \(fx.min()!)…\(fx.max()!)")
        #expect(fy.max()! - fy.min()! < 1e-6, "focal y drifts: \(fy.min()!)…\(fy.max()!)")
        let end = composer.zoomState(at: 2.5)
        #expect(abs(end.scale - 1.4) < 1e-6 && abs(end.x - 0.47) < 1e-6)
    }
}

@Suite struct PatchToneTests {
    static func rgb(_ image: CIImage, at p: CGPoint) -> [Double] {
        var px = [UInt8](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: p.x, y: p.y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return px.prefix(3).map { Double($0) / 255 }
    }

    /// A still of a light title bar with a red dot, over a frame dimmed to half: the
    /// bar matches the frame and the dot keeps its hue, darker.
    @Test func stillDimsWithTheFrame() {
        let r = CGRect(x: 0, y: 0, width: 180, height: 80)
        let dot = CIImage(color: CIColor(red: 1, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 20, y: 30, width: 20, height: 20))
        let still = dot.composited(over: CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9)).cropped(to: r))
        let dim = CIImage(color: CIColor(red: 0.45, green: 0.45, blue: 0.45)).cropped(to: r)
        let out = Composer.toneMatched(still, to: dim)
        let bar = Self.rgb(out, at: CGPoint(x: 100, y: 40)), want = Self.rgb(dim, at: CGPoint(x: 100, y: 40))
        for (a, b) in zip(bar, want) { #expect(abs(a - b) < 0.02) }
        let d = Self.rgb(out, at: CGPoint(x: 30, y: 40)), before = Self.rgb(still, at: CGPoint(x: 30, y: 40))
        #expect(d[0] < before[0] - 0.2 && d[0] > d[1] + 0.2)
    }

    /// A pale scrim over a dark window: the bar lifts to meet the frame and the dot stays red.
    @Test func stillLiftsWithTheFrame() {
        let r = CGRect(x: 0, y: 0, width: 180, height: 80)
        let dot = CIImage(color: CIColor(red: 1, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 20, y: 30, width: 20, height: 20))
        let still = dot.composited(over: CIImage(color: CIColor(red: 0.06, green: 0.06, blue: 0.07)).cropped(to: r))
        let lit = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.13)).cropped(to: r)
        let out = Composer.toneMatched(still, to: lit)
        let bar = Self.rgb(out, at: CGPoint(x: 100, y: 40)), want = Self.rgb(lit, at: CGPoint(x: 100, y: 40))
        for (a, b) in zip(bar, want) { #expect(abs(a - b) < 0.02) }
        let d = Self.rgb(out, at: CGPoint(x: 30, y: 40))
        #expect(d[0] > 0.9 && d[1] < 0.4)
    }

    /// A frame that matches the still leaves it alone.
    @Test func unchangedWhenTheFrameMatches() {
        let r = CGRect(x: 0, y: 0, width: 180, height: 80)
        let still = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6)).cropped(to: r)
        let a = Self.rgb(Composer.toneMatched(still, to: still), at: CGPoint(x: 90, y: 40))
        let b = Self.rgb(still, at: CGPoint(x: 90, y: 40))
        for (x, y) in zip(a, b) { #expect(abs(x - y) < 0.02) }
    }
}
