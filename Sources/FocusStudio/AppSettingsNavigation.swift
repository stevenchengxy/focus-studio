import SwiftUI

enum AppSettingsSection: Hashable {
    case account, aiModels, codex, aiTools, installation
}

@MainActor
final class AppSettingsNavigation: ObservableObject {
    static let shared = AppSettingsNavigation()
    @Published var selection: AppSettingsSection = .account
}

/// The home and assistant windows share one visible route to the Settings
/// scene. The scene's standard Command-comma shortcut remains available.
struct StudioSettingsButton: View {
    var section: AppSettingsSection = .account
    let accessibilityIdentifier: String
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            AppSettingsNavigation.shared.selection = section
            openSettings()
        } label: {
            Label("Settings", systemImage: "gearshape")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(AssistantControlButtonStyle())
        .help("Settings")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct StudioSettingsView: View {
    @ObservedObject var model: StudioModel
    @ObservedObject private var navigation = AppSettingsNavigation.shared
    @ObservedObject private var installation = AppInstallationCoordinator.shared
    private let services = AppServices.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                StudioAppearancePicker()
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 270)
                AppLanguageMenu()
                    .foregroundStyle(StudioTheme.secondaryText)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider().overlay(StudioTheme.line)
            TabView(selection: $navigation.selection) {
                AccountSettingsView(store: model.subscription)
                    .disabled(installation.isWorking)
                    .tabItem { Label("Community connection", systemImage: "person.crop.circle") }
                    .tag(AppSettingsSection.account)
                CodexConnectionSettingsView(director: model.codexAssistant,
                                            mirrorPreferencesTo: model.codexDirector,
                                            showsDoneButton: false)
                    .disabled(installation.isWorking)
                    .tabItem { Label("ChatGPT / Codex", systemImage: "sparkles") }
                    .tag(AppSettingsSection.codex)
                AIGatewaySettingsView(store: model.aiGateway)
                    .disabled(installation.isWorking)
                    .tabItem { Label("AI models", systemImage: "slider.horizontal.3") }
                    .tag(AppSettingsSection.aiModels)
                // Claude Code, Codex and other MCP clients (focus-studio-mcp).
                AutomationSettingsView(access: services.accessStore, connector: services.connector, server: services.controlServer)
                    .disabled(installation.isWorking)
                    .tabItem { Label("AI tools", systemImage: "point.3.connected.trianglepath.dotted") }
                    .tag(AppSettingsSection.aiTools)
                InstallationSettingsView(isBusy: model.isInstallationBusy, isBusyNow: { model.isInstallationBusy })
                    .tabItem { Label("Installation", systemImage: "shippingbox") }
                    .tag(AppSettingsSection.installation)
            }
        }
        .background(StudioTheme.panel)
        .foregroundStyle(StudioTheme.text)
        .studioAppearance()
    }
}
