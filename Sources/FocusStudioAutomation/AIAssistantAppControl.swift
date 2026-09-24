import CoreGraphics
import FocusStudioCore
import Foundation

// MARK: - App control seam

/// A display or window the app can record, described the way the model sees it.
public struct AIRecordingSource: Equatable, Sendable, Identifiable {
    public var id: String
    var kind: CaptureTargetKind
    var appName: String?
    var title: String
    var width: Int
    var height: Int
    /// The display with the menu bar (`CGMainDisplayID`), which "display" means.
    var isMainDisplay: Bool

    init(id: String, kind: CaptureTargetKind, appName: String? = nil, title: String, width: Int, height: Int, isMainDisplay: Bool = false) {
        self.id = id
        self.kind = kind
        self.appName = appName
        self.title = title
        self.width = width
        self.height = height
        self.isMainDisplay = isMainDisplay
    }

    public init(target: CaptureTargetInfo) {
        self.init(target: target, mainDisplayID: CGMainDisplayID())
    }

    init(target: CaptureTargetInfo, mainDisplayID: CGDirectDisplayID) {
        self.init(
            id: target.id,
            kind: target.kind,
            appName: target.appName,
            title: target.title,
            width: Int(target.frame.width.rounded()),
            height: Int(target.frame.height.rounded()),
            // Window numbers can equal a display id; only displays qualify.
            isMainDisplay: target.kind == .display && target.nativeID == mainDisplayID
        )
    }

    var area: Int { max(0, width) * max(0, height) }

    /// The source for a program: id, kind, app, title, size and whether it is the main display.
    var data: AIJSONValue {
        [
            "id": AIJSONValue(id),
            "kind": AIJSONValue(kind.rawValue),
            "app": appName.map { AIJSONValue($0) } ?? .null,
            "title": AIJSONValue(title),
            "width": AIJSONValue(width),
            "height": AIJSONValue(height),
            "main": AIJSONValue(isMainDisplay),
        ]
    }

    /// What the person reads: a display's name, or a window's app and title
    /// ("Safari — Docs"), as the sound prompt and the control bar name it.
    public var displayName: String {
        if kind == .window, let appName, !appName.isEmpty, appName != title {
            return title.isEmpty ? appName : "\(appName) — \(title)"
        }
        return title.isEmpty ? (appName ?? kind.rawValue) : title
    }

    /// One line for the model, e.g. `id win-12 · window · Safari — Docs · 1440×900`.
    var summaryLine: String {
        var parts = ["id \(id)", kind.rawValue]
        if let appName, !appName.isEmpty, kind == .window {
            parts.append(title.isEmpty ? appName : "\(appName) — \(title)")
        } else {
            parts.append(title.isEmpty ? (appName ?? kind.rawValue) : title)
        }
        parts.append("\(width)×\(height)")
        if isMainDisplay { parts.append("main") }
        return parts.joined(separator: " · ")
    }

    /// The displays among `sources` in the order "display 1", "display 2", …
    /// use: the main display first, then the others in the app's (system) order.
    static func orderedDisplays(_ sources: [AIRecordingSource]) -> [AIRecordingSource] {
        let displays = sources.filter { $0.kind == .display }
        return displays.filter(\.isMainDisplay) + displays.filter { !$0.isMainDisplay }
    }
}

/// Where the app is in the record → stop cycle, as far as the tools care.
public enum AIRecordingPhase: Equatable, Sendable {
    case idle
    /// The 3-second countdown (or the capture start) is under way.
    case countdown
    case recording
    case stopping
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "idle"
        case .countdown: return "counting down"
        case .recording: return "recording"
        case .stopping: return "stopping"
        case let .failed(message): return "failed: \(message)"
        }
    }

    /// A stable word for programs: idle, countdown, recording, stopping or failed.
    var code: String {
        switch self {
        case .idle: return "idle"
        case .countdown: return "countdown"
        case .recording: return "recording"
        case .stopping: return "stopping"
        case .failed: return "failed"
        }
    }
}

/// Which privacy permissions the app holds, read with the non-prompting
/// preflight calls so asking never shows a system dialog.
public struct AIPermissionStatus: Equatable, Sendable {
    /// `CGPreflightScreenCaptureAccess`: needed for any recording.
    public var screenRecording: Bool
    /// `AXIsProcessTrusted`: needed for automatic zooms on clicks.
    public var accessibility: Bool
    /// `CGPreflightListenEventAccess`: needed for automatic zooms on typing.
    public var inputMonitoring: Bool

    public init(screenRecording: Bool, accessibility: Bool, inputMonitoring: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }
}

/// Options for one recording. They apply to that recording only: nil keeps
/// the recorder's own choice, and nothing here changes the choices the person
/// made in the recorder.
public struct AIRecordingOptions: Equatable, Sendable {
    public var systemAudio: Bool?
    public var microphone: Bool?
    public var automaticZooms: Bool?
    public var browserContentOnly: Bool?
    public var frameRate: Int?
    /// Seconds of recording after which the app stops it by itself, through
    /// the same stop as the Finish button: counted from the capture's actual
    /// start (after the countdown), with time the person spends paused left
    /// out; nil records until stopped.
    public var duration: TimeInterval?

    /// What `duration` may be: one second to ten minutes.
    public static let durationRange: ClosedRange<TimeInterval> = 1...600

    public init(systemAudio: Bool? = nil, microphone: Bool? = nil, automaticZooms: Bool? = nil, browserContentOnly: Bool? = nil, frameRate: Int? = nil, duration: TimeInterval? = nil) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.automaticZooms = automaticZooms
        self.browserContentOnly = browserContentOnly
        self.frameRate = frameRate
        self.duration = duration
    }
}

/// The sound a recording captures besides the screen.
public struct AIRecordingAudio: Equatable, Sendable {
    public var microphone: Bool
    public var systemAudio: Bool

    public init(microphone: Bool = false, systemAudio: Bool = false) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    public var isEmpty: Bool { !microphone && !systemAudio }

    /// The sources by their start_recording argument names, for structured results.
    public var argumentNames: [String] {
        (microphone ? ["microphone"] : []) + (systemAudio ? ["system_audio"] : [])
    }

    /// "the microphone", "system audio" or both, for texts to the model.
    public var phrase: String {
        switch (microphone, systemAudio) {
        case (true, true): return "the microphone and system audio"
        case (true, false): return "the microphone"
        case (false, true): return "system audio"
        case (false, false): return "no sound"
        }
    }

    /// The sound `options` turns on that `recorder` (the person's own recorder
    /// settings) would not record: what an AI tool must ask the person for.
    public static func added(by options: AIRecordingOptions, to recorder: AIRecordingAudio) -> AIRecordingAudio {
        AIRecordingAudio(
            microphone: options.microphone == true && !recorder.microphone,
            systemAudio: options.systemAudio == true && !recorder.systemAudio
        )
    }
}

/// What an external start_recording asks the person before its countdown:
/// the sound the call turns on for this recording that the person's own
/// recorder settings leave off.
public struct AIRecordingAudioConsentRequest: Equatable, Sendable {
    public var audio: AIRecordingAudio
    /// The source to record, as the person reads it (``AIRecordingSource/displayName``).
    public var sourceName: String

    public init(audio: AIRecordingAudio, sourceName: String) {
        self.audio = audio
        self.sourceName = sourceName
    }
}

/// The person's answer to a sound prompt, as start_recording gets it.
public enum AIRecordingAudioConsent: Equatable, Sendable {
    /// Record with the sound asked for, this recording only.
    case allowed
    /// Record the screen only: no sound at all, also none the person's
    /// recorder settings would record, this recording only.
    case withoutSound
    /// The person chose Cancel recording (or closed the prompt): nothing records.
    case declined
    /// Nobody answered within this many seconds; the prompt is gone and
    /// nothing records.
    case timedOut(TimeInterval)
    /// The call may no longer run (AI tools turned off, the client revoked
    /// while the prompt was up): the text for the model.
    case refused(String)
}

/// Asks the person whether an external start_recording may record the sound
/// in the request, reporting heartbeat progress (when given a handler) so
/// the client keeps waiting. Never remembered: each recording asks again.
public typealias AIRecordingAudioConsentHandler = @Sendable (AIRecordingAudioConsentRequest, AIToolProgressHandler?) async -> AIRecordingAudioConsent

/// Whether macOS lets Focus Studio use the microphone, as start_recording
/// learns it before the countdown of a recording that captures it.
public enum AIMicrophoneAccess: Equatable, Sendable {
    /// Focus Studio may use the microphone: it already could, or macOS asked
    /// the person during this call (`askedNow`) and they allowed it.
    case authorized(askedNow: Bool)
    /// Focus Studio's microphone access is off (System Settings › Privacy &
    /// Security › Microphone): the person turned it off before, or chose
    /// Don't Allow when macOS asked during this call (`askedNow`).
    case denied(askedNow: Bool)
    /// Microphone access is restricted on this Mac (Screen Time, a device
    /// management profile), so the person cannot allow it.
    case restricted
    /// macOS asked the person and nobody answered its dialog within this many
    /// seconds; the dialog may still be on screen.
    case timedOut(TimeInterval)
    /// The call may no longer run (AI tools turned off, the client revoked
    /// while macOS's dialog was up): the text for the model.
    case refused(String)
}

/// Makes sure macOS has decided whether Focus Studio may use the microphone
/// before a recording that captures it counts down, so that macOS's own
/// dialog never comes up while the recording runs: when the person has
/// never answered, it asks macOS (its dialog) and waits for the answer,
/// reporting heartbeat progress meanwhile (when given a handler). Cancelling
/// the caller ends the wait; the caller checks for cancellation itself.
public typealias AIMicrophoneAccessHandler = @Sendable (AIToolProgressHandler?) async -> AIMicrophoneAccess

/// How a recording attempt ended.
public enum AIRecordingOutcome: Equatable, Sendable {
    /// Saved as this project, which the editor then showed.
    case finished(projectID: UUID)
    /// The countdown or the recording was cancelled; nothing was kept.
    case cancelled
    /// The capture could not start, or the recording could not be saved.
    case failed(String)
}

/// One recording attempt as the tools follow it: from its countdown to how it
/// ended. The app keeps the latest one.
public struct AIRecordingSession: Equatable, Sendable {
    public var id: UUID
    /// The source being recorded (an id from list_recording_sources).
    public var sourceID: String
    /// When frames started arriving: the recording's real start, after the
    /// countdown and the capture start. Nil until then.
    public var startedAt: Date?
    /// Seconds of recording (paused time left out) after which the app stops
    /// by itself; nil when the recording runs until someone stops it.
    public var duration: TimeInterval?
    /// Nil while the attempt is counting down, recording or being saved.
    public var outcome: AIRecordingOutcome?
    public var endedAt: Date?
    /// The person paused the recording from its control bar: nothing is
    /// recorded, and a duration waits for the resume.
    public var isPaused: Bool
    /// Seconds spent paused since `startedAt`, which the recording and its
    /// duration leave out.
    public var pausedDuration: TimeInterval

    public init(
        id: UUID, sourceID: String, startedAt: Date? = nil, duration: TimeInterval? = nil, outcome: AIRecordingOutcome? = nil, endedAt: Date? = nil,
        isPaused: Bool = false, pausedDuration: TimeInterval = 0
    ) {
        self.id = id
        self.sourceID = sourceID
        self.startedAt = startedAt
        self.duration = duration
        self.outcome = outcome
        self.endedAt = endedAt
        self.isPaused = isPaused
        self.pausedDuration = pausedDuration
    }

    /// When the app stops by itself, for a recording with a duration: its
    /// start plus the duration plus the time paused so far. Nil while paused,
    /// when that time is not known yet.
    public var autoStopAt: Date? {
        guard let startedAt, let duration, !isPaused else { return nil }
        return startedAt.addingTimeInterval(duration + max(0, pausedDuration))
    }
}

/// A library entry as listed to the model.
public struct AIProjectSummary: Equatable, Sendable, Identifiable {
    public var id: UUID
    var title: String
    var duration: Double
    var createdAt: Date
    var sourceWidth: Int
    var sourceHeight: Int
    var zoomCount: Int
    var chapterCount: Int

    init(id: UUID, title: String, duration: Double, createdAt: Date, sourceWidth: Int, sourceHeight: Int, zoomCount: Int, chapterCount: Int) {
        self.id = id
        self.title = title
        self.duration = duration
        self.createdAt = createdAt
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.zoomCount = zoomCount
        self.chapterCount = chapterCount
    }

    public init(project: RecordingProject) {
        self.init(
            id: project.id,
            title: project.title,
            duration: project.duration,
            createdAt: project.createdAt,
            sourceWidth: project.sourceWidth,
            sourceHeight: project.sourceHeight,
            zoomCount: project.zoomSegments.filter(\.isEnabled).count,
            chapterCount: project.chapters?.count ?? 0
        )
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

/// A bundled music track (from `AudioAssetCatalog`) resolved to a playable file.
public struct AIMusicTrack: Equatable, Sendable, Identifiable {
    public var id: String
    var title: String
    var mood: String
    var durationSeconds: Double
    var suggestedVolume: Double
    var path: String

    init(id: String, title: String, mood: String = "", durationSeconds: Double = 0, suggestedVolume: Double = 0.2, path: String) {
        self.id = id
        self.title = title
        self.mood = mood
        self.durationSeconds = durationSeconds
        self.suggestedVolume = suggestedVolume
        self.path = path
    }

    public init(asset: AudioAssetCatalog.Asset, path: String) {
        self.init(id: asset.id, title: asset.title, mood: asset.mood, durationSeconds: asset.durationSeconds,
                  suggestedVolume: asset.suggestedVolume, path: path)
    }
}

/// What the assistant may do to the app itself: pick a source and record,
/// browse and open the library, and look up bundled audio. `StudioModel`
/// conforms; tests use a fake. Every member runs on the main actor.
@MainActor
public protocol AppControlling: AnyObject, Sendable {
    /// Refreshes the displays and windows from the OS and returns them.
    func refreshRecordingSources() async throws -> [AIRecordingSource]
    /// The sources from the last refresh.
    var recordingSources: [AIRecordingSource] { get }
    /// `.stopping` from the moment a stop begins until its project is open in
    /// the editor (or the stop failed).
    var recordingPhase: AIRecordingPhase { get }
    /// Whether a stop the app started (the Finish button, an earlier call) is
    /// still finalizing the capture or saving its project. A `.stopping` phase
    /// without it is the capture winding down for a cancel, which yields no project.
    var isFinishingRecording: Bool { get }
    /// The error the app is currently showing the user, if any, including the
    /// recorder's Screen Recording permission notice after a refused start.
    var lastReportedError: String? { get }
    /// The sound the person's own recorder settings record (what a recording
    /// without options captures besides the screen). An external
    /// start_recording that turns on more asks the person first.
    var recorderAudio: AIRecordingAudio { get }
    /// Selects the source and starts the visible countdown for a recording
    /// with these options (for this recording only), and returns the new
    /// attempt's id (``recordingSession``). Throws when the app cannot start
    /// (unknown source, recording in progress).
    func startRecording(sourceID: String, options: AIRecordingOptions) throws -> UUID
    /// Finishes the recording; on success the app opens the editor with the new
    /// project and brings it forward, as the Finish button does. A call while
    /// a stop is already under way (the Finish button, the recording's
    /// duration running out, another tool call) waits for that stop instead
    /// of finalizing again; a call with no live recording (a stop that
    /// already finished, a cancel winding down) does nothing.
    func stopRecording() async
    /// ``stopRecording()`` for stop_recording: the in-app assistant's
    /// (the person confirmed it inside the app) shows the editor in front;
    /// an external AI tool's (`external`) leaves the app where it is, since
    /// the person may be typing in another app.
    func stopRecording(external: Bool) async
    /// Cancels attempt `id` (its countdown, its capture start or the
    /// recording) and keeps nothing, as the Cancel buttons do. Does nothing
    /// once that attempt has ended or while a stop is saving it.
    func discardRecording(id: UUID) async
    /// The latest recording attempt, live or ended; nil before the first.
    var recordingSession: AIRecordingSession? { get }
    /// Whether the person paused the recording from its control bar (the
    /// phase stays `.recording`: stop_recording and Cancel still work).
    var isRecordingPaused: Bool { get }
    /// Seconds recorded so far, paused time left out, while `.recording`;
    /// nil otherwise.
    var recordingElapsed: TimeInterval? { get }
    /// Seconds of recording left before a recording with a duration stops by
    /// itself, while `.recording` (it does not count down while paused); nil
    /// otherwise.
    var recordingRemaining: TimeInterval? { get }
    /// Library entries, newest first.
    var projectSummaries: [AIProjectSummary] { get }
    /// The freshest copy of a library project, without opening it: the
    /// editor's copy when it is the open project, else the library's. Nil for
    /// an unknown id.
    func project(id: UUID) -> RecordingProject?
    /// The projects library root (one `<UUID>/` folder per project).
    var libraryDirectory: URL { get }
    /// The project shown in the editor, or nil when the editor is closed.
    var openProjectID: UUID? { get }
    func openProject(id: UUID) throws
    func closeEditor()
    var bundledMusicTracks: [AIMusicTrack] { get }
    /// Screen Recording, Accessibility and Input Monitoring, without prompting.
    var permissionStatus: AIPermissionStatus { get }

    // Library changes an external client may make. Each goes through the
    // app's own action and throws the reason it could not, the app's own
    // reasons as an ``AILocalizedFailure``.

    /// Creates a library project from a movie file and opens it in the
    /// editor (saving and closing any open project first), as Import video
    /// does. A nil title is the file name.
    func importVideo(from url: URL, title: String?) async throws -> RecordingProject
    /// Turns a PNG or JPEG screenshot into an editable demo project and opens
    /// it in the editor, as Animate screenshot does. A nil title is
    /// "<file name> Demo".
    func importScreenshotDemo(from url: URL, title: String?) async throws -> RecordingProject
    /// Renames a library project (its title only) and returns it as saved.
    /// The app returns to the library first, saving and closing the editor.
    func renameLibraryProject(id: UUID, to title: String) async throws -> RecordingProject
    /// Moves a library project's folder to the Trash, never deleting it, and
    /// returns the project as it was. The app returns to the library first,
    /// saving and closing the editor.
    func trashLibraryProject(id: UUID) async throws -> RecordingProject
}

extension AppControlling {
    /// An app without a pause (test fakes) never reports one.
    public var isRecordingPaused: Bool { false }

    /// An app that never activates itself (test fakes) stops the same way
    /// for every caller.
    public func stopRecording(external: Bool) async {
        await stopRecording()
    }
}

// MARK: - Shared helpers

extension AIToolSupport {
    static func requireApp(_ context: AIAssistantContext) throws -> any AppControlling {
        guard let app = context.app else { throw AIToolError.appUnavailable }
        return app
    }

    /// Runs an app action and words its failure in the call's language: the
    /// app's own reasons are translated, tool errors and cancellation pass
    /// through, and any other error is reported by its description.
    static func appAction<Value>(_ context: AIAssistantContext, _ action: () async throws -> Value) async throws -> Value {
        do {
            return try await action()
        } catch let failure as AILocalizedFailure {
            throw AIToolError.failed(failure.message(in: context.resultLanguage))
        } catch let error as AIToolError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIToolError.failed(L10n.tr(error.localizedDescription, language: context.resultLanguage))
        }
    }

    /// The project a call concerns without opening it: the project the call
    /// is pinned to as the app has it now, else the one open in the editor.
    static func referencedProject(_ context: AIAssistantContext) async -> RecordingProject? {
        if let pinned = context.projectID, let app = context.app {
            return await app.project(id: pinned)
        }
        return await MainActor.run { context.readProject() }
    }

    /// Polls `poll` on the main actor every `interval` until it returns a
    /// value, throws, or `timeout` passes (then returns nil). Cancellation propagates.
    static func waitOnMain<Value: Sendable>(
        timeout: TimeInterval,
        interval: TimeInterval = 0.1,
        _ poll: @escaping @MainActor @Sendable () throws -> Value?
    ) async throws -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            if let value = try await MainActor.run(body: poll) { return value }
            guard Date() < deadline else { return nil }
            try await Task.sleep(nanoseconds: UInt64(max(0.01, interval) * 1_000_000_000))
        }
    }

    /// How a recording ended, as stop_recording and wait_for_recording report it.
    enum RecordingEnd {
        case finished(AIProjectSummary)
        case cancelled
    }

    /// Whether the recording a tool follows has ended, and how: saved as a
    /// project (the stop is over and the project is in the library),
    /// cancelled, or failed (the failure). Nil while it has not ended.
    ///
    /// `sessionID` is the attempt the tool followed from the start. Without
    /// one (an app that does not track attempts, or a recording started some
    /// other way), a new project in the editor after `previousProjectID`
    /// ends it, as does, with `idleMeansCancelled`, the app going idle
    /// without one.
    @MainActor
    static func recordingEnd(
        _ app: any AppControlling,
        sessionID: UUID?,
        previousProjectID: UUID?,
        idleMeansCancelled: Bool
    ) -> Result<RecordingEnd, AIToolError>? {
        if let sessionID {
            guard let session = app.recordingSession, session.id == sessionID else {
                return .failure(.failed("The recording ended and another one has started since. Call get_status for the new one and list_projects for the saved projects."))
            }
            switch session.outcome {
            case let .finished(projectID)?:
                // Listed and no longer stopping: the editor shows it.
                guard app.recordingPhase != .stopping, let summary = app.projectSummaries.first(where: { $0.id == projectID }) else { return nil }
                return .success(.finished(summary))
            case .cancelled?:
                return .success(.cancelled)
            case let .failed(message)?:
                return .failure(.failed(session.startedAt == nil ? "The recording could not start: \(message)" : "The recording could not be saved: \(message)"))
            case nil:
                if case let .failed(message) = app.recordingPhase {
                    return .failure(.failed("The recording failed: \(message)"))
                }
                return nil
            }
        }
        if let id = app.openProjectID, id != previousProjectID, app.recordingPhase != .stopping,
           let summary = app.projectSummaries.first(where: { $0.id == id }) {
            return .success(.finished(summary))
        }
        if case let .failed(message) = app.recordingPhase {
            return .failure(.failed("The recording could not be saved: \(message)"))
        }
        if app.recordingPhase == .idle, app.openProjectID == previousProjectID {
            if let error = app.lastReportedError { return .failure(.failed("The recording could not be saved: \(error)")) }
            if idleMeansCancelled { return .success(.cancelled) }
        }
        return nil
    }

    /// The result for a recording saved as `project`: its id, title,
    /// duration, size and zoom count, with `state: "finished"`.
    static func finishedRecording(_ project: AIProjectSummary, isOpen: Bool) -> AIToolResult {
        var text = "Recording saved as project \"\(project.displayTitle)\" (id \(project.id.uuidString), \(seconds(project.duration)) s, \(project.sourceWidth)×\(project.sourceHeight), \(project.zoomCount) automatic zooms)."
        if isOpen { text += " It is open in the editor." }
        let data = merged(AIProjectReport.summaryData(project, isOpen: isOpen), ["project_id": AIJSONValue(project.id.uuidString), "state": "finished"])
        return AIToolResult(text: text, data: data)
    }

    /// How the latest recording ended, for a tool that found nothing
    /// recording: a sentence and the data. Nil when there has been none.
    @MainActor
    static func lastRecordingReport(_ app: any AppControlling) -> (text: String, data: AIJSONValue)? {
        guard let session = app.recordingSession, let outcome = session.outcome else { return nil }
        let ago = session.endedAt.map { " \(seconds(max(0, Date().timeIntervalSince($0)))) s ago" } ?? ""
        var fields: [String: AIJSONValue] = [
            "started_at": session.startedAt.map { AIJSONValue($0) } ?? .null,
            "ended_at": session.endedAt.map { AIJSONValue($0) } ?? .null,
        ]
        let text: String
        switch outcome {
        case let .finished(projectID):
            fields["state"] = "finished"
            fields["project_id"] = AIJSONValue(projectID.uuidString)
            let title = app.projectSummaries.first { $0.id == projectID }.map { " \"\($0.displayTitle)\"" } ?? ""
            text = "The last recording ended\(ago) and was saved as project\(title) (id \(projectID.uuidString))."
        case .cancelled:
            fields["state"] = "cancelled"
            text = "The last recording was cancelled\(ago); nothing was saved."
        case let .failed(message):
            fields["state"] = "failed"
            fields["error"] = AIJSONValue(message)
            text = "The last recording failed\(ago): \(message)"
        }
        return (text, .object(fields))
    }

    static func projectLine(_ summary: AIProjectSummary, isOpen: Bool) -> String {
        var line = "\(summary.displayTitle) · \(seconds(summary.duration)) s · \(summary.sourceWidth)×\(summary.sourceHeight) · \(Self.dateFormatter.string(from: summary.createdAt)) · id \(summary.id.uuidString)"
        if isOpen { line += " · open in the editor" }
        return line
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// Zooms in time order with 1-based indexes, the numbering used by
    /// `remove_zoom` and the project summary.
    static func orderedZooms(_ project: RecordingProject) -> [(index: Int, position: Int, segment: ZoomSegment)] {
        project.zoomSegments.enumerated()
            .sorted { lhs, rhs in
                lhs.element.start == rhs.element.start ? lhs.offset < rhs.offset : lhs.element.start < rhs.element.start
            }
            .enumerated()
            .map { (index: $0.offset + 1, position: $0.element.offset, segment: $0.element.element) }
    }

    static func zoomLine(_ segment: ZoomSegment) -> String {
        var text = "\(seconds(segment.start))–\(seconds(segment.end)) s at (\(String(format: "%.2f", segment.targetX)), \(String(format: "%.2f", segment.targetY))) ×\(String(format: "%.2f", segment.scale)) \(segment.kind.rawValue)"
        if !segment.isEnabled { text += " (disabled)" }
        return text
    }
}

// MARK: - list_recording_sources

struct ListRecordingSourcesTool: AIAssistantTool {
    let name = "list_recording_sources"
    let summary = "Refresh and list what can be recorded: every display and every visible window with its id, app, title and size. Opens the recorder screen. Call it before start_recording unless the user named an exact source."

    static let maximumListedWindows = 40

    var parametersSchema: [String: Any] {
        ["type": "object", "properties": [String: Any]()]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let app = try AIToolSupport.requireApp(context)
        progress(context.tr("Finding screens and windows…"))
        let sources = try await AIToolSupport.appAction(context) { try await app.refreshRecordingSources() }
        guard !sources.isEmpty else {
            let data: AIJSONValue = ["display_count": 0, "window_count": 0, "sources": [], "omitted_windows": 0]
            return AIToolResult(text: "No displays or windows are available. Screen Recording permission may be missing: System Settings › Privacy & Security › Screen Recording.", data: data)
        }
        let displays = AIRecordingSource.orderedDisplays(sources)
        let windows = sources.filter { $0.kind == .window }.sorted { $0.area > $1.area }
        let listedWindows = windows.prefix(Self.maximumListedWindows)
        var lines = ["\(displays.count) displays, \(windows.count) windows"]
        lines.append(contentsOf: displays.map { "- " + $0.summaryLine })
        lines.append(contentsOf: listedWindows.map { "- " + $0.summaryLine })
        if windows.count > Self.maximumListedWindows {
            lines.append("(\(windows.count - Self.maximumListedWindows) smaller windows omitted)")
        }
        let data: AIJSONValue = [
            "display_count": AIJSONValue(displays.count),
            "window_count": AIJSONValue(windows.count),
            // Displays (main first), then the largest windows.
            "sources": .array((displays + listedWindows).map(\.data)),
            "omitted_windows": AIJSONValue(windows.count - listedWindows.count),
        ]
        return AIToolResult(text: lines.joined(separator: "\n"), data: data)
    }
}

// MARK: - start_recording

struct StartRecordingTool: AIAssistantTool {
    let name = "start_recording"
    let summary = "Select a display or window and start recording after the app's 3-second countdown. Returns as soon as the recording is live; the user sees a control bar and can pause, finish or cancel it. Optional capture settings apply to this recording only; with duration the app stops by itself once that many seconds are recorded (paused time does not count). Then reply to the user: call stop_recording when they say they are done, or, for a recording with a duration, wait_for_recording."

    /// How long the countdown plus capture start may take.
    var startTimeout: TimeInterval = 20

    init(startTimeout: TimeInterval = 20) {
        self.startTimeout = startTimeout
    }

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["source"],
            "properties": [
                "source": ["type": "string", "description": "A source id from list_recording_sources, an app name (e.g. Safari), part of a window title, or \"display\" for the main display (\"display 2\" for the second one)."],
                "system_audio": ["type": "boolean", "description": "Capture the Mac's audio output."],
                "microphone": ["type": "boolean"],
                "automatic_zooms": ["type": "boolean", "description": "Generate zooms from clicks and typing (default on)."],
                "browser_content_only": ["type": "boolean", "description": "Crop a browser window to its page content."],
                "frame_rate": ["type": "integer", "enum": [30, 60]],
                "duration": [
                    "type": "number", "minimum": AIRecordingOptions.durationRange.lowerBound, "maximum": AIRecordingOptions.durationRange.upperBound,
                    "description": "Stop by itself once this many seconds (1-600) are recorded, counted from the recording's actual start after the countdown; time the user spends paused does not count. Without it the recording runs until stop_recording or the user's Finish.",
                ],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let query = try arguments.requiredString("source")
        var options = AIRecordingOptions()
        for key in ["system_audio", "microphone", "automatic_zooms", "browser_content_only"] where arguments.has(key) {
            guard let value = arguments.bool(key) else { throw AIToolError.invalidArgument("\"\(key)\" must be true or false.") }
            switch key {
            case "system_audio": options.systemAudio = value
            case "microphone": options.microphone = value
            case "automatic_zooms": options.automaticZooms = value
            default: options.browserContentOnly = value
            }
        }
        if arguments.has("frame_rate") {
            guard let rate = arguments.int("frame_rate"), [30, 60].contains(rate) else {
                throw AIToolError.invalidArgument("\"frame_rate\" must be 30 or 60.")
            }
            options.frameRate = rate
        }
        if arguments.has("duration") {
            guard let seconds = arguments.double("duration"), AIRecordingOptions.durationRange.contains(seconds) else {
                throw AIToolError.invalidArgument("\"duration\" must be a number of seconds from 1 to 600.")
            }
            options.duration = seconds
        }

        let app = try AIToolSupport.requireApp(context)
        let phase = await app.recordingPhase
        switch phase {
        case .idle, .failed:
            break
        case .countdown, .recording, .stopping:
            throw AIToolError.failed("A recording is already \(phase.label). Call wait_for_recording or stop_recording first.")
        }
        var sources = await app.recordingSources
        if sources.isEmpty {
            progress(context.tr("Finding screens and windows…"))
            sources = try await AIToolSupport.appAction(context) { try await app.refreshRecordingSources() }
        }
        let source = try Self.resolveSource(query, in: sources)
        // Sound the person's own recorder settings leave off is recorded only
        // when the person allows it, asked before the countdown and never
        // remembered. The in-app assistant never asks: the person drives it.
        var asked = AIRecordingAudio()
        var consent: AIRecordingAudioConsent?
        if context.isExternal {
            asked = AIRecordingAudio.added(by: options, to: await app.recorderAudio)
            if !asked.isEmpty {
                guard let ask = context.recordingAudioConsent else { throw AIToolError.failed(Self.consentUnavailableMessage(asked)) }
                let answer = await ask(AIRecordingAudioConsentRequest(audio: asked, sourceName: source.displayName), context.numericProgress)
                try Task.checkCancellation()
                switch answer {
                case .allowed:
                    break
                case .withoutSound:
                    // "Record without sound" records the screen only: no sound
                    // at all, also none the recorder itself would record.
                    options.microphone = false
                    options.systemAudio = false
                case .declined:
                    throw AIToolError.failed(Self.soundDeclinedMessage(asked))
                case let .timedOut(seconds):
                    throw AIToolError.failed(Self.soundUnansweredMessage(asked, seconds: seconds))
                case let .refused(message):
                    throw AIToolError.failed(message)
                }
                consent = answer
            }
        }
        let requestedOptions = options
        let allowedAudio = consent == .allowed ? asked : AIRecordingAudio()
        let isExternal = context.isExternal
        // macOS's own permission for the microphone, settled before the
        // countdown: otherwise macOS asks the first time the capture starts,
        // while the recording already runs (a duration running out
        // meanwhile, the start of the sound possibly missing, its dialog
        // possibly in the video).
        var askedForMicrophone = false
        if let ensureMicrophone = context.microphoneAccess {
            let recorder = await app.recorderAudio
            let planned = isExternal ? Self.withoutUnallowedSound(requestedOptions, allowed: allowedAudio, recorder: recorder).0 : requestedOptions
            if planned.microphone ?? recorder.microphone {
                let access = await ensureMicrophone(context.numericProgress)
                try Task.checkCancellation()
                // The in-app assistant records as the person asked, whatever
                // macOS answered, as their own recordings do.
                if isExternal {
                    switch access {
                    case let .authorized(askedNow):
                        askedForMicrophone = askedNow
                    case let .denied(askedNow):
                        throw Self.microphoneDenied(askedNow: askedNow)
                    case .restricted:
                        throw Self.microphoneRestricted()
                    case let .timedOut(seconds):
                        throw Self.microphoneUnanswered(seconds: seconds)
                    case let .refused(message):
                        throw AIToolError.failed(message)
                    }
                }
            }
        }
        let (sessionID, startedOptions, leftOff) = try await AIToolSupport.appAction(context) {
            try await MainActor.run { () throws -> (UUID, AIRecordingOptions, AIRecordingAudio) in
                // Read in the same main-actor turn as the start: sound the
                // person was not asked about records only while their recorder
                // settings still record it, so a toggle they turned off while
                // the prompt was up (or at any moment before the start) wins.
                let (options, leftOff) = isExternal
                    ? Self.withoutUnallowedSound(requestedOptions, allowed: allowedAudio, recorder: app.recorderAudio)
                    : (requestedOptions, AIRecordingAudio())
                return (try app.startRecording(sourceID: source.id, options: options), options, leftOff)
            }
        }
        options = startedOptions

        progress(context.tr("Counting down…"))
        let outcome: Result<AIRecordingSession, AIToolError>?
        do {
            outcome = try await AIToolSupport.waitOnMain(timeout: startTimeout) { Self.startOutcome(app, sessionID: sessionID, source: source) }
        } catch is CancellationError {
            // The caller gave up during the countdown or the capture start:
            // a recording it never saw start must not keep running.
            await app.discardRecording(id: sessionID)
            throw CancellationError()
        }
        guard let outcome else {
            // Like a cancelled call: an attempt this call reports as not
            // started must not go live later (a slow capture start).
            await app.discardRecording(id: sessionID)
            throw AIToolError.timedOut("The recording did not start within \(Int(startTimeout)) s and was cancelled; nothing is recording. Check the app window (for example a Screen Recording prompt), then call start_recording again.")
        }
        let session = try outcome.get()
        if Task.isCancelled {
            // Cancelled as the recording went live, before this call answered.
            await app.discardRecording(id: sessionID)
            throw CancellationError()
        }

        var settings: [String] = []
        if let value = options.systemAudio { settings.append("system audio \(value ? "on" : "off")") }
        if let value = options.microphone { settings.append("microphone \(value ? "on" : "off")") }
        if let value = options.automaticZooms { settings.append("automatic zooms \(value ? "on" : "off")") }
        if let value = options.browserContentOnly { settings.append("browser content only \(value ? "on" : "off")") }
        if let value = options.frameRate { settings.append("\(value) fps") }
        let startedAt = session.startedAt ?? Date()
        var text = "Recording started after the 3-second countdown: \(source.summaryLine)."
        if !settings.isEmpty { text += " Settings for this recording: \(settings.joined(separator: ", "))." }
        switch consent {
        case .allowed?:
            text += " Focus Studio asked the person, and they allowed \(asked.phrase) for this recording."
        case .withoutSound?:
            text += " Focus Studio asked the person about \(asked.phrase), and they chose to record without sound: this recording records no sound at all (microphone and system audio off), although you asked for \(asked.microphone && asked.systemAudio ? "them" : "it"). Do not turn sound on again unless the person asks for it."
        default:
            break
        }
        if askedForMicrophone {
            text += " Before the countdown, macOS asked the person whether Focus Studio may use the microphone, and they allowed it."
        }
        if !leftOff.isEmpty {
            let phrase = leftOff.phrase
            let both = leftOff.microphone && leftOff.systemAudio
            text += " \(phrase.prefix(1).uppercased() + phrase.dropFirst()) \(both ? "are" : "is") off for this recording, although you asked for \(both ? "them" : "it"): the person turned \(both ? "them" : "it") off in their recorder settings before the recording started. Do not turn \(both ? "them" : "it") on again unless the person asks for it."
        }
        if let duration = session.duration {
            text += " It stops by itself once \(AIToolSupport.seconds(duration)) s are recorded (at \(Self.clockTime(startedAt.addingTimeInterval(duration))) unless it is paused; paused time does not count)."
        }
        if context.isExternal {
            // An MCP client may drive the recorded app itself (computer use, browser automation).
            text += " The person sees a control bar and can pause, finish or cancel it at any time. Let them perform the demo, or operate the recorded app yourself with your own tools meanwhile; the control bar floats above every app at the bottom centre of each display, so keep your clicks off it (its x button discards the recording) and stop with stop_recording. Then call wait_for_recording to get the saved project (or stop_recording to stop now)."
        } else if session.duration != nil {
            text += " The user sees a control bar and can pause, finish or cancel it at any time, and performs the demo now; call wait_for_recording to get the saved project when it stops (or stop_recording if the user asks to stop early)."
        } else {
            // The in-app chat stays free while the user performs the demo.
            text += " The user sees a control bar and can pause, finish or cancel it at any time, and performs the demo now. Reply to the user now; when they say they are done, call stop_recording (it also reports the project if they already clicked Finish)."
        }
        var optionData: [String: AIJSONValue] = [:]
        if let value = options.systemAudio { optionData["system_audio"] = AIJSONValue(value) }
        if let value = options.microphone { optionData["microphone"] = AIJSONValue(value) }
        if let value = options.automaticZooms { optionData["automatic_zooms"] = AIJSONValue(value) }
        if let value = options.browserContentOnly { optionData["browser_content_only"] = AIJSONValue(value) }
        if let value = options.frameRate { optionData["frame_rate"] = AIJSONValue(value) }
        var data: [String: AIJSONValue] = [
            "state": "recording",
            "source": source.data,
            "started_at": AIJSONValue(startedAt),
            "options": .object(optionData),
        ]
        if let duration = session.duration {
            data["duration"] = .rounded(duration, places: 1)
            data["auto_stop_at"] = AIJSONValue(startedAt.addingTimeInterval(duration))
        }
        if let consent {
            // What the person was asked, and their answer; "options" above
            // holds what this recording actually records.
            data["audio_consent"] = [
                "asked": .array(asked.argumentNames.map { AIJSONValue($0) }),
                "answer": consent == .allowed ? "allowed" : "without_sound",
            ]
        }
        return AIToolResult(text: text, data: .object(data))
    }

    // MARK: Sound prompt

    /// `options` as an external call may record them: a sound it turns on
    /// that the person did not allow at the prompt (`allowed`) records only
    /// while their recorder settings (`recorder`, read right before the
    /// start) still record it; otherwise it is turned off, and returned as
    /// left off. A sound the person allowed, or one the call turns off or
    /// leaves to the recorder, is unchanged.
    static func withoutUnallowedSound(_ options: AIRecordingOptions, allowed: AIRecordingAudio, recorder: AIRecordingAudio) -> (AIRecordingOptions, leftOff: AIRecordingAudio) {
        var options = options
        var leftOff = AIRecordingAudio()
        if options.microphone == true, !allowed.microphone, !recorder.microphone {
            options.microphone = false
            leftOff.microphone = true
        }
        if options.systemAudio == true, !allowed.systemAudio, !recorder.systemAudio {
            options.systemAudio = false
            leftOff.systemAudio = true
        }
        return (options, leftOff)
    }

    static func consentUnavailableMessage(_ audio: AIRecordingAudio) -> String {
        "Focus Studio could not ask the person whether you may record \(audio.phrase), which their recorder settings leave off, so nothing was recorded. Call start_recording again without turning that sound on; with microphone and system_audio false it records the screen only."
    }

    static func soundDeclinedMessage(_ audio: AIRecordingAudio) -> String {
        "The person did not allow sound: Focus Studio asked whether you may record \(audio.phrase) with this recording, and they chose Cancel recording, so nothing was recorded and nothing is recording. Do not retry with microphone or system_audio on unless the person asks for sound; to record the screen only, call start_recording again with microphone and system_audio false."
    }

    /// Where the person turns Focus Studio's microphone access on or off.
    static let microphoneSettings = "System Settings › Privacy & Security › Microphone"

    // The refusals of an external start_recording that would record the
    // microphone macOS does not let Focus Studio use, or has not been
    // answered about in time: nothing starts, and the model may record
    // without the microphone instead.

    /// Focus Studio's microphone access is off: turned off before, or the
    /// person chose Don't Allow when macOS asked during this call (`askedNow`).
    static func microphoneDenied(askedNow: Bool) -> AIToolFailure {
        let text = askedNow
            ? "Focus Studio may not use the microphone: before the countdown, macOS asked the person whether Focus Studio may use it, and they chose Don't Allow, which turns Focus Studio's microphone access off (\(microphoneSettings)). \(nothingRecorded) \(recordWithoutMicrophone); do not ask for the microphone again unless the person turns that access on."
            : "Focus Studio may not use the microphone: the person has turned off Focus Studio's microphone access in \(microphoneSettings). \(nothingRecorded) \(recordWithoutMicrophone). To record the microphone, ask the person to turn that access on first, then call start_recording again."
        return microphoneUnavailable(text, access: "denied", askedNow: askedNow)
    }

    /// Microphone access is restricted on this Mac.
    static func microphoneRestricted() -> AIToolFailure {
        microphoneUnavailable(
            "Focus Studio may not use the microphone: microphone access is restricted on this Mac (Screen Time or a device management profile), so the person cannot turn it on in \(microphoneSettings). \(nothingRecorded) \(recordWithoutMicrophone).",
            access: "restricted", askedNow: false
        )
    }

    /// macOS asked the person and nobody answered its dialog in `seconds`.
    static func microphoneUnanswered(seconds: TimeInterval) -> AIToolFailure {
        let wait = seconds >= 1 ? "\(Int(seconds.rounded()))" : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        return microphoneUnavailable(
            "Focus Studio did not start the recording: before the countdown, macOS asked the person whether Focus Studio may use the microphone, and nobody answered its dialog within \(wait) seconds. \(nothingRecorded) macOS's dialog may still be on screen: ask the person to answer it, then call start_recording again. \(recordWithoutMicrophone).",
            access: "not_determined", askedNow: true, waited: seconds
        )
    }

    private static let nothingRecorded = "Nothing was recorded and nothing is recording."
    private static let recordWithoutMicrophone = "To record without the microphone, call start_recording again with microphone false"

    /// The text, and for programs: why (`microphone_access`: denied,
    /// restricted or not_determined), whether macOS asked during this call,
    /// where the setting is and the arguments that record without it.
    private static func microphoneUnavailable(_ text: String, access: String, askedNow: Bool, waited: TimeInterval? = nil) -> AIToolFailure {
        var data: [String: AIJSONValue] = [
            "status": "microphone_unavailable",
            "microphone_access": AIJSONValue(access),
            "asked_now": AIJSONValue(askedNow),
            "settings": AIJSONValue(microphoneSettings),
            "retry_with": ["microphone": false],
        ]
        if let waited { data["waited"] = .rounded(waited, places: 1) }
        return AIToolFailure(text, data: .object(data))
    }

    static func soundUnansweredMessage(_ audio: AIRecordingAudio, seconds: TimeInterval) -> String {
        let wait = seconds >= 1 ? "\(Int(seconds.rounded()))" : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        return "The person did not allow sound: Focus Studio asked whether you may record \(audio.phrase) with this recording and nobody answered within \(wait) seconds, so the prompt was closed, nothing was recorded and nothing is recording. Ask the person whether they want sound before calling start_recording again; with microphone and system_audio false it records the screen only, with no prompt."
    }

    /// How attempt `sessionID` stands while start_recording waits: live (its
    /// frames arrive), failed or cancelled before that, or still starting (nil).
    /// An app that does not track attempts is read from its phase alone; its
    /// `.idle` after the start means the countdown was cancelled or the capture
    /// failed, and a failure (a missing Screen Recording permission included)
    /// is what the app now shows the user.
    @MainActor
    static func startOutcome(_ app: any AppControlling, sessionID: UUID, source: AIRecordingSource) -> Result<AIRecordingSession, AIToolError>? {
        let session = app.recordingSession.flatMap { $0.id == sessionID ? $0 : nil }
        if let session, session.startedAt != nil { return .success(session) }
        switch session?.outcome {
        case let .failed(message)?:
            return .failure(.failed("The recording could not start: \(message)"))
        case .cancelled?:
            return .failure(.failed("The recording did not start: its countdown was cancelled (by the user, or by another call)."))
        case .finished?, nil:
            break
        }
        switch app.recordingPhase {
        case .recording:
            var live = session ?? AIRecordingSession(id: sessionID, sourceID: source.id)
            live.startedAt = live.startedAt ?? Date()
            return .success(live)
        case let .failed(message):
            return .failure(.failed("The recording could not start: \(message)"))
        case .countdown, .stopping:
            return nil
        case .idle:
            if let error = app.lastReportedError { return .failure(.failed("The recording could not start: \(error)")) }
            return .failure(.failed("The recording did not start (the countdown was cancelled)."))
        }
    }

    /// A local time of day such as 14:03:27, for texts.
    static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Matches an id, a display request, an app name or a window title.
    static func resolveSource(_ query: String, in sources: [AIRecordingSource]) throws -> AIRecordingSource {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIToolError.invalidArgument("\"source\" must name a display, window or app.") }
        if let exact = sources.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) { return exact }

        let lowercased = trimmed.lowercased()
        // "display" is the main display and "display 2" the next one, whatever
        // order the system listed them in.
        let displays = AIRecordingSource.orderedDisplays(sources)
        let displayWords: Set<String> = [
            "display", "screen", "main display", "main screen", "the display", "the screen", "desktop", "entire screen",
            "full screen", "fullscreen", "whole screen", "monitor", "屏幕", "显示器", "全屏", "桌面", "整个屏幕", "主屏幕", "主显示器",
        ]
        if displayWords.contains(lowercased) {
            guard let display = displays.first else { throw AIToolError.failed("No display is available to record.") }
            return display
        }
        if let match = lowercased.wholeMatch(of: #/(?:display|screen|monitor|显示器|屏幕)\s*#?\s*(\d+)/#),
           let number = Int(match.1) {
            guard number >= 1, number <= displays.count else {
                throw AIToolError.invalidArgument("There are \(displays.count) displays; \"\(trimmed)\" does not exist.")
            }
            return displays[number - 1]
        }

        let windows = sources.filter { $0.kind == .window }
        func largest(_ candidates: [AIRecordingSource]) -> AIRecordingSource? {
            candidates.max { $0.area < $1.area }
        }
        if let match = largest(windows.filter { ($0.appName ?? "").lowercased() == lowercased }) { return match }
        if let match = largest(windows.filter { $0.title.lowercased() == lowercased }) { return match }
        if let match = largest(windows.filter { $0.title.lowercased().contains(lowercased) }) { return match }
        if let match = largest(windows.filter { ($0.appName ?? "").lowercased().contains(lowercased) }) { return match }
        let tokens = lowercased.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
        if !tokens.isEmpty {
            let scored = windows.map { window -> (AIRecordingSource, Int) in
                let haystack = "\((window.appName ?? "").lowercased()) \(window.title.lowercased())"
                return (window, tokens.filter { haystack.contains($0) }.count)
            }.filter { $0.1 > 0 }
            if let best = scored.max(by: { lhs, rhs in lhs.1 == rhs.1 ? lhs.0.area < rhs.0.area : lhs.1 < rhs.1 }) {
                return best.0
            }
        }
        if let match = displays.first(where: { $0.title.lowercased().contains(lowercased) }) { return match }

        let available = (displays + windows.sorted { $0.area > $1.area }).prefix(8).map(\.summaryLine)
        throw AIToolError.invalidArgument("No source matches \"\(trimmed)\". Available: \(available.joined(separator: "; ")). Use list_recording_sources for the full list.")
    }
}

// MARK: - stop_recording

struct StopRecordingTool: AIAssistantTool {
    let name = "stop_recording"
    let summary = "Finish the current recording now (also one with a duration still running, or one the user paused). The app saves it as a new project and opens it in the editor; returns the project id, title and duration."

    var stopTimeout: TimeInterval = 60

    init(stopTimeout: TimeInterval = 60) {
        self.stopTimeout = stopTimeout
    }

    var parametersSchema: [String: Any] {
        ["type": "object", "properties": [String: Any]()]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let app = try AIToolSupport.requireApp(context)
        var (phase, openBeforeStop, finishing) = await MainActor.run { (app.recordingPhase, app.openProjectID, app.isFinishingRecording) }
        if phase == .countdown {
            // The countdown cannot be stopped as a recording; let it start first.
            progress(context.tr("Counting down…"))
            let started = try await AIToolSupport.waitOnMain(timeout: 8) { () -> Bool? in
                app.recordingPhase == .recording ? true : (app.recordingPhase == .countdown ? nil : false)
            }
            (phase, openBeforeStop, finishing) = await MainActor.run { (app.recordingPhase, app.openProjectID, app.isFinishingRecording) }
            guard started == true else {
                throw AIToolError.failed("No recording is in progress (the countdown ended with: \(phase.label)).")
            }
        }
        // A stop the app already has under way (the Finish button, the
        // recording's duration running out, another call) is joined: the app
        // finalizes once and every caller reports the same project. Any other
        // `.stopping` is a cancel, which saves nothing.
        let joining = phase == .stopping && finishing
        guard phase == .recording || joining else {
            let last = await MainActor.run { AIToolSupport.lastRecordingReport(app)?.text }
            throw AIToolError.failed("No recording is in progress (state: \(phase.label)).\(last.map { " " + $0 } ?? "")")
        }
        let previousProjectID = openBeforeStop
        let sessionID = await MainActor.run { app.recordingSession.flatMap { $0.outcome == nil ? $0.id : nil } }
        progress(context.tr("Preparing your editable recording…"))
        // A joined stop is only waited for: asking again could land after it
        // finished and finalize a capture that no longer exists. An external
        // AI tool's stop leaves the app where it is; the in-app assistant's
        // brings the saved project forward, as Finish does.
        let external = context.isExternal
        if !joining { Task { @MainActor in await app.stopRecording(external: external) } }
        let outcome = try await AIToolSupport.waitOnMain(timeout: stopTimeout) {
            AIToolSupport.recordingEnd(app, sessionID: sessionID, previousProjectID: previousProjectID, idleMeansCancelled: false)
        }
        guard let outcome else {
            throw AIToolError.timedOut("The recording is still being saved after \(Int(stopTimeout)) s. Check the app window and call list_projects later.")
        }
        switch try outcome.get() {
        case let .finished(project):
            return await MainActor.run { AIToolSupport.finishedRecording(project, isOpen: app.openProjectID == project.id) }
        case .cancelled:
            throw AIToolError.failed("The recording was cancelled before it could be saved; nothing was kept.")
        }
    }
}

// MARK: - wait_for_recording

/// Waits for the recording under way to end however it ends (the user's
/// Finish or Cancel, its duration, stop_recording) without stopping it, so a
/// caller can start a recording, let the demo happen (or drive the recorded
/// app itself) and then collect the project. Each call waits a bounded time,
/// well inside client tool timeouts, and cancelling it never touches the recording.
struct WaitForRecordingTool: AIAssistantTool {
    let name = "wait_for_recording"
    let summary = "Wait until the current recording ends — the user clicks Finish or Cancel, its duration runs out, or stop_recording is called — and its project is saved and open in the editor; returns the new project's id and duration, or that it was cancelled. Waits at most timeout_seconds (default 120, at most 240), then reports that it is still recording (and whether the user paused it): call it again."

    static let defaultTimeout: TimeInterval = 120
    /// Well inside Codex's 300-second tool timeout.
    static let maximumTimeout: TimeInterval = 240

    /// How often the app is checked.
    var pollInterval: TimeInterval
    /// How often measured progress is reported while waiting.
    var progressInterval: TimeInterval

    init(pollInterval: TimeInterval = 0.1, progressInterval: TimeInterval = 5) {
        self.pollInterval = pollInterval
        self.progressInterval = progressInterval
    }

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "timeout_seconds": [
                    "type": "number", "minimum": 0, "maximum": Self.maximumTimeout, "default": Self.defaultTimeout,
                    "description": "How long to wait, in seconds, from 0 to \(Int(Self.maximumTimeout)) (default \(Int(Self.defaultTimeout))).",
                ],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        var timeout = Self.defaultTimeout
        if arguments.has("timeout_seconds") {
            guard let value = arguments.double("timeout_seconds"), (0...Self.maximumTimeout).contains(value) else {
                throw AIToolError.invalidArgument("\"timeout_seconds\" must be a number of seconds from 0 to \(Int(Self.maximumTimeout)) (default \(Int(Self.defaultTimeout))).")
            }
            timeout = value
        }
        let app = try AIToolSupport.requireApp(context)
        let (phase, session, openBefore) = await MainActor.run { (app.recordingPhase, app.recordingSession, app.openProjectID) }
        switch phase {
        case .idle:
            return await MainActor.run { Self.idleResult(app) }
        case let .failed(message):
            throw AIToolError.failed("The recording failed: \(message)")
        case .countdown, .recording, .stopping:
            break
        }
        let sessionID = session.flatMap { $0.outcome == nil ? $0.id : nil }
        let end: @MainActor @Sendable () -> Result<AIToolSupport.RecordingEnd, AIToolError>? = {
            AIToolSupport.recordingEnd(app, sessionID: sessionID, previousProjectID: openBefore, idleMeansCancelled: true)
        }

        progress(context.tr("Waiting for the recording to end…"))
        let started = Date()
        var nextReport: TimeInterval = 0
        while true {
            try Task.checkCancellation()
            if let ended = await MainActor.run(body: end) { return try await Self.result(ended, app: app) }
            let waited = Date().timeIntervalSince(started)
            guard waited < timeout else { break }
            if waited >= nextReport {
                // Measured progress keeps clients with an idle timeout waiting.
                context.reportProgress(max(waited, 0.001), total: timeout, message: "Waiting for the recording to end")
                nextReport += max(0.1, progressInterval)
            }
            try await Task.sleep(nanoseconds: UInt64(max(0.01, min(pollInterval, timeout - waited)) * 1_000_000_000))
        }
        if let ended = await MainActor.run(body: end) { return try await Self.result(ended, app: app) }
        let waited = timeout
        return await MainActor.run { Self.stillRecordingResult(app, waited: waited) }
    }

    private static func result(_ ended: Result<AIToolSupport.RecordingEnd, AIToolError>, app: any AppControlling) async throws -> AIToolResult {
        switch try ended.get() {
        case let .finished(project):
            return await MainActor.run { AIToolSupport.finishedRecording(project, isOpen: app.openProjectID == project.id) }
        case .cancelled:
            let session = await app.recordingSession
            var data: [String: AIJSONValue] = ["state": "cancelled"]
            if let startedAt = session?.startedAt { data["started_at"] = AIJSONValue(startedAt) }
            if let endedAt = session?.endedAt { data["ended_at"] = AIJSONValue(endedAt) }
            return AIToolResult(text: "The recording was cancelled (from its countdown or its control bar); nothing was saved.", data: .object(data))
        }
    }

    @MainActor
    private static func idleResult(_ app: any AppControlling) -> AIToolResult {
        var text = "Nothing is recording, so there is nothing to wait for."
        var data: [String: AIJSONValue] = ["state": "idle"]
        if let last = AIToolSupport.lastRecordingReport(app) {
            text += " " + last.text
            data["last_recording"] = last.data
        } else {
            text += " Start a recording with start_recording."
        }
        data["message"] = AIJSONValue(text)
        return AIToolResult(text: text, data: .object(data))
    }

    @MainActor
    private static func stillRecordingResult(_ app: any AppControlling, waited: TimeInterval) -> AIToolResult {
        let phase = app.recordingPhase
        let elapsed = phase == .recording ? app.recordingElapsed : nil
        let remaining = phase == .recording ? app.recordingRemaining : nil
        let paused = phase == .recording && app.isRecordingPaused
        var text: String
        switch phase {
        case .countdown: text = "The recording is still counting down"
        case .stopping: text = "The recording is still being saved"
        default: text = paused ? "Still recording, paused by the person," : "Still recording"
        }
        text += " after waiting \(AIToolSupport.seconds(waited)) s"
        var details: [String] = []
        if let elapsed { details.append("\(AIToolSupport.seconds(elapsed)) s recorded so far") }
        if let remaining {
            details.append(paused
                ? "\(AIToolSupport.seconds(remaining)) s of recording remain once they resume; paused time does not count"
                : "it stops by itself in \(AIToolSupport.seconds(remaining)) s")
        }
        if !details.isEmpty { text += " (\(details.joined(separator: "; ")))" }
        text += ". Call wait_for_recording again, or stop_recording to stop it now."
        var data: [String: AIJSONValue] = [
            "state": AIJSONValue(phase.code),
            "elapsed": elapsed.map { .rounded($0, places: 1) } ?? .null,
            "waited": .rounded(waited, places: 1),
        ]
        if phase == .recording { data["paused"] = AIJSONValue(paused) }
        if let remaining { data["remaining"] = .rounded(remaining, places: 1) }
        if let session = app.recordingSession, session.outcome == nil {
            if let startedAt = session.startedAt { data["started_at"] = AIJSONValue(startedAt) }
            // Not known while paused: the pause moves it later.
            if !paused, let autoStopAt = session.autoStopAt { data["auto_stop_at"] = AIJSONValue(autoStopAt) }
        }
        return AIToolResult(text: text, data: .object(data))
    }
}

// MARK: - list_projects

struct ListProjectsTool: AIAssistantTool {
    let name = "list_projects"
    let summary = "List the recordings in the library, newest first, with id, title, duration and creation time."

    static let maximumListed = 30
    static let maximumLimit = 100

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Only projects whose title contains this text (case-insensitive)."],
                "offset": ["type": "integer", "minimum": 0, "description": "How many matching projects to skip (default 0)."],
                "limit": ["type": "integer", "minimum": 1, "maximum": Self.maximumLimit, "description": "How many to return, from 1 to \(Self.maximumLimit) (default \(Self.maximumListed))."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let app = try AIToolSupport.requireApp(context)
        let arguments = AIToolArguments(raw)
        let query = arguments.string("query")
        let offset = max(0, arguments.int("offset") ?? 0)
        let limit = min(Self.maximumLimit, max(1, arguments.int("limit") ?? Self.maximumListed))
        let (projects, openID) = await MainActor.run { (app.projectSummaries, app.openProjectID) }
        let matching = query.map { query in projects.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) } } ?? projects
        let listed = matching.dropFirst(offset).prefix(limit)
        let hasMore = offset + listed.count < matching.count
        let data: AIJSONValue = [
            "total": AIJSONValue(projects.count),
            "matched": AIJSONValue(matching.count),
            "offset": AIJSONValue(offset),
            "has_more": AIJSONValue(hasMore),
            "open_project_id": openID.map { AIJSONValue($0.uuidString) } ?? .null,
            "projects": .array(listed.map { AIProjectReport.summaryData($0, isOpen: $0.id == openID) }),
            "omitted": AIJSONValue(matching.count - listed.count),
        ]
        guard !projects.isEmpty else { return AIToolResult(text: "The library is empty. Record a demo with start_recording.", data: data) }
        if let query, matching.isEmpty { return AIToolResult(text: "No project title contains \"\(query)\".", data: data) }
        var lines = [query.map { "\(matching.count) of \(projects.count) projects contain \"\($0)\" (newest first)" } ?? "\(projects.count) projects (newest first)"]
        for (index, project) in listed.enumerated() {
            lines.append("\(offset + index + 1). " + AIToolSupport.projectLine(project, isOpen: project.id == openID))
        }
        if listed.isEmpty { lines.append("(nothing after offset \(offset))") }
        if hasMore {
            let remaining = matching.count - offset - listed.count
            // The in-app assistant's default call keeps its wording; paging callers learn the next offset.
            let paging = query != nil || arguments.int("offset") != nil || arguments.int("limit") != nil
            lines.append(paging ? "(\(remaining) more; call again with offset: \(offset + listed.count))" : "(\(remaining) older projects omitted)")
        }
        return AIToolResult(text: lines.joined(separator: "\n"), data: data)
    }
}

// MARK: - open_project

struct OpenProjectTool: AIAssistantTool {
    let name = "open_project"
    let summary = "Open a library project in the editor so the editing tools (zooms, chapters, look, music, export) apply to it."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["project"],
            "properties": [
                "project": ["type": "string", "description": "A project id from list_projects or part of its title (the newest match wins)."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let query = try AIToolArguments(raw).requiredString("project")
        let app = try AIToolSupport.requireApp(context)
        let projects = await app.projectSummaries
        let project = try Self.resolveProject(query, in: projects)
        try await AIToolSupport.appAction(context) { try await MainActor.run { try app.openProject(id: project.id) } }
        let opened = await app.projectSummaries.first { $0.id == project.id } ?? project
        return AIToolResult(text: "Opened \"\(opened.displayTitle)\" in the editor (\(AIToolSupport.seconds(opened.duration)) s, \(opened.zoomCount) zooms, \(opened.chapterCount) chapters, id \(opened.id.uuidString)).")
    }

    static func resolveProject(_ query: String, in projects: [AIProjectSummary]) throws -> AIProjectSummary {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIToolError.invalidArgument("\"project\" must be a project id or title.") }
        if let id = UUID(uuidString: trimmed) {
            guard let match = projects.first(where: { $0.id == id }) else { throw AIToolError.invalidArgument("No project has the id \(trimmed).") }
            return match
        }
        let lowercased = trimmed.lowercased()
        if let match = projects.first(where: { $0.title.lowercased() == lowercased }) { return match }
        if let match = projects.first(where: { $0.title.lowercased().contains(lowercased) }) { return match }
        let titles = projects.prefix(8).map { "\"\($0.displayTitle)\"" }.joined(separator: ", ")
        throw AIToolError.invalidArgument("No project matches \"\(trimmed)\". Projects: \(titles.isEmpty ? "none" : titles).")
    }
}

// MARK: - close_editor

struct CloseEditorTool: AIAssistantTool {
    let name = "close_editor"
    let summary = "Save the open project and return to the library."

    var parametersSchema: [String: Any] {
        ["type": "object", "properties": [String: Any]()]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let app = try AIToolSupport.requireApp(context)
        let closed: String? = await MainActor.run {
            guard let id = app.openProjectID else { return nil }
            let title = app.projectSummaries.first { $0.id == id }?.displayTitle ?? "the project"
            app.closeEditor()
            return title
        }
        guard let closed else { return AIToolResult(text: "The editor is not open; the library is showing.") }
        return AIToolResult(text: "Saved and closed \"\(closed)\". The library is showing.")
    }
}

// MARK: - add_zoom

public struct AddZoomTool: AIAssistantTool {
    public let name = "add_zoom"
    public let summary = "Add a manual zoom to the open project: the camera moves to (x, y) on the recording between start and end seconds. Existing automatic zooms stay."

    static let minimumDuration = 0.2
    static let scaleRange = 1.1...3.0

    public init() {}

    public var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["start", "end", "x", "y"],
            "properties": [
                "start": ["type": "number", "description": "Seconds into the recording."],
                "end": ["type": "number", "description": "Seconds; at least 0.2 s after start."],
                "x": ["type": "number", "minimum": 0, "maximum": 1, "description": "Horizontal centre of the zoom, 0 = left edge, 1 = right edge."],
                "y": ["type": "number", "minimum": 0, "maximum": 1, "description": "Vertical centre, 0 = top, 1 = bottom."],
                "scale": ["type": "number", "minimum": 1.1, "maximum": 3, "description": "Magnification, from 1.1 to 3; by default the project's zoom scale."],
            ],
        ]
    }

    public func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let project = try await AIToolSupport.requireProject(context)
        func number(_ key: String) throws -> Double {
            guard arguments.has(key) else { throw AIToolError.invalidArgument("Missing required argument \"\(key)\".") }
            guard let value = arguments.double(key) else { throw AIToolError.invalidArgument("\"\(key)\" must be a number.") }
            return value
        }
        let start = try number("start")
        let end = try number("end")
        let x = try number("x")
        let y = try number("y")
        let duration = max(0, project.duration)
        guard start >= 0, end <= duration + 0.001 else {
            throw AIToolError.invalidArgument("start and end must lie within 0–\(AIToolSupport.seconds(duration)) s (got \(AIToolSupport.seconds(start))–\(AIToolSupport.seconds(end))).")
        }
        guard end - start >= Self.minimumDuration else {
            throw AIToolError.invalidArgument("end must be at least \(Self.minimumDuration) s after start.")
        }
        guard (0...1).contains(x), (0...1).contains(y) else {
            throw AIToolError.invalidArgument("x and y are normalized positions between 0 and 1 (0.5, 0.5 is the centre).")
        }
        var notes: [String] = []
        var scale = project.settings.zoomScale
        if arguments.has("scale") {
            guard let requested = arguments.double("scale") else { throw AIToolError.invalidArgument("\"scale\" must be a number.") }
            scale = requested.clamped(to: Self.scaleRange)
            if scale != requested { notes.append("scale clamped to \(String(format: "%.2f", scale))") }
        }
        let segment = ZoomSegment(start: start, end: min(end, duration), targetX: x, targetY: y, scale: scale, kind: .manual)
        let updated = try await AIToolSupport.edit(context, projectID: project.id) { current -> (index: Int, count: Int) in
            current.zoomSegments.append(segment)
            let index = AIToolSupport.orderedZooms(current).first { $0.segment.id == segment.id }?.index ?? current.zoomSegments.count
            return (index, current.zoomSegments.count)
        }
        var text = "Added zoom #\(updated.index): \(AIToolSupport.zoomLine(segment)). The project now has \(updated.count) zooms."
        if !notes.isEmpty { text += " (\(notes.joined(separator: ", ")))" }
        let data: AIJSONValue = [
            "project_id": AIJSONValue(project.id.uuidString),
            "index": AIJSONValue(updated.index),
            "zoom_id": AIJSONValue(segment.id.uuidString),
            "zoom": AIProjectReport.zoomData(index: updated.index, segment: segment),
            "zoom_count": AIJSONValue(updated.count),
            "notes": .array(notes.map { AIJSONValue($0) }),
        ]
        return AIToolResult(text: text, data: data)
    }
}

// MARK: - remove_zoom

struct RemoveZoomTool: AIAssistantTool {
    let name = "remove_zoom"
    let summary = "Remove one zoom by its number (1-based, in time order as listed in the project summary) or by its id, or remove all zooms."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                // One JSON type per property: some MCP clients (Codex) keep
                // only the first type of a union, which would lose "all".
                "index": ["type": "integer", "minimum": 1, "description": "The zoom number (1-based, in time order). Give one of index, id or all."],
                "id": ["type": "string", "description": "The zoom's id (from get_project or add_zoom); unlike the number it stays valid when other zooms are added or removed."],
                "all": ["type": "boolean", "description": "true removes every zoom."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let project = try await AIToolSupport.requireProject(context)
        let ordered = AIToolSupport.orderedZooms(project)
        // index "all" is still accepted from models that learned it.
        let removesAll = arguments.bool("all") == true
        if let rawID = arguments.string("id") ?? arguments.string("zoom_id") {
            guard !removesAll else { throw AIToolError.invalidArgument("Give only one of \"index\", \"id\" or \"all\".") }
            guard let id = UUID(uuidString: rawID) else {
                throw AIToolError.invalidArgument("\"id\" must be a zoom id from get_project or add_zoom (got \"\(rawID)\").")
            }
            guard let entry = ordered.first(where: { $0.segment.id == id }) else {
                throw AIToolError.invalidArgument(ordered.isEmpty ? "The project has no zooms." : "No zoom has the id \(rawID); it may have been removed already. Check the project's current zooms.")
            }
            if arguments.has("index") {
                guard let index = arguments.int("index"), index == entry.index else {
                    throw AIToolError.invalidArgument("Zoom \(rawID) is #\(entry.index), which does not match \"index\"; give only one of them.")
                }
            }
            return try await remove(entry, from: project, context: context)
        }
        let rawIndex = arguments.string("index") ?? (removesAll ? "all" : nil)
        guard let rawIndex else { throw AIToolError.invalidArgument("Missing required argument \"index\" (a zoom number), \"id\" or \"all\": true.") }
        if removesAll, rawIndex.lowercased() != "all" {
            throw AIToolError.invalidArgument("Give only one of \"index\", \"id\" or \"all\".")
        }
        if rawIndex.lowercased() == "all" {
            let projectID = AIJSONValue(project.id.uuidString)
            guard !ordered.isEmpty else {
                return AIToolResult(text: "The project has no zooms.", data: ["project_id": projectID, "removed_count": 0, "remaining": 0])
            }
            let removed = try await AIToolSupport.edit(context, projectID: project.id) { current -> Int in
                let count = current.zoomSegments.count
                current.zoomSegments.removeAll()
                return count
            }
            return AIToolResult(text: "Removed all \(removed) zooms. Automatic zooms return if the zoom style is regenerated; set autoZoomEnabled false to keep them off.",
                                data: ["project_id": projectID, "removed_count": AIJSONValue(removed), "remaining": 0])
        }
        guard let index = arguments.int("index") else { throw AIToolError.invalidArgument("\"index\" must be a zoom number (or give \"all\": true).") }
        guard let entry = ordered.first(where: { $0.index == index }) else {
            throw AIToolError.invalidArgument(ordered.isEmpty ? "The project has no zooms." : "Zoom #\(index) does not exist; the project has zooms 1–\(ordered.count).")
        }
        return try await remove(entry, from: project, context: context)
    }

    private func remove(
        _ entry: (index: Int, position: Int, segment: ZoomSegment),
        from project: RecordingProject,
        context: AIAssistantContext
    ) async throws -> AIToolResult {
        let id = entry.segment.id
        let index = entry.index
        let remaining = try await AIToolSupport.edit(context, projectID: project.id) { current -> Int in
            guard current.zoomSegments.contains(where: { $0.id == id }) else {
                throw AIToolError.failed("Zoom #\(index) was already removed or changed; nothing was removed. Check the project's zooms and try again.")
            }
            current.zoomSegments.removeAll { $0.id == id }
            return current.zoomSegments.count
        }
        let data: AIJSONValue = [
            "project_id": AIJSONValue(project.id.uuidString),
            "removed": AIProjectReport.zoomData(index: index, segment: entry.segment),
            "removed_count": 1,
            "remaining": AIJSONValue(remaining),
        ]
        return AIToolResult(text: "Removed zoom #\(index) (\(AIToolSupport.zoomLine(entry.segment))). \(remaining) zooms remain.", data: data)
    }
}

// MARK: - set_zoom_style

struct SetZoomStyleTool: AIAssistantTool {
    let name = "set_zoom_style"
    let summary = "Tune how zooms move: screen animation, zoom scale, click hold, ease in/out durations, how nearby clicks are chained, and whether automatic zooms are on. Only the given keys change."

    static let allowedKeys = ["screenAnimation", "zoomScale", "zoomHold", "zoomEaseIn", "zoomEaseOut", "zoomChainGap", "autoZoomEnabled"]
    static let ranges: [String: ClosedRange<Double>] = [
        "zoomHold": 0.2...3,
        "zoomEaseIn": 0.05...1,
        "zoomEaseOut": 0.05...1.4,
        "zoomChainGap": 0...ProjectSettings.maximumZoomChainGap,
    ]

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "screenAnimation": ["type": "string", "enum": ScreenAnimationStyle.allCases.map(\.rawValue)],
                "zoomScale": ["type": "number", "minimum": 1.1, "maximum": 3, "description": "Default magnification for automatic zooms and new manual zooms, from 1.1 to 3."],
                "zoomHold": ["type": "number", "minimum": 0.2, "maximum": 3, "description": "Seconds an automatic zoom stays on a click, from 0.2 to 3."],
                "zoomEaseIn": ["type": "number", "minimum": 0.05, "maximum": 1, "description": "Seconds to zoom in, from 0.05 to 1."],
                "zoomEaseOut": ["type": "number", "minimum": 0.05, "maximum": 1.4, "description": "Seconds to zoom out, from 0.05 to 1.4."],
                "zoomChainGap": ["type": "number", "minimum": 0, "maximum": ProjectSettings.maximumZoomChainGap, "description": "Clicks closer than this many seconds (from 0 to \(ProjectSettings.maximumZoomChainGap)) pan within one zoom instead of zooming out."],
                "autoZoomEnabled": ["type": "boolean"],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let requested = raw.keys.filter { !(raw[$0] is NSNull) }
        let unknown = requested.filter { !Self.allowedKeys.contains($0) }
        guard unknown.isEmpty else {
            throw AIToolError.invalidArgument("Unknown keys \(unknown.sorted().joined(separator: ", ")). Allowed: \(Self.allowedKeys.joined(separator: ", ")).")
        }
        guard !requested.isEmpty else { throw AIToolError.invalidArgument("No zoom style keys given.") }
        let project = try await AIToolSupport.requireProject(context)

        var changes: [String] = []
        // Validate everything before touching the project so a bad call changes nothing.
        var numbers: [String: Double] = [:]
        for key in ["zoomHold", "zoomEaseIn", "zoomEaseOut", "zoomChainGap"] where arguments.has(key) {
            guard let value = arguments.double(key) else { throw AIToolError.invalidArgument("\"\(key)\" must be a number.") }
            let clamped = value.clamped(to: Self.ranges[key]!)
            numbers[key] = clamped
            changes.append("\(key) = \(UpdateSettingsTool.number(clamped))\(clamped == value ? "" : " (clamped)")")
        }
        var autoZoom: Bool?
        if arguments.has("autoZoomEnabled") {
            guard let value = arguments.bool("autoZoomEnabled") else { throw AIToolError.invalidArgument("\"autoZoomEnabled\" must be true or false.") }
            autoZoom = value
            changes.append("autoZoomEnabled = \(value)")
        }
        // Overlapping keys reuse update_settings (same validation and messages).
        let shared = raw.filter { ["screenAnimation", "zoomScale"].contains($0.key) && !($0.value is NSNull) }
        let sharedUpdate = shared.isEmpty ? nil : try UpdateSettingsTool.prepare(arguments: shared, context: context)
        if let sharedUpdate { changes.insert(contentsOf: sharedUpdate.changes, at: 0) }

        let values = numbers
        let requestedAutoZoom = autoZoom
        // One write for every key, so a parallel edit never lands between halves.
        let (count, settings) = try await AIToolSupport.edit(context, projectID: project.id) { project -> (Int, ProjectSettings) in
            try sharedUpdate?.apply(&project.settings)
            if let hold = values["zoomHold"] {
                let delta = hold - project.settings.zoomHold
                project.settings.zoomHold = hold
                TimelineMath.adjustAutomaticClickHold(in: &project, by: delta)
            }
            if let easeIn = values["zoomEaseIn"] { project.settings.zoomEaseIn = easeIn }
            if let easeOut = values["zoomEaseOut"] {
                let delta = easeOut - project.settings.zoomEaseOut
                project.settings.zoomEaseOut = easeOut
                TimelineMath.adjustAutomaticHold(in: &project.zoomSegments, by: delta, duration: project.duration)
            }
            var regenerate = false
            if let gap = values["zoomChainGap"] {
                project.settings.zoomChainGap = gap
                regenerate = true
            }
            if let enabled = requestedAutoZoom {
                let wasEnabled = project.settings.autoZoomEnabled
                project.settings.autoZoomEnabled = enabled
                if enabled, !wasEnabled || !project.zoomSegments.contains(where: { $0.kind == .automatic }) { regenerate = true }
            }
            if regenerate, project.settings.autoZoomEnabled {
                TimelineMath.regenerateAutomaticZoomSegments(in: &project)
            }
            return (project.zoomSegments.filter(\.isEnabled).count, project.settings)
        }
        let data: AIJSONValue = [
            "project_id": AIJSONValue(project.id.uuidString),
            "changes": .array(changes.map { AIJSONValue($0) }),
            "zoom_style": AIToolSupport.merged(AIProjectReport.zoomStyleData(settings), [
                "screenAnimation": AIJSONValue(settings.screenAnimation.rawValue),
                "zoomScale": .rounded(settings.zoomScale),
            ]),
            "zoom_count": AIJSONValue(count),
        ]
        return AIToolResult(text: context.format("Updated %@", changes.joined(separator: ", ")) + " · \(count) zooms", data: data)
    }
}

// MARK: - set_background_music

struct SetBackgroundMusicTool: AIAssistantTool {
    let name = "set_background_music"
    let summary = "Set the open project's background music to a bundled track (by id or title, see the bundled list in the project summary), to a local audio file, or to \"none\" to remove it. Optional volume 0–1 (the track's suggested level by default)."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["track"],
            "properties": [
                "track": ["type": "string", "description": "Bundled track id or title, a local audio file path, or \"none\"."],
                "volume": ["type": "number", "minimum": 0, "maximum": 1, "description": "Music volume, from 0 (silent) to 1 (full); by default the track's suggested level."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let query = try arguments.requiredString("track")
        let project = try await AIToolSupport.requireProject(context)
        var volume: Double?
        if arguments.has("volume") {
            guard let value = arguments.double("volume") else { throw AIToolError.invalidArgument("\"volume\" must be a number between 0 and 1.") }
            volume = value.clamped(to: 0...1)
        }
        let lowercased = query.lowercased()
        if ["none", "off", "remove", "no music", "silence", "无", "关闭"].contains(lowercased) {
            try await AIToolSupport.edit(context, projectID: project.id) { project in
                var audio = project.settings.resolvedProductDemoAudio
                audio.backgroundMusicPath = nil
                project.settings.productDemoAudio = audio
            }
            return AIToolResult(text: "Background music removed.", data: ["project_id": AIJSONValue(project.id.uuidString), "track": nil])
        }

        let tracks = await Self.availableTracks(context)
        let track: AIMusicTrack
        var isBundled = false
        if let bundled = Self.resolveTrack(query, in: tracks) {
            track = bundled
            isBundled = true
        } else if case let .local(url) = try AIToolPaths.reference(query, context: context), FileManager.default.fileExists(atPath: url.path) {
            guard AIToolPaths.kind(of: url) == .audio else { throw AIToolError.invalidArgument("\(url.lastPathComponent) is not an audio file.") }
            track = AIMusicTrack(id: url.path, title: url.deletingPathExtension().lastPathComponent, suggestedVolume: 0.22, path: url.path)
        } else {
            let names = tracks.map { "\($0.title) (\($0.id))" }.joined(separator: ", ")
            throw AIToolError.invalidArgument("No bundled track or audio file matches \"\(query)\". Bundled tracks: \(names.isEmpty ? "none" : names). Or use \"none\".")
        }
        let level = volume ?? track.suggestedVolume
        try await AIToolSupport.edit(context, projectID: project.id) { project in
            var audio = project.settings.resolvedProductDemoAudio
            audio.backgroundMusicPath = track.path
            audio.backgroundMusicVolume = level
            project.settings.productDemoAudio = audio
        }
        let data: AIJSONValue = [
            "project_id": AIJSONValue(project.id.uuidString),
            "track": [
                "id": isBundled ? AIJSONValue(track.id) : .null,
                "title": AIJSONValue(track.title),
                "path": AIJSONValue(track.path),
                "bundled": AIJSONValue(isBundled),
            ],
            "volume": .rounded(level),
        ]
        return AIToolResult(text: "Background music set to \"\(track.title)\" at volume \(String(format: "%.2f", level)).", data: data)
    }

    static func availableTracks(_ context: AIAssistantContext) async -> [AIMusicTrack] {
        if let app = context.app {
            let tracks = await app.bundledMusicTracks
            if !tracks.isEmpty { return tracks }
        }
        guard let catalog = try? AudioAssetCatalog.loadBundled() else { return [] }
        return catalog.music.map { AIMusicTrack(asset: $0, path: catalog.fileURL(for: $0).path) }
    }

    static func resolveTrack(_ query: String, in tracks: [AIMusicTrack]) -> AIMusicTrack? {
        let lowercased = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowercased.isEmpty else { return nil }
        if let match = tracks.first(where: { $0.id.lowercased() == lowercased }) { return match }
        if let match = tracks.first(where: { $0.title.lowercased() == lowercased }) { return match }
        let compact = lowercased.replacingOccurrences(of: " ", with: "-")
        if let match = tracks.first(where: { $0.id.lowercased() == compact }) { return match }
        if let match = tracks.first(where: { $0.title.lowercased().contains(lowercased) }) { return match }
        return tracks.first { $0.mood.lowercased().contains(lowercased) }
    }
}

// MARK: - set_sound_effects

struct SetSoundEffectsTool: AIAssistantTool {
    let name = "set_sound_effects"
    let summary = "Turn the open project's click confirmation sound and zoom whoosh on or off, optionally with volumes 0–1."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "click": ["type": "boolean", "description": "Play a click sound on every recorded click."],
                "zoom": ["type": "boolean", "description": "Play a whoosh on zoom transitions."],
                "click_volume": ["type": "number", "minimum": 0, "maximum": 1, "description": "Click sound volume, from 0 (silent) to 1 (full)."],
                "zoom_volume": ["type": "number", "minimum": 0, "maximum": 1, "description": "Zoom whoosh volume, from 0 (silent) to 1 (full)."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let project = try await AIToolSupport.requireProject(context)
        var click: Bool?
        var zoom: Bool?
        var clickVolume: Double?
        var zoomVolume: Double?
        for key in ["click", "zoom"] where arguments.has(key) {
            guard let value = arguments.bool(key) else { throw AIToolError.invalidArgument("\"\(key)\" must be true or false.") }
            if key == "click" { click = value } else { zoom = value }
        }
        for key in ["click_volume", "zoom_volume"] where arguments.has(key) {
            guard let value = arguments.double(key) else { throw AIToolError.invalidArgument("\"\(key)\" must be a number between 0 and 1.") }
            if key == "click_volume" { clickVolume = value.clamped(to: 0...1) } else { zoomVolume = value.clamped(to: 0...1) }
        }
        guard click != nil || zoom != nil || clickVolume != nil || zoomVolume != nil else {
            throw AIToolError.invalidArgument("Give at least one of click, zoom, click_volume, zoom_volume.")
        }
        let requested = (click: click, zoom: zoom, clickVolume: clickVolume, zoomVolume: zoomVolume)
        let resolved = try await AIToolSupport.edit(context, projectID: project.id) { project -> ProductDemoAudioSettings in
            var audio = project.settings.resolvedProductDemoAudio
            if let click = requested.click { audio.clickSoundEnabled = click }
            if let zoom = requested.zoom { audio.zoomTransitionSoundEnabled = zoom }
            if let clickVolume = requested.clickVolume { audio.clickSoundVolume = clickVolume }
            if let zoomVolume = requested.zoomVolume { audio.zoomTransitionSoundVolume = zoomVolume }
            project.settings.productDemoAudio = audio
            return audio
        }
        let data: AIJSONValue = [
            "project_id": AIJSONValue(project.id.uuidString),
            "click": AIJSONValue(resolved.clickSoundEnabled),
            "click_volume": .rounded(resolved.clickSoundVolume),
            "zoom": AIJSONValue(resolved.zoomTransitionSoundEnabled),
            "zoom_volume": .rounded(resolved.zoomTransitionSoundVolume),
        ]
        return AIToolResult(text: "Sound effects: click \(resolved.clickSoundEnabled ? "on" : "off") (volume \(String(format: "%.2f", resolved.clickSoundVolume))), zoom whoosh \(resolved.zoomTransitionSoundEnabled ? "on" : "off") (volume \(String(format: "%.2f", resolved.zoomTransitionSoundVolume))).", data: data)
    }
}

// MARK: - export_project

public struct ExportProjectTool: AIAssistantTool {
    public let name: String
    public let summary: String

    init() {
        self.init(name: "export_project", summary: "Render the open project with its look, zooms, captions and audio to an MP4. Default location: export-<timestamp>.mp4 in the assets folder; an optional path may name a file (.mp4) or a folder. An existing file is only replaced with overwrite: true, and the project's own recording and media are never written. Optional width and frame_rate apply to this export only.")
    }

    init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }

    public var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Optional output file or folder; ~ is expanded, a bare name lands in the assets folder. Not inside the Focus Studio library except the project's ai folder."],
                "overwrite": ["type": "boolean", "default": false, "description": "Replace the file at path if it already exists."],
                "width": ["type": "integer", "enum": UpdateSettingsTool.exportWidths, "description": "Width of this export in pixels (the height follows the aspect ratio). The project's export width is not changed."],
                "frame_rate": ["type": "integer", "enum": UpdateSettingsTool.exportFrameRates, "description": "Frames per second of this export. The project's frame rate is not changed."],
            ],
        ]
    }

    public func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let overwrite = try Self.overwriteArgument(arguments)
        let width = try arguments.option("width", in: UpdateSettingsTool.exportWidths)
        let frameRate = try arguments.option("frame_rate", in: UpdateSettingsTool.exportFrameRates)
        var project = try await AIToolSupport.requireProject(context)
        let output = try Self.resolveOutputURL(path: arguments.string("path"), context: context, project: project, overwrite: overwrite)
        // Per-call choices shape this render only; nothing is written back.
        if let width { project.settings.exportWidth = width }
        if let frameRate { project.settings.frameRate = frameRate }
        let rendering = AIToolSupport.renderProgress(context.tr("Exporting…"), context: context, progress: progress)
        let result = try await ProjectVideoRenderer.export(project: project, to: output, progress: rendering)
        let text = context.format("Exported %@ (%@ s, %lld × %lld)", output.lastPathComponent, AIToolSupport.seconds(result.duration), result.width, result.height)
        let data = AIToolSupport.merged(
            AIToolSupport.videoData(output, duration: result.duration, width: result.width, height: result.height),
            ["project_id": AIJSONValue(project.id.uuidString), "frame_rate": AIJSONValue(result.frameRate), "includes_audio": AIJSONValue(result.includesAudio)]
        )
        return AIToolResult(text: text + "\n" + output.path, attachments: [output], data: data)
    }

    /// The optional "overwrite" flag of the tools that write a file.
    static func overwriteArgument(_ arguments: AIToolArguments) throws -> Bool {
        guard arguments.has("overwrite") else { return false }
        guard let value = arguments.bool("overwrite") else { throw AIToolError.invalidArgument("\"overwrite\" must be true or false.") }
        return value
    }

    /// Nil → a fresh `export-<timestamp>.mp4` in the assets folder; otherwise
    /// see ``AIToolPaths/outputFile(path:context:prefix:fileExtension:date:outputGuard:overwrite:)``.
    /// With a project, the destination must also pass ``OutputGuard``,
    /// checked before any folder is created.
    public static func resolveOutputURL(
        path: String?,
        context: AIAssistantContext,
        date: Date = Date(),
        project: RecordingProject? = nil,
        overwrite: Bool = false
    ) throws -> URL {
        try AIToolPaths.outputFile(
            path: path, context: context, prefix: "export", fileExtension: "mp4", date: date,
            outputGuard: project.map { OutputGuard(project: $0, context: context) }, overwrite: overwrite
        )
    }

    /// Where a tool may write a file for `project`. Never over the recording
    /// or any media the project uses (or any other `protecting` file, such as
    /// the clips being joined); never inside the projects library except the
    /// project's own `ai/` folder; never over an existing file unless the
    /// caller asked to overwrite it. Paths are compared with symlinks resolved.
    /// Without a project only the library rule and the extra files apply.
    struct OutputGuard {
        let protectedFiles: [String]
        let libraryRoot: URL?
        let allowedFolders: [URL]

        init(project: RecordingProject?, context: AIAssistantContext, protecting extraFiles: [URL] = []) {
            let source = project?.sourceVideoPath ?? ""
            let projectFolder = project.flatMap { project in
                context.projectsDirectory?.appendingPathComponent(project.id.uuidString, isDirectory: true)
                    ?? (source.hasPrefix("/") ? URL(fileURLWithPath: source).deletingLastPathComponent() : nil)
            }
            func resolved(_ path: String?) -> URL? {
                guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
                if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
                return projectFolder?.appendingPathComponent(path)
            }
            let settings = project?.settings
            let audio = settings?.productDemoAudio
            let projectFiles = [source, settings?.backgroundImagePath, audio?.backgroundMusicPath, audio?.clickSoundPath, audio?.zoomTransitionSoundPath]
                .compactMap(resolved)
            protectedFiles = (projectFiles + extraFiles).map(AIToolPaths.canonicalPath)
            libraryRoot = context.projectsDirectory
            // The canonical ai folder, and the one next to a nested legacy source
            // (the assistant's assets folder for that project).
            var folders: [URL] = []
            if let projectFolder { folders.append(projectFolder.appendingPathComponent("ai", isDirectory: true)) }
            if let sourceURL = resolved(source) {
                let nested = sourceURL.deletingLastPathComponent().appendingPathComponent("ai", isDirectory: true)
                if let projectFolder, AIToolPaths.path(AIToolPaths.canonicalPath(nested), isInside: AIToolPaths.canonicalPath(projectFolder)) {
                    folders.append(nested)
                }
            }
            allowedFolders = folders
        }

        func check(_ url: URL, overwrite: Bool) throws {
            let destination = AIToolPaths.canonicalPath(url)
            if protectedFiles.contains(where: { $0.lowercased() == destination.lowercased() }) {
                throw AIToolError.invalidArgument("\"path\" is \(url.lastPathComponent), a file this project uses (its recording or media) or an input of this call; writing there would destroy it. Choose another file name.")
            }
            try checkLocation(destination)
            if !overwrite, FileManager.default.fileExists(atPath: url.path) {
                throw AIToolError.invalidArgument("\(url.path) already exists. Pass overwrite: true to replace it, or choose another file name.")
            }
        }

        /// A folder the default file name would be written into, checked before it is created.
        func checkFolder(_ url: URL) throws {
            try checkLocation(AIToolPaths.canonicalPath(url))
        }

        private func checkLocation(_ destination: String) throws {
            guard let libraryRoot, AIToolPaths.path(destination, isInside: AIToolPaths.canonicalPath(libraryRoot)) else { return }
            guard !allowedFolders.contains(where: { AIToolPaths.path(destination, isInside: AIToolPaths.canonicalPath($0)) }) else { return }
            let suggestion = allowedFolders.first.map { " Use \($0.path)," } ?? ""
            throw AIToolError.invalidArgument("\"path\" is inside the Focus Studio library (\(libraryRoot.path)), which only the app writes.\(suggestion) leave \"path\" empty for the assets folder, or choose a folder outside the library.")
        }
    }
}
