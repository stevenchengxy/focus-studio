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
public enum CaptionRenderer {
    /// Reference proportions at 1080p; everything scales with canvas height.
    static let fontHeightFraction = 0.024
    static let maximumWidthFraction = 0.8
    static let cornerRadiusAt1080p = 14.0

    static let maximumHeightFraction = 0.26
    static let maximumLineCount = 8
    static let minimumFontScale = 0.72

    /// Uses exactly the same layout as preview and export. Call before creating
    /// paid narration so an overlong sentence can be split without losing words.
    public static func canRenderFullText(
        text: String,
        number: Int?,
        canvasSize: CGSize,
        style: CaptionStyle
    ) -> Bool {
        layout(text: text, number: number, canvasSize: canvasSize, style: style) != nil
    }

    static func artwork(
        text rawText: String,
        number: Int?,
        canvasSize: CGSize,
        style: CaptionStyle
    ) -> CaptionArtwork? {
        guard let layout = layout(text: rawText, number: number, canvasSize: canvasSize, style: style)
            ?? truncatedLayoutForExistingCaption(text: rawText, number: number, canvasSize: canvasSize, style: style) else { return nil }
        let resolvedStyle = style.sanitized
        let unit = canvasSize.height / 1080
        let horizontalPadding = layout.horizontalPadding
        let verticalPadding = layout.verticalPadding
        let chipGap = layout.chipGap
        let chip = layout.chip
        let pillHeight = layout.pillSize.height
        let pillWidth = layout.pillSize.width
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
        // Core Graphics uses a bottom-left origin; lay out the first baseline
        // beneath the top padding, then advance by each measured line's height.
        var baseline = pillRect.maxY - verticalPadding - layout.lines[0].metrics.ascent
        for (index, textLine) in layout.lines.enumerated() {
            if index > 0 {
                baseline -= layout.lines[index - 1].metrics.descent + layout.lineGap + textLine.metrics.ascent
            }
            context.textPosition = CGPoint(x: cursorX, y: baseline)
            CTLineDraw(textLine.line, context)
        }

        guard let image = context.makeImage() else { return nil }
        return CaptionArtwork(image: image, size: CGSize(width: bitmapWidth, height: bitmapHeight))
    }

    /// Normalize whitespace before typesetting. Wrapping is determined by the
    /// output canvas, rather than by arbitrary newlines in an AI response.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline || $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct LineMetrics {
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    struct TextLine {
        let line: CTLine
        let range: CFRange
        let metrics: LineMetrics
    }

    struct TextLayout {
        let text: String
        let lines: [TextLine]
        let fontSize: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        let lineGap: CGFloat
        let chipGap: CGFloat
        let chip: (line: CTLine, metrics: LineMetrics, size: CGSize)?
        let pillSize: CGSize
    }

    static func layout(text rawText: String, number: Int?, canvasSize: CGSize, style: CaptionStyle) -> TextLayout? {
        let text = singleLine(rawText)
        guard !text.isEmpty, text.utf16.count <= 4096,
              canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width >= 16, canvasSize.height >= 16,
              canvasSize.width <= 16384, canvasSize.height <= 16384 else { return nil }
        let requestedSize = max(6, canvasSize.height * fontHeightFraction * style.sanitized.scale)
        // Prefer the user's font size. Smaller steps retain readability while
        // allowing long sentences to fit a portrait canvas without truncation.
        for scale in [1.0, 0.94, 0.88, 0.82, 0.76, minimumFontScale] {
            let fontSize = max(6, requestedSize * scale)
            if let result = layout(text: text, number: number, canvasSize: canvasSize, fontSize: fontSize) {
                return result
            }
        }
        return nil
    }

    /// Preserve the previous visible ellipsis for older/manual captions that
    /// exceed the safe area. Generated captions are checked with full layout
    /// before synthesis, so this compatibility path never hides generated words.
    static func truncatedLayoutForExistingCaption(text rawText: String, number: Int?, canvasSize: CGSize, style: CaptionStyle) -> TextLayout? {
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width >= 16, canvasSize.height >= 16,
              canvasSize.width <= 16384, canvasSize.height <= 16384 else { return nil }
        let text = singleLine(String(rawText.prefix(4096)))
        guard !text.isEmpty else { return nil }
        let fontSize = max(6, canvasSize.height * fontHeightFraction * style.sanitized.scale)
        return layout(text: text, number: number, canvasSize: canvasSize, fontSize: fontSize, truncating: true)
    }

    private static func layout(text: String, number: Int?, canvasSize: CGSize, fontSize: CGFloat, truncating: Bool = false) -> TextLayout? {
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let font = systemFont(size: fontSize, weight: 0.3)
        let horizontalPadding = fontSize * 0.85
        let verticalPadding = fontSize * 0.42
        let lineGap = fontSize * 0.18
        let chipGap = fontSize * 0.5
        var chip: (line: CTLine, metrics: LineMetrics, size: CGSize)?
        if let number, number > 0 {
            let chipLine = line("\(number)", font: systemFont(size: fontSize * 0.78, weight: 0.4), color: white)
            let metrics = typographicBounds(chipLine)
            let height = fontSize * 1.18
            chip = (chipLine, metrics, CGSize(width: max(height, metrics.width + fontSize * 0.62), height: height))
        }
        // Include the raster stroke margin in the safe-area budget as well.
        let margin = ceil(max(1, canvasSize.height / 1080)) + 1
        let reservedWidth = horizontalPadding * 2 + (chip.map { $0.size.width + chipGap } ?? 0)
        let availableWidth = floor(canvasSize.width * maximumWidthFraction) - margin * 2 - reservedWidth
        guard availableWidth > 0 else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let string = text as NSString
        var lines: [TextLine] = []
        var offset = 0
        if truncating {
            let fullLine = CTLineCreateWithAttributedString(attributed)
            let token = line("…", font: font, color: white)
            let drawnLine = CTLineCreateTruncatedLine(fullLine, Double(availableWidth), .end, token) ?? fullLine
            let metrics = typographicBounds(drawnLine)
            guard metrics.width <= availableWidth + 0.01 else { return nil }
            lines = [TextLine(line: drawnLine, range: CFRange(location: 0, length: string.length), metrics: metrics)]
            offset = string.length
        }
        while offset < string.length {
            guard lines.count < maximumLineCount else { return nil }
            var count = CTTypesetterSuggestLineBreak(typesetter, offset, Double(availableWidth))
            if count <= 0 { count = CTTypesetterSuggestClusterBreak(typesetter, offset, Double(availableWidth)) }
            guard count > 0 else { return nil }
            var range = CFRange(location: offset, length: min(count, string.length - offset))
            var textLine = CTTypesetterCreateLine(typesetter, range)
            var metrics = typographicBounds(textLine)
            if metrics.width - CGFloat(CTLineGetTrailingWhitespaceWidth(textLine)) > availableWidth + 0.01 {
                // A single unbroken URL can exceed a word break. Cluster breaks
                // preserve complete composed characters (including emoji).
                count = CTTypesetterSuggestClusterBreak(typesetter, offset, Double(availableWidth))
                guard count > 0 else { return nil }
                range = CFRange(location: offset, length: min(count, string.length - offset))
                textLine = CTTypesetterCreateLine(typesetter, range)
                metrics = typographicBounds(textLine)
            }
            let visibleWidth = max(0, metrics.width - CGFloat(CTLineGetTrailingWhitespaceWidth(textLine)))
            guard visibleWidth <= availableWidth + 0.01 else { return nil }
            lines.append(TextLine(line: textLine, range: range,
                                  metrics: LineMetrics(width: visibleWidth, ascent: metrics.ascent, descent: metrics.descent)))
            offset += range.length
        }
        let textHeight = lines.reduce(CGFloat.zero) { $0 + $1.metrics.ascent + $1.metrics.descent }
            + CGFloat(max(0, lines.count - 1)) * lineGap
        let width = reservedWidth + (lines.map(\.metrics.width).max() ?? 0)
        let height = max(textHeight, chip?.size.height ?? 0) + verticalPadding * 2
        guard ceil(width + margin * 2) <= canvasSize.width * maximumWidthFraction,
              ceil(height + margin * 2) <= canvasSize.height * maximumHeightFraction else { return nil }
        return TextLayout(text: text, lines: lines, fontSize: fontSize,
                          horizontalPadding: horizontalPadding, verticalPadding: verticalPadding,
                          lineGap: lineGap, chipGap: chipGap, chip: chip,
                          pillSize: CGSize(width: width, height: height))
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
