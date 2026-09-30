import FocusStudioCore
import Foundation

extension AIAssistantTests {
    @MainActor
    static func timelineEditingTools(root: URL) async throws {
        let source = makeProject(sourceVideoPath: "/original-demo.mov", duration: 6)
        let box = ProjectBox(source)
        let app = FakeApp(box: box)
        app.projects = [source]
        app.openID = source.id
        var context = makeContext(root: root, box: box)
        context.app = app

        let initial = try await GetTimelineTool().run(arguments: ["project_id": source.id.uuidString], context: context, progress: { _ in })
        let initialData = try structured(initial, "get_timeline")
        check(initialData["clip_count"]?.intValue == 1 && initialData["duration"]?.doubleValue == 6, "a legacy recording exposes one editable clip before any mutation")
        guard let firstID = initialData["clips"]?[0]?["id"]?.stringValue else { fatalError("FAIL: initial clip ID") }

        let split = try await SplitClipTool().run(arguments: ["project_id": source.id.uuidString, "clip_id": firstID, "at": 2.0], context: context, progress: { _ in })
        let splitData = try structured(split, "split_clip")
        guard let copyID = splitData["project_id"]?.stringValue,
              let leftID = splitData["clips"]?[0]?["id"]?.stringValue,
              let rightID = splitData["clips"]?[1]?["id"]?.stringValue else { fatalError("FAIL: split receipt IDs") }
        check(copyID != source.id.uuidString && leftID == firstID && rightID != firstID && splitData["clip_count"]?.intValue == 2,
              "first split returns a separate working project and stable/unique clip IDs")
        check(app.projects.first == source && app.videoEditCalls.count == 1, "source project remains untouched by a clip edit")

        let projectID = copyID
        let trim = try await TrimClipTool().run(arguments: ["project_id": projectID, "clip_id": leftID, "source_start": 0.5, "source_end": 2.0], context: context, progress: { _ in })
        let trimmed = try structured(trim, "trim_clip")
        check(trimmed["project_id"]?.stringValue == projectID && trimmed["duration"]?.doubleValue == 5.5
              && trimmed["clips"]?[0]?["id"]?.stringValue == leftID && trimmed["clips"]?[0]?["source_start"]?.doubleValue == 0.5,
              "trim keeps the clip identity, applies source in/out points and retimes the track")

        let transition = try await SetTransitionTool().run(arguments: ["project_id": projectID, "clip_id": leftID, "preset": "fadeToBlack", "duration": 0.4], context: context, progress: { _ in })
        check(transition.data?["clips"]?[0]?["transition_after"]?["preset"]?.stringValue == "fadeToBlack"
              && transition.data?["clips"]?[0]?["transition_after"]?["duration"]?.doubleValue == 0.4
              && transition.data?["clips"]?[0]?["transition_after"]?["outgoing_duration"]?.doubleValue == 0.2
              && transition.data?["clips"]?[0]?["transition_after"]?["incoming_duration"]?.doubleValue == 0.2,
              "an existing symmetric transition call reports its effective in/out durations")
        let shaped = try await SetTransitionTool().run(arguments: [
            "project_id": projectID, "clip_id": leftID, "preset": "fadeToBlack", "duration": 0.4,
            "outgoing_duration": 0.1, "incoming_duration": 0.3,
            "outgoing_curve": "easeIn", "incoming_curve": "easeOut",
        ], context: context, progress: { _ in })
        let shapedReceipt = shaped.data?["clips"]?[0]?["transition_after"]
        check(shapedReceipt?["duration"]?.doubleValue == 0.4
              && shapedReceipt?["outgoing_duration"]?.doubleValue == 0.1
              && shapedReceipt?["incoming_duration"]?.doubleValue == 0.3
              && shapedReceipt?["outgoing_curve"]?.stringValue == "easeIn"
              && shapedReceipt?["incoming_curve"]?.stringValue == "easeOut",
              "Codex can set independently timed and curved transition sides and inspect the result")
        let reread = try await GetTimelineTool().run(arguments: ["project_id": projectID], context: context, progress: { _ in })
        check(reread.data?["clips"]?[0]?["transition_after"] == shapedReceipt,
              "get_timeline returns the persisted transition parameters, not only the edit receipt")
        let beforeInvalidTransition = box.project
        let beforeInvalidCalls = app.videoEditCalls.count
        await expectThrows("side durations must sum to the overall transition duration") {
            _ = try await SetTransitionTool().run(arguments: [
                "project_id": projectID, "clip_id": leftID, "preset": "flash", "duration": 0.4,
                "outgoing_duration": 0.1, "incoming_duration": 0.2,
            ], context: context, progress: { _ in })
        }
        await expectThrows("both side durations are required") {
            _ = try await SetTransitionTool().run(arguments: [
                "project_id": projectID, "clip_id": leftID, "preset": "flash", "duration": 0.4,
                "outgoing_duration": 0.1,
            ], context: context, progress: { _ in })
        }
        await expectThrows("an unknown visual curve is rejected") {
            _ = try await SetTransitionTool().run(arguments: [
                "project_id": projectID, "clip_id": leftID, "preset": "flash", "duration": 0.4,
                "outgoing_duration": 0.1, "incoming_duration": 0.3, "incoming_curve": "bounce",
            ], context: context, progress: { _ in })
        }
        await expectThrows("a transition side cannot exceed its adjacent clip") {
            _ = try await SetTransitionTool().run(arguments: [
                "project_id": projectID, "clip_id": leftID, "preset": "flash", "duration": 1.7,
                "outgoing_duration": 1.6, "incoming_duration": 0.1,
            ], context: context, progress: { _ in })
        }
        check(box.project == beforeInvalidTransition && app.videoEditCalls.count == beforeInvalidCalls,
              "invalid transition parameters leave the working project and edit history unchanged")
        let audio = try await SetClipAudioTool().run(arguments: ["project_id": projectID, "clip_id": leftID, "volume": 0.0], context: context, progress: { _ in })
        check(audio.data?["clips"]?[0]?["source_audio_volume"]?.doubleValue == 0,
              "clip-audio receipt identifies the muted segment")

        let moved = try await MoveClipTool().run(arguments: ["project_id": projectID, "clip_id": rightID, "to_index": 0], context: context, progress: { _ in })
        check(moved.data?["clips"]?[0]?["id"]?.stringValue == rightID, "reorder changes output order without changing IDs")
        let removed = try await DeleteClipTool().run(arguments: ["project_id": projectID, "clip_id": rightID], context: context, progress: { _ in })
        let afterDeletion = box.project
        check(removed.data?["clip_count"]?.intValue == 1 && removed.data?["clips"]?[0]?["id"]?.stringValue == leftID,
              "delete removes only the identified clip from the editable copy")
        let undoDeletion = try await UndoClipEditTool().run(arguments: ["project_id": projectID], context: context, progress: { _ in })
        let undoReorder = try await UndoClipEditTool().run(arguments: ["project_id": projectID], context: context, progress: { _ in })
        check(undoDeletion.data?["clips"]?[0]?["id"]?.stringValue == rightID
              && undoReorder.data?["clips"]?[0]?["id"]?.stringValue == leftID
              && undoReorder.data?["project_id"]?.stringValue == projectID,
              "repeated undo restores the last two clip operations while retaining the working project ID")
        check(app.projects.first == source, "postproduction tools leave the source value and identity unchanged")

        // Identical arguments address the next history entry each time. Check
        // the conversation replay guard as well as the direct tool methods.
        let redoArguments = "{\"project_id\":\"\(projectID)\"}"
        let provider = ScriptedCompletion([
            action("redo_clip_edit", redoArguments),
            action("redo_clip_edit", redoArguments),
            reply("Both edits restored.")
        ])
        let session = AIAssistantSession(context: context, completion: provider,
                                         tools: [RedoClipEditTool()])
        session.send("Redo the last two undone video edits in this project.")
        try await waitUntil("two consecutive redos in one request") { !session.isRunning }
        check(box.project == afterDeletion && app.videoEditRedo[box.project!.id]?.isEmpty == true,
              "one conversation request can redo both the reorder and deletion with the same project arguments")
        check(session.messages.last?.role == .assistant && session.messages.last?.text == "Both edits restored."
                && !session.messages.contains { $0.role == .error },
              "repeated redo reaches the normal final reply without an error")
        check(app.projects.first == source, "conversation redo leaves the original source untouched")

        let prior = box.project
        let calls = app.videoEditCalls.count
        await expectThrows("invalid transition duration") {
            _ = try await SetTransitionTool().run(arguments: ["project_id": projectID, "clip_id": leftID, "preset": "flash", "duration": 9], context: context, progress: { _ in })
        }
        await expectThrows("nonexistent clip ID") {
            _ = try await TrimClipTool().run(arguments: ["project_id": projectID, "clip_id": UUID().uuidString, "source_start": 0, "source_end": 1], context: context, progress: { _ in })
        }
        check(app.videoEditCalls.count == calls && box.project == prior, "invalid operations never partly change the visible timeline")
    }
}
