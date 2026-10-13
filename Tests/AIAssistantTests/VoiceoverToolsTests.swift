import FocusStudioCore
import Foundation

extension AIAssistantTests {
    @MainActor
    static func voiceoverTools(root: URL) async throws {
        var source = makeProject(sourceVideoPath: "/demo.mp4", duration: 10)
        let voice = VoiceoverClip(title: "Explanation", filePath: "/speech.wav", sourceDuration: 6,
                                 sourceStart: 1, sourceEnd: 5, timelineStart: 2)
        source.settings.productDemoAudio = .init(voiceovers: [voice])
        let box = ProjectBox(source), context = makeContext(root: root, box: box)
        let tool = EditVoiceoverTool()
        let id = voice.id.uuidString
        let receipt = try await tool.run(arguments: ["action": "update", "voiceover_id": id,
            "source_in": 2, "source_out": 4, "timeline_start": 3, "volume": 0.5, "fade_in": 0.3, "fade_out": 0.4],
            context: context, progress: { _ in })
        let changed = box.project!.settings.resolvedProductDemoAudio.voiceovers![0]
        check(changed.id == voice.id && changed.filePath == voice.filePath && changed.sourceDuration == 6
              && changed.duration == 2 && changed.timelineStart == 3 && changed.volume == 0.5,
              "voiceover edit retains the original asset, duration and stable id")
        check(receipt.data?["voiceovers"]?[0]?["timeline_end"] == 5 && box.writeCount == 1,
              "one atomic write reports the audible output range")
        let before = box.project, writes = box.writeCount
        for bad: [String: Any] in [["source_in": 4], ["source_out": 6.5], ["timeline_start": -1],
            ["volume": 2.1], ["volume": true], ["fade_in": Double.nan], ["enabled": 1], ["fade_out": "2"],
            ["voiceover_id": UUID().uuidString]] {
            await expectThrows("invalid voiceover edits preserve the project") {
                _ = try await tool.run(arguments: ["action": "update", "voiceover_id": id].merging(bad) { _, v in v },
                                       context: context, progress: { _ in })
            }
        }
        check(box.project == before && box.writeCount == writes, "invalid narration never partially mutates")
        _ = try await SetAudioMixTool().run(arguments: ["source_volume": 1.5, "music_volume": 0.2,
            "music_fade_in": 1, "music_fade_out": 2, "duck_music": true, "duck_level": 0.1],
            context: context, progress: { _ in })
        let mix = box.project!.settings.resolvedProductDemoAudio
        check(mix.sourceAudioVolume == 1.5 && mix.backgroundMusicFadeOut == 2 && mix.voiceoverDuckingLevel == 0.1,
              "assistant can control captured audio, music fades and ducking")
        _ = try await SetAudioMixTool().run(arguments: ["duck_music": false], context: context, progress: { _ in })
        check(box.project!.settings.resolvedProductDemoAudio.voiceoverDuckingLevel == nil
              && box.project!.settings.resolvedProductDemoAudio.sourceAudioVolume == 1.5,
              "disabling ducking preserves the other mix settings")

        let cut = try DemoTimelineEdit(keepRanges: [.init(start: 2.5, end: 3.5), .init(start: 4, end: 6)], sourceDuration: 10)
        let cutProject = cut.remap(source, sourceVideoPath: "/cut.mp4")
        let voices = cutProject.settings.resolvedProductDemoAudio.voiceovers!
        check(voices.count == 2 && voices[0].sourceStart == 1.5 && voices[0].sourceEnd == 2.5
              && voices[0].timelineStart == 0 && voices[1].sourceStart == 3 && voices[1].sourceEnd == 5
              && voices[1].timelineStart == 1 && voices[0].id != voices[1].id,
              "ripple cuts preserve only corresponding narration without looping or duplicate IDs")
        let timeline = try DemoVideoTimeline(project: source)
        let splitProject = try timeline.applying(.split(clipID: timeline.clips[0].id, at: 4), to: source)
        check(splitProject.settings.resolvedProductDemoAudio.voiceovers == [voice],
              "splitting picture without removing frames leaves speech continuous and unchanged")
        var sparse = makeProject(sourceVideoPath: "/sparse.mp4", duration: 40)
        sparse.clickEvents = [ClickEvent(time: 5, x: 0.5, y: 0.5, button: .left)]
        sparse.settings.productDemoAudio = .init(voiceovers: [.init(title: "Long explanation", filePath: "/speech.wav",
            sourceDuration: 25, timelineStart: 10)])
        let proposal = try DemoPacingAnalyzer.analyze(sparse, hasSourceAudio: false)
        check(proposal.edit.ranges.contains { $0.start <= 10 && $0.end >= 35 },
              "automatic pacing retains the entire enabled narration interval")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProductDemoAudioSettings())) as! [String: Any]
        legacy.removeValue(forKey: "voiceovers"); legacy.removeValue(forKey: "voiceoverDuckingLevel")
        let decoded = try JSONDecoder().decode(ProductDemoAudioSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(decoded.voiceovers == nil && decoded.voiceoverDuckingLevel == nil && decoded.sourceAudioVolume == 1,
              "existing project audio keeps its mix when new fields are missing")
        _ = try await tool.run(arguments: ["action": "remove", "voiceover_id": id], context: context, progress: { _ in })
        check(box.project!.settings.resolvedProductDemoAudio.voiceovers!.isEmpty, "remove only unlinks the selected narration")
        let app = FakeApp(box: box); app.projects = [box.project!]; app.openID = box.project!.id
        var appContext = context; appContext.app = app
        let added = try await tool.run(arguments: ["action": "add", "path": root.appendingPathComponent("new-voice.wav").path,
            "title": "New narration", "timeline_start": 1, "source_in": 0.5, "source_out": 2.5],
            context: appContext, progress: { _ in })
        check(app.imported.count == 1 && added.data?["voiceovers"]?[0]?["title"] == "New narration"
              && box.project!.settings.resolvedProductDemoAudio.voiceovers!.count == 1,
              "adding narration delegates file ownership to the app then applies the mix atomically")
        let report = AIProjectReport.audioData(source.settings, tracks: [])
        check(report["voiceovers"]?[0]?["source_duration"] == 6 && report["source_volume"] == 1,
              "project report exposes source handles and mix state to Codex")
    }
}
