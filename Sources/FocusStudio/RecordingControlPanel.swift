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
            let size = NSSize(width: 590, height: 72)
            let panel = RecordingControlPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentView = NSHostingView(
                rootView: AppLocalizedView {
                    FloatingRecordingControls(model: model)
                        .preferredColorScheme(.dark)
                }
            )

            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - 14
            )
            panel.setFrameOrigin(origin)
            panel.orderFrontRegardless()
            return panel
        }
    }
}

private final class RecordingControlPanel: NSPanel {
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
                    Group {
                        if isStopping {
                            Text("Saving…")
                        } else {
                            Text(verbatim: captureEngine.duration.formattedDuration)
                        }
                    }
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
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
