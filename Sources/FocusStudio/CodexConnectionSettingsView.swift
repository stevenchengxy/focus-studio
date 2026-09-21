import AppKit
import SwiftUI

struct CodexConnectionSettingsView: View {
    @ObservedObject var director: CodexDirectorService
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CodexConnectionPreferences
    @State private var apiKey = ""
    @State private var showAPIKey = false
    var showsDoneButton: Bool

    init(director: CodexDirectorService, showsDoneButton: Bool = true) {
        self.director = director
        self.showsDoneButton = showsDoneButton
        _draft = State(initialValue: director.preferences)
    }

    private var hasUnsavedChanges: Bool { draft.normalized != director.preferences }
    private var canAuthenticate: Bool {
        director.isServerConnected && !hasUnsavedChanges && !director.connectionState.isBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex connection").font(.system(size: 20, weight: .semibold))
                    Text("Set up your own account on this Mac.")
                        .font(.system(size: 12)).foregroundStyle(StudioTheme.secondaryText)
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
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        AppLanguagePicker()
                        Text("Changes immediately. Your recording and edits stay open.")
                            .font(.system(size: 11)).foregroundStyle(StudioTheme.secondaryText)
                    }
                    Divider()
                    executableSection
                    accountSection
                    modelSection
                    statusSection
                }
                .padding(22)
            }
            Divider()
            HStack {
                Link("Setup guide", destination: URL(string: "https://learn.chatgpt.com/docs/cli")!)
                    .font(.system(size: 12))
                Spacer()
                if director.isServerConnected {
                    Button("Disconnect") { director.disconnect(); apiKey = "" }
                        .disabled(director.connectionState == .generating)
                }
                Button("Save & test connection") {
                    apiKey = ""
                    director.savePreferences(draft)
                    Task { await director.connect() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(director.connectionState.isBusy)
            }
            .padding(20)
        }
        .frame(width: 620, height: 650)
        .background(StudioTheme.panel)
        .foregroundStyle(StudioTheme.text)
        .environment(\.locale, localization.locale)
        .onAppear { draft = director.preferences }
        .onChange(of: director.preferences) { previous, current in
            // The menu Settings window may be created before a Director sheet
            // saves preferences. Reflect that change without replacing a draft
            // the user is actively editing in this view.
            if draft.normalized == previous { draft = current }
        }
        .onDisappear { apiKey = "" }
    }

    private var executableSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("1. Codex installation").font(.system(size: 13, weight: .semibold))
            Text("Install Codex CLI or the Codex desktop app. Leave the path empty to detect it automatically, or choose your installation.")
                .font(.system(size: 11)).foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Automatic detection", text: $draft.executablePath)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Codex executable path")
                Button("Choose…", action: chooseExecutable)
                Button("Auto") { draft.executablePath = "" }
            }
            .disabled(director.connectionState.isBusy)
            if let path = director.resolvedExecutablePath, !hasUnsavedChanges {
                Text("Detected: \(path)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2. Account").font(.system(size: 13, weight: .semibold))
            Picker("Account", selection: $draft.accountScope) {
                ForEach(CodexConnectionPreferences.AccountScope.allCases, id: \.self) { scope in
                    Text(LocalizedStringKey(scope.title)).tag(scope)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(director.connectionState.isBusy)
            if draft.accountScope == .focusStudio {
                Text("Sign in with ChatGPT or enter an OpenAI API key. Codex saves this separate account in macOS Keychain; your other Codex sessions are not changed.")
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
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
                Text("Reuses the account configured in your local Codex CLI. Manage that account in Codex. No credentials are copied into Focus Studio or installation packages.")
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasUnsavedChanges || !director.isServerConnected {
                Text("Select Save & test connection first to enable sign-in.")
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.yellow)
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("3. Planning model").font(.system(size: 13, weight: .semibold))
            Picker("Model", selection: $draft.modelID) {
                Text("Account default").tag("")
                ForEach(director.availableModels) { model in
                    (Text(verbatim: model.title) + Text(LocalizedStringKey(model.supportsImages ? "" : " · text only"))).tag(model.id)
                }
                if !draft.modelID.isEmpty && !director.availableModels.contains(where: { $0.id == draft.modelID }) {
                    Text("\(draft.modelID) · reconnect to check").tag(draft.modelID)
                }
            }
            .disabled(director.connectionState.isBusy)
            Text("Available models are loaded from your account after sign-in. The connection test does not generate a plan.")
                .font(.system(size: 11)).foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if director.connectionState.isBusy { ProgressView().controlSize(.small) }
                Text(LocalizedStringKey(director.connectionState.title)).font(.system(size: 12, weight: .semibold))
            }
            Text(localizedAccountSummary).font(.system(size: 11)).textSelection(.enabled)
            if let summary = director.connectionTestSummary {
                Group {
                    if summary == "Codex connected. Sign in to finish setup." {
                        Text("Codex connected. Sign in to finish setup.")
                    } else if summary.hasPrefix("Connection verified · ") {
                        Text("Connection verified · \(director.availableModels.count) available models")
                    } else {
                        Text(summary)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(StudioTheme.secondaryText)
            }
            if let error = director.lastErrorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(StudioTheme.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
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
            ? selected.appendingPathComponent("Contents/Resources/codex").path
            : selected.path
    }
}
