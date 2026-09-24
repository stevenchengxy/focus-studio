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
struct RecordingAttempt: Equatable {
    let id: UUID
    let target: CaptureTargetInfo
    let settings: RecordingSettings
    /// Seconds after the capture's first frame at which the app stops the
    /// recording by itself; nil records until someone stops it.
    let duration: TimeInterval?
    /// The first frame's time on the uptime clock: the recording's real
    /// start, after the countdown and the capture start. Nil until then.
    var startUptime: TimeInterval?
    var startedAt: Date?
    var outcome: AIRecordingOutcome?
    var endedAt: Date?

    init(id: UUID = UUID(), target: CaptureTargetInfo, settings: RecordingSettings, duration: TimeInterval?) {
        self.id = id
        self.target = target
        self.settings = settings
        self.duration = duration
    }

    /// Frames are arriving and nothing has ended it yet (a stop that is
    /// saving it included).
    var isLive: Bool { startUptime != nil && outcome == nil }

    /// When the app stops it by itself, on the uptime clock.
    var automaticStopUptime: TimeInterval? {
        guard let startUptime, let duration else { return nil }
        return startUptime + duration
    }

    var session: AIRecordingSession {
        AIRecordingSession(id: id, sourceID: target.id, startedAt: startedAt, duration: duration, outcome: outcome, endedAt: endedAt)
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
