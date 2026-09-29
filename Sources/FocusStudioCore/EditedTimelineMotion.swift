import Foundation

/// Applies the existing manual motion algorithms independently to each edited
/// shot. Original recordings never enter this route and keep their old path.
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
            let shotClicks = clicks.filter { $0.time >= shot.start && $0.time < shot.end }
            let rendered = sigma > 0 ? CursorMotion.smoothedPath(samples: points, clicks: shotClicks, sigma: sigma) : points
            result.append(contentsOf: rendered)
            // Interpolation between the old endpoint and next shot must occur
            // only in an epsilon-sized boundary, never across a sparse tail.
            if shot.end < duration, var hold = result.last, hold.time < shot.end - boundaryEpsilon {
                hold.time = shot.end - boundaryEpsilon
                result.append(hold)
            }
        }
        return result
    }

    public static func followOffsets(duration: Double, segments: [ZoomSegment], settings: ProjectSettings, cursor: [CursorSample], strength: Double, cutTimes: [Double]) -> [CursorFollow.Sample] {
        var result: [CursorFollow.Sample] = []
        for shot in shots(duration: duration, cutTimes: cutTimes) {
            let localCursor = cursor.filter { $0.time >= shot.start && ($0.time < shot.end || shot.end == duration && $0.time == duration) }.map {
                CursorSample(time: $0.time - shot.start, x: $0.x, y: $0.y, cursorKind: $0.cursorKind)
            }
            let localZooms = segments.compactMap { zoom -> ZoomSegment? in
                guard zoom.start < shot.end, zoom.end > shot.start else { return nil }
                var copy = zoom
                copy.start = max(shot.start, zoom.start) - shot.start
                copy.end = min(shot.end, zoom.end) - shot.start
                return copy
            }
            let localOffsets = CursorFollow.offsets(duration: shot.duration, segments: localZooms, settings: settings, cursor: localCursor, strength: strength)
            if localOffsets.isEmpty {
                result.append(.init(time: shot.start, dx: 0, dy: 0))
                result.append(.init(time: shot.end == duration ? shot.end : shot.end - boundaryEpsilon, dx: 0, dy: 0))
                continue
            }
            for offset in localOffsets {
                let time = shot.start + offset.time
                if time < shot.end || shot.end == duration {
                    result.append(.init(time: time, dx: offset.dx, dy: offset.dy))
                }
            }
            if shot.end < duration, let last = result.last, last.time < shot.end - boundaryEpsilon {
                result.append(.init(time: shot.end - boundaryEpsilon, dx: last.dx, dy: last.dy))
            }
        }
        return result.sorted { $0.time < $1.time }
    }
}
