import AppKit
import Darwin
import Foundation

/// Both the app and its preinstalled helper compile this transaction. The candidate
/// stays on the destination volume, so replacement and recovery each require one
/// atomic exchange, even if the process is interrupted.
struct AppUpdateReplacement: Sendable {
    let directoryID: UUID
    let release: AppRelease
    let newFingerprint: String
    let oldFingerprint: String

    func directory(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".focusstudio-update-\(directoryID.uuidString)", isDirectory: true)
    }

    func replace(installer: AppInstaller, launch: (URL) throws -> Void) throws {
        let target = installer.destination
        let directory = directory(for: target)
        let candidate = directory.appendingPathComponent("Focus Studio.app")
        let lock = target.deletingLastPathComponent().appendingPathComponent(".focusstudio-install.lock")
        guard mkdir(lock.path, 0o700) == 0 else {
            throw AppInstallationError(key: "Another installation is in progress. If it was interrupted, review the installation lock before retrying.", detail: lock.path)
        }
        defer { _ = rmdir(lock.path) }
        let current = try installer.inspect(target)
        let pending = try installer.inspect(candidate)
        guard current.fingerprint == oldFingerprint, pending.fingerprint == newFingerprint,
              pending.release == release, release > current.release else {
            throw AppInstallationError(key: "The installed app changed during installation. Please retry.")
        }
        guard !installer.isRunning(target) else {
            throw AppInstallationError(key: "Quit the installed Focus Studio first. A running app will never be replaced.")
        }
        func exchange() throws {
            guard renamex_np(candidate.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        try exchange()
        do {
            guard try installer.inspect(target).fingerprint == newFingerprint else {
                throw AppInstallationError(key: "The installed app failed verification.")
            }
            try launch(target)
        } catch {
            guard !installer.isRunning(target) else {
                // The newly opened app is using this bundle. Preserve its
                // predecessor for recovery rather than changing a live bundle.
                throw AppInstallationError(key: "The previous version is available for recovery.", detail: candidate.path)
            }
            do { try exchange() }
            catch { throw AppInstallationError(key: "The previous version is available for recovery.", detail: candidate.path) }
            throw error
        }
    }
}

enum AppUpdateInstaller {
    static let helperName = "focus-studio-update"

    /// Called only after authenticating the release manifest's signature and the
    /// complete DMG's digest. The caller owns the downloaded DMG throughout.
    static func prepare(verifiedDMG: URL, expectedVersion: String, expectedBuild: String) async throws -> PreparedAppUpdate {
        try await Task.detached(priority: .userInitiated) {
            let target = AppInstaller.canonicalURL
            guard Bundle.main.bundleURL.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path else {
                throw AppInstallationError(key: "Open Focus Studio from Applications to update.")
            }
            try requireSingleInstance()
            let helper = target.appendingPathComponent("Contents/MacOS").appendingPathComponent(helperName)
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw AppInstallationError(key: "The update helper is missing. Install a fresh copy of Focus Studio.")
            }
            let replacement = try stage(verifiedDMG: verifiedDMG, expectedRelease: AppRelease(version: expectedVersion, build: expectedBuild),
                                        installer: AppInstaller(isRunning: isRunning))
            return PreparedAppUpdate(replacement: replacement, helper: helper)
        }.value
    }

    static func stage(verifiedDMG: URL, expectedRelease: AppRelease, installer: AppInstaller) throws -> AppUpdateReplacement {
        let files = FileManager.default
        let target = installer.destination
        let current = try installer.inspect(target)
        guard expectedRelease > current.release else {
            throw AppInstallationError(key: "A newer version is already installed. Downgrades are not allowed.")
        }
        let mount = files.temporaryDirectory.appendingPathComponent("FocusStudioImage-\(UUID())", isDirectory: true)
        try files.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Never recursively delete a mount point, including if detach fails.
        defer { _ = rmdir(mount.path) }
        try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-verify", "-mountpoint", mount.path, verifiedDMG.path])
        defer {
            // A background indexing process can briefly keep a read-only image busy.
            if (try? run("/usr/bin/hdiutil", ["detach", mount.path])) == nil {
                try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
            }
        }
        let source = try installer.inspect(mount.appendingPathComponent("Focus Studio.app"))
        guard source.release.version == expectedRelease.version, source.release.build == expectedRelease.build else {
            throw AppInstallationError(key: "The downloaded app does not match the update version.")
        }
        let replacement = AppUpdateReplacement(directoryID: UUID(), release: source.release,
                                               newFingerprint: source.fingerprint, oldFingerprint: current.fingerprint)
        let directory = replacement.directory(for: target)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let candidate = directory.appendingPathComponent("Focus Studio.app")
            try files.copyItem(at: source.url, to: candidate)
            guard try installer.inspect(candidate).fingerprint == source.fingerprint else {
                throw AppInstallationError(key: "The copied app did not match its source. The installed app was not changed.")
            }
            return replacement
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        let diagnostic = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppInstallationError(key: "The update could not be installed.",
                                       detail: String(decoding: diagnostic.prefix(1200), as: UTF8.self))
        }
    }

    static let isRunning: @Sendable (URL) -> Bool = { target in
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.focusstudio").contains {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path
        }
    }

    static func requireSingleInstance() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.focusstudio").contains(where: {
            !$0.isTerminated && $0.processIdentifier != pid
        }) else { throw AppInstallationError(key: "Quit other copies of Focus Studio before updating.") }
    }
}

final class PreparedAppUpdate: @unchecked Sendable {
    private let replacement: AppUpdateReplacement
    private let helper: URL
    private var handedOff = false

    fileprivate init(replacement: AppUpdateReplacement, helper: URL) {
        self.replacement = replacement
        self.helper = helper
    }

    /// A successful handshake transfers ownership of the private staging folder.
    /// The main app can now use normal Quit, including any pending save prompt.
    @MainActor func beginHandoff() throws {
        guard !handedOff else { throw AppInstallationError(key: "An update is already in progress.") }
        try AppUpdateInstaller.requireSingleInstance()
        let child = Process()
        child.executableURL = helper
        child.arguments = [replacement.directoryID.uuidString, replacement.release.version, replacement.release.build,
                           replacement.newFingerprint, replacement.oldFingerprint, String(getpid())]
        let acknowledgement = Pipe()
        child.standardOutput = acknowledgement
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        try child.run()
        let input = acknowledgement.fileHandleForReading
        var descriptor = pollfd(fd: input.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 2500) > 0, try input.read(upToCount: 1) == Data([1]) else {
            if child.isRunning { child.terminate() }
            throw AppInstallationError(key: "The update helper could not start. Please retry.")
        }
        handedOff = true
    }

    deinit {
        if !handedOff {
            try? FileManager.default.removeItem(at: replacement.directory(for: AppInstaller.canonicalURL))
        }
    }
}
