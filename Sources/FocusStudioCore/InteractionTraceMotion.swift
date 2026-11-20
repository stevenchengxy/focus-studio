import Foundation

/// Execution and physical capture use the same finishing algorithm. Trace
/// resolution supplies the continuity boundaries and trusted button metadata.
public enum InteractionCursorMotion {
    public static func smoothedPath(
        samples: [CursorSample], clicks: [ClickEvent], sigma: Double
    ) -> [CursorSample] {
        CursorMotion.smoothedPath(samples: samples, clicks: clicks, sigma: sigma)
    }
}

/// Camera following with explicit trace boundaries and pointer visibility.
public enum InteractionCursorFollow {
    public static func offsets(
        duration: Double,
        segments: [ZoomSegment],
        settings: ProjectSettings,
        cursor: [CursorSample],
        strength: Double,
        discontinuities: [Double] = [],
        cursorIsAvailable: ((Double) -> Bool)? = nil
    ) -> [CursorFollow.Sample] {
        CursorFollow.offsets(duration: duration, segments: segments, settings: settings,
                             cursor: cursor, strength: strength, discontinuities: discontinuities,
                             cursorIsAvailable: cursorIsAvailable)
    }
}
