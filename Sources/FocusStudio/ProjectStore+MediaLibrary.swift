import AVFoundation
import Foundation
import FocusStudioCore
import ImageIO
import UniformTypeIdentifiers

extension ProjectStore {
    /// Inspect every file before creating an editable project. A bad item in a
    /// multi-file import therefore cannot publish a half-filled media library.
    func inspectEditorMedia(from urls: [URL]) async throws -> [DemoMediaAsset] {
        guard !urls.isEmpty, urls.count <= 64 else { throw StoreError.invalidVideo }
        var inspected: [DemoMediaAsset] = []
        inspected.reserveCapacity(urls.count)
        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            guard url.isFileURL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw StoreError.invalidVideo
            }
            let title = url.deletingPathExtension().lastPathComponent
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            if type?.conforms(to: .image) == true {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      CGImageSourceGetCount(source) > 0,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0 else { throw StoreError.invalidImage }
                inspected.append(DemoMediaAsset(title: title, filePath: url.path,
                                                kind: .image, duration: 0, width: width, height: height))
                continue
            }
            let movie = AVURLAsset(url: url)
            guard let track = try? await movie.loadTracks(withMediaType: .video).first,
                  let duration = try? await movie.load(.duration).seconds,
                  duration.isFinite, duration >= 0.1,
                  let naturalSize = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform) else {
                throw StoreError.invalidVideo
            }
            let transformed = naturalSize.applying(transform)
            let width = Int(abs(transformed.width).rounded())
            let height = Int(abs(transformed.height).rounded())
            guard width > 0, height > 0 else { throw StoreError.invalidVideo }
            inspected.append(DemoMediaAsset(title: title, filePath: url.path,
                                            kind: .video, duration: duration, width: width, height: height))
        }
        return inspected
    }

    /// Own local copies of imported files so the editor, Codex tools and
    /// exported project continue to work after the original file is moved.
    func importEditorMedia(_ inspected: [DemoMediaAsset], into project: RecordingProject) throws -> RecordingProject {
        guard !inspected.isEmpty else { return project }
        let directory = try projectDirectory(for: project.id)
        let mediaDirectory = directory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        var addedURLs: [URL] = []
        do {
            var updated = project
            var assets = updated.mediaAssets ?? []
            for var asset in inspected {
                let source = URL(fileURLWithPath: asset.filePath).standardizedFileURL
                let fileExtension = source.pathExtension.isEmpty
                    ? (asset.kind == .image ? "png" : "mp4") : source.pathExtension.lowercased()
                let target = mediaDirectory.appendingPathComponent(asset.id.uuidString.lowercased())
                    .appendingPathExtension(fileExtension)
                guard !FileManager.default.fileExists(atPath: target.path) else {
                    throw StoreError.invalidProjectMetadata
                }
                try FileManager.default.copyItem(at: source, to: target)
                addedURLs.append(target)
                asset.filePath = target.path
                assets.append(asset)
            }
            updated.mediaAssets = assets
            try save(updated)
            return updated
        } catch {
            for url in addedURLs { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// Carry every referenced asset into a derived working project. The clip
    /// IDs and asset IDs stay stable while paths switch to the new folder.
    func copyEditorMediaAssets(from sourceProject: RecordingProject, to targetDirectory: URL) throws -> [DemoMediaAsset]? {
        guard let sourceAssets = sourceProject.mediaAssets, !sourceAssets.isEmpty else {
            return sourceProject.mediaAssets
        }
        let mediaDirectory = targetDirectory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let sourceDirectory = projectsDirectory.appendingPathComponent(sourceProject.id.uuidString, isDirectory: true)
        return try sourceAssets.map { original in
            var asset = original
            let source = original.filePath.hasPrefix("/")
                ? URL(fileURLWithPath: original.filePath)
                : sourceDirectory.appendingPathComponent(original.filePath)
            let fileExtension = source.pathExtension.isEmpty
                ? (original.kind == .image ? "png" : "mp4") : source.pathExtension
            let target = mediaDirectory.appendingPathComponent(original.id.uuidString.lowercased())
                .appendingPathExtension(fileExtension)
            try FileManager.default.copyItem(at: source, to: target)
            asset.filePath = target.path
            return asset
        }
    }
}
