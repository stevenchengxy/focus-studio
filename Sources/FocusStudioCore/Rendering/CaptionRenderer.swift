import CoreGraphics
import CoreText
import Foundation

/// One pre-rasterized caption pill. Built once per chapter when a compositor
/// is prepared, then only translated and faded per frame.
struct CaptionArtwork: @unchecked Sendable {
    let image: CGImage
    let size: CGSize
}

/// Draws a chapter caption with Core Graphics and Core Text only, so it can
/// run on any thread and produces identical pixels for preview and export.
enum CaptionRenderer {
    /// Reference proportions at 1080p; everything scales with canvas height.
    static let fontHeightFraction = 0.024
    static let maximumWidthFraction = 0.8
    static let cornerRadiusAt1080p = 14.0

    static func artwork(
        text rawText: String,
        number: Int?,
        canvasSize: CGSize,
        style: CaptionStyle
    ) -> CaptionArtwork? {
        let text = singleLine(rawText)
        guard !text.isEmpty,
              canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width >= 16, canvasSize.height >= 16 else { return nil }

        let resolvedStyle = style.sanitized
        let unit = canvasSize.height / 1080
        let fontSize = max(6, canvasSize.height * fontHeightFraction * resolvedStyle.scale)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let textFont = systemFont(size: fontSize, weight: 0.3)
        let textLine = line(text, font: textFont, color: white)
        var textMetrics = typographicBounds(textLine)

        let horizontalPadding = fontSize * 0.85
        let verticalPadding = fontSize * 0.42
        let chipGap = fontSize * 0.5
        var chip: (line: CTLine, metrics: LineMetrics, size: CGSize)?
        if let number, number > 0 {
            let chipLine = line("\(number)", font: systemFont(size: fontSize * 0.78, weight: 0.4), color: white)
            let metrics = typographicBounds(chipLine)
            let height = fontSize * 1.18
            chip = (chipLine, metrics, CGSize(width: max(height, metrics.width + fontSize * 0.62), height: height))
        }

        let maximumPillWidth = canvasSize.width * maximumWidthFraction
        let reservedWidth = horizontalPadding * 2 + (chip.map { $0.size.width + chipGap } ?? 0)
        let availableTextWidth = max(fontSize * 2, maximumPillWidth - reservedWidth)
        var drawnLine = textLine
        if textMetrics.width > availableTextWidth {
            let token = line("\u{2026}", font: textFont, color: white)
            if let truncated = CTLineCreateTruncatedLine(textLine, Double(availableTextWidth), .end, token) {
                drawnLine = truncated
                textMetrics = typographicBounds(truncated)
            }
        }
        let textWidth = min(textMetrics.width, availableTextWidth)
        let lineHeight = textMetrics.ascent + textMetrics.descent
        let pillHeight = max(lineHeight, chip?.size.height ?? 0) + verticalPadding * 2
        let pillWidth = reservedWidth + textWidth
        let cornerRadius = min(pillHeight / 2, max(4, cornerRadiusAt1080p * unit))
        let strokeWidth = max(1, unit)
        let margin = ceil(strokeWidth) + 1

        let bitmapWidth = Int(ceil(pillWidth + margin * 2))
        let bitmapHeight = Int(ceil(pillHeight + margin * 2))
        guard bitmapWidth > 0, bitmapHeight > 0,
              let context = CGContext(
                data: nil,
                width: bitmapWidth,
                height: bitmapHeight,
                bitsPerComponent: 8,
                bytesPerRow: bitmapWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight))
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)
        context.setAllowsFontSmoothing(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelPositioning(true)

        let pillRect = CGRect(x: margin, y: margin, width: pillWidth, height: pillHeight)
        let pillPath = CGPath(
            roundedRect: pillRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.addPath(pillPath)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        context.fillPath()
        let strokeRect = pillRect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
        context.addPath(CGPath(
            roundedRect: strokeRect,
            cornerWidth: max(0, cornerRadius - strokeWidth / 2),
            cornerHeight: max(0, cornerRadius - strokeWidth / 2),
            transform: nil
        ))
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
        context.setLineWidth(strokeWidth)
        context.strokePath()

        var cursorX = pillRect.minX + horizontalPadding
        context.textMatrix = .identity
        context.setTextDrawingMode(.fill)
        if let chip {
            let chipRect = CGRect(
                x: cursorX,
                y: pillRect.midY - chip.size.height / 2,
                width: chip.size.width,
                height: chip.size.height
            )
            let chipRadius = chip.size.height * 0.32
            context.addPath(CGPath(
                roundedRect: chipRect,
                cornerWidth: chipRadius,
                cornerHeight: chipRadius,
                transform: nil
            ))
            let accent = rgb(hex: resolvedStyle.resolvedAccentColorHex)
                ?? rgb(hex: CaptionStyle.defaultAccentColorHex)
                ?? (0.5, 0.38, 1)
            context.setFillColor(CGColor(red: accent.red, green: accent.green, blue: accent.blue, alpha: 1))
            context.fillPath()
            context.textPosition = CGPoint(
                x: chipRect.midX - chip.metrics.width / 2,
                y: chipRect.midY - (chip.metrics.ascent - chip.metrics.descent) / 2
            )
            CTLineDraw(chip.line, context)
            cursorX = chipRect.maxX + chipGap
        }
        context.textPosition = CGPoint(
            x: cursorX,
            y: pillRect.midY - (textMetrics.ascent - textMetrics.descent) / 2
        )
        CTLineDraw(drawnLine, context)

        guard let image = context.makeImage() else { return nil }
        return CaptionArtwork(image: image, size: CGSize(width: bitmapWidth, height: bitmapHeight))
    }

    /// Captions are always a single line: newlines and runs of spaces collapse.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline || $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct LineMetrics {
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    private static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func typographicBounds(_ line: CTLine) -> LineMetrics {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return LineMetrics(width: width, ascent: ascent, descent: descent)
    }

    /// The system UI font (with its CJK cascade) at a Core Text weight trait:
    /// 0.3 is semibold, 0.4 bold.
    private static func systemFont(size: CGFloat, weight: CGFloat) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
        let traits: [CFString: Any] = [kCTFontWeightTrait: weight]
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontTraitsAttribute: traits] as CFDictionary
        )
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
    }

    private static func rgb(hex: String) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else { return nil }
        let shift: UInt64 = value.count == 8 ? 8 : 0
        return (
            CGFloat((number >> (16 + shift)) & 0xFF) / 255,
            CGFloat((number >> (8 + shift)) & 0xFF) / 255,
            CGFloat((number >> shift) & 0xFF) / 255
        )
    }
}
