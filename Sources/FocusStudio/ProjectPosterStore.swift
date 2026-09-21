import AppKit
import AVFoundation
import FocusStudioCore

/// Styled poster frames for the project library, rendered through the same
/// composition as preview and export so cards show the real demo look
/// (background, padding, zoom). Posters stay in memory and are regenerated
/// whenever a project's look changes.
@MainActor
final class ProjectPosterStore: ObservableObject {
    static let shared = ProjectPosterStore()

    private struct Entry {
        var lookHash: Int
        var image: NSImage
    }

    @Published private var entries: [UUID: Entry] = [:]
    private var inFlight: Set<UUID> = []

    func poster(for project: RecordingProject) -> NSImage? {
        guard let entry = entries[project.id], entry.lookHash == Self.lookHash(project) else { return nil }
        return entry.image
    }

    func requestPoster(for project: RecordingProject) {
        let hash = Self.lookHash(project)
        if let entry = entries[project.id], entry.lookHash == hash { return }
        guard !inFlight.contains(project.id) else { return }
        inFlight.insert(project.id)
        let id = project.id
        Task.detached(priority: .utility) {
            let image = await Self.render(project)
            await MainActor.run {
                self.inFlight.remove(id)
                if let image { self.entries[id] = Entry(lookHash: hash, image: image) }
            }
        }
    }

    private static func lookHash(_ project: RecordingProject) -> Int {
        var hasher = Hasher()
        hasher.combine(project.settings)
        hasher.combine(project.sourceVideoPath)
        hasher.combine(project.zoomSegments.count)
        hasher.combine(project.duration)
        return hasher.finalize()
    }

    /// Picks a frame shortly after the first zoom settles, or one tenth in.
    private nonisolated static func posterTime(for project: RecordingProject) -> Double {
        let duration = max(0, project.duration)
        guard duration > 0.2 else { return 0 }
        if let zoom = project.zoomSegments.first(where: { $0.isEnabled }) {
            let timing = ZoomTiming.resolve(zoom, settings: project.settings)
            let candidate = timing.start + timing.easeIn + min(timing.hold, 0.3)
            if candidate < duration - 0.05 { return candidate }
        }
        return min(duration * 0.12, duration - 0.05)
    }

    private nonisolated static func render(_ project: RecordingProject) async -> NSImage? {
        var poster = project
        // Cards are small: render at a modest width to keep the library snappy.
        poster.settings.exportWidth = 960
        guard let prepared = try? await ProjectVideoRenderer.prepare(project: poster) else { return nil }
        let generator = AVAssetImageGenerator(asset: prepared.asset)
        generator.videoComposition = prepared.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        let time = CMTime(seconds: posterTime(for: project), preferredTimescale: 600)
        guard let (image, _) = try? await generator.image(at: time) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
