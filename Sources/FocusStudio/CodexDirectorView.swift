import FocusStudioAutomation
import SwiftUI

/// Both navigation destinations share one conversation and one task runner.
struct CodexDirectorView: View {
    @ObservedObject var model: StudioModel
    var onClose: () -> Void = {}
    var openSettings: (() -> Void)?
    var body: some View {
        AssistantWorkspaceView(model: model, onClose: onClose, openSettings: openSettings)
    }
}

struct AssistantWorkspaceView: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var session: AIAssistantSession
    @ObservedObject var execution: CodexDirectorService
    @ObservedObject private var coordinator: AssistantDemoController
    var onClose: (() -> Void)?
    var openSettings: (() -> Void)?
    @Environment(\.openSettings) private var openAppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: StudioModel, onClose: (() -> Void)? = nil, openSettings: (() -> Void)? = nil) {
        self.model = model
        self.session = model.assistantSession
        self.execution = model.codexAssistant
        self.coordinator = model.assistantDemo
        self.onClose = onClose
        self.openSettings = openSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = coordinator.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(StudioTheme.warning)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("The assistant could not complete this operation.")
                            .font(.system(size: 12, weight: .medium))
                        DisclosureGroup("Details") { Text(verbatim: error).font(.caption).textSelection(.enabled) }
                            .font(.caption).foregroundStyle(StudioTheme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    Button("Connection settings") { showConnectionSettings() }.buttonStyle(.link)
                    Button { coordinator.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                }.padding(14).background(StudioTheme.yellow.opacity(0.07))
                    .transition(.opacity)
            }
            AIAssistantPanel(session: session, gateway: model.aiGateway, modelLabel: model.assistantModelLabel,
                             onClose: onClose, openSettings: openSettings, showsPlan: false,
                             onSubmit: { text, attachments in await coordinator.send(text, attachments: attachments) },
                             openDemoVideo: coordinator.openVideo,
                             hasEditableProject: model.activeProject != nil,
                             headerAccessory: AnyView(connectionControls))
        }
        .background(StudioTheme.window).foregroundStyle(StudioTheme.text)
        .animation(reduceMotion ? nil : StudioMotion.fade, value: coordinator.error != nil)
    }

    private var connectionControls: some View {
        HStack(spacing: 4) {
            if coordinator.isConnecting {
                ProgressView().controlSize(.mini)
                    .help("Connecting…")
                    .accessibilityLabel("Connecting…")
            } else if coordinator.isConnected {
                Button { showConnectionSettings() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(verbatim: "Codex").foregroundStyle(StudioTheme.secondaryText)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityIdentifier("assistant.connectionStatus")
                }
                .buttonStyle(AssistantControlButtonStyle())
                .disabled(session.isRunning)
                .help("Codex connected · Connection settings")
                .accessibilityLabel("Codex connected · Connection settings")
                .accessibilityIdentifier("assistant.connection")
            } else {
                Button { Task { _ = await coordinator.connect() } } label: { Text("Connect Codex") }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(AssistantControlButtonStyle())
                    .disabled(session.isRunning)
                    .accessibilityIdentifier("assistant.connectCodex")
            }
            StudioSettingsButton(accessibilityIdentifier: "assistant.settings")
        }
        .animation(reduceMotion ? nil : StudioMotion.fade, value: coordinator.isConnecting)
        .animation(reduceMotion ? nil : StudioMotion.fade, value: coordinator.isConnected)
    }

    private func showConnectionSettings() {
        AppSettingsNavigation.shared.selection = .codex
        openAppSettings()
    }
}

/// Shared preview: only a deliberate user action submits a plan to the runner.
struct AssistantRecordingPlanView: View {
    @ObservedObject var session: AIAssistantSession
    var compact = false
    @State private var confirmsRun = false
    @State private var reviewedPlan: CodexRecordingPlan?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Recording plan", systemImage: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Draft · review before running")
                    .font(.caption2).foregroundStyle(StudioTheme.secondaryText)
            }
            if let plan = session.recordingPlan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: plan.title).font(.headline)
                        Text(verbatim: plan.summary).font(.caption)
                        Label(captureSummary(plan.capture), systemImage: "viewfinder")
                            .font(.caption).textSelection(.enabled)
                        ForEach(Array(plan.actions.enumerated()), id: \.offset) { index, action in
                            HStack(alignment: .top) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(StudioTheme.purple)
                                Text(verbatim: actionSummary(action)).textSelection(.enabled)
                            }.font(.caption)
                        }
                        Text("Ask in chat to change the steps. Nothing runs until you approve the plan.")
                            .font(.caption).foregroundStyle(StudioTheme.secondaryText)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { reviewedPlan = plan; confirmsRun = true } label: {
                    Label(LocalizedStringKey(session.planWasRun ? "Plan submitted" : "Run recording plan"), systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(tint: StudioTheme.red))
                .disabled(session.isRunning || session.planWasRun || !session.hasPlanRunner)
                .accessibilityIdentifier("assistant.runPlan")
            } else {
                Text("Discuss your idea in chat. A recording plan will appear here when you ask for one.")
                    .font(.caption).foregroundStyle(StudioTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(compact ? 12 : 18)
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .topLeading)
        .background(StudioTheme.panel)
        .confirmationDialog("Run this recording plan?", isPresented: $confirmsRun) {
            Button("Run recording plan") {
                guard let reviewedPlan else { return }
                session.runRecordingPlan(expectedPlan: reviewedPlan)
            }
        } message: {
            Text("This opens the selected target and may click, scroll, navigate, and record it. Review every step before continuing.")
        }
        .onChange(of: session.recordingPlan) { _, _ in confirmsRun = false }
    }

    private func captureSummary(_ capture: CodexCaptureDirective) -> String {
        switch capture.mode {
        case .url: return capture.url.map { L10n.format("Open %@", $0) } ?? L10n.tr("Open a URL")
        case .window: return capture.windowTitle.map { L10n.format("Record window “%@”", $0) } ?? L10n.tr("Record a window")
        case .screenshot: return capture.screenshotPath.map { L10n.format("Capture %@", $0) } ?? L10n.tr("Capture a screenshot")
        }
    }

    private func actionSummary(_ action: CodexRecordingAction) -> String {
        func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
        switch action.type {
        case .wait: return L10n.format("Wait %@s", number(action.seconds ?? 0))
        case .move: return L10n.format("Move pointer to %@, %@ over %@s", number(action.x ?? 0), number(action.y ?? 0), number(action.seconds ?? 0.35))
        case .click: return L10n.format("Click%@ at %@, %@", action.label.map { " “\($0)”" } ?? "", number(action.x ?? 0), number(action.y ?? 0))
        case .scroll: return L10n.format("Scroll by %@, %@", number(action.deltaX ?? 0), number(action.deltaY ?? 0))
        case .navigate: return action.url.map { L10n.format("Navigate to %@", $0) } ?? L10n.tr("Navigate")
        }
    }
}
