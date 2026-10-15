import AppKit
import FocusStudioAutomation
import SwiftUI

struct AppUpdateCommands: Commands {
    @ObservedObject var model: StudioModel
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
            .disabled(updates.isChecking || model.isInstallationBusy)
        }
    }
}

struct AppUpdateSettingsSection: View {
    @ObservedObject private var updates = AppUpdateService.shared
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        Section("Software updates") {
            HStack {
                Text(verbatim: statusText)
                    .foregroundStyle(isFailure ? .orange : .primary)
                    .textSelection(.enabled)
                Spacer()
                if updates.isChecking { ProgressView().controlSize(.small) }
                Button("Check for Updates…") { Task { await updates.check() } }
                    .disabled(updates.isChecking)
                    .accessibilityIdentifier("updates.check")
            }
            if let release = updates.availableRelease {
                HStack(spacing: 12) {
                    Button("Download update") { openDownload(release) }
                        .disabled(!release.supports(updates.operatingSystem))
                        .accessibilityIdentifier("updates.download")
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
            .disabled(updates.isChecking)
            .accessibilityIdentifier("updates.channel")
            .onChange(of: updates.channel) { _, _ in Task { await updates.check() } }
            Toggle("Check automatically once a day", isOn: $updates.automaticallyChecks)
                .accessibilityIdentifier("updates.automatic")
            if let date = updates.lastCheckedAt {
                LabeledContent("Last checked") { Text(date, style: .date) + Text(" ") + Text(date, style: .time) }
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Updates open in your browser. Install when you are ready; your projects and settings stay in place.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var isFailure: Bool {
        if case .failed = updates.status { return true }
        return false
    }
    private var statusText: String {
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

/// Available updates stay visible in the idle library without a modal dialog,
/// taking focus from a recording, or interrupting an export/assistant task.
struct AppUpdateNoticeView: View {
    @ObservedObject private var updates = AppUpdateService.shared
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if updates.shouldShowNotice, let release = updates.availableRelease {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(StudioTheme.purple)
                Text(verbatim: L10n.format("Focus Studio %@ is available.", release.version))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Download update") { openDownload(release) }
                    .accessibilityIdentifier("updates.notice.download")
                Button("Details") {
                    AppSettingsNavigation.shared.selection = .installation
                    openSettings()
                }
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

@MainActor
private func openDownload(_ release: AppUpdateRelease) {
    // Revalidate even though every feed/cache entry passed validation. Opening a
    // download is an explicit user action; there is no updater installer here.
    guard (try? release.validate(expectedChannel: AppUpdateService.shared.channel)) != nil else { return }
    NSWorkspace.shared.open(release.downloadURL)
}
