@preconcurrency import AVFoundation
import FocusStudioCore
import Foundation

@MainActor
enum VoiceoverRegression {
    static func run() async throws {
        try await recordingLifecycle()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FocusStudio-Voiceover-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("Narration.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for index in 0..<48_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) / 48_000 * 2 * .pi * 440) * 0.2) }
        var file: AVAudioFile? = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        try file!.write(from: buffer)
        file = nil // Finalize the WAV header before the import opens it.
        let store = ProjectStore(projectsDirectory: directory.appendingPathComponent("Projects"))
        var original = RecordingProject(title: "Voiceover lifecycle", sourceVideoPath: "raw.mp4", duration: 4,
                                        sourceWidth: 640, sourceHeight: 360)
        // The lifecycle operations copy a source without decoding/re-encoding it.
        try await store.save(original)
        let raw = try await store.resolvedVideoURL(for: original)
        try Data("immutable source".utf8).write(to: raw)
        original.sourceVideoPath = raw.path
        var voice = try await store.importVoiceover(from: audioURL, for: original)
        precondition(abs(voice.sourceDuration - 1) < 0.01 && voice.filePath != audioURL.path)
        voice.timelineStart = 1; voice.sourceStart = 0.1; voice.sourceEnd = 0.9
        original.settings.productDemoAudio = .init(voiceovers: [voice], voiceoverDuckingLevel: 0.25)
        try await store.save(original)
        let loaded = try await store.loadProjects().first { $0.id == original.id }!
        precondition(loaded.settings.resolvedProductDemoAudio.voiceovers == [voice], "Narration round-trips through relative project paths")
        let storedData = try Data(contentsOf: raw.deletingLastPathComponent().appendingPathComponent("project.json"))
        let stored = try JSONSerialization.jsonObject(with: storedData) as! [String: Any]
        let settings = stored["settings"] as! [String: Any]
        let audio = settings["productDemoAudio"] as! [String: Any]
        let path = (audio["voiceovers"] as! [[String: Any]])[0]["filePath"] as! String
        precondition(!path.hasPrefix("/"), "Stored narration is portable and project-owned")

        let working = try await store.createVideoEditingCopy(from: loaded, edited: loaded, title: "Voiceover working copy")
        let copied = working.settings.resolvedProductDemoAudio.voiceovers![0]
        precondition(copied.id == voice.id && copied.filePath != voice.filePath
            && FileManager.default.fileExists(atPath: copied.filePath), "Working copies own their narration")
        let sourceBytes = try Data(contentsOf: URL(fileURLWithPath: voice.filePath))
        let copiedBytes = try Data(contentsOf: URL(fileURLWithPath: copied.filePath))
        precondition(copiedBytes == sourceBytes, "Narration copies do not re-encode or reduce quality")
        let model = StudioModel(store: store)
        model.open(working)
        var changed = working
        changed.settings.productDemoAudio!.voiceovers![0].volume = 0.3
        precondition(model.updateActiveProject(changed), "Manual audio edits publish through the editor")
        let undone = try await model.undoVideoEdit(projectID: working.id)
        precondition(undone.settings.resolvedProductDemoAudio.voiceovers![0].volume == 1,
                     "Undo restores narration settings")
        let redone = try await model.redoVideoEdit(projectID: working.id)
        precondition(redone.settings.resolvedProductDemoAudio.voiceovers![0].volume == 0.3,
                     "Redo reapplies narration settings")
        model.closeEditor(); await model.flushProjectEdits()
        print("PASS: voiceover import, relative persistence, self-contained copy and undo/redo")
    }

    private static func recordingLifecycle() async throws {
        let denied = MicrophoneAccessController(status: { .denied }, request: { fatalError("Denied permission must not re-prompt") })
        var starts = 0
        let recorder = VoiceoverRecorder { url in
            starts += 1; try Data("take".utf8).write(to: url); return FakeRecorder()
        }
        await recorder.start(access: denied, maximumDuration: 8) { _ in fatalError("Denied microphone must not complete") }
        precondition(starts == 0 && recorder.phase == .idle && recorder.error != nil)

        let pending = MicrophoneAccessController(status: { .notDetermined }, request: {
            try? await Task.sleep(for: .milliseconds(80)); return true
        })
        let task = Task { await recorder.start(access: pending, maximumDuration: 8) { _ in fatalError("Cancelled wait must not record") } }
        while pending.waitingCount == 0 { await Task.yield() }
        recorder.cancel(); task.cancel(); await task.value
        try await Task.sleep(for: .milliseconds(100))
        precondition(starts == 0 && recorder.phase == .idle, "A late OS permission answer cannot start a cancelled narration")

        let authorized = MicrophoneAccessController(status: { .authorized }, request: { fatalError("Existing permission must be reused") })
        let engine = FakeRecorder()
        var destination: URL?
        let active = VoiceoverRecorder { url in
            destination = url; try Data("take".utf8).write(to: url); return engine
        }
        var completions = 0
        await active.start(access: authorized, maximumDuration: 12) { url in
            completions += 1; precondition(url == destination)
        }
        precondition(active.phase == .recording && engine.limit == 12)
        engine.currentTime = 1.2; active.refreshMeters()
        precondition(active.elapsed == 1.2 && abs(active.level - 0.8) < 0.001,
                     "The narration meter reflects measured decibels and elapsed recording time")
        active.finish(); active.finish()
        precondition(completions == 1 && engine.stops == 1 && active.phase == .idle,
                     "Stop publishes exactly one finished take")
        if let destination { try? FileManager.default.removeItem(at: destination) }

        await active.start(access: authorized, maximumDuration: 12) { _ in fatalError("Cancelled take must not publish") }
        active.cancel()
        precondition(active.phase == .idle && !FileManager.default.fileExists(atPath: destination!.path),
                     "Cancel immediately closes the microphone and removes the temporary take")
        print("PASS: voiceover permission denial/cancellation, recording meter and one-shot finish")
    }

    private final class FakeRecorder: VoiceoverRecordingEngine {
        var isRecording = false
        var currentTime = 0.0
        var limit = 0.0
        var stops = 0
        func record(forDuration: TimeInterval) -> Bool { limit = forDuration; isRecording = true; return true }
        func stop() { stops += 1; isRecording = false }
        func updateMeters() {}
        func averagePower(forChannel: Int) -> Float { -12 }
    }
}
