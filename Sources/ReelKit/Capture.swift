import AVFoundation
import Foundation
import ScreenCaptureKit

/// Error details reported instead of a bare "Unknown stream error".
public struct ErrorInfo: Codable, Sendable, Equatable {
    public var domain: String
    public var code: Int
    public var description: String
    public var reason: String?
    public var underlying: [String]?

    public init(_ error: Error) {
        let ns = error as NSError
        domain = ns.domain
        code = ns.code
        description = ns.localizedDescription
        reason = ns.localizedFailureReason
        var chain: [String] = []
        var next = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        while let e = next, chain.count < 5 {
            chain.append("\(e.domain) \(e.code): \(e.localizedDescription)")
            next = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if let many = ns.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
            chain += many.map { "\($0.domain) \($0.code): \($0.localizedDescription)" }
        }
        underlying = chain.isEmpty ? nil : chain
    }

    /// "Unknown stream error (SCStreamErrorDomain -3805; underlying …)"
    public var summary: String {
        var s = "\(description) (\(domain) \(code)"
        if let reason { s += "; \(reason)" }
        if let underlying { s += "; underlying: " + underlying.joined(separator: "; ") }
        return s + ")"
    }
}

/// One SCStream writing one file. A recording is one or more segments: when
/// macOS stops a stream, the recorder starts a new segment and joins them.
final class CaptureSegment: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    let url: URL
    private var stream: SCStream!
    private var recording: SCRecordingOutput!
    private let lock = NSLock()
    private var startCont: CheckedContinuation<Void, Error>?
    private var _error: Error?
    private var _finished = false
    private var _stopped = false

    var error: Error? { lock.withLock { _error } }
    var finished: Bool { lock.withLock { _finished } }

    init(filter: SCContentFilter, config: SCStreamConfiguration, url: URL, hevc: Bool) throws {
        self.url = url
        super.init()
        try? FileManager.default.removeItem(at: url)
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = url
        rc.outputFileType = url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        rc.videoCodecType = hevc ? .hevc : .h264
        recording = SCRecordingOutput(configuration: rc, delegate: self)
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(recording)
    }

    /// Starts capture and waits until the file is actually being written.
    func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.withLock { startCont = c }
            stream.startCapture { [weak self] err in
                if let err { self?.fail(err) }
            }
        }
    }

    /// Stops capture (if macOS hasn't already) and waits for the file to be finalised.
    func stop(timeout: Double = 8) async {
        let alreadyStopped = lock.withLock { () -> Bool in let s = _stopped || _error != nil; _stopped = true; return s }
        if !alreadyStopped {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                stream.stopCapture { _ in c.resume() }
            }
        }
        _ = await waitFinished(timeout: timeout)
    }

    /// Waits for SCRecordingOutput to finish writing (it does so even after an error).
    func waitFinished(timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !finished && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return finished
    }

    /// Test hook (REEL_SIMULATE_STOP): stop the stream as if macOS had, with an error.
    func simulateStop() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            stream.stopCapture { _ in c.resume() }
        }
        fail(NSError(domain: "reel.simulated", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Simulated stream stop",
            NSUnderlyingErrorKey: NSError(domain: "reel.simulated.underlying", code: 42, userInfo: [NSLocalizedDescriptionKey: "test"]),
        ]))
    }

    private func fail(_ e: Error) {
        let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            if _error == nil { _error = e }
            let c = startCont; startCont = nil; return c
        }
        c?.resume(throwing: e)
    }

    // MARK: Delegates

    func recordingOutputDidStartRecording(_ r: SCRecordingOutput) {
        let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in let c = startCont; startCont = nil; return c }
        c?.resume()
    }
    func recordingOutputDidFinishRecording(_ r: SCRecordingOutput) { lock.withLock { _finished = true } }
    func recordingOutput(_ r: SCRecordingOutput, didFailWithError error: Error) {
        fail(error)
        lock.withLock { _finished = true }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { fail(error) }
}

/// Joins capture segments into one file, each at its real offset from t=0, so
/// the video stays in step with the cursor/marker timeline. Gaps (while a
/// stream restarted) hold the next segment's first frame.
enum SegmentJoiner {
    static func join(_ parts: [(url: URL, offset: Double)], to output: URL) async throws {
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ReelError.message("Cannot create composition track")
        }
        let ts: CMTimeScale = 6000
        func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: ts) }
        var cursor = 0.0
        for p in parts {
            let asset = AVURLAsset(url: p.url)
            guard let v = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = try await v.load(.timeRange)
            guard range.duration.seconds > 0 else { continue }
            let fps = Double(try await v.load(.nominalFrameRate))
            let frame = cm(1 / max(1, fps))
            let at = max(cursor, p.offset)
            if at - cursor > 0.001 {
                // Hold this segment's first frame across the restart gap. It is a keyframe,
                // so passthrough can repeat it (a segment's last frame usually isn't).
                var t = cursor
                while at - t > 0.0005 {
                    let d = min(frame.seconds, at - t)
                    try track.insertTimeRange(CMTimeRange(start: range.start, duration: cm(d)), of: v, at: cm(t))
                    t += d
                }
            }
            try track.insertTimeRange(range, of: v, at: cm(at))
            cursor = at + range.duration.seconds
        }
        guard cursor > 0 else { throw ReelError.message("No video was captured") }
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw ReelError.message("Cannot create export session")
        }
        try? FileManager.default.removeItem(at: output)
        try await session.export(to: output, as: output.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
    }
}
