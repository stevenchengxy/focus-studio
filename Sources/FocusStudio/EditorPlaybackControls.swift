import AppKit
import FocusStudioCore
import SwiftUI

/// AVPlayer's frequent position reports belong to the transport display, not
/// to the editor document. The editor holds this reference in State without
/// observing it; only small time-dependent controls subscribe to its changes.
@MainActor
final class EditorPlaybackClock: ObservableObject {
    @Published private(set) var time = 0.0

    func update(_ time: Double) {
        guard time.isFinite else { return }
        let bounded = max(0, time)
        guard bounded != self.time else { return }
        self.time = bounded
        EditorPlaybackMetrics.record("clock")
    }
}

struct EditorPlaybackTimeReader<Content: View>: View {
    @ObservedObject var clock: EditorPlaybackClock
    @ViewBuilder var content: (Double) -> Content

    var body: some View { content(clock.time) }
}

/// Opt-in diagnostics for real playback runs. No per-frame logging is enabled
/// in normal use. Counts distinguish broad editor invalidations from the
/// deliberately small transport/playhead updates; they are not an FPS claim.
@MainActor
enum EditorPlaybackMetrics {
    private static let enabled = ProcessInfo.processInfo.environment["FOCUS_STUDIO_PROFILE_EDITOR"] == "1"
    private static var counts: [String: Int] = [:]
    private static var started = ProcessInfo.processInfo.systemUptime

    static func record(_ name: String) {
        guard enabled else { return }
        counts[name, default: 0] += 1
        let now = ProcessInfo.processInfo.systemUptime
        guard now - started >= 2 else { return }
        let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        NSLog("EditorPlaybackMetrics %.2fs %@", now - started, summary)
        counts.removeAll(keepingCapacity: true)
        started = now
    }
}

/// Only handles transport keys in this editor's window. Field editors keep all
/// input (including Space, arrows and IME composition) and sheets keep focus.
enum EditorTransportCommand: Equatable {
    case togglePlayback, step(Int), jump(Double), beginning, end, split, undo, redo, deselect

    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool,
                        isEditingText: Bool) -> Self? {
        guard !isEditingText else { return nil }
        if keyCode == 6, modifiers.contains(.command),
           modifiers.intersection([.control, .option]).isEmpty, !isRepeat {
            return modifiers.contains(.shift) ? .redo : .undo
        }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        switch keyCode {
        case 49: return isRepeat || modifiers.contains(.shift) ? nil : .togglePlayback
        case 123: return modifiers.contains(.shift) ? .jump(-5) : .step(-1)
        case 124: return modifiers.contains(.shift) ? .jump(5) : .step(1)
        case 115: return .beginning
        case 119: return .end
        case 1: return isRepeat || modifiers.contains(.shift) ? nil : .split
        case 53: return .deselect
        default: return nil
        }
    }

    static func steppedTime(_ time: Double, frames: Int, frameRate: Int, duration: Double) -> Double {
        let rate = Double(max(1, frameRate))
        return ((time * rate).rounded() / rate + Double(frames) / rate).clamped(to: 0...max(0, duration))
    }
}

struct EditorKeyboardBridge: NSViewRepresentable {
    var enabled: Bool
    var perform: (EditorTransportCommand) -> Void

    func makeNSView(context: Context) -> KeyboardView { KeyboardView() }
    func updateNSView(_ view: KeyboardView, context: Context) {
        view.enabled = enabled
        view.perform = perform
    }
    static func dismantleNSView(_ view: KeyboardView, coordinator: ()) { view.stop() }

    final class KeyboardView: NSView {
        var enabled = true
        var perform: ((EditorTransportCommand) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, let window = self.window,
                      window.isKeyWindow, event.window === window,
                      window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
                let editing = (window.firstResponder as? NSTextView)?.isEditable == true
                if !editing, event.keyCode == 49, event.isARepeat,
                   event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { return nil }
                guard let command = EditorTransportCommand.resolve(
                    keyCode: event.keyCode, modifiers: event.modifierFlags,
                    isRepeat: event.isARepeat, isEditingText: editing
                ) else { return event }
                self.perform?(command)
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { stop() }
    }
}

struct EditorTransportButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? .white : StudioTheme.text)
            .frame(width: prominent ? 38 : 28, height: prominent ? 32 : 28)
            .background(prominent ? StudioTheme.purple : (configuration.isPressed ? StudioTheme.controlPressed : StudioTheme.controlFill))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : StudioMotion.press, value: configuration.isPressed)
    }
}

extension Double {
    var editorTimecode: String {
        let milliseconds = Int((max(0, isFinite ? self : 0) * 1000).rounded())
        return String(format: "%02d:%02d.%03d", milliseconds / 60000, (milliseconds / 1000) % 60, milliseconds % 1000)
    }
}
