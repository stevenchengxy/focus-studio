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
            let installer = AppInstaller(isRunning: { destination in
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.focusstudio").contains {
                    $0.bundleURL?.standardizedFileURL.path == destination.standardizedFileURL.path
                }
            })
            let source = try installer.inspect(URL(fileURLWithPath: path))
            print("Source: \(source.url.path) — \(source.release.version) (\(source.release.build))")
            print("Canonical destination: \(AppInstaller.canonicalURL.path)")
            if FileManager.default.fileExists(atPath: AppInstaller.canonicalURL.path) {
                let installed = try installer.inspect(AppInstaller.canonicalURL)
                print("Installed: \(installed.release.version) (\(installed.release.build))")
                guard source.release >= installed.release else {
                    throw AppInstallationError(key: "A newer version is already installed. Downgrades are not allowed.")
                }
            }
            guard arguments.contains("--yes"), !arguments.contains("--check") else {
                print("Read-only check complete. Add --yes to explicitly install; no app was changed or stopped.")
                return
            }
            let result = try installer.install(from: source.url)
            print(result.didInstall ? "Installation verified." : "This exact build is already installed.")
            if let backup = result.backupURL { print("Previous app recovery folder: \(backup.path)") }
            print("Open exactly: \(result.app.url.path). No running app was stopped; projects and credentials were not changed.")
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
