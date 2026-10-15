import Foundation

/// SemVer precedence, including prerelease identifiers. Build metadata does not
/// make the same release newer, so restarting never reoffers an identical app.
struct AppSemanticVersion: Comparable, Equatable, Sendable {
    let core: [UInt64]
    let prerelease: [String]

    init?(_ text: String) {
        guard !text.isEmpty, text.count <= 160 else { return nil }
        let buildSplit = text.split(separator: "+", omittingEmptySubsequences: false)
        guard buildSplit.count <= 2 else { return nil }
        func validIdentifier(_ value: Substring) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
        if buildSplit.count == 2 {
            guard buildSplit[1].split(separator: ".", omittingEmptySubsequences: false).allSatisfy(validIdentifier) else { return nil }
        }
        let versionSplit = buildSplit[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let components = versionSplit[0].split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && ($0.count == 1 || !$0.hasPrefix("0")) }),
              components.allSatisfy({ UInt64($0) != nil }) else { return nil }
        core = components.map { UInt64($0)! }
        if versionSplit.count == 2 {
            let identifiers = versionSplit[1].split(separator: ".", omittingEmptySubsequences: false)
            guard identifiers.allSatisfy(validIdentifier), identifiers.allSatisfy({ value in
                !value.utf8.allSatisfy { (48...57).contains($0) } || value.count == 1 || !value.hasPrefix("0")
            }) else { return nil }
            prerelease = identifiers.map(String.init)
        } else { prerelease = [] }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = left.utf8.allSatisfy { (48...57).contains($0) }
            let rightNumeric = right.utf8.allSatisfy { (48...57).contains($0) }
            if leftNumeric != rightNumeric { return leftNumeric }
            if leftNumeric && left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

enum AppUpdateChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case stable, preview
    var id: String { rawValue }
    var title: String { self == .stable ? "Stable releases" : "Preview releases" }
}

enum AppUpdateError: Error, LocalizedError {
    case invalidRelease, invalidInstalledVersion, httpStatus(Int), network
    var errorDescription: String? {
        switch self {
        case .invalidRelease: return "The update service returned invalid release information."
        case .invalidInstalledVersion: return "This app's version could not be checked."
        case let .httpStatus(code): return "The update service returned HTTP \(code)."
        case .network: return "Could not check for updates. Check your connection and try again."
        }
    }
}

struct AppUpdateRelease: Codable, Equatable, Sendable {
    let platform: String
    let version: String
    let channel: AppUpdateChannel
    let title: String
    let publishedAt: String
    let downloadURL: URL
    let releaseURL: URL
    let minimumOS: String

    enum CodingKeys: String, CodingKey {
        case platform, version, channel, title
        case publishedAt = "published_at", downloadURL = "download_url", releaseURL = "release_url", minimumOS = "minimum_os"
    }

    static let websiteHost = "focus-studio.stevenchengxy19.chatgpt.site"

    static func feedURL(channel: AppUpdateChannel) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = websiteHost; parts.path = "/api/releases"
        parts.queryItems = [URLQueryItem(name: "platform", value: "mac"), URLQueryItem(name: "channel", value: channel.rawValue)]
        return parts.url!
    }

    static func decode(_ data: Data, expectedChannel: AppUpdateChannel) throws -> Self {
        guard data.count <= 64 * 1024, let release = try? JSONDecoder().decode(Self.self, from: data) else {
            throw AppUpdateError.invalidRelease
        }
        try release.validate(expectedChannel: expectedChannel)
        return release
    }

    func validate(expectedChannel: AppUpdateChannel) throws {
        func https(_ url: URL, host: String) -> Bool {
            url.scheme == "https" && url.host?.lowercased() == host && (url.port == nil || url.port == 443)
                && url.user == nil && url.password == nil && url.fragment == nil
        }
        let query = URLComponents(url: downloadURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let releaseParts = releaseURL.path.split(separator: "/", omittingEmptySubsequences: false)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractionalDate = formatter.date(from: publishedAt)
        formatter.formatOptions = [.withInternetDateTime]
        guard platform == "mac", (channel == expectedChannel || expectedChannel == .preview && channel == .stable), AppSemanticVersion(version) != nil,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200,
              fractionalDate != nil || formatter.date(from: publishedAt) != nil,
              Self.osComponents(minimumOS) != nil,
              https(downloadURL, host: Self.websiteHost), downloadURL.path == "/api/download/mac",
              query.count == 2, query.filter({ $0.name == "channel" && $0.value == expectedChannel.rawValue }).count == 1,
              query.filter({ $0.name == "version" && $0.value == version }).count == 1,
              https(releaseURL, host: "github.com"), releaseURL.query == nil,
              releaseParts.count == 6, releaseParts[1] == "stevenchengxy", releaseParts[2] == "focus-studio",
              releaseParts[3] == "releases", releaseParts[4] == "tag", !releaseParts[5].isEmpty,
              releaseParts[5] != ".", releaseParts[5] != ".." else { throw AppUpdateError.invalidRelease }
    }

    func isNewer(than installedVersion: String) throws -> Bool {
        guard let installed = AppSemanticVersion(installedVersion), let remote = AppSemanticVersion(version) else {
            throw AppUpdateError.invalidInstalledVersion
        }
        return remote > installed
    }

    func supports(_ os: OperatingSystemVersion) -> Bool {
        guard let minimum = Self.osComponents(minimumOS) else { return false }
        let current = [os.majorVersion, os.minorVersion, os.patchVersion]
        return !current.lexicographicallyPrecedes(minimum)
    }

    private static func osComponents(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return parts.map { Int($0)! } + Array(repeating: 0, count: 3 - parts.count)
    }
}

enum AppUpdateCheckPolicy {
    static let interval: TimeInterval = 24 * 60 * 60
    static func shouldCheck(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed >= interval || elapsed < 0
    }
}
