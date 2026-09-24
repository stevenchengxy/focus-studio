import AVFoundation
import Foundation

public struct RecordedMediaSegment: Sendable {
    public let url: URL
    public let duration: TimeInterval
    public init(url: URL, duration: TimeInterval) { self.url = url; self.duration = duration }
}

/// Joins only active intervals. Passthrough preserves the captured video codec
/// and all recorded audio tracks; no frames or silence from a pause are inserted.
public enum RecordingSegmentAssembler {
    public static func playableDuration(at url: URL, requested: TimeInterval) async throws -> TimeInterval {
        guard requested.isFinite, requested >= 0 else { throw CaptureEngineError.recordingFailed("Invalid recording segment duration.") }
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureEngineError.recordingFailed("A recording segment contains no video frames.")
        }
        let range = try await video.load(.timeRange)
        let seconds = CMTimeGetSeconds(range.duration)
        guard seconds.isFinite, seconds > 0 else {
            throw CaptureEngineError.recordingFailed("A recording segment contains no video frames.")
        }
        return min(requested, seconds)
    }

    @discardableResult
    public static func assemble(_ segments: [RecordedMediaSegment], to outputURL: URL) async throws -> TimeInterval {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw CaptureEngineError.recordingFailed("The assembled recording destination already exists.")
        }
        let composition = AVMutableComposition()
        guard let videoTarget = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CaptureEngineError.recordingFailed("Could not create the paused recording composition.")
        }
        var audioTargets: [AVMutableCompositionTrack] = []
        var cursor = CMTime.zero
        for segment in segments where segment.duration.isFinite && segment.duration > 0 {
            let asset = AVURLAsset(url: segment.url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw CaptureEngineError.recordingFailed("A recording segment contains no video frames.")
            }
            let videoRange = try await video.load(.timeRange)
            let length = CMTimeMinimum(videoRange.duration, CMTime(seconds: segment.duration, preferredTimescale: 60_000))
            guard length > .zero else { continue }
            let range = CMTimeRange(start: videoRange.start, duration: length)
            try videoTarget.insertTimeRange(range, of: video, at: cursor)
            if cursor == .zero { videoTarget.preferredTransform = try await video.load(.preferredTransform) }
            for (index, audio) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
                while audioTargets.count <= index {
                    guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw CaptureEngineError.recordingFailed("Could not preserve the recorded audio track.")
                    }
                    audioTargets.append(track)
                }
                let overlap = CMTimeRangeGetIntersection(range, otherRange: try await audio.load(.timeRange))
                if overlap.duration > .zero {
                    try audioTargets[index].insertTimeRange(overlap, of: audio, at: cursor + overlap.start - range.start)
                }
            }
            cursor = cursor + length
        }
        guard cursor > .zero, let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureEngineError.recordingFailed("The recording contains no active video frames.")
        }
        do {
            try await export.export(to: outputURL, as: .mp4)
        } catch {
            // The destination was absent before this export and is ours alone.
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return CMTimeGetSeconds(cursor)
    }
}
