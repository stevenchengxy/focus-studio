import SwiftUI

/// Identity and sizing of the assistant window scene.
enum AssistantWindow {
    static let id = "assistant"
    @MainActor static let presenter = MainWindowPresenter()
    static let minimumSize = CGSize(width: 720, height: 660)
    static let defaultSize = CGSize(width: 980, height: 800)
}

/// A draft handoff from an editor selection to the app-wide assistant. It
/// only fills the composer; it never sends a message or starts generation.
@MainActor
final class AssistantDraftRouter: ObservableObject {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    static let shared = AssistantDraftRouter()
    @Published private(set) var request: Request?

    func queue(_ text: String) { request = Request(text: text) }

    func consume(_ id: UUID) {
        if request?.id == id { request = nil }
    }
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
