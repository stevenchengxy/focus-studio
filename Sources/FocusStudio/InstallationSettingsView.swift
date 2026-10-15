import AppKit
import FocusStudioAutomation
import SwiftUI

@MainActor
final class AppInstallationCoordinator: ObservableObject {
    static let shared = AppInstallationCoordinator()
    enum LaunchState { case checking, needsSetup, ready }
    @Published private(set) var launchState: LaunchState = .checking
    @Published private(set) var current: InstalledApp?
    @Published private(set) var installed: InstalledApp?
    @Published private(set) var discovered: [InstalledApp] = []
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var backupPath: String?
    private var refreshGeneration: UInt64 = 0
    private var preparation: Task<Void, Never>?

    var isCanonical: Bool { Bundle.main.bundleURL.standardizedFileURL.path == AppInstaller.canonicalURL.path }
    var hasNewerInstalledCopy: Bool {
        guard let current else { return false }
        return discovered.contains { $0.release > current.release }
    }
    var canInstallCurrent: Bool {
        guard !isCanonical, current != nil else { return false }
        return !hasNewerInstalledCopy && !hasConflictingBuild
    }
    var hasConflictingBuild: Bool {
        guard let current else { return false }
        return discovered.contains { $0.release == current.release && $0.fingerprint != current.fingerprint }
    }
    var primaryActionTitle: String {
        if isCanonical { return "Continue with this copy" }
        if let installed, let current, installed.release >= current.release { return "Open installed copy" }
        return discovered.isEmpty ? "Install and open" : "Update and open"
    }
    var canPerformPrimaryAction: Bool {
        isCanonical || installed != nil || canInstallCurrent || hasNewerInstalledCopy
    }

    nonisolated private static func installer() -> AppInstaller {
        AppInstaller(isRunning: { target in
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.focusstudio").contains {
                !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path
            }
        }, prepareVerifiedCopy: { candidate, source in
            // Only a copy of this already-running app, after the user explicitly
            // chose Install. External CLI sources keep their quarantine metadata.
            guard source.url.resolvingSymlinksInPath().path == Bundle.main.bundleURL.resolvingSymlinksInPath().path else { return }
            try AppInstaller.prepareVerifiedSelfCopyForLaunch(candidate)
        })
    }

    private static func runningCopies() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.focusstudio")
            .filter { !$0.isTerminated }
    }

    private var handoff: AppInstallationHandoff {
        AppInstallationHandoff(currentProcessID: ProcessInfo.processInfo.processIdentifier, runningInstances: {
            Self.runningCopies().map { app in
                AppInstallationHandoff.Instance(processID: app.processIdentifier, url: app.bundleURL,
                    requestTermination: { app.terminate() }, hasTerminated: { app.isTerminated })
            }
        })
    }

    func prepareForLaunch() async {
        if let preparation { await preparation.value; return }
        let task = Task { @MainActor in
            // `swift run` and standalone regression executables aren't app bundles.
            guard Bundle.main.bundleURL.pathExtension == "app" else {
                launchState = .ready
                return
            }
            await refresh()
            // The old process exits only AFTER Launch Services returns this
            // new one. Wait for that specific process, then inspect all peers.
            let installerPID = ProcessInfo.processInfo.environment["FOCUS_STUDIO_INSTALL_HANDOFF_PID"].flatMap(Int32.init)
            let isHandoff = isCanonical && installerPID != nil
                && installerPID != ProcessInfo.processInfo.processIdentifier
            if isHandoff, let installer = Self.runningCopies().first(where: { $0.processIdentifier == installerPID }) {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(10))
                while !installer.isTerminated && clock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let others = Self.runningCopies().filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if isHandoff && others.isEmpty {
                // The source may itself have lived in ~/Applications. Only now,
                // after its process exited, can that last duplicate be archived.
                isWorking = true
                do {
                    let target = AppInstaller.canonicalURL
                    let result = try await Task.detached { try Self.installer().install(from: target) }.value
                    backupPath = result.backupURL?.deletingLastPathComponent().path
                    isWorking = false
                    await refresh()
                } catch {
                    isWorking = false
                    report(error)
                    launchState = .needsSetup
                    return
                }
            }
            launchState = AppInstallationLaunchPolicy.requiresSetup(bundleURL: Bundle.main.bundleURL,
                destination: AppInstaller.canonicalURL, otherInstanceCount: others.count)
                || !discovered.isEmpty ? .needsSetup : .ready
        }
        preparation = task
        await task.value
    }

    func refresh() async {
        guard !isWorking else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let source = Bundle.main.bundleURL
        let result = await Task.detached { () -> (InstalledApp?, InstalledApp?, [InstalledApp], Error?) in
            let installer = Self.installer()
            let current = try? installer.inspect(source)
            do {
                let copies = try installer.discoverInstalledApps(excluding: source)
                let installed = source.standardizedFileURL.path == AppInstaller.canonicalURL.path
                    ? current : copies.first { $0.url.standardizedFileURL.path == AppInstaller.canonicalURL.path }
                return (current, installed, copies, nil)
            } catch { return (current, nil, [], error) }
        }.value
        guard !isWorking, generation == refreshGeneration else { return }
        current = result.0
        installed = result.1
        discovered = result.2
        if let error = result.3 { report(error) }
        else if current == nil && source.pathExtension == "app" {
            errorMessage = L10n.tr("The app signature could not be verified. Download a fresh copy from a trusted source.")
        } else { errorMessage = nil }
    }

    /// One explicit action handles first install, upgrade and opening an existing
    /// newer copy. No library, recording or control server starts in this copy
    /// until the startup decision has finished.
    func performPrimaryAction(isBusyNow: @escaping @MainActor () -> Bool) async {
        guard !isWorking else { return }
        guard !isBusyNow() else { reportBusy(); return }
        isWorking = true
        refreshGeneration &+= 1
        errorMessage = nil
        statusMessage = "Closing other copies…"
        defer { isWorking = false }
        var stoppedServer = false
        do {
            // Re-read everything on click: an install can change while the
            // welcome screen is open. Never choose a stale bundle/version.
            let sourceURL = Bundle.main.bundleURL
            let inventory = try await Task.detached { () -> (InstalledApp, [InstalledApp]) in
                let installer = Self.installer()
                return (try installer.inspect(sourceURL), try installer.discoverInstalledApps(excluding: sourceURL))
            }.value
            current = inventory.0
            discovered = inventory.1
            installed = isCanonical ? current : discovered.first { $0.url.standardizedFileURL.path == AppInstaller.canonicalURL.path }
            let newest = ([inventory.0] + inventory.1).max { $0.release < $1.release }!
            let canReuseCanonical = installed.map { $0.release >= newest.release } ?? false
            if isCanonical && newest.release > inventory.0.release {
                throw AppInstallationError(key: "Open the newer Focus Studio copy to complete this update.", detail: newest.url.path)
            }
            // Start a fresh target process so it can finish cleanup after this
            // source exits, including a source installed under a legacy name.
            try await handoff.quitOtherCopies()
            guard !isBusyNow() else { throw busyError }
            // Even when the destination already has this build, archive older
            // installations elsewhere. The installer leaves a matching, running
            // canonical app in place and only retires the stopped duplicates.
            statusMessage = "Installing…"
            let identicalInstalledCopy = installed?.fingerprint == inventory.0.fingerprint
            let installSource: URL
            if newest.release == inventory.0.release && (!canReuseCanonical || identicalInstalledCopy) {
                installSource = sourceURL
            } else {
                installSource = canReuseCanonical ? AppInstaller.canonicalURL : newest.url
            }
            // A previous same-build copy may still carry download quarantine.
            // Re-stage this verified running source so that case is repairable.
            let repairIdenticalCopy = !isCanonical && identicalInstalledCopy && installSource == sourceURL
            let result = try await Task.detached {
                try Self.installer().install(from: installSource, preservingRunningSource: sourceURL,
                                             reinstallIdenticalCopy: repairIdenticalCopy)
            }.value
            installed = result.app
            backupPath = result.backupURL?.deletingLastPathComponent().path
            if isCanonical {
                launchState = .ready
                statusMessage = nil
                return
            }
            guard !isBusyNow() else { throw busyError }
            // Release the shared socket BEFORE opening the installed process.
            // A failed launch restores service in an already-running session.
            if launchState == .ready {
                let pending = AppServices.shared.controlServer.stop()
                stoppedServer = true
                for task in pending { await task.value }
            }
            statusMessage = "Opening installed copy…"
            await AppServices.shared.model.flushProjectEdits()
            guard !isBusyNow() else { throw busyError }
            try await openCanonicalApplication()
            isWorking = false
            NSApp.terminate(nil)
        } catch {
            if stoppedServer { AppServices.shared.controlServer.start() }
            statusMessage = nil
            report(error)
        }
    }

    private func openCanonicalApplication() async throws {
        let target = AppInstaller.canonicalURL
        _ = try await Task.detached { try Self.installer().inspect(target) }.value
        if let app = Self.runningCopies().first(where: { $0.bundleURL?.standardizedFileURL.path == target.path }) {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            app.activate(options: [.activateAllWindows])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.environment = ["FOCUS_STUDIO_INSTALL_HANDOFF_PID": String(ProcessInfo.processInfo.processIdentifier)]
        let app = try await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
        guard !app.isTerminated, app.bundleURL?.standardizedFileURL.path == target.path else {
            throw AppInstallationError(key: "The installed app did not open from Applications. Quit all copies, move the app to another folder and back to Applications using Finder, then open it again.")
        }
    }

    func showInstalledInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([discovered.max { $0.release < $1.release }?.url ?? AppInstaller.canonicalURL])
    }

    private var busyError: AppInstallationError {
        AppInstallationError(key: "Finish recording, exporting, and assistant tasks before managing installation.")
    }
    private func reportBusy() { report(busyError) }
    private func report(_ error: Error) {
        if let failure = error as? AppInstallationError {
            errorMessage = [L10n.tr(failure.key), failure.detail].compactMap { $0 }.joined(separator: "\n")
        } else { errorMessage = error.localizedDescription }
    }
}

struct InstallationStartupView: View {
    @ObservedObject private var installation = AppInstallationCoordinator.shared
    @ObservedObject private var localization = AppLocalization.shared
    let isBusyNow: @MainActor () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "shippingbox.fill").font(.system(size: 42)).foregroundStyle(.orange)
            Text("Set up Focus Studio").font(.largeTitle.bold())
            if installation.launchState == .checking {
                ProgressView("Checking installed versions…")
            } else {
                Text("Install Focus Studio in Applications so recordings, permissions, and updates use the same copy.")
                if let current = installation.current {
                    LabeledContent("This copy", value: current.release.version)
                }
                if !installation.discovered.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Detected installations").font(.headline)
                        ForEach(installation.discovered, id: \.url) { copy in
                            HStack {
                                Text(copy.url.lastPathComponent)
                                Spacer()
                                Text(copy.release.version).monospacedDigit()
                            }
                            Text(verbatim: copy.url.path).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if installation.hasNewerInstalledCopy {
                    Text("You opened an older copy. A newer version is already installed.").foregroundStyle(.orange)
                }
                Text("Save your work and finish recording in other copies first. Setup will ask them to quit, keep a backup of replaced apps, and open the installed version. Your projects and credentials stay unchanged.")
                    .font(.callout).foregroundStyle(.secondary)
                if installation.isWorking {
                    ProgressView(LocalizedStringKey(installation.statusMessage ?? "Installing…"))
                }
                if let error = installation.errorMessage {
                    Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Show installed app in Finder") { installation.showInstalledInFinder() }
                }
                HStack {
                    Button("Quit", role: .cancel) { NSApp.terminate(nil) }.disabled(installation.isWorking)
                    Spacer()
                    Button(LocalizedStringKey(installation.primaryActionTitle)) {
                        Task { await installation.performPrimaryAction(isBusyNow: isBusyNow) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(installation.isWorking || !installation.canPerformPrimaryAction)
                    .accessibilityIdentifier("installation.startup.install")
                }
            }
        }
        .padding(40)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioTheme.canvas)
        .task { await installation.prepareForLaunch() }
    }
}

struct InstallationSettingsView: View {
    /// Disables the buttons and shows the hint; as of the last render.
    let isBusy: Bool
    /// Read again when a button is clicked: an AI call or job can start or
    /// end without this view rendering again.
    let isBusyNow: @MainActor () -> Bool
    @ObservedObject private var installation = AppInstallationCoordinator.shared
    @ObservedObject private var localization = AppLocalization.shared
    @State private var confirmsInstall = false

    var body: some View {
        Form {
            AppUpdateSettingsSection()
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
                    Button(LocalizedStringKey(installation.primaryActionTitle)) { confirmsInstall = true }
                        .disabled(!installation.canPerformPrimaryAction || installation.isCanonical || installation.isWorking || isBusy)
                        .accessibilityIdentifier("installation.install")
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
            Section("Installation and permissions") {
                Text("Older installations in Applications are backed up and replaced. Projects and credentials stay in your user Library.")
                Text("Local builds are not Apple-notarized. Moving or rebuilding an ad-hoc signed app may require granting macOS permissions again.")
                Text("After installation, this copy closes and the installed version opens. Replace any old Dock shortcut with the app in Applications.")
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
            Button(LocalizedStringKey(installation.primaryActionTitle)) { Task { await installation.performPrimaryAction(isBusyNow: isBusyNow) } }
        } message: {
            Text("Save your work and finish recording in other copies first. Setup will ask them to quit, keep a backup of replaced apps, and open the installed version. Your projects and credentials stay unchanged.")
        }
    }
}

struct InstallationNoticeView: View {
    let isBusy: Bool
    /// Read again when a button is clicked (see InstallationSettingsView).
    let isBusyNow: @MainActor () -> Bool
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
                            Button("Open installed copy") { Task { await installation.performPrimaryAction(isBusyNow: isBusyNow) } }
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
