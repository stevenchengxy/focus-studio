import AppKit
import Combine
import FocusStudioAutomation
import FocusStudioCapture
import SwiftUI

/// Owns a non-activating control panel on every connected display. Replicating
/// the compact controller keeps Finish and Screenshot reachable when the user
/// changes displays, Spaces, or enters another app's full-screen Space.
@MainActor
final class RecordingControlPanelCoordinator {
    static let shared = RecordingControlPanelCoordinator()

    private weak var model: StudioModel?
    private var panels: [RecordingControlPanel] = []
    private var stateCancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?

    private init() {}

    func show(model: StudioModel) {
        hide()
        // No application (a command-line test run): nothing to put on screen.
        guard NSApp != nil else { return }
        self.model = model
        rebuildPanels()

        stateCancellable = model.captureEngine.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                switch state {
                case .idle, .completed, .failed:
                    self?.hide()
                case .preparing, .recording, .stopping:
                    break
                }
            }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildPanels() }
        }
    }

    func hide() {
        stateCancellable?.cancel()
        stateCancellable = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        panels.forEach { $0.close() }
        panels.removeAll()
        model = nil
    }

    private func rebuildPanels() {
        guard let model else { return }
        panels.forEach { $0.close() }
        panels = NSScreen.screens.map { screen in
            RecordingControlPanel.showing(FloatingRecordingControls(model: model), size: NSSize(width: 590, height: 72), on: screen)
        }
    }
}

/// A floating 3-2-1 countdown on every display while Focus Studio is not the
/// active app, typically a recording an AI tool started while the person
/// works in a terminal or another app: they see the countdown coming, which
/// AI tool asked for it, and can cancel it. It also appears when the person
/// switches to another app (or hides Focus Studio) during the countdown, so
/// the main window's countdown going behind that app never leaves them
/// without one. Styled like the recording control bar, which takes its place
/// once the capture runs, and like it non-activating: it never takes the
/// keyboard focus or activates the app. It closes when the countdown ends
/// (the capture has started, or it was cancelled, discarded or failed). It
/// is never in the video: display and area captures exclude every Focus
/// Studio window, including windows opened later (`CaptureEngine.displayFilter`
/// excludes the whole app), and a window capture contains only its own window.
@MainActor
final class RecordingCountdownPanelCoordinator {
    static let shared = RecordingCountdownPanelCoordinator(
        appIsActive: { NSApp?.isActive },
        openPanels: RecordingCountdownPanelCoordinator.screenPanels
    )

    /// Whether Focus Studio is the active app; nil without an application
    /// (a command-line test run), when nothing is ever shown.
    private let appIsActive: @MainActor () -> Bool?
    /// Opens the panels for `model`'s countdown, naming the AI tool that
    /// asked for it (if any), and returns how to close each one.
    private let openPanels: @MainActor (StudioModel, String?) -> [() -> Void]
    private let notifications: NotificationCenter
    /// The AI tool whose call is starting this recording, if one is (set by
    /// the app's services; nil in tests and for the person's own recordings).
    var automationRequester: (@MainActor () -> String?)?

    private weak var model: StudioModel?
    private var requester: String?
    private var closers: [() -> Void] = []
    private var destinationCancellable: AnyCancellable?
    private var observers: [NSObjectProtocol] = []

    init(
        appIsActive: @escaping @MainActor () -> Bool?,
        notifications: NotificationCenter = .default,
        openPanels: @escaping @MainActor (StudioModel, String?) -> [() -> Void]
    ) {
        self.appIsActive = appIsActive
        self.notifications = notifications
        self.openPanels = openPanels
    }

    /// Whether the floating countdown is on screen.
    var isShowing: Bool { !closers.isEmpty }

    /// Follows the countdown now starting: shows the panel at once unless
    /// Focus Studio is the active app (its window shows the countdown), and
    /// as soon as the person switches to another app or hides Focus Studio
    /// during it. Does nothing without an application.
    func countdownStarted(model: StudioModel) {
        hide()
        guard let active = appIsActive() else { return }
        self.model = model
        requester = automationRequester?()
        // Delivered as the destination changes, so the panel never outlives
        // the countdown (the model is main-actor isolated).
        destinationCancellable = model.$destination.sink { [weak self] destination in
            if destination != .countdown { self?.hide() }
        }
        observers = [NSApplication.didResignActiveNotification, NSApplication.didHideNotification].map { name in
            notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showPanels() }
            }
        }
        if !active { showPanels() }
    }

    func hide() {
        destinationCancellable?.cancel()
        destinationCancellable = nil
        observers.forEach { notifications.removeObserver($0) }
        observers.removeAll()
        closers.forEach { $0() }
        closers.removeAll()
        model = nil
        requester = nil
    }

    private func showPanels() {
        guard closers.isEmpty, let model, model.destination == .countdown else { return }
        closers = openPanels(model, requester)
    }

    private static func screenPanels(model: StudioModel, requester: String?) -> [() -> Void] {
        NSScreen.screens.map { screen in
            let panel = RecordingControlPanel.showing(
                FloatingRecordingCountdown(model: model, requester: requester),
                size: NSSize(width: 420, height: 72),
                on: screen
            )
            return { panel.close() }
        }
    }
}

private final class RecordingControlPanel: NSPanel {
    /// A panel with `content` at the top centre of `screen`, in front of
    /// every app's windows, without activating Focus Studio.
    static func showing(_ content: some View, size: NSSize, on screen: NSScreen) -> RecordingControlPanel {
        let panel = RecordingControlPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(
            rootView: AppLocalizedView {
                content
                    .preferredColorScheme(.dark)
            }
        )
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 14
        ))
        panel.orderFrontRegardless()
        return panel
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        isFloatingPanel = true
        hidesOnDeactivate = false
        // Stays on screen when Focus Studio is hidden (⌘H): the person can
        // always see a countdown or a recording and cancel it.
        canHide = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
    }
}

private struct FloatingRecordingControls: View {
    @ObservedObject private var model: StudioModel
    @ObservedObject private var captureEngine: CaptureEngine
    @ObservedObject private var localization = AppLocalization.shared

    init(model: StudioModel) {
        self.model = model
        _captureEngine = ObservedObject(wrappedValue: model.captureEngine)
    }

    private var isStopping: Bool {
        if case .stopping = captureEngine.state { return true }
        return false
    }

    /// Seconds until a recording with a duration stops by itself, on the
    /// engine's clock (measured from the first frame, like the timer).
    private var remaining: TimeInterval? {
        guard let attempt = model.currentRecording, attempt.isLive, let limit = attempt.duration, !isStopping else { return nil }
        return max(0, limit - captureEngine.duration)
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(StudioTheme.red)
                    .frame(width: 9, height: 9)
                    .overlay {
                        Circle()
                            .stroke(StudioTheme.red.opacity(0.25), lineWidth: 7)
                            .opacity(isStopping ? 0 : 1)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Group {
                            if isStopping {
                                Text("Saving…")
                            } else {
                                Text(verbatim: captureEngine.duration.formattedDuration)
                            }
                        }
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        if let remaining {
                            Label(L10n.format("Stops in %@", remaining.rounded(.up).formattedDuration), systemImage: "timer")
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.1), in: Capsule())
                                .help("This recording stops by itself when the time runs out. Finish or cancel it any time.")
                                .accessibilityIdentifier("recording.floatingRemaining")
                        }
                        if let settings = model.currentRecording?.settings, let audio = settings.audioDescription {
                            HStack(spacing: 3) {
                                if settings.microphone { Image(systemName: "mic.fill") }
                                if settings.systemAudio { Image(systemName: "speaker.wave.2.fill") }
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StudioTheme.yellow)
                            .help(L10n.tr(audio))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(L10n.tr(audio))
                            .accessibilityIdentifier("recording.floatingAudio")
                        }
                    }
                    let diagnostics = captureEngine.eventMonitor.diagnostics
                    Text("\(diagnostics.storedClicks) clicks · \(diagnostics.storedTypingActivity) inputs")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("recording.floatingInteractionCounts")
                }
                .frame(minWidth: 88, alignment: .leading)
            }
            .padding(.leading, 5)

            Divider()
                .overlay(Color.white.opacity(0.13))
                .frame(height: 28)

            Button {
                Task { await model.takeScreenshot() }
            } label: {
                Label(
                    LocalizedStringKey(model.isTakingScreenshot ? "Capturing…" : "Screenshot"),
                    systemImage: "camera"
                )
            }
            .buttonStyle(FloatingControlButtonStyle())
            .disabled(model.isTakingScreenshot || isStopping)
            .help("Save a PNG of the selected recording source")

            if let notice = model.screenshotNotice {
                Button {
                    model.revealLastScreenshot()
                } label: {
                    Label(notice, systemImage: model.lastScreenshotURL == nil ? "exclamationmark.triangle" : "checkmark")
                        .lineLimit(1)
                }
                .buttonStyle(FloatingControlButtonStyle(compact: true))
                .help(model.lastScreenshotURL == nil ? notice : L10n.tr("Show screenshot in Finder"))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            Spacer(minLength: 0)

            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("Finish", systemImage: "stop.fill")
            }
            .buttonStyle(FloatingControlButtonStyle(tint: StudioTheme.red))
            .disabled(isStopping)
            .help("Finish recording and open the editor")

            Button {
                Task { await model.cancelRecording() }
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(FloatingControlButtonStyle(compact: true))
            .disabled(isStopping)
            .help("Cancel and delete this recording")
        }
        .foregroundStyle(StudioTheme.text)
        .padding(.horizontal, 12)
        .frame(width: 590, height: 72)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.18), value: model.screenshotNotice)
        .environment(\.locale, localization.locale)
    }
}

/// The countdown panel's content: the number, that Focus Studio is about to
/// record, what (and for which AI tool), the audio it records, and Cancel,
/// in the control bar's style.
private struct FloatingRecordingCountdown: View {
    @ObservedObject private var model: StudioModel
    @ObservedObject private var captureEngine: CaptureEngine
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The AI tool that asked for this recording, if one did.
    private let requester: String?

    init(model: StudioModel, requester: String?) {
        self.model = model
        self.requester = requester
        _captureEngine = ObservedObject(wrappedValue: model.captureEngine)
    }

    /// The countdown is over and the capture is starting.
    private var isStarting: Bool { captureEngine.state == .preparing }

    private var sourceTitle: String {
        guard let target = model.currentRecording?.target ?? model.selectedTarget else { return L10n.tr("Selected source") }
        if target.kind == .window, let app = target.appName, !app.isEmpty, app != target.title {
            return target.title.isEmpty ? app : "\(app) — \(target.title)"
        }
        return target.title
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(StudioTheme.red.opacity(0.18))
                Circle()
                    .stroke(StudioTheme.red.opacity(0.5), lineWidth: 1.5)
                if isStarting {
                    Circle()
                        .fill(StudioTheme.red)
                        .frame(width: 12, height: 12)
                } else {
                    Text(verbatim: "\(model.recordingCountdown)")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: model.recordingCountdown)
                }
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(isStarting ? "Starting the recording…" : "Focus Studio is about to record"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: requester.map { L10n.format("%@ asked to record %@", $0, sourceTitle) } ?? sourceTitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let settings = model.currentRecording?.settings, let audio = settings.audioDescription {
                    Label(L10n.tr(audio), systemImage: settings.microphone ? "mic.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StudioTheme.yellow)
                        .lineLimit(1)
                        .accessibilityIdentifier("recording.floatingCountdownAudio")
                }
            }

            Spacer(minLength: 0)

            Button {
                model.cancelRecordingCountdown()
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .buttonStyle(FloatingControlButtonStyle())
            .help("Cancel this recording before it starts")
            .accessibilityIdentifier("recording.floatingCountdownCancel")
        }
        .foregroundStyle(StudioTheme.text)
        .padding(.horizontal, 13)
        .frame(width: 420, height: 72)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .environment(\.locale, localization.locale)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording countdown")
    }
}

private struct FloatingControlButtonStyle: ButtonStyle {
    var tint: Color?
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.72 : 0.96))
            .padding(.horizontal, compact ? 8 : 12)
            .frame(height: 36)
            .background(
                (tint ?? Color.white.opacity(0.09))
                    .opacity(configuration.isPressed ? 0.68 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if tint == nil {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
            }
    }
}
