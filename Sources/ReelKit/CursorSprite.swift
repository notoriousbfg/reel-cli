import AppKit
import CoreGraphics
import CoreImage
import Foundation

/// The macOS cursors (arrow, I-beam, pointing hand, crosshair) plus a click
/// halo, rasterised once at the output scale so they stay crisp at any size.
/// Images come from NSCursor, so they match the system exactly.
struct CursorSprite {
    struct Glyph { let image: CIImage; let hotspot: CGPoint }  // hotspot in CI pixel coords
    let glyphs: [CursorShape: Glyph]
    let pixelsPerPoint: Double

    init(pixelsPerPoint k: Double) {
        pixelsPerPoint = k
        var g: [CursorShape: Glyph] = [:]
        for shape in CursorShape.allCases {
            g[shape] = Self.system(shape, k) ?? (shape == .arrow ? Self.drawnArrow(k) : nil)
        }
        if g[.arrow] == nil { g[.arrow] = Self.drawnArrow(k) }
        glyphs = g
    }

    static func nsCursor(_ s: CursorShape) -> NSCursor {
        switch s {
        case .arrow: return .arrow
        case .ibeam: return .iBeam
        case .hand: return .pointingHand
        case .crosshair: return .crosshair
        }
    }

    /// Renders an NSCursor at `k` pixels per point.
    static func system(_ shape: CursorShape, _ k: Double) -> Glyph? {
        let c = nsCursor(shape)
        let size = c.image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let w = Int((size.width * k).rounded(.up)), h = Int((size.height * k).rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        c.image.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        // NSCursor.hotSpot is top-left origin in points.
        return Glyph(image: CIImage(cgImage: cg), hotspot: CGPoint(x: c.hotSpot.x * k, y: Double(h) - c.hotSpot.y * k))
    }

    /// Fallback arrow if NSCursor images are unavailable.
    static func drawnArrow(_ k: Double) -> Glyph {
        let outline: [CGPoint] = [(0, 0), (0, 16.5), (4.2, 12.6), (7, 19.2), (9.6, 18.1), (6.9, 11.7), (12.5, 11.7)]
            .map { CGPoint(x: $0.0, y: $0.1) }
        let pad = 5.0
        let w = Int(((12.5 + 2 * pad) * k).rounded(.up)), h = Int(((19.2 + 2 * pad) * k).rounded(.up))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: k, y: -k)
        ctx.translateBy(x: pad, y: pad)
        let path = CGMutablePath()
        path.addLines(between: outline)
        path.closeSubpath()
        ctx.setLineJoin(.round)
        ctx.setShadow(offset: CGSize(width: 0, height: -1.2 * k), blur: 3 * k, color: CGColor(gray: 0, alpha: 0.45))
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(2.4)
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        return Glyph(image: CIImage(cgImage: ctx.makeImage()!), hotspot: CGPoint(x: pad * k, y: Double(h) - pad * k))
    }

    /// The cursor with its hotspot at `p` (canvas coords); slightly smaller while pressed.
    func cursor(_ shape: CursorShape, at p: CGPoint, pressed: Bool) -> CIImage {
        let g = glyphs[shape] ?? glyphs[.arrow]!
        let s = pressed ? 0.86 : 1.0
        return g.image.transformed(by: CGAffineTransform(translationX: -g.hotspot.x, y: -g.hotspot.y)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: p.x, y: p.y)))
    }

    /// A soft blue disc that grows and fades over the click effect's duration.
    func halo(at p: CGPoint, progress q: Double) -> CIImage {
        let ease = 1 - pow(1 - q, 3)
        let radius = (10 + 22 * ease) * pixelsPerPoint
        let alpha = 0.42 * (1 - q)
        return CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: p.x, y: p.y),
            "inputRadius0": radius * 0.55,
            "inputRadius1": radius,
            "inputColor0": CIColor(red: 0.22, green: 0.52, blue: 1, alpha: alpha),
            "inputColor1": CIColor(red: 0.22, green: 0.52, blue: 1, alpha: 0),
        ])!.outputImage!.cropped(to: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius))
    }
}
