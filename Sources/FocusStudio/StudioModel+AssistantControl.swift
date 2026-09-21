import FocusStudioCapture
import FocusStudioCore
import Foundation

/// Where the assistant's generated files go right now. Tools read it off the
/// main actor, so the open project's folder is mirrored here under a lock
/// whenever `StudioModel.activeProject` changes.
final class AssistantAssetsLocator: @unchecked Sendable {
    private let lock = NSLock()
    private var projectFolder: URL?

    /// `~/Library/Application Support/FocusStudio/AI Assets`, used when no project is open.
    static let sharedDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FocusStudio/AI Assets", isDirectory: true)

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
        return projectFolder?.appendingPathComponent("ai", isDirectory: true) ?? Self.sharedDirectory
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
            throw AIToolError.failed(L10n.tr("Finish the current library operation before starting another."))
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
                throw AIToolError.failed(captureFailureDetails ?? L10n.tr("Screen Recording permission is required."))
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
        if destination == .countdown { return .countdown }
        switch captureEngine.state {
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
            return .idle
        }
    }

    var lastReportedError: String? {
        if isShowingError, !errorMessage.isEmpty { return errorMessage }
        return nil
    }

    func startRecording(sourceID: String, options: AIRecordingOptions) throws {
        guard !captureEngine.isRecording, destination != .countdown else {
            throw AIToolError.failed("A recording is already in progress.")
        }
        guard !isManagingProjects, !isRunningCodexPlan else {
            throw AIToolError.failed(L10n.tr("Finish the current library operation before starting another."))
        }
        guard let target = captureEngine.availableTargets.first(where: { $0.id == sourceID }) else {
            throw AIToolError.invalidArgument("Source \(sourceID) is no longer available; call list_recording_sources again.")
        }
        if destination == .editor { closeEditor() }
        if let value = options.systemAudio { recordSystemAudio = value }
        if let value = options.microphone { recordMicrophone = value }
        if let value = options.automaticZooms { automaticZooms = value }
        if let value = options.browserContentOnly { browserContentOnly = value }
        if let value = options.frameRate { frameRate = value }
        selectedTargetID = target.id
        destination = .recorder
        isShowingError = false
        startRecordingCountdown(allowUnavailableTracking: true)
        guard destination == .countdown else {
            throw AIToolError.failed(lastReportedError ?? "The countdown could not start.")
        }
    }

    var projectSummaries: [AIProjectSummary] {
        projects.map(AIProjectSummary.init)
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
            throw AIToolError.failed(L10n.tr("Finish the current library operation before starting another."))
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
}
