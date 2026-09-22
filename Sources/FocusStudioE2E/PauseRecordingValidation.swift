@preconcurrency import AVFoundation
import AudioToolbox
import CoreGraphics
import FocusStudioCapture
import Foundation

enum PauseRecordingValidation {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run(sourceURL: URL, outputDirectory: URL) async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure(description: "Pause recording: " + message) }
        }
        let destination = outputDirectory.appendingPathComponent("focus-studio-pause-resume.mp4")
        // This exact E2E output is ours; source fixtures are never overwritten.
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        let duration = try await RecordingSegmentAssembler.assemble([
            .init(url: sourceURL, duration: 1.25),
            .init(url: sourceURL, duration: 0),
            .init(url: sourceURL, duration: 0.75)
        ], to: destination)
        try check(abs(duration - 2) < 0.001, "active intervals must join to exactly 2s regardless of paused wall time")
        let original = AVURLAsset(url: sourceURL)
        let joined = AVURLAsset(url: destination)
        let video = try await joined.loadTracks(withMediaType: .video)
        let audio = try await joined.loadTracks(withMediaType: .audio)
        try check(video.count == 1 && audio.count == 1, "the joined recording must preserve video and sound")
        let actualDuration = try await joined.load(.duration).seconds
        try check(abs(actualDuration - 2) <= 1.0 / 24, "joined media must contain no paused frames or silence")
        let sourceFrames = AVAssetImageGenerator(asset: original)
        let outputFrames = AVAssetImageGenerator(asset: joined)
        for generator in [sourceFrames, outputFrames] {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        var differences: [Double] = []
        for (outputTime, sourceTime) in [(0.5, 0.5), (1.25, 0.0), (1.5, 0.25), (1.875, 0.625)] {
            let expected = try await sourceFrames.image(at: CMTime(seconds: sourceTime, preferredTimescale: 600)).image
            let actual = try await outputFrames.image(at: CMTime(seconds: outputTime, preferredTimescale: 600)).image
            let delta = difference(expected, actual)
            try check(delta < 1, "resumed video did not begin at its first active frame (\(outputTime)s delta \(delta))")
            differences.append(delta)
        }
        let reader = try AVAssetReader(asset: joined)
        let pcm = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(pcm)
        try check(reader.startReading(), "joined audio must decode")
        var audioEnd = 0.0, maximumGap = 0.0, audioBuffers = 0
        while let sample = pcm.copyNextSampleBuffer() {
            let start = sample.presentationTimeStamp.seconds
            maximumGap = max(maximumGap, start - audioEnd)
            audioEnd = max(audioEnd, start + sample.duration.seconds)
            audioBuffers += 1
        }
        try check(reader.status == .completed && audioBuffers > 10, "joined audio must remain playable through the splice")
        try check(maximumGap < 0.03 && abs(audioEnd - 2) < 0.03, "audio must not acquire a pause gap or drift from video")
        let multipleAudioCount = try await validateMultipleAudioTracks(source: original, outputDirectory: outputDirectory)
        try check(multipleAudioCount == 2, "system audio and microphone tracks must both survive pause joins")
        // Existing destinations and invalid/empty input must fail without replacing data.
        let before = try Data(contentsOf: destination)
        do {
            _ = try await RecordingSegmentAssembler.assemble([.init(url: sourceURL, duration: 1)], to: destination)
            throw Failure(description: "Pause assembler overwrote an existing output")
        } catch let failure as Failure { throw failure } catch {}
        let after = try Data(contentsOf: destination)
        try check(before == after, "failed assembly must preserve an existing destination")
        let empty = outputDirectory.appendingPathComponent("pause-empty-\(UUID()).mp4")
        do {
            _ = try await RecordingSegmentAssembler.assemble([], to: empty)
            throw Failure(description: "Pause assembler accepted no active frames")
        } catch let failure as Failure { throw failure } catch {}
        try check(!FileManager.default.fileExists(atPath: empty.path), "zero-frame finish must not leave an invalid movie")
        try await validateTransitionOrdering()
        let report: [String: Any] = [
            "status": "PASS", "fixtureOnly": true, "activeDuration": duration,
            "assetDuration": actualDuration, "videoFrameDifferences": differences,
            "maximumAudioGap": maximumGap, "audioEnd": audioEnd, "audioBufferCount": audioBuffers,
            "multipleAudioTrackCount": multipleAudioCount,
            "outputPath": destination.path
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDirectory.appendingPathComponent("pause-resume-validation.json"), options: .atomic)
        print("PauseRecordingValidation: PASS (true segment splice, first resumed frame, audio continuity, zero-length intervals, non-destructive failure, serialized transitions; synthetic media only)")
    }

    private static func validateMultipleAudioTracks(source: AVAsset, outputDirectory: URL) async throws -> Int {
        let fixtureURL = outputDirectory.appendingPathComponent("pause-two-audio-fixture-\(UUID()).mp4")
        let outputURL = outputDirectory.appendingPathComponent("pause-two-audio-result-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
        guard let video = try await source.loadTracks(withMediaType: .video).first,
              let audio = try await source.loadTracks(withMediaType: .audio).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure(description: "Missing two-audio fixture tracks")
        }
        try videoTrack.insertTimeRange(range, of: video, at: .zero)
        for _ in 0..<2 {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw Failure(description: "Cannot create second audio fixture track")
            }
            try track.insertTimeRange(range, of: audio, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure(description: "Cannot export two-audio fixture")
        }
        try await export.export(to: fixtureURL, as: .mp4)
        _ = try await RecordingSegmentAssembler.assemble([
            .init(url: fixtureURL, duration: 0.5), .init(url: fixtureURL, duration: 0.5)
        ], to: outputURL)
        let tracks = try await AVURLAsset(url: outputURL).loadTracks(withMediaType: .audio)
        for track in tracks {
            let seconds = try await track.load(.timeRange).duration.seconds
            guard abs(seconds - 1) < 0.03 else { throw Failure(description: "An audio track drifted across pause") }
        }
        return tracks.count
    }

    @MainActor
    private static func validateTransitionOrdering() async throws {
        let gate = RecordingTransitionGate()
        var order: [Int] = []
        await gate.acquire()
        let pausing = Task { @MainActor in
            await gate.acquire()
            order.append(1)
            await Task.yield()
            order.append(2)
            gate.release()
        }
        await Task.yield()
        let finishing = Task { @MainActor in
            await gate.acquire()
            order.append(3)
            gate.release()
        }
        await Task.yield()
        gate.release()
        await pausing.value
        await finishing.value
        guard order == [1, 2, 3] else { throw Failure(description: "Pause/finish transitions interleaved: \(order)") }
        let engine = CaptureEngine()
        do { try await engine.pauseRecording(); throw Failure(description: "idle pause unexpectedly accepted") }
        catch let failure as Failure { throw failure } catch {}
        do { try await engine.resumeRecording(); throw Failure(description: "idle resume unexpectedly accepted") }
        catch let failure as Failure { throw failure } catch {}
        guard !engine.isRecording, !engine.isPaused, !engine.isChangingPauseState else {
            throw Failure(description: "invalid transitions left recording controls stuck")
        }
    }

    private static func difference(_ lhs: CGImage, _ rhs: CGImage) -> Double {
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 96 * 54 * 4)
            bytes.withUnsafeMutableBytes {
                let context = CGContext(data: $0.baseAddress, width: 96, height: 54, bitsPerComponent: 8, bytesPerRow: 96 * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 54))
            }
            return bytes
        }
        let a = pixels(lhs), b = pixels(rhs)
        return zip(a, b).reduce(0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(a.count)
    }
}
