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
