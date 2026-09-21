import Foundation

/// Metadata and file lookup for audio shipped with Focus Studio.
///
/// The catalog deliberately lives in FocusStudioCore so both the editor UI and
/// renderer-facing code can share one source of truth without hard-coded file
/// names. `catalog.json` is copied to `Contents/Resources/Audio` by the app
/// build script.
public struct AudioAssetCatalog: Sendable {
    public enum Kind: String, Codable, Sendable {
        case music
        case soundEffect
    }

    public struct Asset: Codable, Hashable, Identifiable, Sendable {
        public let id: String
        public let kind: Kind
        public let title: String
        public let mood: String
        public let relativePath: String
        public let durationSeconds: Double
        public let suggestedVolume: Double
        public let license: String
        public let licenseURL: String?
        public let author: String?
        public let sourcePage: String?
        public let downloadURL: String?
        public let sha256: String?

        public init(
            id: String,
            kind: Kind,
            title: String,
            mood: String,
            relativePath: String,
            durationSeconds: Double,
            suggestedVolume: Double,
            license: String,
            licenseURL: String? = nil,
            author: String? = nil,
            sourcePage: String? = nil,
            downloadURL: String? = nil,
            sha256: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.mood = mood
            self.relativePath = relativePath
            self.durationSeconds = durationSeconds
            self.suggestedVolume = suggestedVolume
            self.license = license
            self.licenseURL = licenseURL
            self.author = author
            self.sourcePage = sourcePage
            self.downloadURL = downloadURL
            self.sha256 = sha256
        }
    }

    private struct Document: Codable {
        let schemaVersion: Int
        let assets: [Asset]
    }

    public enum CatalogError: Error, LocalizedError {
        case notFound
        case unsupportedSchema(Int)
        case missingAsset(String)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "The bundled audio catalog could not be found."
            case .unsupportedSchema(let version):
                return "The audio catalog schema version \(version) is not supported."
            case .missingAsset(let path):
                return "The audio catalog references a missing asset: \(path)"
            }
        }
    }

    public let assets: [Asset]
    public let directoryURL: URL

    public var music: [Asset] {
        assets.filter { $0.kind == .music }
    }

    public var soundEffects: [Asset] {
        assets.filter { $0.kind == .soundEffect }
    }

    public init(contentsOf directoryURL: URL, validateFiles: Bool = true) throws {
        let catalogURL = directoryURL.appendingPathComponent("catalog.json", isDirectory: false)
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: catalogURL))
        guard document.schemaVersion == 1 else {
            throw CatalogError.unsupportedSchema(document.schemaVersion)
        }

        if validateFiles {
            for asset in document.assets {
                let url = directoryURL.appendingPathComponent(asset.relativePath, isDirectory: false)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw CatalogError.missingAsset(asset.relativePath)
                }
            }
        }

        self.assets = document.assets
        self.directoryURL = directoryURL
    }

    /// Loads from an app bundle first and the repository resource directory
    /// second, which also makes command-line development builds convenient.
    public static func loadBundled(bundle: Bundle = .main) throws -> AudioAssetCatalog {
        var candidates: [URL] = []
        if let resourceURL = bundle.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("Audio", isDirectory: true))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Resources/Audio", isDirectory: true)
        )

        for directory in candidates {
            let catalogURL = directory.appendingPathComponent("catalog.json", isDirectory: false)
            if FileManager.default.fileExists(atPath: catalogURL.path) {
                return try AudioAssetCatalog(contentsOf: directory)
            }
        }
        throw CatalogError.notFound
    }

    public func asset(id: String) -> Asset? {
        assets.first { $0.id == id }
    }

    public func fileURL(for asset: Asset) -> URL {
        directoryURL.appendingPathComponent(asset.relativePath, isDirectory: false)
    }
}
