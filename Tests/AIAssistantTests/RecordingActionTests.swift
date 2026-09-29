import Foundation

extension AIAssistantTests {
    @MainActor
    static func recordingActionArguments(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)
        let recordingID = UUID(), observationID = UUID()
        let valid: [String: Any] = [
            "recording_id": recordingID.uuidString, "observation_id": observationID.uuidString,
            "action_id": "click-once", "action": "click", "x": 0.25, "y": 0.75,
        ]
        let tool = PerformRecordingActionTool()
        let receipt = try await tool.run(arguments: valid, context: context, progress: { _ in })
        check(receipt.data?["status"] == "performed" && app.recordingActionCalls.count == 1, "action returns app receipt")
        let delivered = app.recordingActionCalls[0]
        check(delivered.recordingID == recordingID && delivered.observationID == observationID && delivered.actionID == "click-once",
              "recording/action/observation identities reach the app unchanged")
        check(delivered.action.type == .click && delivered.action.x == 0.25 && delivered.action.y == 0.75
              && delivered.action.seconds == 0.45, "uncropped normalized coordinates and default approach duration reach runner")
        var move = valid
        move["action"] = "move"
        move["seconds"] = 0.2
        _ = try await tool.run(arguments: move, context: context, progress: { _ in })
        check(app.recordingActionCalls.last?.action.type == .move && app.recordingActionCalls.last?.action.seconds == 0.2,
              "move has explicit duration")
        var scroll = valid
        scroll["action"] = "scroll"
        scroll["delta_y"] = 230
        scroll["delta_x"] = -40
        _ = try await tool.run(arguments: scroll, context: context, progress: { _ in })
        check(app.recordingActionCalls.last?.action.deltaX == -40 && app.recordingActionCalls.last?.action.deltaY == 230,
              "scroll direction and distance reach app unchanged")
        let before = app.recordingActionCalls.count
        let invalid: [(String, Any)] = [
            ("recording_id", "not-a-uuid"), ("observation_id", "not-a-uuid"), ("action_id", ""),
            ("action_id", String(repeating: "a", count: 129)), ("action", "navigate"), ("action", "type"),
            ("x", -0.1), ("x", 1.1), ("y", Double.nan), ("x", Double.infinity), ("x", true),
            ("seconds", 0), ("seconds", 3.01), ("seconds", Double.nan), ("seconds", "quick"),
            ("delta_x", 1201), ("delta_y", Double.infinity), ("delta_y", "down"),
        ]
        for (key, value) in invalid {
            var arguments = valid
            arguments[key] = value
            await expectToolError("invalid \(key)=\(value)", {
                _ = try await tool.run(arguments: arguments, context: context, progress: { _ in })
            }, { if case .invalidArgument = $0 { return true }; return false })
        }
        for key in ["recording_id", "observation_id", "action_id", "action", "x", "y"] {
            var arguments = valid
            arguments.removeValue(forKey: key)
            await expectToolError("missing \(key)", {
                _ = try await tool.run(arguments: arguments, context: context, progress: { _ in })
            }, { if case .invalidArgument = $0 { return true }; return false })
        }
        var zeroScroll = valid
        zeroScroll["action"] = "scroll"
        await expectToolError("zero scroll", {
            _ = try await tool.run(arguments: zeroScroll, context: context, progress: { _ in })
        }, { if case .invalidArgument = $0 { return true }; return false })
        check(app.recordingActionCalls.count == before, "rejected arguments never reach native app execution")

        let frame = try await CaptureRecordingFrameTool().run(arguments: ["recording_id": recordingID.uuidString], context: context, progress: { _ in })
        check(app.recordingFrameCalls.count == 1 && app.recordingFrameCalls[0].recordingID == recordingID,
              "live observation identifies its recording")
        check(frame.attachments == [app.recordingFrameCalls[0].url]
              && frame.data?["coordinate_space"] == "normalized_uncropped_source", "observation exposes the exact attached image coordinate contract")
        await expectToolError("invalid observation session", {
            _ = try await CaptureRecordingFrameTool().run(arguments: ["recording_id": "missing"], context: context, progress: { _ in })
        }, { if case .invalidArgument = $0 { return true }; return false })
        check(app.recordingFrameCalls.count == 1, "invalid observation does not capture any pixels")

        await expectToolError("Codex display source", {
            _ = try await StartRecordingTool().run(arguments: ["source": "display-1", "interaction_mode": "codex"], context: context, progress: { _ in })
        }, { if case .invalidArgument = $0 { return true }; return false })
        await expectToolError("unknown interaction mode", {
            _ = try await StartRecordingTool().run(arguments: ["source": "win-1", "interaction_mode": "guess"], context: context, progress: { _ in })
        }, { if case .invalidArgument = $0 { return true }; return false })
        check(app.startedSourceIDs.isEmpty, "invalid execution mode never starts a recording")
        let started = try await StartRecordingTool().run(arguments: ["source": "win-1", "interaction_mode": "codex", "system_audio": false, "microphone": false],
                                                       context: context, progress: { _ in })
        check(app.startedOptions.last?.interactionMode == "codex" && app.attemptSettings.last?.interactionMode == "codex",
              "Codex mode is carried through the recording start contract")
        check(started.text.contains("perform_recording_action") && started.data?["options"]?["interaction_mode"] == "codex",
              "A successful start teaches the client the tracked action path")
        await app.stopRecording()
    }
}
