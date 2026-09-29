import Foundation

/// The producer whose pointer and clicks own a recording. A trace is selected
/// as a whole: execution events must never be combined with an unrelated
/// physical pointer moving elsewhere on the desktop.
public enum InteractionSource: String, Codable, Hashable, Sendable {
    case system
    case execution
}

/// Pointer pixels and camera tracking are independent. Embedded pointers are
/// already in the video; hidden pointers can still provide a camera target.
public enum InteractionCursorDisplayMode: String, Codable, Hashable, Sendable {
    case overlay
    case embedded
    case hidden
}

public enum InteractionEventKind: String, Codable, Hashable, Sendable {
    case move
    case click
    case scroll
    /// Navigation, a changed capture geometry, or another loss of continuity.
    case discontinuity
}

/// Coordinates describe the pointer hot spot in the uncropped recorded frame,
/// normalized to 0...1 from its top-left corner. Time is active recording time
/// from the first captured frame, with paused intervals already removed.
/// Text, key codes and page content are deliberately absent.
public struct InteractionEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sequence: Int
    public var time: Double
    public var kind: InteractionEventKind
    public var x: Double?
    public var y: Double?
    public var cursorKind: CursorKind
    public var button: MouseButton
    public var geometryGeneration: Int

    public init(
        id: UUID = UUID(),
        sequence: Int,
        time: Double,
        kind: InteractionEventKind,
        x: Double? = nil,
        y: Double? = nil,
        cursorKind: CursorKind = .arrow,
        button: MouseButton = .left,
        geometryGeneration: Int = 0
    ) {
        self.id = id
        self.sequence = sequence
        self.time = time
        self.kind = kind
        self.x = x
        self.y = y
        self.cursorKind = cursorKind
        self.button = button
        self.geometryGeneration = geometryGeneration
    }
}

public struct InteractionTrace: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var source: InteractionSource
    public var cursorDisplayMode: InteractionCursorDisplayMode
    public var events: [InteractionEvent]
    /// Successfully dispatched text input, in active media time and uncropped
    /// field coordinates. Separate from pointer events; never stores text or
    /// key codes. Optional for traces written before typing capture existed.
    public var typingActivity: [TypingActivity]?

    public init(
        sessionID: UUID,
        source: InteractionSource,
        cursorDisplayMode: InteractionCursorDisplayMode = .overlay,
        events: [InteractionEvent] = [],
        typingActivity: [TypingActivity]? = nil
    ) {
        self.sessionID = sessionID
        self.source = source
        self.cursorDisplayMode = cursorDisplayMode
        self.events = events
        self.typingActivity = typingActivity
    }

    public func resolvedTypingActivity(duration: Double) -> [TypingActivity] {
        guard duration.isFinite, duration >= 0 else { return [] }
        var seen: Set<TypingActivity> = []
        return (typingActivity ?? []).filter { activity in
            activity.time.isFinite && activity.time >= 0 && activity.time <= duration
                && activity.x.isFinite && (0...1).contains(activity.x)
                && activity.y.isFinite && (0...1).contains(activity.y)
                && seen.insert(activity).inserted
        }.sorted {
            if $0.time != $1.time { return $0.time < $1.time }
            if $0.x != $1.x { return $0.x < $1.x }
            return $0.y < $1.y
        }
    }

    /// Invalid events are rejected rather than clamped onto another control.
    /// Stable IDs make replaying a transport batch harmless.
    public func resolved(duration: Double) -> InteractionTraceResolution {
        var seen: Set<UUID> = []
        var valid: [InteractionEvent] = []
        var rejected = 0
        var duplicates = 0
        for event in events {
            guard duration.isFinite, duration >= 0,
                  event.time.isFinite, event.time >= 0, event.time <= duration,
                  event.sequence >= 0, event.geometryGeneration >= 0,
                  event.x.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                  event.y.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                  event.kind == .discontinuity || Self.hasValidPoint(event) else {
                rejected += 1
                continue
            }
            guard seen.insert(event.id).inserted else {
                duplicates += 1
                continue
            }
            valid.append(event)
        }
        valid.sort {
            if $0.time != $1.time { return $0.time < $1.time }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id.uuidString < $1.id.uuidString
        }
        var samples: [CursorSample] = []
        var clicks: [ClickEvent] = []
        var segments: [[CursorSample]] = []
        var current: [CursorSample] = []
        var cuts: [Double] = []
        var generation: Int?
        var availableSince: Double?
        var availability: [Range<Double>] = []
        func finishSegment() {
            if !current.isEmpty { segments.append(current) }
            current = []
        }
        for event in valid {
            let changedGeometry = generation != nil && generation != event.geometryGeneration
            if changedGeometry || event.kind == .discontinuity {
                finishSegment()
                if cuts.last != event.time { cuts.append(event.time) }
                if let start = availableSince, start < event.time {
                    availability.append(start..<event.time)
                }
                availableSince = nil
            }
            generation = event.geometryGeneration
            if event.kind == .discontinuity { continue }
            guard let x = event.x, let y = event.y else { continue }
            if availableSince == nil { availableSince = event.time }
            let sample = CursorSample(time: event.time, x: x, y: y, cursorKind: event.cursorKind)
            // A gap has no measured motion. Keep the last known position until
            // new observations arrive instead of inventing a long slow sweep.
            if let previous = current.last, event.time - previous.time > 0.25 {
                finishSegment()
            }
            if current.last?.time == event.time { current[current.count - 1] = sample }
            else { current.append(sample) }
            if samples.last?.time == event.time { samples[samples.count - 1] = sample }
            else { samples.append(sample) }
            if event.kind == .click {
                clicks.append(ClickEvent(id: event.id, time: event.time, x: x, y: y, button: event.button))
            }
        }
        finishSegment()
        if let start = availableSince { availability.append(start..<Double.infinity) }
        return InteractionTraceResolution(
            cursorSamples: samples,
            clickEvents: clicks,
            discontinuityTimes: cuts,
            rejectedEventCount: rejected,
            deduplicatedEventCount: duplicates,
            cursorSegments: segments,
            isTraceBacked: true,
            usesExecutionMotion: source == .execution,
            availabilityRanges: availability
        )
    }

    private static func hasValidPoint(_ event: InteractionEvent) -> Bool {
        guard let x = event.x, let y = event.y else { return false }
        return x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }
}

public struct InteractionTraceResolution: Sendable {
    public let cursorSamples: [CursorSample]
    public let clickEvents: [ClickEvent]
    public let discontinuityTimes: [Double]
    public let rejectedEventCount: Int
    public let deduplicatedEventCount: Int
    public let cursorSegments: [[CursorSample]]
    public let isTraceBacked: Bool
    public let usesExecutionMotion: Bool
    let availabilityRanges: [Range<Double>]

    /// Smooth only continuously measured paths. Holding the previous endpoint
    /// until the next segment prevents interpolation across idle time or cuts.
    public func renderedCursorSamples(sigma: Double) -> [CursorSample] {
        guard usesExecutionMotion else {
            return sigma > 0
                ? CursorMotion.smoothedPath(samples: cursorSamples, clicks: clickEvents, sigma: sigma)
                : cursorSamples
        }
        var result: [CursorSample] = []
        for segment in cursorSegments {
            guard let first = segment.first, let last = segment.last else { continue }
            let clicks = clickEvents.filter { $0.time >= first.time && $0.time <= last.time }
            let rendered = sigma > 0
                ? InteractionCursorMotion.smoothedPath(samples: segment, clicks: clicks, sigma: sigma)
                : segment
            if var hold = result.last, first.time - hold.time > 0.000_002 {
                hold.time = first.time - 0.000_001
                result.append(hold)
            }
            result.append(contentsOf: rendered)
        }
        return result
    }

    /// A navigation cut hides stale coordinates until a new point is observed.
    /// Legacy projects retain their existing first-sample display behavior.
    public func cursorIsAvailable(at time: Double) -> Bool {
        guard usesExecutionMotion else { return !cursorSamples.isEmpty }
        var low = 0
        var high = availabilityRanges.count
        while low < high {
            let middle = (low + high) / 2
            if availabilityRanges[middle].lowerBound <= time { low = middle + 1 }
            else { high = middle }
        }
        return low > 0 && availabilityRanges[low - 1].contains(time)
    }
}

public extension RecordingProject {
    /// Manual consumers receive the original unfiltered metadata, exactly as
    /// before trace support. Execution metadata is validated at its boundary.
    var resolvedClickEvents: [ClickEvent] {
        interactionTrace?.resolved(duration: duration).clickEvents ?? clickEvents
    }

    /// A present trace is authoritative even when empty or invalid. Falling
    /// back to system samples would move the rendered pointer to someone else.
    var resolvedInteractions: InteractionTraceResolution {
        if let interactionTrace { return interactionTrace.resolved(duration: duration) }
        let samples = cursorSamples
            .filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }
            .sorted { $0.time < $1.time }
        return InteractionTraceResolution(
            cursorSamples: samples,
            clickEvents: clickEvents.filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite },
            discontinuityTimes: [],
            rejectedEventCount: 0,
            deduplicatedEventCount: 0,
            cursorSegments: samples.isEmpty ? [] : [samples],
            isTraceBacked: false,
            usesExecutionMotion: false,
            availabilityRanges: []
        )
    }

    var resolvedCursorOverlayVisible: Bool {
        guard interactionTrace?.source == .execution else { return settings.resolvedShowCursor }
        return settings.resolvedShowCursor && interactionTrace?.cursorDisplayMode == .overlay
    }

    var resolvedCursorFollowEnabled: Bool {
        // Trace-backed recordings can track an embedded or intentionally hidden
        // pointer. Existing recordings preserve the old show-cursor behavior.
        interactionTrace?.source == .execution || settings.resolvedShowCursor
    }

    var resolvedTypingActivity: [TypingActivity] {
        guard let trace = interactionTrace, trace.source == .execution else { return typingActivity ?? [] }
        return trace.resolvedTypingActivity(duration: duration)
    }
}
