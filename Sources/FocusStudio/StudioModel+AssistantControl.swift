import CoreGraphics
import ImageIO
import FocusStudioAutomation
import FocusStudioCapture
import FocusStudioCore
import Foundation

struct RecordingObservation {
    var id: UUID
    var recordingID: UUID
    var frame: CGRect
    var uptime: TimeInterval
    /// Optional field identity observed with this frame; never field contents.
    var textFocus: RecordedTextInput.Focus? = nil
    var textFocusFailure: RecordedTextInput.InputError? = nil
}

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
            return try await refreshListedSources().map(AIRecordingSource.init)
        }
        guard !isManagingProjects else {
            throw AILocalizedFailure("Finish the current library operation before starting another.")
        }
        if destination == .editor { closeEditor() }
        if destination == .recorder {
            do {
                try await refreshListedSources()
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

    // isRecordingPaused: StudioModel.swift (the control bar's Pause).

    var lastReportedError: String? {
        if isShowingError, !errorMessage.isEmpty { return errorMessage }
        // A refused Screen Recording permission is shown on the recorder screen
        // rather than as an alert; without this the assistant would read the
        // failed start as a cancelled countdown.
        if capturePermissionDenied { return captureFailureDetails ?? L10n.tr("Screen Recording permission is required.") }
        return nil
    }

    /// The sound the recorder's own choices record, which an external
    /// start_recording may add to only with the person's consent.
    var recorderAudio: AIRecordingAudio {
        AIRecordingAudio(microphone: recordMicrophone, systemAudio: recordSystemAudio)
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
        // Checked before anything changes: the person's area and source
        // choice stay as they are (the in-app assistant comes here without
        // the bridge's navigation check).
        guard !isSelectingArea else { throw AIToolError.failed(Self.drawingAreaRefusal) }
        // The person's Record waits for macOS's microphone dialog: its
        // countdown starts when they answer, with the source they chose.
        guard !isWaitingForMicrophoneAccess else { throw AIToolError.failed(Self.waitingForMicrophoneRefusal) }
        guard options.interactionMode != "codex" || target.kind == .window else {
            throw AIToolError.invalidArgument("Codex interaction mode requires a window source.")
        }
        if destination == .editor { closeEditor() }
        selectedTargetID = target.id
        recordingSourceKind = target.kind
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

    /// A capture's broad `isRecording` includes preparing and stopping. Native
    /// automation requires actual recording and must stop as soon as Discard
    /// starts, before its asynchronous writer flush completes.
    static func codexInputIsActive(engineState: RecordingState, isBusy: Bool, isPaused: Bool, isTransitioning: Bool) -> Bool {
        engineState == .recording && !isBusy && !isPaused && !isTransitioning
    }

    private var canDispatchCodexRecordingInput: Bool {
        Self.codexInputIsActive(engineState: captureEngine.state, isBusy: isBusy || isFinishingRecording,
                                isPaused: isRecordingPaused || captureEngine.isPaused,
                                isTransitioning: isChangingRecordingPause || captureEngine.isChangingPauseState)
    }

    /// Fixed-size ScreenCaptureKit frames preserve aspect ratio. A resized
    /// window may therefore be letterboxed; its image coordinates are no longer
    /// the same normalized coordinates as desktop input. Position changes are
    /// safe after a new observation, but size changes require a new recording.
    static func recordingWindowSizeMatches(_ current: CGRect, captured: CaptureRect) -> Bool {
        CodexPlanRunner.windowSizeMatches(CaptureRect(x: current.minX, y: current.minY, width: current.width, height: current.height), captured: captured)
    }

    private func liveRecordingFrame(for target: CaptureTargetInfo) throws -> CGRect {
        guard target.kind == .window,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]],
              let window = info.first(where: { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value == target.nativeID }),
              let bounds = window[kCGWindowBounds] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 0, rect.height > 0 else {
            throw AIToolError.failed("The recorded window is no longer visible. Restore it before capturing a new observation.")
        }
        guard let capturedTarget = captureEngine.recordingTarget,
              capturedTarget.kind == .window, capturedTarget.nativeID == target.nativeID,
              Self.recordingWindowSizeMatches(rect, captured: capturedTarget.frame) else {
            throw AIToolError.failed("The recording window was resized. Stop this take and start a new recording before sending more actions.")
        }
        return rect
    }

    func captureRecordingFrame(recordingID: UUID, to url: URL) async throws -> AIJSONValue {
        guard let attempt = currentRecording, attempt.id == recordingID, attempt.isLive,
              attempt.settings.interactionMode == "codex", canDispatchCodexRecordingInput,
              !isPerformingRecordingAction else {
            throw AIToolError.failed("A live, unpaused Codex window recording is required.")
        }
        let before = try liveRecordingFrame(for: attempt.target)
        let textFocusBefore = RecordedTextInput.observation(targetID: attempt.target.nativeID, frame: before)
        try await captureEngine.captureScreenshot(to: url, allowLatestFrameFallback: false)
        guard currentRecording?.id == recordingID, currentRecording?.isLive == true,
              canDispatchCodexRecordingInput, !isPerformingRecordingAction,
              try liveRecordingFrame(for: attempt.target) == before else {
            throw AIToolError.failed("The recording or window changed while observing it. Capture a new frame.")
        }
        let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        let image = imageSource.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        let textFocusAfter = RecordedTextInput.observation(targetID: attempt.target.nativeID, frame: before)
        let textObservation = textFocusBefore.paired(with: textFocusAfter)
        let observation = RecordingObservation(id: UUID(), recordingID: recordingID, frame: before,
                                               uptime: ProcessInfo.processInfo.systemUptime, textFocus: textObservation.focus,
                                               textFocusFailure: textObservation.failure)
        recordingObservation = observation
        return ["recording_id": AIJSONValue(recordingID.uuidString), "observation_id": AIJSONValue(observation.id.uuidString),
                "width": AIJSONValue(image?.width ?? 0), "height": AIJSONValue(image?.height ?? 0),
                "text_input_ready": AIJSONValue(textObservation.focus != nil),
                "text_input_reason": AIJSONValue(textObservation.failure?.diagnosticCode ?? "ready"),
                "coordinate_space": "normalized_uncropped_source", "path": AIJSONValue(url.path)]
    }

    /// A recorder-owned execution path: the coordinates used to dispatch input
    /// are also the coordinates used by the video cursor and automatic camera.
    func performRecordingAction(recordingID: UUID, actionID: String, observationID: UUID, action: CodexRecordingAction) async throws -> AIJSONValue {
        guard let attempt = currentRecording, attempt.id == recordingID, attempt.isLive,
              recordingPhase == .recording, !isBusy, !isFinishingRecording, !isRunningCodexPlan else {
            throw AIToolError.failed("This recording session is no longer live. No input was sent.")
        }
        guard attempt.settings.interactionMode == "codex", recordingInteractionTrace?.sessionID == recordingID else {
            throw AIToolError.failed("This is a manual recording. Start a new window recording with interaction_mode codex for tracked actions.")
        }
        if let receipt = recordingActionReceipts[actionID] {
            return receipt
        }
        guard !isPerformingRecordingAction else { throw AIToolError.failed("Another recording action is still running.") }
        guard !isRecordingPaused, !isChangingRecordingPause, !captureEngine.isChangingPauseState else {
            throw AIToolError.failed("Recording is paused. Resume it before sending an action.")
        }
        guard [.move, .click, .scroll].contains(action.type) else {
            throw AIToolError.invalidArgument("Only move, click and scroll are supported during a live recording.")
        }
        guard let observation = recordingObservation, observation.id == observationID, observation.recordingID == recordingID,
              ProcessInfo.processInfo.systemUptime - observation.uptime <= 60,
              try liveRecordingFrame(for: attempt.target) == observation.frame else {
            throw AIToolError.failed("Missing, stale or changed window observation. Call capture_recording_frame before each action.")
        }
        recordingObservation = nil
        isPerformingRecordingAction = true
        defer { isPerformingRecordingAction = false }
        // A retry after a partially executed or cancelled click must never click twice.
        recordingActionReceipts[actionID] = ["status": "interrupted", "action_id": AIJSONValue(actionID), "message": "This action was attempted. Observe the target before choosing a new action id."]
        let previous = recordingInteractionTrace?.events.last(where: { $0.x != nil && $0.y != nil })
        let initial = previous.flatMap { event in event.x.flatMap { x in event.y.map { CGPoint(x: x, y: $0) } } }
        try await CodexPlanRunner.run(
            actions: [action], in: captureEngine.recordingTarget ?? attempt.target,
            waitUntilReady: { [weak self] in
                guard let self, self.currentRecording?.id == recordingID, self.currentRecording?.isLive == true,
                      self.canDispatchCodexRecordingInput else {
                    throw AIToolError.failed("Recording paused or ended; the remaining input was cancelled.")
                }
                guard try self.liveRecordingFrame(for: attempt.target) == observation.frame else {
                    throw AIToolError.failed("The window moved after observation. Capture a new frame before acting.")
                }
                try Task.checkCancellation()
            },
            activeClock: { [weak self] in self?.captureEngine.recordingIntervals.elapsed(at: ProcessInfo.processInfo.systemUptime) ?? 0 },
            initialCursorPosition: initial,
            onInteraction: { [weak self] event in
                guard let self, self.recordingInteractionTrace?.sessionID == recordingID else { return }
                let sequence = self.recordingInteractionTrace?.events.count ?? 0
                self.recordingInteractionTrace?.events.append(InteractionEvent(
                    sequence: sequence,
                    time: event.time, kind: InteractionEventKind(rawValue: event.kind.rawValue)!, x: event.x, y: event.y
                ))
            }
        )
        let receipt: AIJSONValue = [
            "status": "performed", "recording_id": AIJSONValue(recordingID.uuidString), "action_id": AIJSONValue(actionID),
            "action": AIJSONValue(action.type.rawValue), "elapsed": AIJSONValue(captureEngine.recordingIntervals.elapsed(at: ProcessInfo.processInfo.systemUptime)),
            "trace_events": AIJSONValue(recordingInteractionTrace?.events.count ?? 0),
        ]
        recordingActionReceipts[actionID] = receipt
        return receipt
    }

    /// Text entry shares the pointer action's recording identity, single-use
    /// observation and receipt table. The native helper validates real AX focus
    /// without reading or persisting the field's contents.
    func performRecordingText(recordingID: UUID, actionID: String, observationID: UUID, text: String) async throws -> AIJSONValue {
        try AIRecordingText.validate(text)
        guard let attempt = currentRecording, attempt.id == recordingID, attempt.isLive,
              recordingPhase == .recording, !isBusy, !isFinishingRecording, !isRunningCodexPlan else {
            throw AIToolError.failed("This recording session is no longer live. No input was sent.")
        }
        guard attempt.settings.interactionMode == "codex", recordingInteractionTrace?.sessionID == recordingID else {
            throw AIToolError.failed("This is a manual recording. Start a new window recording with interaction_mode codex for tracked actions.")
        }
        if let receipt = recordingActionReceipts[actionID] { return receipt }
        guard !isPerformingRecordingAction, canDispatchCodexRecordingInput else {
            throw AIToolError.failed("A live, unpaused Codex window recording is required.")
        }
        guard let observation = recordingObservation, observation.id == observationID, observation.recordingID == recordingID,
              ProcessInfo.processInfo.systemUptime - observation.uptime <= 60,
              try liveRecordingFrame(for: attempt.target) == observation.frame else {
            throw AIToolError.failed("Missing, stale or changed window observation. Call capture_recording_frame before each action.")
        }
        guard let observedTextFocus = observation.textFocus else {
            throw observation.textFocusFailure ?? RecordedTextInput.InputError.unsupportedField
        }
        recordingObservation = nil
        isPerformingRecordingAction = true
        defer { isPerformingRecordingAction = false }
        var typedCharacters = 0
        func receipt(_ status: String) -> AIJSONValue {
            ["status": AIJSONValue(status), "action": "type_text", "recording_id": AIJSONValue(recordingID.uuidString),
             "action_id": AIJSONValue(actionID), "typed_characters": AIJSONValue(typedCharacters),
             "elapsed": AIJSONValue(captureEngine.recordingIntervals.elapsed(at: ProcessInfo.processInfo.systemUptime)),
             "trace_events": AIJSONValue(recordingInteractionTrace?.events.count ?? 0),
             "typing_events": AIJSONValue(recordingInteractionTrace?.typingActivity?.count ?? 0)]
        }
        recordingActionReceipts[actionID] = receipt("interrupted")
        try await RecordedTextInput.run(text: text, targetID: attempt.target.nativeID, frame: observation.frame, observedFocus: observedTextFocus,
            waitUntilReady: { [weak self] in
                guard let self, self.currentRecording?.id == recordingID, self.currentRecording?.isLive == true,
                      self.canDispatchCodexRecordingInput else {
                    throw AIToolError.failed("Recording paused or ended; the remaining input was cancelled.")
                }
                guard try self.liveRecordingFrame(for: attempt.target) == observation.frame else {
                    throw AIToolError.failed("The window moved after observation. Capture a new frame before acting.")
                }
                try Task.checkCancellation()
            },
            onCharacters: { count in
                typedCharacters += count
                recordingActionReceipts[actionID] = receipt("interrupted")
            },
            onActivity: { [weak self] point in
                guard let self else { return }
                let time = self.captureEngine.recordingIntervals.elapsed(at: ProcessInfo.processInfo.systemUptime)
                self.appendCodexTypingActivity(recordingID: recordingID, activity: TypingActivity(time: time, x: point.x, y: point.y))
            }
        )
        let result = receipt("performed")
        recordingActionReceipts[actionID] = result
        return result
    }

    /// Input timing belongs to the recording that actually dispatched it.
    /// Keep it separate from pointer motion and from the physical key monitor.
    /// Called synchronously after a native Unicode chunk, so partial input is
    /// retained even if a later chunk is cancelled or loses its focused field.
    func appendCodexTypingActivity(recordingID: UUID, activity: TypingActivity) {
        guard let attempt = currentRecording, attempt.id == recordingID, attempt.isLive,
              attempt.settings.interactionMode == "codex", recordingPhase == .recording,
              !isBusy, !isFinishingRecording, !isRecordingPaused, !isChangingRecordingPause,
              !captureEngine.isChangingPauseState,
              recordingInteractionTrace?.sessionID == recordingID, recordingInteractionTrace?.source == .execution,
              activity.time.isFinite, activity.time >= 0,
              activity.x.isFinite, activity.y.isFinite,
              (0...1).contains(activity.x), (0...1).contains(activity.y),
              activity.time >= (recordingInteractionTrace?.typingActivity?.last?.time ?? 0) else { return }
        if recordingInteractionTrace?.typingActivity == nil { recordingInteractionTrace?.typingActivity = [] }
        recordingInteractionTrace?.typingActivity?.append(activity)
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

    /// Seconds recorded so far, paused time left out (as in the video and
    /// the control bar's clock).
    var recordingElapsed: TimeInterval? {
        guard recordingPhase == .recording else { return nil }
        if let attempt = currentRecording, attempt.isLive {
            return attempt.recordedDuration(at: recordingClock.now())
        }
        // A capture without an attempt (a Codex Director plan): the engine's clock.
        return captureEngine.isRecording ? max(0, captureEngine.duration) : nil
    }

    /// Seconds of recording left before the duration stops it; it does not
    /// count down while paused.
    var recordingRemaining: TimeInterval? {
        guard recordingPhase == .recording, let attempt = currentRecording, attempt.isLive else { return nil }
        return attempt.remaining(at: recordingClock.now())
    }

    var recordingSession: AIRecordingSession? {
        currentRecording?.session(at: recordingClock.now())
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
