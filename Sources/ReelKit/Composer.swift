import CoreImage
import CoreText
import Foundation

/// Turns an `EditPlan` into a frame for any output time. This is the single
/// rendering path: export, previews and contact sheets of edits all use it.
public final class Composer: @unchecked Sendable {
    public let plan: EditPlan
    let events: [RecordingEvents?]
    let W: Double, H: Double
    let background: CIImage
    let placed: [CGRect]     // where each clip's content lands on the canvas (CI coords)
    let keyframes: [Keyframe]
    /// Per clip: drawn cursor sprite at that clip's output scale, and its clicks.
    let cursorSprites: [CursorSprite?]
    let clipClicks: [[RecordingEvents.Click]]
    let patchImages: [String: CIImage]
    let captionImages: [String: CIImage]

    public init(plan: EditPlan) throws {
        self.plan = plan
        W = Double(plan.canvas.width)
        H = Double(plan.canvas.height)
        events = try plan.clips.map { try $0.loadEvents() }

        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        let colors = try plan.canvas.background.map { CIColor(cgColor: try Parse.color($0)) }
        if colors.count >= 2 {
            background = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: H), "inputColor0": colors[0],
                "inputPoint1": CIVector(x: W * 0.35, y: 0), "inputColor1": colors[1],
            ])!.outputImage!.cropped(to: canvas)
        } else {
            background = CIImage(color: colors.first ?? .black).cropped(to: canvas)
        }

        let pad = plan.canvas.padding
        let area = canvas.insetBy(dx: pad, dy: pad)
        placed = plan.clips.map { c in
            let s = min(area.width / c.crop.width, area.height / c.crop.height)
            let w = c.crop.width * s, h = c.crop.height * s
            return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
        }
        keyframes = Self.buildKeyframes(plan.zooms, ease: plan.zoomEase)

        let placedRects = placed
        let evs = events
        cursorSprites = plan.clips.indices.map { i in
            guard let style = plan.cursor, let ev = evs[i] else { return nil }
            // Output pixels per screen point for this clip.
            let k = ev.pointPixelScale * placedRects[i].width / plan.clips[i].crop.width
            return CursorSprite(pixelsPerPoint: k * style.scale)
        }
        clipClicks = events.map { $0?.clicks ?? [] }
        var imgs: [String: CIImage] = [:]
        for p in plan.clips.flatMap(\.patches) where imgs[p.image] == nil {
            guard let img = CIImage(contentsOf: URL(fileURLWithPath: p.image)) else { throw ReelError.message("Cannot read patch image \(p.image)") }
            imgs[p.image] = img
        }
        patchImages = imgs
        var caps: [String: CIImage] = [:]
        for c in plan.captions where caps[c.text] == nil { caps[c.text] = Self.captionImage(c.text, canvasHeight: H) }
        captionImages = caps
    }

    /// A keystroke caption: white text on a dark rounded pill, sized to the canvas.
    static func captionImage(_ text: String, canvasHeight H: Double) -> CIImage? {
        let size = max(18, (H * 0.036).rounded())
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            .init(kCTKernAttributeName as String): size * 0.03,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let padX = size * 0.75, padY = size * 0.42
        let w = Int((textWidth + padX * 2).rounded(.up)), h = Int((ascent + descent + padY * 2).rounded(.up))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let box = CGRect(x: 0, y: 0, width: w, height: h)
        let radius = Double(h) * 0.3
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
        // Core Image blends in linear light, where a dark fill over a pale window reads
        // much lighter than its alpha suggests; hence nearly opaque.
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 0.94))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: box.insetBy(dx: 1, dy: 1), cornerWidth: radius - 1, cornerHeight: radius - 1, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        ctx.setLineWidth(max(1, size / 24))
        ctx.strokePath()
        ctx.textPosition = CGPoint(x: padX, y: padY + descent)
        CTLineDraw(line, ctx)
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    /// Captions showing at output time `t`, bottom centre of the content, over the zoom.
    func drawCaptions(at t: Double, over frame: CIImage) -> CIImage {
        var out = frame
        let pad = plan.canvas.padding
        // One at a time: a caption that starts while another is showing replaces it.
        if let c = plan.captions.last(where: { t >= $0.start && t < $0.end }) {
            guard let img = captionImages[c.text] else { return out }
            let alpha = max(0, min(1, (t - c.start) / 0.15, (c.end - t) / 0.25))
            let x = (W - img.extent.width) / 2, y = pad + (H - 2 * pad) * 0.06
            var placed = img.transformed(by: CGAffineTransform(translationX: x, y: y))
            if alpha < 0.999 {
                placed = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
            }
            out = placed.composited(over: out)
        }
        return out
    }

    /// `still` shifted to the tone `frame` has in the strip at the still's right edge,
    /// which the capture pill never covers. A still taken before a sheet or modal put a
    /// scrim over the window then changes with it: where the frame is darker the still
    /// is scaled down, where it is lighter (a pale scrim over a dark window) the
    /// difference is added, so the bar around the buttons always meets the footage.
    static func toneMatched(_ still: CIImage, to frame: CIImage) -> CIImage {
        let r = still.extent
        let strip = CGRect(x: r.maxX - r.width * 0.15, y: r.minY, width: r.width * 0.15, height: r.height * 0.85)
        func average(_ image: CIImage) -> CIImage {
            image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: strip)]).clampedToExtent()
        }
        func clamped(_ image: CIImage, alpha: CGFloat) -> CIImage {
            image.applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: alpha),
                                                              "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: alpha)])
        }
        /// a + b per channel for two opaque images (adding premultiplied pixels doubles
        /// alpha, which the matrix undoes without scaling the colour).
        func sum(_ a: CIImage, _ b: CIImage) -> CIImage {
            a.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 2, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 2, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 2, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5)])
        }
        let was = average(still), now = average(frame)
        // CIDivideBlendMode: background ÷ input, per channel.
        let gain = clamped(was.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: now]), alpha: 1)
        let negated = was.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0)])
        let lift = clamped(sum(now, negated), alpha: 1)
        let scaled = still.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gain])
        return clamped(sum(scaled.composited(over: CIImage.black), lift), alpha: 1)
            .applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: still])
            .cropped(to: r)
    }

    /// Draws clip `i`'s patches over its source frame (source pixels, before crop),
    /// so they move with zooms and crops like the footage under them.
    func patched(clip i: Int, source: CIImage, sourceTime st: Double) -> CIImage {
        let c = plan.clips[i]
        var out = source
        let sh = source.extent.height
        for p in c.patches where (p.start ?? -.infinity) <= st + 1e-6 && st < (p.end ?? .infinity) {
            guard let img = patchImages[p.image], img.extent.width > 0, img.extent.height > 0 else { continue }
            let t = CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY)
                .concatenating(.init(scaleX: p.width / img.extent.width, y: p.height / img.extent.height))
                .concatenating(.init(translationX: source.extent.minX + p.x, y: source.extent.minY + sh - p.y - p.height))
            var placed = img.transformed(by: t)
            if p.matchTone == true { placed = Self.toneMatched(placed, to: out) }
            if let f = p.feather, f > 0 {
                // Fade the inner (right, bottom) edges so tiny colour differences leave no seam.
                let r = placed.extent
                let right = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(x: r.maxX - f, y: 0), "inputColor0": CIColor.white,
                    "inputPoint1": CIVector(x: r.maxX, y: 0), "inputColor1": CIColor.black])!.outputImage!
                let bottom = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(x: 0, y: r.minY + f), "inputColor0": CIColor.white,
                    "inputPoint1": CIVector(x: 0, y: r.minY), "inputColor1": CIColor.black])!.outputImage!
                let mask = right.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: bottom]).cropped(to: r)
                out = placed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: mask])
            } else {
                out = placed.composited(over: out)
            }
        }
        return out.cropped(to: source.extent)
    }

    // MARK: Coordinate mapping

    /// Maps a point normalized to clip `i`'s *source* frame (top-left origin)
    /// into normalized output-frame coordinates (top-left origin).
    public func outputPoint(clip i: Int, sourceX: Double, sourceY: Double) -> (x: Double, y: Double) {
        let c = plan.clips[i]
        let u = (sourceX * c.sourceWidth - c.crop.x) / c.crop.width
        let v = (sourceY * c.sourceHeight - c.crop.y) / c.crop.height
        let r = placed[i]
        let topY = H - r.maxY
        return ((r.minX + u * r.width) / W, (topY + v * r.height) / H)
    }

    /// Recorded clicks for every clip, mapped onto the output timeline/frame.
    public func outputClicks() -> [(t: Double, x: Double, y: Double)] {
        let starts = plan.clipStarts
        var out: [(Double, Double, Double)] = []
        for (i, ev) in events.enumerated() {
            guard let ev else { continue }
            let c = plan.clips[i]
            for k in ev.clicks where k.t >= c.trimStart && k.t <= c.trimEnd {
                let p = outputPoint(clip: i, sourceX: k.x, sourceY: k.y)
                out.append((starts[i] + (k.t - c.trimStart) / c.speed, p.x, p.y))
            }
        }
        return out
    }

    func cursor(at t: Double) -> (x: Double, y: Double)? {
        guard let i = plan.activeClips(at: min(t, plan.totalDuration - 1e-3)).last, let ev = events[i],
              let p = ev.smoothedCursor(at: plan.sourceTime(clip: i, at: t)) else { return nil }
        return outputPoint(clip: i, sourceX: p.x, sourceY: p.y)
    }

    // MARK: Zoom keyframes

    struct Keyframe {
        var t: Double
        var scale: Double
        var target: EditPlan.ZoomTarget
    }

    /// Each zoom eases in, holds, and eases out. Zooms that touch or overlap
    /// become a pan from one target to the next instead of zooming out between.
    static func buildKeyframes(_ zooms: [EditPlan.Zoom], ease: Double) -> [Keyframe] {
        let sorted = zooms.sorted { $0.start < $1.start }
        var kfs: [Keyframe] = []
        for (i, z) in sorted.enumerated() {
            let e = min(ease, (z.end - z.start) / 2)
            let joinsPrev = i > 0 && z.start <= sorted[i - 1].end
            let joinsNext = i + 1 < sorted.count && sorted[i + 1].start <= z.end
            if !joinsPrev { kfs.append(.init(t: z.start, scale: 1, target: z.target)) }
            kfs.append(.init(t: joinsPrev ? max(z.start + e, kfs.last!.t + 0.01) : z.start + e, scale: z.scale, target: z.target))
            kfs.append(.init(t: max(z.end - e, kfs.last!.t + 0.001), scale: z.scale, target: z.target))
            if !joinsNext { kfs.append(.init(t: max(z.end, kfs.last!.t + 0.001), scale: 1, target: z.target)) }
        }
        return kfs
    }

    func resolve(_ target: EditPlan.ZoomTarget, at t: Double) -> (x: Double, y: Double) {
        switch target {
        case .point(let x, let y): return (x, y)
        case .cursor: return cursor(at: t) ?? (0.5, 0.5)
        }
    }

    /// Zoom scale and normalized target point at output time `t`.
    public func zoomState(at t: Double) -> (scale: Double, x: Double, y: Double) {
        let k = keyframes
        guard let first = k.first, t >= first.t, let last = k.last, t <= last.t else { return (1, 0.5, 0.5) }
        var i = 0
        while i + 1 < k.count && k[i + 1].t <= t { i += 1 }
        if i + 1 >= k.count {
            let p = resolve(k[i].target, at: t)
            return (k[i].scale, p.x, p.y)
        }
        let a = k[i], b = k[i + 1]
        let u = smoothstep((t - a.t) / (b.t - a.t))
        // Interpolate scale geometrically so zoom speed looks uniform.
        let s = a.scale * pow(b.scale / a.scale, u)
        // Interpolate the visible rectangle, not the target: each end's rectangle is
        // clamped to the frame, and its origin moves in proportion to its size. A zoom
        // in or out then grows about one fixed point the whole way (clamping the target
        // per frame made edge zooms head for the corner first, then slide sideways).
        func origin(_ k: Keyframe) -> (x: Double, y: Double) {
            let w = 1 / k.scale, p = resolve(k.target, at: t)
            return (min(max(p.x - w / 2, 0), 1 - w), min(max(p.y - w / 2, 0), 1 - w))
        }
        let oa = origin(a), ob = origin(b)
        let wa = 1 / a.scale, wb = 1 / b.scale, w = 1 / s
        let f = abs(wb - wa) > 1e-9 ? (w - wa) / (wb - wa) : u
        return (s, oa.x + (ob.x - oa.x) * f + w / 2, oa.y + (ob.y - oa.y) * f + w / 2)
    }

    /// Where a normalized output point lands after the zoom at time `t`.
    public func zoomedPoint(at t: Double, x: Double, y: Double) -> (x: Double, y: Double) {
        let z = zoomState(at: t)
        guard z.scale > 1.001 else { return (x, y) }
        let vw = 1 / z.scale, vh = 1 / z.scale
        let ox = min(max(z.x - vw / 2, 0), 1 - vw)
        let oy = min(max(z.y - vh / 2, 0), 1 - vh)
        return ((x - ox) * z.scale, (y - oy) * z.scale)
    }

    // MARK: Frame composition

    /// Content for clip `i` placed on a transparent canvas.
    func layer(clip i: Int, source original: CIImage, at t: Double) -> CIImage {
        let c = plan.clips[i]
        let source = c.patches.isEmpty ? original : patched(clip: i, source: original, sourceTime: plan.sourceTime(clip: i, at: t))
        let sh = source.extent.height
        let cropCI = CGRect(x: c.crop.x, y: sh - c.crop.y - c.crop.height, width: c.crop.width, height: c.crop.height)
        var img = source.cropped(to: cropCI)
            .transformed(by: CGAffineTransform(translationX: -cropCI.minX, y: -cropCI.minY))
        let r = placed[i]
        let s = r.width / c.crop.width
        if abs(s - 1) > 1e-3 {
            img = s < 1
                ? img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
                : img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        img = img.transformed(by: CGAffineTransform(translationX: r.minX - img.extent.minX, y: r.minY - img.extent.minY))
            .cropped(to: r)

        let radius = plan.canvas.cornerRadius
        if radius > 0 {
            let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: r), "inputRadius": radius, "inputColor": CIColor.white,
            ])!.outputImage!
            img = img.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
            ])
        }
        if plan.canvas.shadow {
            let blur = max(12, min(r.width, r.height) * 0.03)
            let shadow = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: r), "inputRadius": radius,
                "inputColor": CIColor(red: 0, green: 0, blue: 0, alpha: 0.55),
            ])!.outputImage!
                .applyingGaussianBlur(sigma: blur)
                .transformed(by: CGAffineTransform(translationX: 0, y: -blur * 0.6))
            img = img.composited(over: shadow)
        }
        return drawCursor(clip: i, at: t, over: img)
    }

    // MARK: Cursor overlay

    static let clickEffectDuration = 0.45

    /// Draws the recorded cursor (and click halos) for clip `i` over its layer.
    /// Drawn before the zoom so it scales with the footage. Hidden while the
    /// pointer is outside the cropped content.
    func drawCursor(clip i: Int, at t: Double, over img: CIImage) -> CIImage {
        guard let style = plan.cursor, let sprite = cursorSprites[i], let ev = events[i] else { return img }
        let c = plan.clips[i], r = placed[i]
        let st = plan.sourceTime(clip: i, at: t)
        func place(_ x: Double, _ y: Double) -> CGPoint? {
            let u = (x * c.sourceWidth - c.crop.x) / c.crop.width
            let v = (y * c.sourceHeight - c.crop.y) / c.crop.height
            guard (0...1).contains(u), (0...1).contains(v) else { return nil }
            return CGPoint(x: r.minX + u * r.width, y: r.maxY - v * r.height)
        }
        var out = img
        if style.clickEffect {
            for k in clipClicks[i] where k.t <= st && st - k.t < Self.clickEffectDuration {
                guard let p = place(k.x, k.y) else { continue }
                out = sprite.halo(at: p, progress: (st - k.t) / Self.clickEffectDuration).composited(over: out)
            }
        }
        // Light smoothing (±40ms) removes sampling jitter without visible lag.
        guard let pos = ev.smoothedCursor(at: st, window: 0.04), let p = place(pos.x, pos.y) else { return out }
        let pressed = ev.sample(at: st)?.down ?? false
        return sprite.cursor(ev.shape(at: st), at: p, pressed: pressed).composited(over: out)
    }

    public func image(at t: Double, sources: [Int: CIImage]) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        let active = plan.activeClips(at: t).filter { sources[$0] != nil }
        var frame: CIImage

        if active.count >= 2 {
            let a = active[0], b = active[1]
            let tr = plan.transitions[a]
            let start = plan.clipStarts[b]
            let p = smoothstep(tr.duration > 0 ? (t - start) / tr.duration : 1)
            frame = transition(tr.kind, p: p,
                               from: layer(clip: a, source: sources[a]!, at: t),
                               to: layer(clip: b, source: sources[b]!, at: t))
        } else if let i = active.first {
            frame = layer(clip: i, source: sources[i]!, at: t).composited(over: background)
        } else {
            frame = background
        }

        let z = zoomState(at: t)
        if z.scale > 1.001 {
            let vw = W / z.scale, vh = H / z.scale
            let cx = z.x * W, cy = (1 - z.y) * H
            let ox = min(max(cx - vw / 2, 0), W - vw)
            let oy = min(max(cy - vh / 2, 0), H - vh)
            frame = frame.cropped(to: CGRect(x: ox, y: oy, width: vw, height: vh))
                .transformed(by: CGAffineTransform(translationX: -ox, y: -oy).concatenating(.init(scaleX: z.scale, y: z.scale)))
        }

        if !plan.captions.isEmpty { frame = drawCaptions(at: t, over: frame) }

        var brightness = 1.0
        if plan.fadeIn > 0 { brightness = min(brightness, t / plan.fadeIn) }
        if plan.fadeOut > 0 { brightness = min(brightness, (plan.totalDuration - t) / plan.fadeOut) }
        brightness = max(0, min(1, brightness))
        if brightness < 0.999 {
            frame = frame.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: brightness, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: brightness, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: brightness, w: 0),
            ])
        }
        return frame.cropped(to: canvas)
    }

    private func transition(_ kind: EditPlan.TransitionKind, p: Double, from a: CIImage, to b: CIImage) -> CIImage {
        let bg = background
        func opacity(_ img: CIImage, _ alpha: Double) -> CIImage {
            img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
        }
        func moved(_ img: CIImage, _ dx: Double, _ dy: Double) -> CIImage {
            img.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        }
        switch kind {
        case .cut:
            return (p < 0.5 ? a : b).composited(over: bg)
        case .crossfade:
            return opacity(b, p).composited(over: a.composited(over: bg))
        case .fade:
            return p < 0.5 ? opacity(a, 1 - p * 2).composited(over: bg) : opacity(b, p * 2 - 1).composited(over: bg)
        case .slideLeft:
            return moved(b, (1 - p) * W, 0).composited(over: moved(a, -p * W, 0)).composited(over: bg)
        case .slideRight:
            return moved(b, -(1 - p) * W, 0).composited(over: moved(a, p * W, 0)).composited(over: bg)
        case .slideUp:
            return moved(b, 0, -(1 - p) * H).composited(over: moved(a, 0, p * H)).composited(over: bg)
        case .slideDown:
            return moved(b, 0, (1 - p) * H).composited(over: moved(a, 0, -p * H)).composited(over: bg)
        case .wipe:
            let revealed = b.composited(over: bg).cropped(to: CGRect(x: 0, y: 0, width: p * W, height: H))
            return revealed.composited(over: a.composited(over: bg))
        case .zoom:
            let s = 1 + 0.15 * p
            let grow = CGAffineTransform(translationX: -W / 2, y: -H / 2)
                .concatenating(.init(scaleX: s, y: s)).concatenating(.init(translationX: W / 2, y: H / 2))
            return opacity(b, p).composited(over: opacity(a.transformed(by: grow), 1 - p)).composited(over: bg)
        }
    }
}

@inline(__always) func smoothstep(_ x: Double) -> Double {
    let c = min(max(x, 0), 1)
    return c * c * (3 - 2 * c)
}
