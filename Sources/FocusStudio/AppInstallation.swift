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
}

/// Shared by the native installation panel and the explicit command-line installer.
/// Never searches the disk, kills apps, modifies user projects, or downloads updates.
struct AppInstaller: @unchecked Sendable {
    static let canonicalURL = URL(fileURLWithPath: "/Applications/Focus Studio.app", isDirectory: true)
    let destination: URL
    let validateSignature: @Sendable (URL) throws -> Void
    let isRunning: @Sendable (URL) -> Bool
    let verifyAfterReplacement: @Sendable (URL) throws -> Void
    private let files = FileManager.default

    init(
        destination: URL = Self.canonicalURL,
        validateSignature: @escaping @Sendable (URL) throws -> Void = { try Self.checkSignature($0) },
        isRunning: @escaping @Sendable (URL) -> Bool,
        verifyAfterReplacement: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.destination = destination.standardizedFileURL
        self.validateSignature = validateSignature
        self.isRunning = isRunning
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

    func install(from sourceURL: URL) throws -> AppInstallationResult {
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
        let existing: InstalledApp?
        if files.fileExists(atPath: destination.path) || (try? files.attributesOfItem(atPath: destination.path)) != nil {
            existing = try inspect(destination)
        } else { existing = nil }
        if let existing {
            guard source.release >= existing.release else {
                throw AppInstallationError(key: "A newer version is already installed. Downgrades are not allowed.")
            }
            if source.release == existing.release {
                guard source.fingerprint == existing.fingerprint else {
                    throw AppInstallationError(key: "This version and build are already installed with different contents. Use a newer build to update.")
                }
                return AppInstallationResult(app: existing, backupURL: nil, didInstall: false)
            }
        }
        guard !isRunning(destination) else {
            throw AppInstallationError(key: "Quit the installed Focus Studio first. A running app will never be replaced.")
        }
        let stage = parent.appendingPathComponent(".focusstudio-install-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        let candidate = stage.appendingPathComponent("Focus Studio.app", isDirectory: true)
        let backup = stage.appendingPathComponent("previous.bundle", isDirectory: true)
        var preserveStage = false
        defer { if !preserveStage { try? files.removeItem(at: stage) } }
        try files.copyItem(at: source.url, to: candidate)
        let copied = try inspect(candidate)
        guard copied.release == source.release, copied.fingerprint == source.fingerprint else {
            throw AppInstallationError(key: "The copied app did not match its source. The installed app was not changed.")
        }
        // A user could open or update the destination while copying. Check again
        // immediately before replacing anything, while our installation lock holds.
        guard !isRunning(destination) else {
            throw AppInstallationError(key: "Quit the installed Focus Studio first. A running app will never be replaced.")
        }
        if let existing {
            guard try inspect(destination).fingerprint == existing.fingerprint else {
                throw AppInstallationError(key: "The installed app changed during installation. Please retry.")
            }
        } else if files.fileExists(atPath: destination.path) {
            throw AppInstallationError(key: "The installed app changed during installation. Please retry.")
        }
        // The final signature/hash verification itself takes time. Recheck after
        // it, immediately before the rename transaction, not only before it.
        guard !isRunning(destination) else {
            throw AppInstallationError(key: "Quit the installed Focus Studio first. A running app will never be replaced.")
        }
        var movedPrevious = false
        var movedCandidate = false
        do {
            if existing != nil {
                try files.moveItem(at: destination, to: backup)
                movedPrevious = true
            }
            try files.moveItem(at: candidate, to: destination)
            movedCandidate = true
            let installed = try inspect(destination)
            try verifyAfterReplacement(destination)
            guard installed.fingerprint == source.fingerprint else {
                throw AppInstallationError(key: "The installed app failed verification.")
            }
            // Keep the previous bundle recoverable, but not as another launchable
            // *.app in Spotlight. No old copies elsewhere are removed.
            preserveStage = movedPrevious
            return AppInstallationResult(app: installed, backupURL: movedPrevious ? backup : nil, didInstall: true)
        } catch {
            do {
                if movedCandidate { try files.moveItem(at: destination, to: stage.appendingPathComponent("rejected.bundle")) }
                if movedPrevious { try files.moveItem(at: backup, to: destination) }
            } catch {
                preserveStage = true
                throw AppInstallationError(key: "Installation could not be rolled back automatically. Your previous app is preserved in the recovery folder.", detail: stage.path)
            }
            throw error
        }
    }

    private func isRegularDirectory(_ url: URL) throws -> Bool {
        try files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory
    }

    private func isRegularFile(_ url: URL) throws -> Bool {
        try files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular
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
        let architecture = Process()
        architecture.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        #if arch(arm64)
        let hostArchitecture = "arm64"
        #else
        let hostArchitecture = "x86_64"
        #endif
        architecture.arguments = [url.appendingPathComponent("Contents/MacOS/FocusStudio").path, "-verify_arch", hostArchitecture]
        architecture.standardOutput = FileHandle.nullDevice
        architecture.standardError = FileHandle.nullDevice
        try architecture.run()
        architecture.waitUntilExit()
        guard architecture.terminationStatus == 0 else {
            throw AppInstallationError(key: "This app does not support this Mac's processor architecture.")
        }
    }
}
