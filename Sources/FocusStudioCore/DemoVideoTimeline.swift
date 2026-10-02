import Foundation

public enum DemoMediaAssetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case video
    case image
}

/// A project-owned copy of a library asset. `filePath` is resolved relative
/// to the project directory when metadata is loaded, just like the source movie.
public struct DemoMediaAsset: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var filePath: String
    public var kind: DemoMediaAssetKind
    /// The source movie length. Still images have no intrinsic duration (zero).
    public var duration: Double
    public var width: Int
    public var height: Int

    public init(id: UUID = UUID(), title: String, filePath: String,
                kind: DemoMediaAssetKind, duration: Double, width: Int, height: Int) {
        self.id = id
        self.title = title
        self.filePath = filePath
        self.kind = kind
        self.duration = duration
        self.width = width
        self.height = height
    }
}

/// A non-destructive segment of the project's immutable source movie.
public struct DemoVideoClip: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sourceStart: Double
    public var sourceEnd: Double
    /// Nil selects the immutable screen recording. Otherwise selects an item
    /// in `RecordingProject.mediaAssets`.
    public var mediaAssetID: UUID?
    /// Source sound only; music and generated effects retain their own settings.
    public var sourceAudioVolume: Double
    public var duration: Double { sourceEnd - sourceStart }

    public init(id: UUID = UUID(), sourceStart: Double, sourceEnd: Double,
                sourceAudioVolume: Double = 1, mediaAssetID: UUID? = nil) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.sourceAudioVolume = sourceAudioVolume
        self.mediaAssetID = mediaAssetID
    }
}

public enum DemoTransitionPreset: String, Codable, CaseIterable, Hashable, Sendable {
    case cut
    case fadeToBlack
    case flash
}

public enum DemoTransitionCurve: String, Codable, CaseIterable, Hashable, Sendable {
    case linear
    case smooth
    case easeIn
    case easeOut

    public func value(at progress: Double) -> Double {
        let t = min(1, max(0, progress))
        switch self {
        case .linear: return t
        case .smooth: return t * t * (3 - 2 * t)
        case .easeIn: return t * t
        case .easeOut: return 1 - (1 - t) * (1 - t)
        }
    }
}

/// An effect centered on the join after `fromClipID`. It does not alter duration.
public struct DemoVideoTransition: Codable, Hashable, Sendable {
    public var fromClipID: UUID
    public var preset: DemoTransitionPreset
    public var duration: Double
    /// Optional so projects written before separate in/out controls retain
    /// their original, evenly split transition when decoded.
    public var outgoingDuration: Double?
    public var incomingDuration: Double?
    public var outgoingCurve: DemoTransitionCurve?
    public var incomingCurve: DemoTransitionCurve?

    public var resolvedOutgoingDuration: Double { outgoingDuration ?? duration / 2 }
    public var resolvedIncomingDuration: Double { incomingDuration ?? duration / 2 }
    public var resolvedOutgoingCurve: DemoTransitionCurve { outgoingCurve ?? .linear }
    public var resolvedIncomingCurve: DemoTransitionCurve { incomingCurve ?? .linear }

    public init(fromClipID: UUID, preset: DemoTransitionPreset = .cut, duration: Double = 0,
                outgoingDuration: Double? = nil, incomingDuration: Double? = nil,
                outgoingCurve: DemoTransitionCurve? = nil, incomingCurve: DemoTransitionCurve? = nil) {
        self.fromClipID = fromClipID
        self.preset = preset
        self.duration = duration
        self.outgoingDuration = outgoingDuration
        self.incomingDuration = incomingDuration
        self.outgoingCurve = outgoingCurve
        self.incomingCurve = incomingCurve
    }
}

public struct DemoVideoClipPlacement: Hashable, Sendable {
    public let clip: DemoVideoClip
    public let start: Double
    public let end: Double
    public var duration: Double { end - start }
}

public enum DemoVideoEditOperation: Sendable {
    /// `at` is the absolute time of the editor playhead, not a source time.
    case split(clipID: UUID, at: Double)
    /// Bounds are seconds within the original source movie. A later trim can
    /// expand a shortened clip again, up to that source's original duration.
    case trim(clipID: UUID, sourceStart: Double, sourceEnd: Double)
    case delete(clipID: UUID)
    case move(clipID: UUID, toIndex: Int)
    /// Insert a project-owned library item before `atIndex`. Videos use their
    /// full source length when `duration` is nil; images default to 3 seconds.
    case insertMedia(assetID: UUID, atIndex: Int, duration: Double?)
    /// A still has no fixed source end, so it can be lengthened as well as cut.
    case setImageDuration(clipID: UUID, duration: Double)
    case setTransition(fromClipID: UUID, preset: DemoTransitionPreset, duration: Double)
    case setTransitionParameters(fromClipID: UUID, preset: DemoTransitionPreset,
                                 outgoingDuration: Double, incomingDuration: Double,
                                 outgoingCurve: DemoTransitionCurve, incomingCurve: DemoTransitionCurve)
    /// A value in 0...2; zero mutes the source sound in this clip.
    case setClipAudio(clipID: UUID, volume: Double)
}

public enum DemoVideoTimelineError: LocalizedError {
    case invalidTimeline(String)
    case clipNotFound
    case lastClip
    case invalidOperation(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidTimeline(reason): return "The video timeline is invalid: \(reason)"
        case .clipNotFound: return "The selected video clip no longer exists. Refresh the timeline."
        case .lastClip: return "A video needs at least one clip. Trim it instead."
        case let .invalidOperation(reason): return reason
        }
    }
}

/// The editor's single source of truth for clip bounds and output timing.
/// Recording metadata in `RecordingProject` always uses output time, while
/// `DemoVideoClip` bounds always use source-movie time.
public struct DemoVideoTimeline: Sendable {
    public let clips: [DemoVideoClip]
    public let transitions: [DemoVideoTransition]
    public let placements: [DemoVideoClipPlacement]
    public let mediaAssets: [DemoMediaAsset]
    public let sourceDuration: Double
    public let duration: Double

    public init(project: RecordingProject) throws {
        let sourceDuration = project.videoSourceDuration ?? project.duration
        let clips = project.videoClips ?? [DemoVideoClip(id: project.id, sourceStart: 0, sourceEnd: sourceDuration)]
        try self.init(clips: clips, transitions: project.videoTransitions ?? [],
                      sourceDuration: sourceDuration, mediaAssets: project.mediaAssets ?? [])
        if project.videoClips != nil, abs(project.duration - duration) > 0.002 {
            throw DemoVideoTimelineError.invalidTimeline("clip lengths do not match the project duration")
        }
    }

    public init(clips: [DemoVideoClip], transitions: [DemoVideoTransition],
                sourceDuration: Double, mediaAssets: [DemoMediaAsset] = []) throws {
        guard sourceDuration.isFinite, sourceDuration >= 0.1,
              (1...128).contains(clips.count) else {
            throw DemoVideoTimelineError.invalidTimeline("expected 1–128 clips and a finite source length")
        }
        var seen = Set<UUID>()
        var assetsByID: [UUID: DemoMediaAsset] = [:]
        for asset in mediaAssets {
            guard assetsByID[asset.id] == nil,
                  !asset.filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  asset.duration.isFinite, asset.duration >= 0,
                  asset.width > 0, asset.height > 0,
                  (asset.kind == .image || asset.duration >= 0.1) else {
                throw DemoVideoTimelineError.invalidTimeline("a media asset has invalid metadata")
            }
            assetsByID[asset.id] = asset
        }
        var placements: [DemoVideoClipPlacement] = []
        var cursor = 0.0
        for clip in clips {
            let validSourceRange: Bool
            if let assetID = clip.mediaAssetID, let asset = assetsByID[assetID] {
                validSourceRange = asset.kind == .image
                    ? clip.sourceStart >= 0 && clip.sourceEnd <= 120 + 0.002
                    : clip.sourceStart >= 0 && clip.sourceEnd <= asset.duration + 0.002
            } else {
                validSourceRange = clip.mediaAssetID == nil
                    && clip.sourceStart >= 0 && clip.sourceEnd <= sourceDuration + 0.002
            }
            guard seen.insert(clip.id).inserted,
                  clip.sourceStart.isFinite, clip.sourceEnd.isFinite,
                  validSourceRange,
                  clip.duration >= 0.1 - 0.000_001,
                  clip.sourceAudioVolume.isFinite, (0...2).contains(clip.sourceAudioVolume) else {
                throw DemoVideoTimelineError.invalidTimeline("a clip has duplicate ID, invalid bounds or invalid volume")
            }
            placements.append(.init(clip: clip, start: cursor, end: cursor + clip.duration))
            cursor += clip.duration
        }
        var transitionByID: [UUID: DemoVideoTransition] = [:]
        let outgoingIDs = Set(clips.dropLast().map(\.id))
        for transition in transitions {
            guard outgoingIDs.contains(transition.fromClipID),
                  transitionByID[transition.fromClipID] == nil,
                  transition.duration.isFinite,
                  (transition.outgoingDuration == nil) == (transition.incomingDuration == nil),
                  transition.resolvedOutgoingDuration.isFinite,
                  transition.resolvedIncomingDuration.isFinite,
                  transition.resolvedOutgoingDuration >= 0,
                  transition.resolvedIncomingDuration >= 0,
                  abs(transition.resolvedOutgoingDuration + transition.resolvedIncomingDuration - transition.duration) < 0.000_001 else {
                throw DemoVideoTimelineError.invalidTimeline("a transition has an invalid or duplicate join")
            }
            switch transition.preset {
            case .cut:
                guard transition.duration == 0 else {
                    throw DemoVideoTimelineError.invalidTimeline("a cut must have zero duration")
                }
            case .fadeToBlack, .flash:
                guard (0.1...2).contains(transition.duration) else {
                    throw DemoVideoTimelineError.invalidTimeline("an effect must last 0.1–2 seconds")
                }
            }
            transitionByID[transition.fromClipID] = transition
        }
        let normalized = clips.dropLast().map { clip in
            transitionByID[clip.id] ?? .init(fromClipID: clip.id)
        }
        // Each side occupies its neighboring clip. Effects at both ends must
        // not overlap inside a very short middle clip.
        for index in clips.indices {
            let incoming = index > 0 ? normalized[index - 1].resolvedIncomingDuration : 0
            let outgoing = index < normalized.count ? normalized[index].resolvedOutgoingDuration : 0
            guard incoming + outgoing <= clips[index].duration + 0.000_001 else {
                throw DemoVideoTimelineError.invalidTimeline("transition duration exceeds adjacent clip handles")
            }
        }
        self.clips = clips
        self.transitions = normalized
        self.placements = placements
        self.mediaAssets = mediaAssets
        self.sourceDuration = sourceDuration
        self.duration = cursor
    }

    public func transition(after clipID: UUID) -> DemoVideoTransition? {
        transitions.first { $0.fromClipID == clipID }
    }

    public func asset(for clip: DemoVideoClip) -> DemoMediaAsset? {
        guard let id = clip.mediaAssetID else { return nil }
        return mediaAssets.first { $0.id == id }
    }

    /// Full source range available to a clip, including frames trimmed from
    /// its current visible span. Imported movies have their own source length.
    public func sourceBounds(for clip: DemoVideoClip) -> ClosedRange<Double> {
        let limit: Double
        if let asset = asset(for: clip) {
            limit = asset.kind == .image ? 120 : asset.duration
        } else {
            limit = sourceDuration
        }
        return 0...limit
    }

    /// Applies a conventional keep-range cut to an already edited source
    /// timeline. The returned clips still refer to the same immutable movie.
    /// `DemoTimelineEdit.remap` handles the output-time overlays separately.
    public func clipped(to edit: DemoTimelineEdit) throws -> DemoVideoTimeline {
        guard abs(edit.sourceDuration - duration) <= 0.002 else {
            throw DemoVideoTimelineError.invalidOperation("Keep ranges target a different timeline duration.")
        }
        struct Piece {
            var clip: DemoVideoClip
            var sourceClipID: UUID
            var originalStart: Double
            var originalEnd: Double
            var keepRangeIndex: Int
        }
        var pieces: [Piece] = []
        var usedIDs = Set<UUID>()
        for (rangeIndex, range) in edit.ranges.enumerated() {
            for placement in placements {
                let lower = max(range.start, placement.start)
                let upper = min(range.end, placement.end)
                guard upper - lower > 0.000_001 else { continue }
                guard upper - lower >= 0.1 - 0.000_001 else {
                    throw DemoVideoTimelineError.invalidOperation("A cut would leave a clip shorter than 0.1 seconds.")
                }
                var clip = placement.clip
                clip.sourceStart += lower - placement.start
                clip.sourceEnd = placement.clip.sourceStart + upper - placement.start
                if !usedIDs.insert(clip.id).inserted { clip.id = UUID() }
                pieces.append(.init(clip: clip, sourceClipID: placement.clip.id,
                                    originalStart: lower, originalEnd: upper,
                                    keepRangeIndex: rangeIndex))
            }
        }
        guard !pieces.isEmpty else { throw DemoVideoTimelineError.lastClip }
        var keptTransitions: [DemoVideoTransition] = []
        for index in pieces.indices.dropLast() {
            let first = pieces[index], second = pieces[index + 1]
            guard first.keepRangeIndex == second.keepRangeIndex,
                  abs(first.originalEnd - second.originalStart) < 0.000_001,
                  let sourceIndex = placements.firstIndex(where: { $0.clip.id == first.sourceClipID }),
                  sourceIndex + 1 < placements.count,
                  placements[sourceIndex + 1].clip.id == second.sourceClipID,
                  let transition = transition(after: first.sourceClipID) else { continue }
            let join = first.originalEnd
            // A partly cut fade/flash has a different shape. Make it a plain
            // cut rather than silently stretching its remaining frames.
            let entireEffectSurvives = first.originalStart <= join - transition.resolvedOutgoingDuration + 0.000_001
                && second.originalEnd >= join + transition.resolvedIncomingDuration - 0.000_001
            if entireEffectSurvives {
                keptTransitions.append(.init(fromClipID: first.clip.id,
                                             preset: transition.preset,
                                             duration: transition.duration,
                                             outgoingDuration: transition.outgoingDuration,
                                             incomingDuration: transition.incomingDuration,
                                             outgoingCurve: transition.outgoingCurve,
                                             incomingCurve: transition.incomingCurve))
            }
        }
        return try DemoVideoTimeline(clips: pieces.map(\.clip),
                                     transitions: keptTransitions,
                                     sourceDuration: sourceDuration,
                                     mediaAssets: mediaAssets)
    }

    public func applying(_ operation: DemoVideoEditOperation, to project: RecordingProject) throws -> RecordingProject {
        var nextClips = clips
        var nextTransitions = transitions
        var parentIDs = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0.id) })
        switch operation {
        case let .split(clipID, at):
            guard let index = clips.firstIndex(where: { $0.id == clipID }) else { throw DemoVideoTimelineError.clipNotFound }
            guard at.isFinite else { throw DemoVideoTimelineError.invalidOperation("The split time is invalid.") }
            let position = placements[index]
            let sourceAt = clips[index].sourceStart + at - position.start
            guard at > position.start + 0.1 - 0.000_001,
                  at < position.end - 0.1 + 0.000_001 else {
                throw DemoVideoTimelineError.invalidOperation("Split at least 0.1 seconds inside the clip.")
            }
            var first = clips[index]
            first.sourceEnd = sourceAt
            let second = DemoVideoClip(sourceStart: sourceAt, sourceEnd: clips[index].sourceEnd,
                                       sourceAudioVolume: clips[index].sourceAudioVolume,
                                       mediaAssetID: clips[index].mediaAssetID)
            nextClips.replaceSubrange(index...index, with: [first, second])
            parentIDs[second.id] = clipID
            // An effect that belonged to the old clip's end still belongs to
            // its end after split; the newly created internal join is a cut.
            if let outgoing = nextTransitions.firstIndex(where: { $0.fromClipID == clipID }) {
                nextTransitions[outgoing].fromClipID = second.id
            }
        case let .trim(clipID, sourceStart, sourceEnd):
            guard let index = clips.firstIndex(where: { $0.id == clipID }) else { throw DemoVideoTimelineError.clipNotFound }
            let current = clips[index]
            let bounds = sourceBounds(for: current)
            guard sourceStart.isFinite, sourceEnd.isFinite,
                  sourceStart >= bounds.lowerBound - 0.000_001,
                  sourceEnd <= bounds.upperBound + 0.002,
                  sourceEnd - sourceStart >= 0.1 - 0.000_001 else {
                throw DemoVideoTimelineError.invalidOperation("Keep at least 0.1 seconds within the source movie.")
            }
            nextClips[index].sourceStart = max(bounds.lowerBound, sourceStart)
            nextClips[index].sourceEnd = min(bounds.upperBound, sourceEnd)
        case let .delete(clipID):
            guard let index = clips.firstIndex(where: { $0.id == clipID }) else { throw DemoVideoTimelineError.clipNotFound }
            guard clips.count > 1 else { throw DemoVideoTimelineError.lastClip }
            nextClips.remove(at: index)
            nextTransitions.removeAll { $0.fromClipID == clipID }
            if index > 0 {
                // The old preceding effect was authored for the deleted shot.
                // The newly exposed join starts as a plain cut.
                nextTransitions.removeAll { $0.fromClipID == clips[index - 1].id }
            }
        case let .move(clipID, toIndex):
            guard let index = clips.firstIndex(where: { $0.id == clipID }) else { throw DemoVideoTimelineError.clipNotFound }
            guard (0..<clips.count).contains(toIndex) else {
                throw DemoVideoTimelineError.invalidOperation("The destination clip index is outside the timeline.")
            }
            nextClips.insert(nextClips.remove(at: index), at: toIndex)
        case let .insertMedia(assetID, atIndex, requestedDuration):
            guard let asset = mediaAssets.first(where: { $0.id == assetID }) else {
                throw DemoVideoTimelineError.invalidOperation("Import the media into this project before adding it to the timeline.")
            }
            guard (0...clips.count).contains(atIndex) else {
                throw DemoVideoTimelineError.invalidOperation("The insertion point is outside the timeline.")
            }
            let clipDuration = requestedDuration ?? (asset.kind == .image ? 3 : asset.duration)
            guard clipDuration.isFinite, clipDuration >= 0.1,
                  (asset.kind == .image ? clipDuration <= 120 : clipDuration <= asset.duration + 0.002) else {
                throw DemoVideoTimelineError.invalidOperation("The inserted media duration is outside its valid range.")
            }
            nextClips.insert(.init(sourceStart: 0, sourceEnd: clipDuration,
                                   mediaAssetID: assetID), at: atIndex)
            // A newly created join needs to begin as a plain cut. A previous
            // effect belongs to its former neighbor, not the inserted shot.
            if atIndex > 0 {
                nextTransitions.removeAll { $0.fromClipID == clips[atIndex - 1].id }
            }
        case let .setImageDuration(clipID, requestedDuration):
            guard let index = clips.firstIndex(where: { $0.id == clipID }),
                  let asset = asset(for: clips[index]), asset.kind == .image else {
                throw DemoVideoTimelineError.invalidOperation("Select an image clip to change its display duration.")
            }
            guard requestedDuration.isFinite, (0.1...120).contains(requestedDuration),
                  clips[index].sourceStart + requestedDuration <= 120 + 0.002 else {
                throw DemoVideoTimelineError.invalidOperation("Image duration must be 0.1–120 seconds.")
            }
            nextClips[index].sourceEnd = nextClips[index].sourceStart + requestedDuration
        case let .setTransition(fromClipID, preset, effectDuration):
            guard let index = clips.dropLast().firstIndex(where: { $0.id == fromClipID }) else {
                throw DemoVideoTimelineError.invalidOperation("A transition needs a following clip.")
            }
            nextTransitions[index] = .init(fromClipID: fromClipID, preset: preset,
                                           duration: preset == .cut ? 0 : effectDuration)
        case let .setTransitionParameters(fromClipID, preset, outgoingDuration, incomingDuration,
                                          outgoingCurve, incomingCurve):
            guard let index = clips.dropLast().firstIndex(where: { $0.id == fromClipID }) else {
                throw DemoVideoTimelineError.invalidOperation("A transition needs a following clip.")
            }
            let duration = outgoingDuration + incomingDuration
            guard preset != .cut, outgoingDuration.isFinite, incomingDuration.isFinite,
                  duration.isFinite, (0.1...2).contains(duration),
                  outgoingDuration >= 0, incomingDuration >= 0 else {
                throw DemoVideoTimelineError.invalidOperation("Set a 0.1–2 second effect with non-negative exit and entry times; use Cut for no effect.")
            }
            nextTransitions[index] = .init(fromClipID: fromClipID, preset: preset,
                                           duration: duration,
                                           outgoingDuration: outgoingDuration,
                                           incomingDuration: incomingDuration,
                                           outgoingCurve: outgoingCurve,
                                           incomingCurve: incomingCurve)
        case let .setClipAudio(clipID, volume):
            guard let index = clips.firstIndex(where: { $0.id == clipID }) else { throw DemoVideoTimelineError.clipNotFound }
            guard volume.isFinite, (0...2).contains(volume) else {
                throw DemoVideoTimelineError.invalidOperation("Source audio volume must be between 0 and 2.")
            }
            nextClips[index].sourceAudioVolume = volume
        }

        // Effects remain attached to an outgoing clip after a move, unless it
        // becomes last. An absent join always has the plain-cut default.
        let outgoing = Set(nextClips.dropLast().map(\.id))
        nextTransitions.removeAll { !outgoing.contains($0.fromClipID) }
        let next = try DemoVideoTimeline(clips: nextClips, transitions: nextTransitions,
                                         sourceDuration: sourceDuration, mediaAssets: mediaAssets)
        if next.clips == clips && next.transitions == transitions {
            var unchanged = project
            unchanged.videoClips = next.clips
            unchanged.videoTransitions = next.transitions
            unchanged.videoSourceDuration = sourceDuration
            unchanged.duration = next.duration
            return unchanged
        }
        switch operation {
        case .setTransition, .setTransitionParameters, .setClipAudio:
            // These are presentation/audio choices. Retiming every event here
            // would needlessly replace trace IDs and turn automatic zooms into
            // manual blocks even though no frame moved.
            var result = project
            result.videoClips = next.clips
            result.videoTransitions = next.transitions
            result.videoSourceDuration = sourceDuration
            result.duration = next.duration
            return result
        default:
            break
        }
        let spans: [TimeSpan] = next.placements.compactMap { placement in
            guard let parentID = parentIDs[placement.clip.id],
                  let previous = placements.first(where: { $0.clip.id == parentID }) else { return nil }
            let lower = max(placement.clip.sourceStart, previous.clip.sourceStart)
            let upper = min(placement.clip.sourceEnd, previous.clip.sourceEnd)
            guard upper > lower else { return nil }
            return TimeSpan(oldStart: previous.start + lower - previous.clip.sourceStart,
                            oldEnd: previous.start + upper - previous.clip.sourceStart,
                            newStart: placement.start + lower - placement.clip.sourceStart)
        }
        var result = remapMetadata(project, through: spans, to: next)
        result.videoClips = next.clips
        result.videoTransitions = next.transitions
        result.videoSourceDuration = sourceDuration
        result.duration = next.duration
        return result
    }
}

private struct TimeSpan {
    let oldStart: Double
    let oldEnd: Double
    let newStart: Double
    var newEnd: Double { newStart + oldEnd - oldStart }

    func maps(_ time: Double, final: Bool = false) -> Bool {
        time >= oldStart && (time < oldEnd || final && abs(time - oldEnd) < 0.000_001)
    }
    func translated(_ time: Double) -> Double { newStart + time - oldStart }
}

private func remapMetadata(_ original: RecordingProject, through spans: [TimeSpan], to timeline: DemoVideoTimeline) -> RecordingProject {
    var result = original
    func mapPoint(_ time: Double) -> Double? {
        for (index, span) in spans.enumerated() where span.maps(time, final: index == spans.count - 1) {
            return span.translated(time)
        }
        return nil
    }
    func mapPoints<T>(_ values: [T], time: (T) -> Double, update: (T, Double) -> T) -> [T] {
        spans.flatMap { span in
            values.compactMap { value -> T? in
                let source = time(value)
                guard span.maps(source, final: span.newEnd == timeline.duration) else { return nil }
                return update(value, span.translated(source))
            }
        }
    }
    result.clickEvents = mapPoints(original.clickEvents, time: { $0.time }) { var value = $0; value.time = $1; return value }
    result.typingActivity = original.typingActivity.map {
        mapPoints($0, time: { $0.time }) { .init(time: $1, x: $0.x, y: $0.y) }
    }
    let sortedSamples = original.cursorSamples.filter { $0.time.isFinite }.sorted { $0.time < $1.time }
    result.cursorSamples = spans.flatMap { span -> [CursorSample] in
        var values: [CursorSample] = []
        if var first = sortedSamples.last(where: { $0.time <= span.oldStart }) {
            first.time = span.newStart
            values.append(first)
        }
        values += sortedSamples.filter { span.maps($0.time) }.map { sample in
            var copy = sample; copy.time = span.translated(sample.time); return copy
        }
        if var last = sortedSamples.last(where: { $0.time < span.oldEnd }) {
            last.time = max(span.newStart, span.newEnd - 0.000_001)
            values.append(last)
        }
        return values
    }
    var cuts = (original.editCutTimes ?? []).compactMap(mapPoint)
    for placement in timeline.placements where placement.clip.mediaAssetID != nil {
        cuts.append(placement.start)
        cuts.append(placement.end)
    }
    for index in spans.indices where index > 0 {
        let previous = spans[index - 1], current = spans[index]
        if abs(previous.oldEnd - current.oldStart) > 0.000_001 { cuts.append(current.newStart) }
    }
    cuts = Set(cuts.filter { $0.isFinite && $0 > 0 && $0 < timeline.duration }).sorted()
    result.editCutTimes = cuts.isEmpty ? nil : cuts
    if let trace = original.interactionTrace {
        let sorted = trace.events.filter { $0.time.isFinite }.sorted {
            $0.time != $1.time ? $0.time < $1.time : $0.sequence < $1.sequence
        }
        let resolved = trace.resolved(duration: original.duration)
        var events: [InteractionEvent] = []
        var generation = 0
        for (index, span) in spans.enumerated() {
            let discontinuous = index == 0 || abs(spans[index - 1].oldEnd - span.oldStart) > 0.000_001
            if discontinuous {
                generation += 1
                events.append(.init(sequence: events.count, time: span.newStart, kind: .discontinuity,
                                    geometryGeneration: generation))
                if resolved.cursorIsAvailable(at: span.oldStart),
                   let pose = resolved.cursorSamples.last(where: { $0.time <= span.oldStart }) {
                    events.append(.init(sequence: events.count, time: span.newStart, kind: .move,
                                        x: pose.x, y: pose.y, cursorKind: pose.cursorKind,
                                        geometryGeneration: generation))
                }
            }
            var previousGeometry: Int?
            for event in sorted where span.maps(event.time, final: index == spans.count - 1) {
                if let previousGeometry, previousGeometry != event.geometryGeneration { generation += 1 }
                previousGeometry = event.geometryGeneration
                var copy = event
                copy.time = span.translated(event.time)
                copy.sequence = events.count
                copy.geometryGeneration = generation
                events.append(copy)
            }
        }
        let typing = trace.typingActivity.map { _ in
            mapPoints(trace.resolvedTypingActivity(duration: original.duration), time: { $0.time }) {
                .init(time: $1, x: $0.x, y: $0.y)
            }
        }
        result.interactionTrace = InteractionTrace(sessionID: UUID(), source: trace.source,
            cursorDisplayMode: trace.cursorDisplayMode, events: events, typingActivity: typing)
        if trace.source == .execution { result.typingActivity = typing ?? [] }
    }
    result.zoomSegments = original.zoomSegments.flatMap { zoom -> [ZoomSegment] in
        var pieces: [ZoomSegment] = []
        for span in spans {
            let lower = max(zoom.start, span.oldStart), upper = min(zoom.end, span.oldEnd)
            guard upper - lower >= 0.001 else { continue }
            var copy = zoom
            if !pieces.isEmpty { copy.id = UUID() }
            copy.start = span.translated(lower)
            copy.end = span.translated(upper)
            copy.isEnabled = zoom.isEnabled && (zoom.kind == .manual || original.settings.autoZoomEnabled)
            copy.kind = .manual
            copy.zoomEaseIn = min(copy.zoomEaseIn ?? original.settings.zoomEaseIn, (copy.end - copy.start) / 2)
            copy.zoomEaseOut = min(copy.zoomEaseOut ?? original.settings.zoomEaseOut, (copy.end - copy.start) / 2)
            if let source = zoom.automaticSource ?? (zoom.kind == .automatic
                ? ZoomAutomaticSource(start: zoom.start, targetX: zoom.targetX,
                    targetY: zoom.targetY, originalEnd: zoom.end) : nil) {
                let clickIDs = source.clickIDs.map { ids in
                    ids.filter { id in
                        result.resolvedClickEvents.contains { click in
                            click.id == id && click.time >= copy.start && click.time < copy.end
                        }
                    }
                }
                let typing = source.typingActivity.map { activity in
                    activity.compactMap { item -> TypingActivity? in
                        guard span.maps(item.time) else { return nil }
                        return .init(time: span.translated(item.time), x: item.x, y: item.y)
                    }
                }
                copy.automaticSource = ZoomAutomaticSource(
                    start: span.maps(source.start) ? span.translated(source.start) : copy.start,
                    targetX: source.targetX, targetY: source.targetY,
                    eventTime: source.eventTime.flatMap { span.maps($0) ? span.translated($0) : nil },
                    clickIDs: clickIDs, typingActivity: typing,
                    originalEnd: source.originalEnd.flatMap { span.maps($0) ? span.translated($0) : nil } ?? copy.end)
            }
            pieces.append(copy)
        }
        return pieces
    }.sorted { $0.start < $1.start }
    result.chapters = original.chapters.map { chapters in
        chapters.flatMap { chapter -> [DemoChapter] in
            var pieces: [DemoChapter] = []
            for span in spans {
                let lower = max(chapter.start, span.oldStart), upper = min(chapter.end, span.oldEnd)
                guard upper - lower >= 0.001 else { continue }
                var copy = chapter
                if !pieces.isEmpty { copy.id = UUID() }
                copy.start = span.translated(lower)
                copy.end = span.translated(upper)
                pieces.append(copy)
            }
            return pieces
        }
    }
    return result
}
