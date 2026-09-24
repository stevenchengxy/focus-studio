import FocusStudioCore
import Foundation

/// What the model decided in one step of the agent loop.
enum AIAssistantDecision {
    case reply(text: String, suggestions: [String])
    case action(tool: String, arguments: [String: Any], thought: String?)
}

/// The strict JSON protocol between the session and the text model, parsed
/// tolerantly: Markdown fences and prose around the object are ignored and
/// anything that is not a protocol object becomes a plain reply.
enum AIAssistantProtocol {
    static let maximumSuggestions = 4

    static func parse(_ text: String) -> AIAssistantDecision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for candidate in jsonCandidates(in: trimmed) {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let decision = decision(from: object)
            else { continue }
            return decision
        }
        return .reply(text: trimmed, suggestions: [])
    }

    static func decision(from object: [String: Any]) -> AIAssistantDecision? {
        let thought = string(object["thought"])
        if let action = object["action"] as? [String: Any],
           let tool = string(action["tool"]) ?? string(action["name"]) {
            let arguments = (action["arguments"] as? [String: Any])
                ?? (action["args"] as? [String: Any])
                ?? (action["parameters"] as? [String: Any])
                ?? [:]
            return .action(tool: tool, arguments: arguments, thought: thought)
        }
        if let tool = string(object["tool"]), object["reply"] == nil {
            let arguments = (object["arguments"] as? [String: Any]) ?? (object["args"] as? [String: Any]) ?? [:]
            return .action(tool: tool, arguments: arguments, thought: thought)
        }
        if let reply = string(object["reply"]) ?? string(object["response"]) ?? string(object["answer"]) ?? string(object["message"]) {
            return .reply(text: reply, suggestions: suggestions(object["suggestions"]))
        }
        if let thought, object.keys.allSatisfy({ ["thought", "suggestions", "action", "reply"].contains($0) }) {
            return .reply(text: thought, suggestions: suggestions(object["suggestions"]))
        }
        return nil
    }

    /// Likely JSON documents inside a reply, most specific first: fenced
    /// code blocks, the whole reply, then every balanced `{…}` span.
    static func jsonCandidates(in text: String) -> [String] {
        var candidates = fencedBlocks(in: text)
        candidates.append(text)
        candidates.append(contentsOf: balancedObjects(in: text))
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func fencedBlocks(in text: String) -> [String] {
        guard text.contains("```"),
              let expression = try? NSRegularExpression(pattern: "```[A-Za-z0-9_+-]*[ \\t]*\\r?\\n?([\\s\\S]*?)```")
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let blockRange = Range(match.range(at: 1), in: text) else { return nil }
            let block = text[blockRange].trimmingCharacters(in: .whitespacesAndNewlines)
            return block.isEmpty ? nil : block
        }
    }

    private static func balancedObjects(in text: String) -> [String] {
        let characters = Array(text)
        var spans: [String] = []
        var index = 0
        while index < characters.count {
            if characters[index] == "{", let end = matchingClose(from: index, in: characters) {
                spans.append(String(characters[index...end]))
                index = end + 1
            } else {
                index += 1
            }
        }
        return spans
    }

    private static func matchingClose(from start: Int, in characters: [Character]) -> Int? {
        var depth = 0
        var inString = false
        var index = start
        while index < characters.count {
            let character = characters[index]
            if inString {
                if character == "\\" { index += 2; continue }
                if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{", "[": depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 { return index }
                    if depth < 0 { return nil }
                default: break
                }
            }
            index += 1
        }
        return nil
    }

    private static func suggestions(_ value: Any?) -> [String] {
        guard let list = value as? [Any] else { return [] }
        return Array(list.compactMap { string($0) }.filter { !$0.isEmpty }.prefix(maximumSuggestions))
    }

    private static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        let text: String
        if let string = value as? String {
            text = string
        } else if let number = value as? NSNumber {
            text = number.stringValue
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One conversation with the assistant: the transcript, the agent loop that
/// turns model replies into tool calls, and the confirmation gate for paid calls.
@MainActor
final class AIAssistantSession: ObservableObject {
    struct PendingToolCall: Identifiable {
        let id = UUID()
        let tool: any AIAssistantTool
        let arguments: [String: Any]
        let estimate: AIToolCostEstimate

        var toolName: String { tool.name }
    }

    static let maximumStepsPerTurn = 8
    static let transcriptCharacterBudget = 12_000
    static let maximumListedAssets = 12
    static let maximumListedZooms = 16

    @Published private(set) var messages: [AIAssistantMessage] = []
    @Published private(set) var isRunning = false
    @Published private(set) var pendingConfirmation: PendingToolCall?
    /// Follow-ups offered by the last reply.
    @Published private(set) var suggestions: [String] = []
    /// Whether a text model (or Codex) can answer right now. Re-evaluated with
    /// ``refreshModelAvailability()`` whenever the app's AI settings change.
    @Published private(set) var hasModel: Bool

    let context: AIAssistantContext
    let tools: [any AIAssistantTool]

    private let completionResolver: @MainActor () -> (any TextCompletionProviding)?
    private let toolCatalogJSON: String
    private var runningTask: Task<Void, Never>?
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    private var statusMessageID: UUID?
    private var declinedMessageIDs: Set<UUID> = []

    convenience init(
        context: AIAssistantContext,
        completion: (any TextCompletionProviding)?,
        tools: [any AIAssistantTool] = AIAssistantToolCatalog.standard
    ) {
        self.init(context: context, completionResolver: { completion }, tools: tools)
    }

    /// `completionResolver` is consulted on every send, so switching the model
    /// or the assistant brain in Settings applies to the next message.
    init(
        context: AIAssistantContext,
        completionResolver: @escaping @MainActor () -> (any TextCompletionProviding)?,
        tools: [any AIAssistantTool] = AIAssistantToolCatalog.standard
    ) {
        self.context = context
        self.completionResolver = completionResolver
        self.tools = tools
        toolCatalogJSON = Self.renderToolCatalog(tools)
        hasModel = completionResolver() != nil
    }

    /// The provider that would answer the next message.
    var completion: (any TextCompletionProviding)? { completionResolver() }

    func refreshModelAvailability() {
        let available = completionResolver() != nil
        if available != hasModel { hasModel = available }
    }

    // MARK: - Public actions

    func send(_ text: String, attachments: [URL] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !trimmed.isEmpty || !attachments.isEmpty else { return }
        refreshModelAvailability()
        guard let completion = completionResolver() else {
            messages.append(AIAssistantMessage(role: .error, text: L10n.tr("Set up an AI model in Settings")))
            return
        }
        suggestions = []
        messages.append(AIAssistantMessage(role: .user, text: trimmed, attachments: attachments))
        isRunning = true
        runningTask = Task { [weak self] in
            guard let self else { return }
            await self.runTurn(completion: completion)
            self.clearStatus()
            self.isRunning = false
            self.runningTask = nil
        }
    }

    func confirmPending() { resolveConfirmation(true) }

    func cancelPending() { resolveConfirmation(false) }

    /// Cancels the running step (and any Ark task being polled).
    func stop() {
        guard isRunning else { return }
        runningTask?.cancel()
        resolveConfirmation(false)
    }

    func clearTranscript() {
        guard !isRunning else { return }
        messages = []
        suggestions = []
        declinedMessageIDs = []
    }

    // MARK: - Agent loop

    private func runTurn(completion: any TextCompletionProviding) async {
        for _ in 0..<Self.maximumStepsPerTurn {
            if Task.isCancelled { appendStopped(); return }
            setStatus(L10n.tr("Thinking…"))
            let raw: String
            do {
                raw = try await completion.complete(system: systemPrompt(), user: userContent(), json: true)
            } catch is CancellationError {
                appendStopped()
                return
            } catch {
                if Task.isCancelled { appendStopped(); return }
                clearStatus()
                messages.append(AIAssistantMessage(role: .error, text: error.localizedDescription))
                return
            }
            if Task.isCancelled { appendStopped(); return }
            clearStatus()

            switch AIAssistantProtocol.parse(raw) {
            case let .reply(text, replySuggestions):
                guard !text.isEmpty else {
                    messages.append(AIAssistantMessage(role: .error, text: L10n.tr("The model returned an empty reply.")))
                    return
                }
                messages.append(AIAssistantMessage(role: .assistant, text: text))
                suggestions = replySuggestions
                return

            case let .action(toolName, arguments, _):
                guard let tool = tools.first(where: { $0.name == toolName }) else {
                    messages.append(AIAssistantMessage(
                        role: .error,
                        text: "Unknown tool \"\(toolName)\". Available: \(tools.map(\.name).joined(separator: ", ")).",
                        toolName: toolName
                    ))
                    continue
                }
                if let estimate = tool.costEstimate(arguments: arguments) {
                    let confirmed = await requestConfirmation(tool: tool, arguments: arguments, estimate: estimate)
                    if Task.isCancelled { appendStopped(); return }
                    guard confirmed else {
                        let declined = AIAssistantMessage(role: .tool, text: L10n.tr("Cancelled — nothing was generated."), toolName: tool.name)
                        declinedMessageIDs.insert(declined.id)
                        messages.append(declined)
                        continue
                    }
                }
                setStatus(L10n.format("Running %@…", tool.name))
                let progress: @Sendable (String) -> Void = { [weak self] text in
                    Task { @MainActor in self?.setStatus(text) }
                }
                do {
                    let result = try await tool.run(arguments: arguments, context: context, progress: progress)
                    clearStatus()
                    messages.append(AIAssistantMessage(role: .tool, text: result.text, attachments: result.attachments, toolName: tool.name))
                } catch is CancellationError {
                    appendStopped()
                    return
                } catch {
                    clearStatus()
                    if Task.isCancelled { appendStopped(); return }
                    messages.append(AIAssistantMessage(role: .error, text: error.localizedDescription, toolName: tool.name))
                }
            }
        }
        clearStatus()
        messages.append(AIAssistantMessage(role: .error, text: L10n.format("Stopped after %lld steps.", Self.maximumStepsPerTurn)))
    }

    // MARK: - Confirmation

    private func requestConfirmation(
        tool: any AIAssistantTool,
        arguments: [String: Any],
        estimate: AIToolCostEstimate
    ) async -> Bool {
        clearStatus()
        return await withCheckedContinuation { continuation in
            confirmationContinuation = continuation
            pendingConfirmation = PendingToolCall(tool: tool, arguments: arguments, estimate: estimate)
        }
    }

    private func resolveConfirmation(_ confirmed: Bool) {
        guard let continuation = confirmationContinuation else { return }
        confirmationContinuation = nil
        pendingConfirmation = nil
        continuation.resume(returning: confirmed)
    }

    // MARK: - Status rows

    private func setStatus(_ text: String) {
        if let id = statusMessageID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = text
        } else {
            let message = AIAssistantMessage(role: .status, text: text)
            statusMessageID = message.id
            messages.append(message)
        }
    }

    private func clearStatus() {
        guard let id = statusMessageID else { return }
        statusMessageID = nil
        messages.removeAll { $0.id == id }
    }

    private func appendStopped() {
        clearStatus()
        messages.append(AIAssistantMessage(role: .status, text: L10n.tr("Stopped")))
    }

    // MARK: - Prompts

    func systemPrompt() -> String {
        """
        You are the AI assistant inside Focus Studio, a macOS app that records the screen and turns the recording into a polished product-demo video: automatic zooms on clicks and typing, a styled background with padding and shadow, chapter captions drawn on the video, background music and sound effects, and MP4 export.
        You operate the app through tools. The end-to-end workflow is: list_recording_sources → start_recording (the app counts down 3 seconds, then records until stop_recording) → stop_recording (saves a project and opens it in the editor) → edit: add_zoom / remove_zoom / set_zoom_style, set_chapters, update_settings or set_background_image for the look, set_background_music and set_sound_effects → export_project → optionally generate_image / generate_video (Volcengine Ark: Seedream images, Seedance clips) for an intro or outro and assemble_video to join intro + export + outro. list_projects / open_project / close_editor move between the library and the editor; editing and export tools need a project open in the editor.

        Tools (name, summary, JSON schema of the arguments):
        \(toolCatalogJSON)

        Rules:
        - Think briefly in "thought", then either call exactly one tool or reply to the user.
        - Multi-step requests ("record Safari and export it") are executed step by step: call the next tool after each result, and keep the user informed with brief replies when a step takes time or needs their action (for example, the demo itself happens while recording — reply after start_recording, then call stop_recording when the user says they are done, unless they asked for a fixed duration).
        - A recording captures what the user does on screen; do not stop it until the user says the demo is finished, and never start a second recording while one is in progress.
        - When the intent is ambiguous (which window, what the image should show, clip length, mood, which clips to join), ask one short clarifying question instead of guessing.
        - Prefer cheap choices while iterating: \(ArkMediaClient.defaultVideoModel), 4–6 seconds, 720p; \(ArkMediaClient.defaultImageModel). Say what things cost in 元.
        - generate_video is paid and the app asks the user to confirm before it runs. If the user declines, do not repeat the same call; ask what to change.
        - Never ask for words, letters, logos or interface text inside image or video prompts: captions and titles are added by the app.
        - A background image must keep the screen readable: subtle, low-contrast, soft gradients or abstract shapes that match the product's colours.
        - Refer to local files by full path or by a file name from list_assets. Use capture_frame when a clip should match the current look, then pass the frame as first_frame or reference_images.
        - Zoom positions are normalized: x 0–1 from left to right, y 0–1 from top to bottom; times are seconds within the recording (see the project summary for duration, clicks and existing zooms).
        - After a tool result decide whether another call is needed; otherwise reply with what happened and up to three short follow-up suggestions.
        - If a tool fails, explain the problem in one sentence and, when possible, suggest the fix (open a project, grant Screen Recording permission, configure the Ark key).
        - Reply in \(Self.languageName(context.uiLanguage)). Keep replies to one to three sentences, no Markdown headings.
        - Everything you produce stays editable by the user in the editor.

        Reply format, strict JSON and nothing else:
        To call a tool: {"thought": "...", "action": {"tool": "<name>", "arguments": {...}}}
        To answer or ask: {"thought": "...", "reply": "...", "suggestions": ["...", "..."]}
        """
    }

    func userContent() -> String {
        var sections: [String] = []
        if let app = appSummary() { sections.append("[App]\n" + app) }
        sections.append("[Project]\n" + projectSummary())
        sections.append("[Conversation]\n" + transcript())
        return sections.joined(separator: "\n\n")
    }

    /// Recording state, library size and bundled music, when the app is controllable.
    func appSummary() -> String? {
        guard let app = context.app else { return nil }
        var lines = ["Recording: \(app.recordingPhase.label) | Projects in library: \(app.projectSummaries.count) | Editor: \(app.openProjectID == nil ? "closed (library showing)" : "open")"]
        let sources = app.recordingSources
        if !sources.isEmpty {
            let displays = sources.filter { $0.kind == .display }.count
            let windows = sources.filter { $0.kind == .window }.count
            lines.append("Known sources: \(displays) displays, \(windows) windows (list_recording_sources refreshes them)")
        }
        let music = app.bundledMusicTracks
        if !music.isEmpty {
            lines.append("Bundled music: " + music.map { "\($0.title) (\($0.id))" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    func projectSummary() -> String {
        guard let project = context.readProject() else { return "No recording is open. Use list_projects and open_project, or record a new demo." }
        let settings = project.settings
        var lines: [String] = []
        let title = project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("Title: \(title.isEmpty ? "Untitled" : title) | Duration: \(Self.seconds(project.duration)) s | Source: \(project.sourceWidth)×\(project.sourceHeight) | Clicks: \(project.clickEvents.count) | Zooms: \(project.zoomSegments.filter(\.isEnabled).count) | Chapters: \(project.chapters?.count ?? 0)")
        lines.append("Look: background \(Self.backgroundDescription(settings)) | aspect \(settings.aspectRatio.title) | padding \(Int(settings.padding)) px | corner radius \(Int(settings.cornerRadius)) px | shadow \(Self.seconds(settings.shadow)) | screen animation \(settings.screenAnimation.rawValue) | zoom scale \(Self.seconds(settings.zoomScale))× | caption \(settings.resolvedCaptionStyle.position.rawValue)")
        if let description = settings.productDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            lines.append("Product: \(String(description.prefix(400)))")
        }
        let audio = settings.resolvedProductDemoAudio
        let music = audio.backgroundMusicPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "none"
        lines.append("Zoom style: automatic zooms \(settings.autoZoomEnabled ? "on" : "off") | hold \(Self.seconds(settings.zoomHold)) s | ease in \(Self.seconds(settings.zoomEaseIn)) s | ease out \(Self.seconds(settings.zoomEaseOut)) s | chain gap \(Self.seconds(settings.resolvedZoomChainGap)) s")
        lines.append("Audio: music \(music) (volume \(Self.seconds(audio.backgroundMusicVolume))) | click sound \(audio.clickSoundEnabled ? "on" : "off") | zoom whoosh \(audio.zoomTransitionSoundEnabled ? "on" : "off")")
        lines.append("Export: \(settings.exportWidth) px wide | \(settings.frameRate) fps")
        let zooms = AIToolSupport.orderedZooms(project)
        if !zooms.isEmpty {
            let listed = zooms.prefix(Self.maximumListedZooms).map { "#\($0.index) \(AIToolSupport.zoomLine($0.segment))" }
            var text = "Zooms (time order): " + listed.joined(separator: "; ")
            if zooms.count > Self.maximumListedZooms { text += "; and \(zooms.count - Self.maximumListedZooms) more" }
            lines.append(text)
        }
        if let chapters = project.chapters, !chapters.isEmpty {
            let listed = chapters.sorted(by: ChapterMath.precedes).prefix(12).enumerated().map { index, chapter in
                "\(index + 1). \(Self.seconds(chapter.start))–\(Self.seconds(chapter.end)) s \(chapter.title)\(chapter.caption.isEmpty ? "" : " — \(chapter.caption)")"
            }
            lines.append("Chapters: " + listed.joined(separator: "; "))
        }
        let assets = Self.listedAssets(in: context.assetsDirectory)
        lines.append(assets.isEmpty ? "Assets: none yet (folder \(context.assetsDirectory.path))" : "Assets in \(context.assetsDirectory.path): \(assets.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }

    /// Newest messages that fit the character budget, oldest first.
    func transcript() -> String {
        var entries: [String] = []
        var used = 0
        var truncated = false
        for message in messages.reversed() {
            guard let entry = transcriptEntry(for: message) else { continue }
            if used + entry.count > Self.transcriptCharacterBudget, !entries.isEmpty {
                truncated = true
                break
            }
            entries.append(entry)
            used += entry.count
        }
        if truncated { entries.append("(earlier messages omitted)") }
        return entries.reversed().joined(separator: "\n\n")
    }

    private func transcriptEntry(for message: AIAssistantMessage) -> String? {
        switch message.role {
        case .user:
            var text = "User: \(message.text)"
            if !message.attachments.isEmpty {
                text += "\nAttached files:\n" + message.attachments.map { "- \($0.path)" }.joined(separator: "\n")
            }
            return text
        case .assistant:
            return "Assistant: \(message.text)"
        case .tool:
            let name = message.toolName ?? "tool"
            if declinedMessageIDs.contains(message.id) {
                return "Tool \(name): the user declined the paid call, so it did not run. Ask what to change or continue without it."
            }
            var text = "Tool \(name) result:\n\(message.text)"
            let extra = message.attachments.filter { !message.text.contains($0.path) }
            if !extra.isEmpty { text += "\nFiles: " + extra.map(\.path).joined(separator: ", ") }
            return text
        case .error:
            guard let name = message.toolName else { return nil }
            return "Tool \(name) failed: \(message.text)"
        case .status:
            return nil
        }
    }

    // MARK: - Helpers

    private static func renderToolCatalog(_ tools: [any AIAssistantTool]) -> String {
        let entries: [[String: Any]] = tools.map { tool in
            ["name": tool.name, "summary": tool.summary, "parameters": tool.parametersSchema]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func backgroundDescription(_ settings: ProjectSettings) -> String {
        switch settings.backgroundStyle {
        case .image:
            let name = settings.backgroundImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
            return "image (\(name))"
        case .solid:
            return "solid \(settings.backgroundColor)"
        case .gradient:
            if let preset = BackgroundPreset.allCases.first(where: { $0.matches(primary: settings.backgroundColor, secondary: settings.secondaryBackgroundColor) }) {
                return "gradient preset \(preset.title)"
            }
            return "gradient \(settings.backgroundColor) → \(settings.secondaryBackgroundColor)"
        }
    }

    private static func listedAssets(in directory: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        let media = contents
            .filter { AIToolPaths.kind(of: $0) != nil }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        var names = media.prefix(maximumListedAssets).map(\.lastPathComponent)
        if media.count > maximumListedAssets { names.append("and \(media.count - maximumListedAssets) more") }
        return names
    }

    static func languageName(_ code: String) -> String {
        let normalized = code.lowercased().replacingOccurrences(of: "_", with: "-")
        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") { return "Traditional Chinese (繁體中文)" }
        if normalized.hasPrefix("zh") { return "Simplified Chinese (简体中文)" }
        if normalized.hasPrefix("en") { return "English" }
        if normalized.hasPrefix("ja") { return "Japanese" }
        return "the language with BCP 47 code \(code)"
    }

    private static func seconds(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
