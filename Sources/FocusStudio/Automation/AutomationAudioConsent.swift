import AppKit
import FocusStudioAutomation
import SwiftUI

/// What the sound prompt shows: which AI tool asks, the sound it wants that
/// the person's recorder settings leave off, and what it is about to record.
struct AutomationAudioConsentRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// The MCP client's name, self-reported ("Claude Code").
    let clientName: String
    /// The program that started the helper, as the app identified it
    /// (``AutomationClientIdentity/programName``); shown next to the
    /// self-reported name, like the approval prompt, so a client cannot pass
    /// its request off as another's. Nil when unknown (tests).
    let programName: String?
    let audio: AIRecordingAudio
    /// The source to record ("Display 1", "Safari — Docs").
    let sourceName: String
    /// How long the prompt waits for an answer before nothing records.
    let timeout: TimeInterval
}

/// The person's answer to the sound prompt.
enum AutomationAudioConsentAnswer: Equatable, Sendable {
    /// Allow for this recording.
    case allow
    /// Record without sound: the recording starts with no sound at all.
    case withoutSound
    /// Cancel recording (also Escape, or closing the prompt).
    case cancel
}

/// Asks the person, before the countdown of a start_recording from an AI
/// tool, whether it may record sound their own recorder settings leave off
/// (``AIRecordingAudio/added(by:to:)``). Every such recording asks again;
/// nothing is remembered. It waits up to ``timeout`` and relays heartbeat
/// progress meanwhile, so the client keeps waiting and the wait counts
/// toward the call's detach threshold like any other part of the tool. When
/// the wait ends without an answer (no answer in time, or the call was
/// cancelled) the prompt is closed, so a late click can never start a
/// recording. The prompter is the app's panel; tests pass their own, which
/// must return when its task is cancelled.
@MainActor
final class AutomationAudioConsentController {
    /// Shows the prompt and returns the answer; nil when it closed without
    /// one. Cancelling the calling task closes the prompt.
    typealias Prompter = @MainActor (AutomationAudioConsentRequest) async -> AutomationAudioConsentAnswer?

    nonisolated static let defaultTimeout: TimeInterval = 60
    nonisolated static let defaultHeartbeatInterval: TimeInterval = 5
    /// Heartbeat progress while waiting: tiny increasing values from this
    /// base, above the approval prompt's heartbeats (which a new client's
    /// first call may have sent before), since a call's progress must keep
    /// increasing.
    nonisolated static let heartbeatBase = 0.01
    nonisolated static let heartbeatStep = 0.0001
    nonisolated static let waitingMessage = "Waiting for the person to answer Focus Studio's sound prompt…"

    let timeout: TimeInterval
    let heartbeatInterval: TimeInterval
    private let prompter: Prompter
    /// The prompts on screen now.
    private(set) var pendingRequests: [AutomationAudioConsentRequest] = []

    init(
        timeout: TimeInterval = defaultTimeout,
        heartbeatInterval: TimeInterval = defaultHeartbeatInterval,
        prompter: @escaping Prompter
    ) {
        self.timeout = max(0, timeout)
        self.heartbeatInterval = max(0.01, heartbeatInterval)
        self.prompter = prompter
    }

    /// Asks the person about `audio` for a recording of `sourceName` that
    /// `clientName` (started by `programName`) is starting, and returns their answer, or
    /// ``AIRecordingAudioConsent/timedOut(_:)`` when nobody answered in time.
    /// A cancelled caller gets ``AIRecordingAudioConsent/declined`` once the
    /// prompt is closed.
    func ask(clientName: String, programName: String? = nil, audio: AIRecordingAudio, sourceName: String, progress: AIToolProgressHandler?) async -> AIRecordingAudioConsent {
        enum Event: Sendable { case answered(AutomationAudioConsentAnswer?), timedOut, heartbeatStopped }
        let request = AutomationAudioConsentRequest(clientName: clientName, programName: programName, audio: audio, sourceName: sourceName, timeout: timeout)
        pendingRequests.append(request)
        defer { pendingRequests.removeAll { $0.id == request.id } }
        let prompter = self.prompter
        let timeout = self.timeout
        let interval = heartbeatInterval
        let beats = HeartbeatCounter()
        let event = await withTaskGroup(of: Event.self) { group -> Event in
            group.addTask { @MainActor in .answered(await prompter(request)) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .timedOut
            }
            if let progress {
                group.addTask {
                    progress(beats.next(), nil, Self.waitingMessage)
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(interval))
                        if Task.isCancelled { break }
                        progress(beats.next(), nil, Self.waitingMessage)
                    }
                    return .heartbeatStopped
                }
            }
            // Leaving the group cancels the rest: an unanswered prompt closes.
            defer { group.cancelAll() }
            while let event = await group.next() {
                if case .heartbeatStopped = event { continue }
                return event
            }
            return .answered(nil)
        }
        // The waiting is over: a last report without a message, so a job's
        // running status no longer says it waits for the person.
        progress?(beats.next(), nil, nil)
        if Task.isCancelled { return .declined }
        switch event {
        case .answered(.allow?):
            return .allowed
        case .answered(.withoutSound?):
            return .withoutSound
        case .answered(.cancel?), .answered(nil), .heartbeatStopped:
            return .declined
        case .timedOut:
            return .timedOut(timeout)
        }
    }
}

/// The heartbeat values of one prompt, increasing from the base.
private final class HeartbeatCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var beats = 0

    func next() -> Double {
        lock.withLock {
            beats += 1
            return AutomationAudioConsentController.heartbeatBase + Double(beats) * AutomationAudioConsentController.heartbeatStep
        }
    }
}

// MARK: - The prompt

/// The prompt that asks the person whether an AI tool may record sound for
/// one recording, in the style of the approval prompt. No button is the
/// default, so a Return typed into another app cannot answer it; Escape (or
/// closing it) cancels the recording. It activates Focus Studio so the
/// person sees it, and gives the app they were using its focus back when
/// answered, so the recorded app stays in front for the countdown.
@MainActor
enum AutomationAudioConsentPanel {
    private static var open: [UUID: AudioConsentPanelController] = [:]

    /// Shows the prompt and returns the answer; nil when the calling task is
    /// cancelled (the prompt then closes).
    static func ask(_ request: AutomationAudioConsentRequest) async -> AutomationAudioConsentAnswer? {
        guard !Task.isCancelled else { return nil }
        let controller = AudioConsentPanelController(request: request)
        open[request.id] = controller
        defer { open[request.id] = nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AutomationAudioConsentAnswer?, Never>) in
                controller.show { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in controller.dismiss() }
        }
    }
}

@MainActor
private final class AudioConsentPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var decide: ((AutomationAudioConsentAnswer?) -> Void)?
    /// The app the person was using when the prompt came up.
    private var previousApp: NSRunningApplication?

    init(request: AutomationAudioConsentRequest) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = L10n.tr("Record sound?")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        let prompt = AppLocalizedView {
            AutomationAudioConsentPromptView(
                request: request,
                allow: { [weak self] in self?.finish(.allow) },
                withoutSound: { [weak self] in self?.finish(.withoutSound) },
                cancel: { [weak self] in self?.finish(.cancel) }
            )
            .preferredColorScheme(.dark)
        }
        let hosting = NSHostingView(rootView: prompt)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
    }

    func show(decide: @escaping (AutomationAudioConsentAnswer?) -> Void) {
        self.decide = decide
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == NSRunningApplication.current ? nil : front
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// Closes the prompt unanswered (its call gave up or timed out).
    func dismiss() {
        finish(nil)
    }

    func windowWillClose(_ notification: Notification) {
        finish(.cancel)
    }

    private func finish(_ answer: AutomationAudioConsentAnswer?) {
        guard let decide else { return }
        self.decide = nil
        panel.close()
        returnFocus()
        decide(answer)
    }

    /// Gives the app the person was using its focus back, unless they have
    /// moved on to another app meanwhile.
    private func returnFocus() {
        guard NSApp.isActive, let previousApp, !previousApp.isTerminated else { return }
        NSApp.yieldActivation(to: previousApp)
        previousApp.activate()
    }
}

struct AutomationAudioConsentPromptView: View {
    let request: AutomationAudioConsentRequest
    let allow: () -> Void
    let withoutSound: () -> Void
    let cancel: () -> Void

    private var headline: LocalizedStringKey {
        switch (request.audio.microphone, request.audio.systemAudio) {
        case (true, true): return "“\(request.clientName)” wants to record your microphone and system audio"
        case (true, false): return "“\(request.clientName)” wants to record your microphone"
        default: return "“\(request.clientName)” wants to record system audio"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: request.audio.microphone ? "mic.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(StudioTheme.yellow)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline)
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("automation.sound.headline")
                    // The verified program, as on the approval prompt: the
                    // name above is whatever the AI tool calls itself.
                    if let program = request.programName {
                        Text("Started by \(program)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StudioTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("automation.sound.program")
                    }
                    Text("It is about to record “\(request.sourceName)”. Your recorder settings leave this sound off; your answer applies to this recording only and changes no settings.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("“Record without sound” records the screen only, with no sound at all. If nobody answers within \(Int(request.timeout.rounded())) seconds, nothing is recorded.")
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel recording", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("automation.sound.cancel")
                Button("Record without sound", action: withoutSound)
                    .accessibilityIdentifier("automation.sound.withoutSound")
                Button("Allow for this recording", action: allow)
                    .accessibilityIdentifier("automation.sound.allow")
            }
        }
        .padding(20)
        .frame(width: 500)
        .background(StudioTheme.panel)
        .foregroundStyle(StudioTheme.text)
    }
}
