import FocusStudioCore
import Foundation

/// Camera-motion guarantees behind the "Cinematic" curve, envelope blending,
/// eased pans and click chaining. Everything here is pure timing math shared
/// by preview and export, so a failure would be visible in both.
func zoomMotionFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }

    // --- Curve shape ---------------------------------------------------------
    for style in ScreenAnimationStyle.allCases {
        let entering = stride(from: 0.0, through: 1.0, by: 0.002).map {
            TimelineMath.transitionAmount($0, style: style, isEntering: true)
        }
        expect(abs(entering.first! - 0) < 1e-9 && abs(entering.last! - 1) < 1e-9,
               "\(style) entering curve must run exactly from 0 to 1")
        expect(zip(entering, entering.dropFirst()).allSatisfy { $0 <= $1 + 1e-12 },
               "\(style) entering curve must be monotonic")
    }
    let cinematicStart = TimelineMath.cinematicEase(0.002)
    let cinematicLate = TimelineMath.cinematicEase(0.998)
    expect(cinematicStart < 1e-4 && 1 - cinematicLate < 1e-4,
           "cinematic ease must start and end with zero velocity (\(cinematicStart), \(cinematicLate))")
    expect(TimelineMath.cinematicEase(0.5) > TimelineMath.smootherStep(0.5) + 0.12,
           "cinematic ease must commit earlier than a symmetric smootherStep")
    let cinematicOut = TimelineMath.transitionAmount(0.5, style: .cinematic, isEntering: false)
    expect(cinematicOut < 0.5, "cinematic zoom-out must release quickly and settle gently")

    var settings = ProjectSettings()
    expect(settings.screenAnimation == .cinematic, "new projects default to the Cinematic curve")
    expect(settings.resolvedZoomChainGap == ProjectSettings.defaultZoomChainGap,
           "missing chain gap resolves to the default")
    settings.zoomChainGap = 99
    expect(settings.resolvedZoomChainGap == ProjectSettings.maximumZoomChainGap, "chain gap is clamped")
    settings.zoomChainGap = nil

    // --- Eased pan without a constraint kink --------------------------------
    settings.zoomScale = 2
    settings.zoomEaseIn = 0.5
    settings.zoomEaseOut = 0.5
    let single = [ZoomSegment(start: 1, end: 3, targetX: 0.8, targetY: 0.2, scale: 2)]
    let step = 0.0025
    let panSamples = stride(from: 1.0, through: 1.5, by: step).map {
        TimelineMath.zoomState(at: $0, segments: single, settings: settings)
    }
    let firstDifferences = zip(panSamples, panSamples.dropFirst()).map { $1.centerX - $0.centerX }
    let secondDifferences = zip(firstDifferences, firstDifferences.dropFirst()).map { abs($1 - $0) }
    let maxVelocity = firstDifferences.map(abs).max() ?? 0
    let maxJerk = secondDifferences.max() ?? 0
    expect(maxVelocity > 0, "the camera must pan toward the click during the ease-in")
    expect(maxJerk < 0.35 * maxVelocity,
           "pan velocity must change gradually; a kink appeared (jerk \(maxJerk) vs velocity \(maxVelocity))")
    expect(firstDifferences.allSatisfy { $0 >= -1e-12 }, "the pan must not reverse")
    let settled = TimelineMath.zoomState(at: 2, segments: single, settings: settings)
    expect(abs(settled.centerX - 0.75) < 1e-9 && abs(settled.centerY - 0.25) < 1e-9,
           "a settled zoom sits on the clamped focus point")
    expect(abs(panSamples.first!.centerX - 0.5) < 1e-9, "the pan starts from the overview centre")

    // --- Overlap blending has no dip or kink ---------------------------------
    // Partial overlap: the first cue lets go while the second is still arriving.
    let overlapping = [
        ZoomSegment(start: 0, end: 2, targetX: 0.3, targetY: 0.5, scale: 2),
        ZoomSegment(start: 1.6, end: 3.5, targetX: 0.6, targetY: 0.5, scale: 2),
    ]
    let crossSamples = stride(from: 1.4, through: 2.2, by: step).map {
        TimelineMath.zoomState(at: $0, segments: overlapping, settings: settings)
    }
    // The union envelope is never weaker than the strongest single cue, so the
    // dip can only be shallower than the old "strongest cue wins" rule.
    for time in stride(from: 1.4, through: 2.2, by: step) {
        let outgoing = TimelineMath.transitionAmount((2 - time) / 0.5, style: settings.screenAnimation, isEntering: false)
        let incoming = TimelineMath.transitionAmount((time - 1.6) / 0.5, style: settings.screenAnimation, isEntering: true)
        let strongest = 1 + max(outgoing, incoming)
        let blended = TimelineMath.zoomState(at: time, segments: overlapping, settings: settings).scale
        expect(blended >= strongest - 1e-9, "blended scale fell below the strongest cue at \(time): \(blended) < \(strongest)")
    }
    // Chained overlap (what generateZoomSegments produces): committed throughout.
    let chainedOverlap = [
        ZoomSegment(start: 0, end: 2.6, targetX: 0.3, targetY: 0.5, scale: 2),
        ZoomSegment(start: 1.6, end: 3.5, targetX: 0.6, targetY: 0.5, scale: 2),
    ]
    let committed = stride(from: 1.0, through: 3.0, by: step).map {
        TimelineMath.zoomState(at: $0, segments: chainedOverlap, settings: settings).scale
    }.min() ?? 0
    expect(committed >= 2 - 1e-9, "a chained handoff must hold full scale from first cue to second (min \(committed))")
    let scaleDifferences = zip(crossSamples, crossSamples.dropFirst()).map { $1.scale - $0.scale }
    let scaleJerk = zip(scaleDifferences, scaleDifferences.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    let scaleVelocity = scaleDifferences.map(abs).max() ?? 0
    expect(scaleJerk < 0.35 * max(scaleVelocity, 1e-6),
           "scale must stay smooth across a handoff (jerk \(scaleJerk) vs velocity \(scaleVelocity))")
    let centers = crossSamples.map(\.centerX)
    expect(zip(centers, centers.dropFirst()).allSatisfy { $1 >= $0 - 1e-9 },
           "the handoff pan must move monotonically toward the newer click")
    expect(abs(crossSamples.last!.centerX - 0.6) < 1e-6, "the newer click owns the settled focus")

    // --- Click chaining ------------------------------------------------------
    var chainSettings = ProjectSettings()
    chainSettings.zoomScale = 1.75
    chainSettings.zoomLeadIn = 0.1
    chainSettings.zoomEaseIn = 0.42
    chainSettings.zoomHold = 0.9
    chainSettings.zoomEaseOut = 0.52
    let clicks = [
        ClickEvent(time: 1, x: 0.3, y: 0.5, button: .left),
        ClickEvent(time: 2.9, x: 0.5, y: 0.5, button: .left),
    ]
    let chained = TimelineMath.generateZoomSegments(from: clicks, duration: 10, settings: chainSettings)
    expect(chained.count == 2, "chained clicks keep separate cues")
    if chained.count == 2 {
        expect(abs(chained[0].end - (2.8 + 0.42 + 0.52)) < 1e-9,
               "a nearby click extends the previous cue through its own transition (end \(chained[0].end))")
        expect(abs((chained[0].automaticSource?.originalEnd ?? -1) - chained[0].end) < 1e-9,
               "chaining records the extended end for regeneration")
        let handoff = TimelineMath.zoomState(at: 2.8, segments: chained, settings: chainSettings)
        expect(handoff.scale > 1.7, "the camera stays zoomed while the next click takes over (\(handoff.scale))")
        let panned = stride(from: 2.8, through: 3.25, by: step).map {
            TimelineMath.zoomState(at: $0, segments: chained, settings: chainSettings).centerX
        }
        expect(zip(panned, panned.dropFirst()).allSatisfy { $1 >= $0 - 1e-9 } && panned.last! > panned.first! + 0.15,
               "chained cues pan smoothly to the new focus")
    }
    var noChain = chainSettings
    noChain.zoomChainGap = 0
    let separate = TimelineMath.generateZoomSegments(from: clicks, duration: 10, settings: noChain)
    expect(separate.count == 2 && abs(separate[0].end - 2.42) < 1e-9,
           "a zero chain gap restores independent cues")
    let farClicks = [
        ClickEvent(time: 1, x: 0.1, y: 0.1, button: .left),
        ClickEvent(time: 2.9, x: 0.9, y: 0.9, button: .left),
    ]
    let far = TimelineMath.generateZoomSegments(from: farClicks, duration: 10, settings: chainSettings)
    expect(far.count == 2 && abs(far[0].end - 2.42) < 1e-9,
           "distant clicks are not chained so the pan never races across the frame")

    // --- Event ordering and focus ownership ----------------------------------
    let rapidClicks = [
        ClickEvent(time: 1, x: 0.2, y: 0.5, button: .left),
        ClickEvent(time: 1.2, x: 0.8, y: 0.5, button: .left),
    ]
    let rapid = TimelineMath.generateZoomSegments(from: rapidClicks, duration: 8, settings: settings)
    expect(rapid.count == 2, "rapid clicks at distinct targets must not be collapsed into the future target")
    expect(rapid.first?.targetX == 0.2, "the first click's target must not be retroactively rewritten")
    expect(TimelineMath.zoomState(at: 1.05, segments: rapid, settings: settings).centerX < 0.5,
           "before the second lead-in, camera movement must still point toward the first click")
    expect(Set(rapid.flatMap { $0.automaticSource?.clickIDs ?? [] }) == Set(rapidClicks.map(\.id)),
           "rapid-click splitting must retain exact source-event ownership")

    let jitterClicks = [
        ClickEvent(time: 1, x: 0.4, y: 0.5, button: .left),
        ClickEvent(time: 1.2, x: 0.415, y: 0.51, button: .left),
    ]
    let jitter = TimelineMath.generateZoomSegments(from: jitterClicks, duration: 8, settings: settings)
    expect(jitter.count == 1 && jitter[0].targetX == 0.4 && jitter[0].targetY == 0.5,
           "a same-control double click should extend one stable focus, not chase pointer jitter")
    var legacyJitter = RecordingProject(title: "Old moving anchor", sourceVideoPath: "synthetic.mp4", duration: 8,
        sourceWidth: 960, sourceHeight: 540, clickEvents: jitterClicks, zoomSegments: jitter, settings: settings)
    let jitterID = legacyJitter.zoomSegments[0].id
    legacyJitter.zoomSegments[0].targetX = jitterClicks[1].x
    legacyJitter.zoomSegments[0].targetY = jitterClicks[1].y
    legacyJitter.zoomSegments[0].scale = 2.3
    legacyJitter.zoomSegments[0].isEnabled = false
    TimelineMath.regenerateAutomaticZoomSegments(in: &legacyJitter)
    expect(legacyJitter.zoomSegments.count == 1 && legacyJitter.zoomSegments[0].id == jitterID
           && legacyJitter.zoomSegments[0].scale == 2.3 && !legacyJitter.zoomSegments[0].isEnabled,
           "regenerating an older moving-anchor cue must keep source-matched IDs, custom scale, and disabled state")

    let partialOverlap = TimelineMath.generateZoomSegments(from: [
        ClickEvent(time: 1, x: 0.3, y: 0.5, button: .left),
        ClickEvent(time: 2.35, x: 0.5, y: 0.5, button: .left),
    ], duration: 8, settings: chainSettings)
    let overlapMinimum = stride(from: 1.5, through: 2.8, by: 0.01).map {
        TimelineMath.zoomState(at: $0, segments: partialOverlap, settings: chainSettings).scale
    }.min() ?? 0
    expect(overlapMinimum >= chainSettings.zoomScale - 1e-9,
           "nearby partially overlapping clicks should stay committed instead of pulsing between cues")

    let differentScales = [
        ZoomSegment(start: 0, end: 4, targetX: 0.3, targetY: 0.5, scale: 2.4),
        ZoomSegment(start: 1, end: 5, targetX: 0.6, targetY: 0.5, scale: 1.4),
    ]
    expect(abs(TimelineMath.zoomState(at: 2, segments: differentScales, settings: settings).scale - 1.4) < 1e-9,
           "a settled newer cue must reach its own scale even while an older cue overlaps")
    let early = TimelineMath.generateZoomSegments(from: [
        ClickEvent(time: 0.02, x: 0.2, y: 0.5, button: .left),
        ClickEvent(time: 0.04, x: 0.8, y: 0.5, button: .left),
    ], duration: 8, settings: settings)
    expect(TimelineMath.zoomState(at: 0.6, segments: early, settings: settings).centerX > 0.7,
           "cues whose lead-in is clamped to zero must be ordered by captured event time, not random generated UUID")

    let typed = stride(from: 0.8, through: 5.8, by: 0.2).map { TypingActivity(time: $0, x: 0.3, y: 0.65) }
    let interruptedClicks = [
        ClickEvent(time: 0.7, x: 0.3, y: 0.65, button: .left),
        ClickEvent(time: 2.5, x: 0.75, y: 0.3, button: .left),
    ]
    let resumedTyping = TimelineMath.generateZoomSegments(from: interruptedClicks, duration: 10, settings: settings, typingActivity: typed)
    expect(resumedTyping.count == 3, "typing that resumes after a different-target click needs a new chronological focus cue")
    let resumed = TimelineMath.zoomState(at: 3.2, segments: resumedTyping, settings: settings)
    expect(abs(resumed.centerX - 0.3) < 1e-9 && abs(resumed.scale - settings.zoomScale) < 1e-9,
           "resumed typing must reclaim input focus promptly instead of waiting for the intervening click to expire")
    expect(resumedTyping.flatMap { $0.automaticSource?.typingActivity ?? [] }.count == typed.count
           && Set(resumedTyping.flatMap { $0.automaticSource?.typingActivity ?? [] }) == Set(typed),
           "chronological typing handoffs must retain every metadata sample exactly once")
    let whileTyping = TimelineMath.generateZoomSegments(from: [
        interruptedClicks[0], ClickEvent(time: 2.5, x: 0.31, y: 0.65, button: .left),
    ], duration: 10, settings: settings, typingActivity: typed)
    expect(whileTyping.count == 1 && abs(whileTyping[0].end - (typed.last!.time + settings.resolvedTypingZoom.idleDelay + settings.zoomEaseOut)) < 1e-9,
           "a click inside the same input must not shorten an ongoing long typing hold")

    let switchedAway = TimelineMath.generateZoomSegments(from: [ClickEvent(time: 2.1, x: 0.75, y: 0.3, button: .left)], duration: 8, settings: settings,
        typingActivity: [TypingActivity(time: 1, x: 0.3, y: 0.65), TypingActivity(time: 2, x: 0.3, y: 0.65)])
    let newerEnd = switchedAway.last?.end ?? 0
    expect(TimelineMath.zoomState(at: newerEnd + 0.01, segments: switchedAway, settings: settings).scale == 1,
           "an older input hold must not spring back after a newer focus cue has finished")

    let edgeTyping = TimelineMath.generateZoomSegments(from: [], duration: 50, settings: settings,
        typingActivity: stride(from: 1.0, through: 40.0, by: 0.1).map { TypingActivity(time: $0, x: 0.98, y: 0.99) })
    expect(edgeTyping.count == 1, "long uninterrupted typing should remain one editable hold")
    let edge = TimelineMath.zoomState(at: 35, segments: edgeTyping, settings: settings)
    expect(abs(edge.scale - settings.zoomScale) < 1e-9
           && edge.centerX + 0.5 / edge.scale <= 1.000_000_1
           && edge.centerY + 0.5 / edge.scale <= 1.000_000_1,
           "long typing near source edges must stay zoomed without exposing outside the source")
    var authored = RecordingProject(title: "Manual motion ownership fixture", sourceVideoPath: "synthetic.mp4", duration: 10, sourceWidth: 960, sourceHeight: 540,
        clickEvents: interruptedClicks, typingActivity: typed, zoomSegments: resumedTyping, settings: settings)
    authored.zoomSegments = authored.zoomSegments.map {
        ZoomTiming.applying(.move(min(8, $0.start + 0.5)), to: $0, projectDuration: 10, settings: settings)
    }
    let preserved = authored.zoomSegments
    authored.settings.zoomHold = 3
    authored.settings.typingZoom = TypingZoomSettings(idleDelay: 0.4)
    TimelineMath.regenerateAutomaticZoomSegments(in: &authored)
    expect(Set(authored.zoomSegments) == Set(preserved),
           "global regeneration after new handoff grouping must preserve all manual blocks and suppress all their source events")
    var malformed = settings
    malformed.zoomLeadIn = .nan
    malformed.zoomHold = -.infinity
    malformed.zoomEaseIn = .infinity
    malformed.zoomEaseOut = .nan
    malformed.zoomScale = .nan
    let sanitized = TimelineMath.generateZoomSegments(from: rapidClicks, duration: 8, settings: malformed, typingActivity: typed)
    expect(!sanitized.isEmpty && sanitized.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && $0.scale.isFinite },
           "malformed timing settings must not create NaN or empty camera intervals")

    // --- Compatibility --------------------------------------------------------
    // A project saved by 1.1.x has every legacy key but no chain gap and a
    // "smooth" curve. Round-trip through JSON to build that exact document.
    do {
        var legacyObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ProjectSettings()), options: []
        ) as? [String: Any] ?? [:]
        legacyObject["screenAnimation"] = "smooth"
        legacyObject.removeValue(forKey: "zoomChainGap")
        let legacy = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(ProjectSettings.self, from: legacy)
        expect(decoded.screenAnimation == .smooth && decoded.zoomChainGap == nil
               && decoded.resolvedZoomChainGap == ProjectSettings.defaultZoomChainGap,
               "older projects keep their saved curve and gain the default chain gap lazily")
    } catch {
        failures.append("older project settings must still decode: \(error)")
    }
    return failures
}
