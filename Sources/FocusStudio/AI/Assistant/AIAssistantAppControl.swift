import FocusStudioCore
import Foundation

// MARK: - App control seam

/// A display or window the app can record, described the way the model sees it.
struct AIRecordingSource: Equatable, Sendable, Identifiable {
    var id: String
    var kind: CaptureTargetKind
    var appName: String?
    var title: String
    var width: Int
    var height: Int

    init(id: String, kind: CaptureTargetKind, appName: String? = nil, title: String, width: Int, height: Int) {
        self.id = id
        self.kind = kind
        self.appName = appName
        self.title = title
        self.width = width
        self.height = height
    }

    init(target: CaptureTargetInfo) {
        self.init(
            id: target.id,
            kind: target.kind,
            appName: target.appName,
            title: target.title,
            width: Int(target.frame.width.rounded()),
            height: Int(target.frame.height.rounded())
        )
    }

    var area: Int { max(0, width) * max(0, height) }

    /// One line for the model, e.g. `id win-12 · window · Safari — Docs · 1440×900`.
    var summaryLine: String {
        var parts = ["id \(id)", kind.rawValue]
        if let appName, !appName.isEmpty, kind == .window {
            parts.append(title.isEmpty ? appName : "\(appName) — \(title)")
        } else {
            parts.append(title.isEmpty ? (appName ?? kind.rawValue) : title)
        }
        parts.append("\(width)×\(height)")
        return parts.joined(separator: " · ")
    }
}

/// Where the app is in the record → stop cycle, as far as the tools care.
enum AIRecordingPhase: Equatable, Sendable {
    case idle
    /// The 3-second countdown (or the capture start) is under way.
    case countdown
    case recording
    case stopping
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "idle"
        case .countdown: return "counting down"
        case .recording: return "recording"
        case .stopping: return "stopping"
        case let .failed(message): return "failed: \(message)"
        }
    }
}

/// Capture options the assistant may set before a recording. Nil keeps the app's current value.
struct AIRecordingOptions: Equatable, Sendable {
    var systemAudio: Bool?
    var microphone: Bool?
    var automaticZooms: Bool?
    var browserContentOnly: Bool?
    var frameRate: Int?

    init(systemAudio: Bool? = nil, microphone: Bool? = nil, automaticZooms: Bool? = nil, browserContentOnly: Bool? = nil, frameRate: Int? = nil) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.automaticZooms = automaticZooms
        self.browserContentOnly = browserContentOnly
        self.frameRate = frameRate
    }
}

/// A library entry as listed to the model.
struct AIProjectSummary: Equatable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var duration: Double
    var createdAt: Date
    var sourceWidth: Int
    var sourceHeight: Int
    var zoomCount: Int
    var chapterCount: Int

    init(id: UUID, title: String, duration: Double, createdAt: Date, sourceWidth: Int, sourceHeight: Int, zoomCount: Int, chapterCount: Int) {
        self.id = id
        self.title = title
        self.duration = duration
        self.createdAt = createdAt
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.zoomCount = zoomCount
        self.chapterCount = chapterCount
    }

    init(project: RecordingProject) {
        self.init(
            id: project.id,
            title: project.title,
            duration: project.duration,
            createdAt: project.createdAt,
            sourceWidth: project.sourceWidth,
            sourceHeight: project.sourceHeight,
            zoomCount: project.zoomSegments.filter(\.isEnabled).count,
            chapterCount: project.chapters?.count ?? 0
        )
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

/// A bundled music track (from `AudioAssetCatalog`) resolved to a playable file.
struct AIMusicTrack: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var mood: String
    var durationSeconds: Double
    var suggestedVolume: Double
    var path: String

    init(id: String, title: String, mood: String = "", durationSeconds: Double = 0, suggestedVolume: Double = 0.2, path: String) {
        self.id = id
        self.title = title
        self.mood = mood
        self.durationSeconds = durationSeconds
        self.suggestedVolume = suggestedVolume
        self.path = path
    }

    init(asset: AudioAssetCatalog.Asset, path: String) {
        self.init(id: asset.id, title: asset.title, mood: asset.mood, durationSeconds: asset.durationSeconds,
                  suggestedVolume: asset.suggestedVolume, path: path)
    }
}

/// What the assistant may do to the app itself: pick a source and record,
/// browse and open the library, and look up bundled audio. `StudioModel`
/// conforms; tests use a fake. Every member runs on the main actor.
@MainActor
protocol AppControlling: AnyObject, Sendable {
    /// Refreshes the displays and windows from the OS and returns them.
    func refreshRecordingSources() async throws -> [AIRecordingSource]
    /// The sources from the last refresh.
    var recordingSources: [AIRecordingSource] { get }
    var recordingPhase: AIRecordingPhase { get }
    /// The error the app is currently showing the user, if any.
    var lastReportedError: String? { get }
    /// Selects the source, applies the options and starts the countdown.
    /// Throws when the app cannot start (unknown source, recording in progress).
    func startRecording(sourceID: String, options: AIRecordingOptions) throws
    /// Finishes the recording; on success the app opens the editor with the new project.
    func stopRecording() async
    /// Library entries, newest first.
    var projectSummaries: [AIProjectSummary] { get }
    /// The project shown in the editor, or nil when the editor is closed.
    var openProjectID: UUID? { get }
    func openProject(id: UUID) throws
    func closeEditor()
    var bundledMusicTracks: [AIMusicTrack] { get }
}

// MARK: - Shared helpers

extension AIToolSupport {
    static func requireApp(_ context: AIAssistantContext) throws -> any AppControlling {
        guard let app = context.app else { throw AIToolError.appUnavailable }
        return app
    }

    /// Polls `poll` on the main actor every `interval` until it returns a
    /// value, throws, or `timeout` passes (then returns nil). Cancellation propagates.
    static func waitOnMain<Value: Sendable>(
        timeout: TimeInterval,
        interval: TimeInterval = 0.1,
        _ poll: @escaping @MainActor @Sendable () throws -> Value?
    ) async throws -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            if let value = try await MainActor.run(body: poll) { return value }
            guard Date() < deadline else { return nil }
            try await Task.sleep(nanoseconds: UInt64(max(0.01, interval) * 1_000_000_000))
        }
    }

    static func projectLine(_ summary: AIProjectSummary, isOpen: Bool) -> String {
        var line = "\(summary.displayTitle) · \(seconds(summary.duration)) s · \(summary.sourceWidth)×\(summary.sourceHeight) · \(Self.dateFormatter.string(from: summary.createdAt)) · id \(summary.id.uuidString)"
        if isOpen { line += " · open in the editor" }
        return line
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// Zooms in time order with 1-based indexes, the numbering used by
    /// `remove_zoom` and the project summary.
    static func orderedZooms(_ project: RecordingProject) -> [(index: Int, position: Int, segment: ZoomSegment)] {
        project.zoomSegments.enumerated()
            .sorted { lhs, rhs in
                lhs.element.start == rhs.element.start ? lhs.offset < rhs.offset : lhs.element.start < rhs.element.start
            }
            .enumerated()
            .map { (index: $0.offset + 1, position: $0.element.offset, segment: $0.element.element) }
    }

    static func zoomLine(_ segment: ZoomSegment) -> String {
        var text = "\(seconds(segment.start))–\(seconds(segment.end)) s at (\(String(format: "%.2f", segment.targetX)), \(String(format: "%.2f", segment.targetY))) ×\(String(format: "%.2f", segment.scale)) \(segment.kind.rawValue)"
        if !segment.isEnabled { text += " (disabled)" }
        return text
    }
}

// MARK: - list_recording_sources

struct ListRecordingSourcesTool: AIAssistantTool {
    let name = "list_recording_sources"
    let summary = "Refresh and list what can be recorded: every display and every visible window with its id, app, title and size. Opens the recorder screen. Call it before start_recording unless the user named an exact source."

    static let maximumListedWindows = 40

    var parametersSchema: [String: Any] {
        ["type": "object", "properties": [String: Any]()]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let app = try AIToolSupport.requireApp(context)
        progress(L10n.tr("Finding screens and windows…"))
        let sources = try await app.refreshRecordingSources()
        guard !sources.isEmpty else {
            return AIToolResult(text: "No displays or windows are available. Screen Recording permission may be missing: System Settings › Privacy & Security › Screen Recording.")
        }
        let displays = sources.filter { $0.kind == .display }
        let windows = sources.filter { $0.kind == .window }.sorted { $0.area > $1.area }
        var lines = ["\(displays.count) displays, \(windows.count) windows"]
        lines.append(contentsOf: displays.map { "- " + $0.summaryLine })
        lines.append(contentsOf: windows.prefix(Self.maximumListedWindows).map { "- " + $0.summaryLine })
        if windows.count > Self.maximumListedWindows {
            lines.append("(\(windows.count - Self.maximumListedWindows) smaller windows omitted)")
        }
        return AIToolResult(text: lines.joined(separator: "\n"))
    }
}

// MARK: - start_recording

struct StartRecordingTool: AIAssistantTool {
    let name = "start_recording"
    let summary = "Select a display or window and start recording after the app's 3-second countdown. Optional capture settings apply to this recording. Returns once frames are being captured; call stop_recording to finish."

    /// How long the countdown plus capture start may take.
    var startTimeout: TimeInterval = 20

    init(startTimeout: TimeInterval = 20) {
        self.startTimeout = startTimeout
    }

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["source"],
            "properties": [
                "source": ["type": "string", "description": "A source id from list_recording_sources, an app name (e.g. Safari), part of a window title, or \"display\" for the main display (\"display 2\" for the second one)."],
                "system_audio": ["type": "boolean", "description": "Capture the Mac's audio output."],
                "microphone": ["type": "boolean"],
                "automatic_zooms": ["type": "boolean", "description": "Generate zooms from clicks and typing (default on)."],
                "browser_content_only": ["type": "boolean", "description": "Crop a browser window to its page content."],
                "frame_rate": ["type": "integer", "enum": [30, 60]],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let query = try arguments.requiredString("source")
        var options = AIRecordingOptions()
        for key in ["system_audio", "microphone", "automatic_zooms", "browser_content_only"] where arguments.has(key) {
            guard let value = arguments.bool(key) else { throw AIToolError.invalidArgument("\"\(key)\" must be true or false.") }
            switch key {
            case "system_audio": options.systemAudio = value
            case "microphone": options.microphone = value
            case "automatic_zooms": options.automaticZooms = value
            default: options.browserContentOnly = value
            }
        }
        if arguments.has("frame_rate") {
            guard let rate = arguments.int("frame_rate"), [30, 60].contains(rate) else {
                throw AIToolError.invalidArgument("\"frame_rate\" must be 30 or 60.")
            }
            options.frameRate = rate
        }

        let app = try AIToolSupport.requireApp(context)
        let phase = await app.recordingPhase
        switch phase {
        case .idle, .failed:
            break
        case .countdown, .recording, .stopping:
            throw AIToolError.failed("A recording is already \(phase.label). Call stop_recording first.")
        }
        var sources = await app.recordingSources
        if sources.isEmpty {
            progress(L10n.tr("Finding screens and windows…"))
            sources = try await app.refreshRecordingSources()
        }
        let source = try Self.resolveSource(query, in: sources)
        let requestedOptions = options
        try await MainActor.run { try app.startRecording(sourceID: source.id, options: requestedOptions) }

        progress(L10n.tr("Counting down…"))
        // The app reports `.countdown` from the moment startRecording returns, so
        // `.idle` while waiting means the countdown was cancelled or the capture failed.
        let outcome = try await AIToolSupport.waitOnMain(timeout: startTimeout) { () -> Result<Void, AIToolError>? in
            switch app.recordingPhase {
            case .recording:
                return .success(())
            case let .failed(message):
                return .failure(.failed("The recording could not start: \(message)"))
            case .countdown, .stopping:
                return nil
            case .idle:
                return .failure(.failed(app.lastReportedError ?? "The recording did not start (the countdown was cancelled)."))
            }
        }
        guard let outcome else {
            throw AIToolError.timedOut("The recording did not start within \(Int(startTimeout)) s. Check the app window.")
        }
        try outcome.get()
        var settings: [String] = []
        if let value = options.systemAudio { settings.append("system audio \(value ? "on" : "off")") }
        if let value = options.microphone { settings.append("microphone \(value ? "on" : "off")") }
        if let value = options.automaticZooms { settings.append("automatic zooms \(value ? "on" : "off")") }
        if let value = options.browserContentOnly { settings.append("browser content only \(value ? "on" : "off")") }
        if let value = options.frameRate { settings.append("\(value) fps") }
        var text = "Recording started (3-second countdown elapsed): \(source.summaryLine)."
        if !settings.isEmpty { text += " Settings: \(settings.joined(separator: ", "))." }
        text += " Call stop_recording when the demo is done."
        return AIToolResult(text: text)
    }

    /// Matches an id, a display request, an app name or a window title.
    static func resolveSource(_ query: String, in sources: [AIRecordingSource]) throws -> AIRecordingSource {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIToolError.invalidArgument("\"source\" must name a display, window or app.") }
        if let exact = sources.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) { return exact }

        let lowercased = trimmed.lowercased()
        let displays = sources.filter { $0.kind == .display }
        let displayWords: Set<String> = [
            "display", "screen", "main display", "main screen", "the display", "the screen", "desktop", "entire screen",
            "full screen", "fullscreen", "whole screen", "monitor", "屏幕", "显示器", "全屏", "桌面", "整个屏幕", "主屏幕", "主显示器",
        ]
        if displayWords.contains(lowercased) {
            guard let display = displays.first else { throw AIToolError.failed("No display is available to record.") }
            return display
        }
        if let match = lowercased.wholeMatch(of: #/(?:display|screen|monitor|显示器|屏幕)\s*#?\s*(\d+)/#),
           let number = Int(match.1) {
            guard number >= 1, number <= displays.count else {
                throw AIToolError.invalidArgument("There are \(displays.count) displays; \"\(trimmed)\" does not exist.")
            }
            return displays[number - 1]
        }

        let windows = sources.filter { $0.kind == .window }
        func largest(_ candidates: [AIRecordingSource]) -> AIRecordingSource? {
            candidates.max { $0.area < $1.area }
        }
        if let match = largest(windows.filter { ($0.appName ?? "").lowercased() == lowercased }) { return match }
        if let match = largest(windows.filter { $0.title.lowercased() == lowercased }) { return match }
        if let match = largest(windows.filter { $0.title.lowercased().contains(lowercased) }) { return match }
        if let match = largest(windows.filter { ($0.appName ?? "").lowercased().contains(lowercased) }) { return match }
        let tokens = lowercased.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
        if !tokens.isEmpty {
            let scored = windows.map { window -> (AIRecordingSource, Int) in
                let haystack = "\((window.appName ?? "").lowercased()) \(window.title.lowercased())"
                return (window, tokens.filter { haystack.contains($0) }.count)
            }.filter { $0.1 > 0 }
            if let best = scored.max(by: { lhs, rhs in lhs.1 == rhs.1 ? lhs.0.area < rhs.0.area : lhs.1 < rhs.1 }) {
                return best.0
            }
        }
        if let match = displays.first(where: { $0.title.lowercased().contains(lowercased) }) { return match }

        let available = (displays + windows.sorted { $0.area > $1.area }).prefix(8).map(\.summaryLine)
        throw AIToolError.invalidArgument("No source matches \"\(trimmed)\". Available: \(available.joined(separator: "; ")). Use list_recording_sources for the full list.")
    }
}

// MARK: - stop_recording

struct StopRecordingTool: AIAssistantTool {
    let name = "stop_recording"
    let summary = "Finish the current recording. The app saves it as a new project and opens it in the editor; returns the project id, title and duration."

    var stopTimeout: TimeInterval = 60

    init(stopTimeout: TimeInterval = 60) {
        self.stopTimeout = stopTimeout
    }

    var parametersSchema: [String: Any] {
        ["type": "object", "properties": [String: Any]()]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let app = try AIToolSupport.requireApp(context)
        var phase = await app.recordingPhase
        if phase == .countdown {
            // The countdown cannot be stopped as a recording; let it start first.
            progress(L10n.tr("Counting down…"))
            let started = try await AIToolSupport.waitOnMain(timeout: 8) { () -> Bool? in
                app.recordingPhase == .recording ? true : (app.recordingPhase == .countdown ? nil : false)
            }
            phase = await app.recordingPhase
            guard started == true else {
                throw AIToolError.failed("No recording is in progress (the countdown ended with: \(phase.label)).")
            }
        }
        guard phase == .recording else {
            throw AIToolError.failed("No recording is in progress (state: \(phase.label)).")
        }
        let previousProjectID = await app.openProjectID
        progress(L10n.tr("Preparing your editable recording…"))
        Task { @MainActor in await app.stopRecording() }
        let outcome = try await AIToolSupport.waitOnMain(timeout: stopTimeout) { () -> Result<AIProjectSummary, AIToolError>? in
            if let id = app.openProjectID, id != previousProjectID, app.recordingPhase != .stopping,
               let summary = app.projectSummaries.first(where: { $0.id == id }) {
                return .success(summary)
            }
            if case let .failed(message) = app.recordingPhase {
                return .failure(.failed("The recording could not be saved: \(message)"))
            }
            if app.recordingPhase == .idle, app.openProjectID == previousProjectID, let error = app.lastReportedError {
                return .failure(.failed("The recording could not be saved: \(error)"))
            }
            return nil
        }
        guard let outcome else {
            throw AIToolError.timedOut("The recording is still being saved after \(Int(stopTimeout)) s. Check the app window and call list_projects later.")
        }
        let project = try outcome.get()
        let text = "Recording saved as project \"\(project.displayTitle)\" (id \(project.id.uuidString), \(AIToolSupport.seconds(project.duration)) s, \(project.sourceWidth)×\(project.sourceHeight), \(project.zoomCount) automatic zooms). It is open in the editor."
        return AIToolResult(text: text)
    }
}

// MARK: - list_projects

struct ListProjectsTool: AIAssistantTool {
    let name = "list_projects"
    let summary = "List the recordings in the library, newest first, with id, title, duration and creation time."

    static let maximumListed = 30

    var parametersSchema: [String: Any] {
        ["type": "object", "properties": [String: Any]()]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let app = try AIToolSupport.requireApp(context)
        let (projects, openID) = await MainActor.run { (app.projectSummaries, app.openProjectID) }
        guard !projects.isEmpty else { return AIToolResult(text: "The library is empty. Record a demo with start_recording.") }
        var lines = ["\(projects.count) projects (newest first)"]
        for (index, project) in projects.prefix(Self.maximumListed).enumerated() {
            lines.append("\(index + 1). " + AIToolSupport.projectLine(project, isOpen: project.id == openID))
        }
        if projects.count > Self.maximumListed { lines.append("(\(projects.count - Self.maximumListed) older projects omitted)") }
        return AIToolResult(text: lines.joined(separator: "\n"))
    }
}

// MARK: - open_project

struct OpenProjectTool: AIAssistantTool {
    let name = "open_project"
    let summary = "Open a library project in the editor so the editing tools (zooms, chapters, look, music, export) apply to it."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["project"],
            "properties": [
                "project": ["type": "string", "description": "A project id from list_projects or part of its title (the newest match wins)."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let query = try AIToolArguments(raw).requiredString("project")
        let app = try AIToolSupport.requireApp(context)
        let projects = await app.projectSummaries
        let project = try Self.resolveProject(query, in: projects)
        try await MainActor.run { try app.openProject(id: project.id) }
        let opened = await app.projectSummaries.first { $0.id == project.id } ?? project
        return AIToolResult(text: "Opened \"\(opened.displayTitle)\" in the editor (\(AIToolSupport.seconds(opened.duration)) s, \(opened.zoomCount) zooms, \(opened.chapterCount) chapters, id \(opened.id.uuidString)).")
    }

    static func resolveProject(_ query: String, in projects: [AIProjectSummary]) throws -> AIProjectSummary {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIToolError.invalidArgument("\"project\" must be a project id or title.") }
        if let id = UUID(uuidString: trimmed) {
            guard let match = projects.first(where: { $0.id == id }) else { throw AIToolError.invalidArgument("No project has the id \(trimmed).") }
            return match
        }
        let lowercased = trimmed.lowercased()
        if let match = projects.first(where: { $0.title.lowercased() == lowercased }) { return match }
        if let match = projects.first(where: { $0.title.lowercased().contains(lowercased) }) { return match }
        let titles = projects.prefix(8).map { "\"\($0.displayTitle)\"" }.joined(separator: ", ")
        throw AIToolError.invalidArgument("No project matches \"\(trimmed)\". Projects: \(titles.isEmpty ? "none" : titles).")
    }
}

// MARK: - close_editor

struct CloseEditorTool: AIAssistantTool {
    let name = "close_editor"
    let summary = "Save the open project and return to the library."

    var parametersSchema: [String: Any] {
        ["type": "object", "properties": [String: Any]()]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let app = try AIToolSupport.requireApp(context)
        let closed: String? = await MainActor.run {
            guard let id = app.openProjectID else { return nil }
            let title = app.projectSummaries.first { $0.id == id }?.displayTitle ?? "the project"
            app.closeEditor()
            return title
        }
        guard let closed else { return AIToolResult(text: "The editor is not open; the library is showing.") }
        return AIToolResult(text: "Saved and closed \"\(closed)\". The library is showing.")
    }
}

// MARK: - add_zoom

struct AddZoomTool: AIAssistantTool {
    let name = "add_zoom"
    let summary = "Add a manual zoom to the open project: the camera moves to (x, y) on the recording between start and end seconds. Existing automatic zooms stay."

    static let minimumDuration = 0.2
    static let scaleRange = 1.1...3.0

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["start", "end", "x", "y"],
            "properties": [
                "start": ["type": "number", "description": "Seconds into the recording."],
                "end": ["type": "number", "description": "Seconds; at least 0.2 s after start."],
                "x": ["type": "number", "minimum": 0, "maximum": 1, "description": "Horizontal centre of the zoom, 0 = left edge, 1 = right edge."],
                "y": ["type": "number", "minimum": 0, "maximum": 1, "description": "Vertical centre, 0 = top, 1 = bottom."],
                "scale": ["type": "number", "minimum": 1.1, "maximum": 3, "description": "Magnification; default is the project's zoom scale."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let project = try await AIToolSupport.requireProject(context)
        func number(_ key: String) throws -> Double {
            guard arguments.has(key) else { throw AIToolError.invalidArgument("Missing required argument \"\(key)\".") }
            guard let value = arguments.double(key) else { throw AIToolError.invalidArgument("\"\(key)\" must be a number.") }
            return value
        }
        let start = try number("start")
        let end = try number("end")
        let x = try number("x")
        let y = try number("y")
        let duration = max(0, project.duration)
        guard start >= 0, end <= duration + 0.001 else {
            throw AIToolError.invalidArgument("start and end must lie within 0–\(AIToolSupport.seconds(duration)) s (got \(AIToolSupport.seconds(start))–\(AIToolSupport.seconds(end))).")
        }
        guard end - start >= Self.minimumDuration else {
            throw AIToolError.invalidArgument("end must be at least \(Self.minimumDuration) s after start.")
        }
        guard (0...1).contains(x), (0...1).contains(y) else {
            throw AIToolError.invalidArgument("x and y are normalized positions between 0 and 1 (0.5, 0.5 is the centre).")
        }
        var notes: [String] = []
        var scale = project.settings.zoomScale
        if arguments.has("scale") {
            guard let requested = arguments.double("scale") else { throw AIToolError.invalidArgument("\"scale\" must be a number.") }
            scale = requested.clamped(to: Self.scaleRange)
            if scale != requested { notes.append("scale clamped to \(String(format: "%.2f", scale))") }
        }
        let segment = ZoomSegment(start: start, end: min(end, duration), targetX: x, targetY: y, scale: scale, kind: .manual)
        let updated: (index: Int, count: Int)? = await MainActor.run {
            var index: Int?
            var count = 0
            context.updateProject { current in
                current.zoomSegments.append(segment)
                index = AIToolSupport.orderedZooms(current).first { $0.segment.id == segment.id }?.index
                count = current.zoomSegments.count
            }
            guard let index else { return nil }
            return (index, count)
        }
        guard let updated else { throw AIToolError.noProject }
        var text = "Added zoom #\(updated.index): \(AIToolSupport.zoomLine(segment)). The project now has \(updated.count) zooms."
        if !notes.isEmpty { text += " (\(notes.joined(separator: ", ")))" }
        return AIToolResult(text: text)
    }
}

// MARK: - remove_zoom

struct RemoveZoomTool: AIAssistantTool {
    let name = "remove_zoom"
    let summary = "Remove one zoom by its number (1-based, in time order as listed in the project summary) or all zooms."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["index"],
            "properties": [
                "index": ["type": ["integer", "string"], "description": "The zoom number, or \"all\"."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let project = try await AIToolSupport.requireProject(context)
        let ordered = AIToolSupport.orderedZooms(project)
        let rawIndex = arguments.string("index") ?? (arguments.bool("all") == true ? "all" : nil)
        guard let rawIndex else { throw AIToolError.invalidArgument("Missing required argument \"index\" (a zoom number or \"all\").") }
        if rawIndex.lowercased() == "all" {
            guard !ordered.isEmpty else { return AIToolResult(text: "The project has no zooms.") }
            await MainActor.run { context.updateProject { $0.zoomSegments.removeAll() } }
            return AIToolResult(text: "Removed all \(ordered.count) zooms. Automatic zooms return if the zoom style is regenerated; set autoZoomEnabled false to keep them off.")
        }
        guard let index = arguments.int("index") else { throw AIToolError.invalidArgument("\"index\" must be a zoom number or \"all\".") }
        guard let entry = ordered.first(where: { $0.index == index }) else {
            throw AIToolError.invalidArgument(ordered.isEmpty ? "The project has no zooms." : "Zoom #\(index) does not exist; the project has zooms 1–\(ordered.count).")
        }
        let id = entry.segment.id
        await MainActor.run { context.updateProject { $0.zoomSegments.removeAll { $0.id == id } } }
        return AIToolResult(text: "Removed zoom #\(index) (\(AIToolSupport.zoomLine(entry.segment))). \(ordered.count - 1) zooms remain.")
    }
}

// MARK: - set_zoom_style

struct SetZoomStyleTool: AIAssistantTool {
    let name = "set_zoom_style"
    let summary = "Tune how zooms move: screen animation, zoom scale, click hold, ease in/out durations, how nearby clicks are chained, and whether automatic zooms are on. Only the given keys change."

    static let allowedKeys = ["screenAnimation", "zoomScale", "zoomHold", "zoomEaseIn", "zoomEaseOut", "zoomChainGap", "autoZoomEnabled"]
    static let ranges: [String: ClosedRange<Double>] = [
        "zoomHold": 0.2...3,
        "zoomEaseIn": 0.05...1,
        "zoomEaseOut": 0.05...1.4,
        "zoomChainGap": 0...ProjectSettings.maximumZoomChainGap,
    ]

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "screenAnimation": ["type": "string", "enum": ScreenAnimationStyle.allCases.map(\.rawValue)],
                "zoomScale": ["type": "number", "minimum": 1.1, "maximum": 3, "description": "Default magnification for automatic zooms and new manual zooms."],
                "zoomHold": ["type": "number", "minimum": 0.2, "maximum": 3, "description": "Seconds an automatic zoom stays on a click."],
                "zoomEaseIn": ["type": "number", "minimum": 0.05, "maximum": 1, "description": "Seconds to zoom in."],
                "zoomEaseOut": ["type": "number", "minimum": 0.05, "maximum": 1.4, "description": "Seconds to zoom out."],
                "zoomChainGap": ["type": "number", "minimum": 0, "maximum": ProjectSettings.maximumZoomChainGap, "description": "Clicks closer than this many seconds pan within one zoom instead of zooming out."],
                "autoZoomEnabled": ["type": "boolean"],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let requested = raw.keys.filter { !(raw[$0] is NSNull) }
        let unknown = requested.filter { !Self.allowedKeys.contains($0) }
        guard unknown.isEmpty else {
            throw AIToolError.invalidArgument("Unknown keys \(unknown.sorted().joined(separator: ", ")). Allowed: \(Self.allowedKeys.joined(separator: ", ")).")
        }
        guard !requested.isEmpty else { throw AIToolError.invalidArgument("No zoom style keys given.") }
        _ = try await AIToolSupport.requireProject(context)

        var changes: [String] = []
        // Validate everything before touching the project so a bad call changes nothing.
        var numbers: [String: Double] = [:]
        for key in ["zoomHold", "zoomEaseIn", "zoomEaseOut", "zoomChainGap"] where arguments.has(key) {
            guard let value = arguments.double(key) else { throw AIToolError.invalidArgument("\"\(key)\" must be a number.") }
            let clamped = value.clamped(to: Self.ranges[key]!)
            numbers[key] = clamped
            changes.append("\(key) = \(UpdateSettingsTool.number(clamped))\(clamped == value ? "" : " (clamped)")")
        }
        var autoZoom: Bool?
        if arguments.has("autoZoomEnabled") {
            guard let value = arguments.bool("autoZoomEnabled") else { throw AIToolError.invalidArgument("\"autoZoomEnabled\" must be true or false.") }
            autoZoom = value
            changes.append("autoZoomEnabled = \(value)")
        }
        // Overlapping keys reuse update_settings (same validation and messages).
        let shared = raw.filter { ["screenAnimation", "zoomScale"].contains($0.key) && !($0.value is NSNull) }
        if !shared.isEmpty {
            changes.insert(contentsOf: try await UpdateSettingsTool.apply(arguments: shared, context: context), at: 0)
        }

        let values = numbers
        let requestedAutoZoom = autoZoom
        await MainActor.run {
            context.updateProject { project in
                if let hold = values["zoomHold"] {
                    let delta = hold - project.settings.zoomHold
                    project.settings.zoomHold = hold
                    TimelineMath.adjustAutomaticClickHold(in: &project, by: delta)
                }
                if let easeIn = values["zoomEaseIn"] { project.settings.zoomEaseIn = easeIn }
                if let easeOut = values["zoomEaseOut"] {
                    let delta = easeOut - project.settings.zoomEaseOut
                    project.settings.zoomEaseOut = easeOut
                    TimelineMath.adjustAutomaticHold(in: &project.zoomSegments, by: delta, duration: project.duration)
                }
                var regenerate = false
                if let gap = values["zoomChainGap"] {
                    project.settings.zoomChainGap = gap
                    regenerate = true
                }
                if let enabled = requestedAutoZoom {
                    let wasEnabled = project.settings.autoZoomEnabled
                    project.settings.autoZoomEnabled = enabled
                    if enabled, !wasEnabled || !project.zoomSegments.contains(where: { $0.kind == .automatic }) { regenerate = true }
                }
                if regenerate, project.settings.autoZoomEnabled {
                    TimelineMath.regenerateAutomaticZoomSegments(in: &project)
                }
            }
        }
        let count = await MainActor.run { context.readProject()?.zoomSegments.filter(\.isEnabled).count ?? 0 }
        return AIToolResult(text: L10n.format("Updated %@", changes.joined(separator: ", ")) + " · \(count) zooms")
    }
}

// MARK: - set_background_music

struct SetBackgroundMusicTool: AIAssistantTool {
    let name = "set_background_music"
    let summary = "Set the open project's background music to a bundled track (by id or title, see the bundled list in the project summary), to a local audio file, or to \"none\" to remove it. Optional volume 0–1 (the track's suggested level by default)."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["track"],
            "properties": [
                "track": ["type": "string", "description": "Bundled track id or title, a local audio file path, or \"none\"."],
                "volume": ["type": "number", "minimum": 0, "maximum": 1],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let query = try arguments.requiredString("track")
        _ = try await AIToolSupport.requireProject(context)
        var volume: Double?
        if arguments.has("volume") {
            guard let value = arguments.double("volume") else { throw AIToolError.invalidArgument("\"volume\" must be a number between 0 and 1.") }
            volume = value.clamped(to: 0...1)
        }
        let lowercased = query.lowercased()
        if ["none", "off", "remove", "no music", "silence", "无", "关闭"].contains(lowercased) {
            await MainActor.run {
                context.updateProject { project in
                    var audio = project.settings.resolvedProductDemoAudio
                    audio.backgroundMusicPath = nil
                    project.settings.productDemoAudio = audio
                }
            }
            return AIToolResult(text: "Background music removed.")
        }

        let tracks = await Self.availableTracks(context)
        let track: AIMusicTrack
        if let bundled = Self.resolveTrack(query, in: tracks) {
            track = bundled
        } else if case let .local(url) = AIToolPaths.reference(query, context: context), FileManager.default.fileExists(atPath: url.path) {
            guard AIToolPaths.kind(of: url) == .audio else { throw AIToolError.invalidArgument("\(url.lastPathComponent) is not an audio file.") }
            track = AIMusicTrack(id: url.path, title: url.deletingPathExtension().lastPathComponent, suggestedVolume: 0.22, path: url.path)
        } else {
            let names = tracks.map { "\($0.title) (\($0.id))" }.joined(separator: ", ")
            throw AIToolError.invalidArgument("No bundled track or audio file matches \"\(query)\". Bundled tracks: \(names.isEmpty ? "none" : names). Or use \"none\".")
        }
        let level = volume ?? track.suggestedVolume
        await MainActor.run {
            context.updateProject { project in
                var audio = project.settings.resolvedProductDemoAudio
                audio.backgroundMusicPath = track.path
                audio.backgroundMusicVolume = level
                project.settings.productDemoAudio = audio
            }
        }
        return AIToolResult(text: "Background music set to \"\(track.title)\" at volume \(String(format: "%.2f", level)).")
    }

    static func availableTracks(_ context: AIAssistantContext) async -> [AIMusicTrack] {
        if let app = context.app {
            let tracks = await app.bundledMusicTracks
            if !tracks.isEmpty { return tracks }
        }
        guard let catalog = try? AudioAssetCatalog.loadBundled() else { return [] }
        return catalog.music.map { AIMusicTrack(asset: $0, path: catalog.fileURL(for: $0).path) }
    }

    static func resolveTrack(_ query: String, in tracks: [AIMusicTrack]) -> AIMusicTrack? {
        let lowercased = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowercased.isEmpty else { return nil }
        if let match = tracks.first(where: { $0.id.lowercased() == lowercased }) { return match }
        if let match = tracks.first(where: { $0.title.lowercased() == lowercased }) { return match }
        let compact = lowercased.replacingOccurrences(of: " ", with: "-")
        if let match = tracks.first(where: { $0.id.lowercased() == compact }) { return match }
        if let match = tracks.first(where: { $0.title.lowercased().contains(lowercased) }) { return match }
        return tracks.first { $0.mood.lowercased().contains(lowercased) }
    }
}

// MARK: - set_sound_effects

struct SetSoundEffectsTool: AIAssistantTool {
    let name = "set_sound_effects"
    let summary = "Turn the open project's click confirmation sound and zoom whoosh on or off, optionally with volumes 0–1."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "click": ["type": "boolean", "description": "Play a click sound on every recorded click."],
                "zoom": ["type": "boolean", "description": "Play a whoosh on zoom transitions."],
                "click_volume": ["type": "number", "minimum": 0, "maximum": 1],
                "zoom_volume": ["type": "number", "minimum": 0, "maximum": 1],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        _ = try await AIToolSupport.requireProject(context)
        var click: Bool?
        var zoom: Bool?
        var clickVolume: Double?
        var zoomVolume: Double?
        for key in ["click", "zoom"] where arguments.has(key) {
            guard let value = arguments.bool(key) else { throw AIToolError.invalidArgument("\"\(key)\" must be true or false.") }
            if key == "click" { click = value } else { zoom = value }
        }
        for key in ["click_volume", "zoom_volume"] where arguments.has(key) {
            guard let value = arguments.double(key) else { throw AIToolError.invalidArgument("\"\(key)\" must be a number between 0 and 1.") }
            if key == "click_volume" { clickVolume = value.clamped(to: 0...1) } else { zoomVolume = value.clamped(to: 0...1) }
        }
        guard click != nil || zoom != nil || clickVolume != nil || zoomVolume != nil else {
            throw AIToolError.invalidArgument("Give at least one of click, zoom, click_volume, zoom_volume.")
        }
        let requested = (click: click, zoom: zoom, clickVolume: clickVolume, zoomVolume: zoomVolume)
        let resolved = await MainActor.run { () -> ProductDemoAudioSettings? in
            var result: ProductDemoAudioSettings?
            context.updateProject { project in
                var audio = project.settings.resolvedProductDemoAudio
                if let click = requested.click { audio.clickSoundEnabled = click }
                if let zoom = requested.zoom { audio.zoomTransitionSoundEnabled = zoom }
                if let clickVolume = requested.clickVolume { audio.clickSoundVolume = clickVolume }
                if let zoomVolume = requested.zoomVolume { audio.zoomTransitionSoundVolume = zoomVolume }
                project.settings.productDemoAudio = audio
                result = audio
            }
            return result
        }
        guard let resolved else { throw AIToolError.noProject }
        return AIToolResult(text: "Sound effects: click \(resolved.clickSoundEnabled ? "on" : "off") (volume \(String(format: "%.2f", resolved.clickSoundVolume))), zoom whoosh \(resolved.zoomTransitionSoundEnabled ? "on" : "off") (volume \(String(format: "%.2f", resolved.zoomTransitionSoundVolume))).")
    }
}

// MARK: - export_project

struct ExportProjectTool: AIAssistantTool {
    let name: String
    let summary: String

    init() {
        self.init(name: "export_project", summary: "Render the open project with its look, zooms, captions and audio to an MP4. Default location: export-<timestamp>.mp4 in the assets folder; an optional path may name a file (.mp4) or a folder.")
    }

    init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Optional output file or folder; ~ is expanded, a bare name lands in the assets folder."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let project = try await AIToolSupport.requireProject(context)
        let output = try Self.resolveOutputURL(path: AIToolArguments(raw).string("path"), context: context)
        progress(L10n.tr("Exporting…"))
        let result = try await ProjectVideoRenderer.export(project: project, to: output)
        let text = L10n.format("Exported %@ (%@ s, %lld × %lld)", output.lastPathComponent, AIToolSupport.seconds(result.duration), result.width, result.height)
        return AIToolResult(text: text + "\n" + output.path, attachments: [output])
    }

    /// Nil → a fresh `export-<timestamp>.mp4` in the assets folder. A folder
    /// (existing directory or trailing slash) gets that default name inside it;
    /// a file name gets an `.mp4` extension when it lacks one.
    static func resolveOutputURL(path: String?, context: AIAssistantContext, date: Date = Date()) throws -> URL {
        guard let raw = path?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return try context.newAssetURL(prefix: "export", fileExtension: "mp4", date: date)
        }
        guard case let .local(url) = AIToolPaths.reference(raw, context: context) else {
            throw AIToolError.invalidArgument("\"path\" must be a local file or folder path.")
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if raw.hasSuffix("/") || (exists && isDirectory.boolValue) {
            var folderContext = context
            folderContext.assetsDirectory = url
            return try folderContext.newAssetURL(prefix: "export", fileExtension: "mp4", date: date)
        }
        if url.pathExtension.lowercased() == "mp4" { return url }
        if url.pathExtension.isEmpty { return url.appendingPathExtension("mp4") }
        return url.deletingPathExtension().appendingPathExtension("mp4")
    }
}
