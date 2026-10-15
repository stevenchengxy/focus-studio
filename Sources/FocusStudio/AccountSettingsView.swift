import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FocusStudioAutomation

struct AccountSettingsView: View {
    @ObservedObject var store: NativeSubscriptionStore
    @ObservedObject private var community = NativeCommunityConnectionStore.shared

    private var clientCommunityURL: URL { URL(string: "https://focus-studio.stevenchengxy19.chatgpt.site/community")! }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 38)).foregroundStyle(StudioTheme.purple)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Free access").font(.title2.bold())
                    Text("Record, edit and export without signing in.")
                        .foregroundStyle(StudioTheme.secondaryText)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 14) {
                Label("Unlimited local exports", systemImage: "externaldrive.badge.checkmark").font(.headline)
                Text("Your projects stay on this Mac. No account or connection is needed to export.")
                    .foregroundStyle(StudioTheme.secondaryText)
                Text("AI providers may charge separately. Generation always asks for confirmation.")
                    .font(.caption).foregroundStyle(StudioTheme.secondaryText)
                Button("Visit the community") {
                    NSWorkspace.shared.open(clientCommunityURL)
                }.buttonStyle(PrimaryButtonStyle())
            }
            .padding(20).background(StudioTheme.panel).clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 12) {
                Label("Community publishing", systemImage: "person.crop.circle.badge.checkmark").font(.headline)
                Text("Connect the same ChatGPT account you use on the website, then confirm this installed client once to publish in the community.")
                    .font(.callout).foregroundStyle(StudioTheme.secondaryText)
                if community.state == .confirmed {
                    Label("This client is confirmed. You can publish on the community website.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    HStack {
                        Button("Visit the community") { NSWorkspace.shared.open(clientCommunityURL) }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Disconnect community account") { Task { await community.disconnect() } }
                            .disabled(community.isWorking)
                    }
                } else if community.isWorking {
                    ProgressView(LocalizedStringKey(community.state == .confirming ? "Confirming this client…" : "Waiting for browser approval…"))
                    if let pairing = community.pairing {
                        Text(verbatim: pairing.userCode).font(.title3.monospaced().bold()).textSelection(.enabled)
                        Text("Approve this matching code in your browser using the ChatGPT account you use to publish.")
                            .font(.caption).foregroundStyle(StudioTheme.secondaryText)
                    }
                    Button("Cancel connection") { Task { await community.cancel() } }
                } else {
                    HStack {
                        Button("Connect ChatGPT for community publishing") { community.connect() }
                            .buttonStyle(PrimaryButtonStyle())
                        if community.state == .error {
                            Button("Retry client confirmation") { Task { await community.refresh() } }
                        }
                    }
                }
                if let error = community.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(StudioTheme.warning).textSelection(.enabled)
                }
                Text("Community sign-in is optional. Recording, editing and local exports stay free without an account.")
                    .font(.caption).foregroundStyle(StudioTheme.secondaryText)
            }
            .padding(20).background(StudioTheme.panel).clipShape(RoundedRectangle(cornerRadius: 16))
            if !store.recoveries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Recover export", systemImage: "arrow.clockwise.circle").font(.headline)
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
                }
                .padding(20).background(StudioTheme.panel).clipShape(RoundedRectangle(cornerRadius: 16))
            }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(StudioTheme.warning).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(28).frame(minWidth: 640, minHeight: 430)
        .background(StudioTheme.window)
        .task { await store.refresh(); await community.refresh() }
        }
    }
}
