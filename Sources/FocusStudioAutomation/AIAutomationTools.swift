import FocusStudioCore
import Foundation

// Read-only tools for external clients. The in-app assistant sees the same
// information in the [App] and [Project] blocks of every prompt, so these are
// not in `AIAssistantToolCatalog.standard`.

// MARK: - get_project

/// A library project in full, read without opening it in the editor.
public struct GetProjectTool: AIAssistantTool {
    public let name = "get_project"
    public let summary = "Describe one library project without opening it: title, duration, source size, look, zoom style, audio and export settings, the zooms with their ids (the first 100 in time order, with zoom_count), the chapters (the first 50, with chapter_count; long text is shortened with …), and the recorded clicks and typing moments (at most 200 of each, spread evenly over the recording, with their totals; times in seconds; positions 0–1 from the top-left corner)."

    public init() {}

    public var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "project_id": ["type": "string", "description": "A project id from list_projects."],
            ],
        ]
    }

    public func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let app = try AIToolSupport.requireApp(context)
        let requested = try await Self.projectID(AIToolArguments(raw), context: context, app: app)
        let (found, openID, tracks, library) = await MainActor.run {
            (app.project(id: requested), app.openProjectID, app.bundledMusicTracks, app.libraryDirectory)
        }
        guard let project = found else {
            throw AIToolError.invalidArgument("No project has the id \(requested.uuidString). Call list_projects for the current ids.")
        }
        let isOpen = openID == project.id
        let assets = AIProjectReport.assetsDirectory(for: project, libraryRoot: context.projectsDirectory ?? library)
        let title = AIProjectSummary(project: project).displayTitle
        var lines = ["Project \"\(title)\" (id \(project.id.uuidString), \(isOpen ? "open in the editor" : "not open in the editor"))"]
        lines.append(AIProjectReport.summary(of: project, assetsDirectory: assets ?? context.assetsDirectory))
        lines.append("Recorded input: \(project.clickEvents.count) clicks, \((project.typingActivity ?? []).count) typing moments. The structured result lists up to 200 of each, sampled evenly, and the first 100 zooms with their ids.")
        let data = AIProjectReport.data(of: project, isOpen: isOpen, assetsDirectory: assets, musicTracks: tracks)
        return AIToolResult(text: lines.joined(separator: "\n"), data: data)
    }

    /// The `project_id` argument, else the project the call is pinned to,
    /// else the project open in the editor.
    static func projectID(_ arguments: AIToolArguments, context: AIAssistantContext, app: any AppControlling) async throws -> UUID {
        if let raw = arguments.string("project_id") {
            guard let id = UUID(uuidString: raw) else {
                throw AIToolError.invalidArgument("\"project_id\" must be a project id from list_projects (got \"\(raw)\").")
            }
            return id
        }
        if let pinned = context.projectID { return pinned }
        if let open = await app.openProjectID { return open }
        throw AIToolError.invalidArgument("Missing required argument \"project_id\" (a project id from list_projects).")
    }
}

// MARK: - get_status

/// What the app is doing and what it may do: version, recording state, the
/// open project, the library size, permissions and the bundled music.
public struct GetStatusTool: AIAssistantTool {
    public let name = "get_status"
    public let summary = "Report Focus Studio's state: version, whether it is counting down or recording (and for how long), which project is open in the editor, how many projects the library has, which permissions are granted (Screen Recording, Accessibility, Input Monitoring) and the bundled music tracks."

    public init() {}

    public var parametersSchema: [String: Any] {
        ["type": "object", "properties": [String: Any]()]
    }

    public func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let app = try AIToolSupport.requireApp(context)
        let (phase, elapsed, openID, projectCount, permissions, tracks) = await MainActor.run {
            (app.recordingPhase, app.recordingElapsed, app.openProjectID, app.projectSummaries.count, app.permissionStatus, app.bundledMusicTracks)
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        var lines = ["Focus Studio \(version ?? "(version unknown)")\(build.map { " (build \($0))" } ?? "")"]
        var recording = "Recording: \(phase.label)"
        if phase == .recording, let elapsed { recording += " for \(AIToolSupport.seconds(elapsed)) s" }
        lines.append(recording)
        lines.append(openID.map { "Editor: project \($0.uuidString) is open" } ?? "Editor: closed (library showing)")
        lines.append("Library: \(projectCount) projects")
        func granted(_ value: Bool) -> String { value ? "granted" : "missing" }
        lines.append("Permissions: Screen Recording \(granted(permissions.screenRecording)), Accessibility \(granted(permissions.accessibility)), Input Monitoring \(granted(permissions.inputMonitoring))")
        if !permissions.screenRecording {
            lines.append("Recording needs Screen Recording permission: System Settings › Privacy & Security › Screen Recording, then relaunch Focus Studio.")
        }
        if !tracks.isEmpty {
            lines.append("Bundled music: " + tracks.map { "\($0.title) (\($0.id))" }.joined(separator: ", "))
        }

        var failure = AIJSONValue.null
        if case let .failed(message) = phase { failure = AIJSONValue(message) }
        let data: AIJSONValue = [
            "app": [
                "name": "Focus Studio",
                "version": version.map { AIJSONValue($0) } ?? .null,
                "build": build.map { AIJSONValue($0) } ?? .null,
                "path": AIJSONValue(Bundle.main.bundlePath),
            ],
            "recording": [
                "state": AIJSONValue(phase.code),
                "elapsed": phase == .recording ? elapsed.map { AIJSONValue.rounded($0, places: 1) } ?? .null : .null,
                "error": failure,
            ],
            "open_project_id": openID.map { AIJSONValue($0.uuidString) } ?? .null,
            "library_count": AIJSONValue(projectCount),
            "permissions": [
                "screen_recording": AIJSONValue(permissions.screenRecording),
                "accessibility": AIJSONValue(permissions.accessibility),
                "input_monitoring": AIJSONValue(permissions.inputMonitoring),
            ],
            "music_tracks": .array(tracks.map { track in
                [
                    "id": AIJSONValue(track.id),
                    "title": AIJSONValue(track.title),
                    "mood": AIJSONValue(track.mood),
                    "duration": .rounded(track.durationSeconds, places: 1),
                    "suggested_volume": .rounded(track.suggestedVolume, places: 2),
                ]
            }),
        ]
        return AIToolResult(text: lines.joined(separator: "\n"), data: data)
    }
}
