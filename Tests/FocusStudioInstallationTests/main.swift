import Darwin
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
        func fixture(_ folder: String, _ version: String, _ build: String, executable: String = "fixture",
                     name: String = "Focus Studio.app", bundleIdentifier: String = "com.local.focusstudio",
                     bundleExecutable: String = "FocusStudio") throws -> URL {
            let app = root.appendingPathComponent(folder).appendingPathComponent(name)
            try files.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": bundleIdentifier, "CFBundleExecutable": bundleExecutable, "CFBundleShortVersionString": version, "CFBundleVersion": build]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            try Data(executable.utf8).write(to: app.appendingPathComponent("Contents/MacOS/\(bundleExecutable)"))
            return app
        }
        func rejects(_ body: () throws -> Void) {
            do { try body(); preconditionFailure("Operation unexpectedly accepted") } catch {}
        }
        func expect(_ condition: Bool, _ message: String = "") { precondition(condition, message) }
        func setQuarantine(_ url: URL) throws {
            let value = Data("0083;00000000;FocusStudioTests;\(UUID().uuidString)".utf8)
            let result = value.withUnsafeBytes { bytes in
                Darwin.setxattr(url.path, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        }
        func quarantine(_ url: URL) throws -> Data? {
            let length = Darwin.getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
            if length < 0 {
                if errno == ENOATTR { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno)!)
            }
            var value = Data(count: length)
            let count = value.withUnsafeMutableBytes { bytes in
                Darwin.getxattr(url.path, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
            }
            guard count == length else { throw AppInstallationError(key: "Test quarantine attribute changed") }
            return value
        }
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

        expect(installer.searchDirectories.map(\.path) == [destination.deletingLastPathComponent().path],
               "Custom destinations must not discover this Mac's real applications")
        let systemApps = root.appendingPathComponent("merge/Applications")
        let userApps = root.appendingPathComponent("merge/User Applications")
        let mergeDestination = try fixture("merge/Applications", "1.4.0", "8")
        let renamed = try fixture("merge/Applications", "1.4.1", "8", name: "Focus Studio Old.app")
        let userOld = try fixture("merge/User Applications", "1.3.0", "7")
        let userSource = try fixture("merge/User Applications", "1.5.0", "9", name: "Focus Studio New.app")
        let unrelated = try fixture("merge/Applications", "99.0", "999", name: "Focus Studio Other.app", bundleIdentifier: "other.app")
        let wrongExecutable = try fixture("merge/Applications", "99.0", "999", name: "Another.app", bundleExecutable: "OtherExecutable")
        let nested = try fixture("merge/Applications/Nested", "99.0", "999")
        let download = try fixture("merge/Downloads", "99.0", "999")
        let linkedInstalled = systemApps.appendingPathComponent("Focus Studio Alias.app")
        try files.createSymbolicLink(at: linkedInstalled, withDestinationURL: download)
        let project = root.appendingPathComponent("merge/Application Support/Focus Studio/project.json")
        try files.createDirectory(at: project.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("project-data-must-survive".utf8).write(to: project)
        let merge = AppInstaller(destination: mergeDestination, searchDirectories: [systemApps, userApps],
                                 validateSignature: { _ in }, isRunning: { $0.path == userSource.path })
        let found = try merge.discoverInstalledApps(excluding: userSource)
        expect(Set(found.map { $0.url.path }) == Set([mergeDestination.path, renamed.path, userOld.path]),
               "Discovery must find renamed and per-user installs by identity, without scanning nested or unrelated apps")
        let merged = try merge.install(from: userSource)
        expect(merged.didInstall && merged.replacedApps.count == 3 && merged.backupURLs.count == 3)
        expect(merged.backupURLs.allSatisfy { $0.pathExtension == "bundle" && files.fileExists(atPath: $0.path) })
        expect(files.fileExists(atPath: merged.backupURL!.deletingLastPathComponent().appendingPathComponent("recovery.plist").path))
        expect(!files.fileExists(atPath: renamed.path) && !files.fileExists(atPath: userOld.path))
        expect(try merge.inspect(mergeDestination).fingerprint == merge.inspect(userSource).fingerprint)
        for untouched in [userSource, unrelated, wrongExecutable, nested, download, linkedInstalled] {
            expect(files.fileExists(atPath: untouched.path), "Source, unrelated apps, links and out-of-scope copies must survive")
        }
        expect(try String(contentsOf: project, encoding: .utf8) == "project-data-must-survive")
        expect(try !merge.install(from: userSource).didInstall, "Reinstalling an identical release is idempotent")

        // The canonical app can consolidate old copies without moving itself,
        // including when this installer runs from that canonical app.
        let redundant = try fixture("merge/User Applications", "1.4.0", "8", name: "Previous Studio.app")
        let canonicalRunning = AppInstaller(destination: mergeDestination, searchDirectories: [systemApps, userApps],
                                           validateSignature: { _ in }, isRunning: { $0.path == mergeDestination.path })
        let consolidated = try canonicalRunning.install(from: mergeDestination)
        expect(consolidated.didInstall && !files.fileExists(atPath: redundant.path))
        expect(files.fileExists(atPath: mergeDestination.path))

        // A newer or conflicting copy anywhere in the configured folders blocks
        // the entire operation, even if the canonical destination is absent.
        let newer = try fixture("blocked/Applications", "2.0.0", "20", name: "Focus Studio Newer.app")
        let blockedDestination = newer.deletingLastPathComponent().appendingPathComponent("Focus Studio.app")
        let blocked = AppInstaller(destination: blockedDestination, validateSignature: { _ in }, isRunning: { _ in false })
        rejects { _ = try blocked.install(from: fresh) }
        expect(files.fileExists(atPath: newer.path) && !files.fileExists(atPath: blockedDestination.path))
        try files.removeItem(at: newer)
        let conflictingCopy = try fixture("blocked/Applications", "1.5.0", "9", executable: "different", name: "Focus Studio Conflicting.app")
        rejects { _ = try blocked.install(from: fresh) }
        expect(files.fileExists(atPath: conflictingCopy.path) && !files.fileExists(atPath: blockedDestination.path))
        try files.removeItem(at: conflictingCopy)
        let busyCopy = try fixture("blocked/Applications", "1.4.0", "8", name: "Focus Studio Running.app")
        let busyInstaller = AppInstaller(destination: blockedDestination, validateSignature: { _ in }, isRunning: { $0.path == busyCopy.path })
        rejects { _ = try busyInstaller.install(from: fresh) }
        expect(files.fileExists(atPath: busyCopy.path) && !files.fileExists(atPath: blockedDestination.path))
        let lateCopyLaunch = LateLaunchState()
        let lateCopyInstaller = AppInstaller(destination: blockedDestination, validateSignature: { url in
            if url.path == busyCopy.path { lateCopyLaunch.inspectDestination() }
        }, isRunning: { $0.path == busyCopy.path && lateCopyLaunch.isRunning })
        rejects { _ = try lateCopyInstaller.install(from: fresh) }
        expect(files.fileExists(atPath: busyCopy.path) && !files.fileExists(atPath: blockedDestination.path),
               "A renamed app launched during verification must not move")

        let appearedCopy = blockedDestination.deletingLastPathComponent().appendingPathComponent("Newly Arrived.app")
        let changedDiscovery = AppInstaller(destination: blockedDestination, validateSignature: { url in
            if url.path.contains(".focusstudio-install-"), !FileManager.default.fileExists(atPath: appearedCopy.path) {
                try FileManager.default.copyItem(at: old, to: appearedCopy)
            }
        }, isRunning: { _ in false })
        rejects { _ = try changedDiscovery.install(from: fresh) }
        expect(files.fileExists(atPath: appearedCopy.path) && files.fileExists(atPath: busyCopy.path) && !files.fileExists(atPath: blockedDestination.path),
               "A changed set of installations must abort before moving any copy")

        let rollbackDestination = try fixture("multi-rollback/Applications", "1.3.0", "7")
        let rollbackRenamed = try fixture("multi-rollback/Applications", "1.4.0", "8", name: "Earlier.app")
        let rollbackUser = try fixture("multi-rollback/User Applications", "1.4.1", "8")
        let rollbackApps = [rollbackDestination, rollbackRenamed, rollbackUser]
        let rollbackFingerprints = try rollbackApps.map { try installer.inspect($0).fingerprint }
        let multiRollback = AppInstaller(destination: rollbackDestination,
                                        searchDirectories: [rollbackDestination.deletingLastPathComponent(), rollbackUser.deletingLastPathComponent()],
                                        validateSignature: { _ in }, isRunning: { _ in false },
                                        verifyAfterReplacement: { _ in throw AppInstallationError(key: "Injected multi-copy failure") })
        rejects { _ = try multiRollback.install(from: fresh) }
        expect(try rollbackApps.map { try installer.inspect($0).fingerprint } == rollbackFingerprints,
               "Verification failure must restore every old app to its exact original path")
        let symlinkDestination = root.appendingPathComponent("symlink-destination/Focus Studio.app")
        try files.createDirectory(at: symlinkDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createSymbolicLink(at: symlinkDestination, withDestinationURL: fresh)
        let symlinkInstaller = AppInstaller(destination: symlinkDestination, validateSignature: { _ in }, isRunning: { _ in false })
        rejects { _ = try symlinkInstaller.install(from: fresh) }
        expect(try files.destinationOfSymbolicLink(atPath: symlinkDestination.path) == fresh.path,
               "A symlink destination pointing to the source is not a valid existing installation")

        let handoffCanonical = try fixture("handoff/Applications", "1.5.0", "9")
        let handoffOld = try fixture("handoff/User Applications", "1.4.0", "8", name: "Focus Studio Old.app")
        let handoffDirectories = [handoffCanonical.deletingLastPathComponent(), handoffOld.deletingLastPathComponent()]
        let handoffInstaller = AppInstaller(destination: handoffCanonical, searchDirectories: handoffDirectories,
                                           validateSignature: { _ in }, isRunning: { $0.path == handoffOld.path })
        rejects { _ = try handoffInstaller.install(from: handoffCanonical) }
        let pendingHandoff = try handoffInstaller.install(from: handoffCanonical, preservingRunningSource: handoffOld)
        expect(!pendingHandoff.didInstall && files.fileExists(atPath: handoffOld.path),
               "Opening a newer canonical app must preserve the currently running per-user source until handoff finishes")
        let afterHandoff = AppInstaller(destination: handoffCanonical, searchDirectories: handoffDirectories,
                                       validateSignature: { _ in }, isRunning: { _ in false })
        let cleanedAfterHandoff = try afterHandoff.install(from: handoffCanonical)
        expect(cleanedAfterHandoff.didInstall && cleanedAfterHandoff.replacedApps.count == 1 && !files.fileExists(atPath: handoffOld.path),
               "The canonical process can archive the old source after that process has exited")
        let preservedNewer = try fixture("handoff/User Applications", "2.0.0", "20", name: "Focus Studio Newer.app")
        rejects { _ = try handoffInstaller.install(from: handoffCanonical, preservingRunningSource: preservedNewer) }
        expect(files.fileExists(atPath: preservedNewer.path), "Preserving a source must not bypass the downgrade check")
        try files.removeItem(at: preservedNewer)
        let preservedConflict = try fixture("handoff/User Applications", "1.5.0", "9", executable: "different", name: "Focus Studio Conflict.app")
        rejects { _ = try handoffInstaller.install(from: handoffCanonical, preservingRunningSource: preservedConflict) }
        expect(files.fileExists(atPath: preservedConflict.path), "Preserving a source must not bypass the equal-build integrity check")

        // Quarantine tests touch only scratch bundles; no downloaded app or real
        // Applications installation is changed or executed by these fixtures.
        let quarantinedSource = try fixture("quarantine/source", "1.6.0", "11")
        let sourceChild = quarantinedSource.appendingPathComponent("Contents/MacOS/FocusStudio")
        let externalDirectory = root.appendingPathComponent("quarantine/external")
        try files.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let externalFile = externalDirectory.appendingPathComponent("keep.txt")
        try Data("external-target".utf8).write(to: externalFile)
        try files.createSymbolicLink(at: quarantinedSource.appendingPathComponent("Contents/ExternalResources"), withDestinationURL: externalDirectory)
        for url in [quarantinedSource, sourceChild, externalDirectory, externalFile] { try setQuarantine(url) }
        let sourceQuarantine = try quarantine(quarantinedSource)
        let childQuarantine = try quarantine(sourceChild)
        let externalQuarantine = try quarantine(externalDirectory)
        let externalChildQuarantine = try quarantine(externalFile)
        let quarantineDestination = root.appendingPathComponent("quarantine/Applications/Focus Studio.app")
        try files.createDirectory(at: quarantineDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let defaultPreparation = AppInstaller(destination: quarantineDestination, validateSignature: { _ in }, isRunning: { _ in false })
        _ = try defaultPreparation.install(from: quarantinedSource)
        // macOS can normalize the flags/agent portion while copying an app.
        let copiedQuarantine = try quarantine(quarantineDestination)
        expect(copiedQuarantine != nil,
               "The default installer and CLI must retain quarantine")
        expect(try quarantine(quarantineDestination.appendingPathComponent("Contents/MacOS/FocusStudio")) == childQuarantine)
        let preparedInstaller = AppInstaller(destination: quarantineDestination, validateSignature: { _ in }, isRunning: { _ in false },
                                            prepareVerifiedCopy: { candidate, source in
            precondition(source.url.path == quarantinedSource.path)
            try AppInstaller.prepareVerifiedSelfCopyForLaunch(candidate)
        })
        expect(try !preparedInstaller.install(from: quarantinedSource).didInstall,
               "An identical build remains a no-op without an explicit repair request")
        expect(try quarantine(quarantineDestination) == copiedQuarantine)
        let repaired = try preparedInstaller.install(from: quarantinedSource, reinstallIdenticalCopy: true)
        expect(repaired.didInstall && repaired.backupURLs.count == 1)
        expect(try quarantine(quarantineDestination) == nil)
        expect(try quarantine(quarantineDestination.appendingPathComponent("Contents/MacOS/FocusStudio")) == nil)
        expect(try quarantine(repaired.backupURL!) != nil,
               "Repairing an identical build must retain the untouched previous bundle")
        expect(try quarantine(quarantinedSource) == sourceQuarantine && quarantine(sourceChild) == childQuarantine,
               "Preparing the copy must leave the original download's quarantine untouched")
        expect(try quarantine(externalDirectory) == externalQuarantine && quarantine(externalFile) == externalChildQuarantine,
               "Quarantine preparation must never follow symlinks outside the candidate")
        rejects { try AppInstaller.prepareVerifiedSelfCopyForLaunch(quarantinedSource) }
        let linkedStage = root.appendingPathComponent(".focusstudio-install-linked")
        try files.createSymbolicLink(at: linkedStage, withDestinationURL: quarantinedSource.deletingLastPathComponent())
        rejects { try AppInstaller.prepareVerifiedSelfCopyForLaunch(linkedStage.appendingPathComponent("Focus Studio.app")) }
        expect(try quarantine(quarantinedSource) == sourceQuarantine,
               "A symlink posing as a staging directory must not reach the source bundle")

        let preparationDestination = try fixture("quarantine-failure/Applications", "1.4.0", "8")
        let preparationFingerprint = try installer.inspect(preparationDestination).fingerprint
        let preparationFailure = AppInstaller(destination: preparationDestination, validateSignature: { _ in }, isRunning: { _ in false },
                                             prepareVerifiedCopy: { _, _ in throw AppInstallationError(key: "Injected preparation failure") })
        rejects { _ = try preparationFailure.install(from: quarantinedSource) }
        expect(try installer.inspect(preparationDestination).fingerprint == preparationFingerprint,
               "Preparation must finish successfully before any previous app moves")
        let preparationMutation = AppInstaller(destination: preparationDestination, validateSignature: { _ in }, isRunning: { _ in false },
                                              prepareVerifiedCopy: { candidate, _ in
            try Data("changed-during-preparation".utf8).write(to: candidate.appendingPathComponent("Contents/MacOS/FocusStudio"))
        })
        rejects { _ = try preparationMutation.install(from: quarantinedSource) }
        expect(try installer.inspect(preparationDestination).fingerprint == preparationFingerprint,
               "The prepared candidate must pass signature and fingerprint inspection again")
        let busyRepair = AppInstaller(destination: quarantineDestination, validateSignature: { _ in }, isRunning: { _ in true },
                                      prepareVerifiedCopy: { _, _ in preconditionFailure("A busy app must be rejected before preparation") })
        rejects { _ = try busyRepair.install(from: quarantinedSource, reinstallIdenticalCopy: true) }
        let canonicalSelfRepair = AppInstaller(destination: quarantineDestination, validateSignature: { _ in }, isRunning: { _ in true },
                                              prepareVerifiedCopy: { _, _ in preconditionFailure("The canonical source must never rewrite itself") })
        expect(try !canonicalSelfRepair.install(from: quarantineDestination, reinstallIdenticalCopy: true).didInstall)
        print("InstallationTests: PASS (versions, conflicts, signature, staging, locking, renamed/per-user discovery, running-source handoff, busy/late launches, multi-copy rollback, project preservation; quarantine default, verified-copy preparation, symlink boundary, preparation failure/mutation, identical-build repair; isolated fixtures only)")
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
