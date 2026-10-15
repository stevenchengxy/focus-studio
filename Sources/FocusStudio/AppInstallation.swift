import CryptoKit
import Darwin
import Foundation

struct AppInstallationError: LocalizedError {
    let key: String
    var detail: String? = nil
    var errorDescription: String? { [key, detail].compactMap { $0 }.joined(separator: "\n") }
}

/// Numeric components, not lexicographic strings: 1.10 is newer than 1.9.
struct AppRelease: Equatable, Comparable, Sendable {
    let version: String
    let build: String
    private let versionParts: [UInt64]
    private let buildParts: [UInt64]

    init(version: String, build: String) throws {
        func parse(_ value: String) throws -> [UInt64] {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 8,
                  parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
                  parts.allSatisfy({ UInt64($0) != nil }) else {
                throw AppInstallationError(key: "The app has an invalid version or build number.")
            }
            var numbers = parts.map { UInt64($0)! }
            while numbers.count > 1 && numbers.last == 0 { numbers.removeLast() }
            return numbers
        }
        self.version = version
        self.build = build
        versionParts = try parse(version)
        buildParts = try parse(build)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.versionParts == rhs.versionParts && lhs.buildParts == rhs.buildParts
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        func comparison(_ lhs: [UInt64], _ rhs: [UInt64]) -> Int {
            for index in 0..<max(lhs.count, rhs.count) {
                let a = index < lhs.count ? lhs[index] : 0
                let b = index < rhs.count ? rhs[index] : 0
                if a != b { return a < b ? -1 : 1 }
            }
            return 0
        }
        let version = comparison(lhs.versionParts, rhs.versionParts)
        return version == 0 ? comparison(lhs.buildParts, rhs.buildParts) < 0 : version < 0
    }
}

struct InstalledApp: Sendable {
    let url: URL
    let release: AppRelease
    let fingerprint: String
}

struct AppInstallationResult: Sendable {
    let app: InstalledApp
    let backupURL: URL?
    let didInstall: Bool
    var backupURLs: [URL] = []
    var replacedApps: [InstalledApp] = []
}

/// Shared by the native installation panel and the explicit command-line installer.
/// Only discovers top-level application bundles in the configured Applications
/// folders. Never kills apps, modifies user projects, or downloads updates.
struct AppInstaller: @unchecked Sendable {
    static let canonicalURL = URL(fileURLWithPath: "/Applications/Focus Studio.app", isDirectory: true)
    let destination: URL
    let searchDirectories: [URL]
    let validateSignature: @Sendable (URL) throws -> Void
    let isRunning: @Sendable (URL) -> Bool
    let prepareVerifiedCopy: @Sendable (URL, InstalledApp) throws -> Void
    let verifyAfterReplacement: @Sendable (URL) throws -> Void
    private let files = FileManager.default

    init(
        destination: URL = Self.canonicalURL,
        searchDirectories: [URL]? = nil,
        validateSignature: @escaping @Sendable (URL) throws -> Void = { try Self.checkSignature($0) },
        isRunning: @escaping @Sendable (URL) -> Bool,
        prepareVerifiedCopy: @escaping @Sendable (URL, InstalledApp) throws -> Void = { _, _ in },
        verifyAfterReplacement: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.destination = destination.standardizedFileURL
        // An isolated/custom destination must never discover real installations.
        self.searchDirectories = (searchDirectories ?? (destination.standardizedFileURL.path == Self.canonicalURL.path ? [
            Self.canonicalURL.deletingLastPathComponent(),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ] : [destination.deletingLastPathComponent()])).map(\.standardizedFileURL)
        self.validateSignature = validateSignature
        self.isRunning = isRunning
        self.prepareVerifiedCopy = prepareVerifiedCopy
        self.verifyAfterReplacement = verifyAfterReplacement
    }

    func inspect(_ appURL: URL) throws -> InstalledApp {
        let url = appURL.standardizedFileURL
        guard url.isFileURL, url.pathExtension == "app", try isRegularDirectory(url) else {
            throw AppInstallationError(key: "Choose a valid Focus Studio app bundle.")
        }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let executable = url.appendingPathComponent("Contents/MacOS/FocusStudio")
        guard try isRegularFile(infoURL), try isRegularFile(executable),
              let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.local.focusstudio",
              info["CFBundleExecutable"] as? String == "FocusStudio",
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else {
            throw AppInstallationError(key: "Choose a valid Focus Studio app bundle.")
        }
        let release = try AppRelease(version: version, build: build)
        try validateSignature(url)
        var hasher = SHA256()
        for file in [infoURL, executable, url.appendingPathComponent("Contents/_CodeSignature/CodeResources")] {
            if files.fileExists(atPath: file.path) { hasher.update(data: try Data(contentsOf: file)) }
        }
        return InstalledApp(url: url, release: release, fingerprint: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Names are not identity: renamed Focus Studio bundles are included, while
    /// unrelated applications and symbolic links are left alone. A matching but
    /// invalid bundle fails inspection instead of being silently overwritten.
    func discoverInstalledApps(excluding sourceURL: URL? = nil) throws -> [InstalledApp] {
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        if let sourceURL { seen.insert(identityPath(sourceURL)) }
        if itemExists(destination) {
            guard try isRegularDirectory(destination) else {
                throw AppInstallationError(key: "Choose a valid Focus Studio app bundle.")
            }
            if seen.insert(identityPath(destination)).inserted { apps.append(try inspect(destination)) }
        }
        for directory in searchDirectories where itemExists(directory) {
            guard try isRegularDirectory(directory) else { continue }
            for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                guard url.pathExtension == "app", !seen.contains(identityPath(url)),
                      try isRegularDirectory(url), hasExpectedIdentity(url) else { continue }
                seen.insert(identityPath(url))
                apps.append(try inspect(url))
            }
        }
        return apps
    }

    func install(from sourceURL: URL, preservingRunningSource: URL? = nil, reinstallIdenticalCopy: Bool = false) throws -> AppInstallationResult {
        let parent = destination.deletingLastPathComponent()
        guard destination.isFileURL, destination.lastPathComponent == "Focus Studio.app",
              try isRegularDirectory(parent), files.isWritableFile(atPath: parent.path) else {
            throw AppInstallationError(key: "The Applications folder is not writable. Ask an administrator to install this app.")
        }
        // Atomic cross-process lock. Do not silently remove a lock left by another
        // process; an interrupted installation needs an explicit recovery review.
        let lock = parent.appendingPathComponent(".focusstudio-install.lock", isDirectory: true)
        guard mkdir(lock.path, 0o700) == 0 else {
            throw AppInstallationError(key: "Another installation is in progress. If it was interrupted, review the installation lock before retrying.", detail: lock.path)
        }
        defer { try? files.removeItem(at: lock) }
        let source = try inspect(sourceURL)
        let discovered = try discoverInstalledApps(excluding: source.url)
        let existing = discovered.first(where: { identityPath($0.url) == identityPath(destination) }) ??
            (identityPath(source.url) == identityPath(destination) ? source : nil)
        var installations = discovered
        if let existing, !installations.contains(where: { identityPath($0.url) == identityPath(existing.url) }) {
            installations.append(existing)
        }
        for app in installations {
            guard source.release >= app.release else {
                throw AppInstallationError(key: "A newer version is already installed. Downgrades are not allowed.", detail: app.url.path)
            }
            if source.release == app.release {
                guard source.fingerprint == app.fingerprint else {
                    throw AppInstallationError(key: "This version and build are already installed with different contents. Use a newer build to update.", detail: app.url.path)
                }
            }
        }
        // A user-approved self-install can repair an identical but quarantined
        // destination by staging again. Never rewrite the source in place.
        let replaceDestination = existing?.fingerprint != source.fingerprint ||
            (reinstallIdenticalCopy && identityPath(source.url) != identityPath(destination))
        let preservedPath = preservingRunningSource.map(identityPath)
        // The UI may be running from an older per-user bundle while reusing a
        // newer canonical app. Keep that live source until launch handoff exits
        // it; it still participates in every version and integrity check above.
        let replacements = installations.filter {
            identityPath($0.url) != identityPath(source.url) &&
            identityPath($0.url) != preservedPath &&
            (identityPath($0.url) != identityPath(destination) || replaceDestination)
        }
        if replaceDestination, identityPath(destination) == preservedPath {
            throw AppInstallationError(key: "Quit the installed Focus Studio first. A running app will never be replaced.", detail: destination.path)
        }
        if !replaceDestination, replacements.isEmpty, let existing {
            return AppInstallationResult(app: existing, backupURL: nil, didInstall: false)
        }
        func requireStoppedCopies() throws {
            for app in replacements where isRunning(app.url) {
                throw AppInstallationError(key: "Quit the installed Focus Studio first. A running app will never be replaced.", detail: app.url.path)
            }
            if replaceDestination, isRunning(destination) {
                throw AppInstallationError(key: "Quit the installed Focus Studio first. A running app will never be replaced.", detail: destination.path)
            }
        }
        try requireStoppedCopies()
        for app in replacements where !files.isWritableFile(atPath: app.url.deletingLastPathComponent().path) {
            throw AppInstallationError(key: "The Applications folder is not writable. Ask an administrator to install this app.", detail: app.url.path)
        }
        let stage = parent.appendingPathComponent(".focusstudio-install-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let candidate = stage.appendingPathComponent("Focus Studio.app", isDirectory: true)
        let backups = replacements.enumerated().map { index, app in
            (app: app, url: stage.appendingPathComponent(index == 0 ? "previous.bundle" : "previous-\(index).bundle", isDirectory: true))
        }
        var preserveStage = false
        defer { if !preserveStage { try? files.removeItem(at: stage) } }
        if replaceDestination {
            try files.copyItem(at: source.url, to: candidate)
            let copied = try inspect(candidate)
            guard copied.release == source.release, copied.fingerprint == source.fingerprint else {
                throw AppInstallationError(key: "The copied app did not match its source. The installed app was not changed.")
            }
            try prepareVerifiedCopy(candidate, source)
            let prepared = try inspect(candidate)
            guard prepared.release == source.release, prepared.fingerprint == source.fingerprint else {
                throw AppInstallationError(key: "The copied app did not match its source. The installed app was not changed.")
            }
        }
        // Preserve the original locations even if the process is interrupted.
        let recovery = backups.map { ["originalPath": $0.app.url.path, "backupName": $0.url.lastPathComponent,
                                      "version": $0.app.release.version, "build": $0.app.release.build] }
        try PropertyListSerialization.data(fromPropertyList: recovery, format: .xml, options: 0)
            .write(to: stage.appendingPathComponent("recovery.plist"), options: .atomic)
        // Re-discover as well as re-verify: another copy may have appeared or been
        // upgraded while the candidate was copying. No old app has moved yet.
        try requireStoppedCopies()
        func snapshot(_ apps: [InstalledApp]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: apps.map { (identityPath($0.url), $0.fingerprint) })
        }
        guard try snapshot(discoverInstalledApps(excluding: source.url)) == snapshot(discovered) else {
            throw AppInstallationError(key: "The installed app changed during installation. Please retry.")
        }
        if let existing, identityPath(existing.url) == identityPath(source.url) {
            guard try inspect(destination).fingerprint == existing.fingerprint else {
                throw AppInstallationError(key: "The installed app changed during installation. Please retry.")
            }
        }
        try requireStoppedCopies()
        var movedBackups: [(app: InstalledApp, url: URL)] = []
        var movedCandidate = false
        do {
            for backup in backups {
                try requireStoppedCopies()
                try files.moveItem(at: backup.app.url, to: backup.url)
                movedBackups.append(backup)
            }
            if replaceDestination {
                try files.moveItem(at: candidate, to: destination)
                movedCandidate = true
            }
            let installed = try inspect(destination)
            try verifyAfterReplacement(destination)
            guard installed.fingerprint == source.fingerprint else {
                throw AppInstallationError(key: "The installed app failed verification.")
            }
            // Keep every replaced bundle recoverable without leaving additional
            // launchable *.app copies in either Applications folder.
            preserveStage = !movedBackups.isEmpty
            return AppInstallationResult(app: installed, backupURL: movedBackups.first?.url, didInstall: true,
                                         backupURLs: movedBackups.map(\.url), replacedApps: movedBackups.map(\.app))
        } catch {
            var rollbackFailed = false
            do {
                if movedCandidate { try files.moveItem(at: destination, to: stage.appendingPathComponent("rejected.bundle")) }
            } catch { rollbackFailed = true }
            for backup in movedBackups.reversed() {
                do { try files.moveItem(at: backup.url, to: backup.app.url) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed {
                preserveStage = true
                throw AppInstallationError(key: "Installation could not be rolled back automatically. Your previous app is preserved in the recovery folder.", detail: stage.path)
            }
            throw error
        }
    }

    private func identityPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func itemExists(_ url: URL) -> Bool {
        (try? files.attributesOfItem(atPath: url.path)) != nil
    }

    private func hasExpectedIdentity(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return false }
        return info["CFBundleIdentifier"] as? String == "com.local.focusstudio" &&
            info["CFBundleExecutable"] as? String == "FocusStudio"
    }

    private func isRegularDirectory(_ url: URL) throws -> Bool {
        try files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory
    }

    private func isRegularFile(_ url: URL) throws -> Bool {
        try files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular
    }

    /// Only for explicit self-installation by the currently running bundle that
    /// the user already opened through Gatekeeper. Signature verification is a
    /// separate prerequisite, not a substitute for that user-approved launch.
    /// This prepares only a verified staging copy; it does not change Gatekeeper
    /// settings, the original download, or any application outside that copy.
    static func prepareVerifiedSelfCopyForLaunch(_ candidate: URL) throws {
        let files = FileManager.default
        let root = candidate.standardizedFileURL
        let stage = root.deletingLastPathComponent()
        let failureKey = "The verified app copy could not be prepared for launch. The installed app was not changed."
        guard root.isFileURL, root.lastPathComponent == "Focus Studio.app",
              stage.lastPathComponent.hasPrefix(".focusstudio-install-"),
              try files.attributesOfItem(atPath: stage.path)[.type] as? FileAttributeType == .typeDirectory,
              try files.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw AppInstallationError(key: failureKey, detail: root.path)
        }
        let boundary = root.resolvingSymlinksInPath().path
        var pending = [root]
        while let url = pending.popLast() {
            let type = try files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            // Never traverse a link or alter its external target, even if a
            // signed bundle legitimately contains symlinked resources.
            if type == .typeSymbolicLink { continue }
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved == boundary || resolved.hasPrefix(boundary + "/") else {
                throw AppInstallationError(key: failureKey, detail: url.path)
            }
            if Darwin.removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0 {
                let failure = errno
                guard failure == ENOATTR else {
                    throw AppInstallationError(key: failureKey, detail: "\(url.path)\n\(String(cString: strerror(failure)))")
                }
            }
            if type == .typeDirectory {
                pending.append(contentsOf: try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))
            }
        }
    }

    static func checkSignature(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppInstallationError(key: "The app signature could not be verified. Download a fresh copy from a trusted source.")
        }
        // Foundation reads the Mach-O architectures without requiring Xcode's
        // command-line tools on a customer's Mac.
        #if arch(arm64)
        let hostArchitecture = 0x0100000c // CPU_TYPE_ARM64
        #else
        let hostArchitecture = 0x01000007 // CPU_TYPE_X86_64
        #endif
        guard Bundle(url: url)?.executableArchitectures?.contains(NSNumber(value: hostArchitecture)) == true else {
            throw AppInstallationError(key: "This app does not support this Mac's processor architecture.")
        }
    }
}
