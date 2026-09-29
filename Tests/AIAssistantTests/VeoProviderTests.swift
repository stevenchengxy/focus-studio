import Foundation

extension AIAssistantTests {
    static func veoRequestBodies() throws {
        check(VeoMediaClient.modelIDs.count == 3, "three documented Veo 3.1 model IDs")
        check(VeoMediaClient.estimateVideoCostUSD(
            model: "veo-3.1-fast-generate-preview", resolution: "1080p", duration: 8
        ) == 0.96, "official Fast 1080p price is $0.12/s")
        check(VeoMediaClient.estimateVideoCostUSD(
            model: "veo-3.1-lite-generate-preview", resolution: "4k", duration: 8
        ) == nil, "Lite cannot produce 4k")

        let image = try VeoMediaClient.inlineImage(from: "data:image/jpeg;base64,/9j/2Q==")
        var task = VeoMediaClient.VideoTaskRequest(
            model: "veo-3.1-fast-generate-preview", prompt: "  controlled camera drift  ",
            duration: 8, ratio: "16:9", resolution: "1080p"
        )
        task.firstFrame = image
        task.lastFrame = image
        task.seed = 17
        let payload = try VeoMediaClient.videoPayload(task)
        let instance = (payload["instances"] as! [[String: Any]])[0]
        let parameters = payload["parameters"] as! [String: Any]
        check(instance["prompt"] as? String == "controlled camera drift"
              && (instance["image"] as? [String: Any])?["inlineData"] != nil
              && (instance["lastFrame"] as? [String: Any])?["inlineData"] != nil,
              "Gemini REST instances use inline image objects and trim prompt")
        check(parameters["durationSeconds"] as? String == "8"
              && parameters["resolution"] as? String == "1080p"
              && parameters["aspectRatio"] as? String == "16:9"
              && parameters["seed"] as? Int == 17,
              "Gemini REST parameters preserve exact duration, size, ratio, seed")
        task.duration = 6
        check((try? VeoMediaClient.videoPayload(task)) == nil, "1080p rejects under 8 seconds")
        task.duration = 8
        task.resolution = "720p"
        task.referenceImages = [image]
        let references = try VeoMediaClient.videoPayload(task)
        let referenceInstance = (references["instances"] as! [[String: Any]])[0]
        check((referenceInstance["referenceImages"] as? [[String: Any]])?.first?["referenceType"] as? String == "asset",
              "reference images are sent as Google asset references")
        task.model = "veo-3.1-lite-generate-preview"
        check((try? VeoMediaClient.videoPayload(task)) == nil, "Veo Lite rejects reference images")
        task.model = "unknown-veo"
        check((try? VeoMediaClient.videoPayload(task)) == nil, "unknown model is rejected before network")

        let tool = GenerateVideoTool()
        let estimate = tool.costEstimate(arguments: [
            "model": "veo-3.1-fast-generate-preview", "duration": 8, "resolution": "1080p",
        ])
        check(estimate?.currencyCode == "USD" && estimate?.amount == 0.96
              && estimate?.summary.contains("Veo 3.1 Fast") == true,
              "paid confirmation quotes exact Veo model and USD amount")
        let unknown = tool.costEstimate(arguments: ["model": "not-a-real-video-model"])
        check(unknown == nil, "unknown model never falls back to a Seedance or zero-priced estimate")
    }

    @MainActor
    static func veoFixtureRoundTrip(root: URL) async throws {
        guard let arkFixturePath = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".py") }) else {
            fatalError("FAIL: pass the path of fake-ark.py")
        }
        let fixturePath = URL(fileURLWithPath: arkFixturePath).deletingLastPathComponent()
            .appendingPathComponent("fake-veo.py").path
        let directory = root.appendingPathComponent("veo-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("start.jpg")
        try Pixels.writeJPEG(width: 96, height: 54, color: (0.2, 0.3, 0.9), to: image)
        let video = directory.appendingPathComponent("result.mp4")
        try await SolidClipWriter.write(to: video, width: 320, height: 180, duration: 1.0,
                                        color: (0.2, 0.8, 0.3), audio: true)
        let log = directory.appendingPathComponent("requests.jsonl")
        let server = try FixtureServer(script: fixturePath, environment: [
            "FAKE_VEO_KEY": "FAKE-GOOGLE-KEY",
            "FAKE_VEO_LOG": log.path,
            "FAKE_VEO_VIDEO": video.path,
        ])
        defer { server.stop() }
        let baseURL = URL(string: "http://127.0.0.1:\(server.port)/v1beta")!
        var client = VeoMediaClient(apiKey: "FAKE-GOOGLE-KEY", baseURL: baseURL)
        client.pollingDelay = 0.02
        client.pollingTimeout = 10
        let frame = try VeoMediaClient.inlineImage(from: ArkMediaClient.imageDataURL(for: image))
        var task = VeoMediaClient.VideoTaskRequest(
            model: "veo-3.1-fast-generate-preview", prompt: "poll a luminous glass shape",
            duration: 8, ratio: "16:9", resolution: "720p"
        )
        task.firstFrame = frame
        let operation = try await client.createVideoTask(task)
        check(operation.hasPrefix("operations/veo-"), "create returns a long-running operation name")
        let completed = try await client.waitForTask(name: operation)
        check(completed.videoURL.contains("/v1beta/files/video.mp4"),
              "poll response carries downloadable video URI")
        let downloaded = directory.appendingPathComponent("downloaded.mp4")
        try await client.download(completed.videoURL, to: downloaded)
        let downloadedBytes = try Data(contentsOf: downloaded)
        let fixtureBytes = try Data(contentsOf: video)
        check(downloadedBytes == fixtureBytes,
              "Veo download writes an intact MP4")

        let wrongKey = VeoMediaClient(apiKey: "WRONG-GOOGLE-KEY", baseURL: baseURL)
        do {
            _ = try await wrongKey.createVideoTask(task)
            fatalError("FAIL: wrong Veo key must fail")
        } catch let error as VeoMediaError {
            check(!error.localizedDescription.contains("WRONG-GOOGLE-KEY"),
                  "key is redacted from Gemini API failures")
        }
        await expectThrows("download from a foreign host") {
            try await client.download("https://example.com/other.mp4", to: downloaded)
        }

        let box = ProjectBox(nil)
        var context = makeContext(root: root, box: box)
        context.geminiVideoAPIKey = { "FAKE-GOOGLE-KEY" }
        context.geminiVideoBaseURL = baseURL
        let tool = GenerateVideoTool()
        await expectThrows("arbitrary reference video unsupported by Veo") {
            _ = try await tool.run(arguments: [
                "prompt": "test", "model": "veo-3.1-fast-generate-preview",
                "duration": 8, "reference_video": video.path,
            ], context: context, progress: { _ in })
        }
        await expectThrows("last frame without first") {
            _ = try await tool.run(arguments: [
                "prompt": "test", "model": "veo-3.1-fast-generate-preview",
                "duration": 8, "last_frame": image.path,
            ], context: context, progress: { _ in })
        }
        let result = try await tool.run(arguments: [
            "prompt": "quiet luminous glass",
            "model": "veo-3.1-fast-generate-preview",
            "duration": 8, "ratio": "16:9", "resolution": "720p",
            "first_frame": image.path,
        ], context: context, progress: { _ in })
        check(result.attachments.count == 1 && result.attachments[0].pathExtension == "mp4"
              && result.text.contains("Veo 3.1 Fast") && result.text.contains("$0.80"),
              "generate_video dispatches to Veo and reports its USD estimate")
        let sidecar = try String(contentsOf: URL(fileURLWithPath: result.attachments[0].path + ".json"),
                                 encoding: .utf8)
        check(sidecar.contains("\"provider\" : \"gemini\"") || sidecar.contains("\"provider\":\"gemini\""),
              "Veo asset sidecar records its provider")
        let requests = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        check(requests.contains { ($0["path"] as? String)?.contains(":predictLongRunning") == true
              && $0["auth_ok"] as? Bool == true },
              "Veo request reached its documented REST endpoint with Google key")
        check(requests.contains { ($0["path"] as? String)?.contains("/operations/") == true }
              && requests.contains { ($0["path"] as? String)?.contains("/files/video.mp4") == true },
              "Veo operation was polled and MP4 downloaded")

        let networkCount = requests.count
        var invalidVideoContext = context
        invalidVideoContext.preferredVideoModelID = { "not-a-real-video-model" }
        let badVideoSession = AIAssistantSession(
            context: invalidVideoContext,
            completion: ScriptedCompletion([
                action("generate_video", "{\"prompt\":\"test\",\"model\":\"not-a-real-video-model\"}"),
                reply("No generation started."),
            ]),
            tools: AIAssistantToolCatalog.standard
        )
        badVideoSession.send("Make a video with this model")
        try await waitUntil("invalid video model rejected") { !badVideoSession.isRunning }
        check(badVideoSession.pendingConfirmation == nil
              && badVideoSession.messages.contains(where: { $0.role == .error }),
              "unknown paid video model is blocked before confirmation")
        let badImageSession = AIAssistantSession(
            context: context,
            completion: ScriptedCompletion([
                action("generate_image", "{\"prompt\":\"test\",\"model\":\"not-a-real-seedream\"}"),
                reply("No generation started."),
            ]),
            tools: AIAssistantToolCatalog.standard
        )
        badImageSession.send("Make an image with this model")
        try await waitUntil("invalid image model rejected") { !badImageSession.isRunning }
        check(badImageSession.pendingConfirmation == nil
              && badImageSession.messages.contains(where: { $0.role == .error }),
              "unknown paid image model is blocked before confirmation")
        context.preferredVideoModelID = { "veo-3.1-fast-generate-preview" }
        let videoSession = AIAssistantSession(
            context: context,
            completion: ScriptedCompletion([
                action("generate_video", "{\"prompt\":\"quiet glass\",\"model\":\"veo-3.1-fast-generate-preview\",\"duration\":8}"),
            ]),
            tools: AIAssistantToolCatalog.standard
        )
        videoSession.send("Make a Veo shot")
        try await waitUntil("Veo confirmation") { videoSession.pendingConfirmation != nil }
        check(videoSession.pendingConfirmation?.estimate.currencyCode == "USD"
              && videoSession.pendingConfirmation?.estimate.amount == 0.8,
              "Veo paid confirmation shows the published USD cost")
        videoSession.cancelPending()
        try await waitUntil("Veo confirmation cancellation") { !videoSession.isRunning }
        let imageSession = AIAssistantSession(
            context: context,
            completion: ScriptedCompletion([
                action("generate_image", "{\"prompt\":\"soft blue glass\",\"model\":\"doubao-seedream-4-5-251128\"}"),
            ]),
            tools: AIAssistantToolCatalog.standard
        )
        imageSession.send("Make a still")
        try await waitUntil("Seedream confirmation") { imageSession.pendingConfirmation != nil }
        check(imageSession.pendingConfirmation?.estimate.currencyCode == "CNY"
              && imageSession.pendingConfirmation?.estimate.amount == 0.25,
              "Seedream image still has a priced paid confirmation")
        imageSession.cancelPending()
        try await waitUntil("Seedream confirmation cancellation") { !imageSession.isRunning }
        let finalNetworkCount = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").count
        check(finalNetworkCount == networkCount,
              "invalid or cancelled paid requests never contacted Gemini")
    }
}
