import AppKit
import Combine
import FocusStudioCapture
import FocusStudioCore
import SwiftUI

/// Owns a non-activating control panel on every connected display. Replicating
/// the compact controller keeps Finish and Screenshot reachable when the user
/// changes displays, Spaces, or enters another app's full-screen Space.
/// The console shrinks to a bar once a take is under way, so it stops covering
/// what is being demonstrated. Geometry lives here as pure functions so the
/// window frame and the SwiftUI layout can never disagree.
enum RecordingPanelLayout: Equatable {
    case expanded
    case compact

    static let bottomInset: CGFloat = 22
    static let edgeInset: CGFloat = 16

    var preferredSize: NSSize {
        switch self {
        case .expanded: return NSSize(width: 760, height: 116)
        case .compact: return NSSize(width: 324, height: 46)
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .expanded: return 22
        case .compact: return 15
        }
    }

    func size(in visibleFrame: NSRect) -> NSSize {
        NSSize(
            width: min(preferredSize.width, max(240, visibleFrame.width - 32)),
            height: preferredSize.height
        )
    }

    /// Anchored on the bottom centre of `current`, so a change of height keeps
    /// the bar hugging the bottom and a panel the user dragged stays put.
    func frame(in visibleFrame: NSRect, anchoredTo current: NSRect?) -> NSRect {
        let size = size(in: visibleFrame)
        let centerX = current?.midX ?? visibleFrame.midX
        let bottom = current?.minY ?? (visibleFrame.minY + Self.bottomInset)
        var origin = NSPoint(x: centerX - size.width / 2, y: bottom)
        if visibleFrame.width > size.width + Self.edgeInset * 2 {
            origin.x = min(
                max(origin.x, visibleFrame.minX + Self.edgeInset),
                visibleFrame.maxX - size.width - Self.edgeInset
            )
        }
        if visibleFrame.height > size.height + Self.edgeInset * 2 {
            origin.y = min(
                max(origin.y, visibleFrame.minY + Self.bottomInset),
                visibleFrame.maxY - size.height - Self.edgeInset
            )
        }
        return NSRect(
            x: origin.x.rounded(),
            y: origin.y.rounded(),
            width: size.width.rounded(),
            height: size.height.rounded()
        )
    }
}

@MainActor
final class RecordingControlPanelCoordinator: ObservableObject {
    static let shared = RecordingControlPanelCoordinator()

    @Published private(set) var layout: RecordingPanelLayout = .expanded

    private weak var model: StudioModel?
    private var panels: [RecordingControlPanel] = []
    private var screenObserver: NSObjectProtocol?
    private var destinationObserver: AnyCancellable?
    /// Expanding mid-take is deliberate but temporary: every take starts as a bar.
    private var expandedWhileRecording = false

    private init() {}

    func show(model: StudioModel) {
        if self.model === model, !panels.isEmpty {
            // Already on screen; only the size may need to catch up.
            updateLayout()
            return
        }
        hide()
        self.model = model
        layout = desiredLayout(for: model)
        rebuildPanels()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildPanels() }
        }
        // A @Published publisher delivers the incoming value, so the panel
        // resizes in step with the SwiftUI layout instead of a frame later.
        destinationObserver = model.$destination.sink { [weak self] destination in
            Task { @MainActor in self?.updateLayout(for: destination) }
        }
    }

    func hide() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        destinationObserver?.cancel()
        destinationObserver = nil
        closePanels()
        panels.removeAll()
        expandedWhileRecording = false
        layout = .expanded
        model = nil
    }

    /// Shrinking at the countdown means the morph has finished before the first
    /// frame is captured, so the geometry is still when the take starts.
    private func desiredLayout(for model: StudioModel) -> RecordingPanelLayout {
        switch model.destination {
        case .countdown, .recording:
            return expandedWhileRecording ? .expanded : .compact
        default:
            return .expanded
        }
    }

    func setExpandedWhileRecording(_ expanded: Bool) {
        expandedWhileRecording = expanded
        updateLayout()
    }

    func updateLayout(for destination: StudioModel.Destination? = nil, animated: Bool = true) {
        guard let model else { return }
        let current = destination ?? model.destination
        if current != .countdown, current != .recording { expandedWhileRecording = false }
        let desired: RecordingPanelLayout = {
            switch current {
            case .countdown, .recording: return expandedWhileRecording ? .expanded : .compact
            default: return .expanded
            }
        }()
        guard desired != layout else { return }
        layout = desired
        resizePanels(animated: animated)
    }

    /// `panel.screen` is nil for a panel that has drifted off screen, so each
    /// panel remembers the frame it was built for.
    private func resizePanels(animated: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for panel in panels {
            let visible = panel.homeVisibleFrame == .zero
                ? (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
                : panel.homeVisibleFrame
            guard visible != .zero else { continue }
            let target = layout.frame(in: visible, anchoredTo: panel.frame)
            guard animated, !reduceMotion else {
                panel.setFrame(target, display: true)
                panel.invalidateShadow()
                continue
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            } completionHandler: {
                MainActor.assumeIsolated { panel.invalidateShadow() }
            }
        }
    }

    private func rebuildPanels() {
        guard let model else { return }
        closePanels()
        layout = desiredLayout(for: model)
        panels = NSScreen.screens.map { screen in
            let visible = screen.visibleFrame
            let frame = layout.frame(in: visible, anchoredTo: nil)
            let panel = RecordingControlPanel(
                contentRect: NSRect(origin: .zero, size: frame.size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            let hostDisplayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            panel.contentView = NSHostingView(
                rootView: AppLocalizedView {
                    FloatingRecordingControls(model: model, hostDisplayID: hostDisplayID)
                        .preferredColorScheme(.dark)
                }
            )
            panel.title = L10n.tr("Recording controls")
            panel.setAccessibilityLabel(L10n.tr("Recording controls"))

            panel.homeVisibleFrame = visible
            panel.setFrameOrigin(frame.origin)
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
    /// The visible frame this panel was built for; `screen` goes nil once a
    /// panel drifts off the display it belongs to.
    var homeVisibleFrame: NSRect = .zero

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
    @ObservedObject private var coordinator = RecordingControlPanelCoordinator.shared
    /// Two-step discard: the bar asks in place rather than raising an alert.
    @State private var discardArmed = false
    private let layoutOverride: RecordingPanelLayout?
    /// The display this panel belongs to, so a first area drag starts on the
    /// screen whose toolbar was clicked.
    private let hostDisplayID: UInt32?

    init(
        model: StudioModel,
        layoutOverride: RecordingPanelLayout? = nil,
        hostDisplayID: UInt32? = nil
    ) {
        self.model = model
        self.layoutOverride = layoutOverride
        self.hostDisplayID = hostDisplayID
        _captureEngine = ObservedObject(wrappedValue: model.captureEngine)
    }

    private var layout: RecordingPanelLayout { layoutOverride ?? coordinator.layout }

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

    private var cornerRadius: CGFloat { layout.cornerRadius }

    var body: some View {
        Group {
            if layout == .compact {
                compactControls
            } else {
                consoleControls
            }
        }
        .foregroundStyle(StudioTheme.text)
        // The window frame is the single source of truth for size; a fixed
        // height here would clip or float during the resize animation.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(red: 0.065, green: 0.071, blue: 0.105).opacity(0.97))
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(LinearGradient(colors: [StudioTheme.purple.opacity(0.14), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(LinearGradient(colors: [StudioTheme.purple.opacity(0.5), Color.white.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .environment(\.locale, localization.locale)
        .onChange(of: model.destination) { _, _ in discardArmed = false }
        .onChange(of: captureEngine.isRecording) { _, isRecording in
            if !isRecording { discardArmed = false }
        }
        .task(id: discardArmed) {
            // An armed discard that the user walks away from disarms itself.
            guard discardArmed else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { discardArmed = false }
        }
    }

    private var consoleControls: some View {
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
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// Discarding throws the take away, so the bar asks once, in place, rather
    /// than raising an alert that would pull focus off the app being demoed.
    private var compactControls: some View {
        HStack(spacing: 6) {
            if discardArmed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StudioTheme.yellow)
                Text("Discard recording?")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Button("Keep") { discardArmed = false }
                    .buttonStyle(FloatingControlButtonStyle(compact: true, height: 30))
                    .accessibilityIdentifier("recording.toolbar.cancelDiscard")
                Button("Discard") {
                    discardArmed = false
                    Task { await model.cancelRecording() }
                }
                .buttonStyle(FloatingControlButtonStyle(tint: StudioTheme.red, compact: true, height: 30))
                .disabled(!canDiscard)
                .accessibilityIdentifier("recording.toolbar.confirmDiscard")
            } else {
                statusDot
                clock
                Spacer(minLength: 0)
                if model.destination == .countdown {
                    Button("Cancel") { model.cancelRecordingCountdown() }
                        .buttonStyle(FloatingControlButtonStyle(compact: true, height: 30))
                        .accessibilityIdentifier("recording.toolbar.cancelCountdown")
                } else {
                    pauseButton(compact: true)
                    finishButton(compact: true)
                    discardButton
                }
                expandButton
            }
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var statusDot: some View {
        if isStopping || captureEngine.isChangingPauseState {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
                .accessibilityIdentifier("recording.toolbar.status")
        } else {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityIdentifier("recording.toolbar.status")
        }
    }

    /// A fixed width stops ticking digits reflowing the row every second.
    private var clock: some View {
        Group {
            if model.destination == .countdown {
                Text("\(model.recordingCountdown)")
            } else if captureEngine.isChangingPauseState {
                Text("Working…")
            } else if isStopping {
                Text("Saving…")
            } else {
                Text(verbatim: captureEngine.duration.formattedDuration)
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .monospacedDigit()
        .lineLimit(1)
        .frame(width: 48, alignment: .leading)
        .help(LocalizedStringKey(statusTitle))
        .accessibilityIdentifier("recording.floatingInteractionCounts")
    }

    /// A Codex-directed take cancels its plan instead of the recording, so one
    /// button must not quietly mean two things.
    private var canDiscard: Bool {
        !locked && captureEngine.isRecording && !model.isRunningCodexPlan
    }

    private var discardButton: some View {
        Button {
            discardArmed = true
        } label: {
            Label("Cancel recording", systemImage: "xmark")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(FloatingControlButtonStyle(compact: true, height: 30))
        .disabled(!canDiscard)
        .help("Cancel and delete this recording")
        .accessibilityLabel("Cancel recording")
        .accessibilityIdentifier("recording.toolbar.cancel")
    }

    private var expandButton: some View {
        Button {
            RecordingControlPanelCoordinator.shared.setExpandedWhileRecording(true)
        } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Show full controls")
        .accessibilityLabel("Show full controls")
        .accessibilityIdentifier("recording.toolbar.expand")
    }

    private var collapseButton: some View {
        Button {
            RecordingControlPanelCoordinator.shared.setExpandedWhileRecording(false)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Hide full controls")
        .accessibilityLabel("Hide full controls")
        .accessibilityIdentifier("recording.toolbar.collapse")
    }

    private func pauseButton(compact: Bool) -> some View {
        Button {
            Task { await model.toggleRecordingPause() }
        } label: {
            let title = LocalizedStringKey(captureEngine.isPaused ? "Resume recording" : "Pause recording")
            let icon = captureEngine.isPaused ? "play.fill" : "pause.fill"
            if compact {
                Label(title, systemImage: icon).labelStyle(.iconOnly)
            } else {
                Label(title, systemImage: icon)
            }
        }
        .buttonStyle(FloatingControlButtonStyle(compact: compact, height: compact ? 30 : 36))
        .disabled(locked || !captureEngine.isRecording)
        .help(LocalizedStringKey(captureEngine.isPaused ? "Resume recording" : "Pause recording"))
        .accessibilityLabel(LocalizedStringKey(captureEngine.isPaused ? "Resume recording" : "Pause recording"))
        .accessibilityIdentifier(captureEngine.isPaused ? "recording.toolbar.resume" : "recording.toolbar.pause")
    }

    private func finishButton(compact: Bool) -> some View {
        Button {
            Task { await model.stopRecording() }
        } label: {
            // Finish keeps its label even in the bar: it is the control a user
            // must be able to hit without aiming.
            Label("Finish", systemImage: "stop.fill")
        }
        .buttonStyle(FloatingControlButtonStyle(tint: StudioTheme.red, compact: compact, height: compact ? 30 : 36))
        .disabled(locked || !captureEngine.isRecording)
        .help("Finish recording and open the editor")
        .accessibilityLabel("Finish")
        .accessibilityIdentifier("recording.toolbar.stop")
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
            Spacer(minLength: 4)
            if let notice = model.screenshotNotice {
                Button { model.revealLastScreenshot() } label: {
                    Label(notice, systemImage: model.lastScreenshotURL == nil ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.system(size: 10)).lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.lastScreenshotURL == nil ? StudioTheme.yellow : Color.green)
            }
            Group {
                if ready {
                    // Idle state spends no words on itself; the colour carries
                    // the state and hover or VoiceOver spells it out.
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .frame(width: 20, height: 20)
                        .background(statusColor.opacity(0.12), in: Circle())
                } else {
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 5, height: 5)
                        Text(LocalizedStringKey(statusTitle))
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(statusColor.opacity(0.09), in: Capsule())
                    .foregroundStyle(statusColor)
                }
            }
            .help(LocalizedStringKey(statusTitle))
            .accessibilityLabel(LocalizedStringKey(statusTitle))
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
        if ready { return areaNeedsDrawing ? "Select recording area" : "Ready to record" }
        if model.destination == .countdown { return "Get ready" }
        if isStopping { return "Saving…" }
        if captureEngine.isChangingPauseState { return "Working…" }
        return captureEngine.isPaused ? "Paused" : "Recording"
    }

    private var statusColor: Color {
        if ready, areaNeedsDrawing { return StudioTheme.yellow }
        if ready || model.destination == .countdown { return Color(red: 0.72, green: 0.65, blue: 1) }
        return captureEngine.isPaused ? StudioTheme.yellow : StudioTheme.red
    }

    private func icon(for kind: CaptureTargetKind) -> String {
        switch kind {
        case .display: return "display"
        case .window: return "macwindow"
        case .area: return "rectangle.dashed"
        }
    }

    private func hint(for kind: CaptureTargetKind) -> String {
        switch kind {
        case .display:
            return "Entire display includes the macOS menu bar and Dock. Window or Area is cleaner for a product demo."
        case .window:
            return "Recommended for product demos: other apps and the macOS menu bar stay out. Browser controls can be hidden below."
        case .area:
            return "Draw an exact fixed region. Only that rectangle is encoded, including screenshots and cursor coordinates."
        }
    }

    /// The rectangle currently in play, whether it arrived through the picker
    /// or through `selectToolbarTarget` on a registered area target.
    private var drawnArea: CaptureTargetInfo? {
        if let area = model.selectedAreaTarget, area.id == model.selectedTargetID { return area }
        if let selected = model.selectedTarget, selected.kind == .area { return selected }
        return nil
    }

    private var areaNeedsDrawing: Bool {
        model.recordingSourceKind == .area && drawnArea == nil
    }

    private var readyControls: some View {
        Group {
            sourceModePicker
            if model.recordingSourceKind == .area {
                if model.areaDisplays.count > 1 { areaDisplayMenu }
                if let area = drawnArea { areaRedrawChip(area) }
            } else {
                sourceChip
            }
            Spacer(minLength: 8)
            settingsMenu
            screenshotButton(iconOnly: true)
            Rectangle().fill(Color.white.opacity(0.09)).frame(width: 1, height: 22)
            primaryButton
        }
        .disabled(locked || model.isSelectingArea)
    }

    /// Three icons replace a menu whose "Area" rows were indistinguishable from
    /// its "Display" rows. The current mode is now visible without opening it.
    private var sourceModePicker: some View {
        HStack(spacing: 2) {
            ForEach([CaptureTargetKind.display, .window, .area], id: \.self) { kind in
                let isSelected = model.recordingSourceKind == kind
                Button {
                    model.selectToolbarSourceKind(kind, preferredDisplayID: hostDisplayID)
                } label: {
                    Image(systemName: icon(for: kind))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : StudioTheme.secondaryText)
                        .frame(width: 34, height: 30)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? StudioTheme.purple.opacity(0.9) : Color.clear)
                        }
                }
                .buttonStyle(.plain)
                .help(LocalizedStringKey(hint(for: kind)))
                .accessibilityLabel(LocalizedStringKey(kind == .display ? "Display" : kind == .window ? "Window" : "Area"))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityIdentifier("recording.toolbar.mode.\(kind.rawValue)")
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var sourceChip: some View {
        Menu {
            ForEach(captureEngine.availableTargets.filter { $0.kind == model.recordingSourceKind }) { target in
                Button(target.title) { model.selectToolbarTarget(target) }
            }
            if captureEngine.availableTargets.allSatisfy({ $0.kind != model.recordingSourceKind }) {
                Text("No sources available")
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon(for: model.recordingSourceKind)).foregroundStyle(StudioTheme.purple)
                Text(model.selectedTarget?.title ?? L10n.tr("Selected source"))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(minWidth: 120, maxWidth: 240)
        .accessibilityLabel("Choose recording source")
        .accessibilityIdentifier("recording.toolbar.source")
    }

    /// Which screen to draw on. Icon only, because the rows themselves say it.
    private var areaDisplayMenu: some View {
        Menu {
            ForEach(model.areaDisplays) { display in
                Button {
                    Task { await model.beginAreaSelection(on: display) }
                } label: {
                    Label(display.title, systemImage: "rectangle.dashed")
                }
            }
            if model.areaDisplays.isEmpty {
                Text("No sources available")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "display")
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(StudioTheme.secondaryText)
            .padding(.horizontal, 10).frame(height: 38)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.areaDisplays.isEmpty)
        .help("Choose a display, then draw the recording area")
        .accessibilityLabel("Choose recording source")
        .accessibilityIdentifier("recording.toolbar.source")
    }

    /// The point of the redesign: redoing a rectangle is one click here instead
    /// of a 9pt link on another page. The size doubles as the label.
    private func areaRedrawChip(_ area: CaptureTargetInfo) -> some View {
        let size = "\(Int(area.frame.width.rounded())) × \(Int(area.frame.height.rounded()))"
        return Button {
            Task { await model.beginAreaSelection(preferredDisplayID: hostDisplayID) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                Text(verbatim: size)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(StudioTheme.purple)
            .padding(.horizontal, 11).frame(height: 38)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .disabled(model.areaDrawDisplay(preferring: hostDisplayID) == nil)
        .help("Reselect area")
        .accessibilityLabel("Reselect area")
        .accessibilityValue(Text(verbatim: size))
        .accessibilityIdentifier("recording.toolbar.area.redraw")
    }

    private var settingsMenu: some View {
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
        .accessibilityLabel("Recording settings")
        .accessibilityIdentifier("recording.toolbar.settings")
    }

    /// In Area mode with nothing drawn, Start used to be silently disabled with
    /// no way out of the toolbar. It now carries the missing step instead.
    private var primaryButton: some View {
        Button {
            if areaNeedsDrawing {
                Task { await model.beginAreaSelection(preferredDisplayID: hostDisplayID) }
            } else {
                model.startRecordingCountdown()
                if model.isShowingInteractionSetup { NSApp.activate(ignoringOtherApps: true) }
            }
        } label: {
            Label(
                LocalizedStringKey(primaryTitle),
                systemImage: areaNeedsDrawing ? "rectangle.dashed" : "record.circle"
            )
        }
        .buttonStyle(FloatingControlButtonStyle(tint: StudioTheme.purple))
        .disabled(areaNeedsDrawing
            ? model.areaDrawDisplay(preferring: hostDisplayID) == nil
            : !sourceReady)
        .accessibilityIdentifier("recording.toolbar.start")
    }

    private var primaryTitle: String {
        if model.isSelectingArea { return "Selecting area…" }
        return areaNeedsDrawing ? "Select recording area" : "Start recording"
    }

    /// Icon only in the idle row, where space buys clarity elsewhere; the
    /// recording bar keeps its word because that row was just shipped.
    private func screenshotButton(iconOnly: Bool) -> some View {
        Button {
            Task { await model.takeScreenshot() }
        } label: {
            let title = LocalizedStringKey(model.isTakingScreenshot ? "Capturing…" : "Screenshot")
            if iconOnly {
                Label(title, systemImage: "camera").labelStyle(.iconOnly)
            } else {
                Label(title, systemImage: "camera")
            }
        }
        .accessibilityLabel(LocalizedStringKey(model.isTakingScreenshot ? "Capturing…" : "Screenshot"))
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

            screenshotButton(iconOnly: false)

            Text(model.selectedTarget?.title ?? L10n.tr("Selected source"))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)

            pauseButton(compact: false)
            finishButton(compact: false)
            discardButton
            if model.destination == .countdown || model.destination == .recording {
                collapseButton
            }
        }
    }
}

private struct FloatingControlButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color?
    var compact = false
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.72 : 0.96))
            .padding(.horizontal, compact ? 8 : 12)
            .frame(height: height)
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
