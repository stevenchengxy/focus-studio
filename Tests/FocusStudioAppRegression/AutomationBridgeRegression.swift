import Combine
import CoreGraphics
import FocusStudioAutomation
import FocusStudioCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The automation bridge against the real StudioModel: editing by project_id
/// opens the project in the editor (saving and closing another first) and
/// writes project.json; refusals while busy or recording; unknown and
/// withheld tools; read-only tools never navigate; capture_frame's inline
/// image; exports into the client's working directory with progress; the
/// library tools; refusals while the in-app assistant works or the editor
/// exports; English results while the app's own language is Chinese; reads
/// that skip the call queue; and long calls detached as jobs. Everything runs
/// in a temporary library with a fake Trash; no capture, network, real
/// library, real Trash or preferences are touched (the UI language is set in
/// the volatile argument domain, which is never saved).
@MainActor
enum AutomationBridgeRegression {
    static func run() async throws {
        try await editingOpensTheProject()
        try await refusals()
        try await refusedBesideTheAssistant()
        try await refusedDuringEditorExport()
        try await readsStayPut()
        try await outputs()
        try await libraryActions()
        try await englishUnderChineseUI()
        try await longCallsDetach()
        try windowPresenterSteps()
        try await installationBusyFollowsAutomation()
        print("AutomationBridgeRegression: PASS (main window presenter: a hidden app is unhidden instead of opening another window, a minimized window is restored, a closed one is never reused, edits by project_id open the editor and save, switching saves the other project, parallel calls take turns, refusals while busy or recording, while the in-app assistant works (also after an Allow at the sound prompt) and during an editor export, unknown/withheld tools, project_id validation, read-only tools stay put, capture_frame inline JPEG, working-directory export with progress, import/screenshot/rename/Trash, English results and refusals under a Chinese UI, detached jobs with wait_for_job and cancellation, reads skip the queue, queued calls detach in time, a call whose time runs out waiting for its turn answers waiting_for_turn with heartbeats and runs when called again, the installer's busy state republished as AI calls and detached jobs begin and end)")
    }

    // MARK: - Main window

    /// What MainWindowPresenter.present() does before an AI call changes
    /// what the app shows. A hidden app (⌘H) reports every window as not
    /// visible; opening a new window then would stack a second editor on the
    /// same project each time, so it is unhidden first and the choice is
    /// made again once it has.
    private static func windowPresenterSteps() throws {
        typealias Presenter = MainWindowPresenter
        let hidden: [(isVisible: Bool, isMiniaturized: Bool)] = [(false, false), (false, false)]
        try expect(Presenter.step(appIsHidden: true, windows: hidden, canOpen: true) == .unhideFirst, "A hidden app is unhidden, not given another window")
        try expect(Presenter.step(appIsHidden: true, windows: [], canOpen: true) == .unhideFirst, "Hidden with no window: unhidden first, then a window opens")
        try expect(Presenter.step(appIsHidden: false, windows: [], canOpen: true) == .openNew, "No window: one opens")
        try expect(Presenter.step(appIsHidden: false, windows: [(false, false)], canOpen: true) == .openNew, "A closed (still registered) window is never reused")
        try expect(Presenter.step(appIsHidden: false, windows: [(false, false), (true, false)], canOpen: true) == .orderFront(1), "The open window comes to the front")
        try expect(Presenter.step(appIsHidden: false, windows: [(false, true), (true, false)], canOpen: true) == .orderFront(1), "An open window wins over a minimized one")
        try expect(Presenter.step(appIsHidden: false, windows: [(false, false), (false, true)], canOpen: true) == .restore(1), "A minimized window is restored")
        try expect(Presenter.step(appIsHidden: false, windows: [], canOpen: false) == .nothing, "Nothing to do without a way to open one")
    }

    // MARK: - Installation

    /// Settings › Installation and the outside-Applications notice pass
    /// `isInstallationBusy` to the installer, and observe only the model. The
    /// model counts the AI calls running and the detached jobs still running,
    /// and republishes whenever either changes, so those views never keep a
    /// stale value (an assemble_video job that changes nothing else, say).
    private static func installationBusyFollowsAutomation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FocusStudio-InstallBusy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudioModel(store: ProjectStore(projectsDirectory: root))
        let activity = AutomationActivity()
        let jobs = AutomationJobs(detachAfter: 0.05)
        var published = 0
        let counter = model.objectWillChange.sink { _ in published += 1 }
        let observer = AppServices.reportAutomationWork(of: activity, jobs: jobs, to: model)
        defer {
            counter.cancel()
            observer.cancel()
        }
        try expect(!model.isInstallationBusy, "Nothing works in the app yet")

        var before = published
        let call = activity.begin(clientName: "Claude Code", tool: "assemble_video")
        try expect(published > before && model.isInstallationBusy, "A call beginning republishes the model, which is busy")
        before = published
        activity.end(call)
        try expect(published > before && !model.isInstallationBusy, "The call ending republishes it, no longer busy")

        let release = BridgeFlag()
        before = published
        let answer = await jobs.run(tool: "assemble_video", progress: nil) { _ in
            while !release.isRaised { try await Task.sleep(for: .milliseconds(5)) }
            return MCPToolCallResult(content: [.text("Assembled.")])
        }
        guard case let .result(running) = answer, running.structuredContent?["status"] == "running" else { throw BridgeFailure("The job must detach: \(answer)") }
        try expect(published > before && model.isInstallationBusy, "A detached job republishes the model, which is busy")
        before = published
        release.raise()
        try await waitUntil("The detached job did not finish") { jobs.runningJobIDs.isEmpty }
        try expect(published > before && !model.isInstallationBusy, "The job finishing republishes it, no longer busy")
    }

    // MARK: - Editing

    private static func editingOpensTheProject() async throws {
        let fixture = try await BridgeFixture()
        defer { fixture.cleanup() }
        let (first, second) = (fixture.projects[0], fixture.projects[1])
        let bridge = AutomationBridge(model: fixture.model)
        try expect(fixture.model.destination == .library, "The library shows at first")

        let zoom = try await fixture.succeed(bridge, "add_zoom", ["project_id": first.id.uuidString, "start": 0.2, "end": 0.8, "x": 0.25, "y": 0.75])
        try expect(fixture.model.destination == .editor && fixture.model.activeProject?.id == first.id, "An edit opens its project in the editor")
        let zoomID = zoom.structuredContent?["zoom_id"]?.stringValue
        try expect(zoom.structuredContent?["project_id"]?.stringValue == first.id.uuidString && zoomID != nil, "The result names the project and the zoom: \(zoom.json)")
        await fixture.model.flushProjectEdits()
        try expect(try fixture.saved(first.id).zoomSegments.contains { $0.id.uuidString == zoomID }, "The zoom is written to project.json")

        // project_id is taken out before the tool runs: update_settings rejects unknown keys.
        _ = try await fixture.succeed(bridge, "update_settings", ["project_id": first.id.uuidString, "padding": 24, "frameRate": 60])
        try expect(fixture.model.activeProject?.settings.padding == 24 && fixture.model.activeProject?.settings.frameRate == 60, "update_settings applies to the open project")

        // An edit the editor has not saved yet survives the switch to another project.
        fixture.model.activeProject?.title = "Unsaved editor title"
        let chapters = try await fixture.succeed(bridge, "set_chapters", ["project_id": second.id.uuidString, "chapters": [["start": 0, "end": 0.8, "title": "Intro"]]])
        try expect(fixture.model.destination == .editor && fixture.model.activeProject?.id == second.id, "Another project's edit switches the editor")
        try expect(chapters.structuredContent?["project_id"]?.stringValue == second.id.uuidString, "set_chapters names its project")
        await fixture.model.flushProjectEdits()
        let savedFirst = try fixture.saved(first.id)
        try expect(savedFirst.title == "Unsaved editor title" && savedFirst.settings.padding == 24, "The project left behind was saved: \(savedFirst.title)")
        try expect(try fixture.saved(second.id).chapters?.map(\.title) == ["Intro"], "The chapter is written to the second project")

        // Parallel calls to different projects take turns, so neither is
        // refused because the other switched the editor under it.
        let zoomsBefore = try fixture.saved(first.id).zoomSegments.count
        let zoomFirst = Task { @MainActor in
            await bridge.call(toolName: "add_zoom", arguments: ["project_id": first.id.uuidString, "start": 0.1, "end": 0.5, "x": 0.5, "y": 0.5], workingDirectory: nil, clientName: "test", progress: nil)
        }
        let captionSecond = Task { @MainActor in
            await bridge.call(toolName: "set_chapters", arguments: ["project_id": second.id.uuidString, "chapters": [["start": 0, "end": 0.9, "title": "Parallel"]]], workingDirectory: nil, clientName: "test", progress: nil)
        }
        let (zoomed, captioned) = (await zoomFirst.value, await captionSecond.value)
        for outcome in [zoomed, captioned] {
            guard case let .result(result) = outcome, !result.isError else { throw BridgeFailure("Parallel calls must both succeed: \(outcome)") }
        }
        await fixture.model.flushProjectEdits()
        let (firstZooms, secondChapters) = (try fixture.saved(first.id).zoomSegments.count, try fixture.saved(second.id).chapters?.map(\.title))
        try expect(firstZooms == zoomsBefore + 1 && secondChapters == ["Parallel"] && fixture.model.activeProject?.id == second.id, "Both parallel edits are saved: \(firstZooms), \(secondChapters ?? [])")

        // A second edit to the open project does not reopen it.
        let before = fixture.model.activeProject
        _ = try await fixture.succeed(bridge, "set_sound_effects", ["project_id": second.id.uuidString, "click": true])
        try expect(fixture.model.activeProject?.id == before?.id && fixture.model.activeProject?.settings.productDemoAudio?.clickSoundEnabled == true, "The open project is edited in place")
        fixture.model.closeEditor()
        await fixture.model.flushProjectEdits()
    }

    private static func refusals() async throws {
        let fixture = try await BridgeFixture()
        defer { fixture.cleanup() }
        let first = fixture.projects[0]
        let bridge = AutomationBridge(model: fixture.model)
        let original = try fixture.metadata(first.id)

        for name in ["generate_video", "generate_image", "open_project", "close_editor", "wait", "export_demo", "reveal_in_finder", "no_such_tool"] {
            let outcome = await bridge.call(toolName: name, arguments: [:], workingDirectory: nil, clientName: "test", progress: nil)
            try expect(outcome == .unknownTool(name), "\(name) is not offered: \(outcome)")
        }
        let zoom: [String: Any] = ["start": 0.2, "end": 0.6, "x": 0.5, "y": 0.5]
        for (arguments, expected) in [(zoom, "Missing required argument \"project_id\""),
                                      (zoom.merging(["project_id": "first"]) { $1 }, "must be a project id"),
                                      (zoom.merging(["project_id": 42]) { $1 }, "must be a project id"),
                                      (zoom.merging(["project_id": UUID().uuidString]) { $1 }, "No project has the id")] {
            let refused = try await fixture.fail(bridge, "add_zoom", arguments)
            try expect(refused.text.contains(expected), "add_zoom explains \(expected): \(refused.text)")
        }
        try expect(fixture.model.destination == .library, "A refused call does not navigate")

        fixture.model.busyMessage = "Importing video…"
        fixture.model.isBusy = true
        let busy = try await fixture.fail(bridge, "add_zoom", zoom.merging(["project_id": first.id.uuidString]) { $1 })
        try expect(busy.text.contains("busy (Importing video…)") && fixture.model.destination == .library, "Edits are refused while busy: \(busy.text)")
        let busyRename = try await fixture.fail(bridge, "rename_project", ["project_id": first.id.uuidString, "title": "No"])
        try expect(busyRename.text == "Focus Studio is busy. Try again when the current task finishes.", "Library actions are refused in English: \(busyRename.text)")
        fixture.model.isBusy = false

        fixture.model.destination = .countdown
        let counting = try await fixture.fail(bridge, "set_zoom_style", ["project_id": first.id.uuidString, "zoomHold": 1])
        try expect(counting.text.contains("counting down to a recording") && counting.text.contains("stop_recording"), "Edits are refused during the countdown: \(counting.text)")
        let importing = try await fixture.fail(bridge, "import_video", ["path": fixture.clip.path])
        try expect(importing.text == "Focus Studio is recording. Try again after the recording is stopped." && fixture.model.destination == .countdown, "Imports are refused during a recording: \(importing.text)")
        fixture.model.destination = .library
        try expect(try fixture.metadata(first.id) == original && fixture.model.projects.count == 2, "Nothing was written or created")
    }

    /// The in-app assistant edits whichever project is open, so while it is
    /// partway through a request no call may switch the editor under it.
    private static func refusedBesideTheAssistant() async throws {
        let script = PausingCompletion([
            #"{"thought": "zoom", "action": {"tool": "add_zoom", "arguments": {"start": 0.1, "end": 0.4, "x": 0.25, "y": 0.25}}}"#,
            #"{"thought": "zoom", "action": {"tool": "add_zoom", "arguments": {"start": 0.5, "end": 0.9, "x": 0.75, "y": 0.75}}}"#,
            #"{"thought": "done", "reply": "Added two zooms.", "suggestions": []}"#,
        ], pauseBefore: 2)
        let fixture = try await BridgeFixture(assistantCompletion: script)
        defer { fixture.cleanup() }
        let (first, second) = (fixture.projects[0], fixture.projects[1])
        let bridge = AutomationBridge(model: fixture.model)
        fixture.model.open(first)
        let zoomsBefore = fixture.model.activeProject?.zoomSegments.count ?? 0
        let secondBefore = try fixture.metadata(second.id)

        // A start_recording whose sound prompt is up while the person starts
        // an in-app assistant request: their Allow no longer starts it.
        let area = CaptureTargetInfo(id: "area-1-bridge", kind: .area, nativeID: 1, title: "Test area", frame: CaptureRect(x: 0, y: 0, width: 64, height: 64))
        try fixture.model.captureEngine.registerAreaTarget(area)
        let prompter = ScriptedSoundPrompter()
        prompter.mode = .hold
        bridge.audioConsent = AutomationAudioConsentController(timeout: 30, heartbeatInterval: 0.05) { await prompter.prompt($0) }
        let recording = Task { @MainActor in
            await bridge.call(toolName: "start_recording", arguments: ["source": area.id, "microphone": true], workingDirectory: nil, clientName: "Claude Code", progress: nil)
        }
        try await waitUntil("the sound prompt") { prompter.heldCount == 1 }
        try expect(fixture.model.automationNavigationRefusal == nil, "Nothing refuses the call when the prompt comes up")
        fixture.model.assistantSession.send("Add two zooms")
        try await waitUntil("the assistant to pause between its steps") { script.paused.isRaised }
        prompter.release(.allow)
        guard case let .result(afterAllow) = await recording.value else { throw BridgeFailure("start_recording must answer") }
        try expect(afterAllow.isError && afterAllow.text == "Focus Studio's own assistant is working on a request in the app. Try again when it finishes."
                   && fixture.model.recordingPhase == .idle && fixture.model.destination == .editor && fixture.model.activeProject?.id == first.id,
                   "Allowed while the in-app assistant works: refused, no countdown, the editor stays: \(afterAllow.text)")
        try expect(fixture.model.isAssistantRunning && fixture.model.activeProject?.zoomSegments.count == zoomsBefore + 1, "The assistant's first zoom is on the open project")
        let refused = try await fixture.fail(bridge, "add_zoom", ["project_id": second.id.uuidString, "start": 0.2, "end": 0.6, "x": 0.5, "y": 0.5])
        try expect(refused.text == "Focus Studio's own assistant is working on a request in the app. Try again when it finishes.", "Edits wait for the in-app assistant: \(refused.text)")
        try expect(fixture.model.destination == .editor && fixture.model.activeProject?.id == first.id, "The editor stays on the assistant's project")
        let recorder = try await fixture.fail(bridge, "list_recording_sources", [:])
        try expect(recorder.text == refused.text && fixture.model.destination == .editor, "So does every call that navigates: \(recorder.text)")
        let read = try await fixture.succeed(bridge, "get_project", ["project_id": second.id.uuidString])
        try expect(read.structuredContent?["id"]?.stringValue == second.id.uuidString, "Reads still answer")

        script.gate.raise()
        try await waitUntil("the assistant's turn to end") { !fixture.model.isAssistantRunning }
        await fixture.model.flushProjectEdits()
        let (firstZooms, secondAfter) = (try fixture.saved(first.id).zoomSegments.count, try fixture.metadata(second.id))
        try expect(firstZooms == zoomsBefore + 2 && secondAfter == secondBefore && fixture.model.activeProject?.id == first.id,
                   "Both of the assistant's zooms went to its project and the other was untouched: \(firstZooms) zooms")
        _ = try await fixture.succeed(bridge, "add_zoom", ["project_id": second.id.uuidString, "start": 0.2, "end": 0.6, "x": 0.5, "y": 0.5])
        try expect(fixture.model.activeProject?.id == second.id, "Once the assistant is done, the call goes through")
        fixture.model.closeEditor()
        await fixture.model.flushProjectEdits()
    }

    /// The editor's own Export renders behind its overlay; switching the
    /// editor would take its result away from the person.
    private static func refusedDuringEditorExport() async throws {
        let fixture = try await BridgeFixture()
        defer { fixture.cleanup() }
        let (first, second) = (fixture.projects[0], fixture.projects[1])
        let bridge = AutomationBridge(model: fixture.model)
        fixture.model.open(first)
        let output = fixture.cwd.appendingPathComponent("editor-export.mp4")
        let export = Task { @MainActor in try await fixture.model.exportFromEditor(first, to: output) }
        // The export starts at its first turn on the main actor, and cannot
        // end before the checks below give the main actor up.
        for _ in 0..<100 where !fixture.model.isExportingFromEditor { await Task.yield() }
        try expect(fixture.model.isExportingFromEditor, "The editor export is under way")

        let chapters = try await fixture.fail(bridge, "set_chapters", ["project_id": second.id.uuidString, "chapters": [["start": 0, "end": 0.8, "title": "Intro"]]])
        try expect(chapters.text == "Focus Studio is exporting a video from its editor. Try again when the export finishes.", "Edits wait for the export: \(chapters.text)")
        let recorder = try await fixture.fail(bridge, "list_recording_sources", [:])
        try expect(recorder.text == chapters.text, "So does the recorder: \(recorder.text)")
        try expect(fixture.model.destination == .editor && fixture.model.activeProject?.id == first.id, "The exporting editor stays")
        do {
            try await fixture.model.importVideo(from: fixture.clip)
            throw BridgeFailure("The app's own import must wait for the export")
        } catch let failure as AILocalizedFailure {
            try expect(failure.key == "Focus Studio is busy. Try again when the current task finishes.", "The app's import waits too: \(failure.key)")
        }

        _ = try await export.value
        try expect(!fixture.model.isExportingFromEditor && FileManager.default.fileExists(atPath: output.path), "The export finished and cleared its state")
        _ = try await fixture.succeed(bridge, "set_chapters", ["project_id": second.id.uuidString, "chapters": [["start": 0, "end": 0.8, "title": "Intro"]]])
        try expect(fixture.model.activeProject?.id == second.id && fixture.model.projects.count == 2, "Afterwards the edit opens its project")
        fixture.model.closeEditor()
        await fixture.model.flushProjectEdits()
    }

    private static func readsStayPut() async throws {
        let fixture = try await BridgeFixture()
        defer { fixture.cleanup() }
        let (first, second) = (fixture.projects[0], fixture.projects[1])
        let bridge = AutomationBridge(model: fixture.model)
        fixture.model.open(first)

        let project = try await fixture.succeed(bridge, "get_project", ["project_id": second.id.uuidString])
        try expect(project.structuredContent?["id"]?.stringValue == second.id.uuidString && project.structuredContent?["open_in_editor"] == false, "get_project reads the other project: \(project.text)")
        let assets = try await fixture.succeed(bridge, "list_assets", ["project_id": second.id.uuidString])
        let secondAssets = URL(fileURLWithPath: second.sourceVideoPath).deletingLastPathComponent().appendingPathComponent("ai", isDirectory: true)
        try expect(assets.structuredContent?["directory"]?.stringValue == secondAssets.path, "list_assets reads that project's folder: \(assets.structuredContent ?? .null)")
        let shared = try await fixture.succeed(bridge, "list_assets", [:])
        let sharedPath = shared.structuredContent?["directory"]?.stringValue ?? ""
        try expect(sharedPath == fixture.model.sharedAssetsDirectory.path && sharedPath.hasPrefix(fixture.root.path), "Without a project, the test library's own AI Assets folder: \(sharedPath)")
        let status = try await fixture.succeed(bridge, "get_status", [:])
        try expect(status.structuredContent?["library_count"] == 2 && status.structuredContent?["open_project_id"]?.stringValue == first.id.uuidString, "get_status: \(status.text)")
        let listed = try await fixture.succeed(bridge, "list_projects", [:])
        try expect(listed.structuredContent?["total"] == 2, "list_projects")
        try expect(fixture.model.destination == .editor && fixture.model.activeProject?.id == first.id, "Reads never navigate")
        fixture.model.closeEditor()
        await fixture.model.flushProjectEdits()
    }

    // MARK: - Outputs

    private static func outputs() async throws {
        let fixture = try await BridgeFixture()
        defer { fixture.cleanup() }
        let (first, second) = (fixture.projects[0], fixture.projects[1])
        let bridge = AutomationBridge(model: fixture.model)

        // capture_frame returns the frame inline.
        let frame = try await fixture.succeed(bridge, "capture_frame", ["project_id": first.id.uuidString, "time": 0.5])
        try expect(fixture.model.activeProject?.id == first.id, "capture_frame opens its project")
        guard frame.content.count == 2, case let .image(jpeg, mimeType) = frame.content[1] else {
            throw BridgeFailure("capture_frame must return an image block: \(frame.content.count) blocks")
        }
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw BridgeFailure("The image block must decode")
        }
        try expect(mimeType == "image/jpeg" && Array(jpeg.prefix(2)) == [0xFF, 0xD8] && max(width, height) <= 1_568 && jpeg.base64EncodedString().utf8.count <= 1_048_576,
                   "A JPEG of at most 1568 px and 1 MiB: \(width)×\(height), \(jpeg.count) bytes")
        let png = frame.structuredContent?["path"]?.stringValue ?? ""
        let firstAssets = URL(fileURLWithPath: first.sourceVideoPath).deletingLastPathComponent().appendingPathComponent("ai").path
        try expect(png.hasPrefix(firstAssets + "/frame-") && FileManager.default.fileExists(atPath: png), "The PNG is kept in the project's assets folder: \(png)")
        try expect(frame.json["content"]?[1]?["type"] == "image", "The image block is MCP's")

        // An export into the client's working directory, with measured progress.
        let progress = ProgressRecorder()
        let outcome = await bridge.call(toolName: "export_project", arguments: ["project_id": second.id.uuidString, "path": "out/demo.mp4", "width": 1_280],
                                        workingDirectory: fixture.cwd, clientName: "test", progress: { progress.record($0, $1, $2) })
        guard case let .result(export) = outcome, !export.isError else { throw BridgeFailure("The export must succeed: \(outcome)") }
        let output = fixture.cwd.appendingPathComponent("out/demo.mp4")
        try expect(FileManager.default.fileExists(atPath: output.path) && export.structuredContent?["width"] == 1_280
                   && (export.structuredContent?["path"]?.stringValue ?? "").hasSuffix("/out/demo.mp4"), "The export lands in the working directory: \(export.text)")
        let values = progress.values
        try expect(values.count >= 2 && values.last == 1 && zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "Progress only moves forward, to 1: \(values)")
        try expect(fixture.model.activeProject?.id == second.id && fixture.model.activeProject?.settings.exportWidth == 1_920, "The export opened its project without changing its saved width")

        let relative = try await fixture.fail(bridge, "export_project", ["project_id": second.id.uuidString, "path": "demo.mp4"])
        try expect(relative.text.contains("absolute path"), "Without a working directory a relative output is refused: \(relative.text)")
        let overRecording = try await fixture.fail(bridge, "export_project", ["project_id": second.id.uuidString, "path": second.sourceVideoPath, "overwrite": true])
        try expect(overRecording.text.contains("this project uses"), "The recording is never overwritten: \(overRecording.text)")
        fixture.model.closeEditor()
        await fixture.model.flushProjectEdits()
    }

    // MARK: - Library

    private static func libraryActions() async throws {
        let fixture = try await BridgeFixture()
        defer { fixture.cleanup() }
        let (first, second) = (fixture.projects[0], fixture.projects[1])
        let bridge = AutomationBridge(model: fixture.model)
        fixture.model.open(first)
        fixture.model.activeProject?.title = "Unsaved before import"

        // import_video: a working-directory path; the open project is saved and closed.
        let imported = try await fixture.succeed(bridge, "import_video", ["path": "clip.mp4", "title": "Imported clip"], cwd: fixture.cwd)
        guard let importedID = imported.structuredContent?["project_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            throw BridgeFailure("import_video returns the new project_id: \(imported.json)")
        }
        try expect(fixture.model.destination == .editor && fixture.model.activeProject?.id == importedID && fixture.model.projects.first?.id == importedID, "The import opens in the editor")
        await fixture.model.flushProjectEdits()
        let (importedTitle, replacedTitle) = (try fixture.saved(importedID).title, try fixture.saved(first.id).title)
        try expect(importedTitle == "Imported clip" && replacedTitle == "Unsaved before import", "The import is saved, and so is the project it replaced")
        try expect(!fixture.model.isBusy, "The busy overlay is gone")
        let notMovie = try await fixture.fail(bridge, "import_video", ["path": "notes.txt"], cwd: fixture.cwd)
        try expect(notMovie.text.contains("not a video file"), "Only movies import: \(notMovie.text)")

        // create_screenshot_demo.
        let demo = try await fixture.succeed(bridge, "create_screenshot_demo", ["path": fixture.screenshot.path])
        guard let demoID = demo.structuredContent?["project_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw BridgeFailure("create_screenshot_demo returns the project_id") }
        try expect(fixture.model.activeProject?.id == demoID && demo.structuredContent?["title"] == "shot Demo" && abs((demo.structuredContent?["duration"]?.doubleValue ?? 0) - 12) < 0.5,
                   "The screenshot becomes a 12-second demo in the editor: \(demo.text)")

        // rename_project: the library shows, the title is written.
        let renamed = try await fixture.succeed(bridge, "rename_project", ["project_id": first.id.uuidString, "title": "  Renamed by MCP "])
        try expect(fixture.model.destination == .library && fixture.model.projects.first { $0.id == first.id }?.title == "Renamed by MCP", "Renamed from the library")
        let renamedTitle = try fixture.saved(first.id).title
        try expect(renamedTitle == "Renamed by MCP" && renamed.structuredContent?["closed_editor"] == true, "The title is written: \(renamed.text)")
        let blank = try await fixture.fail(bridge, "rename_project", ["project_id": first.id.uuidString, "title": "   "])
        try expect(blank.text == "Project “Renamed by MCP” could not be renamed: Please enter a project name.", "The app's reason, in English: \(blank.text)")

        // delete_project: the open project is closed first, then moved to the (fake) Trash.
        fixture.model.open(second)
        let deleted = try await fixture.succeed(bridge, "delete_project", ["project_id": second.id.uuidString])
        try expect(fixture.model.destination == .library && !fixture.model.projects.contains { $0.id == second.id }, "Deleted from the library")
        try expect(fixture.trashed.contains(second.id.uuidString) && !FileManager.default.fileExists(atPath: fixture.library.appendingPathComponent(second.id.uuidString).path),
                   "The folder went to the Trash, not away")
        try expect(deleted.text.contains("Trash") && deleted.structuredContent?["moved_to_trash"] == true && deleted.structuredContent?["closed_editor"] == true, "delete reports what happened: \(deleted.text)")
        let again = try await fixture.fail(bridge, "delete_project", ["project_id": second.id.uuidString])
        try expect(again.text.contains("No project has the id"), "A second delete explains: \(again.text)")
    }

    // MARK: - Result language

    /// MCP results are English whatever the app's own language is: the
    /// bridge's context is English, and refusals the app words for its UI are
    /// rendered in the call's language.
    private static func englishUnderChineseUI() async throws {
        try await withAppLanguage("zh-Hans") {
            try expect(L10n.tr("Focus Studio is busy. Try again when the current task finishes.") == "Focus Studio 正忙。请在当前任务完成后重试。", "The app's own language is Chinese for this test")
            let fixture = try await BridgeFixture()
            defer { fixture.cleanup() }
            let first = fixture.projects[0]
            let bridge = AutomationBridge(model: fixture.model)

            // A tool's own text, from the bridge's context.
            let chapters = try await fixture.succeed(bridge, "set_chapters", ["project_id": first.id.uuidString, "chapters": [["start": 0, "end": 0.8, "title": "Intro"]]])
            try expect(chapters.text.hasPrefix("Set 1 chapters"), "Results are English under a Chinese UI: \(chapters.text)")
            fixture.model.closeEditor()
            await fixture.model.flushProjectEdits()

            // The app's own refusals (AILocalizedFailure) and store errors.
            let blank = try await fixture.fail(bridge, "rename_project", ["project_id": first.id.uuidString, "title": "   "])
            try expect(blank.text == "Project “First” could not be renamed: Please enter a project name.", "The app's reason in English: \(blank.text)")
            fixture.model.isBusy = true
            let busy = try await fixture.fail(bridge, "rename_project", ["project_id": first.id.uuidString, "title": "No"])
            fixture.model.isBusy = false
            try expect(busy.text == "Focus Studio is busy. Try again when the current task finishes.", "Refusals in English: \(busy.text)")
            try expect(L10n.tr("Exporting…") == "导出中…", "MCP calls leave the UI language alone")
        }
    }

    /// Runs `body` with the app's UI language setting in the volatile
    /// argument domain, which is never written to the preferences.
    private static func withAppLanguage<T>(_ code: String, _ body: @MainActor () async throws -> T) async rethrows -> T {
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(saved.merging(["focusStudio.language": code]) { $1 }, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        return try await body()
    }

    // MARK: - Long calls

    private static func longCallsDetach() async throws {
        let fixture = try await BridgeFixture()
        defer { fixture.cleanup() }
        let cancelled = BridgeFlag()
        let slow = MCPToolSpec(tool: SlowTool(cancelled: cancelled), title: "Slow", description: "Sleeps for the given seconds, reporting progress, for tests of detached calls.",
                               scope: .global, annotations: .reads)
        let bridge = AutomationBridge(model: fixture.model, catalog: MCPToolCatalog(tools: MCPToolCatalog.v1.tools + [slow]), jobs: AutomationJobs(detachAfter: 0.2))
        try expect(bridge.jobs.detachAfter == 0.2 && AutomationBridge(model: fixture.model).jobs.detachAfter == 200, "The threshold is injectable and 200 s by default")

        let running = try await fixture.succeed(bridge, "slow_tool", ["seconds": 1.0])
        guard running.structuredContent?["status"] == "running", let jobID = running.structuredContent?["job_id"]?.stringValue else {
            throw BridgeFailure("A slow call answers with a running job: \(running.json)")
        }
        try expect(running.structuredContent?["tool"] == "slow_tool" && bridge.jobs.runningJobIDs == [jobID], "The job keeps running")
        let polled = try await fixture.succeed(bridge, "wait_for_job", ["job_id": jobID, "timeout_seconds": 0.05])
        try expect(polled.structuredContent?["status"] == "running", "A short wait returns the running status again")
        let progress = ProgressRecorder()
        let outcome = await bridge.call(toolName: "wait_for_job", arguments: ["job_id": jobID, "timeout_seconds": 10], workingDirectory: nil, clientName: "test", progress: { progress.record($0, $1, $2) })
        guard case let .result(done) = outcome else { throw BridgeFailure("wait_for_job must answer: \(outcome)") }
        try expect(done.text == "Waited 1.0 s." && done.structuredContent == ["seconds": 1] && !done.isError, "wait_for_job returns the tool's own result: \(done.json)")
        try expect(progress.values.last == 1 && zip(progress.values, progress.values.dropFirst()).allSatisfy { $0 < $1 }, "and its progress: \(progress.values)")

        // A caller cancelled before the call detaches cancels the tool.
        let call = Task { @MainActor in
            await bridge.call(toolName: "slow_tool", arguments: ["seconds": 20], workingDirectory: nil, clientName: "test", progress: nil)
        }
        try await Task.sleep(for: .milliseconds(50))
        call.cancel()
        let result = await call.value
        try expect(result == .cancelled && cancelled.isRaised, "A cancelled call stops its tool: \(result)")

        // Time a call waits for its turn counts toward the threshold: of two
        // slow calls that navigate, arriving together, the second answers
        // about when the first does, not a whole threshold later.
        let navigating = MCPToolSpec(tool: SlowTool(cancelled: BridgeFlag()), title: "Slow", description: "Sleeps for the given seconds, taking a turn like the calls that navigate.",
                                     scope: .global, annotations: .reads, navigates: true)
        let queued = AutomationBridge(model: fixture.model, catalog: MCPToolCatalog(tools: MCPToolCatalog.v1.tools + [navigating]), jobs: AutomationJobs(detachAfter: 0.5))
        let arrived = Date()
        let calls = (0..<2).map { _ in
            Task { @MainActor in
                let outcome = await queued.call(toolName: "slow_tool", arguments: ["seconds": 1.5], workingDirectory: nil, clientName: "test", progress: nil)
                return (outcome: outcome, elapsed: Date().timeIntervalSince(arrived))
            }
        }
        // Reads skip the queue: while the first call holds its turn and the
        // second waits for it, a read and wait_for_job answer at once.
        try await waitUntil("the second slow call to wait for its turn") { queued.queue.waitingCount == 1 }
        let readStarted = Date()
        let status = try await fixture.succeed(queued, "get_status", [:])
        let unknownJob = try await fixture.fail(queued, "wait_for_job", ["job_id": "no-such-job", "timeout_seconds": 0])
        try expect(status.structuredContent?["library_count"] == 2 && unknownJob.text.contains("No job has the id"), "The reads answer: \(status.text) / \(unknownJob.text)")
        try expect(Date().timeIntervalSince(readStarted) < 0.3 && queued.queue.waitingCount == 1, "Reads never wait for a turn held by a navigating call")
        var jobIDs: [String] = []
        var answeredAfter: [Double] = []
        for call in calls {
            let (outcome, elapsed) = await call.value
            guard case let .result(answer) = outcome, answer.structuredContent?["status"] == "running", let id = answer.structuredContent?["job_id"]?.stringValue else {
                throw BridgeFailure("Both slow calls detach: \(outcome)")
            }
            jobIDs.append(id)
            answeredAfter.append(elapsed)
        }
        try expect(answeredAfter[1] < 0.8, "The queued call answers within the threshold of its arrival, not after two: \(answeredAfter)")
        for id in jobIDs {
            let outcome = await queued.call(toolName: "wait_for_job", arguments: ["job_id": id, "timeout_seconds": 10], workingDirectory: nil, clientName: "test", progress: nil)
            guard case let .result(done) = outcome, done.text == "Waited 1.5 s." else { throw BridgeFailure("Each queued job finishes: \(outcome)") }
        }

        // A call that waited for the person's approval can find the turn held
        // by a call that arrived after it, which only detaches a threshold
        // after its own arrival. The waiter's time runs out first: it answers
        // "waiting_for_turn" without running (heartbeats until then), and
        // calling again runs it.
        let started = BridgeFlag()
        let late = MCPToolSpec(tool: SlowTool(name: "slow_late", cancelled: BridgeFlag(), started: started), title: "Slow", description: "Sleeps for the given seconds, taking a turn like the calls that navigate.",
                               scope: .global, annotations: .reads, navigates: true)
        let turns = AutomationBridge(model: fixture.model, catalog: MCPToolCatalog(tools: MCPToolCatalog.v1.tools + [navigating, late]), jobs: AutomationJobs(detachAfter: 1))
        turns.turnHeartbeatInterval = 0.05
        let holder = Task { @MainActor in
            await turns.call(toolName: "slow_tool", arguments: ["seconds": 3], workingDirectory: nil, clientName: "test", progress: nil)
        }
        try await waitUntil("the later call to hold the turn") { turns.queue.isBusy }
        let beats = ProgressRecorder()
        let arrivedEarlier = Date().addingTimeInterval(-0.5)
        let waitedAt = Date()
        let waiting = await turns.call(toolName: "slow_late", arguments: ["seconds": 0.1], workingDirectory: nil, clientName: "test", arrivedAt: arrivedEarlier,
                                       progress: { beats.record($0, $1, $2) })
        let answeredAt = Date().timeIntervalSince(arrivedEarlier)
        guard case let .result(turnless) = waiting else { throw BridgeFailure("The waiting call must answer: \(waiting)") }
        try expect(turnless.isError && turnless.structuredContent == ["status": "waiting_for_turn", "tool": "slow_late", "retry": true]
                   && turnless.text.contains("slow_late has not run yet") && turnless.text.contains("Call slow_late again"), "Out of time for a turn: \(turnless.json)")
        try expect(answeredAt >= 1 && answeredAt < 1.5 && Date().timeIntervalSince(waitedAt) < 1.2, "It answers about a threshold (plus the grace) after its arrival: \(answeredAt) s")
        try expect(!started.isRaised && turns.queue.waitingCount == 0, "Its tool never ran, and it left the queue")
        let values = beats.values
        try expect(values.count >= 5 && zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
                   && values.allSatisfy { $0 > AutomationBridge.turnHeartbeatBase && $0 < AutomationAudioConsentController.heartbeatBase },
                   "Heartbeats while it waited, between the approval's and the sound prompt's: \(values)")
        guard case let .result(held) = await holder.value, held.structuredContent?["status"] == "running" else { throw BridgeFailure("The holder detaches as usual") }
        let retried = try await fixture.succeed(turns, "slow_late", ["seconds": 0.1])
        try expect(retried.text == "Waited 0.1 s." && started.isRaised, "Called again, it runs: \(retried.text)")
    }

    private static func waitUntil(_ message: String, predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            if ContinuousClock.now >= deadline { throw BridgeFailure(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw BridgeFailure(message) }
    }
}

// MARK: - Fixtures

private struct BridgeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class BridgeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    func raise() { lock.lock(); raised = true; lock.unlock() }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ completed: Double, _ total: Double?, _ message: String?) { lock.lock(); recorded.append(completed); lock.unlock() }
}

/// Answers the in-app assistant from a script. Before the reply numbered
/// `pauseBefore` (from 1) it waits for the test to open the gate, so the
/// assistant's turn stays running between two tool steps.
private final class PausingCompletion: TextCompletionProviding, @unchecked Sendable {
    let paused = BridgeFlag()
    let gate = BridgeFlag()
    private let pauseBefore: Int
    private let lock = NSLock()
    private var replies: [String]
    private var calls = 0

    init(_ replies: [String], pauseBefore: Int) {
        self.replies = replies
        self.pauseBefore = pauseBefore
    }

    func complete(system: String, user: String, json: Bool) async throws -> String {
        let (call, reply) = lock.withLock { () -> (Int, String?) in
            calls += 1
            return (calls, replies.isEmpty ? nil : replies.removeFirst())
        }
        if call == pauseBefore {
            paused.raise()
            while !gate.isRaised { try await Task.sleep(for: .milliseconds(5)) }
        }
        guard let reply else { throw BridgeFailure("No scripted reply is left") }
        return reply
    }
}

/// Sleeps for `seconds`, reporting progress every 0.1 s, and notes that it
/// started and whether it was cancelled.
private struct SlowTool: AIAssistantTool {
    var name = "slow_tool"
    let summary = "Sleep."
    let cancelled: BridgeFlag
    var started: BridgeFlag?
    var parametersSchema: [String: Any] { ["type": "object", "properties": ["seconds": ["type": "number"]]] }

    func run(arguments: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        started?.raise()
        let seconds = (arguments["seconds"] as? NSNumber)?.doubleValue ?? 1
        let steps = max(1, Int(seconds * 10))
        do {
            for step in 1...steps {
                try await Task.sleep(for: .milliseconds(100))
                context.numericProgress?(Double(step) / Double(steps), 1, nil)
            }
        } catch {
            cancelled.raise()
            throw error
        }
        return AIToolResult(text: "Waited \(String(format: "%.1f", seconds)) s.", data: ["seconds": AIJSONValue(seconds)])
    }
}

/// A temporary library with two projects made from a real clip, a fake
/// Trash, a working directory for the client, and a model on top.
@MainActor
private final class BridgeFixture {
    let root: URL
    let library: URL
    let trash: URL
    let cwd: URL
    let clip: URL
    let screenshot: URL
    let store: ProjectStore
    let model: StudioModel
    let projects: [RecordingProject]

    init(assistantCompletion: (any TextCompletionProviding)? = nil) async throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory.appendingPathComponent("FocusStudio-Bridge-Test-\(UUID().uuidString)", isDirectory: true)
        library = root.appendingPathComponent("Projects", isDirectory: true)
        trash = root.appendingPathComponent("Trash", isDirectory: true)
        cwd = root.appendingPathComponent("client", isDirectory: true)
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cwd, withIntermediateDirectories: true)
        let trashFolder = trash
        store = ProjectStore(projectsDirectory: library, trashOperation: { url in
            try FileManager.default.moveItem(at: url, to: trashFolder.appendingPathComponent(url.lastPathComponent))
        })
        model = StudioModel(store: store, interactionTrackingAccess: { true }, inputMonitoringAccess: { true }, screenCaptureAccess: { true },
                            assistantCompletion: assistantCompletion)

        screenshot = cwd.appendingPathComponent("shot.png")
        try Self.writeImage(to: screenshot)
        clip = cwd.appendingPathComponent("clip.mp4")
        _ = try await StillImageVideoBuilder.build(from: screenshot, to: clip, duration: 1, renderSize: CGSize(width: 64, height: 64))
        try Data("notes".utf8).write(to: cwd.appendingPathComponent("notes.txt"))
        var created: [RecordingProject] = []
        for title in ["First", "Second"] {
            created.append(try await store.createProject(from: clip, title: title, cursorSamples: [], clickEvents: [ClickEvent(time: 0.4, x: 0.3, y: 0.3, button: .left)]))
        }
        projects = created
        await model.reloadProjects()
        guard model.projects.count == 2 else { throw BridgeFailure("The fixture library did not load") }
    }

    var trashed: [String] { (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [] }

    func succeed(_ bridge: AutomationBridge, _ tool: String, _ arguments: [String: Any], cwd: URL? = nil) async throws -> MCPToolCallResult {
        let outcome = await bridge.call(toolName: tool, arguments: arguments, workingDirectory: cwd, clientName: "test", progress: nil)
        guard case let .result(result) = outcome, !result.isError else { throw BridgeFailure("\(tool) must succeed: \(outcome)") }
        return result
    }

    func fail(_ bridge: AutomationBridge, _ tool: String, _ arguments: [String: Any], cwd: URL? = nil) async throws -> MCPToolCallResult {
        let outcome = await bridge.call(toolName: tool, arguments: arguments, workingDirectory: cwd, clientName: "test", progress: nil)
        guard case let .result(result) = outcome, result.isError else { throw BridgeFailure("\(tool) must fail as a tool result: \(outcome)") }
        return result
    }

    func metadata(_ id: UUID) throws -> Data {
        try Data(contentsOf: library.appendingPathComponent("\(id.uuidString)/project.json"))
    }

    func saved(_ id: UUID) throws -> RecordingProject {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingProject.self, from: metadata(id))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    private static func writeImage(to url: URL) throws {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BridgeFailure("Could not create a bitmap context")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 8, y: 8, width: 24, height: 12))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw BridgeFailure("Could not encode the fixture image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BridgeFailure("Could not write the fixture image") }
    }
}
