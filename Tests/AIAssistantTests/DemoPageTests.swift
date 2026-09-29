import Foundation

extension AIAssistantTests {
    @MainActor
    static func demoPageArguments(root: URL) async throws {
        let bare = try AIDemoPageURL.parse(" finlyze.ai/dashboard ")
        let local = try AIDemoPageURL.parse("http://localhost:3000/demo")
        check(bare.absoluteString == "https://finlyze.ai/dashboard", "launcher accepts a bare website with https")
        check(local.port == 3000, "local development websites remain supported")
        let (context, app, _) = makeFakeApp(root: root)
        let tool = PrepareDemoPageTool()
        let result = try await tool.run(arguments: ["url": "finlyze.ai/dashboard"], context: context, progress: { _ in })
        check(app.demoPageCalls.count == 1 && app.demoPageCalls[0].0.absoluteString == "https://finlyze.ai/dashboard"
              && app.demoPageCalls[0].1 == .automatic, "validated URL and browser selection reach app once")
        check(result.data?["status"] == "page_opened" && result.data?["source"]?["id"] == "win-1"
              && result.data?["recording_options"]?["interaction_mode"] == "codex"
              && result.data?["recording_options"]?["automatic_zooms"] == true,
              "preparation returns exact source and tracked recording defaults")
        check(result.text.contains("not started") && app.startedSourceIDs.isEmpty, "preparation cannot silently start a recording")
        _ = try await tool.run(arguments: ["url": "https://finlyze.ai/dashboard", "browser": "safari"], context: context, progress: { _ in })
        check(app.demoPageCalls.last?.1 == .safari, "explicit browser choice is preserved")
        let before = app.demoPageCalls.count
        for value in ["", "file:///etc/passwd", "javascript:alert(1)", "ftp://example.com", "https://", "https://user:secret@example.com", "https://example.com:70000", "https://bad host.com", "https://example.com/\nnew"] {
            await expectToolError("invalid demo URL \(value)", {
                _ = try await tool.run(arguments: ["url": value], context: context, progress: { _ in })
            }, { if case .invalidArgument = $0 { return true }; return false })
        }
        for arguments: [String: Any] in [[:], ["url": 12], ["url": "https://example.com", "browser": "edge"], ["url": "https://example.com", "browser": true]] {
            await expectToolError("invalid page preparation arguments", {
                _ = try await tool.run(arguments: arguments, context: context, progress: { _ in })
            }, { if case .invalidArgument = $0 { return true }; return false })
        }
        check(app.demoPageCalls.count == before, "invalid requests never open a browser")
    }
}
