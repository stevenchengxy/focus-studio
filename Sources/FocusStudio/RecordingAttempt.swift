import FocusStudioAutomation
import FocusStudioCapture
import FocusStudioCore
import Foundation

/// The recorder options one recording uses: the choices the person made in
/// the recorder, with whatever a start_recording call overrode for that
/// recording only. The recorder's own choices never change for it.
struct RecordingSettings: Equatable {
    var systemAudio: Bool
    var microphone: Bool
    var automaticZooms: Bool
    var browserContentOnly: Bool
    var frameRate: Int
    /// Whether the project shows the recorded pointer (the recorder's Show
    /// cursor); a call cannot change it.
    var showCursor: Bool = true

    /// What this recording captures besides the screen, for the recording
    /// UI (a key of the string catalogs, in English); nil for no audio. An
    /// AI tool can turn audio on for one recording, so the countdown and the
    /// control bar say so.
    var audioDescription: String? {
        switch (microphone, systemAudio) {
        case (true, true): return "Recording microphone and system audio"
        case (true, false): return "Recording microphone"
        case (false, true): return "Recording system audio"
        case (false, false): return nil
        }
    }

    /// These settings with the options a call gave (nil keeps a setting).
    func applying(_ options: AIRecordingOptions) -> RecordingSettings {
        var settings = self
        if let value = options.systemAudio { settings.systemAudio = value }
        if let value = options.microphone { settings.microphone = value }
        if let value = options.automaticZooms { settings.automaticZooms = value }
        if let value = options.browserContentOnly { settings.browserContentOnly = value }
        if let value = options.frameRate { settings.frameRate = value }
        return settings
    }
}

/// One recording attempt: its countdown, its capture and how it ended.
/// StudioModel keeps the latest; the recording tools follow it through
/// ``AIRecordingSession``, and its duration stops it by itself.
///
/// The person can pause a live recording from the control bar. A pause
/// records nothing, so every length here is recorded time: `duration`,
/// the time recorded so far and the time left all leave paused time out,
/// as the video does. `intervals` mirrors the capture's own active
/// intervals (``RecordingPauseClock``) after every pause and resume.
struct RecordingAttempt: Equatable {
    let id: UUID
    let target: CaptureTargetInfo
    let settings: RecordingSettings
    /// Seconds of recording (after the capture's first frame, paused time
    /// left out) after which the app stops the recording by itself; nil
    /// records until someone stops it.
    let duration: TimeInterval?
    /// The AI tool whose call started this recording (the control bar names
    /// it from the countdown on); nil for the person's own recordings.
    var requester: String?
    /// The first frame's time on the uptime clock: the recording's real
    /// start, after the countdown and the capture start. Nil until then.
    var startUptime: TimeInterval?
    var startedAt: Date?
    /// The recording's active intervals on the uptime clock: anchored at the
    /// first frame, closed by a pause, reopened at a resume's first frame.
    var intervals = RecordingPauseClock()
    var outcome: AIRecordingOutcome?
    var endedAt: Date?

    init(id: UUID = UUID(), target: CaptureTargetInfo, settings: RecordingSettings, duration: TimeInterval?) {
        self.id = id
        self.target = target
        self.settings = settings
        self.duration = duration
    }

    /// Frames are arriving (or the recording is paused) and nothing has
    /// ended it yet (a stop that is saving it included).
    var isLive: Bool { startUptime != nil && outcome == nil }

    /// Live and paused: no frames or sound are being recorded.
    var isPaused: Bool { isLive && intervals.firstFrameUptime != nil && intervals.activeStartUptime == nil }

    /// Seconds recorded by `now`, paused time left out.
    func recordedDuration(at now: TimeInterval) -> TimeInterval {
        max(0, intervals.elapsed(at: now))
    }

    /// Seconds of recording left before the duration stops it; it does not
    /// count down while paused. Nil without a duration.
    func remaining(at now: TimeInterval) -> TimeInterval? {
        duration.map { max(0, $0 - recordedDuration(at: now)) }
    }

    /// Seconds spent paused since the first frame, by `now`.
    func pausedDuration(at now: TimeInterval) -> TimeInterval {
        guard let startUptime else { return 0 }
        return max(0, now - startUptime - recordedDuration(at: now))
    }

    /// When the app stops it by itself, on the uptime clock: the current
    /// active interval's start plus the recorded time left. Nil while paused
    /// (the duration waits for the resume) and without a duration.
    var automaticStopUptime: TimeInterval? {
        guard let duration, let activeStart = intervals.activeStartUptime else { return nil }
        return activeStart + max(0, duration - intervals.completedDuration)
    }

    func session(at now: TimeInterval) -> AIRecordingSession {
        AIRecordingSession(
            id: id, sourceID: target.id, startedAt: startedAt, duration: duration, outcome: outcome, endedAt: endedAt,
            isPaused: isPaused, pausedDuration: pausedDuration(at: now)
        )
    }
}

/// Pauses and resumes a live capture, and reports its active intervals.
/// The engine by default; regression tests script it on their manual clock.
struct CapturePauseControl {
    /// Stops writing media until ``resume``; throws when it could not (the
    /// capture then reports whether it is paused through ``intervals``).
    var pause: @MainActor (CaptureEngine) async throws -> Void
    /// Records again from the same source; returns once its first frame arrived.
    var resume: @MainActor (CaptureEngine) async throws -> Void
    /// The capture's active intervals as it measures them now.
    var intervals: @MainActor (CaptureEngine) -> RecordingPauseClock

    static var engine: CapturePauseControl {
        CapturePauseControl(
            pause: { try await $0.pauseRecording() },
            resume: { try await $0.resumeRecording() },
            intervals: { $0.recordingIntervals }
        )
    }
}

/// The clock countdowns and automatic stops are measured on: seconds of
/// `ProcessInfo.systemUptime`, the clock capture timestamps use, and a way
/// to wait on it that throws when cancelled. Regression tests substitute a
/// manual clock so no test waits on the wall clock.
struct RecordingClock {
    var now: @MainActor () -> TimeInterval
    var sleep: @MainActor (TimeInterval) async throws -> Void

    static var system: RecordingClock {
        RecordingClock(
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
        )
    }
}

/// Starts a capture and answers the uptime of its first complete frame.
typealias CaptureStarter = @MainActor (CaptureEngine, CaptureTargetInfo, URL, CaptureOptions) async throws -> TimeInterval
