import FocusStudioAutomation
import SwiftUI

/// Settings › AI models. Providers on the left; the selected provider's key,
/// model and connection test on the right; the app-wide default on top.
struct AIGatewaySettingsView: View {
    @ObservedObject var store: AIGatewayStore
    @State private var selectedKind: AIProviderKind = .openAI
    @State private var showsNarration = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("AI service", selection: $showsNarration) {
                Text("Text and video").tag(false)
                Text("AI narration").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            .padding(.vertical, 12)
            .accessibilityIdentifier("ai.serviceTab")
            if showsNarration {
                AISpeechSettingsView(store: store)
            } else {
                VStack(spacing: 10) {
                    defaultModelBar
                    assistantBrainBar
                    mediaGenerationBar
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
                Divider()
                HStack(spacing: 0) {
                    providerList.frame(width: 190)
                    Divider()
                    AIProviderDetailView(store: store, kind: selectedKind)
                        .id(selectedKind)
                }
            }
        }
        .frame(width: 700, height: 650)
        .background(StudioTheme.panel)
        .foregroundStyle(StudioTheme.text)
        .onAppear { store.refreshKeyPresence() }
    }

    /// Which brain the conversational assistant uses; the default model keeps
    /// serving the editor's own AI buttons either way.
    private var assistantBrainBar: some View {
        HStack(spacing: 12) {
            Text("Assistant brain")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Picker("Assistant brain", selection: $store.assistantBrain) {
                ForEach(AssistantBrain.allCases) { brain in
                    Text(LocalizedStringKey(brain.title)).tag(brain)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 330)
            .help("Answers the AI Assistant window. Codex uses the sign-in from the Codex tab.")
            .accessibilityIdentifier("ai.assistantBrain")
        }
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

    /// Media generation is a separate service from the assistant's chat model.
    /// Present the Ark key and exact media model IDs together for first-run setup.
    private var mediaGenerationBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .foregroundStyle(StudioTheme.purple)
                Text("AI video and images")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Circle()
                    .fill(Self.color(for: store.status(for: store.preferredVideoProvider.gatewayKind)))
                    .frame(width: 7, height: 7)
                Text(mediaStatusLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText)
                Button("Configure video key") { selectedKind = store.preferredVideoProvider.gatewayKind }
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityIdentifier("ai.configureMediaKey")
            }

            HStack(spacing: 12) {
                Picker("Video provider", selection: $store.preferredVideoProvider) {
                    ForEach(AIVideoProvider.allCases) { provider in
                        Text(verbatim: provider.title).tag(provider)
                    }
                }
                .accessibilityIdentifier("ai.preferredVideoProvider")
                Picker("Video model", selection: $store.preferredVideoModelID) {
                    ForEach(store.videoModelChoices.filter { store.videoModelProvider(for: $0) == store.preferredVideoProvider }, id: \.self) { id in
                        Text(verbatim: mediaModelLabel(id, video: true)).tag(id)
                    }
                }
                .accessibilityIdentifier("ai.preferredVideoModel")
            }
            .font(.system(size: 11))
            .controlSize(.small)

            HStack {
                Picker("Image model · Ark", selection: $store.preferredImageModelID) {
                    ForEach(store.imageModelChoices, id: \.self) { id in
                        Text(verbatim: mediaModelLabel(id, video: false)).tag(id)
                    }
                }
                .accessibilityIdentifier("ai.preferredImageModel")
            }
            .font(.system(size: 11))
            .controlSize(.small)

            Text("Seedance and Seedream use an Ark key. Veo uses a separate Gemini key. Test each provider to see listed models.")
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(StudioTheme.window.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
    }

    private var mediaStatusLabel: LocalizedStringKey {
        switch store.status(for: store.preferredVideoProvider.gatewayKind) {
        case .unconfigured: return "No video key"
        case .needsTest: return "Test connection"
        case .ready: return "Video provider connected"
        }
    }

    private func mediaModelLabel(_ id: String, video: Bool) -> String {
        let name = video ? store.videoModelDisplayName(id) : store.imageModelDisplayName(id)
        let listed = video ? store.isVideoModelListed(id) : store.availableImageModelIDs.contains(id)
        return "\(name) · \(id)" + (listed ? "" : " · \(L10n.tr("Not listed by provider"))")
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
            .background(isSelected ? StudioTheme.controlPressed : Color.clear)
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
        case .needsTest: return StudioTheme.warning
        case .unconfigured: return StudioTheme.secondaryText.opacity(0.5)
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

/// Narration uses its own provider and key, irrespective of the assistant brain.
private struct AISpeechSettingsView: View {
    @ObservedObject var store: AIGatewayStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .foregroundStyle(StudioTheme.purple)
                    Text("AI narration").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Picker("Voice provider", selection: $store.preferredSpeechProvider) {
                        ForEach(SpeechProviderKind.allCases, id: \.self) { provider in
                            Text(verbatim: provider.title).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                    .accessibilityIdentifier("ai.speech.provider")
                }
                AISpeechProviderDetailView(store: store, provider: store.preferredSpeechProvider)
                    .id(store.preferredSpeechProvider)
            }
            .padding(22)
        }
    }
}

private struct AISpeechProviderDetailView: View {
    @ObservedObject var store: AIGatewayStore
    let provider: SpeechProviderKind
    @State private var keyDraft = ""
    @State private var keyMessage: String?
    @State private var showsAdvanced = false

    private var configuration: AISpeechProviderConfiguration { store.speechConfiguration(for: provider) }
    private var hasKey: Bool { store.speechProvidersWithKeys.contains(provider) }
    private var isTesting: Bool { store.testingSpeechProviders.contains(provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                GridRow {
                    fieldLabel("API key")
                    HStack(spacing: 8) {
                        SecureField("Narration API key", text: $keyDraft,
                                    prompt: Text(LocalizedStringKey(hasKey ? "Key saved" : provider == .openAICompatible ? "Optional for a local service" : "Paste API key")))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .onSubmit(saveKey)
                            .accessibilityIdentifier("ai.speech.apiKey")
                        Button("Save", action: saveKey)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if hasKey {
                            Button("Remove") {
                                keyDraft = ""
                                do { try store.setSpeechAPIKey("", for: provider); keyMessage = nil }
                                catch { keyMessage = "Could not remove the saved key." }
                            }
                        }
                    }
                }
                GridRow {
                    fieldLabel("Model")
                    Picker("Narration model", selection: modelBinding) {
                        ForEach(store.speechModelChoices, id: \.self) { model in
                            Text(verbatim: model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("ai.speech.model")
                }
                GridRow {
                    fieldLabel("Voice")
                    Picker("Narration voice", selection: voiceBinding) {
                        ForEach(store.speechVoiceChoices, id: \.self) { voice in
                            Text(verbatim: voice).tag(voice)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("ai.speech.voice")
                }
            }
            .font(.system(size: 13))

            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        fieldLabel("Base URL")
                        TextField("Base URL", text: baseURLBinding,
                                  prompt: Text(verbatim: provider.defaultBaseURL.isEmpty ? "https://voice.example/v1" : provider.defaultBaseURL))
                            .accessibilityIdentifier("ai.speech.baseURL")
                    }
                    GridRow {
                        fieldLabel("Model ID")
                        TextField("Custom model ID", text: modelBinding)
                            .accessibilityIdentifier("ai.speech.customModel")
                    }
                    GridRow {
                        fieldLabel("Voice ID")
                        TextField("Custom voice ID", text: voiceBinding)
                            .accessibilityIdentifier("ai.speech.customVoice")
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .padding(.top, 12)
            }
            .font(.system(size: 13))

            Divider()
            HStack(alignment: .top, spacing: 12) {
                Button("Check connection") { Task { await store.testSpeech(provider) } }
                    .disabled(isTesting || (!hasKey && provider != .openAICompatible))
                    .accessibilityIdentifier("ai.speech.test")
                if isTesting { ProgressView().controlSize(.small) }
                Text(verbatim: L10n.tr(keyMessage ?? statusMessage))
                    .font(.system(size: 12))
                    .foregroundStyle(keyMessage != nil || configuration.lastTestState == .failed
                                     ? StudioTheme.warning : StudioTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            Text("Codex can turn your script into narration and captions. Generation asks for confirmation before using paid credits.")
                .font(.system(size: 12))
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { showsAdvanced = provider == .openAICompatible || !configuration.baseURLOverride.isEmpty }
        .onDisappear { keyDraft = "" }
    }

    private var statusMessage: String {
        if isTesting { return "Checking credentials without generating audio…" }
        return configuration.lastTestSummary ?? "Checks your key without generating audio."
    }
    private func fieldLabel(_ value: LocalizedStringKey) -> some View {
        Text(value).foregroundStyle(StudioTheme.secondaryText).gridColumnAlignment(.trailing)
    }
    private var modelBinding: Binding<String> {
        Binding(get: { configuration.effectiveModelID }, set: { value in
            store.updateSpeechConfiguration(provider) { $0.modelID = value }
        })
    }
    private var voiceBinding: Binding<String> {
        Binding(get: { configuration.effectiveVoiceID }, set: { value in
            store.updateSpeechConfiguration(provider) { $0.voiceID = value }
        })
    }
    private var baseURLBinding: Binding<String> {
        Binding(get: { configuration.baseURLOverride }, set: { value in
            store.updateSpeechConfiguration(provider) { $0.baseURLOverride = value }
        })
    }
    private func saveKey() {
        let value = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        keyDraft = ""
        do { try store.setSpeechAPIKey(value, for: provider); keyMessage = nil }
        catch { keyMessage = "Could not save the key. Please try again." }
    }
}

private struct AIProviderDetailView: View {
    @ObservedObject var store: AIGatewayStore
    let kind: AIProviderKind
    @State private var apiKeyDraft = ""
    @State private var baseURLDraft: String
    @State private var showsAdvanced: Bool
    @State private var keychainMessage: String?
    @State private var arkImportMessage: String?
    @State private var isImportingArkEnvironment = false
    private let hasArkEnvironmentFile = AIGatewayStore.arkEnvironmentFileExists

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
                    label(kind == .volcengineArk ? "Chat model" : kind == .googleGemini ? "Video model" : "Model")
                    if kind == .googleGemini { geminiModelPicker }
                    else { modelPicker }
                }
                GridRow {
                    label("Status")
                    statusRow
                }
                if kind == .volcengineArk, hasArkEnvironmentFile {
                    GridRow {
                        label("ark.env")
                        arkEnvironmentRow
                    }
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
                        label(kind == .volcengineArk ? "Chat model ID" : kind == .googleGemini ? "Video model ID" : "Model ID")
                        TextField("Model ID", text: kind == .googleGemini ? geminiModelIDBinding : modelIDBinding, prompt: Text(verbatim: "model"))
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
                .help("Store the key for this macOS user")
            if hasKey {
                Button("Remove", action: removeKey)
                    .help("Delete the saved key")
            }
        }
    }

    @ViewBuilder private var modelPicker: some View {
        let ids = kind == .volcengineArk
            ? configuration.cachedModelIDs.filter { id in
                let lowered = id.lowercased()
                return !AIProviderKind.nonChatModelMarkers.contains { lowered.contains($0) }
            }
            : configuration.cachedModelIDs
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

    private var geminiModelPicker: some View {
        Picker("Video model", selection: geminiModelIDBinding) {
            ForEach(store.videoModelChoices.filter { store.videoModelProvider(for: $0) == .gemini }, id: \.self) { id in
                Text(verbatim: "\(store.videoModelDisplayName(id)) · \(id)").tag(id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 330, alignment: .leading)
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

    /// Shown only when ~/.config/focus-studio/ark.env exists: one click copies
    /// its ARK_API_KEY into the Keychain and tests the provider.
    private var arkEnvironmentRow: some View {
        HStack(spacing: 8) {
            Button("Import from ark.env") { importArkEnvironment() }
                .disabled(isImportingArkEnvironment || isTesting)
                .help("Copy ARK_API_KEY from ~/.config/focus-studio/ark.env into the Keychain and test it")
                .accessibilityIdentifier("ai.importArkEnv")
            if isImportingArkEnvironment {
                ProgressView().controlSize(.small)
                Text("Importing…")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.secondaryText)
            } else if let arkImportMessage {
                Text(verbatim: arkImportMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
    }

    private func importArkEnvironment() {
        guard !isImportingArkEnvironment else { return }
        isImportingArkEnvironment = true
        apiKeyDraft = ""
        Task {
            let outcome = await store.importArkEnvironmentKey()
            switch outcome {
            case .fileMissing:
                arkImportMessage = L10n.tr("ark.env was not found")
            case .keyMissing:
                arkImportMessage = L10n.tr("No ARK_API_KEY found in ark.env")
            case let .keychainFailed(message):
                arkImportMessage = message
            case let .imported(connected, summary):
                arkImportMessage = connected
                    ? L10n.tr("Key imported from ark.env and tested")
                    : L10n.format("Key imported from ark.env, but the test failed: %@", L10n.tr(summary ?? ""))
            }
            isImportingArkEnvironment = false
        }
    }

    @ViewBuilder private var statusText: some View {
        if let keychainMessage {
            Text(verbatim: keychainMessage).foregroundStyle(StudioTheme.warning)
        } else if isTesting {
            Text("Testing…").foregroundStyle(StudioTheme.secondaryText)
        } else if configuration.lastTestSucceeded == true {
            if let count = configuration.lastTestModelCount {
                Text("Connected · \(count) models").foregroundStyle(Color.aiReady)
            } else {
                Text("Connected").foregroundStyle(Color.aiReady)
            }
        } else if configuration.lastTestSucceeded == false, let summary = configuration.lastTestSummary {
            Text(verbatim: L10n.tr(summary)).foregroundStyle(StudioTheme.warning)
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

    private var geminiModelIDBinding: Binding<String> {
        Binding(
            get: { store.preferredVideoProvider == .gemini
                ? store.preferredVideoModelID : AIGatewayStore.recommendedGeminiVideoModelID },
            set: { store.preferredVideoModelID = $0 }
        )
    }

    private func saveKey() {
        let key = trimmedKeyDraft
        guard !key.isEmpty else { return }
        apiKeyDraft = ""
        do {
            try store.setAPIKey(key, for: kind)
            keychainMessage = nil
            if kind == .volcengineArk || kind == .googleGemini {
                Task { await store.test(kind) }
            }
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
