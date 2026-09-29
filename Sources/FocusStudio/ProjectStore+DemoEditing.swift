import Foundation
import FocusStudioCore

extension ProjectStore {
    /// Materialize a derived raw video, then atomically publish its metadata.
    /// The original project and assets are only read, never moved or rewritten.
    func createDemoCut(from original: RecordingProject, keepRanges: [DemoKeepRange], title: String?) async throws -> RecordingProject {
        let edit = try DemoTimelineEdit(keepRanges: keepRanges, sourceDuration: original.duration)
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? original.title + " — Edited"
        guard !resolvedTitle.isEmpty else { throw StoreError.invalidProjectName }
        guard resolvedTitle.count <= 120 else { throw StoreError.projectNameTooLong }
        let id = UUID()
        let directory = try projectDirectory(for: id)
        let source = try resolvedVideoURL(for: original)
        let videoTimeline = original.videoClips == nil ? nil : try DemoVideoTimeline(project: original)
        let movieExtension = videoTimeline == nil ? "mov" : (source.pathExtension.isEmpty ? "mov" : source.pathExtension)
        let movie = directory.appendingPathComponent("raw").appendingPathExtension(movieExtension)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: directory) } }
        if videoTimeline == nil {
            try await DemoCutExporter.export(sourceURL: source, edit: edit, to: movie)
        } else {
            // The source movie of a clip timeline is immutable and may be
            // longer than its edited runtime. Keep it intact; the new clip map
            // selects the requested output-time ranges during preview/export.
            try FileManager.default.copyItem(at: source, to: movie)
        }
        try Task.checkCancellation()
        var project = edit.remap(original, id: id, title: resolvedTitle, sourceVideoPath: movie.path)
        if let videoTimeline {
            let clipped = try videoTimeline.clipped(to: edit)
            project.videoClips = clipped.clips
            project.videoTransitions = clipped.transitions
            project.videoSourceDuration = clipped.sourceDuration
            project.duration = clipped.duration
        }
        let originalDirectory = projectsDirectory.appendingPathComponent(original.id.uuidString, isDirectory: true)
        func copyAsset(_ path: String?, stem: String) throws -> String? {
            guard let path, !path.isEmpty else { return path }
            let source = path.hasPrefix("/") ? URL(fileURLWithPath: path) : originalDirectory.appendingPathComponent(path)
            let target = directory.appendingPathComponent(stem).appendingPathExtension(source.pathExtension)
            // Missing dependencies fail the derived edit rather than silently
            // changing its look or leaving it dependent on the old project.
            try FileManager.default.copyItem(at: source, to: target)
            return target.path
        }
        project.settings.backgroundImagePath = try copyAsset(project.settings.backgroundImagePath, stem: "background")
        if var audio = project.settings.productDemoAudio {
            audio.backgroundMusicPath = try copyAsset(audio.backgroundMusicPath, stem: "background-music")
            audio.clickSoundPath = try copyAsset(audio.clickSoundPath, stem: "click-sound")
            audio.zoomTransitionSoundPath = try copyAsset(audio.zoomTransitionSoundPath, stem: "zoom-sound")
            project.settings.productDemoAudio = audio
        }
        project.mediaAssets = try copyEditorMediaAssets(from: original, to: directory)
        struct Manifest: Encodable {
            let sourceProjectID: UUID
            let sourceDuration: Double
            let keepRanges: [DemoKeepRange]
            let editedDuration: Double
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Manifest(sourceProjectID: original.id, sourceDuration: original.duration, keepRanges: edit.ranges, editedDuration: edit.duration)).write(to: directory.appendingPathComponent("edit-source.json"), options: .atomic)
        try Task.checkCancellation()
        try save(project)
        committed = true
        return project
    }
}
