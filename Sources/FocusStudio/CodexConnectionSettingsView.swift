import AppKit
import FocusStudioAutomation
import SwiftUI

struct CodexConnectionSettingsView: View {
    @ObservedObject var director: CodexDirectorService
    /// The older recording-plan service uses the same non-secret preferences,
    /// while the visible status and sign-in belong to the assistant service.
    var mirrorPreferencesTo: CodexDirectorService?
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CodexConnectionPreferences
    @State private var apiKey = ""
    @State private var showAPIKey = false
    @State private var installations: [CodexInstallation] = []
    @State private var isDetectingInstallations = false
    @State private var detectionTask: Task<Void, Never>?
    @State private var showsInstallations = false
    @State private var showsAdvanced = false
    var showsDoneButton: Bool

    init(director: CodexDirectorService, mirrorPreferencesTo: CodexDirectorService? = nil, showsDoneButton: Bool = true) {
        self.director = director
        self.mirrorPreferencesTo = mirrorPreferencesTo
        self.showsDoneButton = showsDoneButton
        _draft = State(initialValue: director.preferences)
    }

    private var hasUnsavedChanges: Bool { draft.normalized != director.preferences }
    private var canAuthenticate: Bool {
        director.isServerConnected && !hasUnsavedChanges && !director.connectionState.isBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex connection").font(.system(size: 20, weight: .semibold))
                    Text("Connect the AI assistant in Focus Studio.")
                        .font(.system(size: 11)).foregroundStyle(StudioTheme.secondaryText)
                }
                Spacer()
                if showsDoneButton {
                    Button("Done") { apiKey = ""; dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusSection
                    executableSection
                    accountSection
                    DisclosureGroup("Advanced options", isExpanded: $showsAdvanced) {
                        VStack(alignment: .leading, spacing: 14) {
                            executablePathSection
                            modelSection
                            AppLanguagePicker()
                        }
                        .padding(.top, 10)
                    }
                    .font(.system(size: 12))
                }
                .padding(22)
            }
            Divider()
            HStack {
                Link("Setup guide", destination: URL(string: "https://learn.chatgpt.com/docs/codex/cli")!)
                    .font(.system(size: 12))
                Spacer()
                if director.isServerConnected {
                    Button("Disconnect") { director.disconnect(); apiKey = "" }
                        .disabled(director.connectionState == .generating)
                }
                Button(LocalizedStringKey(hasUnsavedChanges || !director.isServerConnected ? "Connect & test" : "Test again")) {
                    apiKey = ""
                    director.savePreferences(draft)
                    mirrorPreferencesTo?.savePreferences(draft)
                    Task { await director.connect() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(director.connectionState.isBusy)
            }
            .padding(20)
        }
        .frame(width: 620, height: 610)
        .background(StudioTheme.panel)
        .foregroundStyle(StudioTheme.text)
        .environment(\.locale, localization.locale)
        .onAppear {
            draft = director.preferences
            detectInstallations()
        }
        .onChange(of: director.preferences) { previous, current in
            // The menu Settings window may be created before a Director sheet
            // saves preferences. Reflect that change without replacing a draft
            // the user is actively editing in this view.
            if draft.normalized == previous { draft = current }
        }
        .onDisappear {
            apiKey = ""
            detectionTask?.cancel()
            detectionTask = nil
        }
    }

    private var executableSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                stepNumber(1)
                Text("Find Codex").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Check again", action: detectInstallations)
                    .font(.system(size: 11))
                    .disabled(isDetectingInstallations)
            }
            if isDetectingInstallations {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking installations…")
                }.font(.system(size: 11)).foregroundStyle(StudioTheme.secondaryText)
            } else if let preferred = installations.first {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Codex found").font(.system(size: 12, weight: .medium))
                    Text(verbatim: preferred.versionString)
                        .font(.system(size: 11)).foregroundStyle(StudioTheme.secondaryText)
                    Spacer()
                    if !draft.executablePath.isEmpty { Button("Use automatic") { draft.executablePath = "" }.font(.system(size: 11)) }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(StudioTheme.yellow)
                    Text("Codex was not found on this Mac.").font(.system(size: 11))
                    Spacer()
                    Link("Install Codex", destination: URL(string: "https://learn.chatgpt.com/docs/codex/cli")!)
                        .font(.system(size: 11))
                }
            }
            if installations.count > 1 {
                DisclosureGroup("Other installations", isExpanded: $showsInstallations) {
                    installationsList.padding(.top, 8)
                }.font(.system(size: 11))
            }
        }
    }

    private func stepNumber(_ number: Int) -> some View {
        Text("\(number)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(StudioTheme.purple)
            .frame(width: 20, height: 20)
            .background(StudioTheme.purple.opacity(0.14), in: Circle())
    }

    private var executablePathSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Codex executable path").font(.system(size: 11, weight: .semibold))
            HStack {
                TextField("Automatic detection", text: $draft.executablePath)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Codex executable path")
                Button("Choose…", action: chooseExecutable)
                Button("Auto") { draft.executablePath = "" }
            }
            .disabled(director.connectionState.isBusy)
            if let path = director.resolvedExecutablePath, !hasUnsavedChanges {
                Text(verbatim: path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .textSelection(.enabled)
            }
        }
    }

    /// Every executable found on this Mac with the version it reports, newest
    /// first. Automatic detection launches the recommended one; "Use" pins a
    /// specific installation instead.
    private var installationsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(installations) { installation in
                installationRow(installation)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.window)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func installationRow(_ installation: CodexInstallation) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if installation.versionString.isEmpty {
                        Text("Version unknown").font(.system(size: 11, weight: .medium))
                    } else {
                        Text(verbatim: installation.versionString).font(.system(size: 11, weight: .medium))
                    }
                    if installation.isRecommended {
                        installationTag("Recommended", color: StudioTheme.purple)
                    }
                    if installation.path == director.resolvedExecutablePath {
                        installationTag("Last used", color: StudioTheme.secondaryText)
                    }
                }
                Text(verbatim: installation.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Use") { draft.executablePath = installation.path }
                .disabled(draft.executablePath == installation.path || director.connectionState.isBusy)
        }
    }

    private func installationTag(_ title: LocalizedStringKey, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
    }

    private func detectInstallations() {
        detectionTask?.cancel()
        isDetectingInstallations = true
        detectionTask = Task { @MainActor in
            let found = await CodexExecutableDiscovery.installations()
            guard !Task.isCancelled else { return }
            installations = found
            isDetectingInstallations = false
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                stepNumber(2)
                Text("Choose an account").font(.system(size: 13, weight: .semibold))
            }
            Picker("Account", selection: $draft.accountScope) {
                ForEach(CodexConnectionPreferences.AccountScope.allCases, id: \.self) { scope in
                    Text(LocalizedStringKey(scope.title)).tag(scope)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(director.connectionState.isBusy)
            if draft.accountScope == .focusStudio {
                if director.connectionState == .signingIn, let loginURL = director.loginURL {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser.").font(.system(size: 11))
                        Spacer()
                        Link("Open again", destination: loginURL)
                        Button("Cancel") { Task { await director.cancelSignIn() } }
                    }
                } else {
                    HStack {
                        Button("Sign in with ChatGPT") {
                            Task { await director.signInWithChatGPT() }
                        }
                        .disabled(!canAuthenticate)
                        Button(LocalizedStringKey(showAPIKey ? "Hide API key" : "Use API key")) { showAPIKey.toggle(); apiKey = "" }
                            .font(.system(size: 11))
                            .disabled(!canAuthenticate)
                        if director.canCreatePlan {
                            Spacer()
                            Button("Sign out") { Task { await director.signOut() } }
                                .disabled(!canAuthenticate)
                        }
                    }
                }
                if showAPIKey {
                    HStack {
                        SecureField("OpenAI API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("OpenAI API key")
                        Button("Save key & sign in") {
                            let submittedKey = apiKey
                            apiKey = ""
                            Task { await director.signInWithAPIKey(submittedKey) }
                        }
                        .disabled(!canAuthenticate || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("API usage is billed to your OpenAI API account.")
                        .font(.system(size: 10)).foregroundStyle(StudioTheme.secondaryText)
                }
            } else {
                Text("Uses the account already signed in to Codex on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.secondaryText)
            }
            if draft.accountScope == .focusStudio && (hasUnsavedChanges || !director.isServerConnected) {
                Text("Connect & test first, then sign in.")
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.secondaryText)
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Planning model").font(.system(size: 11, weight: .semibold))
            Picker("Model", selection: $draft.modelID) {
                Text("Account default").tag("")
                ForEach(director.availableModels) { model in
                    if model.supportsImages {
                        Text(verbatim: model.title).tag(model.id)
                    } else {
                        Text(L10n.format("%@ · text only", model.title)).tag(model.id)
                    }
                }
                if !draft.modelID.isEmpty && !director.availableModels.contains(where: { $0.id == draft.modelID }) {
                    Text("\(draft.modelID) · reconnect to check").tag(draft.modelID)
                }
            }
            .disabled(director.connectionState.isBusy)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if director.connectionState.isBusy { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: director.canCreatePlan ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(director.canCreatePlan ? .green : StudioTheme.secondaryText)
                }
                Text(LocalizedStringKey(director.connectionState.title)).font(.system(size: 12, weight: .semibold))
            }
            if director.isServerConnected {
                Text(localizedAccountSummary).font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText).textSelection(.enabled)
            }
            if let error = director.lastErrorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(StudioTheme.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.window)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var localizedAccountSummary: String {
        switch director.accountSummary {
        case "Not connected", "Not signed in", "Configured provider", "OpenAI API key":
            return L10n.tr(director.accountSummary)
        default:
            return director.accountSummary
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("Choose Codex executable or application")
        panel.message = L10n.tr("Select codex, Codex.app, or ChatGPT.app.")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        draft.executablePath = selected.pathExtension == "app"
            ? (CodexExecutableDiscovery.executable(in: selected)?.path ?? selected.path)
            : selected.path
    }
}
