import FocusStudioAutomation
import FocusStudioCapture
import FocusStudioCore
import Foundation

/// Where the assistant's generated files go right now. Tools read it off the
/// main actor, so the open project's folder is mirrored here under a lock
/// whenever `StudioModel.activeProject` changes.
final class AssistantAssetsLocator: @unchecked Sendable {
    private let lock = NSLock()
    private var projectFolder: URL?
    /// Used when no project is open.
    let sharedDirectory: URL

    init(sharedDirectory: URL) {
        self.sharedDirectory = sharedDirectory
    }

    /// `AI Assets` next to the library: `~/Library/Application Support/FocusStudio/AI Assets`
    /// for the real library, and inside the temporary folder of a test library.
    static func sharedDirectory(forLibrary library: URL) -> URL {
        library.standardizedFileURL.deletingLastPathComponent().appendingPathComponent("AI Assets", isDirectory: true)
    }

    /// Loaded projects carry an absolute raw.mp4 path inside their own folder.
    func update(sourceVideoPath: String?) {
        let folder = sourceVideoPath.flatMap { path -> URL? in
            guard path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        lock.lock()
        projectFolder = folder
        lock.unlock()
    }

    /// The project's `ai/` folder, else the shared folder.
    var directory: URL {
        lock.lock()
        defer { lock.unlock() }
        return projectFolder?.appendingPathComponent("ai", isDirectory: true) ?? sharedDirectory
    }
}

/// The assistant's view of the app. Every operation goes through the same
/// entry points the buttons use, so permissions, busy states and library
/// guards apply exactly as for a click.
extension StudioModel: AppControlling {
    func refreshRecordingSources() async throws -> [AIRecordingSource] {
        if captureEngine.isRecording || destination == .countdown {
            // Never leave a live recording; just refresh the list.
            return try await captureEngine.refreshAvailableTargets().map(AIRecordingSource.init)
        }
        guard !isManagingProjects else {
            throw AILocalizedFailure("Finish the current library operation before starting another.")
        }
        if destination == .editor { closeEditor() }
        if destination == .recorder {
            do {
                _ = try await captureEngine.refreshAvailableTargets()
                capturePermissionDenied = false
                captureFailureDetails = nil
            } catch {
                if let captureError = error as? CaptureEngineError, captureError.isScreenRecordingPermissionFailure {
                    capturePermissionDenied = true
                    captureFailureDetails = captureError.localizedDescription
                }
                throw AIToolError.failed(error.localizedDescription)
            }
        } else {
            let wasShowingError = isShowingError
            await showRecorder()
            if capturePermissionDenied {
                if let captureFailureDetails { throw AIToolError.failed(captureFailureDetails) }
                throw AILocalizedFailure("Screen Recording permission is required.")
            }
            if isShowingError, !wasShowingError, captureEngine.availableTargets.isEmpty {
                throw AIToolError.failed(errorMessage)
            }
        }
        return captureEngine.availableTargets.map(AIRecordingSource.init)
    }

    var recordingSources: [AIRecordingSource] {
        captureEngine.availableTargets.map(AIRecordingSource.init)
    }

    var recordingPhase: AIRecordingPhase {
        Self.recordingPhase(
            destination: destination,
            isFinishingRecording: isFinishingRecording,
            engineState: captureEngine.state,
            attemptIsLive: currentRecording?.isLive == true,
            isRunningCodexPlan: isRunningCodexPlan
        )
    }

    /// The recording phase from the model's state, kept apart so regression
    /// tests can check it for states only a real capture reaches.
    static func recordingPhase(
        destination: Destination,
        isFinishingRecording: Bool,
        engineState: RecordingState,
        attemptIsLive: Bool,
        isRunningCodexPlan: Bool
    ) -> AIRecordingPhase {
        if destination == .countdown { return .countdown }
        // Saving the project follows the engine's own stop; the phase stays
        // `.stopping` until the editor shows the result.
        if isFinishingRecording { return .stopping }
        switch engineState {
        case .preparing:
            return .countdown
        case .recording:
            return .recording
        case .stopping:
            return .stopping
        case let .failed(message):
            // A failure is only current while the recording screen shows it;
            // afterwards the engine keeps the old state until the next start.
            return destination == .recording ? .failed(message) : .idle
        case .idle, .completed:
            // A Codex Director plan saves its capture (the project is created
            // and saved) after the engine completes and before the editor
            // opens it; it has no recording attempt, so that save is reported
            // as stopping, not idle (which a waiting tool reads as cancelled).
            // Its success opens the editor and its failure the Director, both
            // idle again.
            if destination == .recording, isRunningCodexPlan { return .stopping }
            // A capture this model started and nothing has ended yet. In the
            // app the engine then reports `.recording` itself; a capture
            // scripted through `startCapture` (regression tests) leaves the
            // engine idle.
            return destination == .recording && attemptIsLive ? .recording : .idle
        }
    }

    var lastReportedError: String? {
        if isShowingError, !errorMessage.isEmpty { return errorMessage }
        // A refused Screen Recording permission is shown on the recorder screen
        // rather than as an alert; without this the assistant would read the
        // failed start as a cancelled countdown.
        if capturePermissionDenied { return captureFailureDetails ?? L10n.tr("Screen Recording permission is required.") }
        return nil
    }

    func startRecording(sourceID: String, options: AIRecordingOptions) throws -> UUID {
        guard !captureEngine.isRecording, destination != .countdown, currentRecording?.isLive != true else {
            throw AIToolError.failed("A recording is already in progress.")
        }
        guard !isManagingProjects, !isRunningCodexPlan else {
            throw AILocalizedFailure("Finish the current library operation before starting another.")
        }
        guard let target = captureEngine.availableTargets.first(where: { $0.id == sourceID }) else {
            throw AIToolError.invalidArgument("Source \(sourceID) is no longer available; call list_recording_sources again.")
        }
        return try startRecording(target: target, options: options)
    }

    /// Starts the countdown for a target the engine listed, recording with
    /// the recorder's choices overridden by `options` for this recording only
    /// (the recorder keeps its own), and returns the attempt's id. Kept apart
    /// from the lookup so regression tests, which cannot fill the engine's
    /// list without ScreenCaptureKit, can drive it.
    func startRecording(target: CaptureTargetInfo, options: AIRecordingOptions) throws -> UUID {
        guard !isFinishingRecording else {
            throw AIToolError.failed("The last recording is still being saved. Try again when the editor shows it.")
        }
        if destination == .editor { closeEditor() }
        selectedTargetID = target.id
        destination = .recorder
        // Errors from earlier attempts must not be read as this attempt's outcome.
        isShowingError = false
        capturePermissionDenied = false
        captureFailureDetails = nil
        let id = beginRecordingCountdown(
            target: target,
            settings: recorderSettings.applying(options),
            duration: options.duration,
            allowUnavailableTracking: true
        )
        guard let id, destination == .countdown else {
            throw AIToolError.failed(lastReportedError ?? "The countdown could not start.")
        }
        return id
    }

    /// Applies an assistant edit to the project open in the editor through the
    /// same path as an inspector change. Throws instead of dropping the edit
    /// when no editor is showing or a library operation is running.
    func applyAssistantEdit(_ mutate: (inout RecordingProject) throws -> Void) throws {
        guard destination == .editor, var project = activeProject else { throw AIToolError.noProject }
        guard !isManagingProjects else {
            throw AILocalizedFailure("Finish the current library operation before starting another.")
        }
        try mutate(&project)
        guard updateActiveProject(project) else {
            throw AIToolError.failed("The editor changed before the edit was saved; nothing was changed.")
        }
    }

    var recordingElapsed: TimeInterval? {
        guard recordingPhase == .recording else { return nil }
        let live = currentRecording.flatMap { $0.isLive ? $0.startUptime : nil }
        guard let start = live ?? captureEngine.recordingStartUptime else { return nil }
        return max(0, recordingClock.now() - start)
    }

    var recordingRemaining: TimeInterval? {
        guard recordingPhase == .recording, let attempt = currentRecording, attempt.isLive,
              let deadline = attempt.automaticStopUptime else { return nil }
        return max(0, deadline - recordingClock.now())
    }

    var recordingSession: AIRecordingSession? {
        currentRecording?.session
    }

    var projectSummaries: [AIProjectSummary] {
        projects.map(AIProjectSummary.init)
    }

    /// The editor holds the newest edits of the open project; every other
    /// project is as the library last loaded or saved it.
    func project(id: UUID) -> RecordingProject? {
        if destination == .editor, let active = activeProject, active.id == id { return active }
        return projects.first { $0.id == id }
    }

    var openProjectID: UUID? {
        destination == .editor ? activeProject?.id : nil
    }

    func openProject(id: UUID) throws {
        guard let project = projects.first(where: { $0.id == id }) else {
            throw AIToolError.invalidArgument("No project has the id \(id.uuidString).")
        }
        guard !captureEngine.isRecording, destination != .countdown else {
            throw AIToolError.failed("Stop the current recording before opening a project.")
        }
        guard !isManagingProjects, !isRunningCodexPlan, !isBusy else {
            throw AILocalizedFailure("Finish the current library operation before starting another.")
        }
        if destination == .editor {
            if activeProject?.id == id { return }
            closeEditor()
        }
        open(project)
    }

    var bundledMusicTracks: [AIMusicTrack] {
        bundledMusicAssets.compactMap { asset in
            guard let path = bundledAudioPath(for: asset) else { return nil }
            return AIMusicTrack(asset: asset, path: path)
        }
    }

    // importVideo(from:title:) and importScreenshotDemo(from:title:) are the
    // Import video and Animate screenshot actions themselves (StudioModel.swift).

    func renameLibraryProject(id: UUID, to title: String) async throws -> RecordingProject {
        guard projects.contains(where: { $0.id == id }) else {
            throw AIToolError.invalidArgument("No project has the id \(id.uuidString).")
        }
        try showLibraryForProjectManagement()
        return try await renameProjectInLibrary(id: id, to: title)
    }

    func trashLibraryProject(id: UUID) async throws -> RecordingProject {
        guard let project = project(id: id) else {
            throw AIToolError.invalidArgument("No project has the id \(id.uuidString).")
        }
        try showLibraryForProjectManagement()
        let outcome = await moveProjectsToTrash(ids: [id])
        if let refusal = outcome.refusal { throw refusal }
        guard outcome.deleted.contains(id) else {
            throw outcome.failures.first ?? AILocalizedFailure("The project could not be moved to Trash. Its files were kept.")
        }
        return project
    }
}
