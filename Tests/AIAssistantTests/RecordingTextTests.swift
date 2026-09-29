import Foundation

extension AIAssistantTests {
    @MainActor
    static func recordingTextArguments(root: URL) async throws {
        let (context, _, _) = makeFakeApp(root: root)
        let tool = PerformRecordingTextTool()
        let valid: [String: Any] = ["recording_id": UUID().uuidString, "observation_id": UUID().uuidString,
                                    "action_id": "demo-text-once", "text": "分析 NVDA 的公开资料 👩‍💻"]
        for text in [" demo text ", "中文搜索", "👩‍💻", String(repeating: "中", count: 1000)] {
            try AIRecordingText.validate(text)
        }
        let invalid: [(String, Any)] = [
            ("recording_id", "bad-id"), ("observation_id", "bad-id"), ("action_id", ""),
            ("action_id", String(repeating: "a", count: 129)), ("text", 123), ("text", true),
            ("text", ""), ("text", "   "), ("text", "demo\nsubmit"), ("text", "demo\rsubmit"),
            ("text", "demo\tother"), ("text", "demo\u{0}other"), ("text", "demo\u{2028}submit"),
            ("text", String(repeating: "中", count: 1001)),
        ]
        for (key, value) in invalid {
            var args = valid; args[key] = value
            await expectToolError("invalid text argument \(key)", {
                _ = try await tool.run(arguments: args, context: context, progress: { _ in })
            }, { if case .invalidArgument = $0 { return true }; return false })
        }
        for key in ["recording_id", "observation_id", "action_id", "text"] {
            var args = valid; args.removeValue(forKey: key)
            await expectToolError("missing text argument \(key)", {
                _ = try await tool.run(arguments: args, context: context, progress: { _ in })
            }, { if case .invalidArgument = $0 { return true }; return false })
        }
        var unavailable = context
        unavailable.app = nil
        await expectToolError("valid Unicode passes validation before app dispatch", {
            _ = try await tool.run(arguments: valid, context: unavailable, progress: { _ in })
        }, { $0 == .appUnavailable })
    }
}
