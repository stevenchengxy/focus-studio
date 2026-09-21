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

        let sorted = clicks
            .filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite && $0.time >= 0 && $0.time <= duration && crop.croppedPoint(x: $0.x, y: $0.y) != nil }
            .sorted { $0.time < $1.time }

        var result: [ZoomSegment] = []
        for click in sorted {
            let start = max(0, click.time - settings.zoomLeadIn)
            let end = min(duration, click.time + settings.zoomHold + settings.zoomEaseOut)
            guard end > start else { continue }

            if var previous = result.last,
               start < previous.end,
               click.time - previous.start < 0.72 {
                previous.end = max(previous.end, end)
                previous.targetX = click.x
                previous.targetY = click.y
                if !(previous.automaticSource?.clickIDs?.contains(click.id) ?? false) {
                    previous.automaticSource?.clickIDs?.append(click.id)
                }
                previous.automaticSource?.originalEnd = previous.end
                result[result.count - 1] = previous
            } else {
                result.append(
                    ZoomSegment(
                        start: start,
                        end: end,
                        targetX: click.x.clamped(to: 0...1),
                        targetY: click.y.clamped(to: 0...1),
                        scale: settings.zoomScale,
                        automaticSource: ZoomAutomaticSource(
                            start: start, targetX: click.x, targetY: click.y, eventTime: click.time,
                            clickIDs: [click.id], typingActivity: [], originalEnd: end
                        )
                    )
                )
            }
        }
        guard settings.resolvedTypingZoom.enabled else { return result }
        let idleDelay = settings.resolvedTypingZoom.idleDelay
        let activity = typingActivity
            .filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite && $0.time >= 0 && $0.time <= duration && crop.croppedPoint(x: $0.x, y: $0.y) != nil }
            .sorted { $0.time < $1.time }
        struct Burst {
            var first: TypingActivity
            var lastTime: Double
            var events: [TypingActivity]
        }
        var bursts: [Burst] = []
        for event in activity {
            if var burst = bursts.last,
               event.time - burst.lastTime <= idleDelay,
               hypot(event.x - burst.first.x, event.y - burst.first.y) <= 0.08 {
                // Keep the field's initial focus, rather than chasing the mouse
                // (or a caret drifting horizontally as the text gets longer).
                burst.lastTime = event.time
                if burst.events.last != event { burst.events.append(event) }
                bursts[bursts.count - 1] = burst
            } else {
                bursts.append(Burst(first: event, lastTime: event.time, events: [event]))
            }
        }
        for burst in bursts {
            let start = max(0, burst.first.time - max(0, settings.zoomLeadIn))
            let end = min(duration, burst.lastTime + idleDelay + max(0, settings.zoomEaseOut))
            guard end > start else { continue }
            let x = burst.first.x.clamped(to: 0...1)
            let y = burst.first.y.clamped(to: 0...1)
            let previousIndex = result.indices
                .filter { result[$0].start <= start && result[$0].end >= start }
                .max { result[$0].start < result[$1].start }
            if let relatedIndex = previousIndex,
               hypot(result[relatedIndex].targetX - x, result[relatedIndex].targetY - y) <= 0.12 {
                // A click that entered the same input becomes one continuous
                // camera hold, even when typing outlasts the normal click hold.
                result[relatedIndex].end = max(result[relatedIndex].end, end)
                let existingEvents = result[relatedIndex].automaticSource?.typingActivity ?? []
                let existingSet = Set(existingEvents)
                let updatedEnd = result[relatedIndex].end
                result[relatedIndex].automaticSource?.typingActivity = existingEvents + burst.events.filter { !existingSet.contains($0) }
                result[relatedIndex].automaticSource?.originalEnd = updatedEnd
            } else {
                // If focus moves to another input while already zoomed, keep the
                // previous camera envelope alive until this handoff has settled.
                if let previousIndex {
                    result[previousIndex].end = max(
                        result[previousIndex].end,
                        min(duration, start + max(0, settings.zoomEaseIn) + max(0, settings.zoomEaseOut))
                    )
                }
                result.append(ZoomSegment(
                    start: start,
                    end: end,
                    targetX: x,
                    targetY: y,
                    scale: settings.zoomScale,
                    automaticSource: ZoomAutomaticSource(
                        start: start, targetX: x, targetY: y, eventTime: burst.first.time,
                        clickIDs: [], typingActivity: burst.events, originalEnd: end
                    )
                ))
            }
        }
        return result.sorted { $0.start < $1.start }
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
                abs($0.start - generated.start) < 0.000_1
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
                if $0.start == $1.start { return $0.id.uuidString < $1.id.uuidString }
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

        // Auto zooms can overlap when clicks happen close together. Blending their
        // focus points while keeping the strongest active scale creates one smooth
        // camera move instead of briefly snapping back to 1x at the next segment.
        let strongest = active.max {
            let lhs = 1 + (max(1, $0.segment.scale) - 1) * $0.amount
            let rhs = 1 + (max(1, $1.segment.scale) - 1) * $1.amount
            return lhs < rhs
        }!
        let scale = 1 + (max(1, strongest.segment.scale) - 1) * strongest.amount
        // Fold focus points in timeline order. A newer click therefore completes
        // its camera move at its own target instead of getting stuck halfway
        // between two fully-active zooms. Its envelope still provides a smooth
        // handoff on both entry and exit.
        var focusX = active[0].segment.targetX
        var focusY = active[0].segment.targetY
        for entry in active.dropFirst() {
            let handoff = smootherStep(entry.amount)
            focusX += (entry.segment.targetX - focusX) * handoff
            focusY += (entry.segment.targetY - focusY) * handoff
        }
        return ZoomState(
            scale: scale,
            centerX: clampedFocus(focusX, scale: scale),
            centerY: clampedFocus(focusY, scale: scale),
            progress: active.map(\.amount).max() ?? 0
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

    private static func zoomCurve(
        _ value: Double,
        style: ScreenAnimationStyle,
        isEntering: Bool
    ) -> Double {
        let t = value.clamped(to: 0...1)
        switch style {
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
