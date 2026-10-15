import FocusStudioCore
import Foundation

extension AIAssistantTests {
    actor SpeechProbe {
        var requests = 0
        var approvals = 0
        var lastSummary = ""
        func requested() { requests += 1 }
        func approved(_ summary: String) { approvals += 1; lastSummary = summary }
        func snapshot() -> (Int, Int, String) { (requests, approvals, lastSummary) }
    }

    @MainActor
    static func speechTools(root: URL) async throws {
        let tool = GenerateVoiceoverTool()
        let audio = speechFixtureWAV(seconds: 6)
        let configuration = SpeechGenerationConfiguration(provider: .minimax, model: "exact-speech-model", voice: "exact-voice")
        func fixture(duration: Double = 20) -> (ProjectBox, FakeApp, AIAssistantContext, SpeechProbe) {
            let project = makeProject(sourceVideoPath: "/demo.mp4", duration: duration)
            let box = ProjectBox(project), app = FakeApp(box: box), probe = SpeechProbe()
            app.projects = [project]; app.openID = project.id
            var context = makeContext(root: root, box: box)
            context.app = app
            context.speechConfiguration = { configuration }
            context.speechAPIKey = { _ in "FAKE-SPEECH-KEY" }
            context.confirmSpeechGeneration = { summary in await probe.approved(summary); return true }
            context.speechGenerate = { _, _ in
                await probe.requested()
                return SpeechGenerationResult(audioData: audio, fileExtension: "wav")
            }
            return (box, app, context, probe)
        }

        let (box, app, context, probe) = fixture()
        let listed = try await ListSpeechModelsTool().run(arguments: [:], context: context, progress: { _ in })
        check(listed.data?["model"] == "exact-speech-model" && listed.data?["key_configured"] == true,
              "speech discovery returns exact active model and key presence")
        let discoveryJSON = String(decoding: try listed.data!.jsonData(), as: UTF8.self)
        check(!discoveryJSON.contains("FAKE-SPEECH-KEY"),
              "speech discovery never includes a credential")
        var counts = await probe.snapshot()
        check(counts.0 == 0 && counts.1 == 0, "speech discovery performs no approval or provider request")

        for invalid: [String: Any] in [
            ["segments": [["text": "Hello", "start_time": -1]]],
            ["segments": [["text": "Hello", "start_time": true]]],
            ["segments": [["text": "Hello", "start_time": 20]]],
            ["segments": [["text": "", "start_time": 0]]],
            ["segments": [["text": "Hello", "start_time": 0]], "add_captions": 1],
            ["segments": [["text": "Hello", "start_time": 0]], "provider": "openAI"],
        ] {
            await expectThrows("invalid speech plans fail before approval and synthesis") {
                _ = try await tool.run(arguments: invalid, context: context, progress: { _ in })
            }
        }
        counts = await probe.snapshot()
        check(counts.0 == 0 && counts.1 == 0 && app.imported.isEmpty && box.writeCount == 0,
              "invalid plans do not spend money, import files or change a project")

        let (longCaptionBox, longCaptionApp, longCaptionContext, longCaptionProbe) = fixture()
        longCaptionBox.project!.settings.aspectRatio = .vertical
        longCaptionBox.project!.settings.captionStyle = CaptionStyle(scale: 1.6)
        longCaptionApp.projects = [longCaptionBox.project!]
        await expectThrows("captions that cannot fit must be split before paid synthesis") {
            _ = try await tool.run(arguments: ["segments": [["text": String(repeating: "界", count: 240), "start_time": 0]]],
                                   context: longCaptionContext, progress: { _ in })
        }
        let longCounts = await longCaptionProbe.snapshot()
        check(longCounts.0 == 0 && longCounts.1 == 0 && longCaptionApp.imported.isEmpty && longCaptionBox.writeCount == 0,
              "caption fit preflight happens before approval, paid synthesis and import")

        var denied = context
        denied.isExternal = true
        denied.confirmSpeechGeneration = { _ in false }
        do {
            _ = try await tool.run(arguments: ["segments": [["text": "Hello", "start_time": 0]], "confirmed": true],
                                   context: denied, progress: { _ in })
            check(false, "MCP cannot bypass the app's runtime approval")
        } catch let failure as AIToolFailure {
            check(failure.data["requests_sent"] == 0 && failure.data["retry"] == false
                  && failure.message.contains("No request was sent"),
                  "declining approval clearly reports zero billable requests")
        }
        var noApproval = context; noApproval.confirmSpeechGeneration = nil
        await expectThrows("missing native approval handler fails closed") {
            _ = try await tool.run(arguments: ["segments": [["text": "Hello", "start_time": 0]]],
                                   context: noApproval, progress: { _ in })
        }
        counts = await probe.snapshot()
        check(counts.0 == 0, "declined or absent app approval cannot send a provider request")

        let success = try await tool.run(arguments: ["segments": [["text": "See your work clearly.", "start_time": 0],
                                                                  ["text": "Share the finished demo.", "start_time": 8]]],
                                         context: context, progress: { _ in })
        let voices = box.project!.settings.resolvedProductDemoAudio.voiceovers!
        let chapters = box.project!.chapters!
        check(voices.count == 2 && voices[0].timelineStart == 0 && voices[0].timelineEnd == 6
              && voices[1].timelineStart == 8 && voices[1].timelineEnd == 14,
              "narration placement uses measured audio duration and requested output starts")
        check(chapters.count == 2 && chapters[0].start == 0 && chapters[0].end == 6
              && chapters[1].start == 8 && chapters[1].end == 14 && box.writeCount == 1,
              "matching captions and narration are one atomic edit")
        check(success.data?["subtitle_timing"] == "measured_segment_duration" && success.data?["word_aligned"] == false,
              "receipt does not claim word alignment")
        counts = await probe.snapshot()
        check(counts.0 == 2 && counts.1 == 1 && counts.2.contains("exact-speech-model")
              && counts.2.contains("exact-voice") && counts.2.contains("See your work clearly.")
              && counts.2.contains("exact price is unknown"),
              "one real approval discloses exact model, voice, script and paid usage before the batch")

        let (shortBox, shortApp, shortContext, shortProbe) = fixture(duration: 10)
        await expectThrows("overflow is refused rather than cutting off speech") {
            _ = try await tool.run(arguments: ["segments": [["text": "Too late for this sentence.", "start_time": 8]]],
                                   context: shortContext, progress: { _ in })
        }
        counts = await shortProbe.snapshot()
        check(counts.0 == 1 && shortApp.imported.isEmpty && shortBox.writeCount == 0,
              "overflow is measured before import and leaves project unchanged")

        let (overlapBox, overlapApp, overlapContext, overlapProbe) = fixture()
        await expectThrows("a generated segment cannot collide with the next planned sentence") {
            _ = try await tool.run(arguments: ["segments": [["text": "First long sentence.", "start_time": 0],
                                                             ["text": "Second sentence.", "start_time": 4]]],
                                   context: overlapContext, progress: { _ in })
        }
        counts = await overlapProbe.snapshot()
        check(counts.0 == 1 && overlapApp.imported.isEmpty && overlapBox.writeCount == 0,
              "known collision stops before paying for the next segment")

        let (captionBox, captionApp, captionContext, captionProbe) = fixture()
        captionBox.project!.chapters = [DemoChapter(start: 0, end: 3, title: "Keep this title")]
        captionApp.projects = [captionBox.project!]
        let original = captionBox.project
        await expectThrows("existing captions are never silently replaced") {
            _ = try await tool.run(arguments: ["segments": [["text": "Narration here.", "start_time": 1]]],
                                   context: captionContext, progress: { _ in })
        }
        counts = await captionProbe.snapshot()
        check(counts.0 == 0 && captionBox.project == original && captionBox.writeCount == 0,
              "caption conflicts are caught before synthesis without losing existing text")

        let (movingBox, movingApp, baseMovingContext, movingProbe) = fixture()
        var movingContext = baseMovingContext
        movingContext.speechGenerate = { _, _ in
            await movingProbe.requested()
            await MainActor.run { movingBox.project!.title = "User's newer edit" }
            return SpeechGenerationResult(audioData: audio, fileExtension: "wav")
        }
        await expectThrows("long-running speech does not overwrite a user's newer project edit") {
            _ = try await tool.run(arguments: ["segments": [["text": "A narration line.", "start_time": 0]]],
                                   context: movingContext, progress: { _ in })
        }
        check(movingBox.project!.title == "User's newer edit" && movingBox.writeCount == 0 && movingApp.imported.isEmpty,
              "project revision change preserves the user's edit and inserts no partial narration")

        let (failedBox, failedApp, baseFailedContext, failedProbe) = fixture()
        var failedContext = baseFailedContext
        failedContext.speechGenerate = { _, _ in
            await failedProbe.requested()
            if await failedProbe.snapshot().0 > 1 { throw AIToolError.failed("Fixture provider failed") }
            return SpeechGenerationResult(audioData: audio, fileExtension: "wav")
        }
        do {
            _ = try await tool.run(arguments: ["segments": [["text": "First sentence.", "start_time": 0],
                                                             ["text": "Later sentence.", "start_time": 8]]],
                                   context: failedContext, progress: { _ in })
            check(false, "second-segment failure must return an error")
        } catch let failure as AIToolFailure {
            check(failure.data["requests_sent"] == 2 && failure.data["retry"] == false,
                  "partial paid request failure reports usage risk and prohibits automatic retry")
        }
        check(failedBox.writeCount == 0 && failedApp.imported.isEmpty,
              "a later synthesis failure cannot leave partial audio or captions in the project")

        let (rollbackBox, rollbackApp, baseRollbackContext, _) = fixture()
        let rollbackOriginal = rollbackBox.project
        var rollbackContext = baseRollbackContext
        rollbackContext.updateProject = { _ in throw AIToolError.failed("Fixture editor refused the final commit") }
        await expectThrows("a failed final commit rolls back imported voiceover files through the app") {
            _ = try await tool.run(arguments: ["segments": [["text": "First sentence.", "start_time": 0],
                                                             ["text": "Later sentence.", "start_time": 8]]],
                                   context: rollbackContext, progress: { _ in })
        }
        check(rollbackBox.project == rollbackOriginal && rollbackBox.writeCount == 0 && rollbackApp.imported.isEmpty,
              "import rollback leaves neither a partial project edit nor newly owned audio files")

        let (cancelBox, cancelApp, baseCancelContext, cancelProbe) = fixture()
        var preparingCancelContext = baseCancelContext
        preparingCancelContext.speechGenerate = { _, _ in
            await cancelProbe.requested()
            try await Task.sleep(for: .seconds(30))
            return SpeechGenerationResult(audioData: audio, fileExtension: "wav")
        }
        let cancelContext = preparingCancelContext
        let task = Task { try await tool.run(arguments: ["segments": [["text": "A cancelled sentence.", "start_time": 0]]],
                                             context: cancelContext, progress: { _ in }) }
        while await cancelProbe.snapshot().0 == 0 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; check(false, "cancelled synthesis must not finish") }
        catch let failure as AIToolFailure {
            check(failure.data["status"] == "cancelled" && failure.data["requests_sent"] == 1
                  && failure.data["retry"] == false && failure.message.contains("may have incurred usage"),
                  "cancelled synthesis preserves possible paid usage and prohibits automatic replay")
        }
        check(cancelBox.writeCount == 0 && cancelApp.imported.isEmpty,
              "cancellation during synthesis never inserts narration or captions")

        let (_, _, baseSessionContext, sessionProbe) = fixture()
        var mutableSessionContext = baseSessionContext
        mutableSessionContext.speechGenerate = { _, _ in
            await sessionProbe.requested()
            try await Task.sleep(for: .seconds(30))
            return SpeechGenerationResult(audioData: audio, fileExtension: "wav")
        }
        let provider = ScriptedCompletion([action("generate_voiceover", #"{"segments":[{"text":"A cancelled sentence.","start_time":0}]}"#)])
        let session = AIAssistantSession(context: mutableSessionContext, completion: provider, tools: [tool])
        session.send("Generate narration.")
        while await sessionProbe.snapshot().0 == 0 { await Task.yield() }
        session.stop()
        try await waitUntil("cancelled narration session to finish") { !session.isRunning }
        check(session.messages.contains { $0.toolName == "generate_voiceover" && $0.text.contains("may have incurred usage")
              && $0.text.contains("do not automatically retry") },
              "assistant Stop retains the paid cancellation warning in conversation history")
    }

    /// Six seconds matches FakeApp.importVoiceover's measured fixture duration.
    private static func speechFixtureWAV(seconds: Int) -> Data {
        let rate: UInt32 = 16_000, samples = UInt32(seconds) * rate, bytes = samples * 2
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func uint32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func uint16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        ascii("RIFF"); uint32(36 + bytes); ascii("WAVEfmt "); uint32(16)
        uint16(1); uint16(1); uint32(rate); uint32(rate * 2); uint16(2); uint16(16)
        ascii("data"); uint32(bytes); data.append(Data(count: Int(bytes)))
        return data
    }
}

extension AIAssistantTests.FakeApp {
    /// Fake ownership ledger, equivalent to the native store's rollback of only
    /// uncommitted imports; normal successful voiceover tests keep their ledger.
    func discardImportedVoiceovers(_ clips: [VoiceoverClip], projectID: UUID) async {
        let paths = Set(clips.map(\.filePath))
        imported.removeAll { paths.contains($0.path) }
    }
}
