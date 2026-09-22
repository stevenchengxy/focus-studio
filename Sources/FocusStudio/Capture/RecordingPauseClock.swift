import Foundation

/// A recording is a sequence of active intervals. Wall-clock time spent paused,
/// flushing a writer, or waiting for the first resumed frame never enters media.
public struct RecordingPauseClock: Sendable, Equatable {
    public private(set) var firstFrameUptime: TimeInterval?
    public private(set) var activeStartUptime: TimeInterval?
    public private(set) var completedDuration: TimeInterval = 0
    private var lastSegmentDuration: TimeInterval = 0
    private var lastPauseUptime: TimeInterval?

    public init() {}

    @discardableResult
    public mutating func anchor(at uptime: TimeInterval) -> Bool {
        guard uptime.isFinite, uptime >= 0, activeStartUptime == nil,
              lastPauseUptime.map({ uptime >= $0 }) ?? true else { return false }
        if firstFrameUptime == nil { firstFrameUptime = uptime }
        activeStartUptime = uptime
        return true
    }

    /// Returns the just-ended interval length; repeated pauses are idempotent.
    @discardableResult
    public mutating func pause(at uptime: TimeInterval) -> TimeInterval? {
        guard uptime.isFinite, let start = activeStartUptime, uptime >= start else { return nil }
        lastSegmentDuration = uptime - start
        completedDuration += lastSegmentDuration
        activeStartUptime = nil
        lastPauseUptime = uptime
        return lastSegmentDuration
    }

    /// The real video's encodable duration may end up shorter by a frame.
    /// Reconcile before resuming, so every later event shares the media boundary.
    public mutating func reconcileLastSegment(duration: TimeInterval) {
        guard activeStartUptime == nil, duration.isFinite, duration >= 0, firstFrameUptime != nil else { return }
        let resolved = min(lastSegmentDuration, duration)
        completedDuration += resolved - lastSegmentDuration
        lastSegmentDuration = resolved
    }

    public func mediaTime(at uptime: TimeInterval) -> TimeInterval? {
        guard uptime.isFinite, let start = activeStartUptime, uptime >= start else { return nil }
        return completedDuration + uptime - start
    }

    public func elapsed(at uptime: TimeInterval) -> TimeInterval {
        mediaTime(at: uptime) ?? completedDuration
    }
}

/// FIFO main-actor gate for pause/resume/finish. No transition can finish a
/// writer that another transition is still opening or flushing.
@MainActor
public final class RecordingTransitionGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public func acquire() async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    public func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }
}
