import AppKit
import ApplicationServices
import Foundation

/// Optional features that read the UI through the Accessibility API
/// (`reel locate`, `record --ax-snapshots`, element targets in `reel act`).
/// Everything else in reel works without this permission.
public enum Accessibility {
    public static var trusted: Bool { AXIsProcessTrusted() }

    public static func require(_ feature: String) throws {
        if AXIsProcessTrusted() { return }
        // Shows the system prompt the first time.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        throw ReelError.message("""
            \(feature) needs Accessibility. Add your terminal app in System Settings › Privacy & Security › \
            Accessibility, then restart the terminal. (Recording and editing never need it.)
            """)
    }

    /// One UI element, with its frame in global screen points (top-left origin)
    /// and normalized to the window it belongs to.
    public struct Element: Codable, Sendable {
        public var role: String
        public var subrole: String?
        public var label: String          // best human-readable name
        public var title: String?
        public var description: String?
        public var value: String?
        public var identifier: String?
        public var frame: RecordingEvents.Rect          // normalized to the window
        public var center: [Double]                     // normalized [x, y]
        public var screenFrame: RecordingEvents.Rect    // global points
        public var enabled: Bool?
    }

    public struct WindowRef: Sendable {
        public var pid: Int32
        public var windowID: UInt32?
        public var frame: CGRect          // global points, top-left origin
        public var title: String?
    }

    /// Finds a window by id, or the largest on-screen window of `pid`.
    /// Uses CGWindowList, which needs no permission for frames.
    public static func window(pid: Int32?, windowID: UInt32?) throws -> WindowRef {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { throw ReelError.message("Cannot list windows") }
        var best: WindowRef?
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = w[kCGWindowOwnerPID as String] as? Int32,
                  let id = w[kCGWindowNumber as String] as? UInt32,
                  let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
            if let windowID, id != windowID { continue }
            if let pid, owner != pid { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard r.width > 50, r.height > 50 else { continue }
            let ref = WindowRef(pid: owner, windowID: id, frame: r, title: w[kCGWindowName as String] as? String)
            if best == nil || r.width * r.height > best!.frame.width * best!.frame.height { best = ref }
            if windowID != nil { break }
        }
        guard let best else {
            throw ReelError.message(windowID != nil ? "No on-screen window \(windowID!)" : "Process \(pid ?? 0) has no on-screen window")
        }
        return best
    }

    // MARK: AX helpers

    static func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let pv: AXValue = attr(e, kAXPositionAttribute), let sv: AXValue = attr(e, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// The AX window whose frame matches the CG window (AX has no public window id).
    static func axWindow(for ref: WindowRef) -> AXUIElement? {
        let app = AXUIElementCreateApplication(ref.pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        let windows: [AXUIElement] = attr(app, kAXWindowsAttribute) ?? []
        func distance(_ w: AXUIElement) -> CGFloat {
            guard let f = frame(w) else { return .infinity }
            let dx: CGFloat = abs(f.minX - ref.frame.minX) + abs(f.width - ref.frame.width)
            let dy: CGFloat = abs(f.minY - ref.frame.minY) + abs(f.height - ref.frame.height)
            return dx + dy
        }
        return windows.min(by: { distance($0) < distance($1) })
    }

    /// Every labelled, visible element in the window (breadth first, bounded).
    public static func elements(in ref: WindowRef, limit: Int = 4000, maxDepth: Int = 40) throws -> [Element] {
        try require("Element lookup")
        guard let win = axWindow(for: ref) else {
            throw ReelError.message("Accessibility can't see that window (is it on screen?)")
        }
        var out: [Element] = []
        var queue: [(AXUIElement, Int)] = [(win, 0)]
        var visited = 0
        let wr = ref.frame
        while !queue.isEmpty, visited < limit {
            let (e, depth) = queue.removeFirst()
            visited += 1
            let role: String = attr(e, kAXRoleAttribute) ?? ""
            if let f = frame(e), f.width > 0, f.height > 0, f.intersects(wr) {
                let title: String? = attr(e, kAXTitleAttribute)
                let desc: String? = attr(e, kAXDescriptionAttribute)
                let ident: String? = attr(e, kAXIdentifierAttribute)
                var value: String? = attr(e, kAXValueAttribute)
                if let v = value, v.count > 120 { value = String(v.prefix(120)) + "…" }
                let help: String? = attr(e, kAXHelpAttribute)
                let placeholder: String? = attr(e, kAXPlaceholderValueAttribute)
                let label = [title, desc, placeholder, help, value, ident].compactMap { $0 }.first { !$0.isEmpty }
                if let label, e != win {
                    let c = f.intersection(wr)
                    let n = RecordingEvents.Rect(x: r4((c.minX - wr.minX) / wr.width), y: r4((c.minY - wr.minY) / wr.height),
                                                 width: r4(c.width / wr.width), height: r4(c.height / wr.height))
                    out.append(Element(
                        role: role, subrole: attr(e, kAXSubroleAttribute), label: label,
                        title: nonEmpty(title), description: nonEmpty(desc), value: nonEmpty(value), identifier: nonEmpty(ident),
                        frame: n, center: [r4(n.x + n.width / 2), r4(n.y + n.height / 2)],
                        screenFrame: .init(x: f.minX, y: f.minY, width: f.width, height: f.height),
                        enabled: attr(e, kAXEnabledAttribute)))
                }
            }
            if depth < maxDepth, let kids: [AXUIElement] = attr(e, kAXChildrenAttribute) {
                queue.append(contentsOf: kids.map { ($0, depth + 1) })
            }
        }
        return out
    }

    static func r4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
    static func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }

    /// Elements matching a label (exact matches first, then contains), optionally by role.
    public static func find(_ elements: [Element], label: String, role: String? = nil) -> [Element] {
        let needle = label.lowercased()
        let wantRole = role.map { r -> String in
            let l = r.lowercased(); return l.hasPrefix("ax") ? l : "ax" + l
        }
        func names(_ e: Element) -> [String] {
            [e.label, e.title, e.description, e.value, e.identifier].compactMap { $0?.lowercased() }
        }
        let pool = elements.filter { wantRole == nil || $0.role.lowercased() == wantRole }
        let exact = pool.filter { names($0).contains(needle) }
        let partial = pool.filter { e in !names(e).contains(needle) && names(e).contains { $0.contains(needle) } }
        // Smaller elements first within each group: the button, not the toolbar around it.
        let bySize = { (a: Element, b: Element) in a.frame.width * a.frame.height < b.frame.width * b.frame.height }
        return exact.sorted(by: bySize) + partial.sorted(by: bySize)
    }
}

/// A labelled-element snapshot stored in the events sidecar, so cursor scripts
/// can target `{"label": "Highlight"}` instead of coordinates.
public struct ElementSnapshot: Codable, Sendable {
    public var t: Double
    public var marker: String?
    public var elements: [Accessibility.Element]
}

extension RecordingEvents {
    /// The element named `label` in the latest snapshot at or before `t` (or the first one).
    public func element(_ label: String, role: String?, index: Int = 0, at t: Double) throws -> Accessibility.Element {
        guard let snaps = snapshots, !snaps.isEmpty else {
            throw ReelError.message("Element \"\(label)\" needs UI snapshots: record with --ax-snapshots, or use `reel locate` for coordinates")
        }
        let snap = snaps.last(where: { $0.t <= t + 1e-6 }) ?? snaps[0]
        let found = Accessibility.find(snap.elements, label: label, role: role)
        guard found.indices.contains(index) else {
            let near = snap.elements.map(\.label).filter { $0.lowercased().contains(label.lowercased().prefix(3)) }.prefix(8)
            throw ReelError.message(String(format: "No element \"%@\"%@ in the snapshot at %.2fs", label, role.map { " (role \($0))" } ?? "", snap.t)
                + (near.isEmpty ? "" : ". Similar: \(near.joined(separator: ", "))"))
        }
        return found[index]
    }
}
