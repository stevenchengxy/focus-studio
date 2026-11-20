import FocusStudioCapture
import FocusStudioCore
import Foundation

/// Numeric regressions for intent-preserving pointer finishing. Synthetic inputs
/// deliberately separate hand wobble from actions whose path is product content.
func cursorStabilityFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append("cursor stability: " + message) }
    }
    func finish(_ samples: [CursorSample], clicks: [ClickEvent] = []) -> [CursorSample] {
        CursorMotion.smoothedPath(samples: samples, clicks: clicks, sigma: 0.085)
    }
    func length(_ samples: [CursorSample]) -> Double {
        zip(samples, samples.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }
    func point(_ time: Double, _ samples: [CursorSample]) -> CursorSample {
        TimelineMath.cursorPosition(at: time, samples: samples)!
    }
    let winding = (0...168).map { index -> CursorSample in
        let time = Double(index) / 120
        return CursorSample(time: time, x: 0.15 + 0.65 * time / 1.4,
                            y: 0.5 + 0.023 * sin(16 * .pi * time / 1.4), isDragging: false)
    }
    let direct = finish(winding)
    let lengthRatio = length(direct) / length(winding)
    expect(lengthRatio < 0.65, "small free-move detours converge (length ratio \(lengthRatio))")
    expect(direct.allSatisfy { abs($0.y - 0.5) < 0.002 }, "free movement follows its stable intended route")
    expect(winding[1].isDragging == false && abs(winding[1].y - 0.5) > 0.001, "raw observations remain unchanged")
    expect(CursorMotion.smoothedPath(samples: winding, clicks: [], sigma: 0) == winding, "none keeps the exact original route")
    let legacy = winding.map { CursorSample(time: $0.time, x: $0.x, y: 0.5 + 0.02 * sin(.pi * $0.time / 1.4)) }
    let legacyFinished = finish(legacy)
    expect(point(0.7, legacyFinished).y > 0.518, "unknown legacy button state is not treated as free movement")

    // Larger intentional turns are not replaced by a click-to-click diagonal.
    let corner = (0...168).map { index -> CursorSample in
        let time = Double(index) / 120
        let u = time / 1.4
        return CursorSample(time: time, x: 0.2 + 0.6 * u, y: 0.5 + 0.18 * sin(.pi * u), isDragging: false)
    }
    expect(point(0.7, finish(corner)).y > 0.65, "large intentional corners survive simplification")

    let actions = (0...140).map { index -> CursorSample in
        let time = Double(index) / 100
        return CursorSample(time: time, x: 0.15 + 0.65 * time / 1.4,
                            y: 0.5 + 0.07 * sin(9 * time),
                            cursorKind: time >= 1 ? .pointingHand : .arrow,
                            isDragging: time >= 0.35 && time < 0.9)
    }
    let actionFinished = finish(actions)
    for sample in actions where sample.isDragging == true || sample.cursorKind == .pointingHand {
        let rendered = point(sample.time, actionFinished)
        expect(hypot(rendered.x - sample.x, rendered.y - sample.y) < 1e-9,
               "drag/semantic-hover path must be exact at \(sample.time)")
    }
    expect(point(0.9, actionFinished).isDragging == false, "release state survives interpolation")
    let presses = [ClickEvent(time: 0.413, x: 0.343, y: 0.5, button: .left),
                   ClickEvent(time: 0.431, x: 0.351, y: 0.503, button: .left)]
    let pressed = finish(winding, clicks: presses)
    for click in presses {
        let actual = point(click.time, pressed)
        expect(hypot(actual.x - click.x, actual.y - click.y) < 1e-12,
               "rapid off-grid clicks stay exact at their own times")
    }
    expect(zip(pressed, pressed.dropFirst()).allSatisfy { $0.time < $1.time }, "click insertion cannot duplicate timestamps")
    expect(InteractionCursorMotion.smoothedPath(samples: winding, clicks: presses, sigma: 0.085) == pressed,
           "execution and physical capture share one finishing implementation")

    let stop = (0...180).map { index -> CursorSample in
        let time = Double(index) / 120
        let x = time < 0.4 ? 0.1 + 0.35 * time / 0.4 : time < 0.8 ? 0.45 : 0.45 + 0.35 * (time - 0.8) / 0.7
        return CursorSample(time: time, x: x, y: 0.5, isDragging: false)
    }
    let stopped = finish(stop)
    expect(abs(point(0.6, stopped).x - 0.45) < 0.0015, "a hover dwell remains at its observed position and time")
    expect(abs(point(0.55, stopped).x - point(0.65, stopped).x) < 0.002, "a deliberate dwell does not become one continuous sweep")

    let shortHover = (0...258).map { index -> CursorSample in
        let t = Double(index) / 120
        let x = t < 1 ? 0.2 + 0.6 * t : t < 1.15 ? 0.8 : 0.8 - 0.6 * (t - 1.15)
        return CursorSample(time: t, x: x, y: 0.5, isDragging: false)
    }
    let shortHoverFinished = finish(shortHover)
    expect(abs(point(1.075, shortHoverFinished).x - 0.8) < 0.001,
           "a 150ms tooltip/menu hover remains on target instead of rounding through the stop")

    var settings = ProjectSettings()
    settings.zoomEaseIn = 0.1
    settings.zoomEaseOut = 0.1
    let zooms = [ZoomSegment(start: 0, end: 3, targetX: 0.5, targetY: 0.5, scale: 2)]
    let quiet = (0...180).map { i in
        CursorSample(time: Double(i) / 60, x: 0.5 + 0.1 * sin(Double(i) * 0.3), y: 0.5)
    }
    let quietOffsets = CursorFollow.offsets(duration: 3, segments: zooms, settings: settings, cursor: quiet, strength: 1)
    expect(quietOffsets.allSatisfy { abs($0.dx) < 1e-12 && abs($0.dy) < 1e-12 }, "pointer motion within quiet zone cannot shake the zoomed image")
    let away = [CursorSample(time: 0, x: 0.95, y: 0.5), CursorSample(time: 3, x: 0.95, y: 0.5)]
    let hiddenOffsets = InteractionCursorFollow.offsets(duration: 3, segments: zooms, settings: settings,
        cursor: away, strength: 1, discontinuities: [1.5], cursorIsAvailable: { $0 < 1.5 || $0 >= 2.5 })
    expect(CursorFollow.offset(at: 1.4, samples: hiddenOffsets).dx > 0.2, "follow still moves for targets outside the viewport centre")
    expect(CursorFollow.offset(at: 2.4, samples: hiddenOffsets).dx == 0, "hidden interval resets camera inertia")
    expect(CursorFollow.offset(at: 2.5, samples: hiddenOffsets).dx < 0.01, "reappearance cannot inherit a previous shot's framing")

    let beforeCut = winding.map { sample -> CursorSample in var sample = sample; sample.time *= 0.7; return sample }
    let afterCut = winding.map { sample -> CursorSample in var sample = sample; sample.time += 1; sample.x = 1 - sample.x; return sample }
    let cut = EditedTimelineMotion.cursorPath(samples: beforeCut + afterCut, clicks: [], duration: 2.4, cutTimes: [1], sigma: 0.085)
    let independent = finish(afterCut)
    expect(abs(point(0.999, cut).x - beforeCut.last!.x) < 0.002, "pre-cut tail cannot glide to the next source")
    expect(hypot(point(1, cut).x - independent.first!.x, point(1, cut).y - independent.first!.y) < 1e-12,
           "post-cut motion starts from its own shot, without smoothing across a splice")

    do {
        let project = RecordingProject(title: "Motion regression", sourceVideoPath: "/synthetic.mov", duration: 1.4,
                                       sourceWidth: 1920, sourceHeight: 1080, cursorSamples: actions)
        let edit = try DemoTimelineEdit(keepRanges: [.init(start: 0.4, end: 0.8)], sourceDuration: 1.4)
        let retimed = edit.remap(project, sourceVideoPath: "/synthetic-edit.mov")
        expect(retimed.cursorSamples.allSatisfy { $0.isDragging == true }, "edit remapping retains held-button metadata")
        expect(retimed.cursorSamples.first?.time == 0, "retimed drag starts on the new timeline")
        let terminal = ClickEvent(time: 1.4, x: 0.79, y: 0.51, button: .left)
        let terminalPath = EditedTimelineMotion.cursorPath(samples: winding, clicks: [terminal], duration: 1.4, cutTimes: [], sigma: 0.085)
        expect(point(1.4, terminalPath).x == terminal.x && point(1.4, terminalPath).y == terminal.y,
               "a click on the terminal frame belongs to the final shot")
        let old = try JSONDecoder().decode(CursorSample.self, from: Data(#"{"time":1,"x":0.2,"y":0.3}"#.utf8))
        expect(old.isDragging == nil, "old projects decode button state as unknown")
        let known = actions[50]
        let roundTripped = try JSONDecoder().decode(CursorSample.self, from: JSONEncoder().encode(known))
        expect(roundTripped == known, "new button metadata round trips")
    } catch { failures.append("cursor stability: metadata compatibility \(error)") }

    #if DEBUG
    MainActor.assumeIsolated {
        let monitor = EventMonitor()
        do {
            try monitor.prepare(captureRect: .init(x: 0, y: 0, width: 100, height: 100), targetProcessID: 42)
            defer { monitor.stop() }
            monitor.anchor(at: 100)
            monitor.minimumSampleInterval = 1
            monitor.injectEventForTesting(uptime: 100.5, x: 30, y: 30, button: .left, cursorKind: .arrow)
            monitor.injectEventForTesting(uptime: 100.501, x: 31, y: 30, cursorKind: .arrow, isDragging: true)
            monitor.injectEventForTesting(uptime: 100.502, x: 32, y: 30, cursorKind: .arrow, isDragging: false)
            expect(monitor.cursorSamples.suffix(2).map(\.isDragging) == [true, false],
                   "mouse-up is saved even inside the move throttle window")
            expect(monitor.clickEvents.count == 1, "release/drag metadata cannot generate extra clicks")
        } catch { failures.append("cursor stability: capture state fixture failed: \(error)") }
    }
    #endif

    // 60 seconds / 7,201 input samples: the finishing pass runs during prepare,
    // not per frame. This generous debug-build guard catches accidental O(n²).
    let benchmarkSeconds = min(600, max(60, Double(ProcessInfo.processInfo.environment["FOCUS_STUDIO_CURSOR_BENCHMARK_SECONDS"] ?? "60") ?? 60))
    let long = (0...Int(benchmarkSeconds * 120)).map { index -> CursorSample in
        let t = Double(index) / 120
        return CursorSample(time: t, x: 0.5 + 0.3 * sin(t), y: 0.5 + 0.02 * sin(t * 30), isDragging: false)
    }
    let started = ProcessInfo.processInfo.systemUptime
    let longFinished = finish(long)
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    expect(elapsed < 8 * benchmarkSeconds / 60, "cursor finishing stays bounded (\(elapsed)s)")
    expect(longFinished.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "long paths produce finite output")
    print(String(format: "Cursor stability metrics: free-path length %.1f%%; %.0fs prepare %.3fs", lengthRatio * 100, benchmarkSeconds, elapsed))
    return failures
}
