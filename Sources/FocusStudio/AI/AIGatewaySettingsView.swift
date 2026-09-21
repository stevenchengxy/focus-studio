import SwiftUI

/// Settings › AI models. Providers on the left; the selected provider's key,
/// model and connection test on the right; the app-wide default on top.
struct AIGatewaySettingsView: View {
    @ObservedObject var store: AIGatewayStore
    @State private var selectedKind: AIProviderKind = .openAI

    var body: some View {
        VStack(spacing: 0) {
            defaultModelBar
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            Divider()
            HStack(spacing: 0) {
                providerList
                    .frame(width: 190)
                Divider()
                AIProviderDetailView(store: store, kind: selectedKind)
                    .id(selectedKind)
            }
        }
        .frame(width: 620, height: 560)
        .background(StudioTheme.panel)
        .foregroundStyle(StudioTheme.text)
        .onAppear { store.refreshKeyPresence() }
    }

    private var defaultModelBar: some View {
        HStack(spacing: 12) {
            Text("Default text model")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Picker("Default text model", selection: $store.defaultTextModel) {
                Text("None").tag(AITextModelSelection?.none)
                ForEach(store.availableDefaultSelections) { selection in
                    Text(verbatim: "\(L10n.tr(selection.provider.title)) · \(selection.modelID)")
                        .tag(Optional(selection))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 330)
            .help("Used by AI features. Test a provider to list it here.")
            .accessibilityIdentifier("ai.defaultModel")
        }
    }

    private var providerList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(AIProviderKind.allCases) { kind in
                    providerRow(kind)
                }
            }
            .padding(10)
        }
        .background(StudioTheme.window)
    }

    private func providerRow(_ kind: AIProviderKind) -> some View {
        let isSelected = selectedKind == kind
        let isEnabled = store.configuration(for: kind).isEnabled
        let status = store.status(for: kind)
        return Button {
            selectedKind = kind
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(Self.color(for: status))
                    .frame(width: 8, height: 8)
                Text(LocalizedStringKey(kind.title))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isEnabled ? StudioTheme.text : StudioTheme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.white.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.help(for: status))
        .accessibilityIdentifier("ai.provider.\(kind.rawValue)")
    }

    static func color(for status: AIProviderStatus) -> Color {
        switch status {
        case .ready: return .aiReady
        case .needsTest: return StudioTheme.yellow
        case .unconfigured: return Color.white.opacity(0.22)
        }
    }

    static func help(for status: AIProviderStatus) -> LocalizedStringKey {
        switch status {
        case .ready: return "Connected"
        case .needsTest: return "Not tested"
        case .unconfigured: return "No API key"
        }
    }
}

private struct AIProviderDetailView: View {
    @ObservedObject var store: AIGatewayStore
    let kind: AIProviderKind
    @State private var apiKeyDraft = ""
    @State private var baseURLDraft: String
    @State private var showsAdvanced: Bool
    @State private var keychainMessage: String?

    init(store: AIGatewayStore, kind: AIProviderKind) {
        self.store = store
        self.kind = kind
        let configuration = store.configuration(for: kind)
        _baseURLDraft = State(initialValue: configuration.effectiveBaseURL)
        _showsAdvanced = State(initialValue: kind == .custom || !configuration.baseURLOverride.isEmpty)
    }

    private var configuration: AIProviderConfiguration { store.configuration(for: kind) }
    private var hasKey: Bool { store.providersWithKeys.contains(kind) }
    private var isTesting: Bool { store.testingProviders.contains(kind) }
    private var trimmedKeyDraft: String { apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(LocalizedStringKey(kind.title))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Toggle("Enabled", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Off hides this provider from AI features")
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    label("API key")
                    keyRow
                }
                GridRow {
                    label("Model")
                    modelPicker
                }
                GridRow {
                    label("Status")
                    statusRow
                }
            }
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        label("Base URL")
                        TextField("Base URL", text: $baseURLDraft,
                                  prompt: Text(verbatim: kind == .custom ? "https://host/v1" : kind.defaultBaseURL))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .font(.system(size: 12, design: .monospaced))
                            .help("OpenAI-compatible endpoint. Empty restores the default.")
                            .onChange(of: baseURLDraft) { _, value in store.setBaseURL(value, for: kind) }
                    }
                    GridRow {
                        label("Model ID")
                        TextField("Model ID", text: modelIDBinding, prompt: Text(verbatim: "model"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .font(.system(size: 12, design: .monospaced))
                            .help("Type an ID when the provider does not list models")
                    }
                }
                .padding(.top, 10)
            }
            .font(.system(size: 12, weight: .medium))
            Spacer()
            HStack {
                if let url = kind.consoleURL {
                    Link("Open console", destination: url)
                        .font(.system(size: 12))
                        .help("Create an API key in the provider console")
                }
                Spacer()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { apiKeyDraft = "" }
    }

    private func label(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(StudioTheme.secondaryText)
            .gridColumnAlignment(.trailing)
    }

    private var keyRow: some View {
        HStack(spacing: 8) {
            SecureField("API key", text: $apiKeyDraft, prompt: Text(LocalizedStringKey(hasKey ? "Key saved" : "Paste API key")))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit(saveKey)
                .accessibilityIdentifier("ai.apiKey")
            Button("Save", action: saveKey)
                .disabled(trimmedKeyDraft.isEmpty)
                .help("Store the key in the macOS Keychain")
            if hasKey {
                Button("Remove", action: removeKey)
                    .help("Delete the saved key")
            }
        }
    }

    @ViewBuilder private var modelPicker: some View {
        let ids = configuration.cachedModelIDs
        let current = configuration.defaultModelID
        if ids.isEmpty && current.isEmpty {
            Text("Not loaded")
                .font(.system(size: 12))
                .foregroundStyle(StudioTheme.secondaryText)
                .help("Test the connection to load models")
        } else {
            Picker("Model", selection: modelIDBinding) {
                if current.isEmpty {
                    Text("Choose…").tag("")
                } else if !ids.contains(current) {
                    Text(verbatim: current).tag(current)
                }
                ForEach(ids, id: \.self) { id in
                    Text(verbatim: id).tag(id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320, alignment: .leading)
            .help("Recommended model picked after the first test")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Button("Test") { Task { await store.test(kind) } }
                .disabled(isTesting || !store.isConfigured(kind))
                .help("List models and verify the key")
                .accessibilityIdentifier("ai.test")
            if isTesting { ProgressView().controlSize(.small) }
            statusText
                .font(.system(size: 12))
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var statusText: some View {
        if let keychainMessage {
            Text(verbatim: keychainMessage).foregroundStyle(StudioTheme.yellow)
        } else if isTesting {
            Text("Testing…").foregroundStyle(StudioTheme.secondaryText)
        } else if configuration.lastTestSucceeded == true {
            if let count = configuration.lastTestModelCount {
                Text("Connected · \(count) models").foregroundStyle(Color.aiReady)
            } else {
                Text("Connected").foregroundStyle(Color.aiReady)
            }
        } else if configuration.lastTestSucceeded == false, let summary = configuration.lastTestSummary {
            Text(verbatim: L10n.tr(summary)).foregroundStyle(StudioTheme.yellow)
        } else if !store.isConfigured(kind) {
            if kind.requiresAPIKey {
                Text("No API key").foregroundStyle(StudioTheme.secondaryText)
            } else {
                Text("No base URL").foregroundStyle(StudioTheme.secondaryText)
            }
        } else {
            Text("Not tested").foregroundStyle(StudioTheme.secondaryText)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.configuration(for: kind).isEnabled },
            set: { value in store.update(kind) { $0.isEnabled = value } }
        )
    }

    private var modelIDBinding: Binding<String> {
        Binding(
            get: { store.configuration(for: kind).defaultModelID },
            set: { store.setDefaultModelID($0, for: kind) }
        )
    }

    private func saveKey() {
        let key = trimmedKeyDraft
        guard !key.isEmpty else { return }
        apiKeyDraft = ""
        do {
            try store.setAPIKey(key, for: kind)
            keychainMessage = nil
        } catch {
            keychainMessage = error.localizedDescription
        }
    }

    private func removeKey() {
        apiKeyDraft = ""
        do {
            try store.setAPIKey("", for: kind)
            keychainMessage = nil
        } catch {
            keychainMessage = error.localizedDescription
        }
    }
}

private extension Color {
    static let aiReady = Color(red: 0.36, green: 0.80, blue: 0.50)
}
