import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreImage
import FocusStudioAutomation
import FocusStudioCapture
import FocusStudioCore
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StudioModel: ObservableObject {
    enum Destination {
        case library
        case director
        case recorder
        case countdown
        case recording
        case editor
    }

    @Published var destination: Destination = .library
    @Published var projects: [RecordingProject] = []
    @Published var activeProject: RecordingProject? {
        didSet { assistantAssetsLocator.update(sourceVideoPath: activeProject?.sourceVideoPath) }
    }
    @Published var selectedTargetID: String?
    @Published private(set) var selectedAreaTarget: CaptureTargetInfo?
    @Published private(set) var isSelectingArea = false
    // Screen-only capture is the quiet default. On current macOS releases,
    // enabling system audio can trigger a separate Screen & System Audio
    // permission prompt even when Screen Recording itself is already granted.
    @Published var recordSystemAudio = false
    @Published var recordMicrophone = false
    @Published var automaticZooms = true
    @Published var browserContentOnly = true
    @Published var hideBrowserBookmarksBar = true
    @Published var frameRate = 60
    @Published var inputWarning: String?
    @Published private(set) var interactionTrackingAuthorized = false
    @Published private(set) var accessibilityAuthorized = false
    @Published private(set) var inputMonitoringAuthorized = false
    @Published var isShowingInteractionSetup = false
    @Published var capturePermissionDenied = false
    @Published var captureFailureDetails: String?
    @Published var isBusy = false
    @Published var busyMessage = "Working…"
    @Published var isShowingError = false
    @Published var errorMessage = ""
    @Published var isTakingScreenshot = false
    @Published var screenshotNotice: String?
    @Published var lastScreenshotURL: URL?
    @Published private(set) var recordingCountdown = 3
    @Published private(set) var isRunningCodexPlan = false
    @Published private(set) var isManagingProjects = false
    /// The editor's Export is rendering (see ``exportFromEditor(_:to:)``).
    @Published private(set) var isExportingFromEditor = false
    /// In-memory live thumbnails for the recording picker; released on leaving it.
    let sourcePreview = SourcePreviewProvider()
    /// The latest recording attempt, from its countdown to how it ended: the
    /// options it records with, its real start, its duration and its outcome.
    @Published private(set) var currentRecording: RecordingAttempt?
    /// The clock countdowns and automatic stops are measured on.
    let recordingClock: RecordingClock
    /// Shows the floating countdown while another app is in front (the
    /// shared coordinator; regression tests substitute their own).
    var countdownPanels: RecordingCountdownPanelCoordinator = .shared

    let captureEngine = CaptureEngine()
    let codexDirector = CodexDirectorService()
    /// A second app-server connection for the AI assistant when its brain is
    /// Codex. It shares the Director's preferences (executable, model, account)
    /// but keeps its own thread so planning and chatting never interleave.
    let codexAssistant = CodexDirectorService()
    /// LLM provider keys and the default text model for every AI feature.
    let aiGateway = AIGatewayStore()
    /// The one assistant conversation for the whole app, created on first use.
    /// Its context follows whatever project is open; see ``AIAssistantContext``.
    private(set) lazy var assistantSession: AIAssistantSession = makeAssistantSession()
    private let assistantAssetsLocator: AssistantAssetsLocator
    private var assistantObservers: Set<AnyCancellable> = []
    private var didCreateAssistantSession = false
    private let store: ProjectStore
    private let interactionTrackingAccess: @MainActor () -> Bool
    private let inputMonitoringAccess: @MainActor () -> Bool
    private let screenCaptureAccess: @MainActor () -> Bool
    /// Finalizes the capture when a recording is stopped. The engine by default;
    /// regression tests substitute a scripted result to drive a stop without
    /// ScreenCaptureKit.
    private let finishCapture: @MainActor (CaptureEngine) async throws -> RecordingResult
    /// Starts the capture when a countdown ends and answers the uptime of its
    /// first frame. The engine by default; regression tests script it (with
    /// `recordingClock`) to run a whole recording without ScreenCaptureKit.
    private let startCapture: CaptureStarter
    /// Stops and deletes a capture that is being cancelled (Cancel, a
    /// discarded start). The engine by default; regression tests count it.
    private let cancelCapture: @MainActor (CaptureEngine) async -> Void
    /// Answers the in-app assistant instead of the brain chosen in Settings;
    /// regression tests script the assistant's turns with it.
    private let scriptedAssistantCompletion: (any TextCompletionProviding)?
    /// The one launch pass; every `bootstrap()` caller awaits it.
    private var bootstrapTask: Task<Void, Never>?
    /// The stop in flight, which a second Finish request joins.
    private var stopRecordingTask: Task<Void, Never>?
    /// Stops the live recording when its duration runs out. Any other end
    /// (Finish, Cancel, a tool's stop, a new recording) cancels it.
    private var automaticStopTask: Task<Void, Never>?
    /// Ends the current attempt when its capture fails on its own.
    private var captureFailureObserver: AnyCancellable?
    private var screenshotNoticeTask: Task<Void, Never>?
    private var recordingCountdownTask: Task<Void, Never>?
    /// Identifies the task stored in `recordingCountdownTask`. This is kept
    /// separate from `recordingAttemptID`, which is intentionally cleared as
    /// soon as capture starts. Without a task token, a cancelled countdown's
    /// deferred cleanup can race a newly-started countdown and clear the new
    /// task reference.
    private var recordingCountdownTaskID: UUID?
    private var recordingAttemptID: UUID?
    private var pendingSourceCropInsets: SourceCropInsets?
    private var codexPlanTask: Task<Void, Never>?
    private var codexFinishRequested = false
    private var projectSaveTask: Task<Void, Never>?
    private lazy var audioAssetCatalog = try? AudioAssetCatalog.loadBundled()

    init(
        store: ProjectStore = ProjectStore(),
        interactionTrackingAccess: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        inputMonitoringAccess: @escaping @MainActor () -> Bool = { CGPreflightListenEventAccess() },
        screenCaptureAccess: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
        finishCapture: @escaping @MainActor (CaptureEngine) async throws -> RecordingResult = { try await $0.stopRecording() },
        startCapture: @escaping CaptureStarter = { engine, target, outputURL, options in
            try await engine.startRecording(target: target, outputURL: outputURL, options: options)
            return engine.recordingStartUptime ?? ProcessInfo.processInfo.systemUptime
        },
        cancelCapture: @escaping @MainActor (CaptureEngine) async -> Void = { await $0.cancelRecording() },
        recordingClock: RecordingClock = .system,
        assistantCompletion: (any TextCompletionProviding)? = nil
    ) {
        self.store = store
        self.startCapture = startCapture
        self.cancelCapture = cancelCapture
        self.recordingClock = recordingClock
        scriptedAssistantCompletion = assistantCompletion
        assistantAssetsLocator = AssistantAssetsLocator(sharedDirectory: AssistantAssetsLocator.sharedDirectory(forLibrary: store.projectsDirectory))
        self.interactionTrackingAccess = interactionTrackingAccess
        self.inputMonitoringAccess = inputMonitoringAccess
        self.screenCaptureAccess = screenCaptureAccess
        self.finishCapture = finishCapture
        refreshInteractionTrackingPermission()
        // A capture can fail by itself (the stream stops, the window closes):
        // its attempt then ends as failed, without waiting for Finish or Cancel,
        // and so does its automatic stop. The engine publishes on the main actor.
        captureFailureObserver = captureEngine.$state.sink { [weak self] state in
            guard case let .failed(message) = state else { return }
            MainActor.assumeIsolated { self?.endRecordingAttempt(nil, .failed(message)) }
        }
    }

    var selectedTarget: CaptureTargetInfo? {
        if let selectedAreaTarget, selectedAreaTarget.id == selectedTargetID {
            return selectedAreaTarget
        }
        return captureEngine.availableTargets.first { $0.id == selectedTargetID }
    }

    var selectedTargetSupportsBrowserContentCrop: Bool {
        defaultBrowserCrop(for: selectedTarget) != nil
    }

    /// Loads the library and runs the launch hooks once. Every caller,
    /// concurrent ones included, waits for that same pass, so nobody sees the
    /// library before it has loaded.
    func bootstrap() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let task = Task { await self.performBootstrap() }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        await reloadProjects()
        // A key in ~/.config/focus-studio/ark.env (the file the Claude Code
        // skills use) is imported silently whenever the Keychain has none, so
        // the assistant works on a fresh Mac without a visit to Settings. The QA
        // hook FOCUS_STUDIO_IMPORT_ARK_ENV=1 forces a re-import; 0 skips it
        // (regression tests, which must not touch the real key or the network).
        let arkImportMode = ProcessInfo.processInfo.environment["FOCUS_STUDIO_IMPORT_ARK_ENV"]
        let arkImport = Task { [weak self] in
            guard arkImportMode != "0" else { return }
            await self?.importArkEnvironmentKeyIfNeeded(force: arkImportMode == "1")
        }
        // QA hook: `open -n "Focus Studio.app" --env FOCUS_STUDIO_START_DESTINATION=recorder`
        // lands on the recording picker so screenshots of live previews can be
        // taken without scripted clicks. Ignored for any other value.
        switch ProcessInfo.processInfo.environment["FOCUS_STUDIO_START_DESTINATION"] {
        case "recorder":
            await showRecorder()
        case "editor":
            // Opens the most recent project so editor screenshots need no clicks.
            if let project = projects.first { open(project) }
        default:
            break
        }
        // A scripted prompt (FOCUS_STUDIO_ASSISTANT_PROMPT) needs the imported
        // model to exist first; otherwise the test finishes in the background
        // and the assistant picks the model up through its availability refresh.
        if ProcessInfo.processInfo.environment["FOCUS_STUDIO_ASSISTANT_PROMPT"] != nil {
            await arkImport.value
        }
    }

    /// ARK_API_KEY from ~/.config/focus-studio/ark.env, the same file the
    /// Claude Code skills read. Never written anywhere by the app.
    nonisolated static func arkEnvironmentKey() -> String? {
        AIGatewayStore.arkEnvironmentKey()
    }

    /// Imports the env file's key when the gateway has no Ark key (or always,
    /// when forced), tests the provider and lets the store pick the
    /// recommended Doubao model if no default text model exists. A stored key
    /// that never passed its test is re-tested so a first launch without
    /// network still ends up with a working default later.
    func importArkEnvironmentKeyIfNeeded(force: Bool = false) async {
        if force || !aiGateway.isConfigured(.volcengineArk) {
            _ = await aiGateway.importArkEnvironmentKey()
        } else if aiGateway.defaultTextModel == nil,
                  aiGateway.configuration(for: .volcengineArk).lastTestSucceeded != true,
                  aiGateway.configuration(for: .volcengineArk).isEnabled {
            await aiGateway.test(.volcengineArk)
        }
        assistantSessionIfLoaded?.refreshModelAvailability()
    }

    /// Nil until something asked for the session; avoids creating it just to refresh it.
    private var assistantSessionIfLoaded: AIAssistantSession? {
        didCreateAssistantSession ? assistantSession : nil
    }

    /// The in-app assistant is partway through a request. Its tools follow
    /// whatever project is open, so automation must not switch the editor
    /// under it.
    var isAssistantRunning: Bool {
        assistantSessionIfLoaded?.isRunning == true
    }

    /// Builds the app-wide assistant: tools read the current project and the
    /// app through `self`, generated media lands in the open project's `ai/`
    /// folder (else the shared AI Assets folder), and the brain is resolved on
    /// every send from Settings.
    private func makeAssistantSession() -> AIAssistantSession {
        didCreateAssistantSession = true
        assistantAssetsLocator.update(sourceVideoPath: activeProject?.sourceVideoPath)
        let locator = assistantAssetsLocator
        let context = makeToolContext(assetsDirectory: { locator.directory }, language: { Self.assistantLanguage() })
        let session = AIAssistantSession(
            context: context,
            completionResolver: { [weak self] in self?.assistantCompletion() }
        )
        // `@Published` emits before the value changes; deliver on the next
        // run-loop pass so the resolver sees the new setting.
        let refresh: () -> Void = { [weak session] in session?.refreshModelAvailability() }
        aiGateway.$defaultTextModel.receive(on: RunLoop.main).sink { _ in refresh() }.store(in: &assistantObservers)
        aiGateway.$assistantBrain.receive(on: RunLoop.main).sink { [weak self] brain in
            self?.resetCodexAssistantIfStuck(brain: brain)
            refresh()
        }.store(in: &assistantObservers)
        codexAssistant.$connectionState.receive(on: RunLoop.main).sink { _ in refresh() }.store(in: &assistantObservers)
        codexDirector.$connectionState.receive(on: RunLoop.main).sink { [weak self] state in
            // A sign-in completed in Settings › Codex: let the assistant retry.
            if state == .ready { self?.resetCodexAssistantIfStuck(brain: self?.aiGateway.assistantBrain ?? .gatewayModel) }
            refresh()
        }.store(in: &assistantObservers)
        return session
    }

    /// A tool context on this model, shared by the in-app assistant and
    /// automation calls: tools read and edit the project open in the editor
    /// through the inspector's path, reach the app through `self` and know
    /// the library root. The assets folder and the language are the caller's:
    /// the assistant follows the open project and the UI language, an
    /// automation call is pinned to its project and English.
    func makeToolContext(
        assetsDirectory: @escaping @Sendable () -> URL,
        language: @escaping @Sendable () -> String
    ) -> AIAssistantContext {
        let arkBase = URL(string: aiGateway.configuration(for: .volcengineArk).effectiveBaseURL)
            ?? URL(string: "https://ark.cn-beijing.volces.com/api/v3")!
        return AIAssistantContext(
            assetsDirectoryProvider: assetsDirectory,
            uiLanguageProvider: language,
            readProject: { [weak self] in self?.activeProject },
            updateProject: { [weak self] mutate in
                guard let self else { throw AIToolError.noProject }
                try self.applyAssistantEdit(mutate)
            },
            // The env file is a fallback so the skills' key works in-app without re-entering it.
            arkAPIKey: { [weak self] in self?.aiGateway.apiKey(for: .volcengineArk) ?? Self.arkEnvironmentKey() },
            arkBaseURL: arkBase,
            projectsDirectory: store.projectsDirectory,
            app: self
        )
    }

    /// The shared AI Assets folder, next to the library: where generated
    /// files go when no project is open.
    var sharedAssetsDirectory: URL { assistantAssetsLocator.sharedDirectory }

    /// The provider for the next assistant message, per the Settings brain.
    func assistantCompletion() -> (any TextCompletionProviding)? {
        if let scriptedAssistantCompletion { return scriptedAssistantCompletion }
        switch aiGateway.assistantBrain {
        case .gatewayModel:
            return aiGateway.defaultTextModel == nil ? nil : AIGatewayTextCompletion(store: aiGateway)
        case .codex:
            return codexAssistant.isAvailableForCompletion ? CodexTextCompletion(service: codexAssistant) : nil
        }
    }

    /// A failed or signed-out assistant connection is dropped so the next send
    /// reconnects with whatever Settings › Codex now provides.
    private func resetCodexAssistantIfStuck(brain: AssistantBrain) {
        guard brain == .codex, !codexAssistant.isAvailableForCompletion,
              codexAssistant.connectionState != .signingIn else { return }
        codexAssistant.disconnect()
    }

    var assistantModelLabel: String {
        switch aiGateway.assistantBrain {
        case .gatewayModel:
            return aiGateway.defaultTextModel?.modelID ?? L10n.tr("No model")
        case .codex:
            let model = codexDirector.preferences.modelID
            return model.isEmpty ? "Codex" : "Codex · \(model)"
        }
    }

    /// The UI language for the assistant, readable off the main actor (same
    /// preference key as `AppLocalization`).
    nonisolated static func assistantLanguage() -> String {
        let saved = UserDefaults.standard.string(forKey: "focusStudio.language") ?? ""
        return (AppLanguage(rawValue: saved) ?? .system).localeIdentifier
    }

    func reloadProjects() async {
        guard !isManagingProjects else { return }
        do {
            let loaded = try await store.loadProjects()
            guard !isManagingProjects else { return }
            projects = loaded
        } catch {
            show(error)
        }
    }

    func showDirector() {
        guard !isManagingProjects else { return }
        destination = .director
    }

    func closeDirector() {
        destination = .library
    }

    /// Creates a plan with live visual context whenever the chat contains a URL.
    /// The temporary image is content-cropped before it is sent to Codex so the
    /// returned normalized coordinates match the renderer and automation runner.
    func createCodexPlan(from prompt: String) async {
        var contextURL: URL?
        if let url = firstWebURL(in: prompt) {
            do {
                let directive = CodexCaptureDirective(
                    mode: .url,
                    url: url.absoluteString,
                    windowTitle: nil,
                    screenshotPath: nil
                )
                let prepared = try await prepareCodexTarget(for: directive)
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("FocusStudio", isDirectory: true)
                    .appendingPathComponent("CodexDirector", isDirectory: true)
                    .appendingPathComponent("VisualContexts", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let fullURL = directory
                    .appendingPathComponent("context-\(UUID().uuidString)")
                    .appendingPathExtension("png")
                try await captureEngine.captureScreenshot(
                    target: prepared.target,
                    to: fullURL
                )
                if let crop = defaultBrowserCrop(for: prepared.target) {
                    let contentURL = directory
                        .appendingPathComponent("content-\(UUID().uuidString)")
                        .appendingPathExtension("png")
                    contextURL = try cropScreenshot(
                        at: fullURL,
                        to: contentURL,
                        insets: crop
                    )
                    try? FileManager.default.removeItem(at: fullURL)
                } else {
                    contextURL = fullURL
                }
            } catch {
                // A visual context is an accuracy enhancement. Codex can still
                // return a reviewable plan if permission or capture is unavailable.
                contextURL = nil
            }
        }
        await codexDirector.sendPrompt(prompt, screenshotURL: contextURL)
    }

    func showRecorder() async {
        guard !isManagingProjects else { return }
        cancelRecordingCountdown()
        destination = .recorder
        busy("Finding screens and windows…")
        defer { isBusy = false }

        do {
            // A window in another Space or a minimized window may still be
            // enumerated by ScreenCaptureKit, but its stream remains suspended
            // and never produces a recordable first frame. Only offer windows
            // that are visible now; the user can restore one and refresh.
            let targets = try await captureEngine.refreshAvailableTargets()
            capturePermissionDenied = false
            captureFailureDetails = nil
            if let area = selectedAreaTarget,
               !targets.contains(where: {
                   $0.kind == .display && $0.nativeID == area.nativeID
               }) {
                selectedAreaTarget = nil
            }
            if selectedTarget == nil {
                let preferredBrowser = targets
                    .filter { target in
                        target.kind == .window
                            && BrowserFamily.detect(applicationName: target.appName) != nil
                    }
                    .max { lhs, rhs in
                        lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
                    }
                selectedTargetID = preferredBrowser?.id
                    ?? targets.first(where: { $0.kind == .window })?.id
                    ?? targets.first?.id
            }
        } catch {
            selectedTargetID = nil
            if let captureError = error as? CaptureEngineError,
               captureError.isScreenRecordingPermissionFailure {
                capturePermissionDenied = true
                captureFailureDetails = captureError.localizedDescription
            } else {
                capturePermissionDenied = false
                captureFailureDetails = nil
                show(error)
            }
        }
    }

    func selectRecordingArea(on display: CaptureTargetInfo) async {
        guard display.kind == .display, !isSelectingArea else { return }
        isSelectingArea = true
        defer { isSelectingArea = false }

        do {
            guard let area = try await AreaSelectionController.shared.selectArea(
                on: display,
                using: captureEngine
            ) else {
                return
            }
            selectedAreaTarget = area
            selectedTargetID = area.id
        } catch {
            show(error)
        }
    }

    func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    var needsInputMonitoring: Bool { !CGPreflightListenEventAccess() }
    var needsAccessibility: Bool { !AXIsProcessTrusted() }

    /// The privacy permissions as the preflight calls report them, which never
    /// prompt (the assistant and external clients ask through `get_status`).
    var permissionStatus: AIPermissionStatus {
        AIPermissionStatus(
            screenRecording: screenCaptureAccess(),
            accessibility: interactionTrackingAccess(),
            inputMonitoring: inputMonitoringAccess()
        )
    }

    /// The projects library root.
    var libraryDirectory: URL { store.projectsDirectory }

    func refreshInteractionTrackingPermission() {
        accessibilityAuthorized = interactionTrackingAccess()
        inputMonitoringAuthorized = inputMonitoringAccess()
        interactionTrackingAuthorized = accessibilityAuthorized && inputMonitoringAuthorized
    }

    /// Acknowledge missing input access before recording a demo that expects
    /// automatic effects. This never requests access or opens System Settings.
    func confirmInteractionTrackingBeforeRecording(allowUnavailable: Bool = false, automaticZooms: Bool? = nil) -> Bool {
        refreshInteractionTrackingPermission()
        let needsConfirmation = (automaticZooms ?? self.automaticZooms) && !interactionTrackingAuthorized && !allowUnavailable
        isShowingInteractionSetup = needsConfirmation
        return !needsConfirmation
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Launches a fresh process for the same app bundle. Screen Recording grants
    /// are evaluated per process, so this is required on macOS when access was
    /// enabled while Focus Studio was already running.
    func relaunchApplication() {
        let applicationURL = Bundle.main.bundleURL
        guard applicationURL.pathExtension == "app" else {
            showMessage("Quit Focus Studio, reopen the built app, then retry Screen Recording access.")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { _, error in
            Task { @MainActor in
                if let error {
                    self.show(error)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// The recorder's own choices, which a recording uses unless a call
    /// overrides them for that recording (``RecordingSettings``).
    var recorderSettings: RecordingSettings {
        RecordingSettings(
            systemAudio: recordSystemAudio,
            microphone: recordMicrophone,
            automaticZooms: automaticZooms,
            browserContentOnly: browserContentOnly,
            frameRate: frameRate
        )
    }

    func startRecordingCountdown(allowUnavailableTracking: Bool = false) {
        guard let target = selectedTarget else {
            showMessage("Choose a display, window, or area to record.")
            return
        }
        beginRecordingCountdown(target: target, settings: recorderSettings, duration: nil, allowUnavailableTracking: allowUnavailableTracking)
    }

    /// Starts the visible 3-second countdown for a new recording attempt of
    /// `target` with `settings` (for this recording only), stopping by itself
    /// `duration` seconds after its capture starts. Returns the attempt's id,
    /// or nil when no countdown started (one is running, a capture is live, or
    /// the person must first confirm recording without input access).
    @discardableResult
    func beginRecordingCountdown(
        target: CaptureTargetInfo,
        settings: RecordingSettings,
        duration: TimeInterval?,
        allowUnavailableTracking: Bool = false
    ) -> UUID? {
        guard recordingCountdownTask == nil, !captureEngine.isRecording, currentRecording?.isLive != true, !isFinishingRecording else { return nil }
        guard confirmInteractionTrackingBeforeRecording(allowUnavailable: allowUnavailableTracking, automaticZooms: settings.automaticZooms) else { return nil }

        cancelAutomaticStop()
        let targetSnapshot = target
        let attempt = RecordingAttempt(target: target, settings: settings, duration: duration)
        let attemptID = attempt.id
        currentRecording = attempt
        recordingAttemptID = attemptID
        recordingCountdownTaskID = attemptID
        destination = .countdown
        recordingCountdown = 3
        // Someone working in another app (a recording an AI tool started),
        // or switching to one during the countdown, still sees the countdown
        // and can cancel it.
        countdownPanels.countdownStarted(model: self)
        let clock = recordingClock
        recordingCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.recordingCountdownTaskID == attemptID {
                    self.recordingCountdownTask = nil
                    self.recordingCountdownTaskID = nil
                }
            }
            do {
                for value in stride(from: 3, through: 1, by: -1) {
                    try Task.checkCancellation()
                    guard self.recordingAttemptID == attemptID else { return }
                    self.recordingCountdown = value
                    try await clock.sleep(1)
                }
                try Task.checkCancellation()
                guard self.recordingAttemptID == attemptID else { return }
                guard let refreshedTarget = self.listedTarget(for: targetSnapshot) else {
                    self.recordingAttemptID = nil
                    self.destination = .recorder
                    self.showMessage("The selected screen or window is no longer available.")
                    self.endRecordingAttempt(attemptID, .failed("The selected screen or window is no longer available."))
                    return
                }
                await self.startRecordingNow(target: refreshedTarget, attemptID: attemptID)
            } catch is CancellationError {
                // Expected when the user cancels the visible countdown.
            } catch {
                self.destination = .recorder
                self.show(error)
                self.endRecordingAttempt(attemptID, .failed(error.localizedDescription))
            }
        }
        return attemptID
    }

    /// `target` as the engine last listed it, checked when a countdown ends.
    /// An empty list (the engine could not list sources, or never has) is
    /// left to the capture start, which reports the real reason.
    private func listedTarget(for target: CaptureTargetInfo) -> CaptureTargetInfo? {
        let listed = captureEngine.availableTargets
        guard !listed.isEmpty else { return target }
        if target.kind == .area {
            let displayStillExists = listed.contains { $0.kind == .display && $0.nativeID == target.nativeID }
            return displayStillExists ? target : nil
        }
        return listed.first { $0.id == target.id }
    }

    func cancelRecordingCountdown() {
        // Cleared once the capture has started: then only Cancel ends it.
        let attemptID = recordingAttemptID
        recordingAttemptID = nil
        recordingCountdownTaskID = nil
        recordingCountdownTask?.cancel()
        recordingCountdownTask = nil
        recordingCountdown = 3
        pendingSourceCropInsets = nil
        destination = .recorder
        if let attemptID { endRecordingAttempt(attemptID, .cancelled) }
    }

    /// Cancels attempt `id` and keeps nothing, as the Cancel buttons do: its
    /// countdown or capture start, or the recording itself. Does nothing once
    /// it has ended or while a stop is saving it.
    func discardRecording(id: UUID) async {
        guard let attempt = currentRecording, attempt.id == id, attempt.outcome == nil, !isFinishingRecording else { return }
        if recordingAttemptID == id {
            cancelRecordingCountdown()
        } else if attempt.startUptime != nil, destination == .recording {
            await cancelRecording()
        }
    }

    /// Records how attempt `id` (nil: the current one) ended, once.
    private func endRecordingAttempt(_ id: UUID?, _ outcome: AIRecordingOutcome) {
        guard var attempt = currentRecording, attempt.outcome == nil, id == nil || attempt.id == id else { return }
        attempt.outcome = outcome
        attempt.endedAt = Date()
        currentRecording = attempt
        cancelAutomaticStop()
    }

    /// The capture of attempt `id` delivered its first frame at `startUptime`:
    /// the recording's real start, which its duration is measured from.
    private func recordingDidStart(_ id: UUID, startUptime: TimeInterval) {
        guard var attempt = currentRecording, attempt.id == id else { return }
        attempt.startUptime = startUptime
        attempt.startedAt = Date().addingTimeInterval(startUptime - recordingClock.now())
        currentRecording = attempt
        scheduleAutomaticStop(for: attempt)
    }

    /// Stops `attempt` through the Finish button's own path (a stop already
    /// under way is joined) once its duration has passed since its first frame.
    private func scheduleAutomaticStop(for attempt: RecordingAttempt) {
        cancelAutomaticStop()
        guard let deadline = attempt.automaticStopUptime else { return }
        let id = attempt.id
        let clock = recordingClock
        automaticStopTask = Task { @MainActor [weak self] in
            do {
                while true {
                    let remaining = deadline - clock.now()
                    guard remaining > 0 else { break }
                    try await clock.sleep(remaining)
                }
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.currentRecording?.id == id, self.currentRecording?.isLive == true else { return }
            self.automaticStopTask = nil
            await self.stopRecording()
        }
    }

    private func cancelAutomaticStop() {
        automaticStopTask?.cancel()
        automaticStopTask = nil
    }

    /// Whether the live recording's duration is set to stop it.
    var hasPendingAutomaticStop: Bool { automaticStopTask != nil }

    private func startRecordingNow(target: CaptureTargetInfo, attemptID: UUID) async {

        do {
            guard recordingAttemptID == attemptID, !Task.isCancelled else { return }
            // Starting a recording must never request optional permissions.
            // EventMonitor reports a non-blocking warning when Input Monitoring
            // is unavailable; users can opt in from that warning if they want
            // click metadata outside Focus Studio.
            let outputURL = try await store.temporaryRecordingURL()
            guard recordingAttemptID == attemptID, !Task.isCancelled else {
                pendingSourceCropInsets = nil
                destination = .recorder
                return
            }
            // This recording's own options; the recorder's choices stay as they are.
            let settings = currentRecording.flatMap { $0.id == attemptID ? $0.settings : nil } ?? recorderSettings
            var options = CaptureOptions()
            options.systemAudio = settings.systemAudio
            options.microphone = settings.microphone
            options.frameRate = settings.frameRate
            pendingSourceCropInsets = settings.browserContentOnly
                ? defaultBrowserCrop(for: target)
                : nil
            let startUptime = try await startCapture(captureEngine, target, outputURL, options)
            guard recordingAttemptID == attemptID, !Task.isCancelled else {
                await cancelCapture(captureEngine)
                pendingSourceCropInsets = nil
                destination = .recorder
                return
            }
            recordingAttemptID = nil
            inputWarning = captureEngine.eventCaptureWarning
            recordingDidStart(attemptID, startUptime: startUptime)
            destination = .recording
            RecordingControlPanelCoordinator.shared.show(model: self)
        } catch {
            if recordingAttemptID != attemptID || Task.isCancelled {
                if captureEngine.isRecording {
                    await captureEngine.cancelRecording()
                }
                pendingSourceCropInsets = nil
                destination = .recorder
                return
            }
            recordingAttemptID = nil
            pendingSourceCropInsets = nil
            if let captureError = error as? CaptureEngineError,
               captureError.isScreenRecordingPermissionFailure {
                selectedTargetID = nil
                capturePermissionDenied = true
                captureFailureDetails = captureError.localizedDescription
                destination = .recorder
            } else {
                destination = .recorder
                show(error)
            }
            endRecordingAttempt(attemptID, .failed(error.localizedDescription))
        }
    }

    func stopRecording() async {
        if isRunningCodexPlan {
            codexFinishRequested = true
            codexPlanTask?.cancel()
            return
        }
        // Any stop request ends the wait for the recording's duration.
        cancelAutomaticStop()
        // The Finish button, the duration and the tools can all ask to stop. A
        // second request waits for the stop in flight instead of finalizing
        // the capture again, and sees the same outcome.
        if let stopRecordingTask {
            await stopRecordingTask.value
            return
        }
        // Only a live recording is finalized. A late request after a stop has
        // finished (the editor or the recorder is showing), or one while a
        // cancel is stopping the engine, must not finalize the capture again.
        guard destination == .recording, captureEngine.state != .stopping else { return }
        let task = Task {
            await self.finishRecording()
            // Cleared in the same main-actor turn that finishes the stop, so a
            // later stop starts fresh and `isFinishingRecording` never lags.
            self.stopRecordingTask = nil
        }
        stopRecordingTask = task
        await task.value
    }

    /// Whether a stop is finalizing the capture or saving its project.
    var isFinishingRecording: Bool { stopRecordingTask != nil }

    private func finishRecording() async {
        busy("Preparing your editable recording…")
        defer {
            isBusy = false
            RecordingControlPanelCoordinator.shared.hide()
        }

        // The recording being stopped, with the options it was made with.
        let attempt = currentRecording.flatMap { $0.isLive ? $0 : nil }
        let recorded = attempt?.settings ?? recorderSettings
        do {
            let result = try await finishCapture(captureEngine)
            var settings = ProjectSettings()
            settings.autoZoomEnabled = recorded.automaticZooms
            settings.frameRate = min(recorded.frameRate, 60)
            settings.sourceCropInsets = pendingSourceCropInsets
            let title = "Recording \(Date().formatted(date: .abbreviated, time: .shortened))"
            let project = try await store.createProject(
                from: result.outputURL,
                title: title,
                cursorSamples: result.cursorSamples,
                clickEvents: result.clickEvents,
                typingActivity: result.typingActivity,
                eventDiagnostics: result.eventDiagnostics,
                settings: settings
            )
            activeProject = project
            projects.removeAll { $0.id == project.id }
            projects.insert(project, at: 0)
            destination = .editor
            if let attempt { endRecordingAttempt(attempt.id, .finished(projectID: project.id)) }
        } catch {
            // CaptureEngine has already torn down a failed finalization. Return
            // to a retryable source picker instead of leaving a dead recording
            // timer and Finish button on screen.
            destination = .recorder
            show(error)
            if let attempt { endRecordingAttempt(attempt.id, .failed(error.localizedDescription)) }
        }
        pendingSourceCropInsets = nil
    }

    func cancelRecording() async {
        if isRunningCodexPlan {
            codexFinishRequested = false
            codexPlanTask?.cancel()
            return
        }
        // A stop is already saving the recording as a project.
        guard !isFinishingRecording else { return }
        cancelAutomaticStop()
        let attemptID = currentRecording.flatMap { $0.isLive ? $0.id : nil }
        await cancelCapture(captureEngine)
        pendingSourceCropInsets = nil
        RecordingControlPanelCoordinator.shared.hide()
        destination = .library
        if let attemptID { endRecordingAttempt(attemptID, .cancelled) }
    }

    func takeScreenshot() async {
        guard !isTakingScreenshot else { return }
        isTakingScreenshot = true
        defer { isTakingScreenshot = false }

        do {
            let picturesDirectory = FileManager.default.urls(
                for: .picturesDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let directory = picturesDirectory.appendingPathComponent(
                "Focus Studio Screenshots",
                isDirectory: true
            )
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
            let filename = "Focus Studio \(formatter.string(from: Date())).png"
            let outputURL = directory.appendingPathComponent(filename)
            try await captureEngine.captureScreenshot(to: outputURL)
            lastScreenshotURL = outputURL
            showScreenshotNotice("Screenshot saved")
        } catch {
            lastScreenshotURL = nil
            showScreenshotNotice(error.localizedDescription)
        }
    }

    func revealLastScreenshot() {
        guard let lastScreenshotURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastScreenshotURL])
    }

    func importVideo() async {
        guard !isManagingProjects else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.tr("Import a recording")
        panel.prompt = L10n.tr("Import")
        panel.allowedContentTypes = [.mpeg4Movie, .movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await importVideo(from: url)
        } catch {
            show(error)
        }
    }

    /// Creates a library project from a movie file and opens it in the
    /// editor; the open panel and automation share it. A nil title is the
    /// file name. Throws why it could not, worded for the person using the app.
    @discardableResult
    func importVideo(from url: URL, title: String? = nil) async throws -> RecordingProject {
        let title = try newProjectTitle(title, default: url.deletingPathExtension().lastPathComponent)
        try prepareForNewProject()
        busy("Importing video…")
        defer { isBusy = false }
        let project = try await store.createProject(
            from: url,
            title: title,
            cursorSamples: [],
            clickEvents: [],
            settings: ProjectSettings()
        )
        present(project)
        return project
    }

    func importScreenshotDemo() async {
        guard !isManagingProjects else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.tr("Create a demo from a screenshot")
        panel.prompt = L10n.tr("Create demo")
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let imageURL = panel.url else { return }
        do {
            try await importScreenshotDemo(from: imageURL)
        } catch {
            show(error)
        }
    }

    /// Turns a PNG or JPEG screenshot into an editable demo project and opens
    /// it in the editor; the open panel and automation share it. A nil title
    /// is "<file name> Demo". Throws why it could not.
    @discardableResult
    func importScreenshotDemo(from imageURL: URL, title: String? = nil) async throws -> RecordingProject {
        let title = try newProjectTitle(title, default: "\(imageURL.deletingPathExtension().lastPathComponent) Demo")
        try prepareForNewProject()
        busy("Turning the screenshot into an editable demo…")
        defer { isBusy = false }
        return try await createScreenshotDemo(from: imageURL, title: title)
    }

    /// A caller's title, checked like a rename; nil takes `defaultTitle`
    /// (a file name, used as it is).
    private func newProjectTitle(_ title: String?, default defaultTitle: String) throws -> String {
        guard let title else { return defaultTitle }
        do {
            return try ProjectStore.validatedProjectName(title)
        } catch {
            throw AILocalizedFailure(error.localizedDescription)
        }
    }

    /// Refuses a new project while a recording, a library operation or
    /// another task is under way, then saves and closes the editor so the new
    /// project can open.
    private func prepareForNewProject() throws {
        if let blocker = automationBlocker { throw blocker.failure }
        if destination == .editor { closeEditor() }
    }

    /// Runs a validated, user-approved Director plan. The runner can only open
    /// web URLs, wait, click inside the selected window, and scroll. It cannot
    /// type, submit forms, invoke a shell, or perform filesystem mutations.
    func startCodexPlan(_ plan: CodexRecordingPlan) {
        guard codexPlanTask == nil, !isManagingProjects else { return }
        codexFinishRequested = false
        codexPlanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runCodexPlan(plan)
            self.codexPlanTask = nil
            self.codexFinishRequested = false
        }
    }

    private func runCodexPlan(_ plan: CodexRecordingPlan) async {
        guard !isRunningCodexPlan else { return }
        let issues = plan.validationIssues
        guard issues.isEmpty else {
            showMessage(issues.joined(separator: " "))
            return
        }

        isRunningCodexPlan = true
        defer {
            isRunningCodexPlan = false
            isBusy = false
            pendingSourceCropInsets = nil
        }

        do {
            if plan.capture.mode == .screenshot {
                let imageURL = try screenshotURL(for: plan.capture)
                let cues = plannedScreenshotClicks(from: plan.actions)
                busy("Turning the screenshot into a Codex-directed demo…")
                try await createScreenshotDemo(
                    from: imageURL,
                    title: plan.title,
                    clickEvents: cues.events,
                    duration: cues.duration
                )
                return
            }

            busy("Opening and verifying the recording window…")
            let prepared = try await prepareCodexTarget(for: plan.capture)
            let target = prepared.target
            let cropInsets = browserContentOnly
                ? defaultBrowserCrop(for: target)
                : nil
            pendingSourceCropInsets = cropInsets
            selectedTargetID = target.id

            var options = CaptureOptions()
            options.systemAudio = false
            options.microphone = false
            options.frameRate = min(max(frameRate, 30), 60)
            let outputURL = try await store.temporaryRecordingURL()
            try await captureEngine.startRecording(
                target: target,
                outputURL: outputURL,
                options: options
            )
            inputWarning = captureEngine.eventCaptureWarning
            destination = .recording
            RecordingControlPanelCoordinator.shared.show(model: self)
            isBusy = false

            let fallbackStart = ProcessInfo.processInfo.systemUptime
            var plannedClicks: [ClickEvent] = []
            do {
                try await Task.sleep(for: .milliseconds(700))
                try await CodexPlanRunner.run(
                    actions: plan.actions,
                    in: target,
                    cropInsets: cropInsets,
                    browserApplicationURL: prepared.browserApplicationURL
                ) { [weak self] x, y in
                    guard let self else { return }
                    let zero = self.captureEngine.recordingStartUptime ?? fallbackStart
                    plannedClicks.append(
                        ClickEvent(
                            time: max(0, ProcessInfo.processInfo.systemUptime - zero),
                            x: x,
                            y: y,
                            button: .left
                        )
                    )
                }
                try await Task.sleep(for: .milliseconds(900))
            } catch let cancellation as CancellationError {
                guard codexFinishRequested else { throw cancellation }
            }

            busy("Preparing the Codex-directed edit…")
            let result = try await captureEngine.stopRecording()
            RecordingControlPanelCoordinator.shared.hide()

            var settings = ProjectSettings()
            settings.autoZoomEnabled = false
            settings.frameRate = min(max(frameRate, 30), 60)
            settings.sourceCropInsets = cropInsets
            settings.screenAnimation = .smooth
            let clicks = plannedClicks.isEmpty ? result.clickEvents : plannedClicks
            var project = try await store.createProject(
                from: result.outputURL,
                title: plan.title,
                cursorSamples: result.cursorSamples,
                clickEvents: clicks,
                typingActivity: result.typingActivity,
                eventDiagnostics: result.eventDiagnostics,
                settings: settings
            )
            project.zoomSegments = manualZooms(
                for: clicks,
                duration: project.duration,
                cropInsets: cropInsets
            )
            try await store.save(project)
            present(project)
        } catch {
            if captureEngine.isRecording {
                await captureEngine.cancelRecording()
            }
            RecordingControlPanelCoordinator.shared.hide()
            destination = .director
            show(error)
        }
    }

    func importBackgroundMusic(for project: RecordingProject) async -> String? {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("Choose background music")
        panel.prompt = L10n.tr("Use track")
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            return try await store.importBackgroundMusic(from: url, for: project)
        } catch {
            show(error)
            return nil
        }
    }

    func importBackgroundImage(for project: RecordingProject) async -> String? {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("Choose a background image")
        panel.prompt = L10n.tr("Use background")
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            return try await store.importBackgroundImage(from: url, for: project)
        } catch {
            show(error)
            return nil
        }
    }

    var bundledMusicAssets: [AudioAssetCatalog.Asset] {
        audioAssetCatalog?.music ?? []
    }

    var bundledSoundEffectAssets: [AudioAssetCatalog.Asset] {
        audioAssetCatalog?.soundEffects ?? []
    }

    func bundledAudioPath(for asset: AudioAssetCatalog.Asset) -> String? {
        guard let audioAssetCatalog,
              audioAssetCatalog.assets.contains(asset)
        else { return nil }
        let url = audioAssetCatalog.fileURL(for: asset)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    @discardableResult
    private func createScreenshotDemo(
        from imageURL: URL,
        title: String,
        clickEvents: [ClickEvent] = [],
        duration: Double = 12
    ) async throws -> RecordingProject {
        let safeDuration = duration.clamped(to: 6...30)
        let outputURL = try await store.temporaryRecordingURL()
        _ = try await StillImageVideoBuilder.build(
            from: imageURL,
            to: outputURL,
            duration: safeDuration,
            // A still source only needs a low encoded cadence; the project
            // renderer produces the final 30 fps camera animation on export.
            frameRate: 6,
            scalingMode: .aspectFit
        )
        var settings = ProjectSettings()
        settings.autoZoomEnabled = false
        settings.frameRate = 30
        settings.screenAnimation = .smooth
        var project = try await store.createProject(
            from: outputURL,
            title: title,
            cursorSamples: [],
            clickEvents: clickEvents,
            settings: settings
        )
        project.zoomSegments = manualZooms(
            for: clickEvents,
            duration: project.duration,
            cropInsets: nil
        )
        try await store.save(project)
        present(project)
        return project
    }

    private func screenshotURL(for capture: CodexCaptureDirective) throws -> URL {
        if let path = capture.screenshotPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            let allowed = ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased())
            guard allowed, FileManager.default.fileExists(atPath: url.path) else {
                throw DirectorRunError.invalidScreenshot(url)
            }
            return url
        }

        let panel = NSOpenPanel()
        panel.title = L10n.tr("Choose the screenshot for this Codex plan")
        panel.prompt = L10n.tr("Use screenshot")
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            throw DirectorRunError.screenshotSelectionCancelled
        }
        return url
    }

    private func firstWebURL(in prompt: String) -> URL? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }
        let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        return detector.matches(in: prompt, options: [], range: range)
            .compactMap(\.url)
            .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    private func cropScreenshot(
        at sourceURL: URL,
        to outputURL: URL,
        insets: SourceCropInsets
    ) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw DirectorRunError.invalidScreenshot(sourceURL) }
        let crop = insets.sanitized
        let width = Double(image.width)
        let height = Double(image.height)
        let rect = CGRect(
            x: width * crop.leading,
            y: height * crop.top,
            width: width * (1 - crop.leading - crop.trailing),
            height: height * (1 - crop.top - crop.bottom)
        ).integral
        guard let cropped = image.cropping(to: rect)
        else { throw DirectorRunError.invalidScreenshot(sourceURL) }

        let maximumContextDimension = 1_600.0
        let longestEdge = Double(max(cropped.width, cropped.height))
        let scale = min(1, maximumContextDimension / longestEdge)
        let outputImage: CGImage
        if scale < 1 {
            let source = CIImage(cgImage: cropped)
            let scaled = source.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale)
            )
            guard let rendered = CIContext().createCGImage(scaled, from: scaled.extent)
            else { throw DirectorRunError.invalidScreenshot(sourceURL) }
            outputImage = rendered
        } else {
            outputImage = cropped
        }

        guard
              let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              )
        else { throw DirectorRunError.invalidScreenshot(sourceURL) }
        CGImageDestinationAddImage(destination, outputImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DirectorRunError.invalidScreenshot(sourceURL)
        }
        return outputURL
    }

    private func plannedScreenshotClicks(
        from actions: [CodexRecordingAction]
    ) -> (events: [ClickEvent], duration: Double) {
        var time = 1.0
        var events: [ClickEvent] = []
        for action in actions {
            switch action.type {
            case .wait:
                time += (action.seconds ?? 0).clamped(to: 0...30)
            case .click:
                if let x = action.x, let y = action.y {
                    events.append(
                        ClickEvent(
                            time: time,
                            x: x.clamped(to: 0...1),
                            y: y.clamped(to: 0...1),
                            button: .left
                        )
                    )
                }
                time += 1.6
            case .scroll:
                // On a still image, scrolling becomes time for a gentle pan.
                time += 0.8
            case .navigate:
                // Screenshot plans never operate the live desktop.
                break
            }
        }
        return (events, (time + 2).clamped(to: 8...30))
    }

    private struct PreparedCodexTarget {
        var target: CaptureTargetInfo
        var browserApplicationURL: URL?
    }

    private func prepareCodexTarget(
        for capture: CodexCaptureDirective
    ) async throws -> PreparedCodexTarget {
        switch capture.mode {
        case .url:
            guard let value = capture.url,
                  let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { throw DirectorRunError.invalidURL }
            guard let chromeURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.google.Chrome"
            ) else { throw DirectorRunError.chromeNotFound }

            try await CodexPlanRunner.open(url, with: chromeURL)
            try await Task.sleep(for: .seconds(2.4))
            let targets = try await captureEngine.refreshAvailableTargets(
                onScreenWindowsOnly: false
            )
            guard let target = preferredChromeTarget(for: url, in: targets) else {
                throw DirectorRunError.targetNotFound("Google Chrome")
            }
            activateApplication(named: target.appName)
            return PreparedCodexTarget(
                target: target,
                browserApplicationURL: chromeURL
            )

        case .window:
            let requested = capture.windowTitle?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !requested.isEmpty else { throw DirectorRunError.missingWindowTitle }
            let targets = try await captureEngine.refreshAvailableTargets(
                onScreenWindowsOnly: false
            )
            guard let target = preferredWindowTarget(named: requested, in: targets) else {
                throw DirectorRunError.targetNotFound(requested)
            }
            activateApplication(named: target.appName)
            let browserURL = isChrome(target)
                ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
                : nil
            return PreparedCodexTarget(
                target: target,
                browserApplicationURL: browserURL
            )

        case .screenshot:
            throw DirectorRunError.invalidCaptureMode
        }
    }

    private func preferredChromeTarget(
        for url: URL,
        in targets: [CaptureTargetInfo]
    ) -> CaptureTargetInfo? {
        let windows = targets.filter(isChrome)
        guard !windows.isEmpty else { return nil }
        let hostTokens = (url.host(percentEncoded: false) ?? "")
            .lowercased()
            .split(whereSeparator: { $0 == "." || $0 == "-" })
            .map(String.init)
            .filter { $0.count >= 3 && $0 != "www" && $0 != "com" }
        let order = visibleWindowOrder()

        return windows.max { lhs, rhs in
            targetScore(lhs, tokens: hostTokens, order: order)
                < targetScore(rhs, tokens: hostTokens, order: order)
        }
    }

    private func preferredWindowTarget(
        named requested: String,
        in targets: [CaptureTargetInfo]
    ) -> CaptureTargetInfo? {
        let query = requested.lowercased()
        let tokens = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
        let order = visibleWindowOrder()
        let candidates = targets.filter { target in
            guard target.kind == .window else { return false }
            let title = target.title.lowercased()
            let app = target.appName?.lowercased() ?? ""
            return title.contains(query)
                || app.contains(query)
                || tokens.contains(where: { title.contains($0) || app.contains($0) })
        }
        return candidates.max { lhs, rhs in
            targetScore(lhs, tokens: tokens, order: order)
                < targetScore(rhs, tokens: tokens, order: order)
        }
    }

    private func targetScore(
        _ target: CaptureTargetInfo,
        tokens: [String],
        order: [UInt32: Int]
    ) -> Double {
        let haystack = "\(target.appName ?? "") \(target.title)".lowercased()
        let tokenScore = Double(tokens.filter(haystack.contains).count) * 10_000
        let frontScore = Double(max(0, 5_000 - (order[target.nativeID] ?? 5_000)))
        let areaScore = min(target.frame.width * target.frame.height, 10_000_000) / 10_000
        return tokenScore + frontScore + areaScore
    }

    private func visibleWindowOrder() -> [UInt32: Int] {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: entries.enumerated().compactMap { index, entry in
                guard let id = (entry[kCGWindowNumber] as? NSNumber)?.uint32Value else {
                    return nil
                }
                return (id, index)
            }
        )
    }

    private func isChrome(_ target: CaptureTargetInfo) -> Bool {
        target.kind == .window
            && (target.appName?.lowercased().contains("chrome") == true)
    }

    private func activateApplication(named appName: String?) {
        guard let appName else { return }
        NSWorkspace.shared.runningApplications
            .first { $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame }?
            .activate(options: [])
    }

    private func manualZooms(
        for clicks: [ClickEvent],
        duration: Double,
        cropInsets: SourceCropInsets?
    ) -> [ZoomSegment] {
        let duration = max(0, duration)
        let clickZooms = clicks.compactMap { click -> ZoomSegment? in
            let start = max(0, click.time - 0.16)
            let end = min(duration, click.time + 1.75)
            guard end > start + 0.05 else { return nil }
            return ZoomSegment(
                start: start,
                end: end,
                targetX: click.x,
                targetY: click.y,
                scale: 1.55,
                kind: .manual
            )
        }
        if !clickZooms.isEmpty { return clickZooms }

        let crop = cropInsets ?? SourceCropInsets()
        let first = crop.sourcePoint(x: 0.36, y: 0.38)
        let second = crop.sourcePoint(x: 0.68, y: 0.58)
        let firstStart = min(1.0, duration * 0.10)
        let firstEnd = min(duration, max(firstStart + 0.5, duration * 0.42))
        let secondStart = min(duration, max(firstEnd + 0.45, duration * 0.52))
        let secondEnd = min(duration, max(secondStart + 0.5, duration - 0.65))
        return [
            ZoomSegment(
                start: firstStart,
                end: firstEnd,
                targetX: first.x,
                targetY: first.y,
                scale: 1.34,
                kind: .manual
            ),
            ZoomSegment(
                start: secondStart,
                end: secondEnd,
                targetX: second.x,
                targetY: second.y,
                scale: 1.42,
                kind: .manual
            )
        ].filter { $0.end > $0.start + 0.05 }
    }

    private func present(_ project: RecordingProject) {
        activeProject = project
        projects.removeAll { $0.id == project.id }
        projects.insert(project, at: 0)
        destination = .editor
    }

    func open(_ project: RecordingProject) {
        guard !isManagingProjects else { return }
        activeProject = project
        destination = .editor
    }

    func editorBinding(for snapshot: RecordingProject) -> Binding<RecordingProject> {
        Binding(
            get: {
                guard let active = self.activeProject,
                      active.id == snapshot.id else { return snapshot }
                return active
            },
            set: { self.updateActiveProject($0) }
        )
    }

    /// Returns false, changing nothing, when the write is dropped.
    @discardableResult
    func updateActiveProject(_ project: RecordingProject) -> Bool {
        // Ignore callbacks from a disappearing editor, including late preview
        // updates and text-field commits after another project has opened.
        guard destination == .editor, activeProject?.id == project.id, !isManagingProjects else { return false }
        activeProject = project
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        }
        let precedingSave = projectSaveTask
        projectSaveTask = Task {
            await precedingSave?.value
            do { try await store.save(project) }
            catch { await MainActor.run { self.show(error) } }
        }
        return true
    }

    func flushProjectEdits() async {
        await projectSaveTask?.value
    }

    /// Renders the editor's project for its Export button. The editor shows
    /// its overlay meanwhile, and automation leaves the editor alone until
    /// the export ends (see ``automationBlocker``).
    @discardableResult
    func exportFromEditor(_ project: RecordingProject, to url: URL) async throws -> VideoExportResult {
        isExportingFromEditor = true
        defer { isExportingFromEditor = false }
        return try await ProjectVideoRenderer.export(project: project, to: url)
    }

    func closeEditor() {
        if let project = activeProject {
            updateActiveProject(project)
        }
        destination = .library
        activeProject = nil
    }

    func delete(_ project: RecordingProject) async {
        _ = await deleteProjects(ids: [project.id])
    }

    @discardableResult
    func renameProject(id: UUID, to proposedTitle: String) async -> Bool {
        do {
            try await renameProjectInLibrary(id: id, to: proposedTitle)
            return true
        } catch {
            showProjectManagementMessage(error.localizedDescription)
            return false
        }
    }

    /// Renames a library project (its metadata title only) from the library
    /// and returns it as saved. Throws why it could not, as an
    /// ``AILocalizedFailure``, and shows nothing: the rename sheet and
    /// automation each report a failure their own way.
    @discardableResult
    func renameProjectInLibrary(id: UUID, to proposedTitle: String) async throws -> RecordingProject {
        if let refusal = projectManagementRefusal() { throw refusal }
        isManagingProjects = true
        defer { isManagingProjects = false }
        guard let initial = projects.first(where: { $0.id == id }) else {
            throw AILocalizedFailure("The project is no longer available. Refresh the library and try again.")
        }
        func failure(_ error: Error) -> AILocalizedFailure {
            AILocalizedFailure("Project “%@” could not be renamed: %@", .verbatim(initial.title), .text(error.localizedDescription))
        }
        let title: String
        do { title = try ProjectStore.validatedProjectName(proposedTitle) } catch { throw failure(error) }
        await flushProjectEdits()
        guard destination == .library else {
            throw AILocalizedFailure("Return to the project library before managing projects.")
        }
        do {
            let renamed = try await store.renameProject(id: id, to: title)
            if let index = projects.firstIndex(where: { $0.id == id }) {
                projects[index] = renamed
            }
            return renamed
        } catch {
            throw failure(error)
        }
    }

    @discardableResult
    func deleteProjects(ids: Set<UUID>) async -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let outcome = await moveProjectsToTrash(ids: ids)
        if let refusal = outcome.refusal {
            showProjectManagementMessage(refusal.localizedDescription)
        } else if !outcome.failures.isEmpty {
            showProjectManagementMessage(L10n.format(
                "Moved %lld of %lld selected projects to Trash. The remaining projects were kept.\n%@",
                outcome.deleted.count, ids.count, outcome.failures.map(\.localizedDescription).joined(separator: "\n")
            ))
        }
        return outcome.deleted
    }

    /// What a Move to Trash did: the projects moved, and why the others stayed.
    struct TrashOutcome {
        var deleted: Set<UUID> = []
        /// Why nothing was attempted (another library operation, not in the library).
        var refusal: AILocalizedFailure?
        /// One reason per project, or group of projects, that stayed.
        var failures: [AILocalizedFailure] = []
    }

    /// Moves library projects' folders to the Trash, never deleting them
    /// permanently, and reports the outcome without showing anything: the
    /// library and automation each report failures their own way.
    func moveProjectsToTrash(ids: Set<UUID>) async -> TrashOutcome {
        guard !ids.isEmpty else { return TrashOutcome() }
        if let refusal = projectManagementRefusal() { return TrashOutcome(refusal: refusal) }
        isManagingProjects = true
        defer { isManagingProjects = false }
        // Resolve exactly the IDs visible in this library. Never infer a target
        // from a stale card's video path or arbitrary filesystem path.
        let targets = projects.filter { ids.contains($0.id) }
        var outcome = TrashOutcome()
        let missingCount = ids.subtracting(Set(targets.map(\.id))).count
        if missingCount > 0 {
            outcome.failures.append(AILocalizedFailure("%lld selected projects are no longer in the library.", .count(missingCount)))
        }
        await flushProjectEdits()
        guard destination == .library else {
            return TrashOutcome(refusal: AILocalizedFailure("Return to the project library before managing projects."))
        }
        for project in targets {
            guard destination == .library else {
                outcome.failures.append(AILocalizedFailure("Return to the project library before managing projects."))
                break
            }
            do {
                try await store.deleteProject(id: project.id)
                outcome.deleted.insert(project.id)
                projects.removeAll { $0.id == project.id }
            } catch {
                outcome.failures.append(AILocalizedFailure("“%@”: %@", .verbatim(project.title), .text(error.localizedDescription)))
            }
        }
        return outcome
    }

    /// Why a library action (rename, delete) cannot start now, or nil.
    private func projectManagementRefusal() -> AILocalizedFailure? {
        if isManagingProjects {
            return AILocalizedFailure("Finish the current library operation before starting another.")
        }
        guard destination == .library, !isBusy, !isRunningCodexPlan, !captureEngine.isRecording else {
            return AILocalizedFailure("Return to the project library before managing projects.")
        }
        return nil
    }

    private func showProjectManagementMessage(_ message: String) {
        // A rejected library action must not clear an unrelated import/render's
        // busy overlay (unlike the terminal-operation error helper below).
        errorMessage = message
        isShowingError = true
    }

    private func busy(_ message: String) {
        busyMessage = message
        isBusy = true
    }

    private func show(_ error: Error) {
        showMessage(error.localizedDescription)
    }

    private func showMessage(_ message: String) {
        errorMessage = message
        isShowingError = true
        isBusy = false
    }

    private func showScreenshotNotice(_ message: String) {
        screenshotNoticeTask?.cancel()
        screenshotNotice = message
        screenshotNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.screenshotNotice = nil
        }
    }

    private func defaultBrowserCrop(for target: CaptureTargetInfo?) -> SourceCropInsets? {
        BrowserContentCrop.insets(
            for: target,
            hidesBookmarksBar: hideBrowserBookmarksBar
        )
    }

}

private enum DirectorRunError: LocalizedError {
    case screenRecordingPermissionRequired
    case invalidURL
    case chromeNotFound
    case missingWindowTitle
    case targetNotFound(String)
    case invalidScreenshot(URL)
    case screenshotSelectionCancelled
    case invalidCaptureMode

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionRequired:
            return "Codex Director needs Screen Recording access before it can select a window. Enable Focus Studio in System Settings, relaunch it, and try again."
        case .invalidURL:
            return "The recording plan does not contain a valid http or https URL."
        case .chromeNotFound:
            return "Google Chrome is not installed, so Focus Studio cannot run this Chrome recording plan."
        case .missingWindowTitle:
            return "The recording plan does not identify a window to record."
        case let .targetNotFound(name):
            return "Focus Studio could not find the recording window “\(name)”. Open it and run the plan again."
        case let .invalidScreenshot(url):
            return "The screenshot at \(url.path) is missing or is not a PNG/JPEG image."
        case .screenshotSelectionCancelled:
            return "No screenshot was selected, so the Director plan was not run."
        case .invalidCaptureMode:
            return "This capture mode cannot be run as a live recording."
        }
    }
}
