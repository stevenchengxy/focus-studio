import SwiftUI

/// Identity and sizing of the assistant window scene.
enum AssistantWindow {
    static let id = "assistant"
    @MainActor static let presenter = MainWindowPresenter()
    static let minimumSize = CGSize(width: 720, height: 660)
    static let defaultSize = CGSize(width: 980, height: 800)
}

/// Hosts the app-wide assistant. Observing the gateway and the Director keeps
/// the model label current when Settings change the brain or the sign-in.
struct AssistantWindowView: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var gateway: AIGatewayStore
    @ObservedObject var codexDirector: CodexDirectorService
    @ObservedObject private var installation = AppInstallationCoordinator.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        AssistantWorkspaceView(
            model: model,
            onClose: { dismissWindow(id: AssistantWindow.id) },
            openSettings: {
                AppSettingsNavigation.shared.selection = .aiModels
                openSettings()
            }
        )
        .frame(minWidth: AssistantWindow.minimumSize.width, minHeight: AssistantWindow.minimumSize.height)
        .background(StudioTheme.window)
        .preferredColorScheme(.dark)
        .disabled(installation.isWorking)
        .background(HostingWindowReader { AssistantWindow.presenter.register($0) })
        .onAppear {
            AssistantWindow.presenter.openMainWindow = { [openWindow] in openWindow(id: AssistantWindow.id) }
        }
    }
}
