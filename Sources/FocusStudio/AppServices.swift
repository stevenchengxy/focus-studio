import AppKit
import Combine
import FocusStudioAutomation
import Foundation

/// The app's long-lived objects, created once at launch so the library
/// loads and AI tools can connect even before (or without) a window.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let model: StudioModel
    let accessStore: AutomationAccessStore
    let activity = AutomationActivity()
    let bridge: AutomationBridge
    let access: AutomationAccessController
    let controlServer: ControlServer
    let connector: MCPClientConnector

    private init() {
        // The assistant's conversation and plan draft survive relaunches.
        let model = StudioModel(
            assistantHistoryURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("FocusStudio/Assistant/conversation.json")
        )
        self.model = model
        accessStore = AutomationAccessStore(defaults: .standard)
        bridge = AutomationBridge(model: model)
        bridge.presentWindow = { MainWindowPresenter.shared.present() }
        // Sound the person's recorder settings leave off: asked before each
        // such recording an AI tool starts, never remembered.
        bridge.audioConsent = AutomationAudioConsentController { request in
            await AutomationAudioConsentPanel.ask(request)
        }
        access = AutomationAccessController(store: accessStore) { request in
            await AutomationApprovalPanel.ask(request)
        }
        var location: ControlSocketLocation?
        var problem: String?
        do {
            location = try ControlChannel.socketLocation()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        controlServer = ControlServer(
            location: location,
            unavailableReason: problem,
            bridge: bridge,
            access: access,
            activity: activity,
            readiness: { await model.bootstrap() }
        )
        connector = MCPClientConnector(helperPath: MCPClientConnector.bundledHelperPath(), search: .current())
        // The countdown and the control bar name the AI tool whose
        // start_recording call is starting the recording.
        let activity = activity
        model.automationRequester = {
            activity.running.last(where: { $0.tool == "start_recording" })?.clientName
        }
        // Installing or opening another copy is refused while AI tools work
        // in the app (a call running, or a detached export or other job).
        automationObserver = Self.reportAutomationWork(of: activity, jobs: bridge.jobs, to: model)
        // A person's Finish with no main window open opens one for the editor.
        model.presentMainWindow = { MainWindowPresenter.shared.present(activate: true) }
        model.presentAssistantWindow = {
            guard let app = NSApp, app.activationPolicy() == .regular else { return }
            AssistantWindow.presenter.present(activate: true)
            app.activate(ignoringOtherApps: true)
        }
        // The recording control bar follows the model, window or not.
        RecordingControlPanelCoordinator.shared.follow(model)
    }

    /// Republishes the model when AI work begins or ends.
    private var automationObserver: AnyCancellable?

    /// Makes `model.isInstallationBusy` count the AI calls running in the
    /// app and the detached jobs still running, and republishes the model
    /// whenever either changes: a call begins or ends, a call detaches as a
    /// job, a detached job finishes. The views that pass the busy state to
    /// the installer (Settings › Installation, the outside-Applications
    /// notice) observe only the model, so without this they would keep a
    /// stale value. Returns the subscription to keep.
    static func reportAutomationWork(of activity: AutomationActivity, jobs: AutomationJobs, to model: StudioModel) -> AnyCancellable {
        model.automationIsWorking = { [weak activity, weak jobs] in
            !(activity?.running.isEmpty ?? true) || !(jobs?.runningJobIDs.isEmpty ?? true)
        }
        jobs.onChange = { [weak model] in model?.objectWillChange.send() }
        return activity.objectWillChange.sink { [weak model] _ in model?.objectWillChange.send() }
    }
}

/// Loads the library and starts serving AI tools at launch, window or not,
/// and keeps the app running after its last window closes (it may be
/// serving an AI tool; macOS apps stay open without windows).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let installation = AppInstallationCoordinator.shared
        launchObserver = installation.$launchState.sink { state in
            guard state == .ready else { return }
            let services = AppServices.shared
            Task { await services.model.bootstrap() }
            Task { await NativeCommunityConnectionStore.shared.refresh() }
            services.controlServer.start()
        }
        Task { await installation.prepareForLaunch() }
    }

    private var launchObserver: AnyCancellable?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting while AI calls or detached jobs run: they are cancelled
    /// first (the helpers see their connection close and report the calls
    /// cut short), and the app quits once they have stopped, at most
    /// ``terminationGrace`` later, so a cancelled export removes its partial
    /// files from the client's folder instead of leaving them behind.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Do not leave a half-finished rename transaction or stale lock when
        // Cmd-Q arrives while the installation worker is still active.
        guard !AppInstallationCoordinator.shared.isWorking else { return .terminateCancel }
        let services = AppServices.shared
        // A normal Quit request from an updater must never discard a live
        // recording or interrupt the editor's export. Older releases did not
        // have this guard, so setup also tells users to finish work first.
        if services.model.isCaptureLive || services.model.captureEngine.isRecording
            || services.model.isFinishingRecording || services.model.isExportingFromEditor {
            services.model.errorMessage = L10n.tr("Finish recording or exporting before quitting Focus Studio.")
            services.model.isShowingError = true
            MainWindowPresenter.shared.present(activate: true)
            return .terminateCancel
        }
        let pending = services.controlServer.stop() + services.bridge.jobs.cancelRunning()
        terminationReplyPending = true
        // Main-actor tasks keep running while AppKit waits for the reply.
        Task { @MainActor in
            for task in pending { await task.value }
            await services.model.flushProjectEdits()
            self.replyToTermination(sender)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.terminationGrace))
            // The grace limit bounds cancelled AI work, not project saving.
            await services.model.flushProjectEdits()
            self.replyToTermination(sender)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Helpers see the connection close and report the calls it cut short.
        AppServices.shared.controlServer.stop()
    }

    /// A cancelled export stops well within this (AutomationAPITests).
    private static let terminationGrace: TimeInterval = 5
    private var terminationReplyPending = false

    private func replyToTermination(_ sender: NSApplication) {
        guard terminationReplyPending else { return }
        terminationReplyPending = false
        sender.reply(toApplicationShouldTerminate: true)
    }
}
