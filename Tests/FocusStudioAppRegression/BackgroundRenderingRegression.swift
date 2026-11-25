@preconcurrency import AVFoundation
import CoreGraphics
import FocusStudioCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Real prepared-preview and MP4 pixels. No capture, user library or network.
@MainActor
enum BackgroundRenderingRegression {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusStudio-Background-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        let wallpaper = root.appendingPathComponent("wallpaper.png")
        let portrait = root.appendingPathComponent("portrait.png")
        try image(at: source, size: CGSize(width: 640, height: 480), color: .green, redEdges: true)
        try image(at: wallpaper, size: CGSize(width: 64, height: 64), color: .magenta)
        try image(at: portrait, size: CGSize(width: 240, height: 480), color: .blue)
        let movie = root.appendingPathComponent("source.mp4")
        _ = try await StillImageVideoBuilder.build(from: source, to: movie, duration: 1,
                                                   renderSize: CGSize(width: 640, height: 480))
        var project = RecordingProject(title: "Background fixture", sourceVideoPath: movie.path,
                                       duration: 1, sourceWidth: 640, sourceHeight: 480)
        project.settings.exportWidth = 640
        project.settings.frameRate = 24
        project.settings.showCursor = false
        project.settings.showClickRing = false
        project.settings.motionBlur = 0
        project.settings.backgroundStyle = .image
        project.settings.backgroundImagePath = wallpaper.path
        project.settings.padding = 52
        project.settings.cornerRadius = 64
        project.settings.shadow = 0.7
        project.settings.aspectRatio = .wide
        let decorated = project.settings
        let originalGeometry = ProjectVideoRenderer.geometry(for: project)
        try expect(originalGeometry.outputSize == CGSize(width: 640, height: 360)
            && originalGeometry.screenFrame.minY == 52, "existing decorated output keeps its ratio and padding")
        let framed = try await preview(project, at: 0.5)
        try expect(pixel(framed, x: 3, y: 3).matches(.magenta), "wallpaper really renders outside the frame")

        try await bundledGallery(project, root: root)

        project.settings.backgroundStyle = .none
        let geometry = ProjectVideoRenderer.geometry(for: project)
        try expect(geometry.outputSize == CGSize(width: 640, height: 480)
            && geometry.screenFrame == CGRect(x: 0, y: 0, width: 640, height: 480),
            "original mode fills its 4:3 canvas despite stored 16:9, padding and rounded corners")
        let original = try await preview(project, at: 0.5)
        for (x, y) in [(3, 3), (636, 3), (3, 476), (636, 476)] {
            try expect(pixel(original, x: x, y: y).matches(.red), "original source reaches every corner, without matte or rounding")
        }
        try expect(pixel(original, x: 320, y: 240).matches(.green), "original mode keeps the source center")
        var restored = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(project))
        try expect(restored.settings.backgroundStyle == .none, "no-background choice survives save and reload")
        restored.settings.backgroundStyle = .image
        try expect(restored.settings == decorated && ProjectVideoRenderer.geometry(for: restored) == originalGeometry,
                   "switching back restores all stored decoration and aspect settings exactly")

        project.settings.sourceCropInsets = .init(leading: 0.125, trailing: 0.125)
        try expect(ProjectVideoRenderer.geometry(for: project).outputSize == CGSize(width: 640, height: 640),
                   "original mode follows the edited crop rather than uncropped source size")
        let cropped = try await preview(project, at: 0.5)
        for (x, y) in [(4, 4), (635, 4), (4, 635), (635, 635)] {
            try expect(pixel(cropped, x: x, y: y).matches(.green), "crop removes the red source borders without adding decoration")
        }

        // Mixed-aspect footage must retain all content. Only the necessary black
        // matte is visible; it must never revive the saved wallpaper or corners.
        project.settings.sourceCropInsets = nil
        let photo = DemoMediaAsset(title: "Portrait", filePath: portrait.path, kind: .image,
                                   duration: 0, width: 240, height: 480)
        let importedVideo = DemoMediaAsset(title: "Video", filePath: movie.path, kind: .video,
                                           duration: 1, width: 640, height: 480)
        project.mediaAssets = [photo, importedVideo]
        project.videoSourceDuration = 1
        project.duration = 3
        project.videoClips = [
            .init(sourceStart: 0, sourceEnd: 1),
            .init(sourceStart: 0, sourceEnd: 1, mediaAssetID: photo.id),
            .init(sourceStart: 0, sourceEnd: 1, mediaAssetID: importedVideo.id),
        ]
        let prepared = try await ProjectVideoRenderer.prepare(project: project)
        let playerItem = prepared.makePlayerItem()
        try expect(playerItem.videoComposition?.renderSize == CGSize(width: 640, height: 480),
                   "editor player uses the same original-ratio composition")
        let previewGenerator = AVAssetImageGenerator(asset: prepared.asset)
        previewGenerator.videoComposition = prepared.videoComposition
        try await verifyMixedFrames(previewGenerator)

        let output = root.appendingPathComponent("original-mode.mp4")
        let exported = try await ProjectVideoRenderer.export(project: project, to: output)
        try expect(exported.width == 640 && exported.height == 480 && abs(exported.duration - 3) < 0.01,
                   "MP4 exports the original canvas and complete timeline")
        try await verifyMixedFrames(AVAssetImageGenerator(asset: AVURLAsset(url: output)))
        print("BackgroundRenderingRegression: PASS (original ratio, crop, true corner pixels, preview/export parity, image/video inserts, saved decoration restoration)")
    }

    private static func verifyMixedFrames(_ generator: AVAssetImageGenerator) async throws {
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (photo, _) = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600))
        try expect(pixel(photo, x: 3, y: 240).matches(.black)
                   && pixel(photo, x: 320, y: 240).matches(.blue)
                   && pixel(photo, x: 203, y: 3).matches(.blue),
                   "portrait still fits uncropped with black bars and square corners")
        let (video, _) = try await generator.image(at: CMTime(seconds: 2.5, preferredTimescale: 600))
        try expect(pixel(video, x: 3, y: 3).matches(.red)
                   && pixel(video, x: 636, y: 476).matches(.red)
                   && pixel(video, x: 320, y: 240).matches(.green),
                   "imported video has no saved wallpaper, padding, shadow or rounded corners")
    }

    private static func bundledGallery(_ original: RecordingProject, root: URL) async throws {
        let catalog = try BackgroundCatalog.loadBundled()
        guard let artwork = catalog.assets.first(where: { $0.id == "tidal-glass" }) else {
            throw Failure(message: "Missing bundled tidal-glass image")
        }
        let url = catalog.fileURL(for: artwork)
        var project = original
        project.settings.backgroundImagePath = url.path
        let store = ProjectStore(projectsDirectory: root.appendingPathComponent("Projects"))
        let directory = try await store.projectDirectory(for: project.id)
        let source = URL(fileURLWithPath: original.sourceVideoPath)
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(source.lastPathComponent))
        try await store.save(project)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("project.json"))) as? [String: Any]
        let stored = (json?["settings"] as? [String: Any])?["backgroundImagePath"] as? String
        try expect(stored == "focusstudio://background/tidal-glass", "save a portable ID for the catalog image")
        let restored = try await store.loadProjects().first
        try expect(restored?.settings.backgroundImagePath == url.path, "reopen the built-in background from the active installation")
        let legacy = "/Old Installation/Focus Studio.app/Contents/Resources/Backgrounds/tidal-glass.jpg"
        try expect(catalog.resolveStoredImage(legacy) == url && catalog.resolveStoredImage("/Pictures/tidal-glass.jpg") == nil
                   && catalog.reference(forFilePath: "/Pictures/tidal-glass.jpg") == nil, "relocate old bundled images and preserve same-name imports")

        // Render from the serialized reference, as an independent export consumer can do.
        project.settings.backgroundImagePath = stored
        let frame = try await preview(project, at: 0.5)
        let output = root.appendingPathComponent("tidal.mp4")
        _ = try await ProjectVideoRenderer.export(project: project, to: output)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        let encoded = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let screen = pixel(frame, x: 10, y: 10)
        let movie = pixel(encoded, x: 10, y: 10)
        try expect(screen.g > screen.r + 20 && abs(screen.r - movie.r) < 25 && abs(screen.g - movie.g) < 25
                   && abs(screen.b - movie.b) < 25, "the bundled teal photograph matches in preview and exported MP4")
    }

    private static func preview(_ project: RecordingProject, at time: Double) async throws -> CGImage {
        let prepared = try await ProjectVideoRenderer.prepare(project: project)
        let generator = AVAssetImageGenerator(asset: prepared.asset)
        generator.videoComposition = prepared.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    private enum Color {
        case red, green, blue, magenta, black
        var cg: CGColor {
            switch self {
            case .red: return CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
            case .green: return CGColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1)
            case .blue: return CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1)
            case .magenta: return CGColor(red: 0.9, green: 0.1, blue: 0.8, alpha: 1)
            case .black: return CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            }
        }
    }

    private struct RGB {
        let r: Int, g: Int, b: Int
        func matches(_ color: Color) -> Bool {
            switch color {
            case .red: return r > 150 && g < 80 && b < 80
            case .green: return g > 130 && r < 85 && b < 100
            case .blue: return b > 150 && r < 85 && g < 100
            case .magenta: return r > 150 && b > 130 && g < 80
            case .black: return max(r, g, b) < 20
            }
        }
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> RGB {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: CGFloat(-x), y: CGFloat(-y),
                                          width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return RGB(r: Int(bytes[0]), g: Int(bytes[1]), b: Int(bytes[2]))
    }

    private static func image(at url: URL, size: CGSize, color: Color, redEdges: Bool = false) throws {
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cg)
        context.fill(CGRect(origin: .zero, size: size))
        if redEdges {
            context.setFillColor(Color.red.cg)
            context.fill(CGRect(x: 0, y: 0, width: 80, height: size.height))
            context.fill(CGRect(x: size.width - 80, y: 0, width: 80, height: size.height))
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try expect(CGImageDestinationFinalize(destination), "fixture image writes")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { "Background rendering: " + message }
    }
}
