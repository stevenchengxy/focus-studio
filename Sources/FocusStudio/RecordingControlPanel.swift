import AppKit
import Combine
import FocusStudioCapture
import FocusStudioCore
import SwiftUI

/// Owns a non-activating control panel on every connected display. Replicating
/// the compact controller keeps Finish and Screenshot reachable when the user
/// changes displays, Spaces, or enters another app's full-screen Space.
@MainActor
final class RecordingControlPanelCoordinator {
    static let shared = RecordingControlPanelCoordinator()

    private weak var model: StudioModel?
    private var panels: [RecordingControlPanel] = []
    private var screenObserver: NSObjectProtocol?

    private init() {}

    func show(model: StudioModel) {
        if self.model === model, !panels.isEmpty { return }
        hide()
        self.model = model
        rebuildPanels()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildPanels() }
        }
    }

    func hide() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        closePanels()
        panels.removeAll()
        model = nil
    }

    private func rebuildPanels() {
        guard let model else { return }
        closePanels()
        panels = NSScreen.screens.map { screen in
            let size = NSSize(width: min(760, screen.visibleFrame.width - 32), height: 116)
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
            panel.title = L10n.tr("Recording controls")
            panel.setAccessibilityLabel(L10n.tr("Recording controls"))

            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 22
            )
            panel.setFrameOrigin(origin)
            model.captureEngine.eventMonitor.ignoredWindowNumbers.insert(panel.windowNumber)
            panel.orderFrontRegardless()
            return panel
        }
    }

    private func closePanels() {
        for panel in panels {
            model?.captureEngine.eventMonitor.ignoredWindowNumbers.remove(panel.windowNumber)
            panel.close()
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

struct FloatingRecordingControls: View {
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

    private var locked: Bool {
        model.isBusy || isStopping || captureEngine.isChangingPauseState
    }

    private var ready: Bool { model.destination == .recorder }

    private var sourceReady: Bool {
        model.selectedTarget?.kind == model.recordingSourceKind
    }

    var body: some View {
        VStack(spacing: 13) {
            consoleHeader
            HStack(spacing: 10) {
            if ready {
                readyControls
            } else if model.destination == .countdown {
                Label("Get ready", systemImage: "record.circle")
                Text("\(model.recordingCountdown)")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(model.selectedTarget?.title ?? L10n.tr("Selected source"))
                    .lineLimit(1).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelRecordingCountdown() }
                    .buttonStyle(FloatingControlButtonStyle())
                    .accessibilityIdentifier("recording.toolbar.cancelCountdown")
            } else {
                activeControls
            }
            }
            .frame(height: 38)
        }
        .foregroundStyle(StudioTheme.text)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .frame(height: 116)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.065, green: 0.071, blue: 0.105).opacity(0.97))
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(LinearGradient(colors: [StudioTheme.purple.opacity(0.14), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(LinearGradient(colors: [StudioTheme.purple.opacity(0.5), Color.white.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .environment(\.locale, localization.locale)
    }

    private var consoleHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "viewfinder")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 26, height: 26)
                .background(LinearGradient(colors: [StudioTheme.purple, Color(red: 0.32, green: 0.45, blue: 0.94)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 8))
            Text(verbatim: "FOCUS STUDIO")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.8)
            Text("Capture console")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let notice = model.screenshotNotice {
                Button { model.revealLastScreenshot() } label: {
                    Label(notice, systemImage: model.lastScreenshotURL == nil ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.system(size: 10)).lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.lastScreenshotURL == nil ? StudioTheme.yellow : Color.green)
            }
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 5, height: 5)
                Text(LocalizedStringKey(statusTitle))
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(statusColor.opacity(0.09), in: Capsule())
            .foregroundStyle(statusColor)
            .accessibilityIdentifier("recording.toolbar.status")
            if ready {
                Button { model.destination = .library } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(locked)
                .help("Back to library")
                .accessibilityLabel("Back to library")
            }
        }
        .frame(height: 26)
    }

    private var statusTitle: String {
        if ready { return "Ready to record" }
        if model.destination == .countdown { return "Get ready" }
        if isStopping { return "Saving…" }
        if captureEngine.isChangingPauseState { return "Working…" }
        return captureEngine.isPaused ? "Paused" : "Recording"
    }

    private var statusColor: Color {
        if ready || model.destination == .countdown { return Color(red: 0.72, green: 0.65, blue: 1) }
        return captureEngine.isPaused ? StudioTheme.yellow : StudioTheme.red
    }

    private var sourceIcon: String {
        model.recordingSourceKind == .display ? "display" : model.recordingSourceKind == .area ? "rectangle.dashed" : "macwindow"
    }

    private var readyControls: some View {
        Group {
            Menu {
                ForEach([CaptureTargetKind.window, .area, .display], id: \.self) { kind in
                    Section(LocalizedStringKey(kind == .display ? "Display" : kind == .window ? "Window" : "Area")) {
                    ForEach(captureEngine.availableTargets.filter { $0.kind == (kind == .area ? .display : kind) }) { target in
                        Button(target.title) {
                            if kind == .area {
                                model.recordingSourceKind = .area
                                Task { await model.selectRecordingArea(on: target) }
                            } else {
                                model.selectToolbarTarget(target)
                            }
                        }
                    }
                    if captureEngine.availableTargets.isEmpty {
                        Text("No sources available")
                    }
                    }
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: sourceIcon).foregroundStyle(StudioTheme.purple)
                    Text(model.selectedTarget?.title ?? L10n.tr("Selected source"))
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .accessibilityLabel("Choose recording source")
            .accessibilityIdentifier("recording.toolbar.source")
            Menu {
                Toggle("Show cursor", isOn: $model.showRecordingCursor)
                Toggle("Automatic zooms", isOn: $model.automaticZooms)
                Toggle("Microphone", isOn: $model.recordMicrophone)
                Toggle("System audio", isOn: $model.recordSystemAudio)
                Toggle("Browser content only", isOn: $model.browserContentOnly)
            } label: {
                Label("Recording settings", systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly).frame(width: 32, height: 38)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Recording settings")
            .accessibilityIdentifier("recording.toolbar.settings")
            Rectangle().fill(Color.white.opacity(0.09)).frame(width: 1, height: 22)
            screenshotButton
            Button {
                model.startRecordingCountdown()
                if model.isShowingInteractionSetup { NSApp.activate(ignoringOtherApps: true) }
            } label: {
                Label("Start recording", systemImage: "record.circle")
            }
            .buttonStyle(FloatingControlButtonStyle(tint: StudioTheme.purple))
            .disabled(!sourceReady)
            .accessibilityIdentifier("recording.toolbar.start")
        }
        .disabled(locked || model.isSelectingArea)
    }

    private var screenshotButton: some View {
        Button {
            Task { await model.takeScreenshot() }
        } label: {
            Label(LocalizedStringKey(model.isTakingScreenshot ? "Capturing…" : "Screenshot"), systemImage: "camera")
        }
        .buttonStyle(FloatingControlButtonStyle())
        .disabled(model.isTakingScreenshot || locked || (ready && !sourceReady))
        .help("Save a PNG of the selected recording source")
        .accessibilityIdentifier("recording.toolbar.screenshot")
    }

    private var activeControls: some View {
        Group {
            HStack(spacing: 8) {
                Circle()
                    .fill(captureEngine.isPaused ? StudioTheme.yellow : StudioTheme.red)
                    .frame(width: 9, height: 9)
                    .overlay {
                        Circle()
                            .stroke(StudioTheme.red.opacity(0.25), lineWidth: 7)
                            .opacity(isStopping ? 0 : 1)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if captureEngine.isChangingPauseState {
                            Text("Working…")
                        } else if isStopping {
                            Text("Saving…")
                        } else {
                            Text(verbatim: captureEngine.duration.formattedDuration)
                        }
                    }
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    Text(LocalizedStringKey(captureEngine.isPaused ? "Paused" : "Recording"))
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

            screenshotButton

            Text(model.selectedTarget?.title ?? L10n.tr("Selected source"))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)

            Button {
                Task { await model.toggleRecordingPause() }
            } label: {
                Label(LocalizedStringKey(captureEngine.isPaused ? "Resume recording" : "Pause recording"),
                      systemImage: captureEngine.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(FloatingControlButtonStyle())
            .disabled(locked || !captureEngine.isRecording)
            .accessibilityIdentifier(captureEngine.isPaused ? "recording.toolbar.resume" : "recording.toolbar.pause")

            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("Finish", systemImage: "stop.fill")
            }
            .buttonStyle(FloatingControlButtonStyle(tint: StudioTheme.red))
            .disabled(locked || !captureEngine.isRecording)
            .accessibilityIdentifier("recording.toolbar.stop")
            .help("Finish recording and open the editor")

        }
    }
}

private struct FloatingControlButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color?
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .lineLimit(1)
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
            .opacity(isEnabled ? 1 : 0.38)
    }
}
