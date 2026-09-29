import Foundation
import FocusStudioCore

extension ProjectStore {
    /// The first timeline edit branches an immutable source into one working
    /// project. Later edits update only that project's metadata, so dragging
    /// handles does not flood the library with one project per gesture.
    func isVideoEditingCopy(_ id: UUID) throws -> Bool {
        let directory = try projectDirectory(for: id)
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("video-edit-source.json").path)
    }

    func createVideoEditingCopy(from original: RecordingProject, edited: RecordingProject, title: String,
                                importedMedia: [DemoMediaAsset] = []) throws -> RecordingProject {
        let id = UUID()
        let directory = try projectDirectory(for: id)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: directory) } }

        let source = try resolvedVideoURL(for: original)
        let mediaExtension = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let media = directory.appendingPathComponent("raw").appendingPathExtension(mediaExtension)
        try FileManager.default.copyItem(at: source, to: media)

        var project = edited
        project.id = id
        project.title = title
        project.createdAt = Date()
        project.sourceVideoPath = media.path

        let originalDirectory = projectsDirectory.appendingPathComponent(original.id.uuidString, isDirectory: true)
        func copyAsset(_ path: String?, stem: String) throws -> String? {
            guard let path, !path.isEmpty else { return path }
            let source = path.hasPrefix("/") ? URL(fileURLWithPath: path) : originalDirectory.appendingPathComponent(path)
            let target = directory.appendingPathComponent(stem).appendingPathExtension(source.pathExtension)
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
            let workingProjectID: UUID
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Manifest(sourceProjectID: original.id, sourceDuration: original.duration, workingProjectID: id))
            .write(to: directory.appendingPathComponent("video-edit-source.json"), options: .atomic)
        if importedMedia.isEmpty {
            try save(project)
        } else {
            project = try importEditorMedia(importedMedia, into: project)
        }
        committed = true
        return project
    }
}
