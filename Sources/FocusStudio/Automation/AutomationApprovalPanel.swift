import AppKit
import FocusStudioAutomation
import SwiftUI

/// The prompt that asks the person whether an AI client may control Focus
/// Studio, the first time it calls. The only moment an external call brings
/// the app forward. Neither button is the default, so a Return typed into
/// another app cannot answer it; Escape declines.
@MainActor
enum AutomationApprovalPanel {
    private static var open: [UUID: ApprovalPanelController] = [:]

    /// Shows the prompt and returns true for Allow, false for Don't Allow or
    /// closing it.
    static func ask(_ request: AutomationApprovalRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            let controller = ApprovalPanelController(request: request) { allowed in
                open[request.id] = nil
                continuation.resume(returning: allowed)
            }
            open[request.id] = controller
            controller.show()
        }
    }
}

@MainActor
private final class ApprovalPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var decide: ((Bool) -> Void)?

    init(request: AutomationApprovalRequest, decide: @escaping (Bool) -> Void) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        self.decide = decide
        super.init()
        panel.title = L10n.tr("Allow AI tool?")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        let prompt = AppLocalizedView {
            AutomationApprovalPromptView(
                request: request,
                allow: { [weak self] in self?.finish(true) },
                deny: { [weak self] in self?.finish(false) }
            )
            .preferredColorScheme(.dark)
        }
        let hosting = NSHostingView(rootView: prompt)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
    }

    func show() {
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.requestUserAttention(.informationalRequest)
    }

    func windowWillClose(_ notification: Notification) {
        finish(false)
    }

    private func finish(_ allowed: Bool) {
        guard let decide else { return }
        self.decide = nil
        panel.close()
        decide(allowed)
    }
}

struct AutomationApprovalPromptView: View {
    let request: AutomationApprovalRequest
    let allow: () -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundStyle(StudioTheme.purple)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Allow “\(request.clientName)” to control Focus Studio?")
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("It asked to run \(request.toolName). An approved AI tool can record your screen, always with the countdown and the control bar, and edit, export, rename and delete projects.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Started by \(request.identity.programName)")
                    .font(.system(size: 11, weight: .semibold))
                Text(verbatim: request.identity.programPath)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let script = request.identity.scriptPath {
                    Text("Script: \(script)")
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let signer = request.identity.signerDisplayName ?? request.identity.teamIdentifier {
                    Text("Signed by \(signer)")
                        .font(.system(size: 10))
                } else {
                    Text("Not signed by a developer: recognized by its location.")
                        .font(.system(size: 10))
                }
            }
            .foregroundStyle(StudioTheme.secondaryText)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if request.isRemembered {
                Text("You can revoke this at any time in Settings › AI tools.")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText)
            } else {
                // A shell or an interpreter with no script: approving it as
                // such would approve every program it runs.
                Text("\(request.identity.hostName) runs many programs, so this approval lasts only until this AI tool disconnects.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("automation.approval.sessionOnly")
            }
            HStack {
                Spacer()
                Button("Don't Allow", action: deny)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("automation.approval.deny")
                Button("Allow", action: allow)
                    .accessibilityIdentifier("automation.approval.allow")
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(StudioTheme.panel)
        .foregroundStyle(StudioTheme.text)
    }
}
