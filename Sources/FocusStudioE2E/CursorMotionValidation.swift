@preconcurrency import AVFoundation
import FocusStudioCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Synthetic pointer/camera fixture through the shipping compositor. This is
/// QA footage, not a customer recording or evidence of a real capture session.
enum CursorMotionValidation {
    static func run(sourceURL: URL, width: Int, height: Int, duration: Double,
                    frameRate: Int, outputDirectory: URL) async throws {
        let samples = (0...Int(duration * 120)).map { index in sample(at: Double(index) / 120) }
        let clickSample = sample(at: 2.5)
        let clicks = [ClickEvent(time: 2.5, x: clickSample.x, y: clickSample.y, button: .left)]
        var settings = ProjectSettings()
        settings.cursorScale = 1.7
        settings.cursorAppearance = .highContrast
        settings.hideIdleCursor = false
        settings.showCursor = true
        settings.showClickRing = true
        settings.backgroundStyle = .gradient
        settings.backgroundColor = "#D6D1EC"
        settings.secondaryBackgroundColor = "#E8E8DE"
        settings.padding = 32
        settings.cornerRadius = 16
        settings.aspectRatio = .wide
        settings.frameRate = frameRate
        settings.exportWidth = width
        let zooms = [ZoomSegment(start: 0.3, end: 6.5, targetX: 0.5, targetY: 0.5,
                                 scale: 1.8, zoomEaseIn: 0.4, zoomEaseOut: 0.4)]
        var decodedFrames: [String: [Data]] = [:]
        for (name, style) in [("raw", CursorAnimationStyle.none), ("smooth", .smooth)] {
            settings.cursorAnimation = style
            let project = RecordingProject(title: "Synthetic cursor stability — \(name)",
                sourceVideoPath: sourceURL.path, duration: duration,
                sourceWidth: width, sourceHeight: height,
                cursorSamples: samples, clickEvents: clicks, zoomSegments: zooms, settings: settings)
            let output = outputDirectory.appendingPathComponent("cursor-motion-\(name).mp4")
            try? FileManager.default.removeItem(at: output)
            let result = try await ProjectVideoRenderer.export(project: project, to: output)
            guard result.width == width, result.height == height,
                  abs(result.duration - duration) <= 1 / Double(frameRate) else {
                throw ValidationError.invalidExport(name)
            }
            let asset = AVURLAsset(url: output)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard tracks.count == 1 else { throw ValidationError.invalidExport(name) }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            var frames: [Data] = []
            for time in [0.75, 1.25, 2.5, 3.5, 4.75, 6.0] {
                let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                let frameURL = outputDirectory.appendingPathComponent("\(name)-\(time).png")
                guard let destination = CGImageDestinationCreateWithURL(frameURL as CFURL,
                    UTType.png.identifier as CFString, 1, nil) else { throw ValidationError.invalidExport(name) }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination), let pixels = image.dataProvider?.data else {
                    throw ValidationError.invalidExport(name)
                }
                frames.append(pixels as Data)
            }
            decodedFrames[name] = frames
        }
        // Guard that the export actually consumes the finished motion path.
        guard let raw = decodedFrames["raw"], let smooth = decodedFrames["smooth"],
              zip(raw.prefix(2), smooth.prefix(2)).contains(where: { $0 != $1 }) else {
            throw ValidationError.missingRenderedMotion
        }
        let report = """
        {"status":"PASS","suite":"cursor-motion-rendering","synthetic":true,"duration":\(duration),"width":\(width),"height":\(height),"decodedFrames":12,"variants":["raw","smooth"]}
        """
        try Data(report.utf8).write(to: outputDirectory.appendingPathComponent("report.json"))
        print(report)
    }

    private static func sample(at time: Double) -> CursorSample {
        let x: Double, y: Double
        var kind = CursorKind.arrow
        var dragging = false
        switch time {
        case ..<2.4:
            let progress = time / 2.4
            let envelope = sin(.pi * progress)
            x = 0.2 + 0.58 * progress + 0.006 * sin(time * 41) * envelope
            y = 0.32 + 0.021 * sin(time * 23) * envelope
        case ..<2.8:
            x = 0.78 + 0.0018 * sin(time * 75)
            y = 0.32 + 0.0018 * cos(time * 75) // Tremor while hovering, with an exact click anchor.
        case ..<3.2:
            let progress = (time - 2.8) / 0.4
            x = 0.78 - 0.28 * progress; y = 0.32 + 0.18 * progress
        case ..<4.2:
            x = 0.5 + 0.004 * sin(time * 27)
            y = 0.5 + 0.004 * sin(time * 31) // Camera quiet zone.
        case ..<5.5:
            let progress = (time - 4.2) / 1.3
            x = 0.5 + 0.2 * progress
            y = 0.5 + 0.18 * sin(.pi * progress)
            dragging = true // Preserve this deliberate selection arc.
        case ..<6.2:
            x = 0.7 + 0.0018 * sin(time * 75)
            y = 0.5 + 0.0018 * cos(time * 75)
            kind = .pointingHand // A link hover needs the same stable motion as an arrow.
        default:
            x = 0.7 + 0.0018 * sin(time * 75)
            y = 0.5 + 0.0018 * cos(time * 75)
            kind = .iBeam
        }
        return CursorSample(time: time, x: x, y: y, cursorKind: kind, isDragging: dragging)
    }

    private enum ValidationError: Error {
        case invalidExport(String)
        case missingRenderedMotion
    }
}
