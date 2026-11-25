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

    // Free travel is replanned between action/hover anchors, rather than merely
    // deleting sub-threshold wiggles from an otherwise winding polyline.
    let corner = (0...168).map { index -> CursorSample in
        let time = Double(index) / 120
        let u = time / 1.4
        return CursorSample(time: time, x: 0.2 + 0.6 * u, y: 0.5 + 0.18 * sin(.pi * u), isDragging: false)
    }
    let cornerFinished = finish(corner)
    expect(abs(point(0.7, cornerFinished).y - 0.5) < 0.001, "uninterrupted free-arrow detours become a direct glide")
    expect(zip(cornerFinished, cornerFinished.dropFirst()).allSatisfy { $1.x >= $0.x - 1e-10 },
           "a direct glide cannot overshoot or reverse between endpoints")

    let actions = (0...140).map { index -> CursorSample in
        let time = Double(index) / 100
        return CursorSample(time: time, x: 0.15 + 0.65 * time / 1.4,
                            y: 0.5 + 0.07 * sin(9 * time),
                            cursorKind: time >= 1 ? .pointingHand : .arrow,
                            isDragging: time >= 0.35 && time < 0.9)
    }
    let actionFinished = finish(actions)
    for sample in actions where sample.isDragging == true {
        let rendered = point(sample.time, actionFinished)
        expect(hypot(rendered.x - sample.x, rendered.y - sample.y) < 1e-9,
               "drag path must be exact at \(sample.time)")
    }
    expect(point(0.9, actionFinished).isDragging == false, "release state survives interpolation")
    // The previous implementation explicitly disabled its filter inside every
    // stationary cluster and hand/I-beam span. These are its counterexamples.
    func rms(_ values: [CursorSample], axis: (CursorSample) -> Double, target: Double) -> Double {
        sqrt(values.reduce(0) { $0 + pow(axis($1) - target, 2) } / Double(max(1, values.count)))
    }
    let tremor = (0...240).map { i -> CursorSample in
        let t = Double(i) / 120
        return CursorSample(time: t, x: 0.5 + 0.002 * sin(2 * .pi * 12 * t),
                            y: 0.5 + 0.001 * cos(2 * .pi * 10 * t), isDragging: false)
    }
    let settled = finish(tremor)
    let settledInterior = settled.filter { $0.time > 0.2 && $0.time < 1.8 }
    expect(rms(settledInterior, axis: { $0.x }, target: 0.5) < 0.0002,
           "a stationary cluster removes tremor instead of bypassing de-jitter")
    expect((settledInterior.map(\.x).max()! - settledInterior.map(\.x).min()!) < 0.0003,
           "stationary pointer is locked to one spatial target")
    for kind in [CursorKind.pointingHand, .iBeam] {
        let hand = (0...240).map { i -> CursorSample in
            let t = Double(i) / 120
            return CursorSample(time: t, x: 0.2 + 0.2 * t, y: 0.5 + 0.004 * sin(2 * .pi * 9 * t),
                                cursorKind: kind, isDragging: false)
        }
        let cleaned = finish(hand).filter { $0.time > 0.25 && $0.time < 1.75 }
        expect(rms(cleaned, axis: { $0.y }, target: 0.5) < 0.0007,
               "\(kind) movement is gently de-jittered rather than pinned at every raw point")
        expect(cleaned.allSatisfy { $0.cursorKind == kind }, "trajectory finishing retains semantic cursor shape")
    }
    let slow = (0...240).map { i -> CursorSample in
        let t = Double(i) / 120
        return CursorSample(time: t, x: 0.4 + 0.004 * t, y: 0.5, isDragging: false)
    }
    let slowFinished = finish(slow)
    for t in stride(from: 0.3, through: 1.5, by: 0.2) {
        expect(point(t + 0.2, slowFinished).x - point(t, slowFinished).x > 0.0006,
               "a slow intentional adjustment never becomes linked stationary windows")
    }
    expect(abs(point(1, slowFinished).x - 0.404) < 0.0003, "slow intentional movement keeps its timing")

    // A menu hover is an intermediate destination even when the shape stays arrow.
    let menu = (0...240).map { i -> CursorSample in
        let t = Double(i) / 120
        if t < 0.7 { return .init(time: t, x: 0.2 + 0.5 * t / 0.7, y: 0.25, isDragging: false) }
        if t < 1 { return .init(time: t, x: 0.7, y: 0.25, isDragging: false) }
        return .init(time: t, x: 0.7, y: 0.25 + 0.5 * (t - 1), isDragging: false)
    }
    let menuFinished = finish(menu)
    expect(hypot(point(0.85, menuFinished).x - 0.7, point(0.85, menuFinished).y - 0.25) < 0.001,
           "a real dropdown hover is never skipped by one start-to-finish diagonal")
    expect(point(0.9, menuFinished).cursorKind == .arrow, "a real hover needs no hand shape to remain an anchor")

    let sparse = [CursorSample(time: 0, x: 0.2, y: 0.3, isDragging: false),
                  CursorSample(time: 0.1, x: 0.22, y: 0.3, isDragging: false),
                  CursorSample(time: 5.658, x: 0.7, y: 0.8, isDragging: false),
                  CursorSample(time: 5.75, x: 0.72, y: 0.8, isDragging: false)]
    let held = finish(sparse)
    for t in [0.5, 2, 5.5, 5.657] {
        expect(abs(point(t, held).x - 0.22) < 1e-9 && abs(point(t, held).y - 0.3) < 1e-9,
               "event-driven 5.558s gap holds its last observation without fabricated motion")
    }
    expect(abs(point(5.658, held).x - 0.7) < 1e-12, "re-entry starts at the new observed coordinate")
    let cleanFirst = finish(Array(sparse.prefix(2)))
    expect(hypot(point(0.05, held).x - point(0.05, cleanFirst).x,
                 point(0.05, held).y - point(0.05, cleanFirst).y) < 1e-12,
           "Gaussian cannot borrow future observations across a gap")

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

    // Validate the visible result, not only independent source-space curves.
    let stableZoom = [ZoomSegment(start: 0, end: 4, targetX: 0.5, targetY: 0.5, scale: 2)]
    let framingPath = (0...240).map { i -> CursorSample in
        let t = Double(i) / 60
        let x = t < 0.5 ? 0.5 : t < 1 ? 0.5 + 0.45 * (t - 0.5) / 0.5 : t < 1.8 ? 0.95 : 0.8
        return .init(time: t, x: x, y: 0.5, isDragging: false)
    }
    let framing = CursorFollow.offsets(duration: 4, segments: stableZoom, settings: settings, cursor: framingPath, strength: 1)
    let heldFrame = CursorFollow.offset(at: 1.7, samples: framing).dx
    let readingFrame = CursorFollow.offset(at: 3, samples: framing).dx
    expect(abs(readingFrame - heldFrame) < 0.002,
           "returning the pointer inside the shifted viewport does not pull the camera back")
    func visiblePointer(_ time: Double) -> Double {
        var camera = TimelineMath.zoomState(at: time, segments: stableZoom, settings: settings)
        camera.centerX += CursorFollow.offset(at: time, samples: framing).dx
        let position = point(time, framingPath)
        return Double(ZoomFrameTransform(state: camera, width: 1920, height: 1080).mappedPoint(x: position.x, y: position.y).x)
    }
    expect(abs(visiblePointer(2.2) - visiblePointer(3)) < 0.001,
           "the rendered pointer stays still after it settles inside the final composition")
    let entering = CursorFollow.offsets(duration: 3, segments: zooms, settings: settings, cursor: away, strength: 1)
    expect(abs(CursorFollow.offset(at: 0.05, samples: entering).dx) < 1e-12,
           "an authored zoom entrance cannot simultaneously chase an unrelated pointer target")
    expect(abs(CursorFollow.offset(at: 3, samples: entering).dx) < 1e-12,
           "camera following returns fully to overview after the authored exit")

    // One measured move inside the outer safety band, after the camera has
    // engaged. Compare its response while keeping the shot and pointer fixed.
    let singleMove = [CursorSample(time: 0, x: 0.5, y: 0.5), CursorSample(time: 1, x: 0.68, y: 0.5)]
    func followAtSpeed(_ speed: Double?) -> [CursorFollow.Sample] {
        var speedSettings = settings
        speedSettings.cursorAnimation = .none
        speedSettings.zoomFollowSpeed = speed
        return CursorFollow.offsets(duration: 3, segments: zooms, settings: speedSettings,
                                    cursor: singleMove, strength: 1)
    }
    let slowPan = followAtSpeed(0.25), originalPan = followAtSpeed(1), fastPan = followAtSpeed(2)
    let earlySlow = CursorFollow.offset(at: 1.05, samples: slowPan).dx
    let earlyOriginal = CursorFollow.offset(at: 1.05, samples: originalPan).dx
    let earlyFast = CursorFollow.offset(at: 1.05, samples: fastPan).dx
    expect(earlyOriginal - earlySlow > 0.025 && earlyFast - earlyOriginal > 0.01,
           "slow and fast response visibly change the same pan at fixed strength")
    let target = 0.18 - 0.25 * CursorFollow.softZone
    let originalResponse = target * (1 - exp(-(4.0 / 60) / 0.052))
    expect(abs(earlyOriginal - originalResponse) < 1e-9 && followAtSpeed(nil) == originalPan,
           "1× and legacy projects reproduce the original 52 ms response")
    expect([slowPan, originalPan, fastPan].allSatisfy { abs(CursorFollow.offset(at: 2.8, samples: $0).dx - target) < 0.0001 },
           "all speeds settle on the same composition")

    // A fast diagonal crosses most of the *cropped* picture, then doubles
    // back. Check the output hotspot at 120 fps, including between camera
    // samples and while the authored automatic zoom is still entering.
    let followCrop = SourceCropInsets(top: 0.10, leading: 0.08, bottom: 0.12, trailing: 0.20)
    var travelSettings = settings
    travelSettings.zoomEaseIn = 0.8
    travelSettings.zoomFollowSpeed = ProjectSettings.zoomFollowSpeedRange.lowerBound
    let fastCue = [ZoomSegment(start: 0, end: 3, targetX: 0.3, targetY: 0.35, scale: 2.5)]
    let travel = (0...360).map { index -> CursorSample in
        let time = Double(index) / 120
        let out = ((time - 0.30) / 0.28).clamped(to: 0...1)
        let back = ((time - 1.30) / 0.28).clamped(to: 0...1)
        let source = followCrop.sourcePoint(x: 0.30 + 0.58 * (out - back), y: 0.35 + 0.44 * (out - back))
        return CursorSample(time: time, x: source.x, y: source.y)
    }
    let fastFrame = CursorFollow.offsets(duration: 3, segments: fastCue, settings: travelSettings,
                                         cursor: travel, strength: travelSettings.resolvedZoomFollowsCursor, sourceCrop: followCrop)
    var worstDistanceFromCenter = 0.0
    for sample in travel where (0.24...2).contains(sample.time) {
        var camera = TimelineMath.zoomState(at: sample.time, segments: fastCue, settings: travelSettings)
        let follow = CursorFollow.offset(at: sample.time, samples: fastFrame)
        camera.centerX += follow.dx
        camera.centerY += follow.dy
        let cropped = followCrop.croppedPoint(x: sample.x, y: sample.y)!
        let hotspot = ZoomFrameTransform(state: camera, width: 1280, height: 800).mappedPoint(x: cropped.x, y: cropped.y)
        worstDistanceFromCenter = max(worstDistanceFromCenter, abs(hotspot.x - 0.5), abs(hotspot.y - 0.5))
    }
    expect(worstDistanceFromCenter < 0.44,
           "a fast pointer stays inside the visible cropped frame through automatic zoom-in, hold and reversal (\(worstDistanceFromCenter))")

    // Missing crop samples once created a fictional diagonal between the
    // last and next visible points. Raw mode must sample the observed point
    // first and freeze the framing when it falls outside the recorded crop.
    var rawFollow = settings
    rawFollow.cursorAnimation = .none
    let rawPath: [CursorSample] = [
        .init(time: 0, x: 0.44, y: 0.49), .init(time: 0.6, x: 0.97, y: 0.8),
        .init(time: 1.8, x: 0.73, y: 0.75), .init(time: 2.5, x: 0.73, y: 0.75)
    ]
    let rawFrame = CursorFollow.offsets(duration: 3, segments: zooms, settings: rawFollow, cursor: rawPath,
                                        strength: 1, sourceCrop: followCrop)
    expect(TimelineMath.cursorPosition(at: 1.79, samples: rawPath, interpolate: false)?.x == 0.97,
           "raw pointer stays on the last observed pixel until its next timestamp")
    expect(rawFrame.filter { $0.time < 1.8 }.allSatisfy { abs($0.dx) + abs($0.dy) < 1e-10 },
           "hidden raw samples cannot fabricate camera movement inside the crop")
    expect(CursorFollow.offset(at: 2.4, samples: rawFrame).dx > 0.15,
           "re-entering a crop uses the newly measured point in cropped coordinates")

    // Event-driven capture stores no samples while the pointer is still. The
    // tiny hold/jump inserted into its rendered path must not masquerade as a
    // navigation cut and snap a shifted camera back to its original centre.
    var resumeAfterPause = (0...96).map { i -> CursorSample in
        let t = Double(i) / 60
        let x = t < 0.4 ? 0.5 : t < 1.2 ? 0.5 + 0.38 * (t - 0.4) / 0.8 : 0.88
        return .init(time: t, x: x, y: 0.5, isDragging: false)
    }
    resumeAfterPause += [CursorSample(time: 2, x: 0.885, y: 0.5, isDragging: false),
                         CursorSample(time: 2.1, x: 0.89, y: 0.5, isDragging: false),
                         CursorSample(time: 2.2, x: 0.895, y: 0.5, isDragging: false)]
    let resumedPointer = finish(resumeAfterPause)
    let resumedFraming = CursorFollow.offsets(duration: 4, segments: stableZoom, settings: settings,
                                              cursor: resumedPointer, strength: 1)
    let beforeResume = CursorFollow.offset(at: 2 - 1.0 / 60, samples: resumedFraming).dx
    let atResume = CursorFollow.offset(at: 2, samples: resumedFraming).dx
    let afterResume = CursorFollow.offset(at: 2 + 1.0 / 60, samples: resumedFraming).dx
    expect(beforeResume > 0.15, "gap regression starts from an already shifted composition")
    expect(abs(atResume - beforeResume) < 0.003 && abs(afterResume - atResume) < 0.003,
           "a 400ms sampling pause followed by a small move cannot reset camera framing")
    let explicitCutFraming = CursorFollow.offsets(duration: 4, segments: stableZoom, settings: settings,
                                                  cursor: resumedPointer, strength: 1, discontinuities: [2])
    expect(abs(CursorFollow.offset(at: 2, samples: explicitCutFraming).dx) < 1e-12,
           "an explicit source cut still clears old camera framing at the same timestamp")

    let beforeCut = winding.map { sample -> CursorSample in var sample = sample; sample.time *= 0.7; return sample }
    let afterCut = winding.map { sample -> CursorSample in var sample = sample; sample.time += 1; sample.x = 1 - sample.x; return sample }
    let cut = EditedTimelineMotion.cursorPath(samples: beforeCut + afterCut, clicks: [], duration: 2.4, cutTimes: [1], sigma: 0.085)
    let independent = finish(afterCut)
    expect(abs(point(0.999, cut).x - beforeCut.last!.x) < 0.002, "pre-cut tail cannot glide to the next source")
    expect(hypot(point(1, cut).x - independent.first!.x, point(1, cut).y - independent.first!.y) < 1e-12,
           "post-cut motion starts from its own shot, without smoothing across a splice")

    do {
        var versioned = ProjectSettings()
        expect(versioned.resolvedZoomFollowSpeed == 0.75, "new projects start with gentler follow")
        versioned.zoomFollowSpeed = nil
        let legacySettings = try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(versioned))
        expect(legacySettings.zoomFollowSpeed == nil && legacySettings.resolvedZoomFollowSpeed == 1,
               "settings written before follow speed decode at the original speed")
        versioned.zoomFollowSpeed = 1.45
        let savedSettings = try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(versioned))
        expect(savedSettings.resolvedZoomFollowSpeed == 1.45, "custom follow speed survives a project reload")
        for (value, expected) in [(-3.0, 0.25), (3, 2), (Double.nan, 1)] {
            versioned.zoomFollowSpeed = value
            expect(versioned.resolvedZoomFollowSpeed == expected, "malformed follow speeds stay safe")
        }
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
