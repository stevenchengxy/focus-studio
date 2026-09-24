import Foundation

/// How an MCP tool relates to projects, which decides what the app does
/// before it runs the tool.
public enum MCPToolScope: String, Sendable {
    /// No project: status, the library list, recording, imports, waiting.
    case global
    /// Edits or renders one project (`project_id`), which the app first opens
    /// in its editor so the person using it sees each change.
    case project
    /// Reads one project (`project_id`) without opening it.
    case projectReadOnly = "project-readonly"
    /// Renames or trashes one library project (`project_id`); the tool shows
    /// the library itself, as those actions live there.
    case library
}

/// MCP tool annotations: hints a client uses to decide how carefully to
/// treat a call. None of these tools reach outside the Mac.
public struct MCPToolAnnotations: Equatable, Sendable {
    public var readOnly: Bool
    public var destructive: Bool
    public var idempotent: Bool
    public var openWorld: Bool

    public init(readOnly: Bool, destructive: Bool = false, idempotent: Bool = false, openWorld: Bool = false) {
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
        self.openWorld = openWorld
    }

    /// A tool that changes nothing.
    public static let reads = MCPToolAnnotations(readOnly: true, idempotent: true)

    /// MCP's `ToolAnnotations`. The destructive and idempotent hints only
    /// mean something for a tool that writes, so a read-only tool omits them.
    public func json(title: String) -> AIJSONValue {
        var fields: [String: AIJSONValue] = ["title": AIJSONValue(title), "readOnlyHint": AIJSONValue(readOnly), "openWorldHint": AIJSONValue(openWorld)]
        if !readOnly {
            fields["destructiveHint"] = AIJSONValue(destructive)
            fields["idempotentHint"] = AIJSONValue(idempotent)
        }
        return .object(fields)
    }
}

/// One tool as external clients see it: the shared tool that runs it, the
/// description and schema written for a caller outside the app, and what the
/// app must do around the call.
public struct MCPToolSpec: Sendable {
    public let name: String
    public let title: String
    public let description: String
    /// JSON Schema of the arguments, `project_id` included where it applies.
    public let inputSchema: AIJSONValue
    public let annotations: MCPToolAnnotations
    public let scope: MCPToolScope
    /// Whether `project_id` is required (it is optional for list_assets and
    /// assemble_video, and absent for global tools).
    public let requiresProjectID: Bool
    /// The result carries the image the tool wrote as an inline JPEG.
    public let returnsImage: Bool
    /// The app shows something else for the call: a project in the editor,
    /// the library, the recorder or a new project. Such calls run one at a
    /// time (``AutomationCallQueue``) so parallel calls never switch the
    /// editor under each other; reads run at once.
    public let navigates: Bool
    /// The shared tool that runs the call; nil for wait_for_job, which the
    /// automation layer answers itself.
    public let tool: (any AIAssistantTool)?

    /// Whether the tool takes a `project_id`.
    public var acceptsProjectID: Bool { scope != .global }

    /// A spec for `tool`: its schema with `project_id` added for any scope
    /// but global (required unless `requiresProjectID` is false) and the
    /// given property descriptions replaced for callers outside the app.
    /// `navigates` defaults to true for project and library scopes and for
    /// global tools that write, false otherwise.
    public init(
        tool: any AIAssistantTool,
        title: String,
        description: String,
        scope: MCPToolScope,
        requiresProjectID: Bool? = nil,
        annotations: MCPToolAnnotations,
        returnsImage: Bool = false,
        navigates: Bool? = nil,
        propertyDescriptions: [String: String] = [:]
    ) {
        let required = scope == .global ? false : (requiresProjectID ?? true)
        let base = AIJSONValue(jsonObject: tool.parametersSchema) ?? ["type": "object", "properties": [:]]
        self.init(
            name: tool.name, title: title, description: description,
            inputSchema: Self.schema(base, scope: scope, requiresProjectID: required, descriptions: propertyDescriptions),
            annotations: annotations, scope: scope, requiresProjectID: required, returnsImage: returnsImage,
            navigates: navigates ?? Self.navigatesByDefault(scope: scope, annotations: annotations), tool: tool
        )
    }

    init(
        name: String, title: String, description: String, inputSchema: AIJSONValue, annotations: MCPToolAnnotations,
        scope: MCPToolScope, requiresProjectID: Bool, returnsImage: Bool, navigates: Bool, tool: (any AIAssistantTool)?
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.scope = scope
        self.requiresProjectID = requiresProjectID
        self.returnsImage = returnsImage
        self.navigates = navigates
        self.tool = tool
    }

    private static func navigatesByDefault(scope: MCPToolScope, annotations: MCPToolAnnotations) -> Bool {
        switch scope {
        case .project, .library: return true
        case .projectReadOnly: return false
        case .global: return !annotations.readOnly
        }
    }

    /// The argument names the schema declares, sorted.
    public var argumentNames: [String] {
        (inputSchema["properties"]?.objectValue?.keys).map { $0.sorted() } ?? []
    }

    /// Names a tool takes without declaring them: aliases for what another
    /// tool returns (add_zoom answers with a zoom_id).
    static let undeclaredArgumentAliases: [String: Set<String>] = ["remove_zoom": ["zoom_id"]]

    /// The names in `arguments` the tool does not take, sorted; null values
    /// are ignored. Such an argument would otherwise be dropped unnoticed.
    public func unknownArgumentNames(in arguments: [String: AIJSONValue]) -> [String] {
        let known = Set(argumentNames).union(Self.undeclaredArgumentAliases[name] ?? [])
        return arguments.filter { key, value in value != .null && !known.contains(key) }.keys.sorted()
    }

    /// The `tools/list` entry: name, title, description, inputSchema and annotations.
    public var descriptor: AIJSONValue {
        [
            "name": AIJSONValue(name),
            "title": AIJSONValue(title),
            "description": AIJSONValue(description),
            "inputSchema": inputSchema,
            "annotations": annotations.json(title: title),
        ]
    }

    /// No `format` keyword: clients differ on which formats they accept
    /// (some reject `uuid`), so the description says what the id is.
    static let projectIDProperty: AIJSONValue = [
        "type": "string",
        "description": "The project's id (a UUID), from list_projects, stop_recording, import_video or create_screenshot_demo.",
    ]

    private static func schema(_ base: AIJSONValue, scope: MCPToolScope, requiresProjectID: Bool, descriptions: [String: String]) -> AIJSONValue {
        guard case var .object(schema) = base else { return base }
        var properties = schema["properties"]?.objectValue ?? [:]
        for (key, text) in descriptions {
            guard case var .object(property)? = properties[key] else { continue }
            property["description"] = AIJSONValue(text)
            properties[key] = .object(property)
        }
        var required = (schema["required"]?.arrayValue ?? []).filter { $0 != "project_id" }
        // AIJSONValue takes nil literals too, so keys are removed explicitly.
        if scope == .global {
            properties.removeValue(forKey: "project_id")
        } else {
            properties["project_id"] = projectIDProperty
            if requiresProjectID { required.insert("project_id", at: 0) }
        }
        schema["type"] = "object"
        schema["properties"] = .object(properties)
        if required.isEmpty {
            schema.removeValue(forKey: "required")
        } else {
            schema["required"] = .array(required)
        }
        return .object(schema)
    }
}

/// The tools Focus Studio offers MCP clients (Claude Code, Codex), with the
/// server instructions. Transport independent: the helper lists these and the
/// app runs them.
public struct MCPToolCatalog: Sendable {
    public static let waitForJobName = "wait_for_job"

    /// In-app tools deliberately not offered: paid generation (not in v1),
    /// pacing clients do themselves, an alias, and pure navigation (editing
    /// tools open their project anyway; revealing a file steals focus).
    public static let withheldToolNames = [
        "generate_image", "generate_video", "wait", "export_demo", "reveal_in_finder", "open_project", "close_editor",
    ]

    public let tools: [MCPToolSpec]

    public init(tools: [MCPToolSpec]) {
        self.tools = tools
    }

    public func tool(named name: String) -> MCPToolSpec? {
        tools.first { $0.name == name }
    }

    /// The `tools` array of a `tools/list` result.
    public var descriptors: AIJSONValue {
        .array(tools.map(\.descriptor))
    }

    // MARK: - v1

    /// destructiveHint marks a call that can lose something the same tool
    /// cannot simply set back: zooms and chapters it removes or replaces,
    /// automatic zooms a new zoom style regenerates, many settings changed at
    /// once (update_settings), and existing files an export or assembly
    /// replaces with overwrite: true. A tool that sets one project setting the
    /// same tool can set back (background image, music, sound effects) is not
    /// destructive. Clients such as Codex run non-destructive, closed-world
    /// calls without asking the person.
    public static let v1 = MCPToolCatalog(tools: [
        // Status and the library.
        MCPToolSpec(
            tool: GetStatusTool(), title: "Get status",
            description: "Report Focus Studio's state: its version, whether it is counting down or recording (and for how many seconds), which project is open in the editor, how many projects the library has, which macOS permissions it holds (Screen Recording is needed to record; Accessibility and Input Monitoring give automatic zooms on clicks and typing) and the bundled music tracks with their ids for set_background_music. Call it first to check that recording will work.",
            scope: .global, annotations: .reads
        ),
        MCPToolSpec(
            tool: ListProjectsTool(), title: "List projects",
            description: "List the library's projects, newest first, each with its project_id, title, duration in seconds, source size, creation time and whether it is open in the editor. Returns 30 at a time (limit, at most 100) with the total; when has_more is true, call again with offset to page through older projects, or pass query to find projects whose title contains that text.",
            scope: .global, annotations: .reads
        ),
        MCPToolSpec(
            tool: GetProjectTool(), title: "Get project",
            description: "Describe one project without opening it: title, duration and source size; look, zoom style and audio settings under the argument names update_settings, set_zoom_style and set_sound_effects take; export_width and frame_rate (change them with update_settings' exportWidth and frameRate, or for one export with export_project's width and frame_rate); the zooms with their ids and numbers (the first 100 in time order, with zoom_count); the chapters (the first 50, with chapter_count; long text is shortened with …); and the recorded clicks and typing moments (at most 200 of each, spread evenly over the recording, with their totals), as times in seconds and positions from 0 to 1 measured from the top-left corner of the recording. Use it to plan zooms and chapters.",
            scope: .projectReadOnly, annotations: .reads
        ),
        MCPToolSpec(
            tool: RenameProjectTool(), title: "Rename project",
            description: "Rename a library project; only its title changes, its folder and files keep their names. Focus Studio shows its library for this, saving and closing the editor if it is open.",
            scope: .library, annotations: MCPToolAnnotations(readOnly: false, idempotent: true)
        ),
        MCPToolSpec(
            tool: DeleteProjectTool(), title: "Delete project",
            description: "Move a project's folder (its recording, settings and generated media) to the macOS Trash, where the person can restore it; nothing is deleted permanently. Focus Studio shows its library for this, saving and closing the editor if it is open. Ask the person before deleting a project they did not ask you to remove.",
            scope: .library, annotations: MCPToolAnnotations(readOnly: false, destructive: true, idempotent: true)
        ),
        // New projects from files.
        MCPToolSpec(
            tool: ImportVideoTool(), title: "Import video",
            description: "Import a video file (.mp4, .mov or .m4v) as a new project and open it in the Focus Studio editor. The file is copied into the library; the original stays where it is. There are no recorded clicks, so add zooms with add_zoom. Returns the new project_id.",
            scope: .global, annotations: MCPToolAnnotations(readOnly: false),
            propertyDescriptions: ["path": "The video file: an absolute path, or relative to your working directory."]
        ),
        MCPToolSpec(
            tool: CreateScreenshotDemoTool(), title: "Create screenshot demo",
            description: "Turn a PNG or JPEG screenshot into an editable 12-second demo project (a still video with a gentle camera move and no automatic zooms) and open it in the Focus Studio editor; add zooms and chapters afterwards. Returns the new project_id.",
            scope: .global, annotations: MCPToolAnnotations(readOnly: false),
            propertyDescriptions: ["path": "The PNG or JPEG screenshot: an absolute path, or relative to your working directory."]
        ),
        // Recording.
        MCPToolSpec(
            tool: ListRecordingSourcesTool(), title: "List recording sources",
            description: "Refresh and list what can be recorded: every display (the main display first) and the largest visible windows, each with its source id, kind, app, title and size in points. Focus Studio shows its recorder screen for this, saving and closing the editor if it is open. Needs the Screen Recording permission (see get_status).",
            // Not read-only: it switches Focus Studio to its recorder screen.
            scope: .global, annotations: MCPToolAnnotations(readOnly: false, idempotent: true), navigates: true
        ),
        MCPToolSpec(
            tool: StartRecordingTool(), title: "Start recording",
            description: "Start recording a display or window. Focus Studio shows a visible 3-second countdown, then a floating control bar while the person performs the demo; the call returns once frames are being captured. Call stop_recording when the demo is done. Optional capture settings (system audio, microphone, automatic zooms, browser content only, frame rate) are set in Focus Studio before the countdown.",
            scope: .global, annotations: MCPToolAnnotations(readOnly: false)
        ),
        MCPToolSpec(
            tool: StopRecordingTool(), title: "Stop recording",
            description: "Finish the current recording. Focus Studio saves it as a new project, with automatic zooms on the recorded clicks and typing, and opens it in the editor. Returns the project_id, title, duration in seconds, source size and number of zooms.",
            scope: .global, annotations: MCPToolAnnotations(readOnly: false)
        ),
        // Editing a project (opened in the editor first).
        MCPToolSpec(
            tool: AddZoomTool(), title: "Add zoom",
            description: "Add a manual zoom to a project: from start to end (seconds into the recording) the camera moves to (x, y), each from 0 to 1 measured from the top-left corner of the recording, magnified by scale (default: the project's zoom scale). Existing zooms stay. Returns the zoom's id and number. Focus Studio opens the project in its editor, so the person sees the change.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false)
        ),
        MCPToolSpec(
            tool: RemoveZoomTool(), title: "Remove zoom",
            description: "Remove one zoom from a project by its id (from get_project or add_zoom; it stays valid when other zooms change) or by its number (index, 1-based, in time order), or every zoom with all: true. Focus Studio opens the project in its editor.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false, destructive: true)
        ),
        MCPToolSpec(
            tool: SetZoomStyleTool(), title: "Set zoom style",
            description: "Tune how a project's zooms move: screen animation, zoom scale, how long an automatic zoom holds on a click, ease-in and ease-out durations in seconds, how close clicks are chained into one zoom, and whether automatic zooms are on. Only the given keys change; a new chain gap or turning automatic zooms back on regenerates the automatic zooms. Focus Studio opens the project in its editor.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false, destructive: true, idempotent: true)
        ),
        MCPToolSpec(
            tool: UpdateSettingsTool(), title: "Update settings",
            description: "Change how a project looks and exports: background (style, preset, colours, image, blur, brightness), padding, corner radius, shadow, screen animation, zoom scale, aspect ratio, motion blur, caption style, the product description, and the export width and frame rate saved with the project. Only the given keys change; numbers out of range are clamped and reported. Focus Studio opens the project in its editor.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false, destructive: true, idempotent: true),
            propertyDescriptions: ["backgroundImagePath": "An image file: an absolute path, or relative to your working directory."]
        ),
        MCPToolSpec(
            tool: SetChaptersTool(), title: "Set chapters",
            description: "Replace a project's chapters, or add to them with append: true. Each chapter is a time range in seconds with a short title and a one-line caption drawn on the video; it needs at least 0.5 s and a title or caption, and invalid ones are dropped and counted. Focus Studio opens the project in its editor.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false, destructive: true)
        ),
        MCPToolSpec(
            tool: SetBackgroundImageTool(), title: "Set background image",
            description: "Use an image file as a project's background behind the recording. Focus Studio opens the project in its editor.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false, idempotent: true),
            propertyDescriptions: ["path": "The image file: an absolute path, or relative to your working directory."]
        ),
        MCPToolSpec(
            tool: SetBackgroundMusicTool(), title: "Set background music",
            description: "Set a project's background music to a bundled track, to a local audio file, or to \"none\" to remove it, with an optional volume from 0 to 1 (by default the track's suggested level). Focus Studio opens the project in its editor.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false, idempotent: true),
            propertyDescriptions: ["track": "A bundled track id or title (listed by get_status), an audio file (an absolute path, or relative to your working directory), or \"none\"."]
        ),
        MCPToolSpec(
            tool: SetSoundEffectsTool(), title: "Set sound effects",
            description: "Turn a project's click sound and zoom whoosh on or off, optionally with volumes from 0 to 1. Focus Studio opens the project in its editor.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false, idempotent: true)
        ),
        // Output.
        MCPToolSpec(
            tool: CaptureFrameTool(), title: "Capture frame",
            description: "Render one frame of a project as it will export (background, padding, zoom, captions) at a time in seconds, to check the look. Returns the frame as an image and saves it as a PNG in the project's assets folder (its path is in the result). Focus Studio opens the project in its editor.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false), returnsImage: true
        ),
        MCPToolSpec(
            tool: ExportProjectTool(), title: "Export project",
            description: "Render a project with its look, zooms, captions and audio to an MP4 and return its absolute path. An existing file is replaced only with overwrite: true, and the project's own recording and media are never written. Optional width (1280, 1920, 2560 or 3840) and frame_rate (24, 30 or 60) apply to this export only. Reports progress; an export still running after about 200 seconds returns a job_id for wait_for_job. Focus Studio opens the project in its editor.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false, destructive: true),
            propertyDescriptions: ["path": "The .mp4 file or a folder for it: an absolute path, or relative to your working directory. Default: export-<timestamp>.mp4 in the project's assets folder. Not inside the Focus Studio library except the project's ai folder."]
        ),
        MCPToolSpec(
            tool: AssembleVideoTool(), title: "Assemble video",
            description: "Join video clips in order (for example intro + exported demo + outro) into one 1080p or 720p MP4, with a cut or a 0.5 s crossfade; each clip is scaled and letterboxed to fit and its audio kept. An existing file is replaced only with overwrite: true, and a clip is never overwritten. With project_id the default location is that project's assets folder (the project is not opened). A run still going after about 200 seconds returns a job_id for wait_for_job.",
            scope: .projectReadOnly, requiresProjectID: false, annotations: MCPToolAnnotations(readOnly: false, destructive: true),
            propertyDescriptions: [
                "clips": "Video files in playback order: absolute paths, or relative to your working directory.",
                "path": "The .mp4 file or a folder for it: an absolute path, or relative to your working directory. Default: assembled-<timestamp>.mp4 in the project's assets folder (with project_id) or in Focus Studio's AI Assets folder.",
            ]
        ),
        MCPToolSpec(
            tool: ListAssetsTool(), title: "List assets",
            description: "List the images, videos and audio files in a project's assets folder (with project_id; the project is not opened) or in Focus Studio's AI Assets folder, newest first, with absolute paths, kinds, sizes, dimensions and durations.",
            scope: .projectReadOnly, requiresProjectID: false, annotations: .reads
        ),
        // Long calls.
        MCPToolSpec(
            name: waitForJobName, title: "Wait for job",
            description: "Wait for a call that answered {status: \"running\", job_id} (an export or assembly still running after about 200 seconds) and return its result exactly as the original call would have. Waits at most timeout_seconds; if the job is still running it returns the running status again, so call it again. A result is kept for 30 minutes after its job finishes.",
            inputSchema: [
                "type": "object",
                "required": ["job_id"],
                "properties": [
                    "job_id": ["type": "string", "description": "The job_id of a running result."],
                    "timeout_seconds": ["type": "number", "minimum": 0, "maximum": AIJSONValue(AutomationJobs.maximumWait), "default": AIJSONValue(AutomationJobs.defaultWait), "description": AIJSONValue("How long to wait, in seconds, from 0 to \(Int(AutomationJobs.maximumWait)) (default \(Int(AutomationJobs.defaultWait))).")],
                ],
            ],
            annotations: .reads, scope: .global, requiresProjectID: false, returnsImage: false, navigates: false, tool: nil
        ),
    ])

    // MARK: - Instructions

    /// The MCP server `instructions`: what Focus Studio is, the workflow and
    /// the conventions every tool follows. Kept under 2,000 characters, with
    /// the rule about project.json in the first paragraph: Claude Code cuts
    /// server instructions at 2,048.
    public static let instructions = """
    Focus Studio is a macOS app that records the screen and turns the recording into a polished product-demo video: automatic zooms on clicks and typing, a styled background, chapter captions, music and sound effects, MP4 export. These tools operate the Focus Studio app on this Mac while a person watches it. Only Focus Studio writes its library: never edit a project's files (project.json) directly.

    Workflow: get_status (permissions, bundled music) → list_recording_sources → start_recording (a 3-second countdown, then the person performs the demo) → stop_recording (returns the new project_id; if the person stopped from the control bar, the new project is first in list_projects) → edit by project_id: get_project, add_zoom, set_chapters, update_settings, set_background_music and the other editing tools → capture_frame to check the look → export_project. import_video and create_screenshot_demo make projects from existing files.

    Conventions:
    - Times and durations are seconds within the recording.
    - Positions x and y run from 0 to 1, measured from the top-left corner of the recording (0.5, 0.5 is the centre).
    - Paths are absolute or relative to your working directory; ~ is expanded. An existing file is replaced only with overwrite: true, and a project's own recording is never written.
    - project_id comes from list_projects, stop_recording, import_video or create_screenshot_demo.
    - Editing and output tools open their project in the Focus Studio editor first (saving and closing any other open project), so the person sees every change. They are refused while a recording is under way, the app is busy or its own in-app assistant is working on a request; try again afterwards.
    - Calls that change what Focus Studio shows run one at a time, in the order they arrive; reads run at once.
    - A call still running after about 200 seconds (a long export) answers with status "running" and a job_id; call wait_for_job with it to get the result.
    """
}
