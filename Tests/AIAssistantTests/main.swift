import AppKit
@preconcurrency import AVFoundation
import FocusStudioCore
import Foundation

/// Offline coverage for the AI assistant module: the strict JSON protocol,
/// the agent loop driven by a scripted model, the confirmation gate for paid
/// tools, tool argument validation, AVFoundation clip assembly and the Ark
/// client (request bodies plus a generate → poll → download round trip
/// against the local Python fixture in fake-ark.py).
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
        step("update_settings"); try await updateSettingsValidation(root: root)
        step("set_chapters"); try await setChaptersSanitization(root: root)
        step("assemble_video"); try await assembleVideo(root: root)
        step("Ark request bodies"); try arkRequestBodies()
        step("Ark fixture round trip"); try await arkFixtureRoundTrip(root: root)
        print("AIAssistantTests: PASS (protocol parsing, scripted agent loop, confirmation gate, stop, update_settings, set_chapters, assemble_video, Ark request bodies, Ark fixture round trip incl. tools)")
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
        init(_ project: RecordingProject?) { self.project = project }
    }

    @MainActor
    static func makeContext(root: URL, box: ProjectBox, arkBaseURL: URL = ArkMediaClient.defaultBaseURL, key: String? = "FAKE-TEST-KEY") -> AIAssistantContext {
        AIAssistantContext(
            assetsDirectory: root.appendingPathComponent("assets", isDirectory: true),
            uiLanguage: "en",
            readProject: { box.project },
            updateProject: { change in
                guard var project = box.project else { return }
                change(&project)
                box.project = project
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
        check(exported.attachments[0].lastPathComponent.hasPrefix("demo-export-") && abs(exportDuration - 1.5) < 0.15, "export_demo renders the recording: \(exported.text)")

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
