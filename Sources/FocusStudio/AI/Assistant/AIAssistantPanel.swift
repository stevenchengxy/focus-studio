import AppKit
import AVFoundation
import AVKit
import FocusStudioAutomation
import SwiftUI
import UniformTypeIdentifiers

/// The assistant conversation: a compact chat header, the confirmation card
/// for paid calls, follow-up chips and a composer with
/// voice input. Sized for ~360 pt beside the editor and works as a sheet from
/// the library.
struct AIAssistantPanel: View {
    @ObservedObject var session: AIAssistantSession
    @ObservedObject var gateway: AIGatewayStore
    @ObservedObject private var draftRouter = AssistantDraftRouter.shared
    let modelLabel: String
    let onClose: (() -> Void)?
    let openSettings: (() -> Void)?
    let showsPlan: Bool
    let title: String
    let showsHeader: Bool
    let isActive: Bool
    let onSubmit: ((String, [URL]) async -> Bool)?
    let openDemoVideo: ((UUID) -> Void)?
    let hasEditableProject: Bool

    @State private var draft = ""
    @State private var pendingAttachments: [URL] = []
    @State private var showsConversationHistory = false
    @State private var historySearch = ""
    @State private var renamingConversationID: UUID?
    @State private var renameDraft = ""
    @State private var deletingConversationID: UUID?
    @State private var isSubmitting = false
    @State private var queuedClipDraft: String?
    @State private var videoModelSelectionError: String?
    @State private var transcriptFollowRequest = UUID()
    @FocusState private var composerFocused: Bool
    /// What was typed before the mic started; partial transcripts append to it.
    @State private var draftBeforeRecording = ""
    /// Prevent old messages from being spoken when reopening the chat.
    @State private var lastSpokenTimestamp = Date()
    @StateObject private var speechInput = SpeechInputController()
    @StateObject private var speechOutput = SpeechOutputController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Localizable keys; shown as chips and sent verbatim (translated) on click.
    static let exampleRequests = [
        "Record a walkthrough of my website. Ask me for the URL and the steps to demonstrate.",
        "Help me plan a short product walkthrough before recording.",
        "Create an edited copy of my current recording: shorten empty waits, tune each zoom, preview the cuts and export a 1080p demo. Keep meaningful page changes and reading time.",
        "Create a short, text-free product B-roll clip. Ask about the desired look first, then save it to my shared media library.",
    ]

    private static let promoShotPlanningRequest = "Help me plan 2–3 product-led promo shots for my demo. Separate real product UI from AI-generated effects. For each shot, give me a keyframe prompt, a motion prompt, and how it fits my selected video model. Ask for my product URL or screenshots if needed. Do not generate paid media yet."

    init(
        session: AIAssistantSession,
        gateway: AIGatewayStore,
        modelLabel: String,
        onClose: (() -> Void)? = nil,
        openSettings: (() -> Void)? = nil,
        showsPlan: Bool = true,
        title: String = "AI Assistant",
        showsHeader: Bool = true,
        isActive: Bool = true,
        onSubmit: ((String, [URL]) async -> Bool)? = nil,
        openDemoVideo: ((UUID) -> Void)? = nil,
        hasEditableProject: Bool = false
    ) {
        self.session = session
        self.gateway = gateway
        self.modelLabel = modelLabel
        self.onClose = onClose
        self.openSettings = openSettings
        self.showsPlan = showsPlan
        self.title = title
        self.showsHeader = showsHeader
        self.isActive = isActive
        self.onSubmit = onSubmit
        self.openDemoVideo = openDemoVideo
        self.hasEditableProject = hasEditableProject
    }

    private var canSubmit: Bool {
        isActive && !isSubmitting && (session.hasModel || onSubmit != nil)
            && !session.isRunning && session.pendingConfirmation == nil
    }

    private var canSend: Bool {
        canSubmit
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)
    }

    private var canRecord: Bool {
        isActive && !isSubmitting && (session.hasModel || onSubmit != nil) && session.pendingConfirmation == nil
    }

    private var activeDemo: AIDemoTaskProgress? {
        guard let task = session.demoTask, !task.stage.isTerminal else { return nil }
        return task
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    private var cardTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Divider().overlay(StudioTheme.line)
                if !session.hasModel { modelNotice }
            } else {
                conversationBar
            }
            transcript
            if let warning = session.historyWarning {
                Text(verbatim: warning).font(.caption).foregroundStyle(StudioTheme.yellow).padding(10)
            }
            if showsPlan, session.recordingPlan != nil {
                AssistantRecordingPlanView(session: session, compact: true)
                    .frame(maxHeight: 200)
            }
            if session.canRetry, !session.isRunning {
                Button("Retry reply") {
                    transcriptFollowRequest = UUID()
                    session.retryLastTurn()
                }
                    .disabled(!session.hasModel)
                    .help("Continues the conversation without repeating completed actions.")
                    .padding(8)
            }
            if let pending = session.pendingConfirmation {
                confirmationCard(pending)
                    .transition(rowTransition)
            } else if let task = session.demoTask {
                demoProgressCard(task)
                    .transition(rowTransition)
            }
            if !session.suggestions.isEmpty, !session.isRunning, session.pendingConfirmation == nil {
                suggestionChips
                    .transition(.opacity)
            }
            if let issue = speechInput.issue {
                SpeechPermissionNotice(issue: issue) { speechInput.issue = nil }
                    .transition(.opacity)
            }
            Divider().overlay(StudioTheme.line)
            composer
        }
        .background(StudioTheme.panel)
        .foregroundStyle(StudioTheme.text)
        .disabled(!isActive)
        .animation(reduceMotion ? nil : StudioMotion.selection, value: session.pendingConfirmation?.id)
        .animation(reduceMotion ? nil : StudioMotion.selection, value: session.suggestions)
        .animation(reduceMotion ? nil : StudioMotion.fade, value: speechInput.issue)
        .onAppear {
            lastSpokenTimestamp = Date()
        }
        .task(id: draftRouter.request?.id) {
            guard let request = draftRouter.request else { return }
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = request.text
                composerFocused = isActive
            } else {
                queuedClipDraft = request.text
            }
            draftRouter.consume(request.id)
        }
        .onDisappear {
            deactivateComposer()
        }
        .onChange(of: isActive) { _, active in
            lastSpokenTimestamp = Date()
            if !active { deactivateComposer() }
        }
        .onChange(of: session.pendingConfirmation?.id) { _, id in
            if id != nil, speechInput.isActive { speechInput.stop() }
            videoModelSelectionError = nil
        }
        .onChange(of: speechInput.transcript) { _, transcript in
            guard isActive else { return }
            draft = Self.join(draftBeforeRecording, transcript)
        }
        .onChange(of: speechOutput.isEnabled) { _, enabled in
            if !enabled { speechOutput.stop() }
        }
        .onChange(of: session.messages.last?.id) { _, _ in speakNewReplyIfEnabled() }
        .onChange(of: session.conversationID) { _, _ in
            speechInput.cancel()
            speechOutput.stop()
            draft = ""
            pendingAttachments = []
            transcriptFollowRequest = UUID()
            showsConversationHistory = false
            historySearch = ""
            composerFocused = isActive
        }
        .confirmationDialog("Delete conversation?", isPresented: Binding(
            get: { deletingConversationID != nil },
            set: { if !$0 { deletingConversationID = nil } }
        )) {
            if let id = deletingConversationID {
                Button("Delete conversation", role: .destructive) {
                    session.deleteConversation(id)
                    deletingConversationID = nil
                }
            }
        } message: {
            Text("Only this chat history is deleted. Recordings and projects stay unchanged.")
        }
    }

    // MARK: - Optional voice replies

    private func deactivateComposer() {
        composerFocused = false
        speechInput.cancel()
        speechOutput.stop()
    }

    private func speakNewReplyIfEnabled() {
        let fresh = session.messages.filter { $0.role != .status && $0.timestamp > lastSpokenTimestamp }
        guard let latest = fresh.last else { return }
        lastSpokenTimestamp = latest.timestamp
        guard isActive else { return }
        switch latest.role {
        case .assistant:
            if speechOutput.isEnabled, session.claimSpeech(for: latest.id) {
                speechOutput.speak(latest.text)
            }
        case .error, .user:
            speechOutput.stop()
        case .tool, .status:
            break
        }
    }

    // MARK: - Header

    private var currentConversationTitle: String {
        session.conversationSummaries.first(where: { $0.id == session.conversationID })?.title ?? String(localized: "New conversation")
    }

    private var conversationBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(StudioTheme.purple)
            Text(verbatim: currentConversationTitle)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            conversationHistoryButton(compact: false)
            newConversationButton(compact: false)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .background(StudioTheme.panelRaised)
    }

    private func newConversationButton(compact: Bool) -> some View {
        Button { session.createConversation() } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.pencil")
                if !compact { Text("New") }
            }
            .frame(minWidth: compact ? 32 : 0, minHeight: 30)
            .padding(.horizontal, compact ? 0 : 8)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .help("Start a new chat; previous chats stay in history.")
        .disabled(session.isRunning || isSubmitting)
        .accessibilityLabel("New conversation")
        .accessibilityIdentifier("assistant.newConversation")
    }

    private func conversationHistoryButton(compact: Bool) -> some View {
        Button { showsConversationHistory.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                if !compact { Text("History") }
            }
            .frame(minWidth: compact ? 32 : 0, minHeight: 30)
            .padding(.horizontal, compact ? 0 : 8)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .help("Conversation history")
        .accessibilityLabel("Conversation history")
        .accessibilityIdentifier("assistant.history")
        .popover(isPresented: $showsConversationHistory, arrowEdge: .bottom) {
            conversationHistory
        }
    }

    private var conversationHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Conversation history")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(session.conversationSummaries.count)")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.secondaryText)
            }
            TextField("Search conversations", text: $historySearch)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("assistant.historySearch")
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(session.conversationSummaries.filter { historySearch.isEmpty || $0.title.localizedCaseInsensitiveContains(historySearch) }) { summary in
                        conversationHistoryRow(summary)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(14)
        .frame(width: 340)
        .background(StudioTheme.panel)
        .foregroundStyle(StudioTheme.text)
    }

    private func conversationHistoryRow(_ summary: AIAssistantConversationSummary) -> some View {
        HStack(spacing: 6) {
            if renamingConversationID == summary.id {
                TextField("Conversation name", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveConversationRename() }
                Button("Save") { saveConversationRename() }
                    .buttonStyle(.borderless)
            } else {
                Button {
                    session.selectConversation(summary.id)
                    showsConversationHistory = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: summary.id == session.conversationID ? "checkmark.circle.fill" : "bubble.left")
                            .foregroundStyle(summary.id == session.conversationID ? StudioTheme.purple : StudioTheme.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: summary.title).lineLimit(1)
                            Text(summary.updatedAt, format: .dateTime.month().day().hour().minute())
                                .font(.system(size: 10))
                                .foregroundStyle(StudioTheme.secondaryText)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(session.isRunning || isSubmitting)
                .accessibilityIdentifier("assistant.history.\(summary.id.uuidString)")
                Menu {
                    Button("Rename") {
                        renamingConversationID = summary.id
                        renameDraft = summary.title
                    }
                    Button("Delete conversation", role: .destructive) { deletingConversationID = summary.id }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .disabled(session.isRunning || isSubmitting)
                .accessibilityLabel("Manage conversation")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(summary.id == session.conversationID ? StudioTheme.purple.opacity(0.12) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    private func saveConversationRename() {
        guard let id = renamingConversationID else { return }
        session.renameConversation(id, to: renameDraft)
        renamingConversationID = nil
        renameDraft = ""
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                conversationHistoryButton(compact: true)
                newConversationButton(compact: true)
                if let openSettings {
                    Button(action: openSettings) {
                        Label("Model settings", systemImage: "slider.horizontal.3").labelStyle(.iconOnly)
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Model settings")
                }
                Toggle(isOn: $speechOutput.isEnabled) {
                    Label("Voice replies", systemImage: speechOutput.isEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .toggleStyle(IconToggleStyle())
                .help("Voice replies")
                .accessibilityIdentifier("assistant.voiceReplies")
                if let onClose {
                    Button(action: onClose) {
                        Label("Close", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Close")
                    .accessibilityIdentifier("assistant.close")
                }
            }
            .animation(reduceMotion ? nil : StudioMotion.fade, value: session.isRunning)
            if !modelLabel.isEmpty || !session.conversationSummaries.isEmpty {
                let currentTitle = session.conversationSummaries.first(where: { $0.id == session.conversationID })?.title
                Text(verbatim: [currentTitle, modelLabel.isEmpty ? nil : modelLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
    }

    private var modelNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(StudioTheme.yellow)
            Text("Set up an AI model in Settings")
                .font(.system(size: 12))
            Spacer(minLength: 4)
            if let openSettings {
                Button("Settings", action: openSettings)
                    .buttonStyle(PrimaryButtonStyle())
                    .controlSize(.small)
                    .accessibilityIdentifier("assistant.openSettings")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(StudioTheme.yellow.opacity(0.08))
    }

    // MARK: - Transcript

    private var transcript: some View {
        AssistantTranscriptScrollView(followRequest: transcriptFollowRequest) {
            LazyVStack(alignment: .leading, spacing: 10) {
                if session.messages.isEmpty {
                    emptyState
                }
                ForEach(session.messages) { message in
                    row(for: message)
                        .id(message.id)
                }
                if session.isRunning, session.pendingConfirmation == nil, session.messages.last?.role != .status {
                    typingRow(text: nil)
                        .id("assistant.typing")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(StudioTheme.purple)
                    .frame(width: 32, height: 32)
                    .background(StudioTheme.purpleSoft, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("What would you like to make?")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Ask, record, generate media or edit your demo in one conversation.")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 2)
            ForEach(Array(Self.exampleRequests.enumerated()), id: \.element) { index, request in
                Button {
                    submit(L10n.tr(request), attachments: [])
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StudioTheme.secondaryText)
                        Text(LocalizedStringKey(request))
                            .font(.system(size: 12))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(StudioTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .staggeredAppearance(index: index)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func row(for message: AIAssistantMessage) -> some View {
        switch message.role {
        case .user:
            chatRow(message, isUser: true).transition(rowTransition)
        case .assistant:
            chatRow(message, isUser: false).transition(rowTransition)
        case .tool:
            toolCard(message)
                .transition(cardTransition)
        case .status:
            if session.isRunning {
                typingRow(text: message.text)
                    .transition(rowTransition)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "stop.circle")
                        .foregroundStyle(StudioTheme.secondaryText)
                    Text(verbatim: message.text)
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .transition(rowTransition)
            }
        case .error:
            AssistantErrorCard(message: message, openSettings: openSettings)
                .transition(rowTransition)
        }
    }

    private func chatRow(_ message: AIAssistantMessage, isUser: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 32) }
            if !isUser {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTheme.purple)
                    .frame(width: 25, height: 25)
                    .background(StudioTheme.purpleSoft, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
                Text(LocalizedStringKey(isUser ? "You" : "AI Assistant"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StudioTheme.secondaryText)
                if !message.text.isEmpty {
                    Text(verbatim: message.text)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !message.attachments.isEmpty {
                    AssistantAttachmentGrid(urls: message.attachments)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)
            .background(isUser ? StudioTheme.purpleSoft : StudioTheme.panelRaised,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if !isUser { Spacer(minLength: 32) }
        }
    }

    /// Three bouncing dots and an explicit state, including before the first
    /// remote model response has arrived.
    private func typingRow(text: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTheme.purple)
                .frame(width: 25, height: 25)
                .background(StudioTheme.purpleSoft, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(verbatim: text.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.tr("Thinking…"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StudioTheme.secondaryText)
                .lineLimit(2)
            TypingIndicatorView()
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(StudioTheme.panelRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistant.thinking")
    }

    private func toolCard(_ message: AIAssistantMessage) -> some View {
        AssistantToolResultCard(message: message)
    }

    // MARK: - Confirmation

    @ViewBuilder
    private func confirmationCard(_ pending: AIAssistantSession.PendingToolCall) -> some View {
        if let request = pending.demoTaskRequest {
            demoReviewCard(request, expiresAt: pending.expiresAt)
        } else {
            standardConfirmationCard(pending)
        }
    }

    private func demoReviewCard(_ request: AIDemoTaskRequest, expiresAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Ready to record", systemImage: "record.circle")
                .font(.system(size: 13, weight: .semibold))
            Label {
                Text(verbatim: request.sourceTitle).lineLimit(2)
            } icon: { Image(systemName: "macwindow") }
            .font(.system(size: 12, weight: .medium))
            Text(verbatim: request.instructions)
                .font(.system(size: 12)).lineSpacing(2).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if request.mode == .interactive {
                Label(request.allowsTextInput ? "Click, scroll, and type demo text" : "Click and scroll",
                      systemImage: request.allowsTextInput ? "keyboard" : "cursorarrow.click")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioTheme.purple)
                    .accessibilityIdentifier("assistant.demoCapabilities")
            }
            Text(request.mode == .interactive
                 ? "Codex follows this goal in the selected window. Cursor tracking and automatic zoom are included. Audio is off."
                 : "You control the page while it is recorded. Automatic zoom is included. Audio is off.")
                .font(.caption).foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: request.mode == .interactive
                         ? L10n.format("Up to %d seconds · %d interactions", Int(request.maximumDuration), request.maximumActions)
                         : L10n.format("Up to %d seconds", Int(request.maximumDuration)))
                    if let expiresAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(verbatim: L10n.format("Approval expires in %@", Self.clockText(expiresAt.timeIntervalSince(context.date))))
                                .monospacedDigit()
                        }
                    }
                }
                .font(.caption2).foregroundStyle(StudioTheme.secondaryText)
                Spacer(minLength: 4)
                Button("Cancel") { session.cancelPending() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(isActive ? .cancelAction : nil)
                    .accessibilityIdentifier("assistant.cancel")
                Button(request.mode == .interactive ? "Start demo" : "Start recording") {
                    speechOutput.stop()
                    composerFocused = false
                    transcriptFollowRequest = UUID()
                    session.confirmPending()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(isActive ? .defaultAction : nil)
                .accessibilityIdentifier("assistant.confirm")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(StudioTheme.purple.opacity(0.3)))
        .padding(.horizontal, 12).padding(.bottom, 10)
        .accessibilityIdentifier("assistant.demoReview")
    }

    private func standardConfirmationCard(_ pending: AIAssistantSession.PendingToolCall) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: pending.isPaid ? Self.costIcon(pending.estimate) : "record.circle")
                    .foregroundStyle(StudioTheme.yellow)
                Text(LocalizedStringKey(pending.isPaid ? "Confirm generation" : "Confirm recording action"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if pending.isPaid {
                    Text(verbatim: Self.formattedCost(pending.estimate))
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            Text(verbatim: pending.estimate.summary)
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if pending.toolName == "generate_video" {
                videoModelConfirmation(pending)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { session.cancelPending() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .padding(.horizontal, 10)
                    .keyboardShortcut(isActive ? .cancelAction : nil)
                    .accessibilityIdentifier("assistant.cancel")
                Button("Confirm") {
                    transcriptFollowRequest = UUID()
                    session.confirmPending()
                }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(isActive ? .defaultAction : nil)
                    .accessibilityIdentifier("assistant.confirm")
            }
        }
        .padding(12)
        .background(StudioTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .pulsingBorder(StudioTheme.purple, cornerRadius: 11)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private static func formattedCost(_ estimate: AIToolCostEstimate) -> String {
        let code = estimate.currencyCode.uppercased()
        let symbol: String
        switch code {
        case "USD": symbol = "$"
        case "CNY": symbol = "¥"
        default: symbol = ""
        }
        return "≈ \(symbol)\(String(format: "%.2f", estimate.yuan)) \(code)"
    }

    private static func costIcon(_ estimate: AIToolCostEstimate) -> String {
        switch estimate.currencyCode.uppercased() {
        case "USD": return "dollarsign.circle.fill"
        case "CNY": return "yensign.circle.fill"
        default: return "creditcard.circle.fill"
        }
    }

    private func videoModelConfirmation(_ pending: AIAssistantSession.PendingToolCall) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("Video model")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                videoModelMenu(selectedID: pending.selectedVideoModelID ?? gateway.preferredVideoModelID) { id in
                    if session.setPendingVideoModel(id) {
                        gateway.preferredVideoModelID = id
                        videoModelSelectionError = nil
                    } else {
                        videoModelSelectionError = L10n.tr("This model cannot use the current generation settings. Choose another model or adjust the request.")
                    }
                }
            }
            if let videoModelSelectionError {
                Text(verbatim: videoModelSelectionError)
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTheme.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Review the model and updated estimate before paying. Your selection is used for this generation.")
                .font(.system(size: 10))
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let selectedID = pending.selectedVideoModelID,
               !gateway.isVideoModelListed(selectedID) {
                Label("This model is not listed for your configured video provider. Test the connection in Settings before generating.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTheme.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .background(StudioTheme.window, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("assistant.videoModelConfirmation")
    }

    private func videoModelMenu(selectedID: String, onSelect: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(videoModelMenuIDs(selectedID: selectedID), id: \.self) { id in
                Button {
                    onSelect(id)
                } label: {
                    Label {
                        Text(verbatim: videoModelOptionTitle(id))
                    } icon: {
                        Image(systemName: id == selectedID ? "checkmark.circle.fill" : "film")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: gateway.videoModelDisplayName(selectedID))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("assistant.videoModelPicker")
    }

    private func videoModelMenuIDs(selectedID: String) -> [String] {
        var ids = gateway.videoModelChoices
        if !ids.contains(selectedID) { ids.insert(selectedID, at: 0) }
        return ids
    }

    private func videoModelOptionTitle(_ id: String) -> String {
        let name = gateway.videoModelDisplayName(id)
        let provider: String?
        switch gateway.videoModelProvider(for: id) {
        case .ark: provider = "Ark"
        case .gemini: provider = "Google"
        case nil: provider = nil
        }
        let detail = session.videoModelChoices.first(where: { $0.id == id })?.detail
        let verified = gateway.isVideoModelListed(id)
        return [name, provider, detail, verified ? nil : L10n.tr("Not verified")]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func demoProgressCard(_ task: AIDemoTaskProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if task.stage.isTerminal {
                    Image(systemName: task.stage == .completed ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(task.stage == .completed ? Color.green : StudioTheme.yellow)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(LocalizedStringKey(Self.demoStageTitle(task.stage)))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                if !task.stage.isTerminal {
                    Button {
                        speechOutput.stop()
                        session.stop()
                    } label: {
                        Label(task.stage == .reviewing ? "Saving…" : "Stop and save", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(StudioTheme.red)
                    .disabled(task.stage == .reviewing)
                    .accessibilityIdentifier("assistant.finishDemo")
                } else if let projectID = task.projectID, let openDemoVideo {
                    Button { openDemoVideo(projectID) } label: {
                        Label("Open recorded video", systemImage: "play.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("assistant.openDemo")
                }
            }
            Text(verbatim: task.sourceTitle)
                .font(.caption2).foregroundStyle(StudioTheme.secondaryText).lineLimit(1)
            Text(verbatim: L10n.tr(task.detail))
                .font(.caption).foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: L10n.format("%d interactions · limit %d", task.completedActions, task.maximumActions))
                if !task.stage.isTerminal, let startedAt = task.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 10) {
                            Text(verbatim: L10n.format("Elapsed %@", Self.clockText(context.date.timeIntervalSince(startedAt))))
                            if task.stage != .reviewing, let lastActivityAt = task.lastActivityAt,
                               context.date.timeIntervalSince(lastActivityAt) >= 10 {
                                Text(verbatim: L10n.format(task.completedActions == 0
                                    ? "Waiting for first interaction: %@" : "Since last interaction: %@",
                                    Self.clockText(context.date.timeIntervalSince(lastActivityAt))))
                                    .foregroundStyle(StudioTheme.yellow)
                            }
                        }
                    }
                }
            }
            .font(.caption2).monospacedDigit().foregroundStyle(StudioTheme.secondaryText)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.panelRaised, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(StudioTheme.line))
        .padding(.horizontal, 12).padding(.bottom, 10)
        .accessibilityIdentifier("assistant.demoProgress")
    }

    private static func demoStageTitle(_ stage: AIDemoTaskProgress.Stage) -> String {
        switch stage {
        case .preparing: return "Preparing your demo"
        case .checking: return "Checking the page"
        case .starting: return "Starting recording"
        case .observing: return "Observing the page"
        case .thinking: return "Choosing the next interaction"
        case .acting: return "Performing an interaction"
        case .recording: return "Recording in progress"
        case .reviewing: return "Saving your video"
        case .completed: return "Your demo is ready"
        case .cancelled: return "Demo stopped"
        case .failed: return "Demo needs attention"
        }
    }

    private static func clockText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Suggestions

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(session.suggestions.enumerated()), id: \.element) { index, suggestion in
                    Button {
                        submit(suggestion, attachments: [])
                    } label: {
                        Text(verbatim: suggestion)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.06))
                            .overlay(
                                Capsule().stroke(StudioTheme.line, lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                    .staggeredAppearance(index: index)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let queuedClipDraft {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .foregroundStyle(StudioTheme.purple)
                    Text("Selected clip request is ready")
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 2)
                    Button("Append") {
                        draft += "\n\n" + queuedClipDraft
                        self.queuedClipDraft = nil
                        composerFocused = true
                    }
                    .buttonStyle(.link)
                    Button("Replace") {
                        draft = queuedClipDraft
                        self.queuedClipDraft = nil
                        composerFocused = true
                    }
                    .buttonStyle(.link)
                    Button { self.queuedClipDraft = nil } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss selected clip request")
                }
                .padding(7)
                .background(StudioTheme.purpleSoft, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("assistant.queuedClipDraft")
            }
            if !session.isRunning, session.pendingConfirmation == nil, draft.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        draft = L10n.tr(Self.promoShotPlanningRequest)
                        composerFocused = true
                    } label: {
                        Label("Plan promo shots", systemImage: "sparkles.tv")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioTheme.purple)
                    .help("Draft shot concepts and prompts first; no paid generation starts.")
                    .accessibilityIdentifier("assistant.planPromoShots")
                    if hasEditableProject {
                        Button {
                            draft = L10n.tr(Self.exampleRequests[2])
                            composerFocused = true
                        } label: {
                            Label("Polish current video", systemImage: "scissors")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StudioTheme.purple)
                        .help("Prepare a request to shorten waits and adjust zooms in an editable copy.")
                        .accessibilityIdentifier("assistant.polishVideo")
                    }
                }
            }
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pendingAttachments, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: Self.attachmentIcon(url))
                                    .font(.system(size: 10))
                                Text(verbatim: url.lastPathComponent)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 140)
                                Button {
                                    pendingAttachments.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(StudioTheme.secondaryText)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Capsule())
                        }
                    }
                }
            }
            HStack(spacing: 7) {
                Image(systemName: "film")
                    .foregroundStyle(StudioTheme.purple)
                Text("AI video")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioTheme.secondaryText)
                videoModelMenu(selectedID: gateway.preferredVideoModelID) { id in
                    gateway.preferredVideoModelID = id
                }
                Spacer(minLength: 0)
                if !gateway.isVideoModelListed(gateway.preferredVideoModelID) {
                    Button("Set up") { openSettings?() }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                        .help("Configure and test a video model in Settings.")
                }
            }
            .accessibilityIdentifier("assistant.videoModelPreference")
            composerField
            HStack(spacing: 8) {
                Button(action: attachFiles) {
                    Label("Attach files", systemImage: "paperclip")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(IconButtonStyle())
                .help("Attach files")
                .disabled(!isActive || isSubmitting)
                .accessibilityIdentifier("assistant.attach")

                let microphoneHelp: LocalizedStringKey = speechInput.isRecording ? "Stop recording (Esc)" : "Voice input"
                MicrophoneButton(isRecording: speechInput.isRecording, isPreparing: speechInput.isPreparing) {
                    toggleRecording()
                }
                .keyboardShortcut(isActive && speechInput.isRecording ? KeyboardShortcut(.escape, modifiers: []) : nil)
                .help(microphoneHelp)
                .disabled(!canRecord)
                .accessibilityIdentifier("assistant.mic")

                if !showsHeader {
                    Toggle(isOn: $speechOutput.isEnabled) {
                        Label("Voice replies", systemImage: speechOutput.isEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                    }
                    .toggleStyle(IconToggleStyle())
                    .help("Voice replies")
                    .accessibilityIdentifier("assistant.voiceReplies")
                }
                Spacer(minLength: 4)
                if session.isRunning, activeDemo == nil {
                    Button {
                        speechOutput.stop()
                        session.stop()
                    } label: {
                        Label("Stop assistant", systemImage: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(StudioTheme.red.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioTheme.red)
                    .accessibilityIdentifier("assistant.stop")
                } else if activeDemo == nil {
                    Button(action: sendDraft) {
                        HStack(spacing: 6) {
                            if isSubmitting { ProgressView().controlSize(.mini).tint(.white) }
                            Text(isSubmitting ? "Connecting…" : "Send")
                            if !isSubmitting { Image(systemName: "arrow.up") }
                        }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(canSend ? StudioTheme.purple : StudioTheme.purple.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(isActive ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .disabled(!canSend)
                    .help("Send (⌘↩)")
                    .accessibilityIdentifier("assistant.send")
                }
            }
            Text("↩ New line · ⌘↩ Send")
                .font(.system(size: 10))
                .foregroundStyle(StudioTheme.secondaryText)
        }
        .padding(10)
    }

    private var composerField: some View {
        let placeholder: LocalizedStringKey = speechInput.isRecording && draft.isEmpty ? "Listening…" : "Paste a product URL and describe what to show, or ask for an edit…"
        return TextEditor(text: $draft)
            .scrollContentBackground(.hidden)
            .font(.system(size: 14))
            .focused($composerFocused)
            .frame(height: 72)
            .padding(.horizontal, 7)
            .padding(.vertical, 8)
            .background(StudioTheme.panelRaised)
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 14))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(speechInput.isRecording ? StudioTheme.red.opacity(0.55) : (composerFocused ? StudioTheme.purple.opacity(0.7) : StudioTheme.line), lineWidth: 1)
            )
            .overlay(alignment: .bottomTrailing) {
                if speechInput.isRecording {
                    AudioLevelMeterView(level: speechInput.audioLevel)
                        .padding(.trailing, 10)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : StudioMotion.fade, value: speechInput.isRecording)
            .accessibilityLabel("Message to the assistant")
            .accessibilityIdentifier("assistant.composer")
    }

    private func toggleRecording() {
        guard canRecord else { return }
        if speechInput.isRecording {
            speechInput.stop()
            return
        }
        speechOutput.stop()
        draftBeforeRecording = draft
        speechInput.start()
    }

    private func sendDraft() {
        guard canSend else { return }
        submit(draft, attachments: pendingAttachments, clearsDraft: true)
    }

    private func submit(_ text: String, attachments: [URL], clearsDraft: Bool = false) {
        guard canSubmit else { return }
        transcriptFollowRequest = UUID()
        // Discard any transcript still in flight so it cannot land in the empty field.
        speechInput.cancel()
        draftBeforeRecording = ""
        isSubmitting = true
        Task { @MainActor in
            let submitted: Bool
            if let onSubmit {
                submitted = await onSubmit(text, attachments)
            } else {
                session.send(text, attachments: attachments)
                submitted = true
            }
            if submitted, clearsDraft {
                if draft == text { draft = "" }
                if pendingAttachments == attachments { pendingAttachments = [] }
            }
            isSubmitting = false
            if submitted { composerFocused = isActive }
        }
    }

    private func attachFiles() {
        guard isActive else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .audio]
        panel.prompt = L10n.tr("Attach")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !pendingAttachments.contains(url) {
            pendingAttachments.append(url)
        }
    }

    /// Appends a transcript to what was typed before recording started.
    static func join(_ base: String, _ transcript: String) -> String {
        guard !base.isEmpty else { return transcript }
        guard !transcript.isEmpty else { return base }
        let needsSpace = base.last.map { !$0.isWhitespace } ?? false
        return base + (needsSpace ? " " : "") + transcript
    }

    // MARK: - Naming

    static func toolTitle(_ name: String) -> LocalizedStringKey {
        switch name {
        case "run_demo_task": return "Record product demo"
        case "prepare_demo_page": return "Open demo webpage"
        case "get_status": return "Recording readiness"
        case "list_recording_sources": return "Recording sources"
        case "start_recording": return "Start recording"
        case "capture_recording_frame": return "Observe recording window"
        case "perform_recording_action": return "Pointer action"
        case "perform_recording_text": return "Type demo text"
        case "stop_recording": return "Finish recording"
        case "wait_for_recording": return "Recording progress"
        case "list_projects": return "Recordings"
        case "get_project": return "Recording details"
        case "open_project": return "Open recording"
        case "close_editor": return "Close editor"
        case "add_zoom": return "Add zoom"
        case "analyze_demo_pacing": return "Analyze demo pacing"
        case "create_demo_cut": return "Create edited copy"
        case "update_zoom": return "Adjust zoom"
        case "remove_zoom": return "Remove zoom"
        case "set_zoom_style": return "Zoom style"
        case "set_background_music": return "Background music"
        case "set_sound_effects": return "Sound effects"
        case "generate_image": return "Generate image"
        case "generate_video": return "Generate video"
        case "capture_frame": return "Capture frame"
        case "set_background_image": return "Set background image"
        case "update_settings": return "Update settings"
        case "set_chapters": return "Set chapters"
        case "list_assets": return "List assets"
        case "list_media_assets": return "Media library"
        case "import_media_asset": return "Import media"
        case "insert_media_asset": return "Add to timeline"
        case "redo_clip_edit": return "Redo video edit"
        case "set_image_duration": return "Still duration"
        case "export_demo", "export_project": return "Export demo"
        case "assemble_video": return "Assemble video"
        case "reveal_in_finder": return "Reveal in Finder"
        case "wait": return "Wait"
        default: return "Task update"
        }
    }

    static func toolIcon(_ name: String?) -> String {
        switch name {
        case "run_demo_task": return "record.circle"
        case "prepare_demo_page": return "globe"
        case "get_status": return "checkmark.shield"
        case "list_recording_sources": return "macwindow"
        case "start_recording": return "record.circle"
        case "capture_recording_frame": return "viewfinder"
        case "perform_recording_action": return "cursorarrow.motionlines"
        case "perform_recording_text": return "keyboard"
        case "stop_recording": return "stop.circle"
        case "wait_for_recording", "wait": return "clock"
        case "list_projects", "get_project", "open_project", "close_editor": return "rectangle.stack"
        case "add_zoom", "remove_zoom", "set_zoom_style", "update_zoom": return "plus.magnifyingglass"
        case "analyze_demo_pacing": return "clock"
        case "create_demo_cut": return "scissors"
        case "set_background_music": return "music.note"
        case "set_sound_effects": return "waveform"
        case "generate_image": return "photo"
        case "generate_video": return "film"
        case "capture_frame": return "camera.viewfinder"
        case "set_background_image": return "photo.on.rectangle"
        case "update_settings": return "slider.horizontal.3"
        case "set_chapters": return "text.bubble"
        case "list_assets": return "folder"
        case "list_media_assets", "import_media_asset": return "square.stack.3d.up"
        case "insert_media_asset": return "film.stack"
        case "redo_clip_edit": return "arrow.uturn.forward"
        case "set_image_duration": return "timer"
        case "export_demo", "export_project": return "square.and.arrow.up"
        case "assemble_video": return "film.stack"
        case "reveal_in_finder": return "magnifyingglass"
        default: return "wrench.and.screwdriver"
        }
    }

    static func attachmentIcon(_ url: URL) -> String {
        switch AIToolPaths.kind(of: url) {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case nil: return "doc"
        }
    }
}

// MARK: - Attachments

/// Thumbnails for generated files. Video and image attachments preview inside
/// Focus Studio; audio and other files retain the system-open behavior.
struct AssistantAttachmentGrid: View {
    let urls: [URL]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(urls, id: \.self) { url in
                AssistantAttachmentThumbnail(url: url)
            }
        }
    }
}

struct AssistantAttachmentThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    @State private var showsPreview = false

    private var kind: AIToolPaths.MediaKind? { AIToolPaths.kind(of: url) }
    private var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    var body: some View {
        Button {
            if kind == .video || kind == .image {
                showsPreview = true
            } else if exists {
                NSWorkspace.shared.open(url)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: exists ? AIAssistantPanel.attachmentIcon(url) : "exclamationmark.triangle")
                        .font(.system(size: 16))
                        .foregroundStyle(StudioTheme.secondaryText)
                }
                if kind == .video, exists {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.black.opacity(0.72), in: Circle())
                }
            }
            .frame(height: 60)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(StudioTheme.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .help(exists ? L10n.format("Preview %@", url.lastPathComponent) : L10n.tr("This media file is no longer available."))
        .accessibilityLabel(exists ? L10n.format("Preview %@", url.lastPathComponent) : L10n.format("Missing media: %@", url.lastPathComponent))
        .accessibilityIdentifier("assistant.attachment.preview")
        .sheet(isPresented: $showsPreview) {
            AssistantMediaPreviewSheet(url: url, image: image)
        }
        .task(id: url) {
            image = exists ? await Self.thumbnail(for: url) : nil
        }
    }

    static func thumbnail(for url: URL, maximumSide: Int = 320) async -> NSImage? {
        switch AIToolPaths.kind(of: url) {
        case .image:
            return await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumSide,
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }.value
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maximumSide, height: maximumSide)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            guard let (cgImage, _) = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        default:
            return nil
        }
    }
}

/// The generated asset stays in the assistant while the user checks motion,
/// pacing and sound before adding it to a project. AVPlayer is paused when the
/// sheet closes so hidden previews never continue playing audio.
struct AssistantMediaPreviewSheet: View {
    let url: URL
    let title: String?
    @State private var image: NSImage?
    @State private var player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    init(url: URL, image: NSImage? = nil, title: String? = nil) {
        self.url = url
        self.title = title
        _image = State(initialValue: image)
        _player = State(initialValue: AIToolPaths.kind(of: url) == .video ? AVPlayer(url: url) : AVPlayer())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: AIAssistantPanel.attachmentIcon(url))
                    .foregroundStyle(StudioTheme.purple)
                Text(verbatim: title ?? url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioTheme.purple)
            }
            .padding(14)
            Divider()
            Group {
                if !FileManager.default.fileExists(atPath: url.path) {
                    ContentUnavailableView("Media unavailable", systemImage: "film", description: Text("The file was moved or deleted."))
                } else if AIToolPaths.kind(of: url) == .video {
                    VideoPlayer(player: player)
                        .accessibilityIdentifier("assistant.videoPreview")
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView("Loading preview…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
        .frame(minWidth: 600, minHeight: 430)
        .background(StudioTheme.panel)
        .task(id: url) {
            if image == nil, AIToolPaths.kind(of: url) == .image {
                image = await AssistantAttachmentThumbnail.thumbnail(for: url, maximumSide: 2400)
            }
        }
        .onAppear {
            if AIToolPaths.kind(of: url) == .video,
               FileManager.default.fileExists(atPath: url.path) {
                player.play()
            }
        }
        .onDisappear { player.pause() }
    }
}
