import AppKit
@preconcurrency import AVFoundation
import CoreImage
import Foundation

/// The deterministic canvas geometry used by both preview playback and export.
public struct RenderGeometry: Hashable, Sendable {
    public let outputSize: CGSize
    public let screenFrame: CGRect

    public init(outputSize: CGSize, screenFrame: CGRect) {
        self.outputSize = outputSize
        self.screenFrame = screenFrame
    }
}

/// Metadata describing a completed export.
public struct VideoExportResult: Hashable, Sendable {
    public let outputURL: URL
    public let duration: Double
    public let width: Int
    public let height: Int
    public let frameRate: Int
    public let includesAudio: Bool

    public init(
        outputURL: URL,
        duration: Double,
        width: Int,
        height: Int,
        frameRate: Int,
        includesAudio: Bool
    ) {
        self.outputURL = outputURL
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.includesAudio = includesAudio
    }
}

/// A prepared asset which can be handed directly to `AVPlayer` or to an export session.
///
/// Holding the composition and video composition together is intentional: the same frame
/// renderer is therefore used for an editor preview and for the final MP4.
public final class PreparedProjectVideo: @unchecked Sendable {
    public let asset: AVAsset
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix?
    public let duration: Double
    public let geometry: RenderGeometry

    fileprivate let includesAudio: Bool
    fileprivate let frameRate: Int

    fileprivate init(
        asset: AVAsset,
        videoComposition: AVVideoComposition,
        audioMix: AVAudioMix?,
        duration: Double,
        geometry: RenderGeometry,
        includesAudio: Bool,
        frameRate: Int
    ) {
        self.asset = asset
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.duration = duration
        self.geometry = geometry
        self.includesAudio = includesAudio
        self.frameRate = frameRate
    }

    public func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

public enum ProjectVideoRenderer {
    /// Computes an even-pixel output canvas and the aspect-fit source frame inside its padding.
    public static func geometry(for project: RecordingProject) -> RenderGeometry {
        let fullSourceSize = CGSize(
            width: max(1, project.sourceWidth),
            height: max(1, project.sourceHeight)
        )
        let cropInsets = project.settings.sourceCropInsets?.sanitized ?? SourceCropInsets()
        let visibleSourceRect = cropInsets.sourceRect(in: fullSourceSize)
        let sourceWidth = max(1, visibleSourceRect.width)
        let sourceHeight = max(1, visibleSourceRect.height)
        let sourceRatio = Double(sourceWidth) / Double(sourceHeight)
        let canvasRatio = project.settings.aspectRatio.ratio ?? sourceRatio

        let width = evenPixelCount(project.settings.exportWidth, minimum: 320, maximum: 7_680)
        let rawHeight = Int((Double(width) / max(0.01, canvasRatio)).rounded())
        let height = evenPixelCount(rawHeight, minimum: 180, maximum: 7_680)
        let outputSize = CGSize(width: width, height: height)

        let requestedPadding = project.settings.padding.isFinite ? project.settings.padding : 0
        let maxPadding = max(0, min(outputSize.width, outputSize.height) / 2 - 2)
        let padding = requestedPadding.clamped(to: 0...maxPadding)
        let available = CGRect(
            x: padding,
            y: padding,
            width: max(1, outputSize.width - padding * 2),
            height: max(1, outputSize.height - padding * 2)
        )

        let availableRatio = available.width / available.height
        let fittedSize: CGSize
        if sourceRatio > availableRatio {
            fittedSize = CGSize(width: available.width, height: available.width / sourceRatio)
        } else {
            fittedSize = CGSize(width: available.height * sourceRatio, height: available.height)
        }
        let fittedFrame = CGRect(
            x: (outputSize.width - fittedSize.width) / 2,
            y: (outputSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )

        return RenderGeometry(outputSize: outputSize, screenFrame: fittedFrame)
    }

    /// Builds the common composition used by preview playback and final export.
    public static func prepare(project: RecordingProject) async throws -> PreparedProjectVideo {
        let sourceURL = URL(fileURLWithPath: project.sourceVideoPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ProjectRenderError.sourceDoesNotExist(sourceURL)
        }

        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceDuration = try await sourceAsset.load(.duration)
        let sourceDurationSeconds = sourceDuration.seconds
        let sourceVideoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = sourceVideoTracks.first else {
            throw ProjectRenderError.sourceHasNoVideoTrack
        }
        let sourceVideoTimeRange = try await sourceVideoTrack.load(.timeRange)
        let sourceVideoDuration = sourceVideoTimeRange.duration.seconds
        guard sourceDurationSeconds.isFinite, sourceDurationSeconds > 0,
              sourceVideoDuration.isFinite, sourceVideoDuration > 0 else {
            throw ProjectRenderError.invalidSourceDuration
        }

        let requestedDuration = project.duration.isFinite && project.duration > 0
            ? project.duration
            : sourceVideoDuration
        let duration = min(requestedDuration, sourceDurationSeconds, sourceVideoDuration)
        let durationTime = CMTime(seconds: duration, preferredTimescale: 600)
        let sourceRange = CMTimeRange(start: sourceVideoTimeRange.start, duration: durationTime)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ProjectRenderError.couldNotCreateCompositionTrack(.video)
        }
        try videoTrack.insertTimeRange(sourceRange, of: sourceVideoTrack, at: .zero)
        videoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        var includesAudio = false
        var audioMixParameters: [AVAudioMixInputParameters] = []
        let audioSettings = project.settings.resolvedProductDemoAudio
        let sourceAudioVolume = sanitizedVolume(audioSettings.sourceAudioVolume)
        let sourceAudioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        for sourceAudioTrack in sourceAudioTracks {
            guard let audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            let sourceTimeRange = try await sourceAudioTrack.load(.timeRange)
            let intersection = CMTimeRangeGetIntersection(sourceTimeRange, otherRange: sourceRange)
            guard intersection.isValid, !intersection.isEmpty else {
                composition.removeTrack(audioTrack)
                continue
            }
            let insertionTime = CMTimeSubtract(intersection.start, sourceRange.start)
            try audioTrack.insertTimeRange(intersection, of: sourceAudioTrack, at: insertionTime)
            let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
            parameters.setVolume(sourceAudioVolume, at: .zero)
            audioMixParameters.append(parameters)
            includesAudio = true
        }

        if let backgroundMusicPath = normalizedPath(audioSettings.backgroundMusicPath) {
            let musicURL = try? resolveAudioURL(
                path: backgroundMusicPath,
                relativeTo: sourceURL.deletingLastPathComponent()
            )
            if let musicURL,
               let musicTrack = try? await insertLoopedAudio(
                    from: musicURL,
                    into: composition,
                    duration: durationTime
               ) {
                let parameters = musicMixParameters(
                    for: musicTrack,
                    duration: duration,
                    volume: sanitizedVolume(audioSettings.backgroundMusicVolume),
                    fadeIn: sanitizedDuration(audioSettings.backgroundMusicFadeIn),
                    fadeOut: sanitizedDuration(audioSettings.backgroundMusicFadeOut)
                )
                audioMixParameters.append(parameters)
                includesAudio = true
            }
        }

        let clickSoundTimes = project.clickEvents.map(\.time)
        if audioSettings.clickSoundEnabled,
           hasEffectTime(clickSoundTimes, duration: duration) {
            let effectURL = try? resolveSoundEffectURL(
                customPath: audioSettings.clickSoundPath,
                bundledName: "ui-click",
                relativeTo: sourceURL.deletingLastPathComponent()
            )
            if let effectURL,
               let parameters = try? await insertSoundEffects(
                    from: effectURL,
                    at: clickSoundTimes,
                    into: composition,
                    projectDuration: duration,
                    volume: sanitizedVolume(audioSettings.clickSoundVolume)
               ) {
                audioMixParameters.append(contentsOf: parameters)
                includesAudio = includesAudio || !parameters.isEmpty
            }
        }

        let zoomTimes = project.zoomSegments
            .filter(\.isEnabled)
            .flatMap { [$0.start, $0.end] }
        if audioSettings.zoomTransitionSoundEnabled,
           hasEffectTime(zoomTimes, duration: duration) {
            let effectURL = try? resolveSoundEffectURL(
                customPath: audioSettings.zoomTransitionSoundPath,
                bundledName: "zoom-whoosh",
                relativeTo: sourceURL.deletingLastPathComponent()
            )
            if let effectURL,
               let parameters = try? await insertSoundEffects(
                    from: effectURL,
                    at: zoomTimes,
                    into: composition,
                    projectDuration: duration,
                    volume: sanitizedVolume(audioSettings.zoomTransitionSoundVolume)
               ) {
                audioMixParameters.append(contentsOf: parameters)
                includesAudio = includesAudio || !parameters.isEmpty
            }
        }

        let audioMix: AVAudioMix?
        if audioMixParameters.isEmpty {
            audioMix = nil
        } else {
            let mutableAudioMix = AVMutableAudioMix()
            mutableAudioMix.inputParameters = audioMixParameters
            audioMix = mutableAudioMix
        }

        let geometry = geometry(for: project)
        let cursorGraphics = await MainActor.run {
            CursorGraphicSet(appearance: project.settings.resolvedCursorAppearance)
        }
        let frameRenderer = ProjectFrameRenderer(
            project: project,
            geometry: geometry,
            cursorGraphics: cursorGraphics
        )
        let videoComposition: AVMutableVideoComposition = try await withCheckedThrowingContinuation { continuation in
            AVMutableVideoComposition.videoComposition(
                with: composition,
                applyingCIFiltersWithHandler: { request in
                    let rendered = frameRenderer.render(
                        sourceImage: request.sourceImage,
                        seconds: request.compositionTime.seconds
                    )
                    request.finish(with: rendered, context: nil)
                },
                completionHandler: { composition, error in
                    if let composition {
                        continuation.resume(returning: composition)
                    } else {
                        continuation.resume(throwing: error ?? ProjectRenderError.couldNotCreateVideoComposition)
                    }
                }
            )
        }
        let frameRate = project.settings.frameRate.clamped(to: 1...120)
        videoComposition.renderSize = geometry.outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        videoComposition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid

        return PreparedProjectVideo(
            asset: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            duration: duration,
            geometry: geometry,
            includesAudio: includesAudio,
            frameRate: frameRate
        )
    }

    public static func makePlayerItem(project: RecordingProject) async throws -> AVPlayerItem {
        try await prepare(project: project).makePlayerItem()
    }

    /// Exports a self-contained MP4.
    ///
    /// Rendering happens into a sibling temporary file. An existing destination is replaced
    /// only after AVFoundation completes successfully, so a failed export never destroys it.
    /// `progress` receives the completed fraction (0...1, never decreasing) about twice a
    /// second and 1 once the file is in place. Cancelling the task stops AVFoundation,
    /// removes the partial file and throws `CancellationError` itself, not a render error.
    @discardableResult
    public static func export(
        project: RecordingProject,
        to outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> VideoExportResult {
        guard outputURL.pathExtension.lowercased() == "mp4" else {
            throw ProjectRenderError.outputMustBeMP4(outputURL)
        }
        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(
            ".\(outputURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).partial.mp4"
        )
        let prepared = try await prepare(project: project)
        guard let session = AVAssetExportSession(
            asset: prepared.asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ProjectRenderError.couldNotCreateExportSession
        }
        session.videoComposition = prepared.videoComposition
        session.audioMix = prepared.audioMix
        session.shouldOptimizeForNetworkUse = true

        do {
            try await runExportSession(session, to: temporaryURL, as: .mp4, progress: progress)
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            // AVFoundation throws CancellationError for a cancelled task; any
            // other error it reports after a cancel is the cancel as well.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ProjectRenderError.exportFailed(error.localizedDescription)
        }
        progress?(1)

        return VideoExportResult(
            outputURL: outputURL,
            duration: prepared.duration,
            width: Int(prepared.geometry.outputSize.width),
            height: Int(prepared.geometry.outputSize.height),
            frameRate: prepared.frameRate,
            includesAudio: prepared.includesAudio
        )
    }

    /// Runs `session` with the async export API of macOS 15, reporting the
    /// completed fraction from `states(updateInterval:)`. That sequence never
    /// ends on its own, so its observer is cancelled and awaited once the
    /// export returns: no report arrives after this function does. Cancelling
    /// the calling task makes AVFoundation stop and throw `CancellationError`,
    /// which propagates unchanged.
    public static func runExportSession(
        _ session: AVAssetExportSession,
        to url: URL,
        as fileType: AVFileType,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        guard let progress else {
            try await session.export(to: url, as: fileType)
            return
        }
        let states = session.states(updateInterval: 0.5)
        let observer = Task {
            var reported = 0.0
            for await state in states {
                guard !Task.isCancelled else { break }
                guard case let .exporting(exportProgress) = state else { continue }
                let fraction = min(1, max(0, exportProgress.fractionCompleted))
                if fraction > reported {
                    reported = fraction
                    progress(fraction)
                }
            }
        }
        do {
            try await session.export(to: url, as: fileType)
        } catch {
            observer.cancel()
            await observer.value
            throw error
        }
        observer.cancel()
        await observer.value
    }

    private static func insertLoopedAudio(
        from url: URL,
        into composition: AVMutableComposition,
        duration: CMTime
    ) async throws -> AVMutableCompositionTrack {
        let asset = AVURLAsset(url: url)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ProjectRenderError.audioAssetHasNoAudioTrack(url)
        }
        let sourceRange = try await sourceTrack.load(.timeRange)
        let sourceSeconds = sourceRange.duration.seconds
        guard sourceSeconds.isFinite, sourceSeconds >= 0.01 else {
            throw ProjectRenderError.invalidAudioDuration(url)
        }
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ProjectRenderError.couldNotCreateCompositionTrack(.audio)
        }

        let destinationSeconds = duration.seconds
        var insertionSeconds = 0.0
        do {
            while insertionSeconds < destinationSeconds - 0.000_1 {
                let clipSeconds = min(sourceSeconds, destinationSeconds - insertionSeconds)
                let clipRange = CMTimeRange(
                    start: sourceRange.start,
                    duration: CMTime(seconds: clipSeconds, preferredTimescale: 600)
                )
                try compositionTrack.insertTimeRange(
                    clipRange,
                    of: sourceTrack,
                    at: CMTime(seconds: insertionSeconds, preferredTimescale: 600)
                )
                insertionSeconds += clipSeconds
            }
        } catch {
            composition.removeTrack(compositionTrack)
            throw ProjectRenderError.couldNotInsertAudio(url, error.localizedDescription)
        }
        return compositionTrack
    }

    private static func musicMixParameters(
        for track: AVCompositionTrack,
        duration: Double,
        volume: Float,
        fadeIn: Double,
        fadeOut: Double
    ) -> AVMutableAudioMixInputParameters {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let total = max(0, duration)
        var effectiveFadeIn = min(fadeIn, total)
        var effectiveFadeOut = min(fadeOut, total)
        if effectiveFadeIn + effectiveFadeOut > total,
           effectiveFadeIn + effectiveFadeOut > 0 {
            let scale = total / (effectiveFadeIn + effectiveFadeOut)
            effectiveFadeIn *= scale
            effectiveFadeOut *= scale
        }

        if effectiveFadeIn > 0 {
            parameters.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: volume,
                timeRange: CMTimeRange(
                    start: .zero,
                    duration: CMTime(seconds: effectiveFadeIn, preferredTimescale: 600)
                )
            )
        } else {
            parameters.setVolume(volume, at: .zero)
        }

        let fadeOutStart = max(effectiveFadeIn, total - effectiveFadeOut)
        parameters.setVolume(
            volume,
            at: CMTime(seconds: fadeOutStart, preferredTimescale: 600)
        )
        if effectiveFadeOut > 0 {
            parameters.setVolumeRamp(
                fromStartVolume: volume,
                toEndVolume: 0,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: fadeOutStart, preferredTimescale: 600),
                    duration: CMTime(seconds: effectiveFadeOut, preferredTimescale: 600)
                )
            )
        }
        return parameters
    }

    private static func insertSoundEffects(
        from url: URL,
        at rawTimes: [Double],
        into composition: AVMutableComposition,
        projectDuration: Double,
        volume: Float
    ) async throws -> [AVAudioMixInputParameters] {
        let asset = AVURLAsset(url: url)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ProjectRenderError.audioAssetHasNoAudioTrack(url)
        }
        let sourceRange = try await sourceTrack.load(.timeRange)
        let sourceSeconds = sourceRange.duration.seconds
        guard sourceSeconds.isFinite, sourceSeconds >= 0.005 else {
            throw ProjectRenderError.invalidAudioDuration(url)
        }
        let times = deduplicatedEffectTimes(rawTimes, duration: projectDuration)
        guard !times.isEmpty else { return [] }

        var lanes: [AVMutableCompositionTrack] = []
        var availableAt: [Double] = []
        do {
            for eventTime in times {
                let clipSeconds = min(sourceSeconds, projectDuration - eventTime)
                guard clipSeconds >= 0.005 else { continue }
                let laneIndex: Int
                if let reusableIndex = availableAt.firstIndex(where: { $0 <= eventTime + 0.001 }) {
                    laneIndex = reusableIndex
                } else {
                    guard let lane = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else {
                        throw ProjectRenderError.couldNotCreateCompositionTrack(.audio)
                    }
                    lanes.append(lane)
                    availableAt.append(0)
                    laneIndex = lanes.count - 1
                }
                let clipRange = CMTimeRange(
                    start: sourceRange.start,
                    duration: CMTime(seconds: clipSeconds, preferredTimescale: 600)
                )
                try lanes[laneIndex].insertTimeRange(
                    clipRange,
                    of: sourceTrack,
                    at: CMTime(seconds: eventTime, preferredTimescale: 600)
                )
                availableAt[laneIndex] = eventTime + clipSeconds
            }
        } catch let renderError as ProjectRenderError {
            for lane in lanes { composition.removeTrack(lane) }
            throw renderError
        } catch {
            for lane in lanes { composition.removeTrack(lane) }
            throw ProjectRenderError.couldNotInsertAudio(url, error.localizedDescription)
        }

        return lanes.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(volume, at: .zero)
            return parameters
        }
    }

    private static func deduplicatedEffectTimes(_ rawTimes: [Double], duration: Double) -> [Double] {
        let sorted = rawTimes
            .filter { $0.isFinite && $0 >= 0 && $0 < duration }
            .sorted()
        var result: [Double] = []
        for time in sorted where result.last.map({ time - $0 >= 0.025 }) ?? true {
            result.append(time)
        }
        return result
    }

    private static func hasEffectTime(_ times: [Double], duration: Double) -> Bool {
        times.contains { $0.isFinite && $0 >= 0 && $0 < duration }
    }

    private static func resolveSoundEffectURL(
        customPath: String?,
        bundledName: String,
        relativeTo directory: URL
    ) throws -> URL {
        if let customPath = normalizedPath(customPath) {
            return try resolveAudioURL(path: customPath, relativeTo: directory)
        }
        for fileExtension in ["wav", "m4a", "mp3", "aiff"] {
            if let url = Bundle.main.url(
                forResource: bundledName,
                withExtension: fileExtension,
                subdirectory: "Audio"
            ) {
                return url
            }
            if let resourceURL = Bundle.main.resourceURL {
                let candidate = resourceURL
                    .appendingPathComponent("Audio", isDirectory: true)
                    .appendingPathComponent("\(bundledName).\(fileExtension)")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        throw ProjectRenderError.bundledSoundEffectDoesNotExist(bundledName)
    }

    private static func resolveAudioURL(path: String, relativeTo directory: URL) throws -> URL {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url: URL
        if let fileURL = URL(string: expandedPath), fileURL.isFileURL {
            url = fileURL
        } else if expandedPath.hasPrefix("/") {
            url = URL(fileURLWithPath: expandedPath)
        } else {
            url = directory.appendingPathComponent(expandedPath)
        }
        let standardizedURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
            throw ProjectRenderError.audioAssetDoesNotExist(standardizedURL)
        }
        return standardizedURL
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let value = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func sanitizedVolume(_ value: Double) -> Float {
        guard value.isFinite else { return 0 }
        return Float(value.clamped(to: 0...1))
    }

    private static func sanitizedDuration(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private static func evenPixelCount(_ value: Int, minimum: Int, maximum: Int) -> Int {
        let clamped = value.clamped(to: minimum...maximum)
        return clamped.isMultiple(of: 2) ? clamped : clamped - 1
    }
}

public enum ProjectRenderError: LocalizedError, Equatable {
    case sourceDoesNotExist(URL)
    case audioAssetDoesNotExist(URL)
    case bundledSoundEffectDoesNotExist(String)
    case audioAssetHasNoAudioTrack(URL)
    case invalidAudioDuration(URL)
    case couldNotInsertAudio(URL, String)
    case invalidSourceDuration
    case sourceHasNoVideoTrack
    case couldNotCreateCompositionTrack(AVMediaType)
    case outputMustBeMP4(URL)
    case couldNotCreateExportSession
    case couldNotCreateVideoComposition
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceDoesNotExist(let url):
            return "Source video does not exist at \(url.path)."
        case .audioAssetDoesNotExist(let url):
            return "Audio asset does not exist at \(url.path)."
        case .bundledSoundEffectDoesNotExist(let name):
            return "The bundled \(name) sound effect could not be found."
        case .audioAssetHasNoAudioTrack(let url):
            return "The audio asset at \(url.path) does not contain an audio track."
        case .invalidAudioDuration(let url):
            return "The audio asset at \(url.path) has no finite, positive duration."
        case .couldNotInsertAudio(let url, let message):
            return "Could not add audio from \(url.lastPathComponent): \(message)"
        case .invalidSourceDuration:
            return "The source video has no finite, positive duration."
        case .sourceHasNoVideoTrack:
            return "The source asset does not contain a video track."
        case .couldNotCreateCompositionTrack(let mediaType):
            return "Could not create the \(mediaType.rawValue) composition track."
        case .outputMustBeMP4(let url):
            return "The output URL must have an .mp4 extension: \(url.path)."
        case .couldNotCreateExportSession:
            return "AVFoundation could not create an export session."
        case .couldNotCreateVideoComposition:
            return "AVFoundation could not create the Core Image video composition."
        case .exportFailed(let message):
            return "Video export failed: \(message)"
        }
    }
}

private final class ProjectFrameRenderer: @unchecked Sendable {
    private let project: RecordingProject
    private let geometry: RenderGeometry
    private let cursorGraphics: CursorGraphicSet
    private let sortedCursorSamples: [CursorSample]
    private let cursorSampleTimes: [Double]
    private let cursorMotionTimes: [Double]
    private let sortedClicks: [ClickEvent]
    private let clickTimes: [Double]
    private let effectiveZoomSegments: [ZoomSegment]
    private let zoomStartTimes: [Double]
    private let zoomPrefixMaximumEnds: [Double]
    private let timelineSettings: ProjectSettings
    private let primaryColor: CIColor
    private let secondaryColor: CIColor
    private let backgroundPreset: BackgroundPreset?
    private let backgroundImage: CIImage?
    private let sourceCropInsets: SourceCropInsets
    private let visibleSourceReferenceWidth: Double
    /// Enabled chapters in playback order; numbering matches the SRT export.
    private let captionChapters: [DemoChapter]
    private let captionStyle: CaptionStyle
    /// Caption pills rasterized once per chapter for this canvas and style.
    private let captionArtwork: [UUID: CIImage]

    init(project: RecordingProject, geometry: RenderGeometry, cursorGraphics: CursorGraphicSet) {
        self.project = project
        self.geometry = geometry
        self.cursorGraphics = cursorGraphics
        let sourceCropInsets = project.settings.sourceCropInsets?.sanitized ?? SourceCropInsets()
        self.sourceCropInsets = sourceCropInsets
        self.visibleSourceReferenceWidth = max(
            1,
            Double(project.sourceWidth) * (1 - sourceCropInsets.leading - sourceCropInsets.trailing)
        )
        let cursorSamples = project.cursorSamples
            .filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }
            .sorted { $0.time < $1.time }
        self.sortedCursorSamples = cursorSamples
        self.cursorSampleTimes = cursorSamples.map(\.time)
        self.cursorMotionTimes = cursorSamples.indices.compactMap { index in
            guard index > 0 else { return cursorSamples[index].time }
            let lhs = cursorSamples[index - 1]
            let rhs = cursorSamples[index]
            return abs(lhs.x - rhs.x) + abs(lhs.y - rhs.y) > 0.0005 ? rhs.time : nil
        }
        let clicks = project.clickEvents
            .filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }
            .compactMap { click -> ClickEvent? in
                guard let point = sourceCropInsets.croppedPoint(x: click.x, y: click.y) else {
                    return nil
                }
                return ClickEvent(
                    id: click.id,
                    time: click.time,
                    x: point.x,
                    y: point.y,
                    button: click.button
                )
            }
            .sorted { $0.time < $1.time }
        self.sortedClicks = clicks
        self.clickTimes = clicks.map(\.time)
        let zoomSegments = project.zoomSegments
            .filter {
                ($0.kind == .manual || project.settings.autoZoomEnabled)
                    && $0.start.isFinite
                    && $0.end.isFinite
                    && $0.targetX.isFinite
                    && $0.targetY.isFinite
                    && $0.scale.isFinite
                    && $0.end >= $0.start
            }
            .compactMap { segment -> ZoomSegment? in
                guard let point = sourceCropInsets.croppedPoint(
                    x: segment.targetX,
                    y: segment.targetY
                ) else { return nil }
                var cropped = segment
                cropped.targetX = point.x
                cropped.targetY = point.y
                return cropped
            }
            .sorted { $0.start < $1.start }
        self.effectiveZoomSegments = zoomSegments
        self.zoomStartTimes = zoomSegments.map(\.start)
        var maximumEnd = -Double.infinity
        self.zoomPrefixMaximumEnds = zoomSegments.map { segment in
            maximumEnd = max(maximumEnd, segment.end)
            return maximumEnd
        }
        // Durations are literal seconds in both editor and rendered output.
        // Animation style changes the curve, never secretly rescales its timing.
        self.timelineSettings = project.settings
        self.primaryColor = CIColor(hex: project.settings.backgroundColor)
            ?? CIColor(red: 0.427, green: 0.365, blue: 0.984, alpha: 1)
        self.secondaryColor = CIColor(hex: project.settings.secondaryBackgroundColor)
            ?? CIColor(red: 0.094, green: 0.651, blue: 0.788, alpha: 1)
        self.backgroundPreset = BackgroundPreset.allCases.first {
            $0.matches(
                primary: project.settings.backgroundColor,
                secondary: project.settings.secondaryBackgroundColor
            )
        }
        self.backgroundImage = Self.loadBackgroundImage(
            path: project.settings.backgroundImagePath,
            relativeTo: URL(fileURLWithPath: project.sourceVideoPath)
                .deletingLastPathComponent()
        )
        // Captions are part of the immutable compositor state: text is drawn
        // once here, never per frame, and the same pills feed preview and export.
        let captionStyle = project.settings.resolvedCaptionStyle
        self.captionStyle = captionStyle
        let chapters = ChapterMath
            .sanitized(project.chapters ?? [], duration: project.duration)
            .filter(\.isEnabled)
        self.captionChapters = chapters
        var captionArtwork: [UUID: CIImage] = [:]
        for (index, chapter) in chapters.enumerated() {
            guard let artwork = CaptionRenderer.artwork(
                text: chapter.displayText,
                number: captionStyle.showsChapterNumber ? index + 1 : nil,
                canvasSize: geometry.outputSize,
                style: captionStyle
            ) else { continue }
            captionArtwork[chapter.id] = CIImage(cgImage: artwork.image)
        }
        self.captionArtwork = captionArtwork
    }

    func render(sourceImage: CIImage, seconds rawSeconds: Double) -> CIImage {
        let seconds = rawSeconds.isFinite ? max(0, rawSeconds) : 0
        let canvasRect = CGRect(origin: .zero, size: geometry.outputSize)
        var canvas = background(in: canvasRect)

        let sourceExtent = sourceImage.extent
        guard sourceExtent.width > 0, sourceExtent.height > 0 else { return canvas }
        let normalizedSource = sourceImage.transformed(
            by: CGAffineTransform(translationX: -sourceExtent.minX, y: -sourceExtent.minY)
        )
        let sourceCropRect = sourceCropInsets.sourceRect(in: sourceExtent.size)
        let croppedSource = normalizedSource
            .cropped(to: sourceCropRect)
            .transformed(by: CGAffineTransform(
                translationX: -sourceCropRect.minX,
                y: -sourceCropRect.minY
            ))

        let zoom = zoomState(at: seconds)
        let sourceSize = sourceCropRect.size
        let zoomScale = max(1, zoom.scale)
        let zoomTranslation = CGAffineTransform(
            translationX: sourceSize.width / 2 - zoom.centerX * sourceSize.width * zoomScale,
            y: sourceSize.height / 2 - (1 - zoom.centerY) * sourceSize.height * zoomScale
        )
        let zoomedSource = croppedSource
            .transformed(by: CGAffineTransform(scaleX: zoomScale, y: zoomScale))
            .transformed(by: zoomTranslation)
            .cropped(to: CGRect(origin: .zero, size: sourceSize))

        let placementScale = geometry.screenFrame.width / sourceSize.width
        var placedSource = zoomedSource
            .transformed(by: CGAffineTransform(scaleX: placementScale, y: placementScale))
            .transformed(by: CGAffineTransform(
                translationX: geometry.screenFrame.minX,
                y: geometry.screenFrame.minY
            ))

        let motionBlur = project.settings.motionBlur.clamped(to: 0...1)
        if motionBlur > 0 {
            let frameInterval = 1 / Double(project.settings.frameRate.clamped(to: 1...120))
            let previousTime = max(0, seconds - frameInterval)
            let previousZoom = zoomState(at: previousTime)
            let elapsed = max(0.001, seconds - previousTime)
            // The zoom focus always lands on the centre of the screen frame, so
            // radial blur about that centre matches the scale change exactly.
            let scaleVelocity = abs(zoom.scale - previousZoom.scale) / elapsed
            let blurAmount = min(18, scaleVelocity * 2.2) * motionBlur
            if blurAmount >= 0.08 {
                placedSource = placedSource
                    .applyingFilter("CIZoomBlur", parameters: [
                        kCIInputCenterKey: CIVector(
                            x: geometry.screenFrame.midX,
                            y: geometry.screenFrame.midY
                        ),
                        kCIInputAmountKey: blurAmount
                    ])
                    .cropped(to: geometry.screenFrame)
            }
            // A pan (chained clicks, focus handoff) moves the image sideways
            // under the frame. Blur along that direction by the per-frame
            // displacement, which reads as continuous motion instead of
            // strobing between sharp positions.
            let panX = (zoom.centerX - previousZoom.centerX) * sourceSize.width * zoomScale * placementScale
            let panY = (zoom.centerY - previousZoom.centerY) * sourceSize.height * zoomScale * placementScale
            let panDistance = hypot(panX, panY)
            let panRadius = min(28, panDistance * 0.55) * motionBlur
            if panRadius >= 0.6 {
                placedSource = placedSource
                    .clampedToExtent()
                    .applyingFilter("CIMotionBlur", parameters: [
                        kCIInputRadiusKey: panRadius,
                        kCIInputAngleKey: atan2(-panY, panX)
                    ])
                    .cropped(to: geometry.screenFrame)
            }
        }

        let radius = max(0, project.settings.cornerRadius)
            .clamped(to: 0...min(geometry.screenFrame.width, geometry.screenFrame.height) / 2)
        let screenMask = roundedRectangleMask(frame: geometry.screenFrame, radius: radius)
        let transparentCanvas = CIImage(color: .clear).cropped(to: canvasRect)

        if project.settings.shadow > 0 {
            let strength = project.settings.shadow.clamped(to: 0...1)
            let blurRadius = max(4, 32 * strength)
            let shadowMask = screenMask
                .transformed(by: CGAffineTransform(translationX: 0, y: -10 * strength))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
                .cropped(to: canvasRect)
            let shadowColor = CIImage(
                color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.58 * strength)
            ).cropped(to: canvasRect)
            let shadow = shadowColor.applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: transparentCanvas,
                    kCIInputMaskImageKey: shadowMask
                ]
            )
            canvas = shadow.composited(over: canvas)
        }

        var screenLayer = placedSource.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparentCanvas,
                kCIInputMaskImageKey: screenMask
            ]
        )

        if project.settings.showClickRing,
           let clickRing = clickRingLayer(at: seconds, zoom: zoom, canvasRect: canvasRect) {
            screenLayer = clickRing.composited(over: screenLayer)
        }
        // Feedback sits beneath the pointer so a bright ring never obscures the
        // cursor's hotspot or the I-beam while typing.
        if let pointer = cursorLayer(at: seconds, zoom: zoom, canvasRect: canvasRect) {
            screenLayer = pointer.composited(over: screenLayer)
        }

        screenLayer = screenLayer.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparentCanvas,
                kCIInputMaskImageKey: screenMask
            ]
        )
        var composed = screenLayer.composited(over: canvas)
        // The chapter caption sits above everything, including the padding,
        // so it stays legible over any zoom, cursor or background.
        if let caption = captionLayer(at: seconds, canvasRect: canvasRect) {
            composed = caption.composited(over: composed)
        }
        return composed.cropped(to: canvasRect)
    }

    private func captionLayer(at seconds: Double, canvasRect: CGRect) -> CIImage? {
        guard let chapter = ChapterMath.activeChapter(at: seconds, chapters: captionChapters),
              let artwork = captionArtwork[chapter.id] else { return nil }
        let opacity = ChapterMath.opacity(at: seconds, chapter: chapter)
        guard opacity > 0.001 else { return nil }
        let size = artwork.extent.size
        let padding = canvasRect.height * 0.06
        let x = ((canvasRect.width - size.width) / 2).rounded()
        let y: CGFloat
        switch captionStyle.position {
        case .bottom:
            y = padding.rounded()
        case .top:
            y = (canvasRect.height - padding - size.height).rounded()
        }
        var layer = artwork.transformed(by: CGAffineTransform(translationX: x, y: y))
        if opacity < 0.999 {
            layer = layer.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
            ])
        }
        return layer.cropped(to: canvasRect)
    }

    private func background(in rect: CGRect) -> CIImage {
        switch project.settings.backgroundStyle {
        case .solid:
            return CIImage(color: primaryColor).cropped(to: rect)
        case .gradient:
            return gradientBackground(in: rect)
        case .image:
            guard let backgroundImage else {
                // A project may be moved to another Mac without its referenced
                // wallpaper. Falling back keeps preview and export usable.
                return gradientBackground(in: rect)
            }
            return imageBackground(backgroundImage, in: rect)
        }
    }

    private func gradientBackground(in rect: CGRect) -> CIImage {
        guard let filter = CIFilter(name: "CILinearGradient") else {
            return CIImage(color: primaryColor).cropped(to: rect)
        }
        let points = backgroundGradientPoints(in: rect)
        filter.setValue(CIVector(cgPoint: points.start), forKey: "inputPoint0")
        filter.setValue(CIVector(cgPoint: points.end), forKey: "inputPoint1")
        filter.setValue(primaryColor, forKey: "inputColor0")
        filter.setValue(secondaryColor, forKey: "inputColor1")
        let base = (filter.outputImage ?? CIImage(color: primaryColor)).cropped(to: rect)

        // A very soft highlight keeps the preset backgrounds from looking flat,
        // while custom colors remain an exact two-stop gradient.
        guard backgroundPreset != nil,
              let glowFilter = CIFilter(name: "CIRadialGradient") else { return base }
        let radius = max(rect.width, rect.height) * 0.72
        glowFilter.setValue(
            CIVector(x: rect.minX + rect.width * 0.22, y: rect.maxY - rect.height * 0.14),
            forKey: "inputCenter"
        )
        glowFilter.setValue(0, forKey: "inputRadius0")
        glowFilter.setValue(radius, forKey: "inputRadius1")
        glowFilter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 0.10), forKey: "inputColor0")
        glowFilter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 0), forKey: "inputColor1")
        let glow = (glowFilter.outputImage ?? CIImage(color: .clear)).cropped(to: rect)
        return glow.composited(over: base).cropped(to: rect)
    }

    private func imageBackground(_ source: CIImage, in rect: CGRect) -> CIImage {
        let sourceExtent = source.extent.standardized
        guard sourceExtent.width.isFinite,
              sourceExtent.height.isFinite,
              sourceExtent.width > 0,
              sourceExtent.height > 0 else {
            return gradientBackground(in: rect)
        }

        let normalized = source.transformed(
            by: CGAffineTransform(
                translationX: -sourceExtent.minX,
                y: -sourceExtent.minY
            )
        )
        let scale = max(rect.width / sourceExtent.width, rect.height / sourceExtent.height)
        var image = normalized
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: rect.midX - sourceExtent.width * scale / 2,
                y: rect.midY - sourceExtent.height * scale / 2
            ))

        let brightness = project.settings.resolvedBackgroundBrightness
        if abs(brightness) > 0.000_1 {
            image = image.applyingFilter(
                "CIColorControls",
                parameters: [kCIInputBrightnessKey: brightness]
            )
        }

        let blurRadius = project.settings.resolvedBackgroundBlur
        if blurRadius > 0.000_1 {
            // Clamp before blurring so transparent pixels beyond the image do
            // not produce dark seams along the canvas edges.
            image = image
                .clampedToExtent()
                .applyingFilter(
                    "CIGaussianBlur",
                    parameters: [kCIInputRadiusKey: blurRadius]
                )
        }
        return image.cropped(to: rect)
    }

    private static func loadBackgroundImage(path: String?, relativeTo directory: URL) -> CIImage? {
        guard let rawPath = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else { return nil }
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        let url: URL
        if let parsed = URL(string: expandedPath), parsed.isFileURL {
            url = parsed
        } else if expandedPath.hasPrefix("/") {
            url = URL(fileURLWithPath: expandedPath)
        } else {
            url = directory.appendingPathComponent(expandedPath)
        }
        let standardizedURL = url.standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: standardizedURL.path) else {
            return nil
        }
        return CIImage(
            contentsOf: standardizedURL,
            options: [.applyOrientationProperty: true]
        )
    }

    private func backgroundGradientPoints(in rect: CGRect) -> (start: CGPoint, end: CGPoint) {
        switch backgroundPreset {
        case .ocean, .citrus:
            return (
                CGPoint(x: rect.minX, y: rect.midY),
                CGPoint(x: rect.maxX, y: rect.midY)
            )
        case .sunset, .midnight:
            return (
                CGPoint(x: rect.midX, y: rect.maxY),
                CGPoint(x: rect.midX, y: rect.minY)
            )
        case .blossom, .cloud:
            return (
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY)
            )
        case .aurora, .graphite, .none:
            return (
                CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.minY)
            )
        }
    }

    private func roundedRectangleMask(frame: CGRect, radius: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return CIImage(color: .white).cropped(to: frame)
        }
        filter.setValue(CIVector(cgRect: frame), forKey: kCIInputExtentKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        filter.setValue(CIColor.white, forKey: kCIInputColorKey)
        return (filter.outputImage ?? CIImage(color: .white)).cropped(to: frame)
    }

    private func cursorLayer(at seconds: Double, zoom: ZoomState, canvasRect: CGRect) -> CIImage? {
        guard let sourcePosition = cursorPosition(at: seconds),
              let croppedPosition = sourceCropInsets.croppedPoint(
                  x: sourcePosition.x,
                  y: sourcePosition.y
              ),
              cursorOpacity(at: seconds) > 0
        else {
            return nil
        }
        let point = transformedPoint(x: croppedPosition.x, y: croppedPosition.y, zoom: zoom)
        guard point.x >= -0.1, point.x <= 1.1, point.y >= -0.1, point.y <= 1.1 else {
            return nil
        }

        let canvasPoint = CGPoint(
            x: geometry.screenFrame.minX + point.x * geometry.screenFrame.width,
            y: geometry.screenFrame.maxY - point.y * geometry.screenFrame.height
        )
        let cursorGraphic = cursorGraphics.graphic(for: sourcePosition.cursorKind)
        let sourceReferenceScale = geometry.screenFrame.width / CGFloat(visibleSourceReferenceWidth)
        let scale = max(0.5, sourceReferenceScale) * max(0.1, project.settings.cursorScale)
            * cursorPressScale(at: seconds)
        let cursorImage = CIImage(cgImage: cursorGraphic.image)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let offsetX = cursorGraphic.hotSpot.x * scale
        let offsetYFromBottom = (CGFloat(cursorGraphic.image.height) - cursorGraphic.hotSpot.y) * scale
        return cursorImage
            .transformed(by: CGAffineTransform(
                translationX: canvasPoint.x - offsetX,
                y: canvasPoint.y - offsetYFromBottom
            ))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: cursorOpacity(at: seconds))
            ])
            .cropped(to: canvasRect)
    }

    private func clickRingLayer(at seconds: Double, zoom: ZoomState, canvasRect: CGRect) -> CIImage? {
        let settings = project.settings.resolvedClickAnimation
        let color = CIColor(hex: settings.colorHex) ?? CIColor(red: 0.545, green: 0.482, blue: 1)
        let outputScale = min(canvasRect.width, canvasRect.height) / 1080
        var clickIndex = insertionIndex(atOrBefore: seconds, times: clickTimes)
        var result: CIImage?
        while clickIndex >= 0 {
            let click = sortedClicks[clickIndex]
            let age = seconds - click.time
            if age >= settings.duration { break }
            let point = transformedPoint(x: click.x, y: click.y, zoom: zoom)
            let canvasPoint = CGPoint(
                x: geometry.screenFrame.minX + point.x * geometry.screenFrame.width,
                y: geometry.screenFrame.maxY - point.y * geometry.screenFrame.height
            )
            for layer in ClickAnimationMath.layers(age: age, settings: settings) where layer.opacity > 0.001 {
                let graphic: CGImage
                switch layer.kind {
                case .ring: graphic = CursorGraphic.clickRing
                case .fill: graphic = CursorGraphic.clickFill
                case .halo: graphic = CursorGraphic.clickHalo
                }
                let scale = layer.radius * 2 * outputScale / CGFloat(graphic.width)
                let image = CIImage(cgImage: graphic)
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(
                        translationX: canvasPoint.x - layer.radius * outputScale,
                        y: canvasPoint.y - layer.radius * outputScale
                    ))
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: color.red, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: color.green, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: color.blue, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: layer.opacity),
                    ])
                    .cropped(to: canvasRect)
                result = result.map { image.composited(over: $0) } ?? image
            }
            clickIndex -= 1
        }
        return result
    }

    private func cursorPressScale(at seconds: Double) -> Double {
        guard project.settings.showClickRing else { return 1 }
        let settings = project.settings.resolvedClickAnimation
        var clickIndex = insertionIndex(atOrBefore: seconds, times: clickTimes)
        var compression: Double = 0
        var rebound: Double = 0
        while clickIndex >= 0 {
            let age = seconds - sortedClicks[clickIndex].time
            if age > min(0.42, settings.duration * 0.72) { break }
            // Independent continuous envelopes preserve feedback when a second
            // click starts before the first press has settled.
            let candidate = ClickAnimationMath.cursorPressScale(age: age, settings: settings)
            compression = max(compression, 1 - candidate)
            rebound = max(rebound, candidate - 1)
            clickIndex -= 1
        }
        return 1 - compression + rebound
    }

    private func cursorPosition(at seconds: Double) -> CursorSample? {
        guard let first = sortedCursorSamples.first else { return nil }
        if seconds <= first.time { return first }
        guard let last = sortedCursorSamples.last, seconds < last.time else { return sortedCursorSamples.last }

        if project.settings.cursorAnimation == .smooth {
            return TimelineMath.cursorPosition(at: seconds, samples: sortedCursorSamples)
        }

        let lowerIndex = insertionIndex(
            atOrBefore: seconds,
            times: cursorSampleTimes
        )
        guard lowerIndex >= 0 else { return first }
        let lhs = sortedCursorSamples[lowerIndex]
        guard project.settings.cursorAnimation != .none,
              lowerIndex + 1 < sortedCursorSamples.count else { return lhs }
        let rhs = sortedCursorSamples[lowerIndex + 1]
        let rawProgress = ((seconds - lhs.time) / max(0.000_001, rhs.time - lhs.time)).clamped(to: 0...1)
        let progress: Double
        switch project.settings.cursorAnimation {
        case .rapid:
            progress = 1 - pow(1 - rawProgress, 3)
        case .medium:
            progress = rawProgress
        case .smooth:
            progress = TimelineMath.smoothStep(rawProgress)
        case .none:
            progress = 0
        }
        return CursorSample(
            time: seconds,
            x: lhs.x + (rhs.x - lhs.x) * progress,
            y: lhs.y + (rhs.y - lhs.y) * progress,
            cursorKind: lhs.cursorKind
        )
    }

    private func cursorOpacity(at seconds: Double) -> Double {
        guard project.settings.hideIdleCursor else { return 1 }
        guard !sortedCursorSamples.isEmpty else { return 0 }

        let motionIndex = insertionIndex(atOrBefore: seconds, times: cursorMotionTimes)
        let recentMotionTime = motionIndex >= 0
            ? cursorMotionTimes[motionIndex]
            : sortedCursorSamples[0].time

        let clickIndex = insertionIndex(atOrBefore: seconds, times: clickTimes)
        let recentClickTime = clickIndex >= 0 ? clickTimes[clickIndex] : recentMotionTime
        let idleTime = seconds - max(recentMotionTime, recentClickTime)
        if idleTime <= 1.4 { return 1 }
        return 1 - TimelineMath.smootherStep((idleTime - 1.4) / 0.35)
    }

    private func transformedPoint(x: Double, y: Double, zoom: ZoomState) -> CGPoint {
        CGPoint(
            x: 0.5 + (x - zoom.centerX) * zoom.scale,
            y: 0.5 + (y - zoom.centerY) * zoom.scale
        )
    }

    private func zoomState(at seconds: Double) -> ZoomState {
        var index = insertionIndex(
            atOrBefore: seconds,
            times: zoomStartTimes
        )
        var activeSegments: [ZoomSegment] = []
        while index >= 0 {
            if zoomPrefixMaximumEnds[index] < seconds { break }
            let segment = effectiveZoomSegments[index]
            if segment.isEnabled, seconds <= segment.end {
                activeSegments.append(segment)
            }
            index -= 1
        }
        return TimelineMath.zoomState(
            at: seconds,
            segments: activeSegments,
            settings: timelineSettings
        )
    }

    private func insertionIndex(atOrBefore value: Double, times: [Double]) -> Int {
        guard !times.isEmpty else { return -1 }
        var low = 0
        var high = times.count
        while low < high {
            let middle = (low + high) / 2
            if times[middle] <= value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low - 1
    }
}

private struct CursorGraphicSet: @unchecked Sendable {
    let arrow: CursorGraphic
    let iBeam: CursorGraphic

    @MainActor
    init(appearance: CursorAppearance) {
        switch appearance {
        case .system:
            arrow = CursorGraphic.systemOrFallback(
                NSCursor.arrow,
                fallback: CursorGraphic.highContrastArrow,
                fallbackHotSpot: CGPoint(x: 3, y: 2)
            )
            iBeam = CursorGraphic.systemOrFallback(
                NSCursor.iBeam,
                fallback: CursorGraphic.highContrastIBeam,
                fallbackHotSpot: CGPoint(x: 14, y: 20)
            )
        case .highContrast:
            arrow = CursorGraphic(
                image: CursorGraphic.highContrastArrow,
                hotSpot: CGPoint(x: 3, y: 2)
            )
            iBeam = CursorGraphic(
                image: CursorGraphic.highContrastIBeam,
                hotSpot: CGPoint(x: 14, y: 20)
            )
        case .dot:
            let dot = CursorGraphic(
                image: CursorGraphic.dot,
                hotSpot: CGPoint(x: 14, y: 14)
            )
            arrow = dot
            iBeam = dot
        }
    }

    func graphic(for kind: CursorKind) -> CursorGraphic {
        switch kind {
        case .arrow: return arrow
        case .iBeam: return iBeam
        }
    }
}

private struct CursorGraphic: @unchecked Sendable {
    let image: CGImage
    let hotSpot: CGPoint

    @MainActor
    static func systemOrFallback(
        _ cursor: NSCursor,
        fallback: CGImage,
        fallbackHotSpot: CGPoint
    ) -> CursorGraphic {
        let image = cursor.image
        var proposedRect = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) {
            return CursorGraphic(image: cgImage, hotSpot: cursor.hotSpot)
        }
        return CursorGraphic(image: fallback, hotSpot: fallbackHotSpot)
    }

    static let highContrastArrow: CGImage = drawImage(size: CGSize(width: 32, height: 40)) { context in
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.translateBy(x: 0, y: 40)
        context.scaleBy(x: 1, y: -1)
        context.move(to: CGPoint(x: 3, y: 2))
        context.addLine(to: CGPoint(x: 4, y: 31))
        context.addLine(to: CGPoint(x: 11, y: 24))
        context.addLine(to: CGPoint(x: 17, y: 37))
        context.addLine(to: CGPoint(x: 23, y: 34))
        context.addLine(to: CGPoint(x: 17, y: 21))
        context.addLine(to: CGPoint(x: 27, y: 20))
        context.closePath()
        context.setLineJoin(.round)
        context.setLineWidth(4)
        context.setStrokeColor(NSColor.white.cgColor)
        context.strokePath()
        context.move(to: CGPoint(x: 3, y: 2))
        context.addLine(to: CGPoint(x: 4, y: 31))
        context.addLine(to: CGPoint(x: 11, y: 24))
        context.addLine(to: CGPoint(x: 17, y: 37))
        context.addLine(to: CGPoint(x: 23, y: 34))
        context.addLine(to: CGPoint(x: 17, y: 21))
        context.addLine(to: CGPoint(x: 27, y: 20))
        context.closePath()
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
    }

    static let highContrastIBeam: CGImage = drawImage(size: CGSize(width: 28, height: 40)) { context in
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        func addIBeamPath() {
            context.move(to: CGPoint(x: 14, y: 4))
            context.addLine(to: CGPoint(x: 14, y: 36))
            context.move(to: CGPoint(x: 7, y: 4))
            context.addLine(to: CGPoint(x: 21, y: 4))
            context.move(to: CGPoint(x: 7, y: 36))
            context.addLine(to: CGPoint(x: 21, y: 36))
        }

        addIBeamPath()
        context.setLineWidth(7)
        context.setStrokeColor(NSColor.white.cgColor)
        context.strokePath()
        addIBeamPath()
        context.setLineWidth(3)
        context.setStrokeColor(NSColor.black.cgColor)
        context.strokePath()
    }

    static let dot: CGImage = drawImage(size: CGSize(width: 28, height: 28)) { context in
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: 2, y: 2, width: 24, height: 24))
        context.setFillColor(NSColor.black.cgColor)
        context.fillEllipse(in: CGRect(x: 6, y: 6, width: 16, height: 16))
    }

    static let clickRing: CGImage = drawImage(size: CGSize(width: 256, height: 256)) { context in
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(8)
        context.strokeEllipse(in: CGRect(x: 6, y: 6, width: 244, height: 244))
    }

    static let clickFill: CGImage = drawImage(size: CGSize(width: 256, height: 256)) { context in
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: 1, y: 1, width: 254, height: 254))
    }

    static let clickHalo: CGImage = drawImage(size: CGSize(width: 256, height: 256)) { context in
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor.white.withAlphaComponent(0.72).cgColor,
                NSColor.white.withAlphaComponent(0.36).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor,
            ] as CFArray,
            locations: [0, 0.48, 1]
        )!
        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: 128, y: 128),
            startRadius: 0,
            endCenter: CGPoint(x: 128, y: 128),
            endRadius: 127,
            options: []
        )
    }

    private static func drawImage(
        size: CGSize,
        drawing: (CGContext) -> Void
    ) -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.clear(CGRect(origin: .zero, size: size))
        drawing(context)
        return context.makeImage()!
    }
}

private extension CIColor {
    convenience init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else { return nil }

        if value.count == 6 {
            self.init(
                red: CGFloat((number >> 16) & 0xFF) / 255,
                green: CGFloat((number >> 8) & 0xFF) / 255,
                blue: CGFloat(number & 0xFF) / 255,
                alpha: 1
            )
        } else {
            self.init(
                red: CGFloat((number >> 24) & 0xFF) / 255,
                green: CGFloat((number >> 16) & 0xFF) / 255,
                blue: CGFloat((number >> 8) & 0xFF) / 255,
                alpha: CGFloat(number & 0xFF) / 255
            )
        }
    }
}
