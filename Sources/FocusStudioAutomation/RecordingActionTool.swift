import CoreFoundation
import FocusStudioCore
import Foundation

/// The client observes the target, then asks the recorder to execute the same
/// pointer path it will later render. Arbitrary browser input is not intercepted.
struct PerformRecordingActionTool: AIAssistantTool {
    let name = "perform_recording_action"
    let summary = "Move, click or scroll inside the current recorded window, recording the actual dispatched mouse path for cursor animation and automatic zooms. Requires a live start_recording with interaction_mode codex. Observe the current window before choosing coordinates; never guess controls."

    var parametersSchema: [String: Any] {
        ["type": "object", "required": ["recording_id", "action_id", "observation_id", "action", "x", "y"], "properties": [
            "recording_id": ["type": "string", "description": "The recording_id returned by start_recording. Stale sessions are refused."],
            "observation_id": ["type": "string", "description": "Fresh observation_id from capture_recording_frame. Valid for one action, the same recording/window geometry, and at most 60 seconds."],
            "action_id": ["type": "string", "description": "A unique id for this intended action, maximum 128 characters. Reuse it only to retrieve the receipt after an uncertain response; it never repeats the input."],
            "action": ["type": "string", "enum": ["move", "click", "scroll"]],
            "x": ["type": "number", "minimum": 0, "maximum": 1, "description": "Observed pointer hotspot x / full uncropped window width, from 0 to 1 from the top-left. Never apply the browser crop."],
            "y": ["type": "number", "minimum": 0, "maximum": 1, "description": "Observed pointer hotspot y / full uncropped window height, from 0 to 1 from the top-left."],
            "seconds": ["type": "number", "minimum": 0.1, "maximum": 3, "description": "Duration of an approach, from 0.1 to 3 recorded seconds. Default 0.45."],
            "delta_x": ["type": "number", "minimum": -1200, "maximum": 1200, "description": "For scroll: horizontal pixels from -1200 to 1200; positive scrolls right."],
            "delta_y": ["type": "number", "minimum": -1200, "maximum": 1200, "description": "For scroll: pixels from -1200 to 1200; positive scrolls down."],
        ]]
    }

    func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let args = AIToolArguments(raw)
        for key in ["x", "y", "seconds", "delta_x", "delta_y"] {
            if let number = raw[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                throw AIToolError.invalidArgument("\(key) must be a number, not a boolean.")
            }
        }
        guard let recordingID = UUID(uuidString: try args.requiredString("recording_id")) else {
            throw AIToolError.invalidArgument("recording_id must be the UUID from start_recording.")
        }
        guard let observationID = UUID(uuidString: try args.requiredString("observation_id")) else {
            throw AIToolError.invalidArgument("observation_id must come from capture_recording_frame.")
        }
        let actionID = try args.requiredString("action_id")
        guard actionID.count <= 128 else { throw AIToolError.invalidArgument("action_id is too long.") }
        guard let type = CodexRecordingActionType(rawValue: try args.requiredString("action")), [.move, .click, .scroll].contains(type),
              let x = args.double("x"), let y = args.double("y"), (0...1).contains(x), (0...1).contains(y) else {
            throw AIToolError.invalidArgument("action must be move, click or scroll with finite normalized x/y between 0 and 1.")
        }
        let seconds = args.double("seconds") ?? 0.45
        guard !args.has("seconds") || (args.double("seconds") != nil && (0.1...3).contains(seconds)) else {
            throw AIToolError.invalidArgument("seconds must be between 0.1 and 3.")
        }
        for key in ["delta_x", "delta_y"] where args.has(key) {
            guard let delta = args.double(key), abs(delta) <= 1200 else { throw AIToolError.invalidArgument("Scroll deltas must be finite and within ±1200 pixels.") }
        }
        let dx = args.double("delta_x") ?? 0, dy = args.double("delta_y") ?? 0
        guard type != .scroll || dx != 0 || dy != 0 else { throw AIToolError.invalidArgument("scroll requires a non-zero delta_x or delta_y.") }
        let app = try AIToolSupport.requireApp(context)
        let action = CodexRecordingAction(type: type, seconds: seconds, x: x, y: y, deltaX: dx, deltaY: dy)
        let result = try await AIToolSupport.appAction(context) {
            try await app.performRecordingAction(recordingID: recordingID, actionID: actionID, observationID: observationID, action: action)
        }
        return AIToolResult(text: "Recording action receipt. Inspect status before continuing; interrupted actions are never retried automatically.\n" + (String(data: try result.jsonData(), encoding: .utf8) ?? ""), data: result)
    }
}

struct CaptureRecordingFrameTool: AIAssistantTool {
    let name = "capture_recording_frame"
    let summary = "Observe the full uncropped live recording window before performing a pointer action. Returns an image and single-use observation_id. Never reuse earlier geometry after an action or navigation."
    var parametersSchema: [String: Any] {
        ["type": "object", "required": ["recording_id"], "properties": ["recording_id": ["type": "string", "description": "The recording_id from start_recording."]]]
    }
    func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let args = AIToolArguments(raw)
        guard let id = UUID(uuidString: try args.requiredString("recording_id")) else { throw AIToolError.invalidArgument("recording_id must be a UUID.") }
        let app = try AIToolSupport.requireApp(context)
        let url = try context.newAssetURL(prefix: "recording-observation", fileExtension: "png")
        let data = try await AIToolSupport.appAction(context) { try await app.captureRecordingFrame(recordingID: id, to: url) }
        return AIToolResult(text: "Fresh full-window recording frame. Normalize observed x/y to this image width/height, without applying any crop. The observation is consumed by the next action.\n" + (String(data: try data.jsonData(), encoding: .utf8) ?? ""), attachments: [url], data: data)
    }
}
