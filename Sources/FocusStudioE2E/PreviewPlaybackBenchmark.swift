@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import FocusStudioCore
import Foundation
import QuartzCore

/// Exercises real AVPlayer composition delivery on the playback clock. This is
/// a headless compositor benchmark, not a measurement of SwiftUI display FPS.
enum PreviewPlaybackBenchmark {
    @MainActor static func run(projectPath: String, scale: Double, outputDirectory: URL) async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadataURL = URL(fileURLWithPath: projectPath)
        var project = try decoder.decode(RecordingProject.self, from: Data(contentsOf: metadataURL))
        if !(project.sourceVideoPath as NSString).isAbsolutePath {
            project.sourceVideoPath = metadataURL.deletingLastPathComponent().appendingPathComponent(project.sourceVideoPath).path
        }
        let prepareStarted = CACurrentMediaTime()
        let prepared = try await ProjectVideoRenderer.prepare(project: project)
        let prepareMilliseconds = (CACurrentMediaTime() - prepareStarted) * 1000
        let item = prepared.makePlayerItem()
        let composition = prepared.videoComposition.mutableCopy() as! AVMutableVideoComposition
        composition.renderScale = Float(min(1, max(0.1, scale)))
        item.videoComposition = composition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let readyStarted = CACurrentMediaTime()
        let readyDeadline = readyStarted + 15
        while item.status == .unknown && CACurrentMediaTime() < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard item.status == .readyToPlay else { throw item.error ?? URLError(.cannotDecodeContentData) }
        let readyMilliseconds = (CACurrentMediaTime() - readyStarted) * 1000
        await player.seek(to: CMTime(seconds: 0, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.playImmediately(atRate: 1)
        let started = CACurrentMediaTime()
        let frameBudget = prepared.videoComposition.frameDuration.seconds
        var deliveredTimes: [Double] = [], deliveryGaps: [Double] = [], lateness: [Double] = []
        var lastWallTime: Double?, lastPTS = -Double.infinity
        var firstFrameMilliseconds: Double?
        var width = 0, height = 0, missed = 0
        let runSeconds = min(9, project.duration - 0.15)
        while CACurrentMediaTime() - started < runSeconds + 4 && player.currentTime().seconds < runSeconds {
            let now = CACurrentMediaTime()
            let requested = output.itemTime(forHostTime: now)
            if output.hasNewPixelBuffer(forItemTime: requested) {
                var displayed = CMTime.invalid
                if let buffer = output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &displayed) {
                    if firstFrameMilliseconds == nil { firstFrameMilliseconds = (now - started) * 1000 }
                    let seconds = displayed.seconds
                    width = CVPixelBufferGetWidth(buffer); height = CVPixelBufferGetHeight(buffer)
                    if seconds.isFinite && seconds > lastPTS && seconds >= 1 {
                        if lastPTS >= 1 {
                            missed += max(0, Int(((seconds - lastPTS) / frameBudget).rounded()) - 1)
                        }
                        if let lastWallTime { deliveryGaps.append((now - lastWallTime) * 1000) }
                        deliveredTimes.append(seconds)
                        lateness.append(max(0, requested.seconds - seconds) * 1000)
                        lastWallTime = now
                    }
                    if seconds.isFinite { lastPTS = seconds }
                }
            }
            try await Task.sleep(for: .milliseconds(4))
        }
        guard deliveredTimes.count > 10 else { throw URLError(.cannotDecodeContentData) }
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        let report: [String: Any] = [
            "scope": "AVPlayerItemVideoOutput wall-clock delivery, 4ms polling, first playback second excluded; not SwiftUI display FPS",
            "projectId": project.id.uuidString, "renderScale": composition.renderScale,
            "compositionWidth": composition.renderSize.width, "compositionHeight": composition.renderSize.height,
            "deliveredWidth": width, "deliveredHeight": height, "frameBudgetMilliseconds": frameBudget * 1000,
            "deliveredFrames": deliveredTimes.count, "missingFrameIntervals": missed,
            "deliveryGapMedianMilliseconds": percentile(deliveryGaps, 0.5),
            "deliveryGapP95Milliseconds": percentile(deliveryGaps, 0.95),
            "latenessP95Milliseconds": percentile(lateness, 0.95),
            "elapsedSeconds": CACurrentMediaTime() - started,
            "playbackSeconds": player.currentTime().seconds,
            "prepareMilliseconds": prepareMilliseconds, "readyMilliseconds": readyMilliseconds,
            "firstFrameAfterPlayMilliseconds": firstFrameMilliseconds ?? -1
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputDirectory.appendingPathComponent("playback-benchmark.json"))
        print(String(decoding: data, as: UTF8.self))
    }
}
