import Foundation

/// Named edit settings shared across a batch of clips. Read from
/// ~/.config/reel/presets.json and ./reel.json (the project file wins, field by
/// field). Either file is {"name": {...}} or {"presets": {"name": {...}}}.
public struct Preset: Codable, Sendable, Equatable {
    public var padding: Double?
    public var background: String?
    public var cornerRadius: Double?
    public var shadow: Bool?
    public var size: String?
    public var cursor: Double?
    public var clickEffect: Bool?
    public var fadeIn: Double?
    public var fadeOut: Double?
    public var fps: Int?
    public var codec: String?        // hevc | h264
    public var zoomEase: Double?
    public var transition: String?
    public var crop: String?

    public init() {}

    /// Fields set in `other` replace ours.
    public func overlaid(by other: Preset) -> Preset {
        var p = self
        p.padding = other.padding ?? padding
        p.background = other.background ?? background
        p.cornerRadius = other.cornerRadius ?? cornerRadius
        p.shadow = other.shadow ?? shadow
        p.size = other.size ?? size
        p.cursor = other.cursor ?? cursor
        p.clickEffect = other.clickEffect ?? clickEffect
        p.fadeIn = other.fadeIn ?? fadeIn
        p.fadeOut = other.fadeOut ?? fadeOut
        p.fps = other.fps ?? fps
        p.codec = other.codec ?? codec
        p.zoomEase = other.zoomEase ?? zoomEase
        p.transition = other.transition ?? transition
        p.crop = other.crop ?? crop
        return p
    }
}

public enum Presets {
    public static var userFile: URL {
        URL(fileURLWithPath: ("~/.config/reel/presets.json" as NSString).expandingTildeInPath)
    }
    public static var projectFile: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("reel.json")
    }

    static func read(_ url: URL) throws -> [String: Preset] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        struct Wrapped: Decodable { var presets: [String: Preset] }
        do {
            if let w = try? JSONDecoder().decode(Wrapped.self, from: data) { return w.presets }
            return try JSONDecoder().decode([String: Preset].self, from: data)
        } catch let e as DecodingError {
            throw ReelError.message("\(url.path): \(CursorScript.describe(e))")
        }
    }

    public static func all(files: [URL]? = nil) throws -> [String: Preset] {
        var out: [String: Preset] = [:]
        for f in files ?? [userFile, projectFile] {
            for (name, p) in try read(f) { out[name] = (out[name] ?? Preset()).overlaid(by: p) }
        }
        return out
    }

    public static func named(_ name: String, files: [URL]? = nil) throws -> Preset {
        let all = try all(files: files)
        guard let p = all[name] else {
            let where_ = (files ?? [userFile, projectFile]).map(\.path).joined(separator: " or ")
            throw ReelError.message("No preset '\(name)' in \(where_)" + (all.isEmpty ? "" : ". Available: \(all.keys.sorted().joined(separator: ", "))"))
        }
        return p
    }
}
