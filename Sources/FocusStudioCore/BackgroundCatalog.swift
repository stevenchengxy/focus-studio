import Foundation

/// The background images Focus Studio ships with.
///
/// Every image is output of `scripts/generate-background-assets.swift`, so the
/// app can offer a full set of demo backgrounds without reading, copying or
/// redistributing anyone else's artwork. Wallpapers already installed on the
/// user's Mac remain available separately; those are only ever referenced by
/// path and are never bundled.
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

    public func fileURL(for asset: Asset) -> URL {
        directoryURL.appendingPathComponent(asset.relativePath, isDirectory: false)
    }
}
