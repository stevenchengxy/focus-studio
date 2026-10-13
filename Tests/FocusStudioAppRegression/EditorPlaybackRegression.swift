import AppKit
import Foundation
import FocusStudioCore

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
        regionEffectPlacement()
        print("EditorPlaybackRegression: PASS (transport, frame stepping, timeline pointer snapping and end bounds)")
    }

    private static func regionEffectPlacement() {
        var project = RecordingProject(title: "Region timing", sourceVideoPath: "/fixture.mp4",
            duration: 10, sourceWidth: 1000, sourceHeight: 700)
        let clip = DemoVideoClip(id: project.id, sourceStart: 0, sourceEnd: 10)
        let rect = NormalizedRegionRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        let first = RegionEffect(clipID: clip.id, sourceStart: 2, sourceEnd: 4, rect: rect)
        let second = RegionEffect(clipID: clip.id, sourceStart: 6, sourceEnd: 9, rect: rect)
        project.regionEffects = [first, second]
        precondition(EditorRegionTiming.availableRange(in: clip, project: project, near: 3) == 4...6,
                     "Adding over an existing effect chooses the next free interval")
        let duplicate = EditorRegionTiming.duplicate(first, project: project)!
        precondition(duplicate.id != first.id && duplicate.sourceStart == 4 && duplicate.sourceEnd == 6,
                     "Duplicate retains style and finds a legal non-overlapping slot")
        precondition(duplicate.rect == first.rect && duplicate.preset == first.preset)
        let trimmed = DemoVideoClip(id: clip.id, sourceStart: 3, sourceEnd: 8)
        precondition(EditorRegionTiming.availableRange(in: trimmed, project: project, near: 3) == 4...6,
                     "Hidden source ranges still block conflicts when editing a trimmed clip")
        precondition(EditorRegionTiming.availableRange(in: trimmed, project: project, near: 4.5,
                                                       excludingID: first.id) == 3...6,
                     "Dragging the selected effect excludes itself and stops at the neighboring effect")
        project.regionEffects?[0].isEnabled = false
        precondition(EditorRegionTiming.availableRange(in: clip, project: project, near: 2) == 0...6,
                     "Disabled effects do not block a new emphasis")
        let late = RegionEffect(clipID: clip.id, sourceStart: 8, sourceEnd: 10, rect: rect)
        precondition(EditorRegionTiming.selectionSourceTime(effect: late, clip: clip,
                         timelineStart: 0, currentTime: 0) == 9,
                     "Reselecting a later effect must show its midpoint, not an unrelated page at the playhead")
        precondition(EditorRegionTiming.selectionSourceTime(effect: late, clip: clip,
                         timelineStart: 0, currentTime: 8.5) == 8.5,
                     "Reselect retains the playhead only when it is within the selected effect")
        let partiallyTrimmed = DemoVideoClip(id: clip.id, sourceStart: 9, sourceEnd: 10)
        precondition(EditorRegionTiming.selectionSourceTime(effect: late, clip: partiallyTrimmed,
                         timelineStart: 4, currentTime: 0) == 9.5,
                     "A partially hidden effect uses the visible midpoint")
        let fullyTrimmed = DemoVideoClip(id: clip.id, sourceStart: 0, sourceEnd: 5)
        let hiddenTime = EditorRegionTiming.selectionSourceTime(effect: late, clip: fullyTrimmed,
            timelineStart: 0, currentTime: 0)
        precondition(hiddenTime == 9 && EditorRegionTiming.decodableSourceTime(hiddenTime,
            sourceBounds: 0...10, frameRate: 30) == 9,
            "A completely hidden effect must decode its own frame outside the current trim")
        project.regionEffects = (0..<128).map { _ in
            RegionEffect(clipID: clip.id, sourceStart: 2, sourceEnd: 4, rect: rect, isEnabled: false)
        }
        precondition(EditorRegionTiming.duplicate(project.regionEffects![0], project: project) == nil,
                     "Both UI duplicate entry points must refuse a 129th effect even when there is free time")
        project.regionEffects?.removeLast()
        precondition(EditorRegionTiming.duplicate(project.regionEffects![0], project: project) != nil,
                     "The 128th valid effect remains allowed")
        project.regionEffects = [RegionEffect(clipID: clip.id, sourceStart: 0, sourceEnd: 9.95, rect: rect)]
        precondition(EditorRegionTiming.availableRange(in: clip, project: project, near: 0) == nil,
                     "A gap shorter than the 0.1-second minimum cannot create an invalid effect")
    }

}
