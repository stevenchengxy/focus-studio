import AVFoundation
import Foundation
import FocusStudioCapture
import FocusStudioCore
import ImageIO

actor ProjectStore {
    enum StoreError: LocalizedError {
        case invalidVideo
        case invalidAudio
        case invalidImage
        case invalidProjectName
        case projectNameTooLong
        case projectNotFound
        case unsafeProjectDirectory
        case invalidProjectMetadata
        case trashDidNotMoveProject

        var errorDescription: String? {
            switch self {
            case .invalidVideo:
                return "The selected file does not contain a readable video track."
            case .invalidAudio:
                return "The selected file does not contain a readable audio track."
            case .invalidImage:
                return "The selected file is not a readable background image."
            case .invalidProjectName:
                return "Please enter a project name."
            case .projectNameTooLong:
                return "Project names must be 120 characters or fewer."
            case .projectNotFound:
                return "The project is no longer available. Refresh the library and try again."
            case .unsafeProjectDirectory:
                return "This project folder is not a regular local project directory. It was not changed."
            case .invalidProjectMetadata:
                return "The project metadata does not match its folder. It was not changed."
            case .trashDidNotMoveProject:
                return "The project could not be moved to Trash. Its files were kept."
            }
        }
    }

    typealias TrashOperation = @Sendable (URL) throws -> Void
    private let fileManager: FileManager
    /// The library root; each project is a `<UUID>/` folder inside it.
    nonisolated let projectsDirectory: URL
    private let trashOperation: TrashOperation?

    private var incomingDirectory: URL {
        projectsDirectory.appendingPathComponent("Incoming", isDirectory: true)
    }

    init(
        fileManager: FileManager = .default,
        projectsDirectory: URL? = nil,
        trashOperation: TrashOperation? = nil
    ) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.projectsDirectory = (projectsDirectory
            ?? support.appendingPathComponent("FocusStudio/Projects", isDirectory: true)).standardizedFileURL
        self.trashOperation = trashOperation
    }

    func prepare() throws {
        guard projectsDirectory.isFileURL else { throw StoreError.unsafeProjectDirectory }
        if let attributes = try? fileManager.attributesOfItem(atPath: projectsDirectory.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw StoreError.unsafeProjectDirectory
            }
        }
        try fileManager.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
    }

    func temporaryRecordingURL() throws -> URL {
        try prepare()
        let recordings = incomingDirectory
        try fileManager.createDirectory(at: recordings, withIntermediateDirectories: true)
        return recordings
            .appendingPathComponent("recording-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
    }

    func projectDirectory(for id: UUID) throws -> URL {
        try prepare()
        let directory = projectsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        if let attributes = try? fileManager.attributesOfItem(atPath: directory.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw StoreError.unsafeProjectDirectory
            }
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try validatedProjectDirectory(for: id)
    }

    func createProject(
        from sourceURL: URL,
        title: String,
        cursorSamples: [CursorSample],
        clickEvents: [ClickEvent],
        typingActivity: [TypingActivity] = [],
        eventDiagnostics: EventMonitorDiagnostics? = nil,
        settings: ProjectSettings = .init()
    ) async throws -> RecordingProject {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StoreError.invalidVideo
        }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = size.applying(transform)
        let width = max(2, Int(abs(transformed.width)).madeEven)
        let height = max(2, Int(abs(transformed.height)).madeEven)

        var project = RecordingProject(
            title: title,
            sourceVideoPath: "raw.mp4",
            duration: duration.isFinite ? duration : 0,
            sourceWidth: width,
            sourceHeight: height,
            cursorSamples: cursorSamples,
            clickEvents: clickEvents,
            settings: settings
        )
        project.typingActivity = typingActivity
        project.zoomSegments = TimelineMath.generateZoomSegments(
            from: clickEvents,
            duration: project.duration,
            settings: settings,
            typingActivity: typingActivity
        )

        let directory = try projectDirectory(for: project.id)
        let targetURL = directory.appendingPathComponent("raw.mp4")
        if sourceURL.standardizedFileURL != targetURL.standardizedFileURL {
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            try fileManager.copyItem(at: sourceURL, to: targetURL)
        }

        if var audio = project.settings.productDemoAudio,
           let musicPath = audio.backgroundMusicPath,
           !musicPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let musicURL = URL(fileURLWithPath: musicPath)
            if fileManager.fileExists(atPath: musicURL.path) {
                audio.backgroundMusicPath = try copyAudioAsset(
                    from: musicURL,
                    into: directory,
                    stem: "background-music"
                ).path
                project.settings.productDemoAudio = audio
            }
        }
        try save(project)
        if let eventDiagnostics {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Numeric counts, registration state, and permission booleans only.
            // Diagnostic failure must not discard a successfully saved video.
            if let data = try? encoder.encode(eventDiagnostics) {
                try? data.write(to: directory.appendingPathComponent("interaction-diagnostics.json"), options: .atomic)
            }
        }
        let incomingPrefix = incomingDirectory.standardizedFileURL.path + "/"
        if sourceURL.standardizedFileURL.path.hasPrefix(incomingPrefix) {
            try? fileManager.removeItem(at: sourceURL)
        }
        project.sourceVideoPath = targetURL.path
        return project
    }

    func save(_ project: RecordingProject) throws {
        let directory = try projectDirectory(for: project.id)
        let metadataURL = directory.appendingPathComponent("project.json")
        if let attributes = try? fileManager.attributesOfItem(atPath: metadataURL.path),
           attributes[.type] as? FileAttributeType != .typeRegular {
            throw StoreError.invalidProjectMetadata
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var persistedProject = project
        if URL(fileURLWithPath: persistedProject.sourceVideoPath).path.hasPrefix("/") {
            persistedProject.sourceVideoPath = URL(fileURLWithPath: persistedProject.sourceVideoPath).lastPathComponent
        }
        if var audio = persistedProject.settings.productDemoAudio {
            audio.backgroundMusicPath = relativeAssetPath(audio.backgroundMusicPath, in: directory)
            audio.clickSoundPath = relativeAssetPath(audio.clickSoundPath, in: directory)
            audio.zoomTransitionSoundPath = relativeAssetPath(audio.zoomTransitionSoundPath, in: directory)
            persistedProject.settings.productDemoAudio = audio
        }
        persistedProject.settings.backgroundImagePath = relativeAssetPath(
            persistedProject.settings.backgroundImagePath,
            in: directory
        )
        try encoder.encode(persistedProject).write(to: metadataURL, options: .atomic)
    }

    func loadProjects() throws -> [RecordingProject] {
        try prepare()
        let directories = try fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return directories.compactMap { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  directory.lastPathComponent == id.uuidString else { return nil }
            return try? loadProject(id: id)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func resolvedVideoURL(for project: RecordingProject) throws -> URL {
        let value = URL(fileURLWithPath: project.sourceVideoPath)
        if value.path.hasPrefix("/") && fileManager.fileExists(atPath: value.path) {
            return value
        }
        return try projectDirectory(for: project.id).appendingPathComponent(project.sourceVideoPath)
    }

    func importBackgroundMusic(from sourceURL: URL, for project: RecordingProject) async throws -> String {
        let asset = AVURLAsset(url: sourceURL)
        guard try await asset.loadTracks(withMediaType: .audio).first != nil else {
            throw StoreError.invalidAudio
        }
        let directory = try projectDirectory(for: project.id)
        return try copyAudioAsset(
            from: sourceURL,
            into: directory,
            stem: "background-music-\(UUID().uuidString.lowercased())"
        ).path
    }

    func importBackgroundImage(from sourceURL: URL, for project: RecordingProject) throws -> String {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { throw StoreError.invalidImage }

        let directory = try projectDirectory(for: project.id)
        let fileExtension = sourceURL.pathExtension.isEmpty
            ? "png"
            : sourceURL.pathExtension.lowercased()
        let targetURL = directory
            .appendingPathComponent("background-\(UUID().uuidString.lowercased())")
            .appendingPathExtension(fileExtension)
        try fileManager.copyItem(at: sourceURL, to: targetURL)
        return targetURL.path
    }

    func delete(_ project: RecordingProject) throws {
        try deleteProject(id: project.id)
    }

    /// Uses only the existing UUID directory, never the video's stored path.
    /// Trash failure is surfaced without a permanent-deletion fallback.
    func deleteProject(id: UUID) throws {
        let directory = try validatedProjectDirectory(for: id)
        _ = try loadProject(id: id)
        if let trashOperation {
            try trashOperation(directory)
        } else {
            try fileManager.trashItem(at: directory, resultingItemURL: nil)
        }
        guard (try? fileManager.attributesOfItem(atPath: directory.path)) == nil else {
            throw StoreError.trashDidNotMoveProject
        }
    }

    /// Reads the latest saved project after the model has flushed editor writes.
    /// Title is metadata only: no folder, movie, assets, or event IDs are renamed.
    func renameProject(id: UUID, to title: String) throws -> RecordingProject {
        let title = try Self.validatedProjectName(title)
        let metadata = try readProjectMetadata(id: id)
        var project = metadata.project
        guard project.title != title else { return resolvedProject(project, in: metadata.directory) }
        // Rename is deliberately not a normal editor save: preserve legacy
        // nested/absolute asset paths and unknown metadata fields verbatim in
        // meaning. Only the title key changes; no media is copied or renamed.
        guard var object = try JSONSerialization.jsonObject(with: metadata.data) as? [String: Any] else {
            throw StoreError.invalidProjectMetadata
        }
        object["title"] = title
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: metadata.directory.appendingPathComponent("project.json"), options: .atomic)
        project.title = title
        return resolvedProject(project, in: metadata.directory)
    }

    nonisolated static func validatedProjectName(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidProjectName }
        guard trimmed.count <= 120 else { throw StoreError.projectNameTooLong }
        return trimmed
    }

    private func validatedProjectDirectory(for id: UUID) throws -> URL {
        guard projectsDirectory.isFileURL else { throw StoreError.unsafeProjectDirectory }
        guard let rootAttributes = try? fileManager.attributesOfItem(atPath: projectsDirectory.path) else {
            throw StoreError.projectNotFound
        }
        guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw StoreError.unsafeProjectDirectory
        }
        let directory = projectsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        guard let attributes = try? fileManager.attributesOfItem(atPath: directory.path) else {
            throw StoreError.projectNotFound
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              directory.deletingLastPathComponent().standardizedFileURL.path == projectsDirectory.path,
              directory.resolvingSymlinksInPath().deletingLastPathComponent().path
                == projectsDirectory.resolvingSymlinksInPath().path else {
            throw StoreError.unsafeProjectDirectory
        }
        return directory
    }

    private func loadProject(id: UUID) throws -> RecordingProject {
        let metadata = try readProjectMetadata(id: id)
        return resolvedProject(metadata.project, in: metadata.directory)
    }

    private func readProjectMetadata(id: UUID) throws -> (project: RecordingProject, data: Data, directory: URL) {
        let directory = try validatedProjectDirectory(for: id)
        let metadataURL = directory.appendingPathComponent("project.json")
        guard let attributes = try? fileManager.attributesOfItem(atPath: metadataURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw StoreError.invalidProjectMetadata
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project: RecordingProject
        let data: Data
        do {
            data = try Data(contentsOf: metadataURL)
            project = try decoder.decode(RecordingProject.self, from: data)
        } catch {
            throw StoreError.invalidProjectMetadata
        }
        guard project.id == id else { throw StoreError.invalidProjectMetadata }
        return (project, data, directory)
    }

    private func resolvedProject(_ stored: RecordingProject, in directory: URL) -> RecordingProject {
        var project = stored
        project.sourceVideoPath = resolvedAssetPath(project.sourceVideoPath, in: directory) ?? project.sourceVideoPath
        if var audio = project.settings.productDemoAudio {
            audio.backgroundMusicPath = resolvedAssetPath(audio.backgroundMusicPath, in: directory)
            audio.clickSoundPath = resolvedAssetPath(audio.clickSoundPath, in: directory)
            audio.zoomTransitionSoundPath = resolvedAssetPath(audio.zoomTransitionSoundPath, in: directory)
            project.settings.productDemoAudio = audio
        }
        project.settings.backgroundImagePath = resolvedAssetPath(project.settings.backgroundImagePath, in: directory)
        return project
    }


    private func copyAudioAsset(from sourceURL: URL, into directory: URL, stem: String) throws -> URL {
        let fileExtension = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension.lowercased()
        let targetURL = directory
            .appendingPathComponent(stem)
            .appendingPathExtension(fileExtension)
        if sourceURL.standardizedFileURL == targetURL.standardizedFileURL {
            return targetURL
        }
        if fileManager.fileExists(atPath: targetURL.path) {
            return targetURL
        }
        try fileManager.copyItem(at: sourceURL, to: targetURL)
        return targetURL
    }

    private func relativeAssetPath(_ path: String?, in directory: URL) -> String? {
        guard let path else { return nil }
        let assetURL = URL(fileURLWithPath: path).standardizedFileURL
        let directoryPath = directory.standardizedFileURL.path + "/"
        guard assetURL.path.hasPrefix(directoryPath) else { return path }
        return String(assetURL.path.dropFirst(directoryPath.count))
    }

    private func resolvedAssetPath(_ path: String?, in directory: URL) -> String? {
        guard let path else { return nil }
        if path.hasPrefix("/") { return path }
        return directory.appendingPathComponent(path).path
    }
}

private extension Int {
    var madeEven: Int { isMultiple(of: 2) ? self : self + 1 }
}
