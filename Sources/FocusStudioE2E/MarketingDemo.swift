import Foundation
import FocusStudioCore

/// Reproducible marketing reel rendered by the shipping compositor. The input
/// is our original fictional Aster dashboard, never a customer's recording.
enum MarketingDemo {
    static func render(imagePath: String, outputDirectory: URL) async throws {
        let media = DemoMediaAsset(title: "Aster — illustrative dashboard", filePath: imagePath,
            kind: .image, duration: 0, width: 1496, height: 812)
        let clip = DemoVideoClip(sourceStart: 0, sourceEnd: 16, mediaAssetID: media.id)
        var settings = ProjectSettings()
        settings.showCursor = false
        settings.autoZoomEnabled = false
        settings.showClickRing = false
        settings.backgroundStyle = .gradient
        settings.backgroundColor = "#D6D1EC"
        settings.secondaryBackgroundColor = "#E8E8DE"
        settings.padding = 65
        settings.cornerRadius = 20
        settings.shadow = 0.32
        settings.aspectRatio = .wide
        settings.frameRate = 30
        settings.exportWidth = 1280
        var project = RecordingProject(title: "Focus Studio — native effects showcase",
            sourceVideoPath: outputDirectory.appendingPathComponent("aster-source.mp4").path,
            duration: 16, sourceWidth: 1496, sourceHeight: 812,
            settings: settings)
        project.mediaAssets = [media]
        project.videoClips = [clip]
        project.videoSourceDuration = 16
        let chart = NormalizedRegionRect(x: 0.178, y: 0.472, width: 0.46, height: 0.40)
        let metric = NormalizedRegionRect(x: 0.41, y: 0.24, width: 0.18, height: 0.23)
        let tasks = NormalizedRegionRect(x: 0.65, y: 0.472, width: 0.31, height: 0.40)
        project.regionEffects = [
            RegionEffect(clipID: clip.id, sourceStart: 0.7, sourceEnd: 4.0, rect: chart,
                preset: .perspective, background: .dim, scale: 1.32, intensity: 0.45,
                easeIn: 0.7, easeOut: 0.7, perspectiveDegrees: -24),
            RegionEffect(clipID: clip.id, sourceStart: 4.4, sourceEnd: 7.5, rect: metric,
                preset: .magnify, background: .dim, scale: 1.8, intensity: 0.25,
                easeIn: 0.6, easeOut: 0.6),
            RegionEffect(clipID: clip.id, sourceStart: 8.0, sourceEnd: 11.2, rect: tasks,
                preset: .outline, background: .dim, scale: 1.0, intensity: 0.35,
                easeIn: 0.8, easeOut: 0.6, outlineWidth: 4),
            RegionEffect(clipID: clip.id, sourceStart: 11.6, sourceEnd: 15.2, rect: chart,
                preset: .lift, background: .blur, scale: 1.3, intensity: 0.55,
                easeIn: 0.7, easeOut: 0.7)
        ]
        let result = try await ProjectVideoRenderer.export(project: project,
            to: outputDirectory.appendingPathComponent("focus-studio-demo-native.mp4"))
        print("Marketing reel rendered: \(result.duration)s · \(result.width)×\(result.height)")
    }
}
