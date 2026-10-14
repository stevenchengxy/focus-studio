import AppKit
import SwiftUI
import FocusStudioAutomation

/// A billable narration request must be reviewed in the app, from either assistant.
/// Cancellation, closing, or a timeout declines it. Return never approves by accident.
@MainActor
enum SpeechGenerationConsent {
    static func ask(summary: String, caller: String? = nil) async -> Bool {
        guard !Task.isCancelled else { return false }
        let controller = SpeechConsentPanel(summary: summary, caller: caller)
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(120))
            if !Task.isCancelled { controller.finish(false) }
        }
        defer { timeout.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false); return }
                controller.show { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in controller.finish(false) }
        }
    }
}

@MainActor
private final class SpeechConsentPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var completion: ((Bool) -> Void)?

    init(summary: String, caller: String?) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = L10n.tr("Generate AI narration")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: AppLocalizedView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Generate AI narration", systemImage: "waveform")
                    .font(.title2.weight(.semibold))
                if let caller { Text(verbatim: caller).font(.caption).foregroundStyle(.secondary) }
                ScrollView {
                    Text(verbatim: summary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                Text("Provider charges may apply. Nothing is generated until you confirm.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { [weak self] in self?.finish(false) }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Generate narration") { [weak self] in self?.finish(true) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("ai.speech.confirm")
                }
            }
            .padding(22).frame(width: 560, height: 500)
            .studioAppearance()
        })
    }

    func show(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        panel.center(); NSApp.activate(); panel.makeKeyAndOrderFront(nil)
        NSApp.requestUserAttention(.informationalRequest)
    }

    func finish(_ allowed: Bool) {
        guard let completion else { return }
        self.completion = nil
        panel.close()
        completion(allowed)
    }

    func windowWillClose(_ notification: Notification) { finish(false) }
}
