import FocusStudioCore
import Foundation

func cueFollowSpeedFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ message: String) {
        if !condition { failures.append("Cue follow speed: " + message) }
    }

    var settings = ProjectSettings()
    settings.zoomFollowSpeed = 1.5
    settings.screenAnimation = .smooth
    settings.cursorAnimation = .none
    let older = ZoomSegment(start: 0, end: 5, targetX: 0.5, targetY: 0.5, scale: 2,
                            isInstant: true, zoomFollowSpeed: 0.25)
    var newer = ZoomSegment(start: 1, end: 4, targetX: 0.5, targetY: 0.5, scale: 2,
                            zoomEaseIn: 1, zoomEaseOut: 1, zoomFollowSpeed: 2)

    // Measure the first camera step for an identical pointer movement in the
    // middle of each cue and halfway across both directions of the handoff.
    func checkResponse(at time: Double, rate: Double) {
        let cursor = [CursorSample(time: 0, x: 0.5, y: 0.5), CursorSample(time: time, x: 0.68, y: 0.5)]
        let track = CursorFollow.offsets(duration: 5, segments: [newer, older], settings: settings,
                                         cursor: cursor, strength: 1)
        let target = 0.18 - 0.25 * CursorFollow.softZone
        let expected = target * -expm1(-rate / (CursorFollow.sampleRate * CursorFollow.response))
        expect(abs(CursorFollow.offset(at: time, samples: track).dx - expected) < 1e-9,
               "expected \(rate)× camera response at \(time)s")
    }
    checkResponse(at: 0.5, rate: 0.25)
    checkResponse(at: 1.5, rate: 1.125)
    checkResponse(at: 2.25, rate: 2)
    checkResponse(at: 3.5, rate: 1.125)
    checkResponse(at: 4.5, rate: 0.25)
    newer.isEnabled = false
    checkResponse(at: 2.25, rate: 0.25)
    newer.isEnabled = true
    newer.zoomFollowSpeed = nil
    checkResponse(at: 2.25, rate: 1.5)
    newer.zoomFollowSpeed = .nan
    expect(newer.resolvedZoomFollowSpeed(settings: settings) == 1.5, "invalid override inherits project speed")
    newer.zoomFollowSpeed = 9
    expect(newer.resolvedZoomFollowSpeed(settings: settings) == 2, "override uses the project's allowed range")

    // After a video edit, either authored cue may span the splice. Give
    // their IDs the opposite order to their start times to catch local
    // rebasing which made two ongoing cues appear to start together.
    var earlierCue = older, laterCue = newer
    earlierCue.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
    laterCue.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    laterCue.zoomFollowSpeed = 2
    let cut = 1.223, emptyShot = 1.777, nextShot = 3.0
    let cuts = [cut, emptyShot, nextShot]
    let cutPath = [CursorSample(time: 0, x: 0.68, y: 0.5),
                   CursorSample(time: cut, x: 0.5, y: 0.5),
                   CursorSample(time: 1.5, x: 0.68, y: 0.5),
                   CursorSample(time: nextShot, x: 0.3, y: 0.5)]
    let editedPath = EditedTimelineMotion.cursorPath(samples: cutPath, clicks: [], duration: 5, cutTimes: cuts, sigma: 0)
    let edited = EditedTimelineMotion.followOffsets(duration: 5, segments: [laterCue, earlierCue],
        settings: settings, cursor: editedPath, strength: 1, cutTimes: cuts)
    expect(CursorFollow.offset(at: cut.nextDown, samples: edited).dx > 0.07 &&
           CursorFollow.offset(at: cut, samples: edited).dx == 0, "a splice resets inertia exactly on its own frame")
    let firstTick = (cut * CursorFollow.sampleRate).rounded(.up) / CursorFollow.sampleRate
    expect(edited.contains { $0.time == firstTick }, "fractional cuts retain the global camera sample grid")
    let midpointStep = (0.18 - 0.25 * CursorFollow.softZone) * -expm1(-1.125 / (60 * CursorFollow.response))
    expect(abs(CursorFollow.offset(at: 1.5, samples: edited).dx - midpointStep) < 1e-9,
           "overlapping zooms retain their authored order and half-finished handoff across a cut")
    expect(edited.filter { (emptyShot..<nextShot).contains($0.time) }.allSatisfy { $0.dx == 0 && $0.dy == 0 },
           "a shot without pointer data cannot borrow motion from the previous clip")

    do {
        newer.zoomFollowSpeed = nil
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let inherited = try decoder.decode(ZoomSegment.self, from: encoder.encode(newer))
        expect(inherited.zoomFollowSpeed == nil, "old cues continue inheriting after a reload")
        let custom = try decoder.decode(ZoomSegment.self, from: encoder.encode(older))
        expect(custom.zoomFollowSpeed == 0.25, "custom rate survives saving and reopening the project")
        var project = RecordingProject(title: "Cue speed fixture", sourceVideoPath: "/fixture.mov",
                                       duration: 5, sourceWidth: 960, sourceHeight: 540,
                                       clickEvents: [.init(time: 1, x: 0.5, y: 0.5, button: .left)], settings: settings)
        TimelineMath.regenerateAutomaticZoomSegments(in: &project)
        guard let id = project.zoomSegments.first?.id else { return failures + ["Expected an automatic cue"] }
        project.zoomSegments[0].zoomFollowSpeed = 0.35
        TimelineMath.regenerateAutomaticZoomSegments(in: &project)
        expect(project.zoomSegments.first?.id == id && project.zoomSegments.first?.zoomFollowSpeed == 0.35,
               "regenerating the same automatic cue retains its override")
        project.zoomSegments = [older]
        let edit = try DemoTimelineEdit(keepRanges: [.init(start: 0, end: 1), .init(start: 2, end: 4)], sourceDuration: 5)
        let cut = edit.remap(project, sourceVideoPath: "/edit.mov")
        expect(cut.zoomSegments.map(\.zoomFollowSpeed) == [0.25, 0.25], "both retained excerpts keep the override")
        let timeline = try DemoVideoTimeline(project: project)
        let split = try timeline.applying(.split(clipID: timeline.clips[0].id, at: 2), to: project)
        expect(split.zoomSegments.map(\.zoomFollowSpeed) == [0.25, 0.25], "splitting a clip preserves both cue speeds")
        let moved = ZoomTiming.applying(.move(1), to: older, projectDuration: 6, settings: settings)
        expect(moved.kind == .manual && moved.zoomFollowSpeed == 0.25, "manual timing edits preserve the override")
    } catch { failures.append("Cue follow speed fixture: \(error)") }
    return failures
}
