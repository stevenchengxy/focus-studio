import AppKit
import Darwin
import Foundation

@main
enum FocusStudioUpdateHelper {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let target = AppInstaller.canonicalURL
        guard args.count == 6, let directoryID = UUID(uuidString: args[0]),
              let release = try? AppRelease(version: args[1], build: args[2]),
              [args[3], args[4]].allSatisfy({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }),
              let pid = pid_t(args[5]), pid > 1, getppid() == pid else { exit(2) }
        // Only the canonical, already-running Focus Studio can initiate this
        // handoff. No command-line input chooses an installation destination.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              String(cString: path) == target.appendingPathComponent("Contents/MacOS/FocusStudio").path else { exit(2) }
        let replacement = AppUpdateReplacement(directoryID: directoryID, release: release,
                                               newFingerprint: args[3], oldFingerprint: args[4])
        let directory = replacement.directory(for: target)
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { exit(2) }
        guard (try? FileHandle.standardOutput.write(contentsOf: Data([1]))) != nil else { exit(2) }

        let files = FileManager.default
        let installer = AppInstaller(destination: target, searchDirectories: [], isRunning: AppUpdateInstaller.isRunning)
        func launch(_ url: URL) throws {
            try AppUpdateInstaller.run("/usr/bin/open", ["-a", url.path])
            // Launch Services accepting an open request alone doesn't mean that
            // the new app made it through the loader and finished launching.
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while ContinuousClock.now < deadline {
                if NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.focusstudio").contains(where: {
                    !$0.isTerminated && $0.isFinishedLaunching && $0.bundleURL?.resolvingSymlinksInPath().path == url.path
                }) { return }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            }
            throw AppInstallationError(key: "The updated app could not finish opening.")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(90))
        while kill(pid, 0) == 0 {
            if clock.now >= deadline {
                try? files.removeItem(at: directory)
                showError("Focus Studio is still open. Check for updates again when you are ready to restart.")
                exit(1)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        do {
            try replacement.replace(installer: installer, launch: launch)
            try? files.removeItem(at: directory)
        } catch {
            // Never erase the backup when an exchange/rollback was interrupted.
            if let restored = try? installer.inspect(target), restored.fingerprint == replacement.oldFingerprint {
                try? files.removeItem(at: directory)
                if !installer.isRunning(target) { try? launch(target) }
            }
            showError(error.localizedDescription)
            exit(1)
        }
    }

    @MainActor private static func showError(_ message: String) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Focus Studio"
        alert.informativeText = message
        alert.runModal()
    }
}
