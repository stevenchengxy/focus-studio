@preconcurrency import AVFoundation
import AudioToolbox
import FocusStudioCore
import Foundation

enum VoiceoverValidation {
    static func run(sourceURL: URL, outputDirectory: URL) async throws {
        let voiceURL = outputDirectory.appendingPathComponent("voiceover-source.wav")
        let musicURL = outputDirectory.appendingPathComponent("music-source.wav")
        try writeTone(to: voiceURL, duration: 5) { $0 < 1 ? 330 : 880 }
        try writeTone(to: musicURL, duration: 1) { _ in 220 }
        var project = RecordingProject(title: "Voiceover audio validation", sourceVideoPath: sourceURL.path,
                                       duration: 8, sourceWidth: 960, sourceHeight: 540)
        project.settings.exportWidth = 1280; project.settings.frameRate = 24
        let voice = VoiceoverClip(title: "Narration", filePath: voiceURL.path, sourceDuration: 5,
                                 sourceStart: 1, sourceEnd: 3, timelineStart: 2, volume: 0.7, fadeIn: 0.4, fadeOut: 0.4)
        project.settings.productDemoAudio = .init(sourceAudioVolume: 0, backgroundMusicPath: musicURL.path,
            backgroundMusicVolume: 0.5, backgroundMusicFadeIn: 0, backgroundMusicFadeOut: 0,
            voiceovers: [voice], voiceoverDuckingLevel: 0.25)
        let prepared = try await ProjectVideoRenderer.prepare(project: project)
        let preview = try await readAudio(asset: prepared.asset, mix: prepared.audioMix)
        let output = outputDirectory.appendingPathComponent("voiceover-mix.mp4")
        let export = try await ProjectVideoRenderer.export(project: project, to: output)
        let rendered = try await readAudio(asset: AVURLAsset(url: output), mix: nil)
        try require(export.includesAudio, "Export must report the mixed audio track")
        var report: [String: Double] = [:]
        for (label, samples) in [("preview", preview), ("export", rendered)] {
            let bg = amplitude(samples, start: 1, length: 0.2, frequency: 220)
            let duck = amplitude(samples, start: 2.6, length: 0.2, frequency: 220)
            let restored = amplitude(samples, start: 4.6, length: 0.2, frequency: 220)
            let speech = amplitude(samples, start: 2.6, length: 0.2, frequency: 880)
            let early = amplitude(samples, start: 2.04, length: 0.08, frequency: 880)
            let late = amplitude(samples, start: 3.86, length: 0.08, frequency: 880)
            let before = amplitude(samples, start: 1.4, length: 0.2, frequency: 880)
            let after = amplitude(samples, start: 4.8, length: 0.2, frequency: 880)
            let wrongSource = amplitude(samples, start: 2.6, length: 0.2, frequency: 330)
            try require(abs(bg - 0.1) < 0.012, "\(label): music gain measured from real PCM")
            try require(abs(duck / bg - 0.25) < 0.06, "\(label): music ducks to 25% during speech")
            try require(abs(restored / bg - 1) < 0.06, "\(label): music recovers after speech")
            try require(abs(speech - 0.14) < 0.018, "\(label): narration gain and source excerpt are audible")
            try require(early < speech * 0.4 && late < speech * 0.4, "\(label): both narration fades attenuate")
            try require(before < 0.002 && after < 0.002, "\(label): narration offset/end never loops")
            try require(wrongSource < 0.002, "\(label): source in point excludes the first source tone")
            report[label + "_music_amplitude"] = bg; report[label + "_duck_ratio"] = duck / bg
            report[label + "_speech_amplitude"] = speech
            report[label + "_fade_in_ratio"] = early / speech; report[label + "_fade_out_ratio"] = late / speech
        }
        try require(abs(report["preview_speech_amplitude"]! - report["export_speech_amplitude"]!) < 0.008,
                    "Preview/export voice gain agrees after AAC encoding")
        // Disabling a clip removes speech and ducking; a missing enabled asset
        // must fail explicitly rather than silently ship a speechless export.
        project.settings.productDemoAudio!.voiceovers![0].isEnabled = false
        let muted = try await ProjectVideoRenderer.prepare(project: project)
        let mutedSamples = try await readAudio(asset: muted.asset, mix: muted.audioMix)
        try require(amplitude(mutedSamples, start: 2.6, length: 0.2, frequency: 880) < 0.002,
                    "Disabled narration is silent")
        try require(abs(amplitude(mutedSamples, start: 2.6, length: 0.2, frequency: 220) - 0.1) < 0.01,
                    "Disabled narration does not duck music")
        project.settings.productDemoAudio!.voiceovers![0].isEnabled = true
        project.settings.productDemoAudio!.voiceovers![0].filePath = outputDirectory.appendingPathComponent("missing.wav").path
        do {
            _ = try await ProjectVideoRenderer.prepare(project: project)
            throw Failure("Missing voiceover unexpectedly rendered")
        } catch is Failure { throw Failure("Missing voiceover unexpectedly rendered") }
        catch { /* Expected renderer error, no silent omission. */ }
        let data = try JSONSerialization.data(withJSONObject: ["status": "PASS", "measurements": report], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputDirectory.appendingPathComponent("voiceover-validation.json"))
        print(String(data: data, encoding: .utf8)!)
    }

    private static func writeTone(to url: URL, duration: Double, frequency: (Double) -> Double) throws {
        let rate = 48_000, count = Int(duration * Double(rate))
        var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let time = Double(index) / Double(rate)
            var value = Int16((sin(2 * .pi * frequency(time) * time) * 0.2 * Double(Int16.max)).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func str(_ text: String) { wav.append(contentsOf: text.utf8) }
        func int<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        str("RIFF"); int(UInt32(36 + pcm.count)); str("WAVEfmt "); int(UInt32(16)); int(UInt16(1)); int(UInt16(1))
        int(UInt32(rate)); int(UInt32(rate * 2)); int(UInt16(2)); int(UInt16(16)); str("data"); int(UInt32(pcm.count))
        wav.append(pcm); try wav.write(to: url)
    }

    private static func readAudio(asset: AVAsset, mix: AVAudioMix?) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        output.audioMix = mix
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure("Audio reader did not start") }
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let size = CMBlockBufferGetDataLength(block), count = size / MemoryLayout<Float>.size
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
            guard status == noErr else { throw Failure("PCM copy failed") }
            samples.append(contentsOf: chunk)
        }
        guard reader.status == .completed else { throw reader.error ?? Failure("Audio reader failed") }
        return samples
    }

    private static func amplitude(_ samples: [Float], start: Double, length: Double, frequency: Double) -> Double {
        let lower = Int(start * 48_000), upper = min(samples.count, Int((start + length) * 48_000))
        guard upper > lower else { return 0 }
        var sine = 0.0, cosine = 0.0
        for index in lower..<upper {
            let phase = 2 * Double.pi * frequency * Double(index) / 48_000
            sine += Double(samples[index]) * sin(phase); cosine += Double(samples[index]) * cos(phase)
        }
        return 2 * hypot(sine, cosine) / Double(upper - lower)
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
    private struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}
