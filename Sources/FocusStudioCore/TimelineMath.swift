import Foundation

public enum TimelineMath {
    public static func generateZoomSegments(
        from clicks: [ClickEvent],
        duration: Double,
        settings: ProjectSettings,
        typingActivity: [TypingActivity] = []
    ) -> [ZoomSegment] {
        guard settings.autoZoomEnabled, duration.isFinite, duration > 0 else { return [] }
        let crop = settings.sourceCropInsets ?? SourceCropInsets()

        func bounded(_ value: Double, fallback: Double) -> Double {
            min(duration, max(0, value.isFinite ? value : fallback))
        }
        let leadIn = bounded(settings.zoomLeadIn, fallback: 0.1)
        let easeIn = bounded(settings.zoomEaseIn, fallback: 0.42)
        let easeOut = bounded(settings.zoomEaseOut, fallback: 0.52)
        let hold = bounded(settings.zoomHold, fallback: 0.9)
        let scale = settings.zoomScale.isFinite ? max(1, settings.zoomScale) : 1.75
        func distance(_ x: Double, _ y: Double, _ otherX: Double, _ otherY: Double) -> Double {
            guard let a = crop.croppedPoint(x: x, y: y),
                  let b = crop.croppedPoint(x: otherX, y: otherY) else { return .infinity }
            return hypot(a.x - b.x, a.y - b.y)
        }
        let sorted = clicks
            .filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite && $0.time >= 0 && $0.time <= duration && crop.croppedPoint(x: $0.x, y: $0.y) != nil }
            .sorted { $0.time < $1.time }
        let idleDelay = settings.resolvedTypingZoom.idleDelay
        let activity = (settings.resolvedTypingZoom.enabled ? typingActivity : [])
            .filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite && $0.time >= 0 && $0.time <= duration && crop.croppedPoint(x: $0.x, y: $0.y) != nil }
            .sorted { $0.time < $1.time }
        struct Burst {
            var first: TypingActivity
            var lastTime: Double
            var events: [TypingActivity]
        }
        var bursts: [Burst] = []
        var clickIndex = 0
        for event in activity {
            // A toolbar/other-field click is a new focus intent. If typing then
            // returns to the original field, it needs a NEW cue after that click,
            // not an extension of an older cue hidden behind the newer click.
            var interrupted = false
            while clickIndex < sorted.count, sorted[clickIndex].time <= event.time {
                let click = sorted[clickIndex]
                if let burst = bursts.last, click.time > burst.lastTime,
                   distance(click.x, click.y, burst.first.x, burst.first.y) > 0.08 {
                    interrupted = true
                }
                clickIndex += 1
            }
            if let index = bursts.indices.last,
               !interrupted,
               event.time - bursts[index].lastTime <= idleDelay,
               distance(event.x, event.y, bursts[index].first.x, bursts[index].first.y) <= 0.08 {
                // Keep the field's initial focus, rather than chasing the mouse
                // (or a caret drifting horizontally as the text gets longer).
                bursts[index].lastTime = event.time
                if bursts[index].events.last != event { bursts[index].events.append(event) }
            } else {
                bursts.append(Burst(first: event, lastTime: event.time, events: [event]))
            }
        }

        struct Intent {
            var time: Double
            var x: Double
            var y: Double
            var end: Double
            var clickIDs: [UUID]
            var typing: [TypingActivity]
        }
        var intents = sorted.map {
            Intent(time: $0.time, x: $0.x, y: $0.y, end: min(duration, $0.time + hold + easeOut), clickIDs: [$0.id], typing: [])
        }
        intents += bursts.map {
            Intent(time: $0.first.time, x: $0.first.x, y: $0.first.y,
                   end: min(duration, $0.lastTime + idleDelay + easeOut), clickIDs: [], typing: $0.events)
        }
        // Keep equal-time capture order stable, with verified typing taking over
        // after a click at that timestamp. No cue target is rewritten by a future
        // click at a different location.
        let ordered = intents.enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
        var result: [ZoomSegment] = []
        var previousIntentTime = -Double.infinity
        for intent in ordered {
            let start = max(0, intent.time - leadIn)
            guard intent.end > start else { continue }
            let isTyping = !intent.typing.isEmpty
            if var previous = result.last,
               start < previous.end,
               distance(previous.targetX, previous.targetY, intent.x, intent.y) <= (isTyping ? 0.12 : (previous.automaticSource?.typingActivity?.isEmpty == false ? 0.08 : 0.04)),
               isTyping || intent.time - previousIntentTime < 0.32
                    || (previous.automaticSource?.typingActivity?.isEmpty == false && intent.time <= previous.end - easeOut) {
                previous.end = max(previous.end, intent.end)
                let sourceClicks = previous.automaticSource?.clickIDs ?? []
                let sourceTyping = previous.automaticSource?.typingActivity ?? []
                previous.automaticSource?.clickIDs = sourceClicks + intent.clickIDs.filter { !sourceClicks.contains($0) }
                let recordedTyping = Set(sourceTyping)
                previous.automaticSource?.typingActivity = sourceTyping + intent.typing.filter { !recordedTyping.contains($0) }
                previous.automaticSource?.originalEnd = previous.end
                result[result.count - 1] = previous
            } else {
                if var previous = result.last {
                    let overlaps = start < previous.end
                    let nearby = distance(previous.targetX, previous.targetY, intent.x, intent.y) <= zoomChainMaximumDistance
                    let bridgesGap = !isTyping && nearby && shouldChain(previous: previous, nextStart: start, nextX: intent.x, nextY: intent.y, settings: settings)
                    let committedHandoff = overlaps && (isTyping || (nearby && settings.resolvedZoomChainGap > 0))
                    let handoffEnd = min(intent.end, start + easeIn + easeOut)
                    if committedHandoff || bridgesGap {
                        previous.end = handoffEnd
                    } else if overlaps {
                        previous.end = min(previous.end, handoffEnd)
                    }
                    // A superseded automatic focus cannot reappear after the
                    // newer cue leaves. This changes generated cues only; manual
                    // intervals remain untouched by regeneration below.
                    previous.automaticSource?.originalEnd = previous.end
                    result[result.count - 1] = previous
                }
                result.append(ZoomSegment(
                    start: start, end: intent.end,
                    targetX: intent.x, targetY: intent.y, scale: scale,
                    automaticSource: ZoomAutomaticSource(
                        start: start, targetX: intent.x, targetY: intent.y, eventTime: intent.time,
                        clickIDs: intent.clickIDs, typingActivity: intent.typing, originalEnd: intent.end
                    )
                ))
            }
            previousIntentTime = intent.time
        }
        return result
    }

    /// Camera moves between nearby clicks read as one deliberate pan. Distant
    /// targets still zoom out first so the pan never races across the frame.
    public static let zoomChainMaximumDistance = 0.5
    /// Extra seconds a hand-off pan may take beyond the ease-in, and how much
    /// of that is added per normalized unit of distance between the regions.
    public static let handoffPanExtension = 0.25
    public static let handoffPanSecondsPerUnit = 0.6

    static func shouldChain(
        previous: ZoomSegment,
        nextStart: Double,
        nextX: Double,
        nextY: Double,
        settings: ProjectSettings
    ) -> Bool {
        let gap = settings.resolvedZoomChainGap
        guard gap > 0, nextStart >= previous.end else { return false }
        guard nextStart - previous.end <= gap else { return false }
        return hypot(nextX - previous.targetX, nextY - previous.targetY) <= zoomChainMaximumDistance
    }

    /// Global auto-zoom controls rebuild metadata-derived cues while preserving
    /// every explicitly authored manual block (including its ID and timing).
    public static func regenerateAutomaticZoomSegments(in project: inout RecordingProject) {
        let manual = project.zoomSegments.filter { $0.kind == .manual }
        let previousAutomatic = project.zoomSegments.filter { $0.kind == .automatic }
        let sources = manual.compactMap(\.automaticSource)
        let authoredClicks = Set(sources.flatMap { $0.clickIDs ?? [] })
        let authoredTyping = Set(sources.flatMap { $0.typingActivity ?? [] })
        let legacySources = sources.filter { $0.clickIDs == nil && $0.typingActivity == nil }
        func isLegacyMember(time: Double, x: Double, y: Double) -> Bool {
            legacySources.contains { source in
                guard let end = source.originalEnd,
                      source.start.isFinite, end.isFinite, end >= source.start,
                      source.targetX.isFinite, source.targetY.isFinite else { return false }
                return time >= source.start && time <= end
                    && hypot(x - source.targetX, y - source.targetY) <= 0.12
            }
        }
        // Remove taken-over metadata BEFORE grouping it. Filtering only the
        // resulting first anchor lets split bursts (or merged nearby clicks)
        // reappear under a manually shortened/moved block.
        let remainingClicks = project.clickEvents.filter {
            !authoredClicks.contains($0.id) && !isLegacyMember(time: $0.time, x: $0.x, y: $0.y)
        }
        let remainingTyping = (project.typingActivity ?? []).filter {
            !authoredTyping.contains($0) && !isLegacyMember(time: $0.time, x: $0.x, y: $0.y)
        }
        let automatic = generateZoomSegments(
            from: remainingClicks,
            duration: project.duration,
            settings: project.settings,
            typingActivity: remainingTyping
        ).filter { generated in
            !manual.contains { authored in
                guard let source = authored.automaticSource,
                      source.clickIDs == nil, source.typingActivity == nil else { return false }
                if let eventTime = source.eventTime,
                   let generatedSource = generated.automaticSource,
                   let generatedTime = generatedSource.eventTime {
                    return abs(eventTime - generatedTime) < 0.000_1
                        && abs(source.targetX - generatedSource.targetX) < 0.000_1
                        && abs(source.targetY - generatedSource.targetY) < 0.000_1
                }
                // An older saved automatic block has no captured-event anchor.
                return abs(source.start - generated.start) < 0.000_1
                    && abs(source.targetX - generated.targetX) < 0.000_1
                    && abs(source.targetY - generated.targetY) < 0.000_1
            }
        }.map { generated -> ZoomSegment in
            // Keep selection and per-block styling stable while a global timing
            // slider changes the cue's end time. A newly split/added cue receives
            // a fresh identity; manual blocks are preserved verbatim below.
            guard let previous = previousAutomatic.first(where: {
                if let existingSource = $0.automaticSource, let generatedSource = generated.automaticSource,
                   let existingTime = existingSource.eventTime, let generatedTime = generatedSource.eventTime {
                    return abs(existingTime - generatedTime) < 0.000_1
                        && abs(existingSource.targetX - generatedSource.targetX) < 0.000_1
                        && abs(existingSource.targetY - generatedSource.targetY) < 0.000_1
                }
                return abs($0.start - generated.start) < 0.000_1
                    && abs($0.targetX - generated.targetX) < 0.000_1
                    && abs($0.targetY - generated.targetY) < 0.000_1
            }) else { return generated }
            var updated = generated
            updated.id = previous.id
            updated.scale = previous.scale
            updated.isEnabled = previous.isEnabled
            updated.isInstant = previous.isInstant
            updated.zoomEaseIn = previous.zoomEaseIn
            updated.zoomEaseOut = previous.zoomEaseOut
            return updated
        }
        project.zoomSegments = (manual + automatic).sorted { $0.start < $1.start }
    }

    public static func zoomState(
        at time: Double,
        segments: [ZoomSegment],
        settings: ProjectSettings
    ) -> ZoomState {
        guard time.isFinite else { return ZoomState() }
        let active = segments
            .filter {
                $0.isEnabled && $0.start.isFinite && $0.end.isFinite
                    && $0.targetX.isFinite && $0.targetY.isFinite && $0.scale.isFinite
                    && $0.end > max(0, $0.start) && time >= max(0, $0.start) && time <= $0.end
            }
            .sorted {
                if $0.start == $1.start {
                    let lhsEvent = $0.automaticSource?.eventTime ?? $0.start
                    let rhsEvent = $1.automaticSource?.eventTime ?? $1.start
                    if lhsEvent != rhsEvent { return lhsEvent < rhsEvent }
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.start < $1.start
            }
            .map { segment in
                let amount: Double
                if segment.isInstant {
                    amount = 1
                } else {
                    let timing = ZoomTiming.resolve(segment, settings: settings)
                    let incoming = zoomCurve(
                        timing.easeIn > 0 ? ((time - timing.start) / timing.easeIn).clamped(to: 0...1) : 1,
                        style: settings.screenAnimation,
                        isEntering: true
                    )
                    let outgoing = zoomCurve(
                        timing.easeOut > 0 ? ((timing.end - time) / timing.easeOut).clamped(to: 0...1) : 1,
                        style: settings.screenAnimation,
                        isEntering: false
                    )
                    amount = min(incoming, outgoing)
                }
                return (segment: segment, amount: amount)
            }

        guard !active.isEmpty else { return ZoomState() }

        // Auto zooms can overlap when clicks happen close together. Combining
        // their envelopes as a smooth union (1 - Π(1 - amount)) keeps the camera
        // committed through a handoff and, unlike picking the strongest cue,
        // never introduces a velocity kink at the moment one cue overtakes
        // another. Composite scales in timeline order, like focus below: once
        // the newer cue settles it owns its requested scale, rather than being
        // averaged with an older overlapping cue for the rest of that cue's life.
        var union = 1.0
        var scale = 1.0
        for entry in active {
            union *= 1 - entry.amount
            scale += (max(1, entry.segment.scale) - scale) * entry.amount
        }
        let combinedAmount = 1 - union

        // The pan is eased with the same envelope as the scale, starting from
        // the overview centre. Each cue moves toward the focus point it can
        // reach at its own full scale, so the camera never chases the source
        // edge and then stops abruptly when the edge constraint releases.
        // Folding in timeline order lets a newer click finish at its own target.
        var focusX = 0.5
        var focusY = 0.5
        var previousVisible: (x: Double, y: Double)?
        for entry in active {
            let fullScale = max(1, entry.segment.scale)
            let visibleX = clampedFocus(entry.segment.targetX, scale: fullScale)
            let visibleY = clampedFocus(entry.segment.targetY, scale: fullScale)
            var weight = entry.amount
            // Typing cues reclaim the input field at full speed: the viewer is
            // reading what is being typed, so the camera must already be there.
            let isTypingCue = entry.segment.automaticSource?.typingActivity?.isEmpty == false
            if let previousVisible, !entry.segment.isInstant, !isTypingCue {
                // A hand-off between two zoomed regions pans for longer when the
                // regions are far apart, so the camera never whips across the
                // frame. The scale keeps its own envelope; only the focus takes
                // the extra time, capped so it settles inside the chained overlap.
                let timing = ZoomTiming.resolve(entry.segment, settings: settings)
                let distance = hypot(visibleX - previousVisible.x, visibleY - previousVisible.y)
                let panDuration = timing.easeIn + min(handoffPanExtension, distance * handoffPanSecondsPerUnit)
                if timing.easeIn > 0, panDuration > timing.easeIn {
                    let incoming = zoomCurve(
                        ((time - timing.start) / panDuration).clamped(to: 0...1),
                        style: settings.screenAnimation,
                        isEntering: true
                    )
                    let outgoing = zoomCurve(
                        timing.easeOut > 0 ? ((timing.end - time) / timing.easeOut).clamped(to: 0...1) : 1,
                        style: settings.screenAnimation,
                        isEntering: false
                    )
                    weight = min(incoming, outgoing)
                }
            }
            focusX += (visibleX - focusX) * weight
            focusY += (visibleY - focusY) * weight
            previousVisible = (visibleX, visibleY)
        }
        return ZoomState(
            scale: scale,
            centerX: clampedFocus(focusX, scale: scale),
            centerY: clampedFocus(focusY, scale: scale),
            progress: combinedAmount
        )
    }

    /// Retimes existing automatic zooms when the global Hold control changes.
    /// Manual timeline blocks retain their explicitly edited duration.
    public static func adjustAutomaticHold(
        in segments: inout [ZoomSegment],
        by delta: Double,
        duration: Double
    ) {
        guard delta.isFinite, duration.isFinite, duration >= 0 else { return }
        for index in segments.indices where segments[index].kind == .automatic {
            let minimumEnd = min(duration, segments[index].start + 0.01)
            segments[index].end = min(
                duration,
                max(minimumEnd, segments[index].end + delta)
            )
        }
    }

    /// Ordinary click-hold changes must not shorten a keyboard-focused hold or
    /// reset a user's retimed blocks. Typing has its own explicit idle control.
    public static func adjustAutomaticClickHold(in project: inout RecordingProject, by delta: Double) {
        guard delta.isFinite else { return }
        let typing = project.settings.resolvedTypingZoom.enabled ? project.typingActivity ?? [] : []
        for index in project.zoomSegments.indices where project.zoomSegments[index].kind == .automatic {
            let segment = project.zoomSegments[index]
            let containsTyping = typing.contains {
                $0.time >= segment.start && $0.time <= segment.end
                    && hypot($0.x - segment.targetX, $0.y - segment.targetY) <= 0.12
            }
            guard !containsTyping else { continue }
            project.zoomSegments[index].end = min(
                project.duration,
                max(min(project.duration, segment.start + 0.01), segment.end + delta)
            )
        }
    }

    public static func cursorPosition(at time: Double, samples: [CursorSample]) -> CursorSample? {
        guard let first = samples.first else { return nil }
        if time <= first.time { return first }
        guard let last = samples.last else { return first }
        if time >= last.time { return last }

        var low = 0
        var high = samples.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if samples[middle].time <= time {
                low = middle
            } else {
                high = middle
            }
        }

        let lhs = samples[low]
        let rhs = samples[high]
        let span = max(0.000_001, rhs.time - lhs.time)
        let raw = ((time - lhs.time) / span).clamped(to: 0...1)

        // A smooth-step on every individual sample interval stops the cursor at
        // every sample and creates visible micro-stutter at 60/120 Hz. Cubic
        // Hermite interpolation uses the neighbouring samples to maintain
        // velocity through interval boundaries. Per-axis monotone tangents keep
        // sharp turns from overshooting the recorded bounding box.
        let previous = low > 0 ? samples[low - 1] : nil
        let next = high + 1 < samples.count ? samples[high + 1] : nil
        return CursorSample(
            time: time,
            x: monotoneCursorCoordinate(
                at: raw,
                lhs: lhs.x,
                rhs: rhs.x,
                previous: previous.map { ($0.x, $0.time) },
                next: next.map { ($0.x, $0.time) },
                lhsTime: lhs.time,
                rhsTime: rhs.time
            ).clamped(to: 0...1),
            y: monotoneCursorCoordinate(
                at: raw,
                lhs: lhs.y,
                rhs: rhs.y,
                previous: previous.map { ($0.y, $0.time) },
                next: next.map { ($0.y, $0.time) },
                lhsTime: lhs.time,
                rhsTime: rhs.time
            ).clamped(to: 0...1),
            // Cursor shape is discrete metadata. Hold the last observed shape
            // until the next sample instead of visually switching mid-flight.
            cursorKind: raw >= 1 ? rhs.cursorKind : lhs.cursorKind
        )
    }

    private static func monotoneCursorCoordinate(
        at progress: Double,
        lhs: Double,
        rhs: Double,
        previous: (value: Double, time: Double)?,
        next: (value: Double, time: Double)?,
        lhsTime: Double,
        rhsTime: Double
    ) -> Double {
        let span = max(0.000_001, rhsTime - lhsTime)
        let currentSlope = (rhs - lhs) / span
        let incomingSlope: Double
        if let previous {
            incomingSlope = (lhs - previous.value) / max(0.000_001, lhsTime - previous.time)
        } else {
            incomingSlope = currentSlope
        }
        let outgoingSlope: Double
        if let next {
            outgoingSlope = (next.value - rhs) / max(0.000_001, next.time - rhsTime)
        } else {
            outgoingSlope = currentSlope
        }

        let lhsTangent = monotoneTangent(incomingSlope, currentSlope)
        let rhsTangent = monotoneTangent(currentSlope, outgoingSlope)
        let t = progress.clamped(to: 0...1)
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        let value = h00 * lhs
            + h10 * span * lhsTangent
            + h01 * rhs
            + h11 * span * rhsTangent
        return value.clamped(to: min(lhs, rhs)...max(lhs, rhs))
    }

    private static func monotoneTangent(_ lhs: Double, _ rhs: Double) -> Double {
        guard lhs.isFinite, rhs.isFinite, lhs * rhs > 0 else { return 0 }
        let average = (lhs + rhs) / 2
        let limit = 3 * min(abs(lhs), abs(rhs))
        return average.sign == .minus ? -min(abs(average), limit) : min(average, limit)
    }

    public static func smoothStep(_ value: Double) -> Double {
        let t = value.clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }

    public static func smootherStep(_ value: Double) -> Double {
        let t = value.clamped(to: 0...1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// smootherStep with its velocity peak pulled toward the start (t^0.7):
    /// the camera commits early and spends most of the move settling. The
    /// warp exponent stays above 2/3 so velocity and acceleration are both
    /// zero at t = 0 as well as at t = 1.
    public static func cinematicEase(_ value: Double) -> Double {
        let t = value.clamped(to: 0...1)
        return smootherStep(pow(t, 0.7))
    }

    /// Envelope of a single cue at a normalized time, exposed for tests and
    /// for UI curve previews. `value` is the fraction of the transition that
    /// has elapsed when entering, or the fraction remaining when leaving.
    public static func transitionAmount(
        _ value: Double,
        style: ScreenAnimationStyle,
        isEntering: Bool
    ) -> Double {
        zoomCurve(value, style: style, isEntering: isEntering)
    }

    private static func zoomCurve(
        _ value: Double,
        style: ScreenAnimationStyle,
        isEntering: Bool
    ) -> Double {
        let t = value.clamped(to: 0...1)
        switch style {
        case .cinematic:
            // Entering: quick commit, long settle. Leaving `t` counts down the
            // remaining fraction, so mirror the curve: the pull-back starts
            // decisively and lands on the overview without a visible stop.
            return isEntering ? cinematicEase(t) : 1 - cinematicEase(1 - t)
        case .focused:
            // Responsive on the way in, calm on the way back to the overview.
            return isEntering ? 1 - pow(1 - t, 3) : smootherStep(t)
        case .smooth:
            // Zero velocity and acceleration at both ends prevents visible jolts.
            return smootherStep(t)
        case .gentle:
            return (1 - cos(.pi * t)) / 2
        case .snappy:
            return isEntering ? 1 - pow(1 - t, 5) : smoothStep(t)
        }
    }

    private static func clampedFocus(_ value: Double, scale: Double) -> Double {
        guard scale > 1 else { return 0.5 }
        let halfVisible = 0.5 / scale
        return value.clamped(to: halfVisible...(1 - halfVisible))
    }
}

public extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
