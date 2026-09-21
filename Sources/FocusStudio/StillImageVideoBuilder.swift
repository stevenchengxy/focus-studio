import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Turns a PNG or JPEG into a standards-compliant H.264 clip that can enter
/// the same project pipeline as a screen recording.
enum StillImageVideoBuilder {
    enum ScalingMode: Sendable {
        /// Shows the complete image and letterboxes only when aspect ratios differ.
        case aspectFit
        /// Fills the video frame and crops overflow from the center.
        case aspectFill
    }

    struct Result: Sendable {
        let url: URL
        let duration: TimeInterval
        let renderSize: CGSize
        let frameRate: Int
        let frameCount: Int
    }

    enum BuilderError: LocalizedError {
        case invalidDuration
        case invalidFrameRate
        case invalidRenderSize
        case unreadableImage(URL)
        case outputAlreadyExists(URL)
        case writerCreationFailed(String)
        case writerConfigurationFailed
        case pixelBufferCreationFailed(OSStatus)
        case frameAppendFailed(String)
        case writingFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidDuration:
                return "The still-image video duration must be a finite value greater than zero."
            case .invalidFrameRate:
                return "The still-image video frame rate must be between 1 and 120 fps."
            case .invalidRenderSize:
                return "The still-image video size must contain finite, positive dimensions."
            case let .unreadableImage(url):
                return "Focus Studio could not read the PNG or JPEG at \(url.lastPathComponent)."
            case let .outputAlreadyExists(url):
                return "A file already exists at \(url.path). Choose a new output location."
            case let .writerCreationFailed(message):
                return "Focus Studio could not create the still-image video writer: \(message)"
            case .writerConfigurationFailed:
                return "This Mac cannot configure an H.264 writer for the requested video size."
            case let .pixelBufferCreationFailed(status):
                return "Focus Studio could not allocate a video frame (Core Video error \(status))."
            case let .frameAppendFailed(message):
                return "Focus Studio could not encode a still-image frame: \(message)"
            case let .writingFailed(message):
                return "Focus Studio could not finish the still-image video: \(message)"
            }
        }
    }

    /// Creates a silent H.264 MP4 from a local PNG or JPEG.
    ///
    /// - Parameters:
    ///   - imageURL: Local source image. EXIF orientation is applied while loading.
    ///   - outputURL: A new `.mp4` destination. Existing files are never replaced.
    ///   - duration: Requested clip duration in seconds.
    ///   - renderSize: Optional output size. Nil uses the oriented pixel dimensions.
    ///   - frameRate: Encoded frame cadence, from 1 through 120 fps.
    ///   - scalingMode: Aspect-fit by default so screenshots are never cropped.
    ///   - backgroundColor: Letterbox color used by aspect-fit mode.
    static func build(
        from imageURL: URL,
        to outputURL: URL,
        duration: TimeInterval,
        renderSize requestedSize: CGSize? = nil,
        frameRate: Int = 30,
        scalingMode: ScalingMode = .aspectFit,
        backgroundColor: CIColor = CIColor(red: 0.035, green: 0.039, blue: 0.055, alpha: 1)
    ) async throws -> Result {
        guard duration.isFinite, duration > 0 else {
            throw BuilderError.invalidDuration
        }
        guard (1...120).contains(frameRate) else {
            throw BuilderError.invalidFrameRate
        }

        guard let source = CIImage(
            contentsOf: imageURL,
            options: [.applyOrientationProperty: true]
        ) else {
            throw BuilderError.unreadableImage(imageURL)
        }

        let sourceExtent = source.extent.standardized
        guard sourceExtent.width.isFinite,
              sourceExtent.height.isFinite,
              sourceExtent.width > 0,
              sourceExtent.height > 0
        else {
            throw BuilderError.unreadableImage(imageURL)
        }

        let proposedSize = requestedSize ?? sourceExtent.size
        let maximumDimension: CGFloat = 4_096
        let downscale = min(
            1,
            maximumDimension / max(proposedSize.width, proposedSize.height)
        )
        let rawSize = CGSize(
            width: proposedSize.width * downscale,
            height: proposedSize.height * downscale
        )
        guard rawSize.width.isFinite,
              rawSize.height.isFinite,
              rawSize.width > 0,
              rawSize.height > 0
        else {
            throw BuilderError.invalidRenderSize
        }

        let outputWidth = evenDimension(rawSize.width)
        let outputHeight = evenDimension(rawSize.height)
        let outputSize = CGSize(width: outputWidth, height: outputHeight)
        let frameCount = max(1, Int(ceil(duration * Double(frameRate))))

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw BuilderError.outputAlreadyExists(outputURL)
        }
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw BuilderError.writerCreationFailed(error.localizedDescription)
        }

        let bitRate = min(
            24_000_000,
            max(1_200_000, outputWidth * outputHeight * max(12, frameRate) / 5)
        )
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: max(frameRate, 1),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        guard writer.canApply(outputSettings: outputSettings, forMediaType: .video) else {
            throw BuilderError.writerConfigurationFailed
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw BuilderError.writerConfigurationFailed
        }
        writer.add(input)

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.startWriting() else {
            throw BuilderError.writerCreationFailed(
                writer.error?.localizedDescription ?? "AVAssetWriter did not start."
            )
        }
        writer.startSession(atSourceTime: .zero)

        do {
            guard let pool = adaptor.pixelBufferPool else {
                throw BuilderError.pixelBufferCreationFailed(kCVReturnInvalidPixelBufferAttributes)
            }

            let frameImage = compose(
                source: source,
                sourceExtent: sourceExtent,
                outputSize: outputSize,
                scalingMode: scalingMode,
                backgroundColor: backgroundColor
            )
            let context = CIContext(options: [
                .cacheIntermediates: true,
                .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
                .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
            ])
            let bounds = CGRect(origin: .zero, size: outputSize)

            for frameIndex in 0..<frameCount {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    if writer.status == .failed {
                        throw BuilderError.frameAppendFailed(
                            writer.error?.localizedDescription ?? "The video writer failed."
                        )
                    }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }

                var pixelBuffer: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                guard status == kCVReturnSuccess, let pixelBuffer else {
                    throw BuilderError.pixelBufferCreationFailed(status)
                }
                context.render(
                    frameImage,
                    to: pixelBuffer,
                    bounds: bounds,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
                )

                let presentationTime = CMTime(
                    value: CMTimeValue(frameIndex),
                    timescale: CMTimeScale(frameRate)
                )
                guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    throw BuilderError.frameAppendFailed(
                        writer.error?.localizedDescription ?? "AVAssetWriter rejected the frame."
                    )
                }
            }

            writer.endSession(
                atSourceTime: CMTime(seconds: duration, preferredTimescale: 60_000)
            )
            input.markAsFinished()
            try await finish(writer)
        } catch {
            writer.cancelWriting()
            try? fileManager.removeItem(at: outputURL)
            throw error
        }

        return Result(
            url: outputURL,
            duration: duration,
            renderSize: outputSize,
            frameRate: frameRate,
            frameCount: frameCount
        )
    }

    private static func evenDimension(_ value: CGFloat) -> Int {
        let rounded = max(2, Int(value.rounded()))
        return rounded.isMultiple(of: 2) ? rounded : rounded + 1
    }

    private static func compose(
        source: CIImage,
        sourceExtent: CGRect,
        outputSize: CGSize,
        scalingMode: ScalingMode,
        backgroundColor: CIColor
    ) -> CIImage {
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let normalized = source.transformed(
            by: CGAffineTransform(
                translationX: -sourceExtent.origin.x,
                y: -sourceExtent.origin.y
            )
        )
        let widthScale = outputSize.width / sourceExtent.width
        let heightScale = outputSize.height / sourceExtent.height
        let scale: CGFloat
        switch scalingMode {
        case .aspectFit:
            scale = min(widthScale, heightScale)
        case .aspectFill:
            scale = max(widthScale, heightScale)
        }

        let scaledSize = CGSize(
            width: sourceExtent.width * scale,
            height: sourceExtent.height * scale
        )
        let translated = normalized
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(
                by: CGAffineTransform(
                    translationX: (outputSize.width - scaledSize.width) / 2,
                    y: (outputSize.height - scaledSize.height) / 2
                )
            )
        let canvas = CIImage(color: backgroundColor).cropped(to: outputRect)
        return translated
            .cropped(to: outputRect)
            .composited(over: canvas)
            .cropped(to: outputRect)
    }

    private static func finish(_ writer: AVAssetWriter) async throws {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw BuilderError.writingFailed(
                writer.error?.localizedDescription ?? "AVAssetWriter ended in state \(writer.status.rawValue)."
            )
        }
    }
}
