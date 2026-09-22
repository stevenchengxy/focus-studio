import FocusStudioCore
import Foundation

/// Pointer smoothing, click anchoring, shape cross-fades and camera follow.
func cursorMotionFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }

    // --- Smoothing removes jitter but keeps the endpoints and click positions ---
    var raw: [CursorSample] = []
    var seed: UInt64 = 42
    func noise() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (Double(seed >> 33) / Double(1 << 31) - 0.5) * 0.006
    }
    for index in 0...240 {
        let time = Double(index) / 60
        raw.append(CursorSample(time: time, x: 0.2 + 0.5 * time / 4 + noise(), y: 0.3 + 0.2 * sin(time) + noise()))
    }
    let clicks = [ClickEvent(time: 1.5, x: 0.41, y: 0.52, button: .left), ClickEvent(time: 3.2, x: 0.6, y: 0.31, button: .left)]
    let smooth = CursorMotion.smoothedPath(samples: raw, clicks: clicks, sigma: CursorMotion.smoothingSigma(for: .smooth))
    expect(smooth.count > raw.count, "the smoothed path is denser than the raw samples")
    expect(zip(smooth, smooth.dropFirst()).allSatisfy { $1.time > $0.time }, "smoothed sample times are strictly increasing")
    expect(CursorMotion.roughness(smooth) < CursorMotion.roughness(raw) * 0.5,
           "smoothing must remove at least half of the raw jitter (raw \(CursorMotion.roughness(raw)), smooth \(CursorMotion.roughness(smooth)))")
    expect(abs(smooth.first!.x - raw.first!.x) < 0.02 && abs(smooth.last!.x - raw.last!.x) < 0.02,
           "smoothing must not drag the endpoints")
    for click in clicks {
        let at = TimelineMath.cursorPosition(at: click.time, samples: smooth)!
        expect(abs(at.x - click.x) < 0.002 && abs(at.y - click.y) < 0.002,
               "the pointer must land exactly on the click at \(click.time)s (got \(at.x), \(at.y))")
        let before = TimelineMath.cursorPosition(at: click.time - 0.06, samples: smooth)!
        expect(abs(before.x - at.x) < 0.05, "click anchoring must blend in, not jump")
    }
    expect(CursorMotion.smoothedPath(samples: raw, clicks: clicks, sigma: 0) == raw.sorted { $0.time < $1.time },
           "a zero sigma returns the raw samples untouched")
    expect(CursorMotion.smoothingSigma(for: .none) == 0 && CursorMotion.smoothingSigma(for: .smooth) > CursorMotion.smoothingSigma(for: .rapid),
           "smoothing widths are ordered by style")

    // --- Shape cross-fade -------------------------------------------------------
    let shapes = [
        CursorSample(time: 0, x: 0.5, y: 0.5, cursorKind: .arrow),
        CursorSample(time: 0.5, x: 0.5, y: 0.5, cursorKind: .arrow),
        CursorSample(time: 1.0, x: 0.5, y: 0.5, cursorKind: .iBeam),
        CursorSample(time: 1.5, x: 0.5, y: 0.5, cursorKind: .iBeam),
        CursorSample(time: 2.0, x: 0.5, y: 0.5, cursorKind: .arrow),
    ]
    let changes = CursorMotion.kindChangeIndices(shapes)
    expect(changes == [2, 4], "shape changes are detected at the right samples")
    let before = CursorMotion.kindTransition(at: 0.7, samples: shapes, changeIndices: changes)
    expect(before.to == .arrow && before.progress == 1, "no transition before the first change")
    let mid = CursorMotion.kindTransition(at: 1.07, samples: shapes, changeIndices: changes)
    expect(mid.from == .arrow && mid.to == .iBeam && abs(mid.progress - 0.5) < 0.01,
           "half-way through the fade both shapes are visible (\(mid.progress))")
    let done = CursorMotion.kindTransition(at: 1.4, samples: shapes, changeIndices: changes)
    expect(done.to == .iBeam && done.progress == 1, "the fade completes after its duration")
    let back = CursorMotion.kindTransition(at: 2.05, samples: shapes, changeIndices: changes)
    expect(back.from == .iBeam && back.to == .arrow && back.progress < 1, "returning to the arrow fades as well")

    // --- Camera follow ----------------------------------------------------------
    var settings = ProjectSettings()
    settings.zoomEaseIn = 0.3
    settings.zoomEaseOut = 0.3
    let zoom = [ZoomSegment(start: 1, end: 5, targetX: 0.3, targetY: 0.5, scale: 2)]
    // The pointer walks out of the zoomed viewport to the right during the hold.
    let walk = stride(from: 0.0, through: 6.0, by: 1 / 60).map { time -> CursorSample in
        let x = time < 2 ? 0.3 : min(0.85, 0.3 + (time - 2) * 0.25)
        return CursorSample(time: time, x: x, y: 0.5)
    }
    let offsets = CursorFollow.offsets(duration: 6, segments: zoom, settings: settings, cursor: walk, strength: 1)
    expect(!offsets.isEmpty, "follow offsets are produced when enabled")
    let early = CursorFollow.offset(at: 1.8, samples: offsets)
    expect(abs(early.dx) < 0.01, "no drift while the pointer sits inside the safe zone (\(early.dx))")
    let late = CursorFollow.offset(at: 4.2, samples: offsets)
    expect(late.dx > 0.15, "the camera drifts toward a pointer that left the viewport (\(late.dx))")
    let after = CursorFollow.offset(at: 5.4, samples: offsets)
    expect(abs(after.dx) < 0.02, "the drift vanishes once the camera has returned to the overview (\(after.dx))")
    let steps = stride(from: 2.0, through: 4.5, by: 1 / 60).map { CursorFollow.offset(at: $0, samples: offsets).dx }
    let velocities = zip(steps, steps.dropFirst()).map { $1 - $0 }
    let jerk = zip(velocities, velocities.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    let maxVelocity = velocities.map(abs).max() ?? 0
    expect(jerk < 0.35 * max(maxVelocity, 1e-9), "the drift is smooth (jerk \(jerk) vs velocity \(maxVelocity))")
    expect(CursorFollow.offsets(duration: 6, segments: zoom, settings: settings, cursor: walk, strength: 0).isEmpty,
           "strength 0 disables following")
    expect(ProjectSettings().resolvedZoomFollowsCursor == ProjectSettings.defaultZoomFollowsCursor,
           "new projects follow the pointer by default")

    // --- Distance-aware hand-off pans ------------------------------------------
    var panSettings = ProjectSettings()
    panSettings.zoomEaseIn = 0.4
    panSettings.zoomEaseOut = 0.5
    func handoffProgress(distance: Double, at elapsed: Double) -> Double {
        let segments = [
            ZoomSegment(start: 0, end: 4, targetX: 0.5 - distance / 2, targetY: 0.5, scale: 1.75),
            ZoomSegment(start: 1.5, end: 5, targetX: 0.5 + distance / 2, targetY: 0.5, scale: 1.75),
        ]
        let from = TimelineMath.zoomState(at: 1.5, segments: segments, settings: panSettings).centerX
        let to = TimelineMath.zoomState(at: 3.0, segments: segments, settings: panSettings).centerX
        let now = TimelineMath.zoomState(at: 1.5 + elapsed, segments: segments, settings: panSettings).centerX
        return (now - from) / max(1e-9, to - from)
    }
    expect(handoffProgress(distance: 0.4, at: 0.4) < 0.9,
           "a far hand-off is still panning when the scale ease-in ends (\(handoffProgress(distance: 0.4, at: 0.4)))")
    expect(handoffProgress(distance: 0.4, at: 0.4 + TimelineMath.handoffPanExtension) > 0.999,
           "a far hand-off settles by ease-in + extension")
    expect(handoffProgress(distance: 0.05, at: 0.4 + 0.05 * TimelineMath.handoffPanSecondsPerUnit) > 0.999,
           "a short hand-off settles almost as fast as the scale")
    let panPath = stride(from: 1.5, through: 2.4, by: 0.005).map { handoffProgress(distance: 0.4, at: $0 - 1.5) }
    expect(zip(panPath, panPath.dropFirst()).allSatisfy { $1 >= $0 - 1e-9 }, "the hand-off pan is monotonic")
    return failures
}
