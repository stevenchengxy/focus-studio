import AppKit
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
        let model = StudioModel()
        self.model = model
        accessStore = AutomationAccessStore(defaults: .standard)
        bridge = AutomationBridge(model: model)
        bridge.presentWindow = { MainWindowPresenter.shared.present() }
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
        // The floating countdown names the AI tool whose start_recording call
        // is starting the recording.
        let activity = activity
        RecordingCountdownPanelCoordinator.shared.automationRequester = {
            activity.running.last(where: { $0.tool == "start_recording" })?.clientName
        }
    }
}

/// Loads the library and starts serving AI tools at launch, window or not,
/// and keeps the app running after its last window closes (it may be
/// serving an AI tool; macOS apps stay open without windows).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let services = AppServices.shared
        Task { await services.model.bootstrap() }
        services.controlServer.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting while AI calls or detached jobs run: they are cancelled
    /// first (the helpers see their connection close and report the calls
    /// cut short), and the app quits once they have stopped, at most
    /// ``terminationGrace`` later, so a cancelled export removes its partial
    /// files from the client's folder instead of leaving them behind.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let services = AppServices.shared
        let pending = services.controlServer.stop() + services.bridge.jobs.cancelRunning()
        guard !pending.isEmpty else { return .terminateNow }
        terminationReplyPending = true
        // Main-actor tasks keep running while AppKit waits for the reply.
        Task { @MainActor in
            for task in pending { await task.value }
            self.replyToTermination(sender)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.terminationGrace))
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
