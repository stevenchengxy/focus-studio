import FocusStudioCapture
import FocusStudioAutomation
import SwiftUI

struct RecordingPickerView: View {
    @EnvironmentObject private var model: StudioModel

    var body: some View {
        if model.usesSystemCapturePicker {
            SystemRecordingSetupView()
        } else {
            LegacyRecordingPickerView()
        }
    }
}

/// Source consent belongs to macOS; Focus Studio only asks how to record it.
private struct SystemRecordingSetupView: View {
    @EnvironmentObject private var model: StudioModel
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.destination = .library } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Back to library")
                Spacer()
                Text("New recording").font(.system(size: 14, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 32, height: 30)
            }
            .padding(.horizontal, 22)
            .frame(height: 58)
            .background(StudioTheme.panel)
            Divider().overlay(StudioTheme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Ready to record?")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Button { model.chooseSystemCaptureSource() } label: {
                        HStack(spacing: 16) {
                            Image(systemName: model.selectedTarget?.kind == .display ? "display" : "macwindow")
                                .font(.system(size: 28)).foregroundStyle(StudioTheme.purple)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.selectedTarget?.title ?? L10n.tr("Choose a window or display"))
                                    .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                                if let app = model.selectedTarget?.appName {
                                    Text(verbatim: app).font(.system(size: 12)).foregroundStyle(StudioTheme.secondaryText)
                                }
                            }
                            Spacer(minLength: 12)
                            if model.isSelectingSystemContent { ProgressView().controlSize(.small) }
                            else { Image(systemName: "chevron.up.chevron.down").foregroundStyle(StudioTheme.secondaryText) }
                        }
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(StudioTheme.inset, in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isSelectingSystemContent || model.isWaitingForMicrophoneAccess)
                    .accessibilityIdentifier("recording.system.source")
                    if model.selectedTarget?.kind == .display {
                        Label("Recording controls stay in the menu bar", systemImage: "menubar.rectangle")
                            .font(.system(size: 12)).foregroundStyle(StudioTheme.secondaryText)
                    }

                    VStack(spacing: 18) {
                        Toggle(isOn: $model.recordMicrophone) { Label("Microphone", systemImage: "mic") }
                        Toggle(isOn: $model.recordSystemAudio) { Label("System audio", systemImage: "speaker.wave.2") }
                        Toggle(isOn: $model.automaticZooms) { Label("Automatic zooms", systemImage: "plus.magnifyingglass") }
                        DisclosureGroup("More options") {
                            VStack(alignment: .leading, spacing: 16) {
                                Toggle("Show cursor", isOn: $model.showRecordingCursor)
                                if model.selectedTargetSupportsBrowserContentCrop {
                                    Toggle("Webpage only", isOn: $model.browserContentOnly)
                                    if model.browserContentOnly {
                                        Toggle("Hide bookmarks bar", isOn: $model.hideBrowserBookmarksBar)
                                    }
                                }
                                Picker("Frame rate", selection: $model.frameRate) {
                                    Text("30 fps").tag(30)
                                    Text("60 fps").tag(60)
                                }
                                HStack {
                                    if !model.accessibilityAuthorized {
                                        Button("Accessibility") { model.openAccessibilitySettings() }
                                    }
                                    if !model.inputMonitoringAuthorized {
                                        Button("Input Monitoring") { model.openInputMonitoringSettings() }
                                    }
                                }.controlSize(.small)
                            }.padding(.top, 16)
                        }.foregroundStyle(StudioTheme.secondaryText)
                    }
                    .toggleStyle(.switch)
                    .padding(22).studioPanel()

                    HStack {
                        Button("Record an area") { Task { await model.showAreaRecorder() } }
                            .buttonStyle(.plain).foregroundStyle(StudioTheme.secondaryText)
                            .accessibilityIdentifier("recording.system.area")
                        Spacer()
                        Button { model.startRecordingCountdown() } label: {
                            Label("Start recording", systemImage: "record.circle")
                        }
                        .buttonStyle(PrimaryButtonStyle(tint: StudioTheme.red))
                        .disabled(model.selectedTarget == nil || model.isSelectingSystemContent || model.isBusy || model.isWaitingForMicrophoneAccess)
                        .accessibilityIdentifier("recording.system.start")
                    }
                    .disabled(model.isSelectingSystemContent || model.isWaitingForMicrophoneAccess)
                }
                .frame(maxWidth: 560).padding(40).frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(StudioTheme.text)
        .environment(\.locale, localization.locale)
        .onAppear { model.refreshInteractionTrackingPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshInteractionTrackingPermission()
        }
        .alert("Interaction tracking needs setup", isPresented: $model.isShowingInteractionSetup) {
            if !model.accessibilityAuthorized {
                Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
            }
            if !model.inputMonitoringAuthorized {
                Button("Open Input Monitoring Settings") { model.openInputMonitoringSettings() }
            }
            Button("Record with limited tracking") { model.startRecordingCountdown(allowUnavailableTracking: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable interaction access for automatic click zooms and cursor effects.")
        }
    }
}
