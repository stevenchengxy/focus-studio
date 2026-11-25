import CryptoKit
import Foundation

/// The app authenticates the release metadata before it trusts a file name, size, or digest.
struct MacUpdateManifest: Decodable, Sendable {
    let tag: String
    let version: String
    let build: String
    let channel: String
    let assetName: String
    let byteCount: Int64
    let sha256: String
    let signature: String

    fileprivate var signedBytes: Data {
        Data(["Focus Studio macOS update v1", tag, version, build, channel, assetName,
              String(byteCount), sha256, ""].joined(separator: "\n").utf8)
    }
}

enum MacUpdateTrust {
    enum Failure: LocalizedError {
        case metadata, integrity
        var errorDescription: String? {
            switch self {
            case .metadata: return "The update could not be authenticated."
            case .integrity: return "The downloaded update did not pass verification."
            }
        }
    }

    static func fetch(for release: AppUpdateRelease) async throws -> MacUpdateManifest {
        guard let publicKey = Bundle.main.object(forInfoDictionaryKey: "FocusStudioUpdatePublicKey") as? String,
              let keyData = Data(base64Encoded: publicKey) else { throw Failure.metadata }
        let tag = release.releaseURL.lastPathComponent
        guard validTag(tag, for: release) else { throw Failure.metadata }
        let url = URL(string: "https://github.com/stevenchengxy/focus-studio/releases/download/")!
            .appendingPathComponent(tag).appendingPathComponent("mac-update.json")
        let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: url, timeoutInterval: 25))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength <= 8192 else { throw Failure.metadata }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8192 else { throw Failure.metadata }
            data.append(byte)
        }
        return try authenticate(data, release: release, publicKey: keyData)
    }

    private static func validTag(_ tag: String, for release: AppUpdateRelease) -> Bool {
        let base = "v" + release.version
        if release.channel == .stable { return tag == base }
        let prefix = base + "-preview."
        let suffix = tag.dropFirst(prefix.count)
        return tag.hasPrefix(prefix) && !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func authenticate(_ data: Data, release: AppUpdateRelease, publicKey: Data) throws -> MacUpdateManifest {
        let names = ["local", "developer-id", "notarized"].map { "Focus-Studio-\(release.version)-universal-\($0).dmg" }
        guard data.count <= 8192, let item = try? JSONDecoder().decode(MacUpdateManifest.self, from: data),
              item.tag == release.releaseURL.lastPathComponent, validTag(item.tag, for: release),
              item.version == release.version, item.channel == release.channel.rawValue,
              !item.build.isEmpty, item.build.allSatisfy({ $0.isASCII && $0.isNumber }), UInt64(item.build) != nil,
              names.contains(item.assetName), (1024...2_147_483_648).contains(item.byteCount),
              item.sha256.utf8.count == 64, item.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let signature = Data(base64Encoded: item.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: item.signedBytes) else { throw Failure.metadata }
        return item
    }

    static func verify(file: URL, against manifest: MacUpdateManifest) async throws {
        let stream = try FileHandle(forReadingFrom: file)
        defer { try? stream.close() }
        var bytes: Int64 = 0
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try stream.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            bytes += Int64(chunk.count)
            guard bytes <= manifest.byteCount else { throw Failure.integrity }
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard bytes == manifest.byteCount, digest == manifest.sha256 else { throw Failure.integrity }
    }
}
