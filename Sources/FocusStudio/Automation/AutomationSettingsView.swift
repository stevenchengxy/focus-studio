import AppKit
import FocusStudioAutomation
import SwiftUI

/// Settings › AI tools: the switch for external AI tools, the clients the
/// person approved (with Revoke), recent declines (with Allow), and one-click
/// registration with Claude Code and Codex through their own CLIs, with the
/// command to copy when that is not possible.
struct AutomationSettingsView: View {
    @ObservedObject var access: AutomationAccessStore
    @ObservedObject var connector: MCPClientConnector
    @ObservedObject var server: ControlServer
    @ObservedObject private var localization = AppLocalization.shared
    @State private var didRefresh = false
    @State private var busyKinds: Set<MCPClientKind> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                accessSection
                Divider()
                approvedSection
                Divider()
                connectSection
            }
            .padding(22)
        }
        .frame(width: 620, height: 600)
        .background(StudioTheme.panel)
        .foregroundStyle(StudioTheme.text)
        .environment(\.locale, localization.locale)
        .task {
            guard !didRefresh else { return }
            didRefresh = true
            await connector.refresh()
        }
    }

    // MARK: - Access

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("Allow AI tools to control Focus Studio", isOn: $access.isEnabled)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityIdentifier("automation.enabled")
            Text("Claude Code, Codex and other MCP clients can record, edit and export in Focus Studio through focus-studio-mcp. The first time an AI tool calls, Focus Studio asks you to approve it. Every recording still shows the countdown and the control bar.")
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            serverStatus
        }
    }

    @ViewBuilder
    private var serverStatus: some View {
        if !access.isEnabled {
            // The server keeps listening so it can answer; every call is refused.
            Label("AI tools are turned off. Focus Studio refuses their calls.", systemImage: "nosign")
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.secondaryText)
        } else {
            serverState
        }
    }

    @ViewBuilder
    private var serverState: some View {
        switch server.state {
        case .listening:
            Label("Ready for AI tools.", systemImage: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.secondaryText)
        case .waitingForOtherInstance:
            Label("Another copy of Focus Studio is serving AI tools.", systemImage: "hourglass")
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.secondaryText)
        case let .failed(message):
            Label {
                Text("AI tools cannot connect: \(message)")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .textSelection(.enabled)
        case .stopped:
            Label("Not accepting AI tools.", systemImage: "pause.circle")
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.secondaryText)
        }
    }

    // MARK: - Approved clients

    private var approvedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Approved AI tools").font(.system(size: 13, weight: .semibold))
            if access.approvedClients.isEmpty {
                Text("No AI tool has been approved yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText)
            } else {
                ForEach(access.approvedClients) { client in
                    clientRow(client.identity, name: client.clientName, date: client.approvedAt, lastUsed: client.lastUsedAt) {
                        Button("Revoke") { access.revoke(key: client.identity.key) }
                            .accessibilityIdentifier("automation.revoke.\(client.identity.programName)")
                    }
                }
            }
            if !access.declinedClients.isEmpty {
                Text("Recently declined").font(.system(size: 12, weight: .semibold)).padding(.top, 4)
                ForEach(access.declinedClients) { client in
                    clientRow(client.identity, name: client.clientName, date: nil, lastUsed: nil) {
                        Button("Allow") { access.approve(client.identity, clientName: client.clientName) }
                    }
                }
            }
        }
    }

    private func clientRow<Actions: View>(
        _ identity: AutomationClientIdentity,
        name: String,
        date: Date?,
        lastUsed: Date?,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "\(name) · \(identity.programName)")
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: identity.programPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let script = identity.scriptPath {
                    Text("Script: \(script)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Group {
                    if let signer = identity.signerDisplayName ?? identity.teamIdentifier {
                        Text("Signed by \(signer)")
                    } else {
                        Text("Not signed by a developer: recognized by its location.")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(StudioTheme.secondaryText)
                if let date {
                    Text("Approved \(Text(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened)))")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTheme.secondaryText)
                }
                if let lastUsed {
                    Text("Last used \(Text(lastUsed, format: Date.FormatStyle(date: .abbreviated, time: .shortened)))")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTheme.secondaryText)
                }
            }
            Spacer()
            actions()
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Connect

    private var connectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connect AI tools").font(.system(size: 13, weight: .semibold))
                Spacer()
                if connector.isLocating { ProgressView().controlSize(.small) }
                Button("Check again") { Task { await connector.refresh() } }
                    .disabled(connector.isLocating || !busyKinds.isEmpty)
            }
            Text("Adds Focus Studio to the AI tool's list of MCP servers with its own command. Nothing else in its settings changes.")
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: connector.helperPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(StudioTheme.secondaryText)
                .textSelection(.enabled)
            if let warning = connector.helperWarning {
                Label(LocalizedStringKey(warning), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(MCPClientKind.allCases) { kind in
                clientConnection(kind)
            }
        }
    }

    private func clientConnection(_ kind: MCPClientKind) -> some View {
        let status = connector.status(for: kind)
        let isBusy = busyKinds.contains(kind) || status.state == .checking
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(verbatim: kind.title).font(.system(size: 12, weight: .semibold))
                statusText(status.state, kind: kind)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
                connectButton(kind, state: status.state)
                    .disabled(isBusy || connector.isLocating || connector.helperWarning != nil)
            }
            if let note = status.note {
                Text(LocalizedStringKey(note))
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText)
            }
            if let path = status.cliPath {
                Text("Uses \(path)")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .textSelection(.enabled)
            }
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: connector.commandLine(for: kind))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Button("Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(connector.commandLine(for: kind), forType: .string)
                }
                .help("Copies the command to paste into Terminal.")
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("automation.connect.\(kind.rawValue)")
    }

    @ViewBuilder
    private func statusText(_ state: MCPClientConnectionState, kind: MCPClientKind) -> some View {
        switch state {
        case .unknown, .checking:
            Text("Checking…")
        case .cliNotFound:
            Text("\(kind.executableName) was not found on this Mac. Install \(kind.title), or run the command below in Terminal.")
        case .notConnected:
            Text("Not connected.")
        case .connected:
            Text("Connected.")
        case let .connectedElsewhere(registration):
            Text("Connected to another copy: \(registration.command)")
        case let .failed(message):
            Text("The command failed: \(message)")
        }
    }

    @ViewBuilder
    private func connectButton(_ kind: MCPClientKind, state: MCPClientConnectionState) -> some View {
        switch state {
        case .connected:
            Button("Connected") {}
                .disabled(true)
        case .connectedElsewhere:
            Button("Update") { connect(kind) }
                .buttonStyle(PrimaryButtonStyle())
        case .cliNotFound:
            Button("Connect") {}
                .disabled(true)
        default:
            Button("Connect") { connect(kind) }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func connect(_ kind: MCPClientKind) {
        busyKinds.insert(kind)
        Task {
            await connector.connect(kind)
            busyKinds.remove(kind)
        }
    }
}
