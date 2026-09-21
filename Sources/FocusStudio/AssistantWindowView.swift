import SwiftUI

/// Identity and sizing of the assistant window scene.
enum AssistantWindow {
    static let id = "assistant"
    static let minimumSize = CGSize(width: 420, height: 560)
    static let defaultSize = CGSize(width: 460, height: 720)
}

/// Hosts the app-wide assistant. Observing the gateway and the Director keeps
/// the model label current when Settings change the brain or the sign-in.
struct AssistantWindowView: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var gateway: AIGatewayStore
    @ObservedObject var codexDirector: CodexDirectorService
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        AIAssistantPanel(
            session: model.assistantSession,
            modelLabel: model.assistantModelLabel,
            onClose: { dismissWindow(id: AssistantWindow.id) },
            openSettings: { openSettings() }
        )
        .frame(minWidth: AssistantWindow.minimumSize.width, minHeight: AssistantWindow.minimumSize.height)
        .background(StudioTheme.window)
        .preferredColorScheme(.dark)
    }
}
