import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// The assistant conversation: an animated character above the transcript,
/// the confirmation card for paid calls, follow-up chips and a composer with
/// voice input. Sized for ~360 pt beside the editor and works as a sheet from
/// the library.
struct AIAssistantPanel: View {
    @ObservedObject var session: AIAssistantSession
    let modelLabel: String
    let onClose: (() -> Void)?
    let openSettings: (() -> Void)?

    @State private var draft = ""
    @State private var pendingAttachments: [URL] = []
    /// What was typed before the mic started; partial transcripts append to it.
    @State private var draftBeforeRecording = ""
    /// Newest non-status message the avatar already reacted to.
    @State private var lastReactedTimestamp = Date()
    @StateObject private var speechInput = SpeechInputController()
    @StateObject private var speechOutput = SpeechOutputController()
    @StateObject private var avatar = AssistantAvatarDirector()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Localizable keys; shown as chips and sent verbatim (translated) on click.
    static let exampleRequests = [
        "Generate a background image for this recording",
        "Make a 5-second intro clip from the current look",
        "Create chapters and captions from my clicks",
    ]

    static let expandedAvatarHeight: CGFloat = 150
    static let compactAvatarHeight: CGFloat = 90
    /// The avatar shrinks once the transcript has more rows than this.
    static let compactTranscriptThreshold = 3

    init(
        session: AIAssistantSession,
        modelLabel: String,
        onClose: (() -> Void)? = nil,
        openSettings: (() -> Void)? = nil
    ) {
        self.session = session
        self.modelLabel = modelLabel
        self.onClose = onClose
        self.openSettings = openSettings
    }

    private var canSend: Bool {
        session.hasModel && !session.isRunning && session.pendingConfirmation == nil
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)
    }

    private var canRecord: Bool {
        session.hasModel && session.pendingConfirmation == nil
    }

    private var isCompact: Bool {
        session.messages.count > Self.compactTranscriptThreshold
    }

    private var avatarAudioLevel: Double {
        if speechInput.isRecording { return speechInput.audioLevel }
        if speechOutput.isSpeaking { return speechOutput.activityLevel }
        return 0
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    private var cardTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StudioTheme.line)
            if !session.hasModel { modelNotice }
            transcript
            if let pending = session.pendingConfirmation {
                confirmationCard(pending)
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
        .animation(reduceMotion ? nil : StudioMotion.selection, value: session.pendingConfirmation?.id)
        .animation(reduceMotion ? nil : StudioMotion.selection, value: session.suggestions)
        .animation(reduceMotion ? nil : StudioMotion.fade, value: speechInput.issue)
        .animation(reduceMotion ? nil : StudioMotion.selection, value: isCompact)
        .onAppear {
            lastReactedTimestamp = Date()
            updateAvatarBase()
        }
        .onDisappear {
            speechInput.cancel()
            speechOutput.stop()
        }
        .onChange(of: session.isRunning) { _, _ in updateAvatarBase() }
        .onChange(of: session.pendingConfirmation?.id) { _, id in
            if id != nil, speechInput.isActive { speechInput.stop() }
            updateAvatarBase()
        }
        .onChange(of: speechInput.isRecording) { _, _ in updateAvatarBase() }
        .onChange(of: speechInput.isPreparing) { _, _ in updateAvatarBase() }
        .onChange(of: speechInput.transcript) { _, transcript in
            draft = Self.join(draftBeforeRecording, transcript)
        }
        .onChange(of: speechOutput.isSpeaking) { _, speaking in avatar.setSpeakingAloud(speaking) }
        .onChange(of: speechOutput.isEnabled) { _, enabled in
            if !enabled { speechOutput.stop() }
        }
        .onChange(of: session.messages.last?.id) { _, _ in reactToNewMessages() }
    }

    // MARK: - Avatar

    private func updateAvatarBase() {
        let base: AvatarState
        if speechInput.isActive || session.pendingConfirmation != nil {
            base = .listening
        } else if session.isRunning {
            base = .thinking
        } else {
            base = .idle
        }
        avatar.setBase(base)
    }

    /// Reacts to the newest message the avatar has not seen. Status rows are
    /// skipped so a tool result followed at once by "Thinking…" still counts.
    private func reactToNewMessages() {
        let fresh = session.messages.filter { $0.role != .status && $0.timestamp > lastReactedTimestamp }
        guard let latest = fresh.last else { return }
        lastReactedTimestamp = latest.timestamp
        switch latest.role {
        case .assistant:
            if speechOutput.isEnabled {
                speechOutput.speak(latest.text)
            } else {
                avatar.react(.speaking, for: .seconds(2))
            }
        case .error:
            speechOutput.stop()
            avatar.react(.error, for: .seconds(2.5))
        case .tool:
            if latest.text != L10n.tr("Cancelled — nothing was generated.") {
                avatar.react(.happy, for: .seconds(1.4))
            }
        case .user:
            speechOutput.stop()
        case .status:
            break
        }
    }

    // MARK: - Header

    private var header: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 2) {
                AssistantAvatarView(state: avatar.state, audioLevel: avatarAudioLevel)
                    .frame(maxWidth: .infinity)
                    .frame(height: isCompact ? Self.compactAvatarHeight : Self.expandedAvatarHeight)
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    Text("AI Assistant")
                        .font(.system(size: 13, weight: .semibold))
                    if !modelLabel.isEmpty {
                        Text(verbatim: modelLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(StudioTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .padding(.bottom, 10)

            HStack(spacing: 6) {
                Toggle(isOn: $speechOutput.isEnabled) {
                    Label("Voice replies", systemImage: speechOutput.isEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .toggleStyle(IconToggleStyle())
                .help("Voice replies")
                .accessibilityIdentifier("assistant.voiceReplies")
                if session.isRunning {
                    Button {
                        speechOutput.stop()
                        session.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Stop")
                    .accessibilityIdentifier("assistant.stop")
                    .transition(.opacity)
                }
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
            .padding(8)
            .animation(reduceMotion ? nil : StudioMotion.fade, value: session.isRunning)
        }
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
        ScrollViewReader { proxy in
            ScrollView {
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
                            .transition(rowTransition)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .animation(reduceMotion ? nil : StudioMotion.selection, value: session.messages.map(\.id))
            }
            .onChange(of: session.messages.last?.id) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : StudioMotion.fade) { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: session.messages.last?.text) { _, _ in
                guard let id = session.messages.last?.id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.exampleRequests.enumerated()), id: \.element) { index, request in
                Button {
                    session.send(L10n.tr(request))
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
                .disabled(!session.hasModel)
                .staggeredAppearance(index: index)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func row(for message: AIAssistantMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.text.isEmpty {
                        Text(verbatim: message.text)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !message.attachments.isEmpty {
                        AssistantAttachmentGrid(urls: message.attachments)
                    }
                }
                .padding(10)
                .background(StudioTheme.purpleSoft)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .transition(rowTransition)
        case .assistant:
            HStack {
                Text(verbatim: message.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(StudioTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                Spacer(minLength: 40)
            }
            .transition(rowTransition)
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
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(StudioTheme.yellow)
                VStack(alignment: .leading, spacing: 3) {
                    if let toolName = message.toolName {
                        Text(Self.toolTitle(toolName))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StudioTheme.secondaryText)
                    }
                    Text(verbatim: message.text)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(StudioTheme.yellow.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .transition(rowTransition)
        }
    }

    /// Three bouncing dots plus the optional progress text from the session.
    private func typingRow(text: String?) -> some View {
        HStack(spacing: 8) {
            TypingIndicatorView()
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(StudioTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            if let text, !text.isEmpty {
                Text(verbatim: text)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private func toolCard(_ message: AIAssistantMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.toolIcon(message.toolName))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StudioTheme.purple)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.toolTitle(message.toolName ?? ""))
                    .font(.system(size: 11, weight: .semibold))
                Text(verbatim: message.text)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.attachments.isEmpty {
                    AssistantAttachmentGrid(urls: message.attachments)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(message.attachments)
                    } label: {
                        Label("Reveal", systemImage: "magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioTheme.purple)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(StudioTheme.panelRaised)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(StudioTheme.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Confirmation

    private func confirmationCard(_ pending: AIAssistantSession.PendingToolCall) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "yensign.circle.fill")
                    .foregroundStyle(StudioTheme.yellow)
                Text("Confirm generation")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(verbatim: "≈ ¥" + String(format: "%.2f", pending.estimate.yuan))
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(verbatim: pending.estimate.summary)
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { session.cancelPending() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .padding(.horizontal, 10)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("assistant.cancel")
                Button("Confirm") { session.confirmPending() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
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

    // MARK: - Suggestions

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(session.suggestions.enumerated()), id: \.element) { index, suggestion in
                    Button {
                        session.send(suggestion)
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
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: attachFiles) {
                    Label("Attach files", systemImage: "paperclip")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(IconButtonStyle())
                .help("Attach files")
                .disabled(!session.hasModel)
                .accessibilityIdentifier("assistant.attach")

                composerField

                let microphoneHelp: LocalizedStringKey = speechInput.isRecording ? "Stop recording (Esc)" : "Voice input"
                MicrophoneButton(isRecording: speechInput.isRecording, isPreparing: speechInput.isPreparing) {
                    toggleRecording()
                }
                .keyboardShortcut(speechInput.isRecording ? KeyboardShortcut(.escape, modifiers: []) : nil)
                .help(microphoneHelp)
                .disabled(!canRecord)
                .accessibilityIdentifier("assistant.mic")

                Button(action: sendDraft) {
                    Label("Send", systemImage: "arrow.up")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 30)
                        .background(canSend ? StudioTheme.purple : StudioTheme.purple.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("Send (⌘↩)")
                .accessibilityIdentifier("assistant.send")
            }
        }
        .padding(10)
    }

    private var composerField: some View {
        let placeholder: LocalizedStringKey = speechInput.isRecording && draft.isEmpty ? "Listening…" : "Ask the assistant…"
        return TextField(placeholder, text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .font(.system(size: 12))
            .padding(.leading, 10)
            .padding(.trailing, speechInput.isRecording ? 34 : 10)
            .padding(.vertical, 7)
            .background(StudioTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(speechInput.isRecording ? StudioTheme.red.opacity(0.55) : StudioTheme.line, lineWidth: 1)
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
            .disabled(!session.hasModel)
            .accessibilityIdentifier("assistant.composer")
    }

    private func toggleRecording() {
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
        // Discard any transcript still in flight so it cannot land in the empty field.
        speechInput.cancel()
        draftBeforeRecording = ""
        let text = draft
        let attachments = pendingAttachments
        draft = ""
        pendingAttachments = []
        session.send(text, attachments: attachments)
    }

    private func attachFiles() {
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
        case "generate_image": return "Generate image"
        case "generate_video": return "Generate video"
        case "capture_frame": return "Capture frame"
        case "set_background_image": return "Set background image"
        case "update_settings": return "Update settings"
        case "set_chapters": return "Set chapters"
        case "list_assets": return "List assets"
        case "export_demo": return "Export demo"
        case "assemble_video": return "Assemble video"
        case "reveal_in_finder": return "Reveal in Finder"
        default: return LocalizedStringKey(name)
        }
    }

    static func toolIcon(_ name: String?) -> String {
        switch name {
        case "generate_image": return "photo"
        case "generate_video": return "film"
        case "capture_frame": return "camera.viewfinder"
        case "set_background_image": return "photo.on.rectangle"
        case "update_settings": return "slider.horizontal.3"
        case "set_chapters": return "text.bubble"
        case "list_assets": return "folder"
        case "export_demo": return "square.and.arrow.up"
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

/// Thumbnails for generated files. Images and videos render a preview; other
/// files show an icon. A click opens the file with its default app.
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

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.35))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: AIAssistantPanel.attachmentIcon(url))
                    .font(.system(size: 16))
                    .foregroundStyle(StudioTheme.secondaryText)
            }
        }
        .frame(height: 60)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(StudioTheme.line, lineWidth: 1)
        )
        .help(url.lastPathComponent)
        .onTapGesture { NSWorkspace.shared.open(url) }
        .task(id: url) {
            image = await Self.thumbnail(for: url)
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
