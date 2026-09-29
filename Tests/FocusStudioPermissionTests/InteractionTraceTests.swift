import FocusStudioCore
import Foundation

func interactionTraceFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append("Interaction trace: \(message)") }
    }
    let sessionID = UUID()
    let clickID = UUID()
    let click = InteractionEvent(id: clickID, sequence: 3, time: 1.1, kind: .click, x: 0.7, y: 0.4)
    var trace = InteractionTrace(sessionID: sessionID, source: .execution, events: [
        click,
        InteractionEvent(sequence: 1, time: 1, kind: .move, x: 0.2, y: 0.4),
        InteractionEvent(sequence: 2, time: 1.05, kind: .move, x: 0.5, y: 0.4),
        click,
        InteractionEvent(sequence: 4, time: -1, kind: .click, x: 0.1, y: 0.1),
        InteractionEvent(sequence: 5, time: 11, kind: .move, x: 0.1, y: 0.1),
        InteractionEvent(sequence: 6, time: 2, kind: .click, x: .nan, y: 0.1),
        InteractionEvent(sequence: 7, time: 2, kind: .move, x: 1.01, y: 0.1),
        InteractionEvent(sequence: 8, time: 2, kind: .scroll),
    ])
    let resolved = trace.resolved(duration: 10)
    expect(resolved.rejectedEventCount == 5, "out-of-range times, points and missing scroll locations are rejected")
    expect(resolved.deduplicatedEventCount == 1, "replayed event IDs are counted once")
    expect(resolved.cursorSamples.map(\.time) == [1, 1.05, 1.1], "out-of-order batches resolve in media-time order")
    expect(resolved.clickEvents.count == 1 && resolved.clickEvents.first?.id == clickID, "click identity survives for zoom/audio deduplication")
    let smooth = resolved.renderedCursorSamples(sigma: 0.045)
    let atClick = TimelineMath.cursorPosition(at: 1.1, samples: smooth)
    expect(abs((atClick?.x ?? 0) - 0.7) < 0.002 && abs((atClick?.y ?? 0) - 0.4) < 0.002,
           "pointer hot spot and click use the same source and media timestamp")
    expect(zip(smooth, smooth.dropFirst()).allSatisfy { $0.time < $1.time },
           "a floating-point grid boundary does not create duplicate terminal samples")
    let closeClicks = [
        ClickEvent(time: 1.053, x: 0.41, y: 0.4, button: .left),
        ClickEvent(time: 1.103, x: 0.7, y: 0.4, button: .left),
    ]
    let shortPath = InteractionCursorMotion.smoothedPath(
        samples: [CursorSample(time: 1, x: 0.2, y: 0.4), CursorSample(time: 1.103, x: 0.7, y: 0.4)],
        clicks: closeClicks, sigma: 0.045
    )
    expect(closeClicks.allSatisfy { click in
        abs((TimelineMath.cursorPosition(at: click.time, samples: shortPath)?.x ?? 0) - click.x) < 0.000_001
    }, "closely spaced, non-grid clicks and a partial final sample all remain exact anchors")
    expect(!resolved.cursorIsAvailable(at: 0.9), "future pointer observations cannot appear before the first recorded sample")

    let legacy = RecordingProject(
        title: "Manual path invariant", sourceVideoPath: "/tmp/manual.mov", duration: 10,
        sourceWidth: 2000, sourceHeight: 1000,
        cursorSamples: [CursorSample(time: 1.103, x: 0.7, y: 0.4), CursorSample(time: 1, x: 0.2, y: 0.4)],
        clickEvents: closeClicks + [ClickEvent(time: 2, x: .nan, y: 0.4, button: .left)]
    )
    let originalSamples = legacy.cursorSamples
        .filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }.sorted { $0.time < $1.time }
    let originalClicks = legacy.clickEvents.filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }
    for style in CursorAnimationStyle.allCases {
        let sigma = CursorMotion.smoothingSigma(for: style)
        let expected = sigma > 0
            ? CursorMotion.smoothedPath(samples: originalSamples, clicks: originalClicks, sigma: sigma)
            : originalSamples
        expect(legacy.resolvedInteractions.renderedCursorSamples(sigma: sigma) == expected,
               "manual \(style) path is sample-for-sample identical to the original algorithm")
        var systemTrace = trace
        systemTrace.source = .system
        let system = systemTrace.resolved(duration: 10)
        let expectedSystem = sigma > 0
            ? CursorMotion.smoothedPath(samples: system.cursorSamples, clicks: system.clickEvents, sigma: sigma)
            : system.cursorSamples
        expect(system.renderedCursorSamples(sigma: sigma) == expectedSystem,
               "system traces also use the original \(style) algorithm")
    }
    expect(legacy.resolvedClickEvents.map(\.id) == legacy.clickEvents.map(\.id),
           "legacy audio and timeline consumers retain their original unfiltered click metadata")
    var systemProject = legacy
    systemProject.interactionTrace = InteractionTrace(sessionID: UUID(), source: .system, cursorDisplayMode: .hidden)
    systemProject.settings.showCursor = true
    expect(systemProject.resolvedCursorOverlayVisible, "system traces preserve the existing show-cursor setting")
    systemProject.settings.showCursor = false
    expect(!systemProject.resolvedCursorFollowEnabled, "system traces preserve the original hidden-pointer follow gate")

    trace.events = [
        InteractionEvent(sequence: 1, time: 0, kind: .move, x: 0.1, y: 0.4),
        InteractionEvent(sequence: 2, time: 0.1, kind: .click, x: 0.2, y: 0.4),
        InteractionEvent(sequence: 3, time: 5, kind: .click, x: 0.8, y: 0.4),
        InteractionEvent(sequence: 4, time: 6, kind: .discontinuity),
        InteractionEvent(sequence: 5, time: 7, kind: .move, x: 0.4, y: 0.5),
        InteractionEvent(sequence: 6, time: 7.1, kind: .move, x: 0.6, y: 0.5, geometryGeneration: 1),
    ]
    let discontinuous = trace.resolved(duration: 10)
    let path = discontinuous.renderedCursorSamples(sigma: 0.045)
    expect(abs((TimelineMath.cursorPosition(at: 4, samples: path)?.x ?? 0) - 0.2) < 0.002,
           "sparse click anchors do not fabricate a five-second cursor journey")
    expect(!discontinuous.cursorIsAvailable(at: 6.5) && discontinuous.cursorIsAvailable(at: 7),
           "navigation hides stale coordinates until a new observation arrives")
    expect(discontinuous.discontinuityTimes == [6, 7.1], "changed geometry starts a new path without cross-page smoothing")
    expect(abs((TimelineMath.cursorPosition(at: 7.1, samples: path)?.x ?? 0) - 0.6) < 0.002,
           "new-geometry pointer positions are not smoothed into the old page")

    var project = RecordingProject(
        title: "Trace regression", sourceVideoPath: "/tmp/trace.mov", duration: 10,
        sourceWidth: 2000, sourceHeight: 1000,
        cursorSamples: [CursorSample(time: 0, x: 0.95, y: 0.95)],
        clickEvents: [ClickEvent(time: 2, x: 0.95, y: 0.95, button: .left)]
    )
    let legacySamples = project.resolvedInteractions.cursorSamples
    expect(legacySamples == project.cursorSamples, "manual legacy recordings retain system input")
    project.interactionTrace = InteractionTrace(sessionID: sessionID, source: .execution)
    expect(project.resolvedInteractions.cursorSamples.isEmpty && project.resolvedInteractions.clickEvents.isEmpty,
           "an empty execution trace never falls back to someone else's physical mouse")
    project.interactionTrace?.events = [click]
    project.settings.sourceCropInsets = SourceCropInsets(top: 0.2)
    let sourceClick = project.resolvedInteractions.clickEvents[0]
    let crop = project.settings.sourceCropInsets!.croppedPoint(x: sourceClick.x, y: sourceClick.y)
    expect(sourceClick.y == 0.4 && abs((crop?.y ?? 0) - 0.25) < 0.000_001,
           "trace points stay in uncropped frame space so cropping is applied exactly once")
    expect(TimelineMath.hasAutomaticZoomInput(in: project), "trace clicks are eligible for automatic zoom")
    TimelineMath.regenerateAutomaticZoomSegments(in: &project)
    expect(!project.zoomSegments.isEmpty && project.zoomSegments.allSatisfy { abs($0.targetX - 0.7) < 0.000_001 },
           "automatic cues are generated from execution targets, excluding unrelated physical clicks")
    project.interactionTrace?.events = []
    project.typingActivity = [TypingActivity(time: 2, x: 0.5, y: 0.5)]
    expect(!TimelineMath.hasAutomaticZoomInput(in: project), "automatic zoom does not leak legacy physical clicks into an execution recording")
    expect(project.resolvedTypingActivity.isEmpty, "physical typing metadata cannot create zooms in an execution-owned trace")

    let executionTyping = [TypingActivity(time: 0, x: 0.35, y: 0.65),
                           TypingActivity(time: 4, x: 0.35, y: 0.65),
                           TypingActivity(time: 10, x: 0.35, y: 0.65)]
    let invalidTyping = [TypingActivity(time: -1, x: 0.3, y: 0.6),
                         TypingActivity(time: 11, x: 0.3, y: 0.6),
                         TypingActivity(time: .nan, x: 0.3, y: 0.6),
                         TypingActivity(time: 3, x: .infinity, y: 0.6),
                         TypingActivity(time: 3, x: 0.3, y: 1.01)]
    var typedProject = project
    typedProject.interactionTrace?.typingActivity = [executionTyping[2], executionTyping[1], executionTyping[0], executionTyping[1]] + invalidTyping
    expect(typedProject.resolvedTypingActivity == executionTyping,
           "execution typing rejects invalid timing/coordinates, deduplicates and sorts without falling back to physical activity")
    expect(typedProject.interactionTrace?.resolvedTypingActivity(duration: .nan).isEmpty == true,
           "invalid media duration cannot authorize typing activity")
    expect(typedProject.resolvedInteractions.cursorSamples.isEmpty && typedProject.resolvedClickEvents.isEmpty,
           "typing field anchors never manufacture pointer movement or clicks")
    expect(TimelineMath.hasAutomaticZoomInput(in: typedProject), "execution typing is eligible for automatic zooms")
    typedProject.zoomSegments = []
    TimelineMath.regenerateAutomaticZoomSegments(in: &typedProject)
    expect(!typedProject.zoomSegments.isEmpty && typedProject.zoomSegments.allSatisfy { abs($0.targetX - 0.35) < 0.000_001 },
           "typing zooms use the execution field anchor and exclude physical typing coordinates")
    typedProject.interactionTrace?.typingActivity = invalidTyping
    expect(typedProject.resolvedTypingActivity.isEmpty,
           "an entirely invalid execution typing stream cannot fall back to physical typing")
    typedProject.interactionTrace?.source = .system
    expect(typedProject.resolvedTypingActivity == project.typingActivity,
           "system typing preserves the original project metadata path")
    typedProject.interactionTrace?.source = .execution
    typedProject.interactionTrace?.typingActivity = executionTyping
    do {
        let encoded = try JSONEncoder().encode(typedProject)
        let decoded = try JSONDecoder().decode(RecordingProject.self, from: encoded)
        expect(decoded.interactionTrace?.typingActivity == executionTyping && decoded.resolvedTypingActivity == executionTyping,
               "execution typing provenance and active media times survive project save/load")
        var oldObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var oldTrace = oldObject["interactionTrace"] as! [String: Any]
        let rows = oldTrace["typingActivity"] as! [[String: Any]]
        expect(rows.allSatisfy { Set($0.keys) == Set(["time", "x", "y"]) },
               "persisted typing contains only timing and field coordinates, never text or key codes")
        oldTrace.removeValue(forKey: "typingActivity")
        oldObject["interactionTrace"] = oldTrace
        let oldData = try JSONSerialization.data(withJSONObject: oldObject)
        let oldProject = try JSONDecoder().decode(RecordingProject.self, from: oldData)
        expect(oldProject.interactionTrace?.typingActivity == nil && oldProject.resolvedTypingActivity.isEmpty,
               "older execution traces decode without migration and never borrow physical typing")
    } catch {
        failures.append("Interaction trace: typing Codable regression \(error)")
    }

    project.interactionTrace?.cursorDisplayMode = .embedded
    project.settings.showCursor = false
    expect(!project.resolvedCursorOverlayVisible && project.resolvedCursorFollowEnabled,
           "embedded cursor pixels disable the duplicate overlay without disabling camera follow")
    project.interactionTrace?.cursorDisplayMode = .hidden
    expect(!project.resolvedCursorOverlayVisible && project.resolvedCursorFollowEnabled,
           "an intentionally hidden trace pointer can still guide the camera")
    project.interactionTrace?.cursorDisplayMode = .overlay
    expect(!project.resolvedCursorOverlayVisible, "overlay mode still honors the user's show-cursor setting")
    project.settings.showCursor = true
    expect(project.resolvedCursorOverlayVisible, "measured execution movement can render an overlay")

    var walkTrace = InteractionTrace(sessionID: sessionID, source: .execution, cursorDisplayMode: .embedded)
    walkTrace.events = (0...360).map { index in
        let time = Double(index) / 60
        return InteractionEvent(sequence: index, time: time, kind: .move,
                                x: time < 2 ? 0.3 : min(0.85, 0.3 + (time - 2) * 0.25), y: 0.5)
    }
    walkTrace.events.append(InteractionEvent(sequence: 361, time: 4.5, kind: .discontinuity))
    let walk = walkTrace.resolved(duration: 6)
    let camera = InteractionCursorFollow.offsets(
        duration: 6,
        segments: [ZoomSegment(start: 1, end: 5, targetX: 0.3, targetY: 0.5, scale: 2)],
        settings: project.settings,
        cursor: walk.renderedCursorSamples(sigma: 0.045), strength: 1,
        discontinuities: walk.discontinuityTimes,
        cursorIsAvailable: { walk.cursorIsAvailable(at: $0) }
    )
    expect(CursorFollow.offset(at: 4.2, samples: camera).dx > 0.15, "camera follows the measured embedded pointer")
    expect(abs(CursorFollow.offset(at: 4.5, samples: camera).dx) < 0.03,
           "a navigation cut resets camera drift rather than carrying it into the next page")

    project.interactionTrace = walkTrace
    do {
        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(RecordingProject.self, from: encoded)
        expect(decoded.interactionTrace == walkTrace, "trace provenance and cursor display mode round-trip")
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "interactionTrace")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        let oldProject = try JSONDecoder().decode(RecordingProject.self, from: oldData)
        expect(oldProject.interactionTrace == nil && oldProject.resolvedInteractions.cursorSamples == legacySamples,
               "projects saved before trace support remain readable without migration")
    } catch {
        failures.append("Interaction trace: Codable regression \(error)")
    }
    return failures
}
