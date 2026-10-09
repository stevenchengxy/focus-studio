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
/// treat a call. Tracked input can affect the recorded website; openWorld discloses that.
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
    /// A call still running after about 200 seconds answers with a job_id
    /// for wait_for_job (``AutomationJobs``). False for a tool that bounds
    /// its own wait well inside client timeouts (wait_for_recording).
    public let detaches: Bool
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
        detaches: Bool = true,
        propertyDescriptions: [String: String] = [:]
    ) {
        let required = scope == .global ? false : (requiresProjectID ?? true)
        let base = AIJSONValue(jsonObject: tool.parametersSchema) ?? ["type": "object", "properties": [:]]
        self.init(
            name: tool.name, title: title, description: description,
            inputSchema: Self.schema(base, scope: scope, requiresProjectID: required, descriptions: propertyDescriptions),
            annotations: annotations, scope: scope, requiresProjectID: required, returnsImage: returnsImage,
            navigates: navigates ?? Self.navigatesByDefault(scope: scope, annotations: annotations), detaches: detaches, tool: tool
        )
    }

    init(
        name: String, title: String, description: String, inputSchema: AIJSONValue, annotations: MCPToolAnnotations,
        scope: MCPToolScope, requiresProjectID: Bool, returnsImage: Bool, navigates: Bool, detaches: Bool = true, tool: (any AIAssistantTool)?
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
        self.detaches = detaches
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
        "description": "The project's id (a UUID), from list_projects, stop_recording, wait_for_recording, import_video or create_screenshot_demo.",
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
            description: "Report Focus Studio's state: its version, whether it is counting down or recording (recording.elapsed: seconds recorded, paused time left out; recording.paused: whether the person paused it; recording.remaining: seconds of recording left when a duration will stop it), which project is open in the editor, how many projects the library has, which macOS permissions it holds (Screen Recording is needed to record; Accessibility and Input Monitoring give automatic zooms on clicks and typing) and the bundled music tracks with their ids for set_background_music. Call it first to check that recording will work.",
            scope: .global, annotations: .reads
        ),
        MCPToolSpec(
            tool: ListProjectsTool(), title: "List projects",
            description: "List the library's projects, newest first, each with its project_id, title, duration in seconds, source size, creation time and whether it is open in the editor. Returns 30 at a time (limit, at most 100) with the total; when has_more is true, call again with offset to page through older projects, or pass query to find projects whose title contains that text.",
            scope: .global, annotations: .reads
        ),
        MCPToolSpec(
            tool: GetProjectTool(), title: "Get project",
            description: "Describe one project without opening it: title, duration and source size; look, zoom style and audio settings under the argument names update_settings, set_zoom_style and set_sound_effects take; export_width and frame_rate (change them with update_settings' exportWidth and frameRate, or for one export with export_project's width and frame_rate); the zooms with their ids and numbers (the first 80 in time order, with zoom_count); the chapters (the first 50, with chapter_count; long text is shortened with …); and the recorded clicks and typing moments (at most 200 of each, spread evenly over the recording, with their totals), as times in seconds and positions from 0 to 1 measured from the top-left corner of the recording. Use it to plan zooms and chapters.",
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
            description: "Start recording a display or window. The person sees a 3-second countdown, which names you, in a floating control bar (Pause, Finish, Cancel) that stays for the whole recording, and may pause, resume or cancel at any time. The call returns as soon as the recording is live: state \"recording\" with started_at. Meanwhile, let the person perform the demo, or operate the recorded app yourself with your own tools (computer use, browser automation); then call wait_for_recording, or stop_recording to stop at once. The control bar floats above every app at the bottom centre of each display, just above the Dock (about 324 to 392 x 46 points while recording; the person can expand it to about 760 x 116), and is not in the video: mouse clicks there land on the bar, and its x discards the recording (it moves to the Trash). When you click the recorded app yourself, keep its controls out of that area (move or resize its window, or scroll), and stop with stop_recording, never with the bar's buttons. With duration, Focus Studio stops by itself once that many seconds are recorded (auto_stop_at); time the person spends paused is not recorded and does not count, so a pause moves the stop later. Capture settings given here apply to this recording only. Sound: when microphone or system_audio turns on sound that the person's own recorder settings leave off, Focus Studio asks the person before the countdown (every time, never remembered). They may allow it for this recording, record without sound (the recording then has no sound at all; audio_consent and options in the result say so), or cancel, and no answer within 60 seconds also cancels: then nothing records and the call returns isError. Recordings that add no sound start without asking. Microphone: macOS must also allow Focus Studio to use it. If macOS has never asked, it asks the person before the countdown (no answer to it within 60 seconds cancels too). If that access is off (System Settings › Privacy & Security › Microphone), nothing records and the call returns isError with status \"microphone_unavailable\": to record without the microphone, call again with microphone false. For automated pointer demos, set interaction_mode codex, then capture_recording_frame and perform_recording_action for each observed action. This records a synchronized cursor path and click zooms without depending on the physical pointer. Clicks and typing sent independently over a browser's DevTools protocol (Playwright, Chrome automation) are not intercepted; unreported actions still need add_zoom afterwards.",
            scope: .global, annotations: MCPToolAnnotations(readOnly: false),
            propertyDescriptions: [
                "system_audio": "Capture the Mac's audio output in this recording. If the person's recorder settings leave it off, Focus Studio asks the person first.",
                "microphone": "Capture the microphone in this recording. If the person's recorder settings leave it off, Focus Studio asks the person first; macOS must also allow Focus Studio to use the microphone.",
            ]
        ),
        MCPToolSpec(
            tool: CaptureRecordingFrameTool(), title: "Observe recording window",
            description: "Capture a fresh image of the current uncropped recorded window and return its recording_id, observation_id and pixel dimensions. Requires a live unpaused recording with interaction_mode codex. Use this image to choose normalized x/y before every perform_recording_action or perform_recording_text. The single-use observation expires after 60 seconds, a window move/resize, or an action. The image excludes Focus Studio recording controls.",
            scope: .global, annotations: MCPToolAnnotations(readOnly: false), returnsImage: true, detaches: false
        ),
        MCPToolSpec(
            tool: PerformRecordingActionTool(), title: "Perform tracked recording action",
            description: "Execute an observed move, click or scroll in the live recorded window and record the dispatched path for cursor animation, click highlights and automatic zooms. Requires start_recording interaction_mode codex, its recording_id, a fresh single-use observation_id from capture_recording_frame, and a unique action_id. Coordinates are normalized to the full uncropped source image from its top-left. Refuses stale, moved, obscured, paused or stopped targets. Never guess a control or click outside the user's authorized demo. Clicks can affect the recorded website, including submitting forms: use only actions the user requested. Reusing action_id returns its receipt and never repeats input. Manual recordings keep system event tracking. Arbitrary browser or accessibility actions outside this tool are not intercepted.",
            scope: .global, annotations: MCPToolAnnotations(readOnly: false, destructive: true, idempotent: true, openWorld: true), detaches: false
        ),
        MCPToolSpec(
            tool: PerformRecordingTextTool(), title: "Type observed demo text",
            description: "Type a single line of user-authorized demo text into the focused editable field inside the recorded webpage. First focus that field with perform_recording_action, then inspect a fresh capture_recording_frame. Requires the live codex recording_id, a fresh single-use observation_id and a unique action_id. Refuses password fields, browser chrome, missing focus and stale or changed windows. Up to 1000 characters; control characters and newlines are rejected. Does not press Enter or submit. Reusing action_id returns its receipt without typing twice. Text may affect the website through autosave; only enter content authorized by the user.",
            scope: .global, annotations: MCPToolAnnotations(readOnly: false, destructive: true, idempotent: true, openWorld: true), detaches: false
        ),
        MCPToolSpec(
            tool: StopRecordingTool(), title: "Stop recording",
            description: "Stop the current recording now (also one whose duration is still running, or one the person paused) and wait until Focus Studio has saved it as a new project, with automatic zooms on the recorded clicks and typing, and opened it in the editor. Returns state \"finished\" with the project_id, title, duration in seconds, source size and number of zooms. A stop already under way (the person's Finish, the duration running out) is joined, never repeated.",
            scope: .global, annotations: MCPToolAnnotations(readOnly: false)
        ),
        MCPToolSpec(
            tool: WaitForRecordingTool(), title: "Wait for recording",
            description: "Wait, without stopping it, until the current recording ends: the person clicks Finish or Cancel, its duration runs out, or stop_recording is called. Returns state \"finished\" with the project_id and duration once the project is saved and open in the editor, or \"cancelled\" when the person cancelled (nothing is saved). Waits at most timeout_seconds (default 120, at most 240); if the recording has not ended by then, it returns the state it is still in and you call it again: \"countdown\" (the countdown or the capture start), \"recording\" (with paused, true while the person has paused it; elapsed, the seconds recorded; and remaining with a duration, which does not count down while paused) or \"stopping\" (the recording is being saved). Returns state \"idle\" when nothing is recording, with how the last recording ended (and its project_id if it was saved) in last_recording. Other calls, get_status included, keep working while it waits.",
            // Bounds its own wait, so it is never turned into a job.
            scope: .global, annotations: .reads, detaches: false
        ),
        // Editing a project (opened in the editor first).
        MCPToolSpec(
            tool: AnalyzeDemoPacingTool(), title: "Analyze demo pacing",
            description: "Suggest source-time keep ranges and candidate waits from the project's recorded actions. This does not change the project or detect visual inactivity: inspect frames around proposed cuts and preserve page loading, generated answers, reading time and audio. Returns keep_ranges for create_demo_cut. Without usable actions there is no automatic cut proposal.",
            scope: .projectReadOnly, annotations: .reads
        ),
        MCPToolSpec(
            tool: CreateDemoCutTool(), title: "Create edited demo copy",
            description: "Create and open a new editable project from ordered source-time keep_ranges. The original project and recording are preserved. The source video, recorded cursor/actions, typing, zooms and chapters are cut and remapped together; appearance and media are copied. Use analyze_demo_pacing and inspect frames before selecting ranges. Afterward use the returned new project_id and its new timeline for all edits, previews and export.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false)
        ),
        MCPToolSpec(
            tool: GetTimelineTool(), title: "Read video timeline",
            description: "Read every clip in the project's video track with stable clip IDs, ordered zero-based indices, source in/out points, output timeline positions, source-audio gain and outgoing transitions. This does not edit or open the project. For a precise visual cut, resolve_timeline_frame maps a time or output-frame index to an exact output time and source clip before split_clip.",
            scope: .projectReadOnly, annotations: .reads
        ),
        MCPToolSpec(
            tool: ResolveTimelineFrameTool(), title: "Resolve video frame",
            description: "Resolve exactly one approximate output time (at_seconds) or zero-based output frame_index against this project's export frame-rate grid. Returns the exact output time, containing clip ID and source time, plus whether a split is safe there. Read-only: it does not move the editor playhead, start playback, capture an image or change the project. Use capture_frame with returned time_seconds to inspect the picture, then split_clip with that exact time if desired.",
            scope: .projectReadOnly, annotations: .reads
        ),
        MCPToolSpec(
            tool: ListMediaAssetsTool(), title: "List editor media assets",
            description: "List the reusable image and video assets imported into this project's editor media library, with stable asset IDs, source paths, dimensions and durations. These are available to drag onto the timeline or to insert_media_asset. Does not open or change the project.",
            scope: .projectReadOnly, annotations: .reads
        ),
        MCPToolSpec(
            tool: ListGlobalMediaAssetsTool(), title: "List shared media assets",
            description: "List reusable images and videos in the app-wide shared media library. These do not belong to any project until explicitly copied with add_global_media_to_project.",
            scope: .global, annotations: .reads
        ),
        MCPToolSpec(
            tool: ImportGlobalMediaAssetTool(), title: "Import shared media asset",
            description: "Copy a local image or video into Focus Studio's app-wide shared library. No project or timeline changes. Use the returned global asset ID to add it to a project later.",
            scope: .global, annotations: MCPToolAnnotations(readOnly: false),
            propertyDescriptions: ["path": "Absolute local image/video path, or relative to your working directory."]
        ),
        MCPToolSpec(
            tool: AddGlobalMediaToProjectTool(), title: "Add shared media to project",
            description: "Copy a shared asset into this project's private media library. The first project edit may create a working copy; use its returned project_id and local asset_id. Does not insert a timeline clip.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false)
        ),
        MCPToolSpec(
            tool: ImportMediaAssetTool(), title: "Import editor media asset",
            description: "Copy a local image or video into the current project's reusable media library without placing it on the timeline. A first media edit may create and open a working copy; use the returned project_id and asset_id for subsequent insertion. The original file remains untouched.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false),
            propertyDescriptions: ["path": "Absolute local image/video path, or relative to your working directory."]
        ),
        MCPToolSpec(
            tool: InsertMediaAssetTool(), title: "Insert editor media asset",
            description: "Insert a previously imported image or video at a zero-based clip position. Images default to three seconds; videos default to their full duration. The asset remains reusable. The edit is reversible with undo_clip_edit and can be reapplied with redo_clip_edit.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false)
        ),
        MCPToolSpec(
            tool: SplitClipTool(), title: "Split a video clip",
            description: "Split a clip at an absolute output-timeline time strictly inside that clip. The first video-track edit creates a separate editable copy and preserves the original recording; use the returned project_id and new clip IDs for subsequent edits. The video, associated source sound and interaction overlays stay synchronized.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false)
        ),
        MCPToolSpec(
            tool: TrimClipTool(), title: "Trim clip in/out points",
            description: "Adjust one clip's source in/out points in seconds, using its stable clip_id from get_timeline. Later output times are recalculated. The first video-track edit makes an editable copy; use the returned project_id thereafter. Original media remains in the library, and invalid ranges are refused without changing the track.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false, idempotent: true)
        ),
        MCPToolSpec(
            tool: DeleteClipTool(), title: "Remove a video clip",
            description: "Remove one clip by stable clip_id from the editable video track, recalculating output timing and associated audio/overlays. It does not trash the source project or original media. The first video-track edit creates a separate working copy; use its returned project_id for later calls.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false, destructive: true)
        ),
        MCPToolSpec(
            tool: MoveClipTool(), title: "Reorder a video clip",
            description: "Move one clip to a zero-based destination index in the project's video track. The output timeline and associated audio/interaction timing follow the new order; stable IDs remain the same. Read get_timeline again after reordering. The first edit creates a separate editable copy.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false, idempotent: true)
        ),
        MCPToolSpec(
            tool: SetTransitionTool(), title: "Set clip transition",
            description: "Set the rendered effect after a clip by stable clip_id: cut (0 seconds), fadeToBlack or flash (0.1–2 seconds). Optionally supply outgoing_duration and incoming_duration, summing to duration, plus separate outgoing_curve and incoming_curve (linear, smooth, easeIn, easeOut). The final clip has no outgoing transition. Preview and MP4 share these settings; get_timeline reports both sides. The first edit creates a separate editable copy.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false, idempotent: true)
        ),
        MCPToolSpec(
            tool: SetClipAudioTool(), title: "Set clip source-audio gain",
            description: "Set the source-audio gain for one clip by stable clip_id: 0 mutes, 1 keeps the original level, 2 gives 200% gain. Preview and export apply it only to that clip. Background music and click/zoom sounds are separate project controls. The first edit creates an editable copy.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false, idempotent: true)
        ),
        MCPToolSpec(
            tool: SetImageDurationTool(), title: "Set still-image clip duration",
            description: "Set the visible duration of an imported still-image clip in seconds by its stable clip_id from get_timeline. Later clip times are recalculated, and the reusable source image stays in the project's media library. Invalid durations or video clip IDs are refused without changing the timeline.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false, idempotent: true)
        ),
        MCPToolSpec(
            tool: UndoClipEditTool(), title: "Undo last video edit",
            description: "Undo the most recent editor change in the currently open working project, including clip placement, zoom, chapter or project-setting changes. Call repeatedly to walk its finite undo history; no source recording is removed. The undo stack is in memory and may be unavailable after an app restart. Returns the current project_id and complete video timeline.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false)
        ),
        MCPToolSpec(
            tool: RedoClipEditTool(), title: "Redo last video edit",
            description: "Reapply the most recently undone editor change in the open working project, including video clips, zooms and project settings. A new edit clears redo history. Returns the updated complete timeline.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false)
        ),
        MCPToolSpec(
            tool: UpdateZoomTool(), title: "Adjust one zoom",
            description: "Adjust one zoom by its stable zoom_id from get_project or add_zoom: change start/end seconds, target, scale, easing or enabled state without replacing its ID or other zooms. The edited zoom becomes manual so later automatic regeneration preserves this decision. Use the current project's timeline, especially after create_demo_cut, and preview both ends of the adjusted zoom.",
            scope: .project, annotations: MCPToolAnnotations(readOnly: false, idempotent: true)
        ),
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
            description: "Change how a project looks and exports: background (style, preset, colours, image, blur, brightness), padding, corner radius, shadow, screen animation, zoom scale and cursor following, aspect ratio, motion blur, caption style, the product description, and export width/frame rate. zoomFollowsCursor 0 holds authored camera targets for reading; 1 fully follows the cursor. Only supplied keys change; numbers out of range are clamped and reported. Focus Studio opens the project in its editor.",
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
            description: "Render one frame of a project as it will export (background, padding, zoom, captions) at a time in seconds. With exact_frame: true, snap the requested time to the project's output frame grid and use zero image-generator time tolerance; this can take longer. The result reports frame_index, actual_time_seconds and frame_matches_request so you can verify the requested frame was shown. Returns an image and saves a PNG in the project's assets folder. Focus Studio opens the project in its editor.",
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
            description: "Wait for a call that answered {status: \"running\", job_id} (an export or assembly still running about 200 seconds after it reached Focus Studio, or a start_recording whose sound prompt, or macOS's microphone prompt, the person has not answered yet) and return its result exactly as the original call would have. Waits at most timeout_seconds; if the job is still running it returns the running status again, so call it again. A result is kept for 30 minutes after its job finishes.",
            inputSchema: [
                "type": "object",
                "required": ["job_id"],
                "properties": [
                    "job_id": ["type": "string", "description": "The job_id of a running result."],
                    "timeout_seconds": ["type": "number", "minimum": 0, "maximum": AIJSONValue(AutomationJobs.maximumWait), "default": AIJSONValue(AutomationJobs.defaultWait), "description": AIJSONValue("How long to wait, in seconds, from 0 to \(Int(AutomationJobs.maximumWait)) (default \(Int(AutomationJobs.defaultWait))).")],
                ],
            ],
            annotations: .reads, scope: .global, requiresProjectID: false, returnsImage: false, navigates: false, detaches: false, tool: nil
        ),
    ])

    // MARK: - Instructions

    /// The MCP server `instructions`: what Focus Studio is, the workflow and
    /// the conventions every tool follows. Kept at most 2,000 UTF-16 units,
    /// with the rule about project.json in the first paragraph: Claude Code
    /// cuts server instructions at 2,048.
    public static let instructions = """
    Focus Studio records and edits demos. Only Focus Studio writes its library: never edit project.json directly.

    Record: get_status → list_recording_sources → start_recording (bounded duration, countdown and control bar) → demo → stop_recording. wait_for_recording waits for a manual take. For Codex use interaction_mode codex; call capture_recording_frame before each perform_recording_action or perform_recording_text. observation_id is single-use; x/y use the full image. Text needs a focused webpage field and never presses Enter. Actions from your own tools are not intercepted.

    Edit: get_timeline → resolve_timeline_frame (exact output time; read-only, no seek) → capture_frame → split_clip/trim_clip/delete_clip/move_clip. Media: list_global_media_assets or import_global_media_asset → add_global_media_to_project → insert_media_asset (use returned local ID). import_media_asset imports to a project. Adjust transitions, audio and zooms; preview with capture_frame, export_project. First edit creates a copy: use its project_id. Undo/redo with undo_clip_edit/redo_clip_edit. Preserve answers and speech. import_video creates a project from a file.

    Conventions:
    - Times are seconds in the recording.
    - x/y run 0–1 from the recording's top-left corner.
    - Paths are absolute or relative to your working directory. overwrite: true replaces files; never write a project's recording.
    - Editing/rendering opens the project and runs serially; refused while recording or the app or in-app assistant is busy. get_project, list_assets and assemble_video leave the editor unchanged.
    - Sound the person's recorder leaves off (microphone, system_audio) records only if they allow it when Focus Studio asks.
    - Clicks and typing sent independently over DevTools are untracked; add_zoom adds camera cues but cannot recover a cursor path.
    - After about 200 s a long call returns status "running" and job_id: call wait_for_job. "waiting_for_approval" or "waiting_for_turn" means it did not run; call it again.
    """
}
