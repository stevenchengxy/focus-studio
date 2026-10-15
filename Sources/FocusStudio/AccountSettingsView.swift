import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FocusStudioAutomation

struct AccountSettingsView: View {
    // This legacy store is retained only for previously rendered export recovery.
    @ObservedObject var store: NativeSubscriptionStore
    @ObservedObject private var community = NativeCommunityConnectionStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Community connection").font(.title2.bold())
                    Text("Connect your ChatGPT account to share creations.")
                        .foregroundStyle(StudioTheme.secondaryText)
                }
                VStack(alignment: .leading, spacing: 18) {
                    identity
                    if let pairing = community.connection.pairing {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Finish signing in in your browser, then approve this code.")
                                .font(.callout).foregroundStyle(StudioTheme.secondaryText)
                            HStack(spacing: 12) {
                                Text(verbatim: pairing.userCode).font(.system(.title3, design: .monospaced).weight(.semibold))
                                    .textSelection(.enabled)
                                Button("Copy code") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(pairing.userCode, forType: .string)
                                }.buttonStyle(.borderless)
                            }
                            HStack {
                                Button("Reopen browser") { community.reopenBrowser() }.buttonStyle(PrimaryButtonStyle())
                                if community.operation == .idle { Button("Check connection") { community.refresh() } }
                                Button("Cancel") { community.cancel() }.disabled(community.operation == .cancelling)
                            }
                        }
                    } else if community.operation == .starting {
                        HStack { ProgressView().controlSize(.small); Text("Opening community sign-in…"); Spacer(); Button("Cancel") { community.cancel() } }
                    } else if community.connection.hasCredential {
                        if community.connection.identity == nil {
                            Text("Connection saved. Refresh to verify your account.")
                                .font(.callout).foregroundStyle(StudioTheme.secondaryText)
                            Button("Check connection") { community.refresh() }.disabled(community.isWorking)
                        } else if !community.connection.clientConfirmed {
                            Text("Confirm that you are using Focus Studio on this Mac to enable community publishing. No project will be uploaded.")
                                .font(.callout).foregroundStyle(StudioTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                            Button("Confirm this Mac") { community.confirmClient() }
                                .buttonStyle(PrimaryButtonStyle()).disabled(community.isWorking)
                        } else {
                            Button("Open community") { community.openCommunity() }.buttonStyle(PrimaryButtonStyle())
                        }
                        HStack(spacing: 14) {
                            Button("Disconnect") { community.disconnect() }.disabled(community.isWorking)
                                .help("Disconnecting removes this Mac’s connection. Your community confirmation remains.")
                            Button("Refresh") { community.refresh() }.disabled(community.isWorking)
                            if community.isWorking { ProgressView().controlSize(.small) }
                        }
                    } else {
                        Button("Connect with ChatGPT") { community.connect() }
                            .buttonStyle(PrimaryButtonStyle()).disabled(community.isWorking)
                        if community.isWorking { ProgressView().controlSize(.small) }
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioTheme.panel).clipShape(RoundedRectangle(cornerRadius: 14))
                .animation(reduceMotion ? nil : StudioMotion.fade, value: community.connection.clientConfirmed)
                .animation(reduceMotion ? nil : StudioMotion.fade, value: community.isPairing)
                if let error = community.error {
                    Label { Text(LocalizedStringKey(error)) } icon: { Image(systemName: "exclamationmark.circle") }
                        .font(.callout).foregroundStyle(StudioTheme.warning).textSelection(.enabled)
                }
                Text("Community connection is separate from Codex sign-in. Recording, editing and export work without either connection.")
                    .font(.caption).foregroundStyle(StudioTheme.secondaryText)
                if !store.recoveries.isEmpty {
                    DisclosureGroup("Recover exports") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Save a previously rendered video to your Mac.")
                                .font(.caption).foregroundStyle(StudioTheme.secondaryText)
                            ForEach(store.recoveries) { record in
                                HStack {
                                    Text(URL(fileURLWithPath: record.destinationPath).lastPathComponent)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Button("Recover export") {
                                        let panel = NSSavePanel()
                                        panel.nameFieldStringValue = URL(fileURLWithPath: record.destinationPath).lastPathComponent
                                        panel.allowedContentTypes = [.mpeg4Movie]
                                        if panel.runModal() == .OK, let destination = panel.url {
                                            Task { await store.recover(record, to: destination) }
                                        }
                                    }.disabled(store.isWorking)
                                }
                            }
                            if let error = store.error { Text(verbatim: error).font(.callout).foregroundStyle(StudioTheme.warning) }
                        }.padding(.top, 12)
                    }
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 430).background(StudioTheme.window)
        .task { community.refresh(); await store.refresh() }
    }
    @ViewBuilder private var identity: some View {
        HStack(spacing: 12) {
            Image(systemName: community.connection.clientConfirmed ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                .font(.system(size: 30)).foregroundStyle(StudioTheme.purple)
            VStack(alignment: .leading, spacing: 4) {
                if let identity = community.connection.identity {
                    Text(verbatim: identity.displayName?.isEmpty == false ? identity.displayName! : identity.email).font(.headline)
                    if identity.displayName?.isEmpty == false { Text(verbatim: identity.email).font(.callout).foregroundStyle(StudioTheme.secondaryText) }
                    Text(LocalizedStringKey(community.connection.clientConfirmed ? "Connected" : "Awaiting client confirmation"))
                        .font(.caption).foregroundStyle(StudioTheme.secondaryText)
                } else if community.isPairing {
                    Text("Waiting for browser approval").font(.headline)
                } else if community.connection.hasCredential {
                    Text("Connection saved").font(.headline)
                } else {
                    Text("Not connected").font(.headline)
                }
            }
            Spacer()
            if community.operation == .polling { ProgressView().controlSize(.small) }
        }
    }
}
