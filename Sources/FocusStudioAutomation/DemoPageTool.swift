import Foundation

public enum AIDemoBrowser: String, CaseIterable, Sendable {
    case automatic, chrome, safari
}

public enum AIDemoPageURL {
    /// The launcher and the conversational tool share the same URL contract.
    public static func parse(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitScheme = trimmed.contains("://")
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: explicitScheme ? trimmed : "https://" + trimmed),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url else {
            throw AIToolError.invalidArgument("Enter a complete http or https website address without an embedded username or password.")
        }
        return url
    }
}

public struct AIPreparedDemoPage: Equatable, Sendable {
    public var url: URL
    public var source: AIRecordingSource
    public var browserName: String
    public var options: AIRecordingOptions

    public init(url: URL, source: AIRecordingSource, browserName: String) {
        self.url = url
        self.source = source
        self.browserName = browserName
        self.options = AIRecordingOptions(systemAudio: false, microphone: false, automaticZooms: true,
                                          browserContentOnly: true, frameRate: 60, interactionMode: "codex")
    }

    var data: AIJSONValue {
        ["status": "page_opened", "url": AIJSONValue(url.absoluteString), "browser": AIJSONValue(browserName),
         "source": source.data,
         "recording_options": ["interaction_mode": "codex", "automatic_zooms": true,
                               "browser_content_only": true, "system_audio": false, "microphone": false, "frame_rate": 60]]
    }
}

struct PrepareDemoPageTool: AIAssistantTool {
    let name = "prepare_demo_page"
    let summary = "Open the requested website in a visible Chrome or Safari window and identify that exact recordable window. This only prepares the page, without starting a recording. Use only when asked to open or prepare the website. The page can still require login or finish loading: inspect a fresh frame after starting before choosing any action."
    var parametersSchema: [String: Any] {
        ["type": "object", "required": ["url"], "properties": [
            "url": ["type": "string", "description": "The website to show, using http or https."],
            "browser": ["type": "string", "enum": AIDemoBrowser.allCases.map(\.rawValue),
                        "description": "automatic prefers installed Chrome, then Safari. Default automatic."],
        ]]
    }

    func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        guard let value = raw["url"] as? String else { throw AIToolError.invalidArgument("url must be a website address.") }
        let url = try AIDemoPageURL.parse(value)
        let browser: AIDemoBrowser
        if let value = raw["browser"] {
            guard let name = value as? String, let parsed = AIDemoBrowser(rawValue: name) else {
                throw AIToolError.invalidArgument("browser must be automatic, chrome or safari.")
            }
            browser = parsed
        } else { browser = .automatic }
        let app = try AIToolSupport.requireApp(context)
        let page = try await AIToolSupport.appAction(context) { try await app.prepareDemoPage(url: url, browser: browser) }
        return AIToolResult(text: "Opened \(page.url.absoluteString) in \(page.browserName). Prepared visible source: \(page.source.displayName) (\(page.source.id)). Recording has not started. Next call run_demo_task with source_id \(page.source.id) and the user's goal to show one task review. The session checks the page before recording and owns its bounded recording and automatic save. Do not use raw start_recording. This receipt is not evidence of page content.", data: page.data)
    }
}

/// A session-owned handoff, intentionally absent from external MCP. The
/// session validates the exact target, asks once, then owns capture cleanup.
struct RunDemoTaskTool: AIAssistantTool {
    let name = "run_demo_task"
    let summary = "Propose one bounded interactive demo of an exact prepared window. The app shows its window, goal and limits for one Start approval, checks the visible page before recording, then observes/clicks/scrolls and saves automatically. Use this instead of start_recording for an AI-operated product demo."
    var parametersSchema: [String: Any] {
        ["type": "object", "required": ["source_id", "goal"], "properties": [
            "source_id": ["type": "string", "description": "Exact window source id returned by prepare_demo_page or list_recording_sources."],
            "goal": ["type": "string", "description": "The user's requested demonstration: visible navigation, scrolling, and explicitly requested non-sensitive product AI/search submission. No purchases, deletions, financial/account forms, credentials or communication with other people."],
            "max_seconds": ["type": "number", "minimum": 1, "maximum": 300, "description": "Total recording task limit including model thinking and pauses. Default 120."],
            "max_actions": ["type": "integer", "minimum": 1, "maximum": 12, "description": "Maximum pointer actions. Default 6."],
            "allow_text_input": ["type": "boolean", "description": "Request approval for short non-sensitive demo text in the recorded page, only if the user's goal requires it. Default false. Never passwords, account/payment data or implicit submission."],
        ]]
    }
    func run(arguments: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        throw AIToolError.failed("A demo task must run through the in-app assistant's task approval and recording owner.")
    }
}
