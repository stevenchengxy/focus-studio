import FocusStudioAutomation
import FocusStudioCapture
import FocusStudioCore
import SwiftUI

struct RecordingPickerView: View {
    @EnvironmentObject private var model: StudioModel
    @ObservedObject private var localization = AppLocalization.shared
    @State private var kind: CaptureTargetKind = .window
    @State private var areaDisplayID: String?

    private var filteredTargets: [CaptureTargetInfo] {
        model.captureEngine.availableTargets.filter { target in
            switch kind {
            case .display, .area:
                return target.kind == .display
            case .window:
                return target.kind == .window
            }
        }
    }

    private var displayTargets: [CaptureTargetInfo] {
        model.captureEngine.availableTargets.filter { $0.kind == .display }
    }

    private var selectedAreaDisplay: CaptureTargetInfo? {
        displayTargets.first { $0.id == areaDisplayID } ?? displayTargets.first
    }

    private var preferredBrowserWindow: CaptureTargetInfo? {
        model.captureEngine.availableTargets
            .filter {
                $0.kind == .window
                    && BrowserFamily.detect(applicationName: $0.appName) != nil
            }
            .max {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }
    }

    private var selectedAreaIsReady: Bool {
        guard let area = model.selectedAreaTarget,
              let display = selectedAreaDisplay
        else { return false }
        return model.selectedTargetID == area.id && area.nativeID == display.nativeID
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.destination = .library } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Back to library")
                Spacer()
                Text("New recording")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 32, height: 30)
            }
            .padding(.horizontal, 22)
            .frame(height: 58)
            .background(StudioTheme.panel)
            .overlay(alignment: .bottom) { Divider().overlay(StudioTheme.line) }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("What would you like to record?")
                        .font(.system(size: 24, weight: .bold, design: .rounded))

                    Picker("Source", selection: $kind) {
                        Label("Display", systemImage: "display").tag(CaptureTargetKind.display)
                        Label("Window", systemImage: "macwindow").tag(CaptureTargetKind.window)
                        Label("Area", systemImage: "rectangle.dashed").tag(CaptureTargetKind.area)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 430)
                    .help(LocalizedStringKey(sourceHint))

                    if kind == .display, let browser = preferredBrowserWindow {
                        Button {
                            kind = .window
                            model.selectedTargetID = browser.id
                        } label: {
                            Label("Use \(browser.appName ?? L10n.tr("browser")) window", systemImage: "macwindow")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StudioTheme.purple)
                        .help(LocalizedStringKey(sourceHint))
                    }

                    ScrollView {
                        if filteredTargets.isEmpty, model.capturePermissionDenied {
                            VStack(spacing: 13) {
                                Image(systemName: "rectangle.inset.filled.badge.record")
                                    .font(.system(size: 34, weight: .light))
                                    .foregroundStyle(StudioTheme.yellow)
                                Text("Screen Recording needs attention")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Enable Focus Studio in System Settings → Privacy & Security → Screen & System Audio Recording. If it is already enabled, toggle it off and on once, then relaunch Focus Studio.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(StudioTheme.secondaryText)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 430)
                                if let details = model.captureFailureDetails {
                                    Text(details)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(StudioTheme.secondaryText.opacity(0.72))
                                        .multilineTextAlignment(.center)
                                        .textSelection(.enabled)
                                        .lineLimit(4)
                                        .frame(maxWidth: 480)
                                }
                                HStack(spacing: 9) {
                                    Button("Open Settings") {
                                        model.openScreenRecordingSettings()
                                    }
                                    .buttonStyle(PrimaryButtonStyle())
                                    Button("Relaunch") {
                                        model.relaunchApplication()
                                    }
                                    .buttonStyle(.bordered)
                                    Button("Retry") {
                                        Task { await model.showRecorder() }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 70)
                            .studioPanel()
                        } else if filteredTargets.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: kind == .window ? "macwindow.badge.plus" : "display.trianglebadge.exclamationmark")
                                    .font(.system(size: 32, weight: .light))
                                    .foregroundStyle(StudioTheme.secondaryText)
                                Text(LocalizedStringKey(kind == .window ? "No recordable windows found" : "No display found"))
                                    .font(.system(size: 14, weight: .semibold))
                                Text(LocalizedStringKey(kind == .window
                                    ? "Open the product window you want to demonstrate, then refresh the source list."
                                    : "Connect or enable a display, then refresh the source list."))
                                    .font(.system(size: 10))
                                    .foregroundStyle(StudioTheme.secondaryText)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 380)
                                Button("Refresh sources") {
                                    Task { await model.showRecorder() }
                                }
                                .buttonStyle(.bordered)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 70)
                            .studioPanel()
                        } else {
                            SourceGridView(
                                preview: model.sourcePreview,
                                targets: filteredTargets,
                                kind: kind,
                                areaTarget: kind == .area ? model.selectedAreaTarget : nil,
                                isSelected: targetIsSelected,
                                onSelect: selectTargetCard
                            )
                            .padding(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Recording settings")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.bottom, 16)

                    SettingToggle(
                        title: "System audio",
                        subtitle: "Optional; macOS may ask when enabled",
                        icon: "speaker.wave.2",
                        isOn: $model.recordSystemAudio
                    )
                    Divider().overlay(StudioTheme.line)
                    SettingToggle(
                        title: "Microphone",
                        subtitle: "Record your selected input",
                        icon: "mic",
                        isOn: $model.recordMicrophone
                    )
                    Divider().overlay(StudioTheme.line)
                    SettingToggle(
                        title: "Automatic zooms",
                        subtitle: "Create a zoom wherever you click",
                        icon: "plus.magnifyingglass",
                        isOn: $model.automaticZooms
                    )
                    if model.selectedTargetSupportsBrowserContentCrop {
                        Divider().overlay(StudioTheme.line)
                        SettingToggle(
                            title: "Webpage only",
                            subtitle: "Hide browser tabs and toolbar",
                            icon: "rectangle.inset.filled",
                            isOn: $model.browserContentOnly
                        )
                        if model.browserContentOnly {
                            Divider().overlay(StudioTheme.line)
                            SettingToggle(
                                title: "Hide bookmarks bar",
                                subtitle: "Also remove the saved-links row",
                                icon: "bookmark",
                                isOn: $model.hideBrowserBookmarksBar
                            )
                        }
                    }

                    Divider().overlay(StudioTheme.line)
                        .padding(.vertical, 14)

                    HStack {
                        Label("Frame rate", systemImage: "speedometer")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Picker("Frame rate", selection: $model.frameRate) {
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }

                    Spacer()

                    if kind == .area {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(
                                selectedAreaIsReady
                                    ? (model.selectedAreaTarget?.title ?? L10n.tr("Selected area"))
                                    : L10n.tr("Choose a display, then draw the recording area"),
                                systemImage: selectedAreaIsReady ? "checkmark.rectangle" : "rectangle.dashed"
                            )
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(selectedAreaIsReady ? StudioTheme.purple : StudioTheme.secondaryText)

                            if selectedAreaIsReady, let area = model.selectedAreaTarget {
                                Text(verbatim: "\(Int(area.frame.width.rounded())) × \(Int(area.frame.height.rounded()))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(StudioTheme.secondaryText)
                                Button("Reselect area") {
                                    chooseRecordingArea()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(StudioTheme.purple)
                            }
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.025))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }

                    HStack(spacing: 8) {
                        Image(systemName: model.automaticZooms && !model.interactionTrackingAuthorized ? "exclamationmark.triangle" : "checkmark.shield")
                            .foregroundStyle(model.automaticZooms && !model.interactionTrackingAuthorized ? StudioTheme.yellow : StudioTheme.secondaryText)
                        Text("Permissions")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        if model.automaticZooms {
                            if !model.accessibilityAuthorized {
                                Button("Accessibility") { model.openAccessibilitySettings() }
                            }
                            if !model.inputMonitoringAuthorized {
                                Button("Input Monitoring") { model.openInputMonitoringSettings() }
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Screen-only recording starts without optional permission prompts. Input Monitoring captures clicks; Accessibility keeps zoom focused while you type and detects text cursors. Enable these in Privacy & Security when needed.")

                    Button {
                        if kind == .area, !selectedAreaIsReady {
                            chooseRecordingArea()
                        } else {
                            model.startRecordingCountdown()
                        }
                    } label: {
                        Label(LocalizedStringKey(primaryActionTitle), systemImage: primaryActionIcon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: StudioTheme.red))
                    .disabled(primaryActionDisabled)
                    .padding(.top, 18)
                }
                .padding(20)
                .frame(width: 330)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .studioPanel()
            }
            .padding(24)
        }
        .environment(\.locale, localization.locale)
        .onChange(of: kind) { _, newKind in
            switch newKind {
            case .display:
                model.selectedTargetID = displayTargets.first?.id
            case .window:
                model.selectedTargetID = preferredBrowserWindow?.id
                    ?? model.captureEngine.availableTargets.first(where: { $0.kind == .window })?.id
            case .area:
                if areaDisplayID == nil {
                    areaDisplayID = displayTargets.first?.id
                }
                if let area = model.selectedAreaTarget,
                   displayTargets.contains(where: { $0.nativeID == area.nativeID }) {
                    areaDisplayID = displayTargets.first(where: { $0.nativeID == area.nativeID })?.id
                    model.selectedTargetID = area.id
                } else {
                    model.selectedTargetID = selectedAreaDisplay?.id
                }
            }
        }
        .onAppear {
            model.refreshInteractionTrackingPermission()
            areaDisplayID = model.selectedAreaTarget.flatMap { area in
                displayTargets.first(where: { $0.nativeID == area.nativeID })?.id
            } ?? displayTargets.first?.id
            guard let selectedKind = model.selectedTarget?.kind else {
                model.selectedTargetID = preferredBrowserWindow?.id
                    ?? model.captureEngine.availableTargets.first(where: { $0.kind == .window })?.id
                    ?? displayTargets.first?.id
                kind = model.selectedTarget?.kind ?? .window
                return
            }
            kind = selectedKind
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshInteractionTrackingPermission()
        }
        .onAppear { syncSourcePreview() }
        .onDisappear { model.sourcePreview.stop() }
        .onChange(of: filteredTargets.map(\.id)) { _, _ in syncSourcePreview() }
        .onChange(of: model.selectedTargetID) { _, _ in syncSourcePreview() }
        .onChange(of: areaDisplayID) { _, _ in syncSourcePreview() }
        .onChange(of: model.isSelectingArea) { _, selecting in
            // The area selection overlay covers the display; pause previews
            // so the live stream never shows the selection UI itself.
            if selecting { model.sourcePreview.stop() } else { syncSourcePreview() }
        }
        .alert("Interaction tracking needs setup", isPresented: $model.isShowingInteractionSetup) {
            if !model.accessibilityAuthorized {
                Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
            }
            if !model.inputMonitoringAuthorized {
                Button("Open Input Monitoring Settings") { model.openInputMonitoringSettings() }
            }
            Button("Record with limited tracking") {
                model.startRecordingCountdown(allowUnavailableTracking: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Automatic zooms are on, but interaction permissions are incomplete. Enable Accessibility and Input Monitoring for Focus Studio, then return. Otherwise clicks or typing may not generate zooms; granting access later cannot restore missing events in this recording.")
        }
    }

    private var sourceHint: String {
        switch kind {
        case .display:
            return "Entire display includes the macOS menu bar and Dock. Window or Area is cleaner for a product demo."
        case .window:
            return "Recommended for product demos: other apps and the macOS menu bar stay out. Browser controls can be hidden below."
        case .area:
            return "Draw an exact fixed region. Only that rectangle is encoded, including screenshots and cursor coordinates."
        }
    }

    private var primaryActionTitle: String {
        if model.isSelectingArea { return "Selecting area…" }
        if kind == .area, !selectedAreaIsReady { return "Select recording area" }
        return "Start recording"
    }

    private var primaryActionIcon: String {
        kind == .area && !selectedAreaIsReady ? "rectangle.dashed" : "record.circle"
    }

    private var primaryActionDisabled: Bool {
        if model.isSelectingArea { return true }
        switch kind {
        case .display:
            return model.selectedTarget?.kind != .display
        case .window:
            return model.selectedTarget?.kind != .window
        case .area:
            return selectedAreaDisplay == nil
        }
    }

    private func targetIsSelected(_ target: CaptureTargetInfo) -> Bool {
        if kind == .area {
            return selectedAreaDisplay?.id == target.id
        }
        return model.selectedTargetID == target.id
    }

    private func selectTargetCard(_ target: CaptureTargetInfo) {
        if kind == .area {
            areaDisplayID = target.id
            if let area = model.selectedAreaTarget, area.nativeID == target.nativeID {
                model.selectedTargetID = area.id
            } else {
                model.selectedTargetID = target.id
            }
        } else {
            model.selectedTargetID = target.id
        }
    }

    private func chooseRecordingArea() {
        guard let display = selectedAreaDisplay else { return }
        Task { await model.selectRecordingArea(on: display) }
    }

    /// The selected card streams live; every other visible card refreshes
    /// about once per second. Nothing runs once the picker is gone.
    private func syncSourcePreview() {
        guard !model.isSelectingArea, !model.capturePermissionDenied else { return }
        let liveID: String?
        switch kind {
        case .area:
            liveID = selectedAreaDisplay?.id
        case .display, .window:
            liveID = model.selectedTarget?.kind == kind ? model.selectedTargetID : nil
        }
        model.sourcePreview.start(targets: filteredTargets, liveTargetID: liveID)
    }
}

/// Observes the preview provider separately from the picker so a new frame
/// only redraws the cards, not the settings column.
private struct SourceGridView: View {
    @ObservedObject var preview: SourcePreviewProvider
    let targets: [CaptureTargetInfo]
    let kind: CaptureTargetKind
    let areaTarget: CaptureTargetInfo?
    let isSelected: (CaptureTargetInfo) -> Bool
    let onSelect: (CaptureTargetInfo) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
            ForEach(targets) { target in
                TargetCard(
                    target: target,
                    isSelected: isSelected(target),
                    preview: preview.images[target.id],
                    isLive: preview.liveTargetID == target.id && preview.images[target.id] != nil,
                    areaFrame: areaTarget.flatMap { area in
                        area.nativeID == target.nativeID ? area.frame : nil
                    }
                ) {
                    onSelect(target)
                }
            }
        }
    }
}

struct RecordingCountdownView: View {
    @EnvironmentObject private var model: StudioModel
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 22) {
            Text("Get ready")
                .font(.system(size: 17, weight: .semibold, design: .rounded))

            ZStack {
                Circle()
                    .fill(StudioTheme.red.opacity(0.16))
                    .frame(width: 150, height: 150)
                    .scaleEffect(pulse ? 1.06 : 0.96)
                Circle()
                    .stroke(StudioTheme.red.opacity(0.38), lineWidth: 2)
                    .frame(width: 118, height: 118)
                Text("\(model.recordingCountdown)")
                    .font(.system(size: 70, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: model.recordingCountdown)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulse = true }
            }

            Text(model.selectedTarget?.title ?? L10n.tr("Selected source"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StudioTheme.secondaryText)

            Button("Cancel") {
                model.cancelRecordingCountdown()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
        }
        .padding(48)
        .frame(width: 460)
        .studioPanel()
        .environment(\.locale, localization.locale)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording countdown")
    }
}

private struct TargetCard: View {
    let target: CaptureTargetInfo
    let isSelected: Bool
    let preview: CGImage?
    let isLive: Bool
    let areaFrame: CaptureRect?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                    if let preview {
                        GeometryReader { proxy in
                            let fitted = fittedRect(for: preview, in: proxy.size)
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .interpolation(.medium)
                                .frame(width: fitted.width, height: fitted.height)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .position(x: fitted.midX, y: fitted.midY)
                            if let areaFrame {
                                let rect = areaRect(areaFrame, in: fitted)
                                Rectangle()
                                    .fill(Color.black.opacity(0.42))
                                    .frame(width: fitted.width, height: fitted.height)
                                    .position(x: fitted.midX, y: fitted.midY)
                                    .mask {
                                        Rectangle()
                                            .overlay(alignment: .topLeading) {
                                                Rectangle()
                                                    .frame(width: rect.width, height: rect.height)
                                                    .offset(x: rect.minX - fitted.minX, y: rect.minY - fitted.minY)
                                                    .blendMode(.destinationOut)
                                            }
                                            .compositingGroup()
                                            .frame(width: fitted.width, height: fitted.height)
                                    }
                                Rectangle()
                                    .stroke(StudioTheme.purple, lineWidth: 1.5)
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                            }
                        }
                        .padding(6)
                        .transition(.opacity)
                    } else {
                        Image(systemName: target.kind == .display ? "display" : "macwindow")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(.white.opacity(0.52))
                            .transition(.opacity)
                    }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white, StudioTheme.purple)
                            .symbolRenderingMode(.palette)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(9)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    if isLive {
                        HStack(spacing: 4) {
                            Circle().fill(StudioTheme.red).frame(width: 5, height: 5)
                            Text("LIVE")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.6)
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(9)
                        .transition(.opacity)
                        .accessibilityLabel("Live preview")
                    }
                }
                .frame(height: 130)
                .animation(reduceMotion ? nil : StudioMotion.fade, value: preview == nil)
                .animation(reduceMotion ? nil : StudioMotion.fade, value: isLive)

                VStack(alignment: .leading, spacing: 3) {
                    Text(target.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(target.appName ?? "\(Int(target.frame.width)) × \(Int(target.frame.height))")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(9)
            .background(isSelected ? StudioTheme.purple.opacity(0.17) : StudioTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(isSelected ? StudioTheme.purple : StudioTheme.line, lineWidth: isSelected ? 2 : 1)
            )
            .animation(reduceMotion ? nil : StudioMotion.selection, value: isSelected)
        }
        .buttonStyle(.plain)
        .hoverLift()
        .accessibilityLabel(
            "\(target.appName.map { "\($0), " } ?? "")\(target.title), \(Int(target.frame.width)) by \(Int(target.frame.height))"
        )
        .accessibilityValue(Text(LocalizedStringKey(isSelected ? "Selected" : "Not selected")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func fittedRect(for image: CGImage, in size: CGSize) -> CGRect {
        let imageRatio = Double(max(1, image.width)) / Double(max(1, image.height))
        let boxRatio = size.width / max(1, size.height)
        let fitted: CGSize = imageRatio > boxRatio
            ? CGSize(width: size.width, height: size.width / imageRatio)
            : CGSize(width: size.height * imageRatio, height: size.height)
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    /// Maps a global area rectangle onto the display thumbnail.
    private func areaRect(_ area: CaptureRect, in fitted: CGRect) -> CGRect {
        let scaleX = fitted.width / max(1, target.frame.width)
        let scaleY = fitted.height / max(1, target.frame.height)
        let x = fitted.minX + (area.x - target.frame.x) * scaleX
        let y = fitted.minY + (area.y - target.frame.y) * scaleY
        return CGRect(x: x, y: y, width: area.width * scaleX, height: area.height * scaleY)
            .intersection(fitted)
    }
}

private struct SettingToggle: View {
    let title: String
    let subtitle: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StudioTheme.secondaryText)
                .frame(width: 22)
            Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .medium))
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
        .padding(.vertical, 11)
        .help(LocalizedStringKey(subtitle))
    }
}

struct ActiveRecordingView: View {
    @EnvironmentObject private var model: StudioModel
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(StudioTheme.red.opacity(0.15))
                    .frame(width: 94, height: 94)
                Circle()
                    .fill(StudioTheme.red)
                    .frame(width: 46, height: 46)
                    .overlay(Circle().stroke(Color.white.opacity(0.65), lineWidth: 3))
            }
            RecordingDurationLabel(captureEngine: model.captureEngine)
            Text("Recording \(model.selectedTarget?.title ?? L10n.tr("screen"))")
                .font(.system(size: 14))
                .foregroundStyle(StudioTheme.secondaryText)

            HStack(spacing: 12) {
                Button {
                    Task { await model.cancelRecording() }
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                Button {
                    Task { await model.takeScreenshot() }
                } label: {
                    Label(LocalizedStringKey(model.isTakingScreenshot ? "Capturing…" : "Screenshot"), systemImage: "camera")
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .disabled(model.isTakingScreenshot)

                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Label("Finish recording", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryButtonStyle(tint: StudioTheme.red))
            }

            RecordingInteractionStatusLabel(captureEngine: model.captureEngine)

            if let warning = model.inputWarning {
                VStack(spacing: 8) {
                    Label(LocalizedStringKey(warning), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTheme.yellow)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 390)
                    HStack {
                        if model.needsInputMonitoring {
                            Button("Input Monitoring") { model.openInputMonitoringSettings() }
                        }
                        if model.needsAccessibility {
                            Button("Accessibility") { model.openAccessibilitySettings() }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let notice = model.screenshotNotice {
                Button {
                    model.revealLastScreenshot()
                } label: {
                    Label(notice, systemImage: model.lastScreenshotURL == nil ? "exclamationmark.triangle" : "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.lastScreenshotURL == nil ? StudioTheme.yellow : Color.green)
            }
        }
        .padding(44)
        .frame(width: 520)
        .studioPanel()
        .environment(\.locale, localization.locale)
    }
}

/// Observe the capture clock so this reports events actually received, rather
/// than claiming success just because a system event monitor was registered.
private struct RecordingInteractionStatusLabel: View {
    @ObservedObject var captureEngine: CaptureEngine

    var body: some View {
        let diagnostics = captureEngine.eventMonitor.diagnostics
        let hasInteractions = diagnostics.storedClicks > 0 || diagnostics.storedTypingActivity > 0
        Group {
            if hasInteractions {
                Text("Captured: \(diagnostics.storedClicks) clicks · \(diagnostics.storedTypingActivity) input updates")
            } else {
                Text("Waiting for interactions. Click or type inside the recorded source to verify tracking.")
            }
        }
            .font(.system(size: 11))
            .foregroundStyle(!hasInteractions && captureEngine.duration > 5 ? StudioTheme.yellow : StudioTheme.secondaryText)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("recording.interactionStatus")
    }
}

/// `StudioModel` owns the engine, but ObservableObject does not automatically
/// forward changes from nested objects. Observe the engine directly so the
/// large in-window timer advances alongside the floating controller.
private struct RecordingDurationLabel: View {
    @ObservedObject var captureEngine: CaptureEngine

    var body: some View {
        Text(captureEngine.duration.formattedDuration)
            .font(.system(size: 52, weight: .medium, design: .monospaced))
            .monospacedDigit()
    }
}
