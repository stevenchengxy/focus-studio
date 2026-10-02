import AppKit
import Foundation

@MainActor
enum EditorPlaybackRegression {
    static func run() {
        func command(_ key: UInt16, _ modifiers: NSEvent.ModifierFlags = [], repeat repeated: Bool = false, editing: Bool = false) -> EditorTransportCommand? {
            EditorTransportCommand.resolve(keyCode: key, modifiers: modifiers, isRepeat: repeated, isEditingText: editing)
        }
        precondition(command(49) == .togglePlayback)
        precondition(command(49, repeat: true) == nil, "Holding Space must not toggle playback repeatedly")
        for key: UInt16 in [49, 123, 124, 115, 119, 1, 53] {
            precondition(command(key, editing: true) == nil, "Editor shortcuts must leave typing and IME input alone")
            for modifiers: NSEvent.ModifierFlags in [.command, .control, .option] {
                precondition(command(key, modifiers) == nil, "System and application shortcuts retain their modifiers")
            }
        }
        precondition(command(123) == .step(-1) && command(124) == .step(1))
        precondition(command(123, .shift) == .jump(-5) && command(124, .shift) == .jump(5))
        precondition(command(115) == .beginning && command(119) == .end)
        precondition(command(1) == .split && command(1, repeat: true) == nil && command(1, .shift) == nil)
        precondition(command(53) == .deselect)
        for rate in [24, 30, 60] {
            let next = EditorTransportCommand.steppedTime(1, frames: 1, frameRate: rate, duration: 10)
            precondition(abs(next - (1 + 1 / Double(rate))) < 0.000001)
            precondition(EditorTransportCommand.steppedTime(0, frames: -1, frameRate: rate, duration: 10) == 0)
            precondition(EditorTransportCommand.steppedTime(10, frames: 1, frameRate: rate, duration: 10) == 10)
            let frame = TimelineFramePosition.index(x: 250, width: 1_000, duration: 4, frameRate: rate)
            precondition(frame == rate, "Timeline pointer must snap to a project frame")
            precondition(abs(TimelineFramePosition.time(for: frame, duration: 4, frameRate: rate) - 1) < 0.000001)
        }
        precondition(TimelineFramePosition.index(x: -20, width: 100, duration: 9.847, frameRate: 30) == 0)
        let finalFrame = TimelineFramePosition.index(x: 100, width: 100, duration: 9.847, frameRate: 30)
        precondition(TimelineFramePosition.time(for: finalFrame, duration: 9.847, frameRate: 30) == 9.847,
                     "Clicking the right edge must reach an ending between frames")
        precondition(TimelineFramePosition.index(x: .nan, width: 100, duration: 9.847, frameRate: 30) == 0)
        precondition(59.9996.editorTimecode == "01:00.000", "Timecode carries milliseconds into the next minute")
        precondition((-1.0).editorTimecode == "00:00.000")
        print("EditorPlaybackRegression: PASS (transport, frame stepping, timeline pointer snapping and end bounds)")
    }
}
