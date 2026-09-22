import SwiftUI

/// Opening Director never starts a request, opens a browser, or creates a second chat.
struct CodexDirectorView: View {
    @ObservedObject var session: AIAssistantSession
    @ObservedObject var director: CodexDirectorService
    let modelLabel: String
    var onClose: () -> Void = {}
    var openSettings: (() -> Void)?
    @State private var showsConnectionSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onClose) { Image(systemName: "chevron.left") }
                    .buttonStyle(IconButtonStyle())
                Text("Demo Director").font(.system(size: 15, weight: .semibold))
                Text("One conversation, from idea to recording")
                    .font(.caption).foregroundStyle(StudioTheme.secondaryText)
                Spacer()
                Button("Connection") { showsConnectionSettings = true }
            }
            .padding(.horizontal, 18).frame(height: 60).background(StudioTheme.panel)
            Divider().overlay(StudioTheme.line)
            HSplitView {
                AIAssistantPanel(session: session, modelLabel: modelLabel,
                                 openSettings: openSettings, showsPlan: false)
                    .frame(minWidth: 390, idealWidth: 480)
                AssistantRecordingPlanView(session: session)
                    .frame(minWidth: 320, idealWidth: 390)
            }
        }
        .background(StudioTheme.window).foregroundStyle(StudioTheme.text)
        .sheet(isPresented: $showsConnectionSettings) {
            AppLocalizedView { CodexConnectionSettingsView(director: director) }
        }
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
        case .click: return L10n.format("Click%@ at %@, %@", action.label.map { " “\($0)”" } ?? "", number(action.x ?? 0), number(action.y ?? 0))
        case .scroll: return L10n.format("Scroll by %@, %@", number(action.deltaX ?? 0), number(action.deltaY ?? 0))
        case .navigate: return action.url.map { L10n.format("Navigate to %@", $0) } ?? L10n.tr("Navigate")
        }
    }
}
