import CoreGraphics
import Foundation

/// A non-destructive crop expressed in the source video's normalized coordinate
/// space. The origin follows screen coordinates: `top` removes pixels from the
/// top edge even though Core Image itself uses a bottom-left origin.
public struct SourceCropInsets: Codable, Hashable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(
        top: Double = 0,
        leading: Double = 0,
        bottom: Double = 0,
        trailing: Double = 0
    ) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    /// Legacy normalized presets retained for projects and editor controls that
    /// do not know the recorded source dimensions. New capture flows should use
    /// `BrowserContentCrop.insets(...)`, which is stable across window heights.
    public static let chromeContent = SourceCropInsets(top: 0.105)
    public static let edgeContent = SourceCropInsets(top: 0.105)
    public static let braveContent = SourceCropInsets(top: 0.105)
    public static let firefoxContent = SourceCropInsets(top: 0.112)
    public static let safariContent = SourceCropInsets(top: 0.082)

    /// Keeps every edge finite and leaves at least 10% of the source visible.
    public var sanitized: SourceCropInsets {
        var value = SourceCropInsets(
            top: finiteUnit(top),
            leading: finiteUnit(leading),
            bottom: finiteUnit(bottom),
            trailing: finiteUnit(trailing)
        )
        Self.limitPair(leading: &value.leading, trailing: &value.trailing)
        Self.limitPair(leading: &value.top, trailing: &value.bottom)
        return value
    }

    public var isEffectivelyEmpty: Bool {
        let value = sanitized
        return value.top + value.leading + value.bottom + value.trailing < 0.000_001
    }

    public func sourceRect(in sourceSize: CGSize) -> CGRect {
        let value = sanitized
        let width = max(1, sourceSize.width * (1 - value.leading - value.trailing))
        let height = max(1, sourceSize.height * (1 - value.top - value.bottom))
        return CGRect(
            x: sourceSize.width * value.leading,
            y: sourceSize.height * value.bottom,
            width: width,
            height: height
        )
    }

    /// Converts a point from full-source coordinates into the cropped frame.
    /// Returns nil when the point sits in an area that has been removed.
    public func croppedPoint(x: Double, y: Double) -> CGPoint? {
        let value = sanitized
        let visibleWidth = 1 - value.leading - value.trailing
        let visibleHeight = 1 - value.top - value.bottom
        guard x >= value.leading,
              x <= 1 - value.trailing,
              y >= value.top,
              y <= 1 - value.bottom
        else { return nil }

        return CGPoint(
            x: (x - value.leading) / visibleWidth,
            y: (y - value.top) / visibleHeight
        )
    }

    /// Converts a point expressed in the visible, cropped content back into the
    /// full source coordinate space. Director plans use content coordinates so
    /// a click at y=0 still lands below a browser's cropped toolbar.
    public func sourcePoint(x: Double, y: Double) -> CGPoint {
        let value = sanitized
        let visibleWidth = 1 - value.leading - value.trailing
        let visibleHeight = 1 - value.top - value.bottom
        return CGPoint(
            x: value.leading + x.clamped(to: 0...1) * visibleWidth,
            y: value.top + y.clamped(to: 0...1) * visibleHeight
        )
    }

    private func finiteUnit(_ rawValue: Double) -> Double {
        guard rawValue.isFinite else { return 0 }
        return rawValue.clamped(to: 0...0.85)
    }

    private static func limitPair(leading: inout Double, trailing: inout Double) {
        let total = leading + trailing
        guard total > 0.9 else { return }
        let scale = 0.9 / total
        leading *= scale
        trailing *= scale
    }
}

/// Browser families whose native window chrome can be removed non-destructively.
/// The values intentionally describe layout families rather than bundle IDs so
/// Chromium distributions inherit the same robust crop behavior.
public enum BrowserFamily: String, Codable, CaseIterable, Sendable {
    case chrome
    case edge
    case brave
    case chromium
    case firefox
    case safari

    /// Typical vertical distance, in macOS logical points, from the top of a
    /// browser window to the first row of webpage pixels. Browser UI is sized in
    /// points, not as a percentage of the window, so this yields much more stable
    /// results than a fixed normalized inset on short and tall windows.
    public var contentOffsetPoints: Double {
        switch self {
        case .chrome, .edge, .brave, .chromium:
            return 92
        case .firefox:
            return 98
        case .safari:
            return 72
        }
    }

    /// Additional browser UI below the tabs/address toolbar when the user keeps
    /// a bookmarks or favorites bar visible. This is deliberately optional:
    /// applying it to a browser without that bar would remove the first row of
    /// webpage content, so the recording picker exposes it as its own switch.
    public var bookmarksBarOffsetPoints: Double {
        switch self {
        case .chrome, .edge, .brave, .chromium:
            return 28
        case .firefox:
            return 30
        case .safari:
            return 28
        }
    }

    public static func detect(applicationName: String?, bundleIdentifier: String? = nil) -> Self? {
        let identity = [applicationName, bundleIdentifier]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        guard !identity.isEmpty else { return nil }
        if identity.contains("firefox") { return .firefox }
        if identity.contains("safari") { return .safari }
        if identity.contains("microsoft edge") || identity.contains("com.microsoft.edgemac") {
            return .edge
        }
        if identity.contains("brave") { return .brave }
        if identity.contains("chromium") { return .chromium }
        if identity.contains("chrome") || identity.contains("com.google.chrome") { return .chrome }
        return nil
    }
}

/// Dimension-aware browser content cropping shared by capture, screenshots,
/// cursor remapping, and the final renderer.
public enum BrowserContentCrop {
    /// Returns a crop for a browser window capture. `windowHeightPoints` must be
    /// the ScreenCaptureKit window height in logical points. Passing the captured
    /// pixel height here on a Retina display would double-crop the page.
    public static func insets(
        for family: BrowserFamily,
        windowHeightPoints: Double,
        hidesBookmarksBar: Bool = false
    ) -> SourceCropInsets {
        guard windowHeightPoints.isFinite, windowHeightPoints > 0 else {
            return fallbackInsets(for: family)
        }

        // Avoid destroying a very small window while still removing the whole
        // toolbar from ordinary browser windows. Sanitization remains the final
        // safety net for adversarial metadata.
        let chromeHeight = family.contentOffsetPoints
            + (hidesBookmarksBar ? family.bookmarksBarOffsetPoints : 0)
        let normalizedTop = (chromeHeight / windowHeightPoints)
            .clamped(to: 0.035...0.24)
        return SourceCropInsets(top: normalizedTop).sanitized
    }

    public static func insets(
        applicationName: String?,
        bundleIdentifier: String? = nil,
        windowHeightPoints: Double,
        hidesBookmarksBar: Bool = false
    ) -> SourceCropInsets? {
        guard let family = BrowserFamily.detect(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier
        ) else { return nil }
        return insets(
            for: family,
            windowHeightPoints: windowHeightPoints,
            hidesBookmarksBar: hidesBookmarksBar
        )
    }

    /// Convenience used by the recorder. Display targets are deliberately not
    /// guessed here: without a chosen browser window rectangle, a display may
    /// contain zero, one, or several browsers and no crop can be deterministic.
    public static func insets(
        for target: CaptureTargetInfo?,
        hidesBookmarksBar: Bool = false
    ) -> SourceCropInsets? {
        guard let target, target.kind == .window else { return nil }
        return insets(
            applicationName: target.appName,
            windowHeightPoints: target.frame.height,
            hidesBookmarksBar: hidesBookmarksBar
        )
    }

    /// Crops a full-display recording down to one browser's webpage rectangle.
    /// Both rectangles use the same top-left-origin, logical-point coordinate
    /// space used by ScreenCaptureKit target metadata. This removes desktop
    /// margins and the macOS menu bar whenever they sit above the browser window,
    /// then removes that browser's own tabs and toolbar.
    public static func displayInsets(
        for family: BrowserFamily,
        displayFrame: CGRect,
        browserWindowFrame: CGRect
    ) -> SourceCropInsets? {
        guard displayFrame.width.isFinite,
              displayFrame.height.isFinite,
              displayFrame.width > 0,
              displayFrame.height > 0
        else { return nil }

        let clippedWindow = browserWindowFrame.standardized.intersection(displayFrame.standardized)
        guard !clippedWindow.isNull,
              clippedWindow.width >= 32,
              clippedWindow.height >= 32
        else { return nil }

        let contentTop = clippedWindow.minY + family.contentOffsetPoints
        guard contentTop < clippedWindow.maxY - 16 else { return nil }

        return SourceCropInsets(
            top: (contentTop - displayFrame.minY) / displayFrame.height,
            leading: (clippedWindow.minX - displayFrame.minX) / displayFrame.width,
            bottom: (displayFrame.maxY - clippedWindow.maxY) / displayFrame.height,
            trailing: (displayFrame.maxX - clippedWindow.maxX) / displayFrame.width
        ).sanitized
    }

    public static func fallbackInsets(for family: BrowserFamily) -> SourceCropInsets {
        switch family {
        case .chrome, .chromium: return .chromeContent
        case .edge: return .edgeContent
        case .brave: return .braveContent
        case .firefox: return .firefoxContent
        case .safari: return .safariContent
        }
    }
}
