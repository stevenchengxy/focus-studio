import AppKit
import FocusStudioAutomation
import SwiftUI

struct AppUpdateCommands: Commands {
    @ObservedObject private var updates = AppUpdateService.shared
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L10n.tr("Check for Updates…")) {
                AppSettingsNavigation.shared.selection = .installation
                openSettings()
                Task { await updates.check() }
            }
        }
    }
}

struct AppUpdateSettingsSection: View {
    let isBusy: Bool
    let isBusyNow: @MainActor () -> Bool
    @ObservedObject private var updates = AppUpdateService.shared
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        Section("Software updates") {
            HStack {
                Text(verbatim: statusText)
                    .foregroundStyle(checkFailed ? .orange : .primary)
                    .textSelection(.enabled)
                Spacer()
                if updates.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    action
                }
            }
            if case let .downloading(percent) = updates.phase {
                if let percent {
                    ProgressView(value: Double(percent), total: 100)
                        .accessibilityLabel("Download update")
                        .accessibilityValue(Text(percent, format: .percent.scale(1)))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            if let error = updates.operationError {
                Text(verbatim: error.components(separatedBy: "\n").map { L10n.tr($0) }.joined(separator: "\n"))
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            } else if isBusy && updates.phase == .ready {
                Text("Return to the library and finish active tasks to install the update.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let release = updates.availableRelease {
                HStack {
                    Link("Release notes", destination: release.releaseURL)
                    if !release.supports(updates.operatingSystem) {
                        Text(verbatim: L10n.format("Requires macOS %@ or later.", release.minimumOS))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Picker("Update channel", selection: $updates.channel) {
                ForEach(AppUpdateChannel.allCases) { channel in
                    Text(LocalizedStringKey(channel.title)).tag(channel)
                }
            }
            .disabled(updates.isChecking || updates.isUpdating)
            .accessibilityIdentifier("updates.channel")
            .onChange(of: updates.channel) { _, _ in Task { await updates.check() } }
            Toggle("Check automatically once a day", isOn: $updates.automaticallyChecks)
                .accessibilityIdentifier("updates.automatic")
        }
    }

    @ViewBuilder private var action: some View {
        switch updates.phase {
        case .idle:
            if let release = updates.availableRelease, release.supports(updates.operatingSystem), !checkFailed {
                Button(updates.operationError == nil ? "Download update" : "Retry download") { updates.startDownload() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("updates.download")
            } else {
                Button("Check for Updates…") { Task { await updates.check() } }
                    .accessibilityIdentifier("updates.check")
            }
        case .downloading, .verifying:
            Button("Cancel") { updates.cancelDownload() }
                .accessibilityIdentifier("updates.cancel")
        case .ready:
            Button("Install and restart") {
                Task {
                    await updates.install(isBusyNow: isBusyNow, prepare: { package, release in
                        let prepared = try await AppUpdateInstaller.prepare(verifiedDMG: package.file,
                            expectedVersion: release.version, expectedBuild: package.build)
                        return { try prepared.beginHandoff() }
                    }, flushEdits: { await AppServices.shared.model.flushProjectEdits() },
                       restart: { NSApp.terminate(nil) })
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)
            .accessibilityIdentifier("updates.install")
        case .installing, .restarting:
            ProgressView().controlSize(.small)
        }
    }

    private var checkFailed: Bool {
        if case .failed = updates.status, updates.phase == .idle { return true }
        return false
    }

    private var statusText: String {
        switch updates.phase {
        case let .downloading(percent):
            if let percent { return L10n.format("Downloading update · %d%%", percent) }
            return L10n.tr("Downloading update…")
        case .verifying: return L10n.tr("Verifying update…")
        case .ready: return L10n.format("Focus Studio %@ is ready to install.", updates.availableRelease?.version ?? "")
        case .installing: return L10n.tr("Preparing update…")
        case .restarting: return L10n.tr("Restarting Focus Studio…")
        case .idle: break
        }
        switch updates.status {
        case .idle: return L10n.tr("Check for a newer version.")
        case .checking: return L10n.tr("Checking for updates…")
        case .upToDate: return L10n.tr("You're up to date.")
        case .noRelease: return L10n.tr("No release is available in this channel yet.")
        case .available, .requiresNewerOS:
            return L10n.format("Focus Studio %@ is available.", updates.availableRelease?.version ?? "")
        case let .failed(message): return L10n.tr(message)
        }
    }
}

struct AppUpdateNoticeView: View {
    @ObservedObject private var updates = AppUpdateService.shared
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if updates.shouldShowNotice, let release = updates.availableRelease {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(StudioTheme.purple)
                Text(verbatim: updates.phase == .ready
                     ? L10n.format("Focus Studio %@ is ready to install.", release.version)
                     : L10n.format("Focus Studio %@ is available.", release.version))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button("View update") {
                    AppSettingsNavigation.shared.selection = .installation
                    openSettings()
                }
                .accessibilityIdentifier("updates.notice.details")
                Button { updates.dismissNotice() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss update notice")
                .help("Dismiss update notice")
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(StudioTheme.purple.opacity(0.1))
        }
    }
}
