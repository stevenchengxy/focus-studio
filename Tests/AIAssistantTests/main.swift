import AppKit
@preconcurrency import AVFoundation
import FocusStudioCore
import Foundation

/// Offline coverage for the AI assistant module: the strict JSON protocol,
/// the agent loop driven by a scripted model, the confirmation gate for paid
/// tools, tool argument validation, write safety (dropped and interleaved
/// edits), the app-control tools against a fake app (record → stop → library →
/// zooms → music → export paths and the export guard), AVFoundation clip
/// assembly and the Ark client (request bodies plus a generate → poll →
/// download round trip against the local Python fixture in fake-ark.py).
@main
struct AIAssistantTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIAssistantTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        step("protocol parsing"); protocolParsing()
        step("scripted agent loop"); try await scriptedAgentLoop(root: root)
        step("confirmation flow"); try await confirmationFlow(root: root)
        step("stop while thinking"); try await stopWhileThinking(root: root)
        step("model resolver"); try await modelResolver(root: root)
        step("update_settings"); try await updateSettingsValidation(root: root)
        step("set_chapters"); try await setChaptersSanitization(root: root)
        step("dropped writes"); try await droppedWrites(root: root)
        step("interleaved edits"); try await interleavedEdits(root: root)
        step("app control: recording"); try await recordingControl(root: root)
        step("app control: permission, main display, joined stops"); try await recordingEdgeCases(root: root)
        step("app control: library"); try await libraryControl(root: root)
        step("zoom tools"); try await zoomTools(root: root)
        step("audio tools"); try await audioTools(root: root)
        step("export paths"); try exportPaths(root: root)
        step("export guard"); try await exportGuard(root: root)
        step("assemble_video"); try await assembleVideo(root: root)
        step("Ark request bodies"); try arkRequestBodies()
        step("Ark fixture round trip"); try await arkFixtureRoundTrip(root: root)
        print("AIAssistantTests: PASS (protocol parsing, scripted agent loop, confirmation gate, stop, model resolver, update_settings incl. export width/frame rate, set_chapters, dropped writes, interleaved edits, app control (sources/start/stop/library, permission errors, main display, joined stops), zoom tools, audio tools, export paths, export guard, assemble_video, Ark request bodies, Ark fixture round trip incl. tools)")
    }

    // MARK: - Helpers

    static func step(_ name: String) {
        print("AIAssistantTests: \(name)")
        fflush(stdout)
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        guard condition() else { fatalError("FAIL: \(message)", file: file, line: line) }
    }

    @MainActor
    static func waitUntil(timeout: TimeInterval = 30, _ message: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { fatalError("FAIL: timed out waiting for \(message)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static func expectThrows(_ message: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            fatalError("FAIL: expected an error: \(message)")
        } catch {
            // expected
        }
    }

    /// Holds the "open project" for a test context. Tools read and write it
    /// through the MainActor closures exactly as the editor will.
    @MainActor
    final class ProjectBox {
        var project: RecordingProject?
        /// Edits that reached the project; an atomic tool call makes exactly one.
        var writeCount = 0
        /// Runs once, right after the next read and before the tool writes: an
        /// edit from a parallel call or the user, or the editor closing.
        var afterNextRead: (() -> Void)?
        init(_ project: RecordingProject?) { self.project = project }
    }

    @MainActor
    static func makeContext(root: URL, box: ProjectBox, arkBaseURL: URL = ArkMediaClient.defaultBaseURL, key: String? = "FAKE-TEST-KEY") -> AIAssistantContext {
        AIAssistantContext(
            assetsDirectory: root.appendingPathComponent("assets", isDirectory: true),
            uiLanguage: "en",
            readProject: {
                let snapshot = box.project
                if let interleaved = box.afterNextRead {
                    box.afterNextRead = nil
                    interleaved()
                }
                return snapshot
            },
            updateProject: { change in
                // Like the app: with no project open the edit is refused, never dropped.
                guard var project = box.project else { throw AIToolError.noProject }
                try change(&project)
                box.project = project
                box.writeCount += 1
            },
            arkAPIKey: { key },
            arkBaseURL: arkBaseURL
        )
    }

    static func makeProject(sourceVideoPath: String, duration: Double, width: Int = 640, height: Int = 360) -> RecordingProject {
        RecordingProject(
            title: "Fixture recording",
            sourceVideoPath: sourceVideoPath,
            duration: duration,
            sourceWidth: width,
            sourceHeight: height,
            cursorSamples: [CursorSample(time: 0, x: 0.5, y: 0.5), CursorSample(time: duration, x: 0.6, y: 0.4)],
            clickEvents: [ClickEvent(time: min(0.5, duration / 2), x: 0.5, y: 0.5, button: .left)],
            zoomSegments: [ZoomSegment(start: 0.2, end: min(1.2, duration), targetX: 0.5, targetY: 0.5, scale: 1.6)]
        )
    }

    // MARK: - Protocol parsing

    static func protocolParsing() {
        if case let .action(tool, arguments, thought) = AIAssistantProtocol.parse(
            "Sure!\n```json\n{\"thought\": \"need an image\", \"action\": {\"tool\": \"generate_image\", \"arguments\": {\"prompt\": \"soft gradient\", \"ratio\": \"16:9\"}}}\n```"
        ) {
            check(tool == "generate_image" && arguments["prompt"] as? String == "soft gradient" && thought == "need an image", "fenced action parses")
        } else {
            fatalError("FAIL: fenced action not parsed")
        }
        if case let .reply(text, suggestions) = AIAssistantProtocol.parse(
            "Here you go: {\"thought\":\"answer\",\"reply\":\"Done: the background is set.\",\"suggestions\":[\"Make it darker\",\"Export\"]} thanks"
        ) {
            check(text == "Done: the background is set." && suggestions == ["Make it darker", "Export"], "prose + JSON reply parses: \(text) \(suggestions)")
        } else {
            fatalError("FAIL: prose + JSON reply not parsed")
        }
        if case let .reply(text, suggestions) = AIAssistantProtocol.parse("I could not decide {oops") {
            check(text == "I could not decide {oops" && suggestions.isEmpty, "invalid JSON becomes a plain reply")
        } else {
            fatalError("FAIL: invalid JSON must become a reply")
        }
        if case let .action(tool, arguments, _) = AIAssistantProtocol.parse("{\"tool\":\"list_assets\",\"arguments\":{}}") {
            check(tool == "list_assets" && arguments.isEmpty, "top-level tool object is tolerated")
        } else {
            fatalError("FAIL: top-level tool object not parsed")
        }
        if case let .reply(text, _) = AIAssistantProtocol.parse("{\"thought\":\"Only a thought\"}") {
            check(text == "Only a thought", "thought-only object becomes the reply")
        } else {
            fatalError("FAIL: thought-only object")
        }
        if case let .reply(text, suggestions) = AIAssistantProtocol.parse("{\"reply\":\"Nested {braces} and \\\"quotes\\\"\",\"suggestions\":[1, \"two\", null]}") {
            check(text == "Nested {braces} and \"quotes\"" && suggestions == ["1", "two"], "strings with braces survive; suggestions tolerate junk: \(suggestions)")
        } else {
            fatalError("FAIL: braces inside strings")
        }
    }

    // MARK: - Scripted model and tools

    final class ScriptedCompletion: TextCompletionProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [String]
        private(set) var calls: [(system: String, user: String, json: Bool)] = []
        var delay: TimeInterval = 0

        init(_ responses: [String]) { self.responses = responses }

        private func record(_ call: (system: String, user: String, json: Bool)) -> String? {
            lock.lock()
            defer { lock.unlock() }
            calls.append(call)
            return responses.isEmpty ? nil : responses.removeFirst()
        }

        func complete(system: String, user: String, json: Bool) async throws -> String {
            let next = record((system, user, json))
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let next else {
                throw NSError(domain: "AIAssistantTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "no scripted response left"])
            }
            return next
        }
    }

    final class ToolLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        var runs: [String] { lock.lock(); defer { lock.unlock() }; return entries }
        func record(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
    }

    struct RecordingTool: AIAssistantTool {
        let name: String
        let summary: String
        let cost: AIToolCostEstimate?
        let log: ToolLog
        var parametersSchema: [String: Any] { ["type": "object", "properties": ["x": ["type": "integer"]]] }

        func costEstimate(arguments: [String: Any]) -> AIToolCostEstimate? { cost }

        func run(arguments: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
            progress("working on \(name)")
            log.record(name + ":" + ((arguments["x"] as? NSNumber)?.stringValue ?? "-"))
            let file = try context.newAssetURL(prefix: "fake", fileExtension: "txt")
            try "fixture".write(to: file, atomically: true, encoding: .utf8)
            return AIToolResult(text: "ok \(name)", attachments: [file])
        }
    }

    static func action(_ tool: String, _ arguments: String = "{}") -> String {
        "{\"thought\": \"call \(tool)\", \"action\": {\"tool\": \"\(tool)\", \"arguments\": \(arguments)}}"
    }

    static func reply(_ text: String, _ suggestions: [String] = []) -> String {
        let list = suggestions.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"thought\": \"answer\", \"reply\": \"\(text)\", \"suggestions\": [\(list)]}"
    }

    @MainActor
    static func scriptedAgentLoop(root: URL) async throws {
        let log = ToolLog()
        let free = RecordingTool(name: "fake_free", summary: "A free fixture tool.", cost: nil, log: log)
        let paid = RecordingTool(name: "fake_paid", summary: "A paid fixture tool.", cost: AIToolCostEstimate(yuan: 1.5, summary: "fixture · 5 s"), log: log)
        let box = ProjectBox(makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 12))
        let context = makeContext(root: root, box: box)

        // Tool call, then a reply with follow-ups.
        let provider = ScriptedCompletion([
            "```json\n" + action("fake_free", "{\"x\": 7}") + "\n```",
            reply("Listed.", ["Next A", "Next B"]),
        ])
        let session = AIAssistantSession(context: context, completion: provider, tools: [free, paid])
        check(session.hasModel, "a completion provider means a model is available")
        session.send("hello")
        check(session.isRunning, "send starts the turn")
        try await waitUntil("scripted turn to finish") { !session.isRunning }
        check(log.runs == ["fake_free:7"], "the tool ran once with its arguments: \(log.runs)")
        check(session.messages.map(\.role) == [.user, .tool, .assistant], "transcript order user → tool → assistant: \(session.messages.map(\.role))")
        check(session.messages[1].toolName == "fake_free" && session.messages[1].attachments.count == 1, "tool row carries its name and attachment")
        check(session.messages[2].text == "Listed." && session.suggestions == ["Next A", "Next B"], "reply text and suggestions surface")
        check(provider.calls.count == 2 && provider.calls.allSatisfy(\.json), "two model calls in JSON mode")
        check(provider.calls[0].system.contains("\"name\":\"fake_free\"") && provider.calls[0].system.contains("\"name\":\"fake_paid\""), "system prompt lists the tool catalog")
        check(provider.calls[0].system.contains("\"reply\": \"...\"") && provider.calls[0].system.contains("English"), "system prompt states the JSON protocol and language")
        check(provider.calls[0].user.contains("[Project]") && provider.calls[0].user.contains("Fixture recording") && provider.calls[0].user.contains("User: hello"), "user content carries project summary and transcript")
        check(provider.calls[1].user.contains("Tool fake_free result:\nok fake_free"), "tool results are fed back: \(provider.calls[1].user.suffix(200))")
        check(!session.messages.contains { $0.role == .status }, "status rows are removed when the turn ends")

        // Prose (invalid protocol) becomes a plain reply; unknown tools are reported back to the model.
        let provider2 = ScriptedCompletion([action("no_such_tool"), "Just prose, no JSON."])
        let session2 = AIAssistantSession(context: context, completion: provider2, tools: [free])
        session2.send("try something")
        try await waitUntil("prose turn to finish") { !session2.isRunning }
        check(session2.messages.map(\.role) == [.user, .error, .assistant], "unknown tool → error row → reply: \(session2.messages.map(\.role))")
        check(provider2.calls[1].user.contains("Tool no_such_tool failed"), "unknown tool errors are fed back")
        check(session2.messages.last?.text == "Just prose, no JSON.", "prose is shown as the reply")

        // The step budget ends runaway loops.
        let provider3 = ScriptedCompletion(Array(repeating: action("fake_free"), count: 12))
        let session3 = AIAssistantSession(context: context, completion: provider3, tools: [free])
        session3.send("loop")
        try await waitUntil("runaway turn to stop") { !session3.isRunning }
        check(provider3.calls.count == AIAssistantSession.maximumStepsPerTurn, "at most \(AIAssistantSession.maximumStepsPerTurn) model calls per turn: \(provider3.calls.count)")
        check(session3.messages.last?.role == .error, "the step limit is reported")

        // No model configured: no crash, one error row.
        let session4 = AIAssistantSession(context: context, completion: nil, tools: [free])
        session4.send("anything")
        check(!session4.hasModel && !session4.isRunning && session4.messages.last?.role == .error, "missing model is reported")

        // Transcript truncation keeps the newest messages.
        let session5 = AIAssistantSession(context: context, completion: ScriptedCompletion([]), tools: [free])
        for index in 0..<40 {
            session5.send("message \(index) " + String(repeating: "x", count: 500))
            try await waitUntil("filler turn") { !session5.isRunning }
        }
        let transcript = session5.transcript()
        check(transcript.count <= AIAssistantSession.transcriptCharacterBudget + 600 && transcript.contains("message 39") && !transcript.contains("message 0 ") && transcript.contains("(earlier messages omitted)"), "transcript keeps the newest ~12k characters: \(transcript.count)")
    }

    @MainActor
    static func confirmationFlow(root: URL) async throws {
        let log = ToolLog()
        let paid = RecordingTool(name: "fake_paid", summary: "A paid fixture tool.", cost: AIToolCostEstimate(yuan: 1.5, summary: "fixture · 5 s"), log: log)
        let box = ProjectBox(makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 12))
        let context = makeContext(root: root, box: box)

        // Decline: the tool never runs and the model hears about it.
        let provider = ScriptedCompletion([action("fake_paid", "{\"x\": 1}"), reply("Okay, tell me what to change.")])
        let session = AIAssistantSession(context: context, completion: provider, tools: [paid])
        session.send("make a clip")
        try await waitUntil("confirmation to appear") { session.pendingConfirmation != nil }
        check(session.isRunning, "the turn stays running while waiting for the user")
        check(session.pendingConfirmation?.toolName == "fake_paid" && session.pendingConfirmation?.estimate.yuan == 1.5, "pending call exposes tool and estimate")
        check(provider.calls.count == 1 && log.runs.isEmpty, "nothing runs before the user decides")
        session.cancelPending()
        try await waitUntil("declined turn to finish") { !session.isRunning }
        check(session.pendingConfirmation == nil && log.runs.isEmpty, "declined tool never ran")
        check(provider.calls.count == 2 && provider.calls[1].user.contains("declined"), "the decline is fed back to the model: \(provider.calls[1].user.suffix(160))")
        check(session.messages.map(\.role) == [.user, .tool, .assistant], "decline row then the model's reply: \(session.messages.map(\.role))")

        // Confirm: the tool runs after the user agrees.
        let provider2 = ScriptedCompletion([action("fake_paid", "{\"x\": 2}"), reply("Done.")])
        let session2 = AIAssistantSession(context: context, completion: provider2, tools: [paid])
        session2.send("make a clip")
        try await waitUntil("second confirmation") { session2.pendingConfirmation != nil }
        session2.confirmPending()
        try await waitUntil("confirmed turn to finish") { !session2.isRunning }
        check(log.runs == ["fake_paid:2"], "confirmed tool ran exactly once: \(log.runs)")
        check(session2.messages.map(\.role) == [.user, .tool, .assistant] && session2.messages[1].text == "ok fake_paid", "confirmed run produces a tool row")
        check(provider2.calls[1].user.contains("Tool fake_paid result:\nok fake_paid"), "the result reaches the model")

        // Stop while waiting for confirmation: nothing runs, the turn ends.
        let provider3 = ScriptedCompletion([action("fake_paid"), reply("unused")])
        let session3 = AIAssistantSession(context: context, completion: provider3, tools: [paid])
        session3.send("make a clip")
        try await waitUntil("third confirmation") { session3.pendingConfirmation != nil }
        session3.stop()
        try await waitUntil("stopped turn to finish") { !session3.isRunning }
        check(session3.pendingConfirmation == nil && log.runs == ["fake_paid:2"] && provider3.calls.count == 1, "stop cancels the pending call without running it")
        check(session3.messages.last?.role == .status, "stop leaves a status row")
    }

    @MainActor
    static func stopWhileThinking(root: URL) async throws {
        let box = ProjectBox(nil)
        let context = makeContext(root: root, box: box)
        let provider = ScriptedCompletion([reply("late")])
        provider.delay = 5
        let session = AIAssistantSession(context: context, completion: provider, tools: [])
        session.send("slow question")
        try await Task.sleep(nanoseconds: 50_000_000)
        check(session.messages.contains { $0.role == .status }, "a status row shows while the model thinks")
        session.stop()
        try await waitUntil(timeout: 3, "stop to cancel the model call") { !session.isRunning }
        check(session.messages.map(\.role) == [.user, .status] && session.messages.last?.role == .status, "stopping removes the live status and leaves a stopped row: \(session.messages.map(\.role))")
        check(provider.calls[0].user.contains("No recording is open."), "missing project is described to the model")
    }

    // MARK: - Tool validation

    @MainActor
    static func updateSettingsValidation(root: URL) async throws {
        let box = ProjectBox(makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 12))
        let context = makeContext(root: root, box: box)
        let tool = UpdateSettingsTool()
        let result = try await tool.run(
            arguments: ["backgroundPreset": "ocean", "padding": 10_000, "aspectRatio": "9:16", "zoomScale": "2.2", "screenAnimation": "Snappy", "captionPosition": "top", "showsChapterNumber": false],
            context: context, progress: { _ in }
        )
        let settings = box.project!.settings
        check(settings.backgroundStyle == .gradient && settings.backgroundColor == "#0866C6" && settings.secondaryBackgroundColor == "#21D4B4", "preset sets both colours and the gradient style")
        check(settings.padding == 160, "padding is clamped to the inspector range: \(settings.padding)")
        check(settings.aspectRatio == .vertical && settings.zoomScale == 2.2 && settings.screenAnimation == .snappy, "ratios, numeric strings and case-insensitive enums are accepted")
        check(settings.resolvedCaptionStyle.position == .top && settings.resolvedCaptionStyle.showsChapterNumber == false, "caption style keys apply")
        check(result.text.contains("padding") && result.text.contains("clamped"), "clamping is reported: \(result.text)")

        let before = box.project!.settings
        await expectThrows("unknown key") { _ = try await tool.run(arguments: ["bogus": 1], context: context, progress: { _ in }) }
        await expectThrows("bad colour") { _ = try await tool.run(arguments: ["backgroundColor": "blue"], context: context, progress: { _ in }) }
        await expectThrows("bad enum") { _ = try await tool.run(arguments: ["screenAnimation": "wobbly"], context: context, progress: { _ in }) }
        await expectThrows("non-numeric") { _ = try await tool.run(arguments: ["padding": "lots"], context: context, progress: { _ in }) }
        await expectThrows("empty") { _ = try await tool.run(arguments: [:], context: context, progress: { _ in }) }
        await expectThrows("image style without a path") { _ = try await tool.run(arguments: ["backgroundStyle": "image"], context: context, progress: { _ in }) }
        await expectThrows("missing image file") { _ = try await tool.run(arguments: ["backgroundImagePath": "/nonexistent/bg.png"], context: context, progress: { _ in }) }
        check(box.project!.settings == before, "failed calls change nothing")

        _ = try await tool.run(arguments: ["backgroundColor": "6d5dfb", "backgroundStyle": "solid", "productDescription": "  A budgeting app  "], context: context, progress: { _ in })
        check(box.project!.settings.backgroundColor == "#6D5DFB" && box.project!.settings.backgroundStyle == .solid && box.project!.settings.productDescription == "A budgeting app", "hex normalisation, solid style and trimmed description")

        // Export width and frame rate take exactly the editor's choices.
        let properties = tool.parametersSchema["properties"] as? [String: Any]
        check((properties?["exportWidth"] as? [String: Any])?["enum"] as? [Int] == [1_280, 1_920, 2_560, 3_840] && (properties?["frameRate"] as? [String: Any])?["enum"] as? [Int] == [24, 30, 60], "the schema lists the export choices")
        let exportResult = try await tool.run(arguments: ["exportWidth": 3_840, "frameRate": "60 fps"], context: context, progress: { _ in })
        check(box.project!.settings.exportWidth == 3_840 && box.project!.settings.frameRate == 60 && exportResult.text.contains("exportWidth = 3840") && exportResult.text.contains("frameRate = 60"), "export width and frame rate apply: \(exportResult.text)")
        _ = try await tool.run(arguments: ["exportWidth": "1920", "frameRate": 24], context: context, progress: { _ in })
        check(box.project!.settings.exportWidth == 1_920 && box.project!.settings.frameRate == 24, "numeric strings are accepted")
        let exportBefore = box.project!.settings
        for (name, arguments) in [
            ("width not offered", ["exportWidth": 1_080] as [String: Any]),
            ("fractional width", ["exportWidth": 1_920.5]),
            ("width word", ["exportWidth": "4k"]),
            ("frame rate not offered", ["frameRate": 25]),
            ("frame rate word", ["frameRate": "fast"]),
            ("valid key with a bad one", ["padding": 20, "frameRate": 120]),
            // Beyond Int's range: rejected, not a crash converting it.
            ("huge width", ["exportWidth": 1e19]),
            ("huge frame rate text", ["frameRate": "1e19"]),
            ("huge negative width", ["exportWidth": -1e300]),
        ] {
            await expectToolError(name, { _ = try await tool.run(arguments: arguments, context: context, progress: { _ in }) }) {
                if case let .invalidArgument(message) = $0 { return message.contains("must be one of") } else { return false }
            }
        }
        check(box.project!.settings == exportBefore, "rejected export values change nothing")

        // Every integer argument (frame_rate, zoom index, durations) goes through int(); huge values are unparsable, not a crash.
        check(AIToolArguments(["n": 1e19]).int("n") == nil && AIToolArguments(["n": "-1e300"]).int("n") == nil, "out-of-range integers are unparsable")
        check(AIToolArguments(["n": 41.6]).int("n") == 42 && AIToolArguments(["n": "30 fps"]).int("n") == 30, "in-range integers still round and parse text")
        check(UpdateSettingsTool.number(1e19) == "10000000000000000000.00" && UpdateSettingsTool.number(12) == "12", "change notes format huge whole numbers without trapping")

        box.project = nil
        await expectThrows("no project") { _ = try await tool.run(arguments: ["padding": 10], context: context, progress: { _ in }) }
    }

    @MainActor
    static func setChaptersSanitization(root: URL) async throws {
        let box = ProjectBox(makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 12))
        let context = makeContext(root: root, box: box)
        let tool = SetChaptersTool()
        let result = try await tool.run(arguments: ["chapters": [
            ["start": 5, "end": 9, "title": "Second"],
            ["start": 0, "end": "4.5", "title": "First", "caption": "  Cap  "],
            ["start": 3, "end": 3.1, "title": "Blink"],
            ["start": 20, "end": 30, "title": "Beyond"],
            ["start": 1, "end": 2],
            ["start": "x", "end": 2, "title": "NaN"],
        ]], context: context, progress: { _ in })
        let chapters = box.project!.chapters ?? []
        check(chapters.map(\.title) == ["First", "Second"], "invalid chapters are dropped and the rest sorted: \(chapters.map(\.title))")
        check(chapters[0].caption == "Cap" && chapters[0].end == 4.5, "captions are trimmed and numeric strings accepted")
        check(result.text.contains("2") && result.text.contains("First — Cap"), "result lists the chapters: \(result.text)")

        _ = try await tool.run(arguments: ["chapters": [["start": 9.5, "end": 12, "title": "Third"]], "append": true], context: context, progress: { _ in })
        check(box.project!.chapters?.map(\.title) == ["First", "Second", "Third"], "append keeps existing chapters")

        await expectThrows("nothing valid") { _ = try await tool.run(arguments: ["chapters": [["start": 3, "end": 3.1, "title": "Blink"]]], context: context, progress: { _ in }) }
        await expectThrows("missing array") { _ = try await tool.run(arguments: ["chapters": "nope"], context: context, progress: { _ in }) }
        check(box.project!.chapters?.count == 3, "failed calls change nothing")
    }

    // MARK: - Write safety

    /// Every editing tool, with arguments that succeed on `makeProject`.
    static func editingCalls(root: URL) throws -> [(name: String, tool: any AIAssistantTool, arguments: [String: Any])] {
        let image = root.appendingPathComponent("dropped-background.jpg")
        try Pixels.writeJPEG(width: 32, height: 18, color: (0.2, 0.6, 0.4), to: image)
        let music = root.appendingPathComponent("dropped-music.mp3")
        try Data([0]).write(to: music)
        return [
            ("add_zoom", AddZoomTool(), ["start": 1, "end": 2, "x": 0.5, "y": 0.5]),
            ("remove_zoom", RemoveZoomTool(), ["index": 1]),
            ("remove_zoom all", RemoveZoomTool(), ["index": "all"]),
            ("set_zoom_style", SetZoomStyleTool(), ["zoomHold": 1.5, "zoomScale": 2]),
            ("update_settings", UpdateSettingsTool(), ["padding": 10]),
            ("set_chapters", SetChaptersTool(), ["chapters": [["start": 0, "end": 2, "title": "Intro"]]]),
            ("set_background_image", SetBackgroundImageTool(), ["path": image.path]),
            ("set_background_music", SetBackgroundMusicTool(), ["track": music.path]),
            ("set_background_music none", SetBackgroundMusicTool(), ["track": "none"]),
            ("set_sound_effects", SetSoundEffectsTool(), ["click": true]),
        ]
    }

    /// An edit the app does not take must come back as an error, never as success.
    @MainActor
    static func droppedWrites(root: URL) async throws {
        let calls = try editingCalls(root: root)
        let box = ProjectBox(nil)
        let context = makeContext(root: root, box: box)
        for call in calls {
            // The editor closes between the tool's read and its write.
            box.project = makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 12)
            box.writeCount = 0
            box.afterNextRead = { box.project = nil }
            await expectToolError("\(call.name) after the editor closed", { _ = try await call.tool.run(arguments: call.arguments, context: context, progress: { _ in }) }) { $0 == .noProject }
            check(box.writeCount == 0, "\(call.name): nothing was written")

            // Another project was opened in between: the edit must not land in it.
            let original = makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 12)
            let other = makeProject(sourceVideoPath: "/other.mp4", duration: 12)
            box.project = original
            box.afterNextRead = { box.project = other }
            await expectToolError("\(call.name) after another project opened", { _ = try await call.tool.run(arguments: call.arguments, context: context, progress: { _ in }) }) {
                if case let .failed(message) = $0 { return message.contains("Another project was opened") } else { return false }
            }
            check(box.project == other && box.writeCount == 0, "\(call.name): the other project is untouched")
        }

        // An integrator that silently skips the write is caught as well.
        let project = makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 12)
        let skipping = AIAssistantContext(
            assetsDirectory: root.appendingPathComponent("assets", isDirectory: true),
            uiLanguage: "en",
            readProject: { project },
            updateProject: { _ in },
            arkAPIKey: { nil }
        )
        for call in calls {
            await expectToolError("\(call.name) with a skipped write", { _ = try await call.tool.run(arguments: call.arguments, context: skipping, progress: { _ in }) }) {
                if case let .failed(message) = $0 { return message.contains("did not apply") } else { return false }
            }
        }
    }

    /// Parallel calls and the user's own edits land between a tool's read and
    /// its write; each tool writes once and only the keys it was asked to change.
    @MainActor
    static func interleavedEdits(root: URL) async throws {
        let box = ProjectBox(makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 12))
        let context = makeContext(root: root, box: box)

        // update_settings(padding) while another edit sets zoomHold.
        box.writeCount = 0
        box.afterNextRead = { box.project!.settings.zoomHold = 1.7 }
        _ = try await UpdateSettingsTool().run(arguments: ["padding": 100, "captionPosition": "top"], context: context, progress: { _ in })
        check(box.project!.settings.padding == 100 && box.project!.settings.resolvedCaptionStyle.position == .top && box.project!.settings.zoomHold == 1.7, "both interleaved edits survive update_settings: \(box.project!.settings)")
        check(box.writeCount == 1, "update_settings writes once")

        // set_zoom_style(zoomScale + zoomHold) while another edit sets padding: one write, both survive.
        box.writeCount = 0
        box.afterNextRead = { box.project!.settings.padding = 40 }
        _ = try await SetZoomStyleTool().run(arguments: ["zoomScale": 2.4, "zoomHold": 1.2], context: context, progress: { _ in })
        check(box.project!.settings.zoomScale == 2.4 && box.project!.settings.zoomHold == 1.2 && box.project!.settings.padding == 40, "both interleaved edits survive set_zoom_style: \(box.project!.settings)")
        check(box.writeCount == 1, "set_zoom_style writes its keys in one step (was two)")

        // set_chapters(append) while another call appends a chapter.
        box.project!.chapters = [DemoChapter(start: 0, end: 3, title: "First")]
        box.afterNextRead = { box.project!.chapters!.append(DemoChapter(start: 4, end: 6, title: "Parallel")) }
        let appended = try await SetChaptersTool().run(arguments: ["chapters": [["start": 8, "end": 11, "title": "Mine"]], "append": true], context: context, progress: { _ in })
        check(box.project!.chapters?.map(\.title) == ["First", "Parallel", "Mine"] && !appended.text.contains("dropped"), "append merges with the chapters present at write time: \(box.project!.chapters?.map(\.title) ?? [])")

        // add_zoom while another zoom is added.
        let zoomsBefore = box.project!.zoomSegments.count
        box.afterNextRead = { box.project!.zoomSegments.append(ZoomSegment(start: 5, end: 6, targetX: 0.3, targetY: 0.3, scale: 1.5, kind: .manual)) }
        let added = try await AddZoomTool().run(arguments: ["start": 9, "end": 10, "x": 0.5, "y": 0.5], context: context, progress: { _ in })
        check(box.project!.zoomSegments.count == zoomsBefore + 2 && added.text.contains("now has \(zoomsBefore + 2) zooms"), "both zooms are kept: \(added.text)")

        // Two real tool calls at once, on different keys, many times over.
        for round in 0..<12 {
            async let padding = UpdateSettingsTool().run(arguments: ["padding": 20 + round], context: context, progress: { _ in })
            async let hold = SetZoomStyleTool().run(arguments: ["zoomHold": 0.5 + Double(round) * 0.1], context: context, progress: { _ in })
            async let music = SetSoundEffectsTool().run(arguments: ["click_volume": Double(round) / 20], context: context, progress: { _ in })
            _ = try await (padding, hold, music)
            let settings = box.project!.settings
            check(settings.padding == Double(20 + round) && abs(settings.zoomHold - (0.5 + Double(round) * 0.1)) < 0.000_1 && abs(settings.resolvedProductDemoAudio.clickSoundVolume - Double(round) / 20) < 0.000_1, "round \(round): concurrent edits to different keys all survive: \(settings)")
        }
    }

    // MARK: - Model resolver

    @MainActor
    final class ProviderBox {
        var provider: (any TextCompletionProviding)?
    }

    @MainActor
    static func modelResolver(root: URL) async throws {
        let box = ProjectBox(nil)
        let context = makeContext(root: root, box: box)
        let providers = ProviderBox()
        let session = AIAssistantSession(context: context, completionResolver: { providers.provider }, tools: [])
        check(!session.hasModel, "no provider → no model")
        session.send("hi")
        check(session.messages.last?.role == .error && !session.isRunning, "sending without a provider reports the setup problem")

        // The resolver is consulted on every send, so Settings changes apply without a new session.
        providers.provider = ScriptedCompletion([reply("now")])
        check(!session.hasModel, "hasModel is a published snapshot until refreshed")
        session.refreshModelAvailability()
        check(session.hasModel, "refresh picks up the new provider")
        session.send("hello")
        try await waitUntil("resolved turn") { !session.isRunning }
        check(session.messages.last?.text == "now", "the resolved provider answered: \(session.messages.map(\.text))")
        providers.provider = nil
        session.send("again")
        check(!session.hasModel && session.messages.last?.role == .error, "send refreshes availability before running")

        let names = AIAssistantToolCatalog.standard.map(\.name)
        for expected in ["list_recording_sources", "start_recording", "stop_recording", "list_projects", "open_project", "close_editor",
                         "add_zoom", "remove_zoom", "set_zoom_style", "set_background_music", "set_sound_effects", "export_project", "export_demo",
                         "generate_image", "generate_video", "capture_frame", "set_background_image", "update_settings", "set_chapters",
                         "list_assets", "assemble_video", "reveal_in_finder"] {
            check(names.contains(expected), "standard catalog lists \(expected): \(names)")
        }
        check(Set(names).count == names.count, "tool names are unique")

        // With an app the model sees the app state and the bundled music.
        var appContext = context
        let app = FakeApp(box: box)
        app.tracks = [AIMusicTrack(id: "calm-gradient", title: "Calm Gradient", path: "/bundle/calm.m4a")]
        appContext.app = app
        let appSession = AIAssistantSession(context: appContext, completion: nil, tools: [])
        let content = appSession.userContent()
        check(content.contains("[App]") && content.contains("Recording: idle") && content.contains("Bundled music: Calm Gradient (calm-gradient)") && content.contains("[Project]"), "app summary precedes the project: \(content.prefix(300))")
        check(!session.userContent().contains("[App]"), "no app → no app section")
        check(appSession.systemPrompt().contains("list_recording_sources → start_recording") && appSession.systemPrompt().contains("step by step"), "system prompt teaches the workflow")
    }

    // MARK: - App control (fake app)

    /// Stands in for StudioModel: a source list, a scripted countdown and stop,
    /// and a library whose open project is shared with the tool context.
    @MainActor
    final class FakeApp: AppControlling {
        enum StartBehaviour {
            case succeed(after: TimeInterval)
            case fail(String, after: TimeInterval)
            case cancel(after: TimeInterval)
            /// Like StudioModel when ScreenCaptureKit refuses: back on the recorder
            /// (`.idle`) with the permission notice as the reported error.
            case permissionDenied(String, after: TimeInterval)
            case hang
        }

        enum StopBehaviour {
            case succeed(after: TimeInterval)
            case fail(String, after: TimeInterval)
            case hang
        }

        let box: ProjectBox
        var sources: [AIRecordingSource] = []
        var refreshCount = 0
        var refreshError: Error?
        var recordingPhase: AIRecordingPhase = .idle
        var lastReportedError: String?
        var startedSourceIDs: [String] = []
        var startedOptions: [AIRecordingOptions] = []
        var startBehaviour: StartBehaviour = .succeed(after: 0.05)
        var stopBehaviour: StopBehaviour = .succeed(after: 0.05)
        /// Times the capture was actually finalized (joined stops do not count).
        var finalizeCount = 0
        /// Times anything asked the app to stop, joined or not.
        var stopRequests = 0
        private var stopInFlight: Task<Void, Never>?
        var projects: [RecordingProject] = []
        var openID: UUID?
        var closeCount = 0
        var tracks: [AIMusicTrack] = []

        init(box: ProjectBox) { self.box = box }

        var recordingSources: [AIRecordingSource] { sources }

        func refreshRecordingSources() async throws -> [AIRecordingSource] {
            refreshCount += 1
            if let refreshError { throw refreshError }
            return sources
        }

        func startRecording(sourceID: String, options: AIRecordingOptions) throws {
            guard recordingPhase == .idle else { throw AIToolError.failed("A recording is already in progress.") }
            guard sources.contains(where: { $0.id == sourceID }) else { throw AIToolError.invalidArgument("Unknown source \(sourceID).") }
            startedSourceIDs.append(sourceID)
            startedOptions.append(options)
            lastReportedError = nil
            recordingPhase = .countdown
            switch startBehaviour {
            case let .succeed(delay):
                Task { try? await Task.sleep(for: .seconds(delay)); self.recordingPhase = .recording }
            case let .fail(message, delay):
                Task { try? await Task.sleep(for: .seconds(delay)); self.recordingPhase = .failed(message) }
            case let .cancel(delay):
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    self.lastReportedError = "The selected screen or window is no longer available."
                    self.recordingPhase = .idle
                }
            case let .permissionDenied(message, delay):
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    self.lastReportedError = message
                    self.recordingPhase = .idle
                }
            case .hang:
                break
            }
        }

        var isFinishingRecording: Bool { stopInFlight != nil }

        /// Joins a stop in flight, and ignores one with nothing recording, like StudioModel does.
        func stopRecording() async {
            stopRequests += 1
            if let stopInFlight {
                await stopInFlight.value
                return
            }
            guard recordingPhase == .recording else { return }
            let task = Task {
                await self.finalize()
                self.stopInFlight = nil
            }
            stopInFlight = task
            await task.value
        }

        private func finalize() async {
            finalizeCount += 1
            recordingPhase = .stopping
            switch stopBehaviour {
            case let .succeed(delay):
                try? await Task.sleep(for: .seconds(delay))
                var project = makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 12)
                project.title = "Recording \(projects.count + 1)"
                projects.insert(project, at: 0)
                openID = project.id
                box.project = project
                recordingPhase = .idle
            case let .fail(message, delay):
                try? await Task.sleep(for: .seconds(delay))
                lastReportedError = message
                recordingPhase = .idle
            case .hang:
                // Until the test gives up on it and resets the phase.
                while recordingPhase == .stopping { try? await Task.sleep(for: .milliseconds(10)) }
            }
        }

        var projectSummaries: [AIProjectSummary] { projects.map(AIProjectSummary.init) }
        var openProjectID: UUID? { openID }

        func openProject(id: UUID) throws {
            guard let project = projects.first(where: { $0.id == id }) else { throw AIToolError.invalidArgument("No project \(id).") }
            openID = id
            box.project = project
        }

        func closeEditor() {
            closeCount += 1
            openID = nil
            box.project = nil
        }

        var bundledMusicTracks: [AIMusicTrack] { tracks }
    }

    @MainActor
    static func makeFakeApp(root: URL) -> (context: AIAssistantContext, app: FakeApp, box: ProjectBox) {
        let box = ProjectBox(nil)
        var context = makeContext(root: root, box: box)
        let app = FakeApp(box: box)
        app.sources = [
            AIRecordingSource(id: "display-1", kind: .display, title: "Built-in Display", width: 2_560, height: 1_440),
            AIRecordingSource(id: "display-2", kind: .display, title: "External", width: 1_920, height: 1_080),
            AIRecordingSource(id: "win-1", kind: .window, appName: "Safari", title: "Focus Studio — Docs", width: 1_440, height: 900),
            AIRecordingSource(id: "win-2", kind: .window, appName: "Safari", title: "Apple", width: 800, height: 600),
            AIRecordingSource(id: "win-3", kind: .window, appName: "Xcode", title: "FocusStudio.swift", width: 1_600, height: 1_000),
        ]
        context.app = app
        return (context, app, box)
    }

    static func expectToolError(_ message: String, _ body: () async throws -> Void, _ verify: (AIToolError) -> Bool) async {
        do {
            try await body()
            fatalError("FAIL: expected an error: \(message)")
        } catch let error as AIToolError {
            check(verify(error), "\(message): unexpected error \(error)")
        } catch {
            fatalError("FAIL: \(message): expected AIToolError, got \(error)")
        }
    }

    @MainActor
    static func recordingControl(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)

        // list_recording_sources refreshes and lists id, kind, app, title and size.
        let listed = try await ListRecordingSourcesTool().run(arguments: [:], context: context, progress: { _ in })
        check(app.refreshCount == 1 && listed.text.hasPrefix("2 displays, 3 windows"), "sources are refreshed and counted: \(listed.text)")
        check(listed.text.contains("- id display-1 · display · Built-in Display · 2560×1440") && listed.text.contains("- id win-1 · window · Safari — Focus Studio — Docs · 1440×900"), "source lines carry id, kind, app, title and size: \(listed.text)")
        check(listed.text.range(of: "win-3")!.lowerBound < listed.text.range(of: "win-2")!.lowerBound, "windows are listed largest first")

        // Source resolution: id, display words, app names, titles, tokens.
        func resolved(_ query: String) -> String {
            do { return try StartRecordingTool.resolveSource(query, in: app.sources).id } catch { return "error: \(error)" }
        }
        check(resolved("WIN-2") == "win-2", "exact id, case-insensitive")
        check(resolved("display") == "display-1", "\"display\" is the main display")
        check(resolved("屏幕") == "display-1", "Chinese display word")
        check(resolved("display 2") == "display-2", "numbered display")
        check(resolved("safari") == "win-1", "app name → its largest window")
        check(resolved("docs") == "win-1", "title substring")
        check(resolved("Xcode FocusStudio") == "win-3", "token match")
        check(resolved("external") == "display-2", "display title substring")
        await expectToolError("missing display number", { _ = try StartRecordingTool.resolveSource("display 3", in: app.sources) }) {
            if case let .invalidArgument(message) = $0 { return message.contains("2 displays") } else { return false }
        }
        await expectToolError("unknown source lists what exists", { _ = try StartRecordingTool.resolveSource("Figma", in: app.sources) }) {
            if case let .invalidArgument(message) = $0 { return message.contains("No source matches \"Figma\"") && message.contains("display-1") } else { return false }
        }

        // start_recording selects, applies options and waits for the recording state.
        let start = StartRecordingTool(startTimeout: 2)
        let started = try await start.run(arguments: ["source": "Safari", "system_audio": true, "frame_rate": 60, "automatic_zooms": "false"], context: context, progress: { _ in })
        check(app.startedSourceIDs == ["win-1"], "the resolved source was started: \(app.startedSourceIDs)")
        let options = app.startedOptions.last!
        check(options.systemAudio == true && options.frameRate == 60 && options.automaticZooms == false && options.microphone == nil && options.browserContentOnly == nil, "only the given options are set: \(options)")
        check(app.recordingPhase == .recording && started.text.contains("Recording started (3-second countdown elapsed)") && started.text.contains("win-1") && started.text.contains("60 fps"), "start reports after the countdown: \(started.text)")
        await expectToolError("second start while recording", { _ = try await start.run(arguments: ["source": "display"], context: context, progress: { _ in }) }) {
            if case let .failed(message) = $0 { return message.contains("already recording") } else { return false }
        }
        await expectThrows("bad frame rate") { _ = try await start.run(arguments: ["source": "display", "frame_rate": 45], context: context, progress: { _ in }) }
        await expectThrows("bad boolean") { _ = try await start.run(arguments: ["source": "display", "microphone": "maybe"], context: context, progress: { _ in }) }
        check(app.startedSourceIDs.count == 1, "rejected calls never reach the app")

        // stop_recording waits for the editor to show the new project.
        let stop = StopRecordingTool(stopTimeout: 2)
        let stopped = try await stop.run(arguments: [:], context: context, progress: { _ in })
        let recorded = app.projects[0]
        check(app.recordingPhase == .idle && app.projects.count == 1 && app.openID == recorded.id, "stop produced and opened a project")
        check(stopped.text.contains("Recording saved as project \"Recording 1\"") && stopped.text.contains(recorded.id.uuidString) && stopped.text.contains("12.0 s"), "stop returns id, title and duration: \(stopped.text)")
        await expectToolError("nothing to stop", { _ = try await stop.run(arguments: [:], context: context, progress: { _ in }) }) {
            if case let .failed(message) = $0 { return message.contains("No recording is in progress") } else { return false }
        }

        // A cancelled countdown, a failed capture and a hang are all reported.
        app.startBehaviour = .cancel(after: 0.05)
        await expectToolError("cancelled countdown", { _ = try await start.run(arguments: ["source": "display"], context: context, progress: { _ in }) }) {
            if case let .failed(message) = $0 { return message.contains("no longer available") } else { return false }
        }
        app.startBehaviour = .fail("The stream stopped", after: 0.05)
        await expectToolError("capture failure", { _ = try await start.run(arguments: ["source": "display"], context: context, progress: { _ in }) }) {
            if case let .failed(message) = $0 { return message.contains("The stream stopped") } else { return false }
        }
        app.recordingPhase = .idle
        app.startBehaviour = .hang
        await expectToolError("start timeout", { _ = try await StartRecordingTool(startTimeout: 0.3).run(arguments: ["source": "display"], context: context, progress: { _ in }) }) {
            if case .timedOut = $0 { return true } else { return false }
        }
        app.recordingPhase = .idle

        // stop failures: the app's error and a timeout.
        app.startBehaviour = .succeed(after: 0.02)
        _ = try await start.run(arguments: ["source": "display 2"], context: context, progress: { _ in })
        check(app.startedSourceIDs.last == "display-2", "numbered display started")
        app.stopBehaviour = .fail("Disk full", after: 0.05)
        await expectToolError("stop failure", { _ = try await stop.run(arguments: [:], context: context, progress: { _ in }) }) {
            if case let .failed(message) = $0 { return message.contains("Disk full") } else { return false }
        }
        check(app.projects.count == 1, "a failed stop adds no project")
        app.recordingPhase = .recording
        app.stopBehaviour = .hang
        await expectToolError("stop timeout", { _ = try await StopRecordingTool(stopTimeout: 0.3).run(arguments: [:], context: context, progress: { _ in }) }) {
            if case .timedOut = $0 { return true } else { return false }
        }
        app.recordingPhase = .idle

        // A countdown in progress is waited out by stop_recording.
        app.startBehaviour = .succeed(after: 0.15)
        app.stopBehaviour = .succeed(after: 0.02)
        try app.startRecording(sourceID: "win-3", options: AIRecordingOptions())
        check(app.recordingPhase == .countdown, "countdown started directly")
        let afterCountdown = try await stop.run(arguments: [:], context: context, progress: { _ in })
        check(app.projects.count == 2 && afterCountdown.text.contains("Recording 2"), "stop waited for the countdown, then saved: \(afterCountdown.text)")

        // Without an app the tools fail clearly instead of crashing.
        let bare = makeContext(root: root, box: ProjectBox(nil))
        await expectToolError("no app", { _ = try await ListRecordingSourcesTool().run(arguments: [:], context: bare, progress: { _ in }) }) { $0 == .appUnavailable }
        await expectToolError("no app for start", { _ = try await start.run(arguments: ["source": "display"], context: bare, progress: { _ in }) }) { $0 == .appUnavailable }
        app.refreshError = AIToolError.failed("Screen Recording permission is required.")
        await expectToolError("refresh failure surfaces", { _ = try await ListRecordingSourcesTool().run(arguments: [:], context: context, progress: { _ in }) }) {
            if case let .failed(message) = $0 { return message.contains("Screen Recording") } else { return false }
        }
    }

    @MainActor
    static func recordingEdgeCases(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)
        let start = StartRecordingTool(startTimeout: 2)
        let stop = StopRecordingTool(stopTimeout: 3)

        // A refused Screen Recording permission is reported as such, not as a cancelled countdown.
        let permission = "Screen Recording access is not active for this copy of Focus Studio. Enable it in System Settings › Privacy & Security › Screen Recording."
        app.startBehaviour = .permissionDenied(permission, after: 0.05)
        await expectToolError("permission refused", { _ = try await start.run(arguments: ["source": "display"], context: context, progress: { _ in }) }) {
            if case let .failed(message) = $0 { return message.contains("could not start") && message.contains("Screen Recording access is not active") && !message.contains("cancelled") } else { return false }
        }
        app.startBehaviour = .succeed(after: 0.02)

        // "display" is the main display wherever the system lists it; numbers count from it.
        let displays = [
            AIRecordingSource(id: "display-5", kind: .display, title: "Studio Display", width: 5_120, height: 2_880),
            AIRecordingSource(id: "display-1", kind: .display, title: "Built-in Retina Display", width: 1_512, height: 982, isMainDisplay: true),
            AIRecordingSource(id: "display-9", kind: .display, title: "Sidecar", width: 1_366, height: 1_024),
            AIRecordingSource(id: "win-1", kind: .window, appName: "Safari", title: "Docs", width: 1_440, height: 900),
        ]
        func resolved(_ query: String) -> String {
            do { return try StartRecordingTool.resolveSource(query, in: displays).id } catch { return "error: \(error)" }
        }
        for query in ["display", "main display", "screen", "屏幕", "display 1"] {
            check(resolved(query) == "display-1", "\"\(query)\" is the main display: \(resolved(query))")
        }
        check(resolved("display 2") == "display-5" && resolved("screen 3") == "display-9", "other displays keep the system order after the main one")
        check(resolved("display 4").contains("3 displays"), "a missing number names the count: \(resolved("display 4"))")
        app.sources = displays
        let listed = try await ListRecordingSourcesTool().run(arguments: [:], context: context, progress: { _ in })
        let lines = listed.text.split(separator: "\n").map(String.init)
        check(lines.count > 1 && lines[1] == "- id display-1 · display · Built-in Retina Display · 1512×982 · main" && lines[2].contains("display-5"), "the main display is listed first and marked: \(listed.text)")
        _ = try await start.run(arguments: ["source": "display"], context: context, progress: { _ in })
        check(app.startedSourceIDs.last == "display-1", "start_recording records the main display: \(app.startedSourceIDs)")

        // Only a display with the main display's id is the main one; a window number can collide.
        let frame = CaptureRect(x: 0, y: 0, width: 1_440, height: 900)
        check(AIRecordingSource(target: CaptureTargetInfo(id: "display-7", kind: .display, nativeID: 7, title: "Main", frame: frame), mainDisplayID: 7).isMainDisplay, "the main display is flagged")
        check(!AIRecordingSource(target: CaptureTargetInfo(id: "display-8", kind: .display, nativeID: 8, title: "Other", frame: frame), mainDisplayID: 7).isMainDisplay, "another display is not")
        check(!AIRecordingSource(target: CaptureTargetInfo(id: "window-7", kind: .window, nativeID: 7, title: "Window", frame: frame), mainDisplayID: 7).isMainDisplay, "a window with the same number is not")

        // The Finish button and two stop_recording calls at once: one finalization, one project, the same answer.
        app.stopBehaviour = .succeed(after: 0.3)
        let finalized = app.finalizeCount
        let projectCount = app.projects.count
        let requests = app.stopRequests
        let finishButton = Task { await app.stopRecording() }
        try await waitUntil("the button's stop to begin") { app.recordingPhase == .stopping }
        async let first = stop.run(arguments: [:], context: context, progress: { _ in })
        async let second = stop.run(arguments: [:], context: context, progress: { _ in })
        let (a, b) = try await (first, second)
        await finishButton.value
        check(app.finalizeCount == finalized + 1 && app.projects.count == projectCount + 1, "the capture was finalized once: \(app.finalizeCount - finalized) finalizations, \(app.projects.count - projectCount) projects")
        check(a.text == b.text && a.text.contains(app.projects[0].id.uuidString), "both calls report the one new project: \(a.text) / \(b.text)")
        // Joined calls only wait: a request landing after the stop finished
        // would otherwise finalize a capture that no longer exists.
        check(app.stopRequests == requests + 1, "joined calls never ask the app to stop again: \(app.stopRequests - requests) requests")
        await expectToolError("nothing left to stop", { _ = try await stop.run(arguments: [:], context: context, progress: { _ in }) }) {
            if case let .failed(message) = $0 { return message.contains("No recording is in progress") } else { return false }
        }

        // `.stopping` without a stop of the app's own is a cancel winding down: refused, nothing finalized.
        app.recordingPhase = .stopping
        let beforeCancel = (app.finalizeCount, app.stopRequests, app.projects.count)
        await expectToolError("stop during a cancel", { _ = try await stop.run(arguments: [:], context: context, progress: { _ in }) }) {
            if case let .failed(message) = $0 { return message.contains("No recording is in progress (state: stopping)") } else { return false }
        }
        check((app.finalizeCount, app.stopRequests, app.projects.count) == beforeCancel, "a cancel in progress is never finalized as a recording")
        app.recordingPhase = .idle
    }

    @MainActor
    static func libraryControl(root: URL) async throws {
        let (context, app, box) = makeFakeApp(root: root)
        let empty = try await ListProjectsTool().run(arguments: [:], context: context, progress: { _ in })
        check(empty.text.contains("The library is empty"), "empty library: \(empty.text)")

        var first = makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 12)
        first.title = "Onboarding walkthrough"
        var second = makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 8)
        second.title = "Second take"
        app.projects = [second, first]
        try app.openProject(id: first.id)

        let listed = try await ListProjectsTool().run(arguments: [:], context: context, progress: { _ in })
        check(listed.text.hasPrefix("2 projects (newest first)") && listed.text.contains("1. Second take · 8.0 s") && listed.text.contains("2. Onboarding walkthrough · 12.0 s") && listed.text.contains(first.id.uuidString), "projects are numbered newest first with ids: \(listed.text)")
        check(listed.text.contains("Onboarding walkthrough · 12.0 s · 640×360") && listed.text.contains("open in the editor"), "the open project is marked: \(listed.text)")

        let opened = try await OpenProjectTool().run(arguments: ["project": "second"], context: context, progress: { _ in })
        check(app.openID == second.id && box.project?.id == second.id && opened.text.contains("Opened \"Second take\" in the editor (8.0 s"), "open by title substring: \(opened.text)")
        _ = try await OpenProjectTool().run(arguments: ["project": first.id.uuidString], context: context, progress: { _ in })
        check(app.openID == first.id, "open by id")
        await expectToolError("unknown project", { _ = try await OpenProjectTool().run(arguments: ["project": "nope"], context: context, progress: { _ in }) }) {
            if case let .invalidArgument(message) = $0 { return message.contains("No project matches \"nope\"") && message.contains("Second take") } else { return false }
        }
        await expectToolError("unknown id", { _ = try await OpenProjectTool().run(arguments: ["project": UUID().uuidString], context: context, progress: { _ in }) }) {
            if case .invalidArgument = $0 { return true } else { return false }
        }
        await expectThrows("missing argument") { _ = try await OpenProjectTool().run(arguments: [:], context: context, progress: { _ in }) }

        let closed = try await CloseEditorTool().run(arguments: [:], context: context, progress: { _ in })
        check(app.openID == nil && app.closeCount == 1 && box.project == nil && closed.text.contains("Saved and closed \"Onboarding walkthrough\""), "close saves and names the project: \(closed.text)")
        let closedAgain = try await CloseEditorTool().run(arguments: [:], context: context, progress: { _ in })
        check(app.closeCount == 1 && closedAgain.text.contains("not open"), "closing twice is a no-op: \(closedAgain.text)")
        await expectToolError("editing needs an open project", { _ = try await AddZoomTool().run(arguments: ["start": 1, "end": 2, "x": 0.5, "y": 0.5], context: context, progress: { _ in }) }) { $0 == .noProject }
    }

    @MainActor
    static func zoomTools(root: URL) async throws {
        let (context, app, box) = makeFakeApp(root: root)
        var project = makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 8)
        project.title = "Zoom fixture"
        app.projects = [project]
        try app.openProject(id: project.id)

        let added = try await AddZoomTool().run(arguments: ["start": 3, "end": "5.5", "x": 0.25, "y": 0.75, "scale": 9], context: context, progress: { _ in })
        var zooms = box.project!.zoomSegments
        check(zooms.count == 2 && zooms[1].kind == .manual && zooms[1].start == 3 && zooms[1].end == 5.5 && zooms[1].targetX == 0.25 && zooms[1].targetY == 0.75, "a manual zoom is appended: \(zooms)")
        check(zooms[1].scale == 3 && added.text.contains("Added zoom #2") && added.text.contains("clamped") && added.text.contains("2 zooms"), "scale is clamped and the time-ordered number reported: \(added.text)")
        let defaultScale = try await AddZoomTool().run(arguments: ["start": 6, "end": 7, "x": 0.5, "y": 0.5], context: context, progress: { _ in })
        check(box.project!.zoomSegments.last?.scale == project.settings.zoomScale && defaultScale.text.contains("#3"), "scale defaults to the project's zoom scale: \(defaultScale.text)")
        for (name, arguments) in [
            ("too short", ["start": 5, "end": 5.1, "x": 0.5, "y": 0.5] as [String: Any]),
            ("beyond duration", ["start": 7, "end": 9, "x": 0.5, "y": 0.5]),
            ("negative start", ["start": -1, "end": 2, "x": 0.5, "y": 0.5]),
            ("x out of range", ["start": 1, "end": 2, "x": 1.5, "y": 0.5]),
            ("missing y", ["start": 1, "end": 2, "x": 0.5]),
            ("non-numeric", ["start": "one", "end": 2, "x": 0.5, "y": 0.5]),
        ] {
            await expectToolError(name, { _ = try await AddZoomTool().run(arguments: arguments, context: context, progress: { _ in }) }) {
                if case .invalidArgument = $0 { return true } else { return false }
            }
        }
        check(box.project!.zoomSegments.count == 3, "rejected zooms change nothing")

        let removed = try await RemoveZoomTool().run(arguments: ["index": 1], context: context, progress: { _ in })
        zooms = box.project!.zoomSegments
        check(zooms.count == 2 && zooms.allSatisfy { $0.kind == .manual } && removed.text.contains("Removed zoom #1 (0.2–1.2 s") && removed.text.contains("2 zooms remain"), "remove by time-ordered number: \(removed.text)")
        await expectToolError("index past the end", { _ = try await RemoveZoomTool().run(arguments: ["index": 5], context: context, progress: { _ in }) }) {
            if case let .invalidArgument(message) = $0 { return message.contains("1–2") } else { return false }
        }
        await expectThrows("non-numeric index") { _ = try await RemoveZoomTool().run(arguments: ["index": "second"], context: context, progress: { _ in }) }
        await expectThrows("missing index") { _ = try await RemoveZoomTool().run(arguments: [:], context: context, progress: { _ in }) }
        let removedAll = try await RemoveZoomTool().run(arguments: ["index": "all"], context: context, progress: { _ in })
        check(box.project!.zoomSegments.isEmpty && removedAll.text.contains("Removed all 2 zooms"), "remove all: \(removedAll.text)")
        let nothing = try await RemoveZoomTool().run(arguments: ["index": "all"], context: context, progress: { _ in })
        check(nothing.text.contains("no zooms"), "removing from an empty project is reported, not an error: \(nothing.text)")

        // set_zoom_style clamps, reuses update_settings for shared keys and regenerates automatic zooms.
        let styled = try await SetZoomStyleTool().run(arguments: ["zoomHold": 10, "zoomEaseIn": 0.3, "zoomEaseOut": "0.6s", "zoomChainGap": 1.5, "zoomScale": 2.5, "screenAnimation": "Smooth", "autoZoomEnabled": true], context: context, progress: { _ in })
        let settings = box.project!.settings
        check(settings.zoomHold == 3 && settings.zoomEaseIn == 0.3 && settings.zoomEaseOut == 0.6 && settings.zoomChainGap == 1.5 && settings.zoomScale == 2.5 && settings.screenAnimation == .smooth && settings.autoZoomEnabled, "zoom style keys apply with clamping: \(settings)")
        check(styled.text.contains("zoomHold = 3 (clamped)") && styled.text.contains("zoomScale = 2.5") && styled.text.contains("screenAnimation = smooth"), "changes are reported: \(styled.text)")
        check(box.project!.zoomSegments.contains { $0.kind == .automatic }, "enabling automatic zooms regenerates them from the recorded click")
        await expectToolError("unknown key", { _ = try await SetZoomStyleTool().run(arguments: ["zoomLeadIn": 1], context: context, progress: { _ in }) }) {
            if case let .invalidArgument(message) = $0 { return message.contains("zoomLeadIn") } else { return false }
        }
        await expectThrows("non-numeric hold") { _ = try await SetZoomStyleTool().run(arguments: ["zoomHold": "long"], context: context, progress: { _ in }) }
        await expectThrows("bad animation") { _ = try await SetZoomStyleTool().run(arguments: ["screenAnimation": "wobbly"], context: context, progress: { _ in }) }
        await expectThrows("empty") { _ = try await SetZoomStyleTool().run(arguments: [:], context: context, progress: { _ in }) }
        check(box.project!.settings == settings, "failed calls change nothing")
        _ = try await SetZoomStyleTool().run(arguments: ["autoZoomEnabled": "no"], context: context, progress: { _ in })
        check(!box.project!.settings.autoZoomEnabled, "automatic zooms can be turned off")
    }

    @MainActor
    static func audioTools(root: URL) async throws {
        let (context, app, box) = makeFakeApp(root: root)
        let project = makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 8)
        app.projects = [project]
        try app.openProject(id: project.id)
        app.tracks = [
            AIMusicTrack(id: "calm-gradient", title: "Calm Gradient", mood: "Soft, airy pads", durationSeconds: 60, suggestedVolume: 0.17, path: "/bundle/calm.m4a"),
            AIMusicTrack(id: "bright-launch", title: "Bright Launch", mood: "Upbeat keys", durationSeconds: 45, suggestedVolume: 0.14, path: "/bundle/bright.m4a"),
        ]

        let byTitle = try await SetBackgroundMusicTool().run(arguments: ["track": "calm gradient"], context: context, progress: { _ in })
        var audio = box.project!.settings.resolvedProductDemoAudio
        check(audio.backgroundMusicPath == "/bundle/calm.m4a" && audio.backgroundMusicVolume == 0.17 && byTitle.text.contains("Calm Gradient") && byTitle.text.contains("0.17"), "bundled track by title with its suggested volume: \(byTitle.text)")
        _ = try await SetBackgroundMusicTool().run(arguments: ["track": "bright-launch", "volume": 1.4], context: context, progress: { _ in })
        audio = box.project!.settings.resolvedProductDemoAudio
        check(audio.backgroundMusicPath == "/bundle/bright.m4a" && audio.backgroundMusicVolume == 1, "track by id; volume clamped to 1")
        _ = try await SetBackgroundMusicTool().run(arguments: ["track": "upbeat"], context: context, progress: { _ in })
        check(box.project!.settings.resolvedProductDemoAudio.backgroundMusicPath == "/bundle/bright.m4a", "mood words match too")
        let custom = root.appendingPathComponent("custom.mp3")
        try Data([0]).write(to: custom)
        let local = try await SetBackgroundMusicTool().run(arguments: ["track": custom.path, "volume": 0.3], context: context, progress: { _ in })
        audio = box.project!.settings.resolvedProductDemoAudio
        check(audio.backgroundMusicPath == custom.path && audio.backgroundMusicVolume == 0.3 && local.text.contains("custom"), "a local audio file is accepted: \(local.text)")
        await expectToolError("unknown track lists the bundled ones", { _ = try await SetBackgroundMusicTool().run(arguments: ["track": "Jazz Nights"], context: context, progress: { _ in }) }) {
            if case let .invalidArgument(message) = $0 { return message.contains("Calm Gradient (calm-gradient)") } else { return false }
        }
        let notAudio = root.appendingPathComponent("notes.txt")
        try "x".write(to: notAudio, atomically: true, encoding: .utf8)
        await expectThrows("not an audio file") { _ = try await SetBackgroundMusicTool().run(arguments: ["track": notAudio.path], context: context, progress: { _ in }) }
        let removed = try await SetBackgroundMusicTool().run(arguments: ["track": "none"], context: context, progress: { _ in })
        check(box.project!.settings.resolvedProductDemoAudio.backgroundMusicPath == nil && removed.text.contains("removed"), "\"none\" clears the music: \(removed.text)")
        check(SetBackgroundMusicTool.resolveTrack("Bright Launch", in: app.tracks)?.id == "bright-launch" && SetBackgroundMusicTool.resolveTrack("", in: app.tracks) == nil, "title lookup helper")

        let effects = try await SetSoundEffectsTool().run(arguments: ["click": true, "zoom_volume": 0.5], context: context, progress: { _ in })
        audio = box.project!.settings.resolvedProductDemoAudio
        check(audio.clickSoundEnabled && !audio.zoomTransitionSoundEnabled && audio.zoomTransitionSoundVolume == 0.5 && effects.text.contains("click on") && effects.text.contains("zoom whoosh off"), "sound effect toggles and volumes: \(effects.text)")
        _ = try await SetSoundEffectsTool().run(arguments: ["zoom": "yes", "click": false], context: context, progress: { _ in })
        audio = box.project!.settings.resolvedProductDemoAudio
        check(!audio.clickSoundEnabled && audio.zoomTransitionSoundEnabled, "string booleans are accepted")
        await expectThrows("no keys") { _ = try await SetSoundEffectsTool().run(arguments: [:], context: context, progress: { _ in }) }
        await expectThrows("bad boolean") { _ = try await SetSoundEffectsTool().run(arguments: ["click": "maybe"], context: context, progress: { _ in }) }
        app.closeEditor()
        await expectToolError("music needs a project", { _ = try await SetBackgroundMusicTool().run(arguments: ["track": "none"], context: context, progress: { _ in }) }) { $0 == .noProject }
    }

    @MainActor
    static func exportPaths(root: URL) throws {
        let box = ProjectBox(nil)
        var context = makeContext(root: root, box: box)
        let assets = root.appendingPathComponent("export-assets", isDirectory: true)
        context.assetsDirectory = assets
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        func resolve(_ path: String?) throws -> URL {
            try ExportProjectTool.resolveOutputURL(path: path, context: context, date: stamp)
        }
        func resolvedPath(_ path: String?) -> String {
            do { return try resolve(path).path } catch { return "error: \(error)" }
        }
        let byDefault = try resolve(nil)
        check(byDefault.deletingLastPathComponent().path == assets.path && byDefault.lastPathComponent.hasPrefix("export-") && byDefault.pathExtension == "mp4", "default export lands in the assets folder: \(byDefault.path)")
        check(FileManager.default.fileExists(atPath: assets.path), "the assets folder is created for the default name")
        check(resolvedPath("final") == assets.appendingPathComponent("final.mp4").path, "a bare name gets .mp4 inside the assets folder")
        check(resolvedPath("final.mov") == assets.appendingPathComponent("final.mp4").path, "another video extension becomes .mp4")
        check(resolvedPath("clips/final.mp4") == assets.appendingPathComponent("clips/final.mp4").path, "relative folders stay under the assets folder")
        let absolute = root.appendingPathComponent("out/demo.mp4")
        check(resolvedPath(absolute.path) == absolute.path, "absolute paths are used as given")
        check(resolvedPath("file://" + absolute.path) == absolute.path, "file URLs are accepted")
        let folder = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inFolder = try resolve(folder.path)
        check(inFolder.deletingLastPathComponent().path == folder.path && inFolder.lastPathComponent.hasPrefix("export-") && inFolder.pathExtension == "mp4", "an existing folder gets the default file name: \(inFolder.path)")
        let trailing = try resolve(root.appendingPathComponent("new-folder").path + "/")
        check(trailing.deletingLastPathComponent().lastPathComponent == "new-folder" && trailing.lastPathComponent.hasPrefix("export-"), "a trailing slash means a folder: \(trailing.path)")
        let home = FileManager.default.homeDirectoryForCurrentUser
        check(resolvedPath("~/Movies/demo.mp4") == home.appendingPathComponent("Movies/demo.mp4").path, "~ is expanded")
        check((try? resolve("https://example.com/demo.mp4")) == nil, "remote URLs are rejected")
        try "taken".write(to: assets.appendingPathComponent("export-" + Self.stampString(stamp) + ".mp4"), atomically: true, encoding: .utf8)
        check(resolvedPath(nil).hasSuffix("-2.mp4"), "an existing file is never clobbered")
        check(ExportDemoTool().name == "export_demo" && ExportProjectTool().name == "export_project" && ExportDemoTool().parametersSchema.keys == ExportProjectTool().parametersSchema.keys, "export_demo stays as an alias")
    }

    /// export_project never writes over the project's own files or into the
    /// library, and replaces an existing file only when asked to.
    @MainActor
    static func exportGuard(root: URL) async throws {
        let fileManager = FileManager.default
        let library = root.appendingPathComponent("guard-library", isDirectory: true)
        var project = makeProject(sourceVideoPath: "", duration: 5)
        let folder = library.appendingPathComponent(project.id.uuidString, isDirectory: true)
        let otherFolder = library.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = root.appendingPathComponent("guard-outside", isDirectory: true)
        for directory in [folder, otherFolder.appendingPathComponent("ai", isDirectory: true), outside] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let source = folder.appendingPathComponent("raw.mp4")
        let theme = outside.appendingPathComponent("theme.mp4")
        for file in [source, theme, folder.appendingPathComponent("project.json")] {
            try Data("keep \(file.lastPathComponent)".utf8).write(to: file)
        }
        project.sourceVideoPath = source.path
        project.settings.productDemoAudio = ProductDemoAudioSettings(backgroundMusicPath: theme.path)
        var context = makeContext(root: root, box: ProjectBox(project))
        context.projectsDirectory = library
        context.assetsDirectory = folder.appendingPathComponent("ai", isDirectory: true)
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        func resolve(_ path: String?, overwrite: Bool = false) throws -> URL {
            try ExportProjectTool.resolveOutputURL(path: path, context: context, date: stamp, project: project, overwrite: overwrite)
        }
        func refusal(_ path: String?, overwrite: Bool = false) -> String {
            do { return "accepted \(try resolve(path, overwrite: overwrite).path)" } catch let error as AIToolError {
                if case let .invalidArgument(message) = error { return message }
                return "\(error)"
            } catch { return "\(error)" }
        }

        // The recording and the media it uses, under any spelling, even with overwrite.
        let link = root.appendingPathComponent("guard-link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: folder)
        var sourceSpellings = [source.path, link.appendingPathComponent("raw.mp4").path, folder.path + "/./ai/../raw.mp4", folder.appendingPathComponent("raw").path]
        if source.path.hasPrefix("/var/") { sourceSpellings.append("/private" + source.path) }
        // The same file through the Data volume's firmlink, which realpath leaves as it is.
        func onDataVolume(_ url: URL) -> String {
            "/System/Volumes/Data" + (url.path.hasPrefix("/var/") ? "/private" + url.path : url.path)
        }
        let dataVolume = fileManager.fileExists(atPath: onDataVolume(source))
        if dataVolume { sourceSpellings.append(onDataVolume(source)) }
        // On a case-insensitive volume (the APFS default) RAW.MP4 is the same file.
        let shouted = folder.appendingPathComponent("RAW.MP4").path
        if fileManager.fileExists(atPath: shouted) { sourceSpellings.append(shouted) }
        for path in sourceSpellings {
            let message = refusal(path, overwrite: true)
            check(message.lowercased().contains("raw.mp4") && message.contains("this project uses"), "the source recording is refused as \(path): \(message)")
        }
        for path in [theme.path] + (dataVolume ? [onDataVolume(theme)] : []) {
            check(refusal(path, overwrite: true).contains("this project uses"), "a referenced media file outside the library is refused as \(path): \(refusal(path, overwrite: true))")
        }
        let sourceBytes = try Data(contentsOf: source)
        check(sourceBytes == Data("keep raw.mp4".utf8), "the source is untouched")

        // Nothing else inside the library, except this project's ai folder.
        var libraryPaths = [folder.appendingPathComponent("demo.mp4").path, folder.appendingPathComponent("project").path,
                            otherFolder.appendingPathComponent("ai/demo.mp4").path, library.appendingPathComponent("Incoming/demo.mp4").path,
                            library.appendingPathComponent("demo.mp4").path, link.appendingPathComponent("demo.mp4").path]
        if dataVolume {
            libraryPaths += [onDataVolume(folder.appendingPathComponent("demo.mp4")), onDataVolume(otherFolder.appendingPathComponent("ai/demo.mp4"))]
        }
        for path in libraryPaths {
            let message = refusal(path)
            check(message.contains("inside the Focus Studio library") && message.contains(context.assetsDirectory.path), "\(path) is refused with a way out: \(message)")
        }
        // Another project's recording is library content too, even with overwrite.
        let otherSource = otherFolder.appendingPathComponent("raw.mp4")
        try Data("keep other raw.mp4".utf8).write(to: otherSource)
        for path in [otherSource.path] + (dataVolume ? [onDataVolume(otherSource)] : []) {
            check(refusal(path, overwrite: true).contains("inside the Focus Studio library"), "another project's recording is refused as \(path): \(refusal(path, overwrite: true))")
        }
        let otherBytes = try Data(contentsOf: otherSource)
        check(otherBytes == Data("keep other raw.mp4".utf8), "the other recording is untouched")
        for folderPath in [folder.path, library.appendingPathComponent("new-folder").path + "/"] {
            check(refusal(folderPath).contains("inside the Focus Studio library"), "folder \(folderPath) is refused")
        }
        check(!fileManager.fileExists(atPath: library.appendingPathComponent("new-folder").path), "a refused folder is not created")
        let inAIFolder = try resolve(folder.appendingPathComponent("ai/final.mp4").path)
        check(inAIFolder.path == folder.appendingPathComponent("ai/final.mp4").path, "the project's ai folder is allowed")
        let bareName = try resolve("final")
        check(bareName.path == folder.appendingPathComponent("ai/final.mp4").path, "a bare name lands in the ai folder")
        let fresh = try resolve(nil)
        check(fresh.deletingLastPathComponent().path == context.assetsDirectory.path && fresh.lastPathComponent.hasPrefix("export-"), "the default path still works: \(fresh.path)")

        // An existing file is replaced only with overwrite: true.
        let existing = outside.appendingPathComponent("existing.mp4")
        try Data("old export".utf8).write(to: existing)
        let message = refusal(existing.path)
        check(message.contains("already exists") && message.contains("overwrite: true"), "an existing file needs overwrite: \(message)")
        let overwritten = try resolve(existing.path, overwrite: true)
        check(overwritten.path == existing.path, "overwrite: true allows it")
        let newOutside = try resolve(outside.appendingPathComponent("new.mp4").path)
        check(newOutside.path == outside.appendingPathComponent("new.mp4").path, "a new file outside the library is fine")
        await expectToolError("bad overwrite", { _ = try await ExportProjectTool().run(arguments: ["overwrite": "maybe"], context: context, progress: { _ in }) }) {
            if case let .invalidArgument(message) = $0 { return message.contains("overwrite") } else { return false }
        }
        check(ExportProjectTool().parametersSchema.description.contains("overwrite") && ExportDemoTool().parametersSchema.keys == ExportProjectTool().parametersSchema.keys, "the schema offers overwrite on both names")

        // Without a known library root the project's own files are still protected.
        context.projectsDirectory = nil
        check(refusal(source.path, overwrite: true).contains("this project uses"), "the source is refused without a library root")
        let unguarded = try resolve(folder.appendingPathComponent("demo.mp4").path)
        check(unguarded.lastPathComponent == "demo.mp4", "without a library root other paths are allowed")
    }

    static func stampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    // MARK: - Clip assembly

    @MainActor
    static func assembleVideo(root: URL) async throws {
        let clips = root.appendingPathComponent("clips", isDirectory: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let red = clips.appendingPathComponent("red.mp4")
        let blue = clips.appendingPathComponent("blue.mp4")
        try await SolidClipWriter.write(to: red, width: 640, height: 360, duration: 1.5, color: (0.9, 0.1, 0.1), audio: true)
        try await SolidClipWriter.write(to: blue, width: 720, height: 1_280, duration: 2.0, color: (0.1, 0.2, 0.9), audio: true)

        let crossfaded = clips.appendingPathComponent("crossfade.mp4")
        let result = try await VideoAssembler.assemble(clips: [red, blue], transition: .crossfade, renderSize: CGSize(width: 1_920, height: 1_080), to: crossfaded)
        check(abs(result.duration - 3.0) < 0.02, "crossfade duration is the sum minus one overlap: \(result.duration)")
        let asset = AVURLAsset(url: crossfaded)
        let duration = try await asset.load(.duration).seconds
        check(abs(duration - 3.0) < 0.1, "exported crossfade lasts ≈ 3.0 s: \(duration)")
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        check(size == CGSize(width: 1_920, height: 1_080), "output is 1920×1080: \(size)")
        let audioTrackCount = try await asset.loadTracks(withMediaType: .audio).count
        check(audioTrackCount == 1, "audio is carried over")

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let early = try await Pixels.sample(generator, seconds: 0.4, x: 960, y: 540)
        check(early.red > 150 && early.blue < 80, "first clip fills the centre early on: \(early)")
        let middle = try await Pixels.sample(generator, seconds: 1.25, x: 960, y: 540)
        check(middle.red > 60 && middle.blue > 60, "the middle of the crossfade blends both clips: \(middle)")
        let late = try await Pixels.sample(generator, seconds: 2.6, x: 960, y: 540)
        check(late.blue > 150 && late.red < 80, "second clip fills the centre later: \(late)")
        let letterbox = try await Pixels.sample(generator, seconds: 2.6, x: 120, y: 540)
        check(letterbox.red < 30 && letterbox.green < 30 && letterbox.blue < 30, "the portrait clip is letterboxed: \(letterbox)")

        let cut = clips.appendingPathComponent("cut.mp4")
        let cutResult = try await VideoAssembler.assemble(clips: [red, blue], transition: .cut, renderSize: CGSize(width: 1_280, height: 720), to: cut)
        check(abs(cutResult.duration - 3.5) < 0.02, "cut duration is the plain sum: \(cutResult.duration)")
        let cutSize = try await AVURLAsset(url: cut).loadTracks(withMediaType: .video).first!.load(.naturalSize)
        check(cutSize == CGSize(width: 1_280, height: 720), "720p output: \(cutSize)")

        // The tool resolves asset names and absolute paths and writes into the assets folder.
        let box = ProjectBox(nil)
        var context = makeContext(root: root, box: box)
        context.assetsDirectory = clips
        let toolResult = try await AssembleVideoTool().run(arguments: ["clips": [red.path, "blue.mp4"], "transition": "cut"], context: context, progress: { _ in })
        check(toolResult.attachments.count == 1 && toolResult.attachments[0].lastPathComponent.hasPrefix("assembled-") && FileManager.default.fileExists(atPath: toolResult.attachments[0].path), "assemble_video writes assembled-<ts>.mp4: \(toolResult.text)")
        await expectThrows("missing clip") { _ = try await AssembleVideoTool().run(arguments: ["clips": ["missing.mp4"]], context: context, progress: { _ in }) }
        await expectThrows("bad transition") { _ = try await AssembleVideoTool().run(arguments: ["clips": [red.path], "transition": "wipe"], context: context, progress: { _ in }) }
    }

    // MARK: - Ark client

    static func arkRequestBodies() throws {
        var request = ArkMediaClient.VideoTaskRequest(model: "doubao-seedance-2-5-260628", prompt: "  slow orbit around the product  ")
        request.images = [.init(url: "data:image/jpeg;base64,AAAA", role: "first_frame"), .init(url: "https://example.com/last.png", role: "last_frame"), .init(url: "https://example.com/ref.png", role: "reference_image")]
        request.videos = [.init(url: "https://example.com/ref.mp4", role: "reference_video")]
        request.audios = [.init(url: "https://example.com/ref.mp3", role: "reference_audio")]
        request.ratio = "16:9"
        request.duration = 5
        request.generateAudio = true
        request.seed = 7
        let payload = try ArkMediaClient.videoPayload(request)
        let content = payload["content"] as! [[String: Any]]
        check(payload["model"] as? String == "doubao-seedance-2-5-260628", "model")
        check(content.count == 6 && content[0]["type"] as? String == "text" && content[0]["text"] as? String == "slow orbit around the product", "prompt is the first, trimmed content item")
        check(content[1]["type"] as? String == "image_url" && content[1]["role"] as? String == "first_frame" && (content[1]["image_url"] as? [String: Any])?["url"] as? String == "data:image/jpeg;base64,AAAA", "first frame item")
        check(content[2]["role"] as? String == "last_frame" && content[3]["role"] as? String == "reference_image", "last frame and reference image items")
        check(content[4]["type"] as? String == "video_url" && content[4]["role"] as? String == "reference_video" && (content[4]["video_url"] as? [String: Any])?["url"] as? String == "https://example.com/ref.mp4", "reference video item")
        check(content[5]["type"] as? String == "audio_url" && content[5]["role"] as? String == "reference_audio", "reference audio item")
        check(payload["resolution"] == nil && payload["ratio"] as? String == "16:9" && payload["duration"] as? Int == 5 && payload["generate_audio"] as? Bool == true && payload["watermark"] as? Bool == false && payload["seed"] as? Int == 7, "optional fields only when set: \(payload.keys.sorted())")
        let serialized = try JSONSerialization.data(withJSONObject: payload)
        check(!serialized.isEmpty, "payload serializes")

        var badRole = ArkMediaClient.VideoTaskRequest(model: "m", prompt: "p")
        badRole.images = [.init(url: "https://example.com/a.png", role: "hero")]
        check((try? ArkMediaClient.videoPayload(badRole)) == nil, "unknown image roles are rejected")
        check((try? ArkMediaClient.videoPayload(.init(model: "m", prompt: "   "))) == nil, "empty prompts are rejected")

        let image = try ArkMediaClient.imagePayload(model: "doubao-seedream-4-5-251128", prompt: "soft gradient", size: "2560x1440", referenceImages: ["https://example.com/a.png"])
        check(image["model"] as? String == "doubao-seedream-4-5-251128" && image["prompt"] as? String == "soft gradient" && image["size"] as? String == "2560x1440"
              && image["response_format"] as? String == "url" && image["watermark"] as? Bool == false && image["sequential_image_generation"] as? String == "disabled"
              && image["image"] as? String == "https://example.com/a.png", "image payload shape: \(image)")
        let multi = try ArkMediaClient.imagePayload(model: "m", prompt: "p", size: "2048x2048", referenceImages: ["a", "b"])
        check((multi["image"] as? [String]) == ["a", "b"], "several references become an array")
        let bare = try ArkMediaClient.imagePayload(model: "m", prompt: "p", size: "1x1")
        check(bare["image"] == nil, "no image key without references")

        // Estimates and catalogue.
        check(ArkMediaClient.outputPixelSize(resolution: "720p", ratio: "16:9") == (1_280, 720) && ArkMediaClient.outputPixelSize(resolution: "720p", ratio: "9:16") == (720, 1_280)
              && ArkMediaClient.outputPixelSize(resolution: "1080p", ratio: "1:1") == (1_080, 1_080) && ArkMediaClient.outputPixelSize(resolution: "480p", ratio: "adaptive") == (864, 480), "pixel sizes per resolution and ratio")
        check(ArkMediaClient.estimateVideoTokens(width: 1_280, height: 720, duration: 5) == 108_000, "tokens = w×h×24×s/1024")
        let plain = ArkMediaClient.estimateVideoCost(model: "doubao-seedance-2-0-mini-260615", resolution: nil, ratio: "16:9", duration: 5, usesAudioOrReferenceMedia: false)
        check(plain.tokens == 108_000 && plain.resolution == "720p" && abs((plain.yuan ?? 0) - 2.484) < 0.001, "mini 5 s 720p ≈ ¥2.48: \(plain)")
        let audio = ArkMediaClient.estimateVideoCost(model: "doubao-seedance-2-5-260628", resolution: "1080p", ratio: "16:9", duration: 10, usesAudioOrReferenceMedia: true)
        check(audio.multiplier == 1.7 && audio.tokens == Int((Double(1_920 * 1_080 * 24 * 10) / 1_024 * 1.7).rounded()) && abs((audio.yuan ?? 0) - Double(audio.tokens) / 1_000 * 0.046) < 0.001, "reference media multiplies tokens by 1.7: \(audio)")
        check(ArkMediaClient.estimateVideoCost(model: "unknown-model", resolution: nil, ratio: "16:9", duration: 5, usesAudioOrReferenceMedia: false).yuan == nil, "unknown models have no price")
        check(ArkMediaClient.estimateImageCost(model: "doubao-seedream-4-5-251128") == 0.25 && ArkMediaClient.estimateImageCost(model: "doubao-seedream-5-0-260128") == 0.30 && ArkMediaClient.estimateImageCost(model: "doubao-seedream-4-0-250828") == 0.20, "image price table")
        check(ArkMediaClient.videoModelInfo(for: "doubao-seedance-2-0-mini-260615")?.resolutions == ["480p", "720p"] && ArkMediaClient.videoModelInfo(for: "doubao-seedance-2-0-260128")?.yuanPerKiloToken == 0.046 && ArkMediaClient.videoModelInfo(for: "doubao-seedance-1-0-pro-250528")?.yuanPerKiloToken == 0.015, "video model catalogue by prefix")
        check(ArkMediaClient.displayName(forModel: "doubao-seedance-2-0-mini-260615") == "Seedance 2.0 mini" && ArkMediaClient.displayName(forModel: "doubao-seedream-4-5-251128") == "Seedream 4.5", "display names")
        check(ArkMediaClient.defaultImageSize(ratio: "9:16") == "1440x2560" && ArkMediaClient.defaultImageSize(ratio: "1:1") == "2048x2048" && ArkMediaClient.defaultImageSize(ratio: "16:9") == "2560x1440", "default sizes satisfy the 3,686,400 px minimum")
        check(ArkMediaClient.cost(forModel: "doubao-seedance-2-0-mini-260615", usage: ArkUsage(completionTokens: 100_000)) == 2.3, "cost from usage")
        let redacted = ArkMediaClient.redact("key SECRET-KEY-123 and Authorization: Bearer abcdefghijklmnop", apiKey: "SECRET-KEY-123")
        check(!redacted.contains("SECRET-KEY-123") && !redacted.contains("abcdefghijklmnop") && redacted.contains("Bearer ***"), "keys and bearer tokens are masked: \(redacted)")
    }

    @MainActor
    static func arkFixtureRoundTrip(root: URL) async throws {
        guard let fixturePath = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".py") }) else {
            fatalError("FAIL: pass the path of fake-ark.py")
        }
        let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let imageFixture = fixtures.appendingPathComponent("image.jpg")
        try Pixels.writeJPEG(width: 64, height: 36, color: (0.9, 0.2, 0.2), to: imageFixture)
        let videoFixture = fixtures.appendingPathComponent("video.mp4")
        try await SolidClipWriter.write(to: videoFixture, width: 320, height: 180, duration: 1.0, color: (0.2, 0.8, 0.3), audio: false)
        let recording = fixtures.appendingPathComponent("recording.mp4")
        try await SolidClipWriter.write(to: recording, width: 640, height: 360, duration: 1.5, color: (0.2, 0.3, 0.9), audio: true)
        let logURL = fixtures.appendingPathComponent("requests.jsonl")

        let server = try FixtureServer(script: fixturePath, environment: [
            "FAKE_ARK_KEY": "FAKE-TEST-KEY", "FAKE_ARK_LOG": logURL.path,
            "FAKE_ARK_IMAGE": imageFixture.path, "FAKE_ARK_VIDEO": videoFixture.path,
        ])
        defer { server.stop() }
        let baseURL = URL(string: "http://127.0.0.1:\(server.port)/api/v3")!

        var client = ArkMediaClient(apiKey: "FAKE-TEST-KEY", baseURL: baseURL)
        client.pollingInitialDelay = 0.05
        client.pollingMaximumDelay = 0.1
        client.pollingTimeout = 10

        // Image: generate → download → PNG conversion.
        let reference = try ArkMediaClient.imageDataURL(for: imageFixture)
        check(reference.hasPrefix("data:image/jpeg;base64,") && reference.count > 100, "local images become JPEG data URLs")
        let image = try await client.generateImage(model: "doubao-seedream-4-5-251128", prompt: "soft gradient", size: "2560x1440", referenceImages: [reference])
        check(image.url?.hasSuffix("/files/image.jpg") == true && image.size == "2560x1440" && image.usage?.generatedImages == 1, "image response parsed: \(image)")
        let downloaded = fixtures.appendingPathComponent("downloaded.jpg")
        try await client.saveImage(image, to: downloaded)
        let downloadedBytes = try Data(contentsOf: downloaded)
        let imageFixtureBytes = try Data(contentsOf: imageFixture)
        check(downloadedBytes == imageFixtureBytes, "download streams the exact bytes")
        let png = fixtures.appendingPathComponent("converted.png")
        let pngSize = try ArkMediaClient.writePNG(from: downloaded, to: png)
        let pngBytes = try Data(contentsOf: png)
        check(pngSize == (64, 36) && pngBytes.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "JPEG results are re-encoded as PNG")

        // Video: create → poll (queued, running, succeeded) → download; cancellation reaches the server.
        var request = ArkMediaClient.VideoTaskRequest(model: "doubao-seedance-2-0-mini-260615", prompt: "slow orbit")
        request.images = [.init(url: reference, role: "first_frame")]
        request.ratio = "16:9"
        request.duration = 5
        let taskID = try await client.createVideoTask(request)
        check(taskID.hasPrefix("cgt-fixture-"), "task id returned: \(taskID)")
        let statuses = ToolLog()
        let task = try await client.waitForTask(id: taskID) { task, _ in statuses.record(task.status) }
        check(statuses.runs == ["queued", "running", "succeeded"], "polling follows the task through every status: \(statuses.runs)")
        check(task.videoURL?.hasSuffix("/files/video.mp4") == true && task.usage?.completionTokens == 123_456, "succeeded task carries the video URL and usage")
        let downloadedVideo = fixtures.appendingPathComponent("downloaded.mp4")
        try await client.download(task.videoURL!, to: downloadedVideo)
        let downloadedVideoBytes = try Data(contentsOf: downloadedVideo)
        let videoFixtureBytes = try Data(contentsOf: videoFixture)
        check(downloadedVideoBytes == videoFixtureBytes, "video download matches the fixture bytes")
        let slowID = try await client.createVideoTask(.init(model: "doubao-seedance-2-0-mini-260615", prompt: "slow again"))
        let slowClient = client
        let waiting = Task { try await slowClient.waitForTask(id: slowID) }
        try await Task.sleep(nanoseconds: 30_000_000)
        waiting.cancel()
        let cancelled = await waiting.result
        if case .failure(let error) = cancelled { check(error is CancellationError, "cancelled polling throws CancellationError: \(error)") } else { fatalError("FAIL: cancelled polling must fail") }
        try await Task.sleep(nanoseconds: 100_000_000)
        let slowStatus = try await client.getTask(id: slowID).status
        check(slowStatus == "cancelled", "cancelling the Swift task cancels the Ark task")

        // Errors never leak the key and carry hints.
        let wrongKey = ArkMediaClient(apiKey: "WRONG-KEY-VALUE", baseURL: baseURL)
        do {
            _ = try await wrongKey.generateImage(model: "m", prompt: "p")
            fatalError("FAIL: wrong key must fail")
        } catch let error as ArkMediaError {
            guard case let .api(status, _, message) = error else { fatalError("FAIL: expected api error, got \(error)") }
            check(status == 401 && !message.contains("WRONG-KEY-VALUE") && message.contains("rejected"), "401 is redacted and explained: \(error.localizedDescription)")
        }
        do {
            _ = try await client.generateImage(model: "doubao-seedream-not-open", prompt: "p")
            fatalError("FAIL: closed model must fail")
        } catch let error as ArkMediaError {
            guard case let .api(status, code, message) = error else { fatalError("FAIL: expected api error, got \(error)") }
            check(status == 404 && code == "ModelNotOpen" && message.contains("not activated"), "ModelNotOpen explains activation: \(message)")
        }

        // The request log shows the wire shapes the fixture received.
        let entries = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map { line -> [String: Any] in
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        }
        let imageEntry = entries.first { $0["path"] as? String == "/api/v3/images/generations" }!
        let imageBody = imageEntry["body"] as! [String: Any]
        check(imageEntry["auth_ok"] as? Bool == true && (imageBody["image"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true && imageBody["size"] as? String == "2560x1440", "image request on the wire: \(imageBody.keys.sorted())")
        let taskEntry = entries.first { $0["path"] as? String == "/api/v3/contents/generations/tasks" }!
        let taskBody = taskEntry["body"] as! [String: Any]
        let wireContent = taskBody["content"] as! [[String: Any]]
        check(wireContent.count == 2 && wireContent[1]["role"] as? String == "first_frame" && taskBody["duration"] as? Int == 5 && taskBody["watermark"] as? Bool == false, "video task on the wire: \(taskBody.keys.sorted())")
        check(entries.contains { $0["method"] as? String == "DELETE" }, "cancellation sent DELETE")

        // Tools end to end against the fixture.
        let box = ProjectBox(makeProject(sourceVideoPath: recording.path, duration: 1.5))
        let context = makeContext(root: root, box: box, arkBaseURL: baseURL)
        let progressLog = ToolLog()
        let generated = try await GenerateImageTool().run(arguments: ["prompt": "subtle gradient", "purpose": "background", "ratio": "16:9"], context: context, progress: { progressLog.record($0) })
        let generatedImage = generated.attachments[0]
        check(generatedImage.lastPathComponent.hasPrefix("image-") && generatedImage.pathExtension == "png" && ArkMediaClient.imagePixelSize(at: generatedImage)! == (64, 36), "generate_image saves image-<ts>.png: \(generated.text)")
        check(FileManager.default.fileExists(atPath: generatedImage.path + ".json") && generated.text.contains(generatedImage.lastPathComponent), "sidecar and result text")
        check(GenerateImageTool().costEstimate(arguments: [:]) == nil, "images need no confirmation")

        let background = try await SetBackgroundImageTool().run(arguments: ["path": generatedImage.lastPathComponent], context: context, progress: { _ in })
        check(box.project!.settings.backgroundStyle == .image && box.project!.settings.backgroundImagePath == generatedImage.path && background.attachments == [generatedImage], "set_background_image applies the generated file by name")

        let videoTool = GenerateVideoTool()
        let estimate = videoTool.costEstimate(arguments: ["prompt": "orbit", "duration": 5])!
        check(abs(estimate.yuan - 2.484) < 0.001 && estimate.summary.contains("Seedance 2.0 mini") && estimate.summary.contains("16:9"), "generate_video always asks for confirmation with an estimate: \(estimate)")
        await expectThrows("mini has no 1080p") { _ = try await videoTool.run(arguments: ["prompt": "x", "resolution": "1080p"], context: context, progress: { _ in }) }
        await expectThrows("duration range") { _ = try await videoTool.run(arguments: ["prompt": "x", "duration": 20], context: context, progress: { _ in }) }
        await expectThrows("missing reference") { _ = try await videoTool.run(arguments: ["prompt": "x", "first_frame": "missing.png"], context: context, progress: { _ in }) }
        let keyless = makeContext(root: root, box: box, arkBaseURL: baseURL, key: nil)
        await expectThrows("no key") { _ = try await videoTool.run(arguments: ["prompt": "x"], context: keyless, progress: { _ in }) }
        let video = try await videoTool.run(arguments: ["prompt": "orbit", "duration": 5, "first_frame": generatedImage.path, "reference_images": [generatedImage.lastPathComponent]], context: context, progress: { progressLog.record($0) })
        let generatedVideo = video.attachments[0]
        let generatedVideoBytes = try Data(contentsOf: generatedVideo)
        check(generatedVideo.lastPathComponent.hasPrefix("video-") && generatedVideo.pathExtension == "mp4" && generatedVideoBytes == videoFixtureBytes, "generate_video saves video-<ts>.mp4: \(video.text)")
        check(progressLog.runs.count >= 3, "progress messages were reported: \(progressLog.runs)")

        let frame = try await CaptureFrameTool().run(arguments: ["time": 0.5], context: context, progress: { _ in })
        let frameSize = ArkMediaClient.imagePixelSize(at: frame.attachments[0])!
        check(frame.attachments[0].lastPathComponent.hasPrefix("frame-") && frameSize.width == 1_920, "capture_frame renders a styled 1920-wide PNG: \(frameSize)")

        let listed = try await ListAssetsTool().run(arguments: [:], context: context, progress: { _ in })
        check(listed.text.contains(generatedImage.lastPathComponent) && listed.text.contains(generatedVideo.lastPathComponent) && listed.text.contains(frame.attachments[0].lastPathComponent) && !listed.text.contains(".json"), "list_assets lists media only: \(listed.text)")

        let exported = try await ExportDemoTool().run(arguments: [:], context: context, progress: { _ in })
        let exportDuration = try await AVURLAsset(url: exported.attachments[0]).load(.duration).seconds
        check(exported.attachments[0].lastPathComponent.hasPrefix("export-") && abs(exportDuration - 1.5) < 0.15, "export_demo (alias) renders the recording into export-<ts>.mp4: \(exported.text)")
        _ = try await UpdateSettingsTool().run(arguments: ["exportWidth": 1_280, "frameRate": 24], context: context, progress: { _ in })
        let customExport = try await ExportProjectTool().run(arguments: ["path": fixtures.appendingPathComponent("final/demo").path], context: context, progress: { _ in })
        check(customExport.attachments[0].path == fixtures.appendingPathComponent("final/demo.mp4").path && FileManager.default.fileExists(atPath: customExport.attachments[0].path), "export_project writes to the requested path with .mp4: \(customExport.text)")
        let exportedTrack = try await AVURLAsset(url: customExport.attachments[0]).loadTracks(withMediaType: .video).first!
        let (exportedSize, exportedFrameRate) = try await exportedTrack.load(.naturalSize, .nominalFrameRate)
        check(exportedSize.width == 1_280 && abs(Double(exportedFrameRate) - 24) < 1, "update_settings export width and frame rate reach the export: \(exportedSize), \(exportedFrameRate) fps")
        await expectToolError("existing export without overwrite", { _ = try await ExportProjectTool().run(arguments: ["path": customExport.attachments[0].path], context: context, progress: { _ in }) }) {
            if case let .invalidArgument(message) = $0 { return message.contains("overwrite: true") } else { return false }
        }
        let replaced = try await ExportProjectTool().run(arguments: ["path": customExport.attachments[0].path, "overwrite": true], context: context, progress: { _ in })
        check(replaced.attachments == customExport.attachments, "overwrite: true replaces the export: \(replaced.text)")
        await expectToolError("export over the recording", { _ = try await ExportProjectTool().run(arguments: ["path": recording.path, "overwrite": true], context: context, progress: { _ in }) }) {
            if case let .invalidArgument(message) = $0 { return message.contains("this project uses") } else { return false }
        }
        let recordingDuration = try await AVURLAsset(url: recording).load(.duration).seconds
        check(abs(recordingDuration - 1.5) < 0.1, "the recording survives an export aimed at it: \(recordingDuration)")

        // The session drives a real paid tool through the confirmation card.
        let provider = ScriptedCompletion([
            action("generate_video", "{\"prompt\": \"orbit\", \"duration\": 4, \"first_frame\": \"\(generatedImage.lastPathComponent)\"}"),
            reply("Your clip is ready.", ["Make an outro too"]),
        ])
        let session = AIAssistantSession(context: context, completion: provider, tools: AIAssistantToolCatalog.standard)
        session.send("make an intro clip")
        try await waitUntil("real confirmation") { session.pendingConfirmation != nil }
        check(session.pendingConfirmation?.toolName == "generate_video" && (session.pendingConfirmation?.estimate.yuan ?? 0) > 0, "paid tool waits for confirmation")
        session.confirmPending()
        try await waitUntil("real generation") { !session.isRunning }
        check(session.messages.map(\.role) == [.user, .tool, .assistant], "session ran the tool after confirmation: \(session.messages.map(\.role)) \(session.messages.map(\.text))")
        check(session.messages[1].attachments.first?.pathExtension == "mp4" && session.suggestions == ["Make an outro too"], "tool row has the clip and suggestions follow")
    }
}

// MARK: - Fixture server

final class FixtureServer {
    let process = Process()
    let port: Int

    init(script: String, environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script]
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if let text = String(data: buffer, encoding: .utf8), let line = text.split(separator: "\n").first(where: { $0.hasPrefix("PORT ") }) {
                port = Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces))!
                Thread.sleep(forTimeInterval: 0.1)
                return
            }
        }
        fatalError("FAIL: fixture server did not report a port")
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}

// MARK: - Media fixtures

enum Pixels {
    struct Sample: CustomStringConvertible {
        let red: Int
        let green: Int
        let blue: Int
        var description: String { "(r \(red), g \(green), b \(blue))" }
    }

    static func sample(_ generator: AVAssetImageGenerator, seconds: Double, x: Int, y: Int) async throws -> Sample {
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("FAIL: pixel context") }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Sample(red: Int(pixel[0]), green: Int(pixel[1]), blue: Int(pixel[2]))
    }

    static func writeJPEG(width: Int, height: Int, color: (Double, Double, Double), to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("FAIL: image context") }
        context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { fatalError("FAIL: make image") }
        try ArkMediaClient.jpegData(image, quality: 0.9).write(to: url)
    }
}

/// Solid-colour H.264 clips (optionally with a sine tone) for assembly tests.
enum SolidClipWriter {
    static func write(to url: URL, width: Int, height: Int, duration: Double, color: (Double, Double, Double), audio: Bool, frameRate: Int = 30) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(videoInput)
        let sampleRate = 44_100
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ])
        audioInput.expectsMediaDataInRealTime = false
        if audio { writer.add(audioInput) }
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "SolidClipWriter", code: 1) }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int((duration * Double(frameRate)).rounded())
        let format = audio ? try audioFormat(sampleRate: sampleRate) : nil
        let totalSamples = Int(duration * Double(sampleRate))
        var sampleOffset = 0
        func appendAudio(until limit: Int) async throws {
            guard let format else { return }
            while sampleOffset < limit {
                while !audioInput.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error ?? NSError(domain: "SolidClipWriter", code: 7) }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                let count = min(1_024, limit - sampleOffset)
                let sample = try toneBuffer(offset: sampleOffset, count: count, sampleRate: sampleRate, format: format)
                guard audioInput.append(sample) else { throw writer.error ?? NSError(domain: "SolidClipWriter", code: 5) }
                sampleOffset += count
            }
        }
        for frameIndex in 0..<frameCount {
            while !videoInput.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? NSError(domain: "SolidClipWriter", code: 7) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "SolidClipWriter", code: 2) }
            var maybeBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
            guard let buffer = maybeBuffer else { throw NSError(domain: "SolidClipWriter", code: 3) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer),
               let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) {
                context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(frameRate))) else {
                throw writer.error ?? NSError(domain: "SolidClipWriter", code: 4)
            }
            // Feed audio chronologically: offline inputs back-pressure each other.
            try await appendAudio(until: min(totalSamples, Int(Double(frameIndex + 1) / Double(frameRate) * Double(sampleRate))))
        }
        videoInput.markAsFinished()
        if audio {
            try await appendAudio(until: totalSamples)
            audioInput.markAsFinished()
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "SolidClipWriter", code: 6) }
    }

    private static func audioFormat(sampleRate: Int) throws -> CMAudioFormatDescription {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw NSError(domain: "SolidClipWriter", code: Int(status)) }
        return format
    }

    private static func toneBuffer(offset: Int, count: Int, sampleRate: Int, format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        var samples = (0..<count).map { Float(sin(Double(offset + $0) / Double(sampleRate) * 440 * .pi * 2) * 0.1) }
        let byteCount = count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { throw NSError(domain: "SolidClipWriter", code: Int(status)) }
        status = samples.withUnsafeMutableBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == kCMBlockBufferNoErr else { throw NSError(domain: "SolidClipWriter", code: Int(status)) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sampleRate)),
                                        decodeTimeStamp: .invalid)
        var sampleSize = MemoryLayout<Float>.size
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                      formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { throw NSError(domain: "SolidClipWriter", code: Int(status)) }
        return sampleBuffer
    }
}
