@preconcurrency import AVFoundation
import Foundation

public enum DemoCutExporter {
    /// Re-encodes the selected raw frames once, leaving zoom/cursor rendering
    /// editable. Source audio follows the same cuts; orientation is preserved.
    public static func export(sourceURL: URL, edit: DemoTimelineEdit, to outputURL: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path), sourceURL.standardizedFileURL != outputURL.standardizedFileURL else {
            throw DemoEditError.invalidMedia("The edited movie must use a new file; no existing video was changed.")
        }
        let asset = AVURLAsset(url: sourceURL)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw DemoEditError.invalidMedia("The source has no readable video track.") }
        let sourceRange = try await video.load(.timeRange)
        guard sourceRange.duration.seconds + 0.001 >= edit.sourceDuration else { throw DemoEditError.invalidMedia("The source video is shorter than its project timeline.") }
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw DemoEditError.invalidMedia("Could not create a video edit track.") }
        target.preferredTransform = try await video.load(.preferredTransform)
        let audioSources = try await asset.loadTracks(withMediaType: .audio)
        var audioTracks: [(AVAssetTrack, AVMutableCompositionTrack, CMTimeRange)] = []
        for audio in audioSources {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw DemoEditError.invalidMedia("Could not preserve source audio.") }
            audioTracks.append((audio, track, try await audio.load(.timeRange)))
        }
        var offset = CMTime.zero
        for range in edit.ranges {
            try Task.checkCancellation()
            let sourceStart = sourceRange.start + CMTime(seconds: range.start, preferredTimescale: 60_000)
            let duration = CMTime(seconds: range.duration, preferredTimescale: 60_000)
            let selected = CMTimeRange(start: sourceStart, duration: duration)
            try target.insertTimeRange(selected, of: video, at: offset)
            for (source, audio, available) in audioTracks {
                let intersection = CMTimeRangeGetIntersection(selected, otherRange: available)
                if intersection.duration.seconds > 0 {
                    try audio.insertTimeRange(intersection, of: source, at: offset + intersection.start - selected.start)
                }
            }
            offset = offset + duration
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw DemoEditError.invalidMedia("Could not create the edited movie export.") }
        let temporary = outputURL.deletingLastPathComponent().appendingPathComponent(".cut-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await ProjectVideoRenderer.runExportSession(session, to: temporary, as: .mov, progress: progress)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: outputURL)
        progress?(1)
    }
}
