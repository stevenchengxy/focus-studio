import AppKit
import CoreGraphics
import Foundation

/// Cursor artwork shared by the preview, the export and the style gallery in
/// the inspector, so a style always looks the same wherever it is shown.
///
/// Geometry note: every graphic reports its hot spot in *image pixels* and how
/// many image pixels make one reference pixel (`supersample`). The renderer
/// divides its scale by that factor, so artwork drawn at twice the reference
/// density stays crisp at large cursor sizes without rendering twice as big.
/// The system cursors need this too: `NSCursor.image` is measured in points
/// while its backing bitmap is 2x on a Retina Mac, and `NSCursor.hotSpot` is in
/// points. Converting the hot spot to pixels is what keeps the arrow tip on the
/// click point instead of a few pixels below and to the right of it.
public enum CursorArtwork {
    public struct Graphic: @unchecked Sendable {
        public let image: CGImage
        /// Hot spot in image pixels, measured from the top-left corner.
        public let hotSpot: CGPoint
        /// Image pixels per reference pixel.
        public let supersample: CGFloat

        public init(image: CGImage, hotSpot: CGPoint, supersample: CGFloat = 1) {
            self.image = image
            self.hotSpot = hotSpot
            self.supersample = supersample
        }
    }

    /// A drawn style is fully described by its ink, its outline and whether it
    /// casts a shadow, which keeps arrow, I-beam and hand visually consistent.
    struct Palette {
        var fill: NSColor
        var stroke: NSColor
        var lineWidth: CGFloat
        var shadow: Bool
    }

    // MARK: - Public entry points

    /// The three pointer shapes for one appearance.
    @MainActor
    public static func set(for appearance: CursorAppearance, tint: NSColor) -> [CursorKind: Graphic] {
        var result: [CursorKind: Graphic] = [:]
        for kind in CursorKind.allCases {
            result[kind] = graphic(for: kind, appearance: appearance, tint: tint)
        }
        return result
    }

    @MainActor
    public static func graphic(
        for kind: CursorKind,
        appearance: CursorAppearance,
        tint: NSColor
    ) -> Graphic {
        switch appearance {
        case .system:
            return systemGraphic(for: kind)
        case .dot:
            return Graphic(image: dot, hotSpot: CGPoint(x: 28, y: 28), supersample: 2)
        case .elevated, .highContrast, .light, .accent:
            let palette = palette(for: appearance, tint: tint)
            switch kind {
            case .arrow:
                return Graphic(image: arrow(palette), hotSpot: arrowHotSpot, supersample: 2)
            case .iBeam:
                return Graphic(image: iBeam(palette), hotSpot: iBeamHotSpot, supersample: 2)
            case .pointingHand:
                return Graphic(image: hand(palette), hotSpot: handHotSpot, supersample: 2)
            }
        }
    }

    /// A gallery swatch: the pointer shape drawn to fit `size`, so the inspector
    /// shows the real artwork rather than an approximation of it.
    @MainActor
    public static func preview(
        for appearance: CursorAppearance,
        kind: CursorKind = .arrow,
        tint: NSColor,
        size: CGSize
    ) -> CGImage? {
        let graphic = graphic(for: kind, appearance: appearance, tint: tint)
        let source = graphic.image
        let fitted = fit(width: CGFloat(source.width), height: CGFloat(source.height), into: size)
        return drawImage(size: size) { context in
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(
                x: (size.width - fitted.width) / 2,
                y: (size.height - fitted.height) / 2,
                width: fitted.width,
                height: fitted.height
            ))
        }
    }

    private static func fit(width: CGFloat, height: CGFloat, into size: CGSize) -> CGSize {
        guard width > 0, height > 0 else { return size }
        let scale = min(size.width / width, size.height / height)
        return CGSize(width: width * scale, height: height * scale)
    }

    // MARK: - System cursors

    @MainActor
    private static func systemGraphic(for kind: CursorKind) -> Graphic {
        let cursor: NSCursor
        let fallbackAppearance: CursorAppearance = .elevated
        switch kind {
        case .arrow: cursor = .arrow
        case .iBeam: cursor = .iBeam
        case .pointingHand: cursor = .pointingHand
        }
        let image = cursor.image
        var proposed = CGRect(origin: .zero, size: image.size)
        guard image.size.width > 0, image.size.height > 0,
              let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else {
            // AppKit hands back an empty image in a headless process; the drawn
            // artwork keeps tests and command-line renders meaningful.
            let palette = palette(for: fallbackAppearance, tint: .white)
            switch kind {
            case .arrow: return Graphic(image: arrow(palette), hotSpot: arrowHotSpot, supersample: 2)
            case .iBeam: return Graphic(image: iBeam(palette), hotSpot: iBeamHotSpot, supersample: 2)
            case .pointingHand: return Graphic(image: hand(palette), hotSpot: handHotSpot, supersample: 2)
            }
        }
        let pixelsPerPoint = CGFloat(cgImage.width) / image.size.width
        return Graphic(
            image: cgImage,
            hotSpot: CGPoint(
                x: cursor.hotSpot.x * pixelsPerPoint,
                y: cursor.hotSpot.y * pixelsPerPoint
            ),
            supersample: pixelsPerPoint
        )
    }

    // MARK: - Palettes

    static let accentFallback = NSColor(red: 0.545, green: 0.482, blue: 1, alpha: 1)
    private static let ink = NSColor(white: 0.06, alpha: 1)

    static func palette(for appearance: CursorAppearance, tint: NSColor) -> Palette {
        switch appearance {
        case .elevated:
            return Palette(fill: ink, stroke: .white, lineWidth: 6, shadow: true)
        case .highContrast:
            return Palette(fill: .black, stroke: .white, lineWidth: 8, shadow: false)
        case .light:
            return Palette(fill: .white, stroke: ink, lineWidth: 5.5, shadow: true)
        case .accent:
            return Palette(fill: tint, stroke: .white, lineWidth: 6, shadow: true)
        case .system, .dot:
            return Palette(fill: ink, stroke: .white, lineWidth: 6, shadow: true)
        }
    }

    // MARK: - Shapes
    //
    // Authored in a 64x80 box at twice the reference cursor grid, so every drawn
    // style matches the on-screen size of the system arrow while carrying enough
    // resolution for a 3x cursor size.

    private static let canvas = CGSize(width: 64, height: 80)
    private static let arrowHotSpot = CGPoint(x: 8, y: 6)
    private static let iBeamHotSpot = CGPoint(x: 32, y: 40)
    private static let handHotSpot = CGPoint(x: 18, y: 13)

    private static let arrowPoints: [CGPoint] = [
        CGPoint(x: 8, y: 6), CGPoint(x: 8, y: 60), CGPoint(x: 21, y: 48),
        CGPoint(x: 30, y: 71), CGPoint(x: 42, y: 66), CGPoint(x: 33, y: 44),
        CGPoint(x: 51, y: 43),
    ]

    /// Paths are written with a top-left origin to match how cursors are
    /// specified; this flips into the bottom-left origin of a CGContext.
    private static func topLeft(_ context: CGContext, _ body: () -> Void) {
        context.saveGState()
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)
        body()
        context.restoreGState()
    }

    private static func withShadow(_ context: CGContext, _ enabled: Bool, _ body: () -> Void) {
        if enabled {
            context.setShadow(
                offset: CGSize(width: 0, height: -2.5),
                blur: 6.5,
                color: NSColor.black.withAlphaComponent(0.4).cgColor
            )
        }
        body()
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }

    private static func addArrowPath(_ context: CGContext) {
        topLeft(context) {
            context.move(to: arrowPoints[0])
            for point in arrowPoints.dropFirst() { context.addLine(to: point) }
            context.closePath()
        }
    }

    private static func addIBeamPath(_ context: CGContext) {
        topLeft(context) {
            context.move(to: CGPoint(x: 32, y: 10))
            context.addLine(to: CGPoint(x: 32, y: 70))
            context.move(to: CGPoint(x: 19, y: 10))
            context.addLine(to: CGPoint(x: 45, y: 10))
            context.move(to: CGPoint(x: 19, y: 70))
            context.addLine(to: CGPoint(x: 45, y: 70))
        }
    }

    static func arrow(_ palette: Palette) -> CGImage {
        drawImage(size: canvas) { context in
            context.setLineJoin(.round)
            context.setLineCap(.round)
            withShadow(context, palette.shadow) {
                addArrowPath(context)
                context.setLineWidth(palette.lineWidth)
                context.setStrokeColor(palette.stroke.cgColor)
                context.strokePath()
            }
            addArrowPath(context)
            context.setFillColor(palette.fill.cgColor)
            context.fillPath()
        }
    }

    static func iBeam(_ palette: Palette) -> CGImage {
        drawImage(size: canvas) { context in
            context.setLineJoin(.round)
            context.setLineCap(.round)
            withShadow(context, palette.shadow) {
                addIBeamPath(context)
                context.setLineWidth(6 + palette.lineWidth * 0.75)
                context.setStrokeColor(palette.stroke.cgColor)
                context.strokePath()
            }
            addIBeamPath(context)
            context.setLineWidth(6)
            context.setStrokeColor(palette.fill.cgColor)
            context.strokePath()
        }
    }

    @MainActor
    static func hand(_ palette: Palette) -> CGImage {
        let rect = CGRect(x: 6, y: 5, width: 54, height: 68)
        return drawImage(size: canvas) { context in
            withShadow(context, palette.shadow) {
                draw(symbol: "hand.point.up.left.fill", color: palette.stroke,
                     in: rect.insetBy(dx: -4, dy: -4), context: context)
            }
            draw(symbol: "hand.point.up.left.fill", color: palette.fill,
                 in: rect, context: context)
        }
    }

    @MainActor
    private static func draw(symbol name: String, color: NSColor, in rect: CGRect, context: CGContext) {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 62, weight: .semibold))
        else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { drawRect in
            symbol.draw(in: drawRect)
            color.set()
            drawRect.fill(using: .sourceAtop)
            return true
        }
        var proposed = rect
        guard let cgImage = tinted.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return }
        context.draw(cgImage, in: rect)
    }

    static let dot: CGImage = drawImage(size: CGSize(width: 56, height: 56)) { context in
        context.setShadow(
            offset: CGSize(width: 0, height: -2),
            blur: 5,
            color: NSColor.black.withAlphaComponent(0.4).cgColor
        )
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: 4, y: 4, width: 48, height: 48))
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setFillColor(NSColor.black.withAlphaComponent(0.82).cgColor)
        context.fillEllipse(in: CGRect(x: 12, y: 12, width: 32, height: 32))
    }

    // MARK: - Drawing

    static func drawImage(size: CGSize, drawing: (CGContext) -> Void) -> CGImage {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return blank
        }
        context.clear(CGRect(origin: .zero, size: size))
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        drawing(context)
        return context.makeImage() ?? blank
    }

    private static let blank: CGImage = {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }()
}
