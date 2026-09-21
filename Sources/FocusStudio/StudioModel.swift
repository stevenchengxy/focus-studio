import AppKit
import ApplicationServices
import AVFoundation
import CoreImage
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
    @Published var activeProject: RecordingProject?
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
    /// In-memory live thumbnails for the recording picker; released on leaving it.
    let sourcePreview = SourcePreviewProvider()

    let captureEngine = CaptureEngine()
    let codexDirector = CodexDirectorService()
    /// LLM provider keys and the default text model for every AI feature.
    let aiGateway = AIGatewayStore()
    private let store: ProjectStore
    private let interactionTrackingAccess: @MainActor () -> Bool
    private let inputMonitoringAccess: @MainActor () -> Bool
    private var didBootstrap = false
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
        inputMonitoringAccess: @escaping @MainActor () -> Bool = { CGPreflightListenEventAccess() }
    ) {
        self.store = store
        self.interactionTrackingAccess = interactionTrackingAccess
        self.inputMonitoringAccess = inputMonitoringAccess
        refreshInteractionTrackingPermission()
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

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await reloadProjects()
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
        if ProcessInfo.processInfo.environment["FOCUS_STUDIO_OPEN_SETTINGS"] == "1" {
            // Same action the app menu's Settings… item sends.
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
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

    func refreshInteractionTrackingPermission() {
        accessibilityAuthorized = interactionTrackingAccess()
        inputMonitoringAuthorized = inputMonitoringAccess()
        interactionTrackingAuthorized = accessibilityAuthorized && inputMonitoringAuthorized
    }

    /// Acknowledge missing input access before recording a demo that expects
    /// automatic effects. This never requests access or opens System Settings.
    func confirmInteractionTrackingBeforeRecording(allowUnavailable: Bool = false) -> Bool {
        refreshInteractionTrackingPermission()
        let needsConfirmation = automaticZooms && !interactionTrackingAuthorized && !allowUnavailable
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

    func startRecordingCountdown(allowUnavailableTracking: Bool = false) {
        guard let target = selectedTarget else {
            showMessage("Choose a display, window, or area to record.")
            return
        }
        guard recordingCountdownTask == nil, !captureEngine.isRecording else { return }
        guard confirmInteractionTrackingBeforeRecording(allowUnavailable: allowUnavailableTracking) else { return }

        let targetSnapshot = target
        let attemptID = UUID()
        recordingAttemptID = attemptID
        recordingCountdownTaskID = attemptID
        destination = .countdown
        recordingCountdown = 3
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
                    try await Task.sleep(for: .seconds(1))
                }
                try Task.checkCancellation()
                guard self.recordingAttemptID == attemptID else { return }
                let refreshedTarget: CaptureTargetInfo?
                if targetSnapshot.kind == .area {
                    let displayStillExists = self.captureEngine.availableTargets.contains {
                        $0.kind == .display && $0.nativeID == targetSnapshot.nativeID
                    }
                    refreshedTarget = displayStillExists ? targetSnapshot : nil
                } else {
                    refreshedTarget = self.captureEngine.availableTargets.first(
                        where: { $0.id == targetSnapshot.id }
                    )
                }
                guard let refreshedTarget else {
                    self.recordingAttemptID = nil
                    self.destination = .recorder
                    self.showMessage("The selected screen or window is no longer available.")
                    return
                }
                await self.startRecordingNow(target: refreshedTarget, attemptID: attemptID)
            } catch is CancellationError {
                // Expected when the user cancels the visible countdown.
            } catch {
                self.destination = .recorder
                self.show(error)
            }
        }
    }

    func cancelRecordingCountdown() {
        recordingAttemptID = nil
        recordingCountdownTaskID = nil
        recordingCountdownTask?.cancel()
        recordingCountdownTask = nil
        recordingCountdown = 3
        pendingSourceCropInsets = nil
        destination = .recorder
    }

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
            var options = CaptureOptions()
            options.systemAudio = recordSystemAudio
            options.microphone = recordMicrophone
            options.frameRate = frameRate
            pendingSourceCropInsets = browserContentOnly
                ? defaultBrowserCrop(for: target)
                : nil
            try await captureEngine.startRecording(
                target: target,
                outputURL: outputURL,
                options: options
            )
            guard recordingAttemptID == attemptID, !Task.isCancelled else {
                await captureEngine.cancelRecording()
                pendingSourceCropInsets = nil
                destination = .recorder
                return
            }
            recordingAttemptID = nil
            inputWarning = captureEngine.eventCaptureWarning
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
        }
    }

    func stopRecording() async {
        if isRunningCodexPlan {
            codexFinishRequested = true
            codexPlanTask?.cancel()
            return
        }
        busy("Preparing your editable recording…")
        defer {
            isBusy = false
            RecordingControlPanelCoordinator.shared.hide()
        }

        do {
            let result = try await captureEngine.stopRecording()
            var settings = ProjectSettings()
            settings.autoZoomEnabled = automaticZooms
            settings.frameRate = min(frameRate, 60)
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
        } catch {
            // CaptureEngine has already torn down a failed finalization. Return
            // to a retryable source picker instead of leaving a dead recording
            // timer and Finish button on screen.
            destination = .recorder
            show(error)
        }
        pendingSourceCropInsets = nil
    }

    func cancelRecording() async {
        if isRunningCodexPlan {
            codexFinishRequested = false
            codexPlanTask?.cancel()
            return
        }
        await captureEngine.cancelRecording()
        pendingSourceCropInsets = nil
        RecordingControlPanelCoordinator.shared.hide()
        destination = .library
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

        busy("Importing video…")
        defer { isBusy = false }
        do {
            let settings = ProjectSettings()
            let project = try await store.createProject(
                from: url,
                title: url.deletingPathExtension().lastPathComponent,
                cursorSamples: [],
                clickEvents: [],
                settings: settings
            )
            activeProject = project
            projects.insert(project, at: 0)
            destination = .editor
        } catch {
            show(error)
        }
    }

    func importScreenshotDemo() async {
        guard !isManagingProjects else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.tr("Create a demo from a screenshot")
        panel.prompt = L10n.tr("Create demo")
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let imageURL = panel.url else { return }

        busy("Turning the screenshot into an editable demo…")
        defer { isBusy = false }
        do {
            try await createScreenshotDemo(
                from: imageURL,
                title: "\(imageURL.deletingPathExtension().lastPathComponent) Demo"
            )
        } catch {
            show(error)
        }
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

    private func createScreenshotDemo(
        from imageURL: URL,
        title: String,
        clickEvents: [ClickEvent] = [],
        duration: Double = 12
    ) async throws {
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

    func updateActiveProject(_ project: RecordingProject) {
        // Ignore callbacks from a disappearing editor, including late preview
        // updates and text-field commits after another project has opened.
        guard destination == .editor, activeProject?.id == project.id, !isManagingProjects else { return }
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
    }

    func flushProjectEdits() async {
        await projectSaveTask?.value
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
        guard beginManagingProjects() else { return false }
        defer { isManagingProjects = false }
        guard let initial = projects.first(where: { $0.id == id }) else {
            showProjectManagementMessage(L10n.tr("The project is no longer available. Refresh the library and try again."))
            return false
        }
        do {
            let title = try ProjectStore.validatedProjectName(proposedTitle)
            await flushProjectEdits()
            guard destination == .library else {
                showProjectManagementMessage(L10n.tr("Return to the project library before managing projects."))
                return false
            }
            let renamed = try await store.renameProject(id: id, to: title)
            if let index = projects.firstIndex(where: { $0.id == id }) {
                projects[index] = renamed
            }
            return true
        } catch {
            showProjectManagementMessage(L10n.format("Project “%@” could not be renamed: %@", initial.title, L10n.tr(error.localizedDescription)))
            return false
        }
    }

    @discardableResult
    func deleteProjects(ids: Set<UUID>) async -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        guard beginManagingProjects() else { return [] }
        defer { isManagingProjects = false }
        // Resolve exactly the IDs visible in this library. Never infer a target
        // from a stale card's video path or arbitrary filesystem path.
        let targets = projects.filter { ids.contains($0.id) }
        var failures: [String] = []
        let missingCount = ids.subtracting(Set(targets.map(\.id))).count
        if missingCount > 0 {
            failures.append(L10n.format("%lld selected projects are no longer in the library.", missingCount))
        }
        await flushProjectEdits()
        guard destination == .library else {
            showProjectManagementMessage(L10n.tr("Return to the project library before managing projects."))
            return []
        }
        var deleted: Set<UUID> = []
        for project in targets {
            guard destination == .library else {
                failures.append(L10n.tr("Return to the project library before managing projects."))
                break
            }
            do {
                try await store.deleteProject(id: project.id)
                deleted.insert(project.id)
                projects.removeAll { $0.id == project.id }
            } catch {
                failures.append(L10n.format("“%@”: %@", project.title, L10n.tr(error.localizedDescription)))
            }
        }
        if !failures.isEmpty {
            showProjectManagementMessage(L10n.format(
                "Moved %lld of %lld selected projects to Trash. The remaining projects were kept.\n%@",
                deleted.count, ids.count, failures.joined(separator: "\n")
            ))
        }
        return deleted
    }

    private func beginManagingProjects() -> Bool {
        guard !isManagingProjects else {
            showProjectManagementMessage(L10n.tr("Finish the current library operation before starting another."))
            return false
        }
        guard destination == .library, !isBusy, !isRunningCodexPlan, !captureEngine.isRecording else {
            showProjectManagementMessage(L10n.tr("Return to the project library before managing projects."))
            return false
        }
        isManagingProjects = true
        return true
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
