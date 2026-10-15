import AppKit
import Foundation

@main
enum InstallAppCommand {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let path = arguments.first, path.hasPrefix("/"),
                  arguments.dropFirst().allSatisfy({ $0 == "--yes" || $0 == "--check" }) else {
                throw AppInstallationError(key: "Usage: install-app.sh '/absolute/path/Focus Studio.app' [--check | --yes]")
            }
            let isRunning: @Sendable (URL) -> Bool = { destination in
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.focusstudio").contains {
                    !$0.isTerminated && $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path ==
                        destination.standardizedFileURL.resolvingSymlinksInPath().path
                }
            }
            let installer = AppInstaller(isRunning: isRunning)
            let source = try installer.inspect(URL(fileURLWithPath: path))
            print("Source: \(source.url.path) — \(source.release.version) (\(source.release.build))")
            print("Canonical destination: \(AppInstaller.canonicalURL.path)")
            let copies = try installer.discoverInstalledApps(excluding: source.url)
            print("Detected installations (excluding the source): \(copies.count)")
            for copy in copies {
                print("Installed: \(copy.url.path) — \(copy.release.version) (\(copy.release.build))\(isRunning(copy.url) ? " [running]" : "")")
            }
            let newerCopies = copies.filter { $0.release > source.release }
            guard newerCopies.isEmpty else {
                throw AppInstallationError(key: "A newer version is already installed. Downgrades are not allowed.",
                                           detail: newerCopies.map { $0.url.path }.joined(separator: "\n"))
            }
            let conflictingCopies = copies.filter { $0.release == source.release && $0.fingerprint != source.fingerprint }
            guard conflictingCopies.isEmpty else {
                throw AppInstallationError(key: "This version and build are already installed with different contents. Use a newer build to update.",
                                           detail: conflictingCopies.map { $0.url.path }.joined(separator: "\n"))
            }
            guard arguments.contains("--yes"), !arguments.contains("--check") else {
                print("Read-only check complete. Add --yes to explicitly install; no app was changed or stopped.")
                return
            }
            let result = try installer.install(from: source.url)
            print(result.didInstall ? "Installation verified." : "This exact build is already installed.")
            for (previous, backup) in zip(result.replacedApps, result.backupURLs) {
                print("Archived: \(previous.url.path) — \(previous.release.version) (\(previous.release.build))")
                print("Recovery bundle: \(backup.path)")
            }
            print("Open exactly: \(result.app.url.path). No running app was stopped; projects and credentials were not changed.")
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
