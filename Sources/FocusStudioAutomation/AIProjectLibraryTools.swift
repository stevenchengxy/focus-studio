import FocusStudioCore
import Foundation
import UniformTypeIdentifiers

// Library tools for external clients: new projects from existing files, and
// renaming or trashing a project. Each goes through the same app action as
// the library's buttons. They are not in `AIAssistantToolCatalog.standard`;
// the in-app assistant leaves the library to the person using it.

extension AIToolSupport {
    /// The optional "title" of a new project, trimmed; nil when absent. The
    /// app checks the length like the library's Rename does.
    static func optionalTitle(_ arguments: AIToolArguments) throws -> String? {
        guard arguments.has("title") else { return nil }
        guard let title = arguments.string("title") else {
            throw AIToolError.invalidArgument("\"title\" must be a non-empty string (or left out for the default).")
        }
        return title
    }

    /// The project a library tool acts on: its `project_id` argument, else
    /// the project the call is pinned to. Never the open project by default,
    /// so a missing id can never rename or trash the wrong one.
    static func libraryProjectID(_ arguments: AIToolArguments, context: AIAssistantContext) throws -> UUID {
        if let raw = arguments.string("project_id") {
            guard let id = UUID(uuidString: raw) else {
                throw AIToolError.invalidArgument("\"project_id\" must be a project id from list_projects (got \"\(raw)\").")
            }
            return id
        }
        if let pinned = context.projectID { return pinned }
        throw AIToolError.invalidArgument("Missing required argument \"project_id\" (a project id from list_projects).")
    }

    /// The result of a tool that created a project and opened it.
    static func newProjectResult(_ project: RecordingProject, verb: String, source: URL, app: any AppControlling, context: AIAssistantContext) async -> AIToolResult {
        let (isOpen, library) = await MainActor.run { (app.openProjectID == project.id, app.libraryDirectory) }
        let summary = AIProjectSummary(project: project)
        var text = "\(verb) \"\(summary.displayTitle)\" as project \(project.id.uuidString) (\(seconds(project.duration)) s, \(project.sourceWidth)×\(project.sourceHeight))."
        if isOpen { text += " It is open in the editor." }
        let assets = AIProjectReport.assetsDirectory(for: project, libraryRoot: context.projectsDirectory ?? library)
        let data = merged(AIProjectReport.summaryData(summary, isOpen: isOpen), [
            "project_id": AIJSONValue(project.id.uuidString),
            "source": AIJSONValue(source),
            "assets_dir": assets.map { AIJSONValue($0) } ?? .null,
        ])
        return AIToolResult(text: text, data: data)
    }
}

// MARK: - import_video

/// A video file as a new project, opened in the editor like Import video.
struct ImportVideoTool: AIAssistantTool {
    let name = "import_video"
    let summary = "Import a video file (.mp4, .mov or .m4v) as a new library project and open it in the editor. The file is copied into the library; the original stays where it is."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["path"],
            "properties": [
                "path": ["type": "string", "description": "The video file."],
                "title": ["type": "string", "description": "The project's title; the file name by default. At most 120 characters."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let url = try AIToolPaths.existingLocalFile(try arguments.requiredString("path"), context: context)
        guard UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .movie) == true else {
            throw AIToolError.invalidArgument("\(url.lastPathComponent) is not a video file; import_video takes .mp4, .mov or .m4v.")
        }
        let title = try AIToolSupport.optionalTitle(arguments)
        let app = try AIToolSupport.requireApp(context)
        progress(context.tr("Importing video…"))
        let project = try await AIToolSupport.appAction(context) { try await app.importVideo(from: url, title: title) }
        return await AIToolSupport.newProjectResult(project, verb: "Imported", source: url, app: app, context: context)
    }
}

// MARK: - create_screenshot_demo

/// A screenshot as an editable demo project, like Animate screenshot.
struct CreateScreenshotDemoTool: AIAssistantTool {
    let name = "create_screenshot_demo"
    let summary = "Turn a PNG or JPEG screenshot into an editable demo project (a 12-second still video with a gentle camera move and no automatic zooms) and open it in the editor. Add zooms and chapters afterwards."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["path"],
            "properties": [
                "path": ["type": "string", "description": "The PNG or JPEG screenshot."],
                "title": ["type": "string", "description": "The project's title; \"<file name> Demo\" by default. At most 120 characters."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let url = try AIToolPaths.existingLocalFile(try arguments.requiredString("path"), context: context)
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        guard type?.conforms(to: .png) == true || type?.conforms(to: .jpeg) == true else {
            throw AIToolError.invalidArgument("\(url.lastPathComponent) is not a PNG or JPEG screenshot.")
        }
        guard ArkMediaClient.imagePixelSize(at: url) != nil else {
            throw AIToolError.invalidArgument("\(url.lastPathComponent) is not a readable image.")
        }
        let title = try AIToolSupport.optionalTitle(arguments)
        let app = try AIToolSupport.requireApp(context)
        progress(context.tr("Turning the screenshot into an editable demo…"))
        let project = try await AIToolSupport.appAction(context) { try await app.importScreenshotDemo(from: url, title: title) }
        return await AIToolSupport.newProjectResult(project, verb: "Created a demo from the screenshot", source: url, app: app, context: context)
    }
}

// MARK: - rename_project

/// A new title for a library project, through the library's Rename.
struct RenameProjectTool: AIAssistantTool {
    let name = "rename_project"
    let summary = "Rename a library project. Only its title changes; its folder and files keep their names. The app shows the library while it renames."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["project_id", "title"],
            "properties": [
                "project_id": ["type": "string", "description": "A project id from list_projects."],
                "title": ["type": "string", "description": "The new title, at most 120 characters."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let id = try AIToolSupport.libraryProjectID(arguments, context: context)
        guard arguments.has("title") else { throw AIToolError.invalidArgument("Missing required argument \"title\".") }
        // A blank title reaches the app, which explains the rule in its own words.
        let title = (raw["title"] as? String) ?? arguments.string("title") ?? ""
        let app = try AIToolSupport.requireApp(context)
        let (before, wasOpen) = await MainActor.run { (app.project(id: id), app.openProjectID != nil) }
        guard let before else {
            throw AIToolError.invalidArgument("No project has the id \(id.uuidString). Call list_projects for the current ids.")
        }
        let renamed = try await AIToolSupport.appAction(context) { try await app.renameLibraryProject(id: id, to: title) }
        var text = "Renamed \"\(AIProjectSummary(project: before).displayTitle)\" to \"\(renamed.title)\" (project \(id.uuidString))."
        if wasOpen { text += " The editor was saved and closed; the library is showing." }
        let data: AIJSONValue = [
            "project_id": AIJSONValue(id.uuidString),
            "title": AIJSONValue(renamed.title),
            "previous_title": AIJSONValue(before.title),
            "closed_editor": AIJSONValue(wasOpen),
        ]
        return AIToolResult(text: text, data: data)
    }
}

// MARK: - delete_project

/// A library project moved to the Trash, through the library's Move to Trash.
struct DeleteProjectTool: AIAssistantTool {
    let name = "delete_project"
    let summary = "Move a library project's folder (its recording, settings and generated media) to the Trash, where it can be restored. Nothing is deleted permanently. The app shows the library while it does this."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["project_id"],
            "properties": [
                "project_id": ["type": "string", "description": "A project id from list_projects."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let id = try AIToolSupport.libraryProjectID(AIToolArguments(raw), context: context)
        let app = try AIToolSupport.requireApp(context)
        let (known, openID) = await MainActor.run { (app.project(id: id), app.openProjectID) }
        guard known != nil else {
            throw AIToolError.invalidArgument("No project has the id \(id.uuidString); it may be in the Trash already. Call list_projects for the current ids.")
        }
        let trashed = try await AIToolSupport.appAction(context) { try await app.trashLibraryProject(id: id) }
        let remaining = await app.projectSummaries.count
        let title = AIProjectSummary(project: trashed).displayTitle
        var text = "Moved \"\(title)\" (project \(id.uuidString)) to the Trash; it can be restored from the Trash in Finder. \(remaining) projects remain in the library."
        if openID == id {
            text += " It was open in the editor, which was saved and closed first."
        } else if openID != nil {
            text += " The editor was saved and closed; the library is showing."
        }
        let data: AIJSONValue = [
            "project_id": AIJSONValue(id.uuidString),
            "title": AIJSONValue(trashed.title),
            "moved_to_trash": true,
            "closed_editor": AIJSONValue(openID != nil),
            "library_count": AIJSONValue(remaining),
        ]
        return AIToolResult(text: text, data: data)
    }
}
