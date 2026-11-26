import Foundation

/// Applies shared motion finishing independently to each edited shot so a cut
/// never becomes a fabricated pointer sweep or inherits camera momentum.
public enum EditedTimelineMotion {
    private static let boundaryEpsilon = 0.000_001

    private static func shots(duration: Double, cutTimes: [Double]) -> [DemoKeepRange] {
        guard duration.isFinite, duration > 0 else { return [] }
        let cuts = Set(cutTimes.filter { $0.isFinite && $0 > 0 && $0 < duration }).sorted()
        let boundaries = [0] + cuts + [duration]
        return zip(boundaries, boundaries.dropFirst()).map { pair in .init(start: pair.0, end: pair.1) }
    }

    public static func cursorPath(samples: [CursorSample], clicks: [ClickEvent], duration: Double, cutTimes: [Double], sigma: Double) -> [CursorSample] {
        let sorted = samples.filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }.sorted { $0.time < $1.time }
        var result: [CursorSample] = []
        for shot in shots(duration: duration, cutTimes: cutTimes) {
            let points = sorted.filter { $0.time >= shot.start && ($0.time < shot.end || shot.end == duration && $0.time == duration) }
            let shotClicks = clicks.filter { $0.time >= shot.start && ($0.time < shot.end || shot.end == duration && $0.time == duration) }
            let rendered = sigma > 0 ? CursorMotion.smoothedPath(samples: points, clicks: shotClicks, sigma: sigma) : points
            result.append(contentsOf: rendered)
            // Interpolation between the old endpoint and next shot must occur
            // only in an epsilon-sized boundary, never across a sparse tail.
            if shot.end < duration, var hold = rendered.last, hold.time < shot.end - boundaryEpsilon {
                hold.time = shot.end - boundaryEpsilon
                result.append(hold)
            }
        }
        return result
    }

    public static func followOffsets(duration: Double, segments: [ZoomSegment], settings: ProjectSettings, cursor: [CursorSample], strength: Double, cutTimes: [Double], sourceCrop: SourceCropInsets = SourceCropInsets()) -> [CursorFollow.Sample] {
        var result: [CursorFollow.Sample] = []
        for shot in shots(duration: duration, cutTimes: cutTimes) {
            // Two cues may already overlap when this shot begins. Slicing
            // their envelopes to the cut would restart both entrances and
            // could reverse their authored order. Only cursor/inertia reset.
            let lastTime = shot.end == duration ? shot.end : shot.end.nextDown
            let shotCursor = cursor.filter { $0.time >= shot.start && $0.time <= lastTime }
            let shotZooms = segments.filter { $0.start <= lastTime && $0.end >= shot.start }
            let offsets = CursorFollow.offsets(from: shot.start, through: lastTime,
                                              segments: shotZooms, settings: settings, cursor: shotCursor,
                                              strength: strength, sourceCrop: sourceCrop)
            if offsets.isEmpty {
                result.append(.init(time: shot.start, dx: 0, dy: 0))
                if lastTime > shot.start {
                    result.append(.init(time: lastTime, dx: 0, dy: 0))
                }
            } else {
                result.append(contentsOf: offsets)
            }
        }
        return result
    }
}
