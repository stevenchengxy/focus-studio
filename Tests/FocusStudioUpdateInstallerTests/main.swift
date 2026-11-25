import Darwin
import Foundation

@main
enum UpdateInstallerTests {
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("FocusStudioUpdateTests-\(UUID())", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }
        func fixture(in directory: URL, build: String) throws -> URL {
            let bundle = directory.appendingPathComponent("Focus Studio.app")
            let contents = bundle.appendingPathComponent("Contents")
            let binaries = contents.appendingPathComponent("MacOS")
            try files.createDirectory(at: binaries, withIntermediateDirectories: true)
            let executable = binaries.appendingPathComponent("FocusStudio")
            try files.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
            let plist = ["CFBundleExecutable": "FocusStudio", "CFBundleIdentifier": "com.local.focusstudio",
                         "CFBundleShortVersionString": "1.0", "CFBundleVersion": build, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            try AppUpdateInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
            return bundle
        }
        enum Failure: Error { case expected }
        func rejects(_ block: () throws -> Void) {
            do { try block(); fatalError("Expected rejection") } catch { }
        }
        let target = try fixture(in: root.appendingPathComponent("Applications"), build: "1")
        let payload = root.appendingPathComponent("payload")
        _ = try fixture(in: payload, build: "2")
        let dmg = root.appendingPathComponent("update.dmg")
        try AppUpdateInstaller.run("/usr/bin/hdiutil", ["create", "-size", "6m", "-fs", "HFS+", "-srcfolder", payload.path, dmg.path])
        let installer = AppInstaller(destination: target, searchDirectories: [], isRunning: { _ in false })
        let old = try installer.inspect(target)
        let release = try AppRelease(version: "1.0", build: "2")
        rejects {
            _ = try AppUpdateInstaller.stage(verifiedDMG: dmg, expectedRelease: AppRelease(version: "1.0", build: "3"), installer: installer)
        }
        let replacement = try AppUpdateInstaller.stage(verifiedDMG: dmg, expectedRelease: release, installer: installer)
        let directory = replacement.directory(for: target)
        let before = try installer.inspect(target)
        precondition(before.fingerprint == old.fingerprint)
        rejects {
            let busy = AppInstaller(destination: target, searchDirectories: [], isRunning: { _ in true })
            try replacement.replace(installer: busy) { _ in fatalError("Launched while running") }
        }
        rejects {
            try replacement.replace(installer: installer) { target in
                let candidate = try installer.inspect(target)
                precondition(candidate.release == release)
                throw Failure.expected
            }
        }
        let restored = try installer.inspect(target)
        precondition(restored.fingerprint == old.fingerprint)
        try replacement.replace(installer: installer) { reopened in precondition(reopened.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path) }
        let updated = try installer.inspect(target)
        let backup = try installer.inspect(directory.appendingPathComponent("Focus Studio.app"))
        precondition(updated.release == release && backup.fingerprint == old.fingerprint)
        rejects { _ = try AppUpdateInstaller.stage(verifiedDMG: dmg, expectedRelease: release, installer: installer) }
        print("Verified read-only DMG staging, exact version, live-app guard, launch rollback and atomic update.")
    }
}
