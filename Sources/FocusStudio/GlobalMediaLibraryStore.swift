import Foundation
import FocusStudioCore

/// A reusable catalog outside every recording folder. Projects receive their
/// own copies when an item is selected, so editing/exporting is self-contained.
actor GlobalMediaLibraryStore {
    enum LibraryError: LocalizedError {
        case assetMissing
        case invalidCatalog

        var errorDescription: String? {
            switch self {
            case .assetMissing: return "This shared media item is no longer available. Refresh the media library."
            case .invalidCatalog: return "The shared media library could not be read safely."
            }
        }
    }

    nonisolated let directory: URL
    private let inspector: ProjectStore
    private let fileManager: FileManager
    private var cachedAssets: [DemoMediaAsset]?

    init(directory: URL, inspector: ProjectStore, fileManager: FileManager = .default) {
        self.directory = directory.standardizedFileURL
        self.inspector = inspector
        self.fileManager = fileManager
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var filesDirectory: URL { directory.appendingPathComponent("files", isDirectory: true) }

    func assets() throws -> [DemoMediaAsset] {
        if let cachedAssets { return cachedAssets }
        try prepare()
        guard fileManager.fileExists(atPath: indexURL.path) else {
            cachedAssets = []
            return []
        }
        let data = try Data(contentsOf: indexURL)
        let stored = try JSONDecoder().decode([DemoMediaAsset].self, from: data)
        let base = directory.resolvingSymlinksInPath().path + "/"
        let resolved: [DemoMediaAsset] = try stored.compactMap { entry in
            guard !entry.filePath.hasPrefix("/"),
                  !entry.filePath.split(separator: "/").contains(".."),
                  entry.filePath.hasPrefix("files/") else { throw LibraryError.invalidCatalog }
            var asset = entry
            let url = directory.appendingPathComponent(entry.filePath).resolvingSymlinksInPath()
            guard url.path.hasPrefix(base) else { throw LibraryError.invalidCatalog }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil // A removed asset is unavailable, but other entries remain usable.
            }
            asset.filePath = url.path
            return asset
        }
        cachedAssets = resolved
        return resolved
    }

    func importFiles(_ urls: [URL]) async throws -> [DemoMediaAsset] {
        let inspected = try await inspector.inspectEditorMedia(from: urls)
        guard !inspected.isEmpty else { return [] }
        let existing = try assets()
        var addedFiles: [URL] = []
        do {
            var added: [DemoMediaAsset] = []
            for var asset in inspected {
                let source = URL(fileURLWithPath: asset.filePath).standardizedFileURL
                let ext = source.pathExtension.isEmpty
                    ? (asset.kind == .image ? "png" : "mp4") : source.pathExtension.lowercased()
                let target = filesDirectory.appendingPathComponent(asset.id.uuidString.lowercased())
                    .appendingPathExtension(ext)
                try fileManager.copyItem(at: source, to: target)
                addedFiles.append(target)
                asset.filePath = target.path
                added.append(asset)
            }
            try save(existing + added)
            cachedAssets = existing + added
            return added
        } catch {
            for file in addedFiles { try? fileManager.removeItem(at: file) }
            throw error
        }
    }

    func urls(for ids: [UUID]) throws -> [URL] {
        let available = try assets()
        return try ids.map { id in
            guard let asset = available.first(where: { $0.id == id }),
                  fileManager.fileExists(atPath: asset.filePath) else { throw LibraryError.assetMissing }
            return URL(fileURLWithPath: asset.filePath)
        }
    }

    private func prepare() throws {
        guard directory.isFileURL else { throw LibraryError.invalidCatalog }
        for url in [directory, filesDirectory] {
            if let type = try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
               type != .typeDirectory { throw LibraryError.invalidCatalog }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func save(_ assets: [DemoMediaAsset]) throws {
        let stored = assets.map { asset -> DemoMediaAsset in
            var copy = asset
            copy.filePath = "files/" + URL(fileURLWithPath: asset.filePath).lastPathComponent
            return copy
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: indexURL, options: .atomic)
    }
}
