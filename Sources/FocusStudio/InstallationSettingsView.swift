import AppKit
import SwiftUI

@MainActor
final class AppInstallationCoordinator: ObservableObject {
    static let shared = AppInstallationCoordinator()
    @Published private(set) var current: InstalledApp?
    @Published private(set) var installed: InstalledApp?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var backupPath: String?
    private var refreshGeneration: UInt64 = 0

    var isCanonical: Bool { Bundle.main.bundleURL.standardizedFileURL.path == AppInstaller.canonicalURL.path }
    var hasNewerInstalledCopy: Bool {
        guard let current, let installed else { return false }
        return installed.release > current.release
    }
    var canInstallCurrent: Bool {
        guard !isCanonical, let current else { return false }
        guard let installed else { return true }
        return current.release > installed.release
    }
    var hasConflictingBuild: Bool {
        guard !isCanonical, let current, let installed else { return false }
        return current.release == installed.release && current.fingerprint != installed.fingerprint
    }

    nonisolated private static func installer() -> AppInstaller {
        AppInstaller(isRunning: { target in
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.focusstudio").contains {
                $0.bundleURL?.standardizedFileURL.path == target.standardizedFileURL.path
            }
        })
    }

    func refresh() async {
        guard !isWorking else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let source = Bundle.main.bundleURL
        let result = await Task.detached {
            let installer = Self.installer()
            return (try? installer.inspect(source), try? installer.inspect(AppInstaller.canonicalURL))
        }.value
        guard !isWorking, generation == refreshGeneration else { return }
        current = result.0
        installed = result.1
    }

    func installThisCopy(isBusy: Bool) async {
        guard !isBusy, !isWorking else {
            errorMessage = L10n.tr("Finish recording, exporting, and assistant tasks before managing installation.")
            return
        }
        isWorking = true
        refreshGeneration &+= 1
        errorMessage = nil
        statusMessage = nil
        let source = Bundle.main.bundleURL
        do {
            let result = try await Task.detached { try Self.installer().install(from: source) }.value
            installed = result.app
            backupPath = result.backupURL?.path
            statusMessage = result.didInstall ? "Installed successfully. Open the installed copy when you are ready." : "This version is already installed."
        } catch {
            if let failure = error as? AppInstallationError {
                errorMessage = [L10n.tr(failure.key), failure.detail].compactMap { $0 }.joined(separator: "\n")
            } else { errorMessage = error.localizedDescription }
        }
        isWorking = false
    }

    func openInstalledCopy(isBusy: Bool) {
        guard !isBusy, !isWorking else {
            errorMessage = L10n.tr("Finish recording, exporting, and assistant tasks before managing installation.")
            return
        }
        // Use an exact URL, never `open -a`, which can select an older registered
        // duplicate. Current app is deliberately not terminated here.
        do {
            _ = try Self.installer().inspect(AppInstaller.canonicalURL)
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.focusstudio").first(where: {
                $0.bundleURL?.standardizedFileURL.path == AppInstaller.canonicalURL.path
            }) {
                running.activate(options: [.activateAllWindows])
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            // Another version with the same bundle ID can already be running.
            // Without this, Launch Services can reactivate that older copy even
            // though the caller supplied the canonical app URL explicitly.
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: AppInstaller.canonicalURL, configuration: configuration) { _, error in
                if let error { Task { @MainActor in self.errorMessage = error.localizedDescription } }
            }
        } catch {
            if let failure = error as? AppInstallationError {
                errorMessage = [L10n.tr(failure.key), failure.detail].compactMap { $0 }.joined(separator: "\n")
            } else { errorMessage = error.localizedDescription }
        }
    }
}

struct InstallationSettingsView: View {
    let isBusy: Bool
    @ObservedObject private var installation = AppInstallationCoordinator.shared
    @ObservedObject private var localization = AppLocalization.shared
    @State private var confirmsInstall = false

    var body: some View {
        Form {
            Section("This copy") {
                LabeledContent("Version", value: installation.current.map { "\($0.release.version) (\($0.release.build))" } ?? "—")
                Text(verbatim: Bundle.main.bundleURL.path).font(.caption).textSelection(.enabled)
            }
            Section("Installed copy") {
                LabeledContent("Version", value: installation.installed.map { "\($0.release.version) (\($0.release.build))" } ?? L10n.tr("Not installed"))
                Text(verbatim: AppInstaller.canonicalURL.path).font(.caption).textSelection(.enabled)
                if installation.hasNewerInstalledCopy {
                    Label("You opened an older copy. A newer version is already installed.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if installation.hasConflictingBuild {
                    Text("This version and build are already installed with different contents. Use a newer build to update.")
                        .foregroundStyle(.orange)
                } else if installation.isCanonical {
                    Label("You are using the installed copy.", systemImage: "checkmark.circle")
                } else {
                    Text("Install one canonical copy in Applications to avoid opening an older download or build.")
                }
                HStack {
                    Button("Install this copy to Applications") { confirmsInstall = true }
                        .disabled(!installation.canInstallCurrent || installation.isWorking || isBusy)
                        .accessibilityIdentifier("installation.install")
                    Button("Open installed copy") { installation.openInstalledCopy(isBusy: isBusy) }
                        .disabled(installation.installed == nil || installation.isCanonical || installation.isWorking || isBusy)
                        .accessibilityIdentifier("installation.openInstalled")
                    Button("Refresh") { Task { await installation.refresh() } }
                        .disabled(installation.isWorking)
                }
                if installation.isWorking { ProgressView("Installing…") }
                if isBusy { Text("Finish recording, exporting, and assistant tasks before managing installation.").foregroundStyle(.secondary) }
                if let status = installation.statusMessage { Text(LocalizedStringKey(status)).foregroundStyle(.green) }
                if let error = installation.errorMessage { Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled) }
                if let backup = installation.backupPath {
                    Text("Previous app recovery folder").font(.caption)
                    Text(verbatim: backup).font(.caption).textSelection(.enabled)
                }
            }
            Section("Updates and permissions") {
                Text("Open a newer trusted release, then use its installation action. Automatic online updates are not enabled.")
                Text("Projects and credentials stay in your user Library. Other app copies are never deleted automatically.")
                Text("Local builds are not Apple-notarized. Moving or rebuilding an ad-hoc signed app may require granting macOS permissions again.")
                Text("After opening the installed copy, quit the older window yourself and replace any old Dock shortcut with the app in Applications.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 650, minHeight: 540)
        .task { await installation.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await installation.refresh() }
        }
        .alert("Install Focus Studio in Applications?", isPresented: $confirmsInstall) {
            Button("Cancel", role: .cancel) {}
            Button("Install") { Task { await installation.installThisCopy(isBusy: isBusy) } }
        } message: {
            Text("The verified app will be copied to /Applications/Focus Studio.app. A previous installation is backed up. Running apps are not replaced, and your projects are not changed.")
        }
    }
}

struct InstallationNoticeView: View {
    let isBusy: Bool
    @ObservedObject private var installation = AppInstallationCoordinator.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if !installation.isCanonical && installation.current != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Image(systemName: installation.hasNewerInstalledCopy ? "exclamationmark.triangle.fill" : "shippingbox")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(LocalizedStringKey(installation.hasNewerInstalledCopy ? "You opened an older copy. A newer version is already installed." : "This app is running outside Applications."))
                            Text(verbatim: Bundle.main.bundleURL.path).font(.caption).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if installation.hasNewerInstalledCopy {
                            Button("Open installed copy") { installation.openInstalledCopy(isBusy: isBusy) }
                                .disabled(isBusy || installation.isWorking)
                        }
                        Button("Installation settings") {
                            AppSettingsNavigation.shared.selection = .installation
                            openSettings()
                        }
                        .disabled(isBusy || installation.isWorking)
                    }
                    if let error = installation.errorMessage { Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled) }
                }
                .font(.system(size: 12))
                .padding(10)
                .background(.orange.opacity(0.12))
            }
        }
        .task { await installation.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await installation.refresh() }
        }
    }
}
