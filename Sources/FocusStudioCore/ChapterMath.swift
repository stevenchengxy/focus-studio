import Foundation

/// A single timing edit applied to a chapter from the timeline or Inspector.
public enum ChapterEdit: Sendable {
    case start(Double)
    case end(Double)
    /// New start time, keeping the existing length whenever it fits the video.
    case move(Double)
}

public enum ChapterMath {
    public static let minimumDuration = 0.5
    public static let defaultChapterLength = 4.0
    /// Enabled zoom segments closer together than this form one chapter.
    public static let zoomClusterGap = 2.5
    public static let heuristicChapterRange = 3...6

    // MARK: Sanitizing

    /// Drops chapters without a usable time range or text, clamps the rest to
    /// the project, enforces the minimum length and sorts by start time.
    public static func sanitized(_ chapters: [DemoChapter], duration: Double) -> [DemoChapter] {
        guard duration.isFinite, duration > 0 else { return [] }
        var seenIDs = Set<UUID>()
        var result: [DemoChapter] = []
        for chapter in chapters {
            guard chapter.start.isFinite, chapter.end.isFinite else { continue }
            var cleaned = chapter
            cleaned.title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.caption = chapter.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !(cleaned.title.isEmpty && cleaned.caption.isEmpty) else { continue }
            cleaned.start = chapter.start.clamped(to: 0...duration)
            cleaned.end = chapter.end.clamped(to: cleaned.start...duration)
            guard cleaned.end - cleaned.start >= min(minimumDuration, duration) - 0.000_001 else { continue }
            if seenIDs.contains(cleaned.id) { cleaned.id = UUID() }
            seenIDs.insert(cleaned.id)
            result.append(cleaned)
        }
        return result.sorted(by: precedes)
    }

    /// Stable chronological order used for numbering everywhere.
    public static func precedes(_ lhs: DemoChapter, _ rhs: DemoChapter) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    // MARK: Editing

    /// Invalid numeric edits are ignored. Valid edits are clamped to the video
    /// and keep the chapter at least ``minimumDuration`` long. Editing one edge
    /// leaves the other fixed; moving preserves the chapter length.
    public static func applying(
        _ edit: ChapterEdit,
        to chapter: DemoChapter,
        duration: Double
    ) -> DemoChapter {
        guard duration.isFinite, duration > 0 else { return chapter }
        switch edit {
        case let .start(value), let .end(value), let .move(value):
            guard value.isFinite else { return chapter }
        }
        var result = chapter
        let minimum = min(minimumDuration, duration)
        let start = chapter.start.isFinite ? chapter.start : 0
        let end = chapter.end.isFinite ? chapter.end : start
        result.start = start.clamped(to: 0...max(0, duration - minimum))
        result.end = end.clamped(to: (result.start + minimum)...duration)
        switch edit {
        case .start(let value):
            result.start = value.clamped(to: 0...max(0, result.end - minimum))
        case .end(let value):
            result.end = value.clamped(to: (result.start + minimum)...duration)
        case .move(let value):
            let length = (result.end - result.start).clamped(to: minimum...duration)
            result.start = value.clamped(to: 0...max(0, duration - length))
            result.end = min(duration, result.start + length)
        }
        return result
    }

    /// A new ``defaultChapterLength`` chapter starting at `time`, pulled back
    /// so it fits inside the recording. Nil when the recording is too short.
    public static func newChapter(
        at time: Double,
        duration: Double,
        title: String
    ) -> DemoChapter? {
        guard duration.isFinite, duration > 0, time.isFinite else { return nil }
        let length = min(duration, defaultChapterLength)
        let start = time.clamped(to: 0...max(0, duration - length))
        return DemoChapter(start: start, end: min(duration, start + length), title: title)
    }

    // MARK: Heuristics

    /// Chapters derived from where the camera already focuses: enabled zoom
    /// segments closer together than ``zoomClusterGap`` become one chapter.
    /// The result always tiles the whole recording with 3–6 chapters (fewer
    /// only when the recording is too short for the minimum length).
    public static func chaptersFromZooms(
        project: RecordingProject,
        title: (Int) -> String = { "Chapter \($0)" }
    ) -> [DemoChapter] {
        let duration = project.duration
        guard duration.isFinite, duration > 0 else { return [] }
        let maximumCount = max(1, min(heuristicChapterRange.upperBound, Int(duration / minimumDuration)))
        let minimumCount = min(heuristicChapterRange.lowerBound, maximumCount)

        let segments = project.zoomSegments
            .filter { $0.isEnabled && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .map { (start: $0.start.clamped(to: 0...duration), end: $0.end.clamped(to: 0...duration)) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }

        var clusters: [(start: Double, end: Double)] = []
        for segment in segments {
            if let last = clusters.last, segment.start - last.end < zoomClusterGap {
                clusters[clusters.count - 1].end = max(last.end, segment.end)
            } else {
                clusters.append(segment)
            }
        }
        // Too many focus groups: merge the pair with the shortest gap until
        // the result is a digestible number of chapters.
        while clusters.count > maximumCount {
            var bestIndex = 0
            var bestGap = Double.infinity
            for index in 0..<(clusters.count - 1) {
                let gap = clusters[index + 1].start - clusters[index].end
                if gap < bestGap {
                    bestGap = gap
                    bestIndex = index
                }
            }
            clusters[bestIndex].end = max(clusters[bestIndex].end, clusters[bestIndex + 1].end)
            clusters.remove(at: bestIndex + 1)
        }

        var boundaries: [Double]
        if clusters.count >= minimumCount {
            boundaries = [0]
            for index in 0..<(clusters.count - 1) {
                boundaries.append((clusters[index].end + clusters[index + 1].start) / 2)
            }
            boundaries.append(duration)
        } else {
            // Too few focus groups to narrate: split the recording evenly.
            boundaries = (0...minimumCount).map { duration * Double($0) / Double(minimumCount) }
        }

        var chapters: [DemoChapter] = []
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            guard end - start >= min(minimumDuration, duration) - 0.000_001 else { continue }
            chapters.append(DemoChapter(start: start, end: end, title: title(chapters.count + 1)))
        }
        return sanitized(chapters, duration: duration)
    }
}
