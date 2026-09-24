import Foundation

@main
enum InstallationTests {
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("FocusStudio-Installation-\(UUID())", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }
        let destination = root.appendingPathComponent("Applications/Focus Studio.app")
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let installer = AppInstaller(destination: destination, validateSignature: { _ in }, isRunning: { _ in false })
        func fixture(_ folder: String, _ version: String, _ build: String, executable: String = "fixture") throws -> URL {
            let app = root.appendingPathComponent("\(folder)/Focus Studio.app")
            try files.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "com.local.focusstudio", "CFBundleExecutable": "FocusStudio", "CFBundleShortVersionString": version, "CFBundleVersion": build]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            try Data(executable.utf8).write(to: app.appendingPathComponent("Contents/MacOS/FocusStudio"))
            return app
        }
        func rejects(_ body: () throws -> Void) {
            do { try body(); preconditionFailure("Operation unexpectedly accepted") } catch {}
        }
        func expect(_ condition: Bool, _ message: String = "") { precondition(condition, message) }
        expect(try AppRelease(version: "1.10.0", build: "1") > AppRelease(version: "1.9.9", build: "99"))
        expect(try AppRelease(version: "1.5", build: "10") > AppRelease(version: "1.5.0", build: "9"))
        expect(try AppRelease(version: "1.5", build: "9") == AppRelease(version: "1.5.0", build: "9.0"))
        for bad in ["", "1..5", "v1.5", "1.5-beta", "-1", "18446744073709551616"] {
            rejects { _ = try AppRelease(version: bad, build: "9") }
        }
        let old = try fixture("old", "1.4.0", "8")
        let fresh = try fixture("fresh", "1.5.0", "9")
        let first = try installer.install(from: old)
        precondition(first.didInstall && first.backupURL == nil)
        let update = try installer.install(from: fresh)
        precondition(update.didInstall && update.app.release.version == "1.5.0")
        precondition(files.fileExists(atPath: update.backupURL!.appendingPathComponent("Contents/Info.plist").path))
        precondition(update.backupURL!.pathExtension == "bundle")
        let fingerprint = try installer.inspect(destination).fingerprint
        rejects { _ = try installer.install(from: old) }
        expect(try installer.inspect(destination).fingerprint == fingerprint)
        expect(try !installer.install(from: fresh).didInstall)
        let conflict = try fixture("conflict", "1.5.0", "9", executable: "different")
        rejects { _ = try installer.install(from: conflict) }
        let next = try fixture("next", "1.5.0", "10")
        let running = AppInstaller(destination: destination, validateSignature: { _ in }, isRunning: { _ in true })
        rejects { _ = try running.install(from: next) }
        expect(try installer.inspect(destination).fingerprint == fingerprint)
        let lateLaunch = LateLaunchState()
        let openedDuringVerification = AppInstaller(destination: destination, validateSignature: { url in
            if url.standardizedFileURL.path == destination.standardizedFileURL.path { lateLaunch.inspectDestination() }
        }, isRunning: { _ in lateLaunch.isRunning })
        rejects { _ = try openedDuringVerification.install(from: next) }
        expect(try installer.inspect(destination).fingerprint == fingerprint, "A destination opened during final validation must not be replaced")
        let rollback = AppInstaller(destination: destination, validateSignature: { _ in }, isRunning: { _ in false }, verifyAfterReplacement: { _ in throw AppInstallationError(key: "Injected verification failure") })
        rejects { _ = try rollback.install(from: next) }
        expect(try installer.inspect(destination).fingerprint == fingerprint, "Post-copy failure must restore the previous bundle")
        let invalid = try fixture("invalid", "1.6.0", "11")
        let invalidInfo = invalid.appendingPathComponent("Contents/Info.plist")
        let metadata = ["CFBundleIdentifier": "other.app", "CFBundleExecutable": "FocusStudio", "CFBundleShortVersionString": "1.6.0", "CFBundleVersion": "11"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: invalidInfo)
        rejects { _ = try installer.install(from: invalid) }
        let invalidSignature = AppInstaller(destination: destination, validateSignature: { _ in throw AppInstallationError(key: "Bad signature") }, isRunning: { _ in false })
        rejects { _ = try invalidSignature.install(from: next) }
        let stagedFailure = AppInstaller(destination: destination, validateSignature: { url in
            if url.path.contains(".focusstudio-install-") { throw AppInstallationError(key: "Bad staged signature") }
        }, isRunning: { _ in false })
        rejects { _ = try stagedFailure.install(from: next) }
        expect(try installer.inspect(destination).fingerprint == fingerprint, "Staging failure must not move the installed app")
        let emptyParent = root.appendingPathComponent("Empty Applications")
        try files.createDirectory(at: emptyParent, withIntermediateDirectories: false)
        let emptyDestination = emptyParent.appendingPathComponent("Focus Studio.app")
        let failedFirstInstall = AppInstaller(destination: emptyDestination, validateSignature: { _ in }, isRunning: { _ in false }, verifyAfterReplacement: { _ in throw AppInstallationError(key: "First-install verification failure") })
        rejects { _ = try failedFirstInstall.install(from: next) }
        precondition(!files.fileExists(atPath: emptyDestination.path), "Failed first install must not leave an unverified app")
        let lock = destination.deletingLastPathComponent().appendingPathComponent(".focusstudio-install.lock")
        try files.createDirectory(at: lock, withIntermediateDirectories: false)
        rejects { _ = try installer.install(from: next) }
        try files.removeItem(at: lock)
        let linked = root.appendingPathComponent("linked.app")
        try files.createSymbolicLink(at: linked, withDestinationURL: fresh)
        rejects { _ = try installer.install(from: linked) }
        expect(try installer.inspect(destination).fingerprint == fingerprint)
        print("InstallationTests: PASS (numeric versions/builds, invalid versions, first install, recoverable update, no downgrade, equal-build conflict, busy app, update and first-install rollback, identity/signature, stage failure, locking, symlink rejection; isolated fixtures only)")
    }
}

private final class LateLaunchState: @unchecked Sendable {
    private let lock = NSLock()
    private var destinationInspections = 0
    func inspectDestination() {
        lock.lock()
        defer { lock.unlock() }
        destinationInspections += 1
    }
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return destinationInspections >= 2
    }
}
