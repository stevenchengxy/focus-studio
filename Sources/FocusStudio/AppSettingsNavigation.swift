import SwiftUI

enum AppSettingsSection: Hashable {
    case aiModels, codex, aiTools, installation
}

@MainActor
final class AppSettingsNavigation: ObservableObject {
    static let shared = AppSettingsNavigation()
    @Published var selection: AppSettingsSection = .aiModels
}

struct StudioSettingsView: View {
    @ObservedObject var model: StudioModel
    @ObservedObject private var navigation = AppSettingsNavigation.shared
    @ObservedObject private var installation = AppInstallationCoordinator.shared
    private let services = AppServices.shared

    var body: some View {
        TabView(selection: $navigation.selection) {
            AIGatewaySettingsView(store: model.aiGateway)
                .disabled(installation.isWorking)
                .tabItem { Label("AI models", systemImage: "sparkles") }
                .tag(AppSettingsSection.aiModels)
            CodexConnectionSettingsView(director: model.codexDirector, showsDoneButton: false)
                .disabled(installation.isWorking)
                .tabItem { Label("Codex", systemImage: "terminal") }
                .tag(AppSettingsSection.codex)
            // Claude Code, Codex and other MCP clients (focus-studio-mcp).
            AutomationSettingsView(access: services.accessStore, connector: services.connector, server: services.controlServer)
                .disabled(installation.isWorking)
                .tabItem { Label("AI tools", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(AppSettingsSection.aiTools)
            InstallationSettingsView(isBusy: model.isInstallationBusy, isBusyNow: { model.isInstallationBusy })
                .tabItem { Label("Installation", systemImage: "shippingbox") }
                .tag(AppSettingsSection.installation)
        }
        .preferredColorScheme(.dark)
    }
}
