import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FocusStudioAutomation

struct AccountSettingsView: View {
    @ObservedObject var store: NativeSubscriptionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 38)).foregroundStyle(StudioTheme.purple)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your Focus Studio account").font(.title2.bold())
                    Text(store.account?.account.email ?? L10n.tr("Sign in to export your first demo"))
                        .foregroundStyle(StudioTheme.secondaryText).textSelection(.enabled)
                }
                Spacer()
            }
            if let account = store.account {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label(LocalizedStringKey(account.entitlement.plan == "free" ? "Free export" : "Focus Studio Pro"),
                              systemImage: account.entitlement.plan == "free" ? "gift" : "checkmark.seal.fill")
                            .font(.headline)
                        Spacer()
                        if account.entitlement.canExport { Text("Ready to export").foregroundStyle(.green) }
                    }
                    if account.entitlement.plan == "free" {
                        Text(account.entitlement.freeExportsRemaining > 0 ? "One successful export included" : "Your free export has been used")
                            .foregroundStyle(StudioTheme.secondaryText)
                    } else {
                        Text(account.entitlement.plan == "yearly" ? "$108 / year · $9 / month" : "$29 / month")
                            .foregroundStyle(StudioTheme.secondaryText)
                    }
                    HStack {
                        Button(account.entitlement.plan == "free" ? "View plans" : "Manage subscription") { store.openAccount() }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Refresh") { Task { await store.refresh() } }.disabled(store.isWorking)
                    }
                }
                .padding(20).background(StudioTheme.panel).clipShape(RoundedRectangle(cornerRadius: 16))
                HStack {
                    Text("Record and edit freely. Only completed exports use your allowance.")
                        .font(.caption).foregroundStyle(StudioTheme.secondaryText)
                    Spacer()
                    Button("Sign out") { Task { await store.signOut() } }.disabled(store.isWorking)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Label("One free export", systemImage: "gift").font(.headline)
                    Text("Then $29 monthly, or $108 yearly ($9 / month).")
                        .foregroundStyle(StudioTheme.secondaryText)
                    if let pairing = store.pairing {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Finish signing in in your browser")
                                Text(pairing.userCode).font(.system(.headline, design: .monospaced)).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Cancel") { store.cancelSignIn() }
                        }
                    } else {
                        Button("Continue in browser") { store.signIn() }
                            .buttonStyle(PrimaryButtonStyle()).disabled(store.isWorking)
                    }
                }
                .padding(20).background(StudioTheme.panel).clipShape(RoundedRectangle(cornerRadius: 16))
            }
            if !store.recoveries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Recover export", systemImage: "arrow.clockwise.circle").font(.headline)
                    Text("Finish a saved render without using another export.")
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
                            }.disabled(store.isWorking || store.account == nil)
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
        .task { await store.refresh() }
    }
}
