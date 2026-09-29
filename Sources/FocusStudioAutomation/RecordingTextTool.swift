import Foundation

public enum AIRecordingText {
    public static func validate(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 1000, text.utf16.count <= 8000,
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0) }) else {
            throw AIToolError.invalidArgument("Demo text must contain 1–1000 characters without newlines or control characters. It is entered without submitting the form.")
        }
    }
}

public struct PerformRecordingTextTool: AIAssistantTool {
    public init() {}
    public let name = "perform_recording_text"
    public let summary = "Enter demo text into the recorded browser's currently focused, editable, non-password page field. Requires an explicitly text-enabled demo and fresh full-window observation. Focus the observed input with a recorded click first. Never types into browser chrome, uses the clipboard, sends keyboard shortcuts or submits the form. Inspect the next frame to verify the result."
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["recording_id", "action_id", "observation_id", "text"], "properties": [
            "recording_id": ["type": "string", "description": "The active Codex recording session UUID."],
            "action_id": ["type": "string", "description": "Unique intended action ID, at most 128 characters. A repeated ID returns its receipt without typing again."],
            "observation_id": ["type": "string", "description": "Fresh single-use observation_id from capture_recording_frame after the input field was focused."],
            "text": ["type": "string",
                     "description": "Non-sensitive demo or search text. No newlines, control characters, passwords, commands or implicit submission."],
        ]]
    }

    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let args = AIToolArguments(raw)
        guard let recordingID = UUID(uuidString: try args.requiredString("recording_id")),
              let observationID = UUID(uuidString: try args.requiredString("observation_id")) else {
            throw AIToolError.invalidArgument("recording_id and observation_id must be UUIDs from the live recording and its fresh frame.")
        }
        let actionID = try args.requiredString("action_id")
        guard actionID.count <= 128 else { throw AIToolError.invalidArgument("action_id is too long.") }
        guard let text = raw["text"] as? String else { throw AIToolError.invalidArgument("text must be a string.") }
        try AIRecordingText.validate(text)
        let app = try AIToolSupport.requireApp(context)
        let data = try await AIToolSupport.appAction(context) {
            try await app.performRecordingText(recordingID: recordingID, actionID: actionID, observationID: observationID, text: text)
        }
        return AIToolResult(text: "Text entry receipt. No submit key was sent. Capture and inspect the resulting field before continuing. Interrupted entry is never retried automatically.\n" + (String(data: try data.jsonData(), encoding: .utf8) ?? ""), data: data)
    }
}
