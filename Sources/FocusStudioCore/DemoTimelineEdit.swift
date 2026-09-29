import Foundation

public struct DemoKeepRange: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var duration: Double { end - start }
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public enum DemoEditError: LocalizedError {
    case invalidRanges
    case invalidMedia(String)
    public var errorDescription: String? {
        switch self {
        case .invalidRanges: return "Keep ranges must contain 1–128 ordered, non-overlapping intervals of at least 0.1 seconds within the recording."
        case let .invalidMedia(message): return message
        }
    }
}

/// A cut-only timeline. Source times remain explicit; neither speed changes nor
/// transitions invent coordinates or stretch the recorded input trace.
public struct DemoTimelineEdit: Sendable {
    public let ranges: [DemoKeepRange]
    public let sourceDuration: Double
    public var duration: Double { ranges.reduce(0) { $0 + $1.duration } }

    public init(keepRanges: [DemoKeepRange], sourceDuration: Double) throws {
        guard sourceDuration.isFinite, sourceDuration > 0,
              (1...128).contains(keepRanges.count) else { throw DemoEditError.invalidRanges }
        var previous = 0.0
        for range in keepRanges {
            guard range.start.isFinite, range.end.isFinite, range.start >= previous,
                  range.start >= 0, range.end <= sourceDuration,
                  range.duration >= 0.1 - 0.000_001 else { throw DemoEditError.invalidRanges }
            previous = range.end
        }
        // Touching intervals retain continuous source time. Treat them as
        // one shot so remapping cannot fabricate a camera reset or split a
        // zoom when no video was actually removed.
        var continuousRanges: [DemoKeepRange] = []
        for range in keepRanges {
            if let last = continuousRanges.last, range.start == last.end {
                continuousRanges[continuousRanges.count - 1].end = range.end
            } else {
                continuousRanges.append(range)
            }
        }
        self.ranges = continuousRanges
        self.sourceDuration = sourceDuration
    }

    /// A point at an internal range's end belongs only to a following retained
    /// interval. This avoids duplicating clicks at adjacent edit boundaries.
    public func mappedTime(_ time: Double) -> Double? {
        var offset = 0.0
        for range in ranges {
            if time >= range.start && (time < range.end || time == sourceDuration && range.end == sourceDuration) {
                return offset + time - range.start
            }
            offset += range.duration
        }
        return nil
    }

    public var removedRanges: [DemoKeepRange] {
        var result: [DemoKeepRange] = []
        var previous = 0.0
        for range in ranges {
            if range.start > previous { result.append(.init(start: previous, end: range.start)) }
            previous = range.end
        }
        if previous < sourceDuration { result.append(.init(start: previous, end: sourceDuration)) }
        return result
    }

    public func remap(_ original: RecordingProject, id: UUID = UUID(), title: String? = nil, sourceVideoPath: String) -> RecordingProject {
        var result = original
        result.id = id
        result.title = title ?? original.title + " — Edited"
        result.createdAt = Date()
        result.sourceVideoPath = sourceVideoPath
        result.duration = duration
        var cutTimes = (original.editCutTimes ?? []).compactMap(mappedTime)
        var outputStart = 0.0
        for (index, range) in ranges.enumerated() {
            if index > 0, range.start > ranges[index - 1].end { cutTimes.append(outputStart) }
            outputStart += range.duration
        }
        let internalCuts = Set(cutTimes.filter { $0.isFinite && $0 > 0 && $0 < duration }).sorted()
        result.editCutTimes = internalCuts.isEmpty ? nil : internalCuts
        result.cursorSamples = remapSamples(original.cursorSamples)
        result.clickEvents = original.clickEvents.compactMap { event in
            guard let time = mappedTime(event.time) else { return nil }
            var copy = event; copy.time = time; return copy
        }
        result.typingActivity = original.typingActivity?.compactMap { event in
            guard let time = mappedTime(event.time) else { return nil }
            var copy = event; copy.time = time; return copy
        }
        if let trace = original.interactionTrace {
            let resolution = trace.resolved(duration: sourceDuration)
            var seen: Set<UUID> = []
            let validEvents = trace.events.filter { event in
                guard event.time.isFinite, event.time >= 0, event.time <= sourceDuration,
                      event.sequence >= 0, event.geometryGeneration >= 0,
                      event.x.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                      event.y.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                      event.kind == .discontinuity || event.x != nil && event.y != nil else { return false }
                return seen.insert(event.id).inserted
            }.sorted { $0.time != $1.time ? $0.time < $1.time : $0.sequence != $1.sequence ? $0.sequence < $1.sequence : $0.id.uuidString < $1.id.uuidString }
            var generation = 0
            var events: [InteractionEvent] = []
            var offset = 0.0
            for range in ranges {
                generation += 1
                var previousSourceGeneration = validEvents.last(where: { $0.time <= range.start })?.geometryGeneration
                events.append(.init(sequence: events.count, time: offset, kind: .discontinuity, geometryGeneration: generation))
                if resolution.cursorIsAvailable(at: range.start),
                   let pose = resolution.cursorSamples.last(where: { $0.time <= range.start }) {
                    events.append(.init(sequence: events.count, time: offset, kind: .move, x: pose.x, y: pose.y, cursorKind: pose.cursorKind, geometryGeneration: generation))
                }
                for event in validEvents {
                    guard event.time >= range.start,
                          event.time < range.end || event.time == sourceDuration && range.end == sourceDuration else { continue }
                    if let previousSourceGeneration, previousSourceGeneration != event.geometryGeneration { generation += 1 }
                    previousSourceGeneration = event.geometryGeneration
                    var copy = event
                    copy.time = offset + event.time - range.start
                    copy.sequence = events.count
                    // Explicit source discontinuities remain; each edit boundary
                    // independently breaks camera/pointer continuity.
                    copy.geometryGeneration = generation
                    events.append(copy)
                }
                offset += range.duration
            }
            let typing = trace.typingActivity.map { _ in
                trace.resolvedTypingActivity(duration: sourceDuration).compactMap { activity -> TypingActivity? in
                    guard let time = mappedTime(activity.time) else { return nil }
                    return .init(time: time, x: activity.x, y: activity.y)
                }
            }
            result.interactionTrace = InteractionTrace(sessionID: UUID(), source: trace.source,
                cursorDisplayMode: trace.cursorDisplayMode, events: events, typingActivity: typing)
            // Keep report/editor metadata consistent with the authoritative
            // execution trace, never an unrelated physical typing stream.
            if trace.source == .execution { result.typingActivity = typing ?? [] }
        }
        result.zoomSegments = original.zoomSegments.flatMap { segment in
            pieces(start: segment.start, end: segment.end).enumerated().map { index, piece in
                var copy = segment
                if index > 0 { copy.id = UUID() }
                copy.start = piece.start; copy.end = piece.end
                // Freeze the source's effective visibility as well as timing:
                // an automatic cue hidden by the global switch must not become
                // visible merely because the cut turns it into a manual cue.
                copy.isEnabled = segment.isEnabled && (segment.kind == .manual || original.settings.autoZoomEnabled)
                // These are now authored cuts. Regeneration must not restore
                // a removed hold or coalesce two separate shots.
                copy.kind = .manual
                if let source = segment.automaticSource ?? (segment.kind == .automatic ? ZoomAutomaticSource(start: segment.start, targetX: segment.targetX, targetY: segment.targetY, originalEnd: segment.end) : nil) {
                    let clicks = (source.clickIDs ?? []).filter { id in result.resolvedClickEvents.contains { $0.id == id } }
                    let typing = source.typingActivity?.compactMap { activity -> TypingActivity? in
                        guard let time = mappedTime(activity.time) else { return nil }
                        return .init(time: time, x: activity.x, y: activity.y)
                    }
                    copy.automaticSource = ZoomAutomaticSource(
                        start: mappedTime(source.start) ?? piece.start,
                        targetX: source.targetX, targetY: source.targetY,
                        eventTime: source.eventTime.flatMap(mappedTime), clickIDs: source.clickIDs == nil ? nil : clicks,
                        typingActivity: typing, originalEnd: source.originalEnd.flatMap(mappedTime) ?? piece.end)
                }
                let length = piece.duration
                copy.zoomEaseIn = min(copy.zoomEaseIn ?? original.settings.zoomEaseIn, length / 2)
                copy.zoomEaseOut = min(copy.zoomEaseOut ?? original.settings.zoomEaseOut, length / 2)
                return copy
            }
        }.sorted { $0.start < $1.start }
        result.chapters = original.chapters?.flatMap { chapter in
            pieces(start: chapter.start, end: chapter.end).enumerated().map { index, piece in
                var copy = chapter
                if index > 0 { copy.id = UUID() }
                copy.start = piece.start; copy.end = piece.end
                return copy
            }
        }
        return result
    }

    private func pieces(start: Double, end: Double) -> [DemoKeepRange] {
        var result: [DemoKeepRange] = []
        var offset = 0.0
        for range in ranges {
            let lower = max(start, range.start), upper = min(end, range.end)
            if upper > lower { result.append(.init(start: offset + lower - range.start, end: offset + upper - range.start)) }
            offset += range.duration
        }
        return result
    }

    private func remapSamples(_ samples: [CursorSample]) -> [CursorSample] {
        let sorted = samples.filter { $0.time.isFinite }.sorted { $0.time < $1.time }
        var result: [CursorSample] = []
        var offset = 0.0
        for range in ranges {
            if var first = sorted.last(where: { $0.time <= range.start }) {
                first.time = offset; result.append(first)
            }
            for sample in sorted where sample.time >= range.start && sample.time < range.end {
                var copy = sample; copy.time = offset + sample.time - range.start; result.append(copy)
            }
            if var last = sorted.last(where: { $0.time < range.end }) {
                last.time = offset + range.duration - 0.000_001; result.append(last)
            }
            offset += range.duration
        }
        return result
    }
}

public struct DemoPacingProposal: Sendable {
    public let edit: DemoTimelineEdit
    public let evidenceCount: Int
    public let warnings: [String]
}

public enum DemoPacingAnalyzer {
    public static func analyze(_ project: RecordingProject, hasSourceAudio: Bool, preRoll: Double = 0.8, postRoll: Double = 1.8, minimumGap: Double = 3) throws -> DemoPacingProposal {
        guard preRoll.isFinite, postRoll.isFinite, minimumGap.isFinite,
              (0.1...10).contains(preRoll), (0.1...15).contains(postRoll), (0.5...60).contains(minimumGap) else { throw DemoEditError.invalidRanges }
        var times = project.resolvedClickEvents.map(\.time) + project.resolvedTypingActivity.map(\.time)
        if let trace = project.interactionTrace {
            times += trace.events.filter { $0.kind == .scroll }.map(\.time)
            // Keep dense measured movement spans too; do not truncate a long drag
            // or the approach to a click simply because no button was pressed.
            times += trace.resolved(duration: project.duration).cursorSamples.map(\.time)
        }
        times = times.filter { $0.isFinite && $0 >= 0 && $0 <= project.duration }.sorted()
        let whole = try DemoTimelineEdit(keepRanges: [.init(start: 0, end: project.duration)], sourceDuration: project.duration)
        let baseWarning = "Input silence is only a candidate wait: preview loading, generated answers and reading time before applying cuts. No visual or speech analysis was performed."
        if hasSourceAudio || times.isEmpty {
            return .init(edit: whole, evidenceCount: times.count, warnings: [baseWarning, hasSourceAudio ? "Source audio is present. Kept the complete recording to protect speech; supply reviewed ranges explicitly to cut it." : "No complete interaction evidence is available. Kept the complete recording."])
        }
        var spans = times.map { DemoKeepRange(start: max(0, $0 - preRoll), end: min(project.duration, $0 + postRoll)) }
        spans += [.init(start: 0, end: min(project.duration, postRoll)), .init(start: max(0, project.duration - postRoll), end: project.duration)]
        spans += (project.chapters ?? []).filter(\.isEnabled).map { .init(start: max(0, $0.start), end: min(project.duration, $0.end)) }
        spans.sort { $0.start < $1.start }
        var merged: [DemoKeepRange] = []
        for span in spans where span.end > span.start {
            if let last = merged.last, span.start - last.end < minimumGap {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else { merged.append(span) }
        }
        // More than 128 shots is not a useful automatic proposal. Keep the
        // original rather than silently discard later actions to meet the cap.
        if merged.count > 128 { return .init(edit: whole, evidenceCount: times.count, warnings: [baseWarning, "Too many candidate shots; the recording was kept complete."]) }
        return .init(edit: try DemoTimelineEdit(keepRanges: merged, sourceDuration: project.duration), evidenceCount: times.count, warnings: [baseWarning])
    }
}
