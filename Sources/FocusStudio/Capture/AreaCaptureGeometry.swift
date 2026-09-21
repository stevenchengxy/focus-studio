import CoreGraphics
import FocusStudioCore

/// Coordinate conversions shared by the area picker and ScreenCaptureKit.
///
/// `CaptureTargetInfo.frame` and `SCDisplay.frame` use the Quartz global screen
/// coordinate space (top-left origin). AppKit views use a bottom-left origin, so
/// selections made in an overlay window must be flipped exactly once before the
/// target is created.
public enum AreaCaptureGeometry {
    /// Converts a rectangle in an AppKit overlay's local coordinates into the
    /// Quartz global coordinate space used by ScreenCaptureKit and CGEvent.
    public static func globalFrame(
        forLocalSelection selection: CaptureRect,
        onDisplay displayFrame: CaptureRect
    ) -> CaptureRect? {
        guard
            displayFrame.width > 0,
            displayFrame.height > 0,
            selection.width > 0,
            selection.height > 0
        else { return nil }

        let localBounds = CGRect(
            x: 0,
            y: 0,
            width: displayFrame.width,
            height: displayFrame.height
        )
        let requested = CGRect(
            x: selection.x,
            y: selection.y,
            width: selection.width,
            height: selection.height
        )
        let clipped = requested.standardized.intersection(localBounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }

        return CaptureRect(
            x: displayFrame.x + clipped.minX,
            y: displayFrame.y + displayFrame.height - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
    }

    /// Clips a requested Quartz-global area to a display. The returned rectangle
    /// is the canonical target frame used for movie capture, screenshots, and
    /// cursor/click normalization.
    public static func clippedGlobalFrame(
        _ requestedFrame: CaptureRect,
        toDisplay displayFrame: CaptureRect
    ) -> CaptureRect? {
        let requested = cgRect(requestedFrame).standardized
        let display = cgRect(displayFrame).standardized
        let clipped = requested.intersection(display)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        return captureRect(clipped)
    }

    /// Returns the display-local, top-left-origin source rectangle expected by
    /// `SCStreamConfiguration.sourceRect`.
    public static func sourceRect(
        forGlobalFrame globalFrame: CaptureRect,
        onDisplay displayFrame: CaptureRect
    ) -> CGRect? {
        guard let clipped = clippedGlobalFrame(globalFrame, toDisplay: displayFrame) else {
            return nil
        }
        return CGRect(
            x: clipped.x - displayFrame.x,
            y: clipped.y - displayFrame.y,
            width: clipped.width,
            height: clipped.height
        )
    }

    private static func cgRect(_ rect: CaptureRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private static func captureRect(_ rect: CGRect) -> CaptureRect {
        CaptureRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }
}
