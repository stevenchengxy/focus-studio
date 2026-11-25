import Foundation

/// The background images Focus Studio ships with.
///
/// Bundled originals are available offline. System wallpapers and imported
/// files are resolved separately.
public struct BackgroundCatalog: Sendable {
    public struct Asset: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var mood: String
        public var relativePath: String
        public var width: Int
        public var height: Int
        public var sha256: String
        public var license: String

        public init(
            id: String,
            title: String,
            mood: String,
            relativePath: String,
            width: Int,
            height: Int,
            sha256: String,
            license: String
        ) {
            self.id = id
            self.title = title
            self.mood = mood
            self.relativePath = relativePath
            self.width = width
            self.height = height
            self.sha256 = sha256
            self.license = license
        }
    }

    public enum CatalogError: Error, Sendable {
        case notFound
    }

    private struct Document: Codable {
        var schemaVersion: Int
        var assets: [Asset]
    }

    public static let bundled = try? loadBundled()

    public let directoryURL: URL
    public let assets: [Asset]

    public init(contentsOf directoryURL: URL) throws {
        let catalogURL = directoryURL.appendingPathComponent("catalog.json", isDirectory: false)
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: catalogURL))
        self.directoryURL = directoryURL
        // Only advertise images that are actually present, so a trimmed bundle
        // degrades to fewer choices instead of dead swatches.
        self.assets = document.assets.filter {
            FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent($0.relativePath).path
            )
        }
    }

    public static func loadBundled(bundle: Bundle = .main) throws -> BackgroundCatalog {
        var candidates: [URL] = []
        if let resourceURL = bundle.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("Backgrounds", isDirectory: true))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Resources/Backgrounds", isDirectory: true)
        )
        for directory in candidates {
            let catalogURL = directory.appendingPathComponent("catalog.json", isDirectory: false)
            if FileManager.default.fileExists(atPath: catalogURL.path) {
                return try BackgroundCatalog(contentsOf: directory)
            }
        }
        throw CatalogError.notFound
    }

    private static let referencePrefix = "focusstudio://background/"

    /// The live editor uses a usable file path. Persist an ID only for files
    /// that actually belong to this catalog, so a project can move to another Mac.
    public func reference(forFilePath path: String?) -> String? {
        guard let path, path.hasPrefix(directoryURL.path + "/"),
              let asset = assets.first(where: { fileURL(for: $0).path == path }) else { return nil }
        return Self.referencePrefix + asset.id
    }

    public func resolveStoredImage(_ path: String?) -> URL? {
        guard let path else { return nil }
        if path.hasPrefix(Self.referencePrefix) {
            let id = path.dropFirst(Self.referencePrefix.count)
            return assets.first(where: { $0.id == id }).map(fileURL(for:))
        }
        // Projects saved before portable IDs used the absolute path inside
        // Focus Studio.app. An imported file with the same name stays external.
        let directory = (path as NSString).deletingLastPathComponent
        guard directory.hasSuffix("/Focus Studio.app/Contents/Resources/Backgrounds") else { return nil }
        let name = (path as NSString).lastPathComponent
        return assets.first(where: { $0.relativePath == name }).map(fileURL(for:))
    }

    public func fileURL(for asset: Asset) -> URL {
        directoryURL.appendingPathComponent(asset.relativePath, isDirectory: false)
    }
}
