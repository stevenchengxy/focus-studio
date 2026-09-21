import SwiftUI

/// A self-contained Director panel. Its run action is intentionally a callback:
/// the view can propose and validate a plan, but it never controls capture or UI
/// automation directly.
struct CodexDirectorView: View {
    @ObservedObject var director: CodexDirectorService
    @ObservedObject private var localization = AppLocalization.shared
    var onClose: () -> Void
    var onCreatePlan: ((String) -> Void)?
    var onRunPlan: (CodexRecordingPlan) -> Void

    @State private var prompt = ""
    @State private var showsConnectionSettings = false

    init(
        director: CodexDirectorService,
        onClose: @escaping () -> Void = {},
        onCreatePlan: ((String) -> Void)? = nil,
        onRunPlan: @escaping (CodexRecordingPlan) -> Void = { _ in }
    ) {
        self.director = director
        self.onClose = onClose
        self.onCreatePlan = onCreatePlan
        self.onRunPlan = onRunPlan
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StudioTheme.line)

            HSplitView {
                conversation
                    .frame(minWidth: 390, idealWidth: 480)

                planPanel
                    .frame(minWidth: 320, idealWidth: 390)
            }
        }
        .background(StudioTheme.window)
        .foregroundStyle(StudioTheme.text)
        // Observe language here as well as at the root: plan summaries contain
        // formatted app labels around verbatim user URLs and window names.
        .environment(\.locale, localization.locale)
        .sheet(isPresented: $showsConnectionSettings) {
            AppLocalizedView {
                CodexConnectionSettingsView(director: director)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(IconButtonStyle())

            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StudioTheme.purple)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Director")
                    .font(.system(size: 15, weight: .semibold))
                Text("Describe the product demo you want to record")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText)
            }

            Spacer()

            connectionBadge

            Button {
                showsConnectionSettings = true
            } label: {
                Label("Connection", systemImage: "gearshape")
            }
            .disabled(director.connectionState == .generating)

            if director.connectionState == .generating {
                Button("Stop planning") {
                    Task { await director.interruptCurrentTurn() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioTheme.yellow)
            } else if director.connectionState == .ready {
                Button("Disconnect") {
                    director.disconnect()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioTheme.secondaryText)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 60)
        .background(StudioTheme.panel)
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(LocalizedStringKey(director.connectionState.title))
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(Color.white.opacity(0.055))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(StudioTheme.line, lineWidth: 1))
    }

    private var statusColor: Color {
        switch director.connectionState {
        case .disconnected: return StudioTheme.secondaryText
        case .connecting, .generating, .needsSignIn, .signingIn: return StudioTheme.yellow
        case .ready: return .green
        case .failed: return StudioTheme.red
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if !director.canCreatePlan && director.connectionState != .generating {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect your Codex account").font(.system(size: 13, weight: .semibold))
                        Text("Choose your installation, sign in, and test the connection.")
                            .font(.system(size: 11)).foregroundStyle(StudioTheme.secondaryText)
                    }
                    Spacer()
                    Button("Set up Codex") { showsConnectionSettings = true }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(16)
                .background(StudioTheme.purpleSoft)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if director.messages.isEmpty {
                            emptyConversation
                        }

                        ForEach(director.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }

                        if director.connectionState == .generating {
                            streamingBubble
                                .id("codex-stream")
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onChange(of: director.messages.count) { _, _ in
                    if let lastID = director.messages.last?.id {
                        withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                    }
                }
                .onChange(of: director.streamedResponse) { _, _ in
                    guard director.connectionState == .generating else { return }
                    proxy.scrollTo("codex-stream", anchor: .bottom)
                }
            }

            if let error = director.lastErrorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StudioTheme.yellow)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.secondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(StudioTheme.yellow.opacity(0.08))
            }

            composer
        }
        .background(StudioTheme.window)
    }

    private var emptyConversation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 24))
                .foregroundStyle(StudioTheme.purple)
            Text("Plan a polished product recording")
                .font(.system(size: 17, weight: .semibold))
            Text("Try: “Open our dashboard, wait for it to load, click Analytics, scroll through the chart, then open Settings.”")
                .font(.system(size: 12))
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Include a URL and Focus Studio will open it, capture the visible content, and send that screenshot with your prompt to Codex for visual planning.")
                .font(.system(size: 10))
                .foregroundStyle(StudioTheme.secondaryText.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func messageBubble(_ message: CodexDirectorMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }

            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey(message.role == .user ? "You" : "Codex"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StudioTheme.secondaryText)
                Text(message.text)
                    .font(.system(size: 12, design: message.role == .assistant ? .monospaced : .default))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(message.role == .user ? StudioTheme.purpleSoft : StudioTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            if message.role != .user { Spacer(minLength: 48) }
        }
    }

    private var streamingBubble: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 5) {
                Text("Codex is planning…")
                    .font(.system(size: 11, weight: .semibold))
                if !director.streamedResponse.isEmpty {
                    Text(director.streamedResponse)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(StudioTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var composer: some View {
        VStack(spacing: 10) {
            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 66, maxHeight: 108)
                .background(StudioTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(StudioTheme.line, lineWidth: 1)
                )

            HStack {
                Text("Prompts and URL screenshots are sent to Codex. Nothing runs until you approve the plan.")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTheme.secondaryText)
                Spacer()
                Button("Create plan") { submitPrompt() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.45)
            }
        }
        .padding(14)
        .background(StudioTheme.panel)
        .overlay(alignment: .top) { Divider().overlay(StudioTheme.line) }
    }

    private var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && director.canCreatePlan
    }

    private func submitPrompt() {
        let submitted = prompt
        prompt = ""
        if let onCreatePlan {
            onCreatePlan(submitted)
        } else {
            Task { await director.sendPrompt(submitted) }
        }
    }

    private var planPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recording plan")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let plan = director.currentPlan {
                    Text("\(plan.actions.count) actions")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(StudioTheme.secondaryText)
                }
            }
            .padding(16)

            Divider().overlay(StudioTheme.line)

            if let plan = director.currentPlan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(plan.title)
                                .font(.system(size: 18, weight: .semibold))
                            Text(plan.summary)
                                .font(.system(size: 12))
                                .foregroundStyle(StudioTheme.secondaryText)
                        }

                        captureCard(plan.capture)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("SEQUENCE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(StudioTheme.secondaryText)

                            ForEach(Array(plan.actions.enumerated()), id: \.offset) { index, action in
                                actionRow(index: index, action: action)
                            }
                        }
                    }
                    .padding(16)
                }

                Button {
                    onRunPlan(plan)
                } label: {
                    Label("Run recording plan", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(tint: StudioTheme.red))
                .padding(16)
                .background(StudioTheme.panel)
                .overlay(alignment: .top) { Divider().overlay(StudioTheme.line) }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .font(.system(size: 30))
                        .foregroundStyle(StudioTheme.secondaryText)
                    Text("Your validated plan will appear here")
                        .font(.system(size: 12, weight: .medium))
                    Text("Nothing runs until you select the run button.")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(StudioTheme.panel.opacity(0.7))
    }

    private func captureCard(_ capture: CodexCaptureDirective) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: captureIcon(capture.mode))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StudioTheme.purple)
                .frame(width: 30, height: 30)
                .background(StudioTheme.purple.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(capture.mode.title))
                    .textCase(.uppercase)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(StudioTheme.secondaryText)
                Text(captureSummary(capture))
                    .font(.system(size: 12, weight: .medium))
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(StudioTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(StudioTheme.line, lineWidth: 1)
        )
    }

    private func actionRow(index: Int, action: CodexRecordingAction) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 23, height: 23)
                .background(StudioTheme.purpleSoft)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(action.type.rawValue.capitalized))
                    .font(.system(size: 11, weight: .semibold))
                Text(actionSummary(action))
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func captureIcon(_ mode: CodexCaptureMode) -> String {
        switch mode {
        case .url: return "globe"
        case .window: return "macwindow"
        case .screenshot: return "camera.viewfinder"
        }
    }

    private func captureSummary(_ capture: CodexCaptureDirective) -> String {
        switch capture.mode {
        case .url:
            return capture.url.map { L10n.format("Open %@", $0) } ?? L10n.tr("Open a URL")
        case .window:
            return capture.windowTitle.map { L10n.format("Record window “%@”", $0) } ?? L10n.tr("Record a window")
        case .screenshot:
            return capture.screenshotPath.map { L10n.format("Capture %@", $0) } ?? L10n.tr("Capture a screenshot")
        }
    }

    private func actionSummary(_ action: CodexRecordingAction) -> String {
        func number(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(0...2)))
        }
        switch action.type {
        case .wait:
            return L10n.format("Wait %@s", number(action.seconds ?? 0))
        case .click:
            let target = action.label.map { " “\($0)”" } ?? ""
            if let x = action.x, let y = action.y {
                return L10n.format("Click%@ at %@, %@", target, number(x), number(y))
            }
            return L10n.format("Click%@", target)
        case .scroll:
            return L10n.format("Scroll by %@, %@", number(action.deltaX ?? 0), number(action.deltaY ?? 0))
        case .navigate:
            return action.url.map { L10n.format("Navigate to %@", $0) } ?? L10n.tr("Navigate")
        }
    }
}
