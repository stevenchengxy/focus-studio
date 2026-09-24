import Foundation

/// Actual transition lengths after fitting them inside the segment.
public struct ResolvedZoomTiming: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var easeIn: Double
    public var hold: Double
    public var easeOut: Double

    public var duration: Double { end - start }
    /// Absolute time at which the zoom-in has fully arrived.
    public var fullZoomStart: Double { start + easeIn }
    /// Absolute time at which the zoom-out begins.
    public var zoomOutStart: Double { end - easeOut }
}

public enum ZoomTimingEdit: Sendable {
    case start(Double)
    case end(Double)
    case duration(Double)
    case hold(Double)
    case easeIn(Double)
    case easeOut(Double)
    /// Absolute time when the zoom-in should be complete (moves the inner
    /// boundary; start and end stay fixed).
    case fullZoomAt(Double)
    /// Absolute time when the zoom-out should begin (moves the inner
    /// boundary; start and end stay fixed).
    case zoomOutAt(Double)
    /// New start time, keeping the existing length whenever it fits the video.
    case move(Double)
    case resetTransitions
}

/// Shared by Inspector fields, timeline gestures, preview, and export.
public enum ZoomTiming {
    public static let minimumDuration = 0.05

    public static func resolve(
        _ segment: ZoomSegment,
        settings: ProjectSettings
    ) -> ResolvedZoomTiming {
        let start = segment.start.isFinite ? max(0, segment.start) : 0
        let end = segment.end.isFinite ? max(start, segment.end) : start
        let duration = end - start
        guard duration > 0, !segment.isInstant else {
            return ResolvedZoomTiming(start: start, end: end, easeIn: 0, hold: duration, easeOut: 0)
        }
        var easeIn = finiteDuration(segment.zoomEaseIn, fallback: settings.zoomEaseIn, default: 0.42)
        var easeOut = finiteDuration(segment.zoomEaseOut, fallback: settings.zoomEaseOut, default: 0.52)
        if easeIn > duration || easeOut > duration - easeIn {
            // Normalize before adding, avoiding overflow for malformed settings.
            // Both curves meet at 1, so even a very short clip reaches its scale.
            let largest = max(easeIn, easeOut)
            let incomingWeight = easeIn / largest
            let outgoingWeight = easeOut / largest
            let totalWeight = incomingWeight + outgoingWeight
            easeIn = duration * (incomingWeight / totalWeight)
            easeOut = duration - easeIn
        }
        return ResolvedZoomTiming(
            start: start,
            end: end,
            easeIn: easeIn,
            hold: max(0, duration - easeIn - easeOut),
            easeOut: easeOut
        )
    }

    /// Invalid numeric edits are ignored. Valid edits are clamped to the media
    /// bounds and become manual, protecting them from global automatic controls.
    /// Editing one edge leaves the other fixed; moving preserves segment length.
    public static func applying(
        _ edit: ZoomTimingEdit,
        to segment: ZoomSegment,
        projectDuration: Double,
        settings: ProjectSettings
    ) -> ZoomSegment {
        guard projectDuration.isFinite, projectDuration > 0 else { return segment }
        switch edit {
        case let .start(value), let .end(value), let .duration(value), let .hold(value),
             let .easeIn(value), let .easeOut(value), let .move(value),
             let .fullZoomAt(value), let .zoomOutAt(value):
            guard value.isFinite else { return segment }
        case .resetTransitions:
            break
        }
        var result = segment
        let minimum = min(minimumDuration, projectDuration)
        let initial = resolve(segment, settings: settings)
        result.start = initial.start.clamped(to: 0...(projectDuration - minimum))
        result.end = initial.end.clamped(to: (result.start + minimum)...projectDuration)
        let timing = resolve(result, settings: settings)
        switch edit {
        case .start(let value):
            result.start = value.clamped(to: 0...max(0, result.end - minimum))
        case .end(let value):
            result.end = value.clamped(to: (result.start + minimum)...projectDuration)
        case .duration(let value):
            let length = value.clamped(to: minimum...(projectDuration - result.start))
            result.end = result.start + length
        case .hold(let value):
            // Keep the currently displayed transition lengths. Otherwise a short
            // block's formerly compressed overrides would expand again with its
            // new length and consume the hold the user has just requested.
            result.zoomEaseIn = timing.easeIn
            result.zoomEaseOut = timing.easeOut
            // Bound each operand before addition to keep even extreme edits finite.
            let available = projectDuration - result.start
            let transitions = min(available, timing.easeIn + timing.easeOut)
            let hold = max(0, value).clamped(to: 0...max(0, available - transitions))
            result.end = result.start + max(minimum, transitions + hold)
        case .easeIn(let value):
            result.zoomEaseIn = max(0, value)
            result.isInstant = false
        case .easeOut(let value):
            result.zoomEaseOut = max(0, value)
            result.isInstant = false
        case .fullZoomAt(let value):
            // The zoom-out keeps its current length; the zoom-in fills what is left.
            let available = max(0, timing.duration - timing.easeOut)
            result.zoomEaseIn = (value - timing.start).clamped(to: 0...available)
            result.zoomEaseOut = timing.easeOut
            result.isInstant = false
        case .zoomOutAt(let value):
            let available = max(0, timing.duration - timing.easeIn)
            result.zoomEaseOut = (timing.end - value).clamped(to: 0...available)
            result.zoomEaseIn = timing.easeIn
            result.isInstant = false
        case .move(let value):
            let length = timing.duration.clamped(to: minimum...projectDuration)
            result.start = value.clamped(to: 0...max(0, projectDuration - length))
            result.end = min(projectDuration, result.start + length)
        case .resetTransitions:
            result.zoomEaseIn = nil
            result.zoomEaseOut = nil
            result.isInstant = false
        }
        if result.kind == .automatic, result.automaticSource == nil {
            // Legacy projects predate source anchors. Capture their original
            // (not newly edited) geometry for regeneration's compatibility match.
            result.automaticSource = ZoomAutomaticSource(
                start: segment.start,
                targetX: segment.targetX,
                targetY: segment.targetY,
                originalEnd: segment.end
            )
        } else if result.kind == .automatic, result.automaticSource?.originalEnd == nil {
            result.automaticSource?.originalEnd = segment.end
        }
        result.kind = .manual
        return result
    }

    private static func finiteDuration(_ override: Double?, fallback: Double, default defaultValue: Double) -> Double {
        if let override, override.isFinite { return max(0, override) }
        return fallback.isFinite ? max(0, fallback) : defaultValue
    }
}
