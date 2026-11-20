import AppKit
import FocusStudioAutomation

/// Full-display system sharing cannot exclude our floating window without
/// replacing its authorized filter. Standard menu-bar controls remain usable
/// while the application and its floating panels are hidden.
@MainActor
final class SystemRecordingMenuBar: NSObject, NSMenuDelegate {
    static let shared = SystemRecordingMenuBar()
    private weak var model: StudioModel?
    private var item: NSStatusItem?

    func sync(_ model: StudioModel) {
        guard let app = NSApp, app.activationPolicy() == .regular else { return }
        guard model.hidesControlsForSystemCapture,
              [.countdown, .recording].contains(model.destination) else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            self.model = nil
            return
        }
        self.model = model
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: L10n.tr("Recording controls"))
        item.button?.toolTip = L10n.tr("Focus Studio recording")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        let live = model.destination == .recording && !model.isFinishingRecording
        let pause = NSMenuItem(title: L10n.tr(model.isRecordingPaused ? "Resume recording" : "Pause recording"),
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.isEnabled = live && !model.isChangingRecordingPause
        menu.addItem(pause)
        let screenshot = NSMenuItem(title: L10n.tr("Screenshot"), action: #selector(screenshot), keyEquivalent: "")
        screenshot.target = self
        screenshot.isEnabled = live && !model.isTakingScreenshot
        menu.addItem(screenshot)
        menu.addItem(.separator())
        let finish = NSMenuItem(title: L10n.tr("Finish recording"), action: #selector(finish), keyEquivalent: "")
        finish.target = self
        finish.isEnabled = !model.isFinishingRecording
        menu.addItem(finish)
        menu.autoenablesItems = false
    }

    @objc private func togglePause() {
        guard let model else { return }
        Task { await model.toggleRecordingPause() }
    }

    @objc private func screenshot() {
        guard let model else { return }
        Task { await model.takeScreenshot() }
    }

    @objc private func finish() {
        guard let model else { return }
        if model.destination == .countdown { model.cancelRecordingCountdown() }
        else { Task { await model.stopRecording() } }
    }
}
