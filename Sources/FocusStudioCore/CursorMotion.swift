import Foundation

/// Pointer motion finishing shared by preview and export.
///
/// Raw mouse samples carry hand jitter and arrive at an uneven rate. The
/// rendered pointer follows a dense, zero-phase smoothed path that is pinned
/// to every click position at the click time, so the arrow still lands exactly
/// where the click ring appears. Cursor shape changes (arrow ↔ I-beam) are
/// confirmed briefly before switching, without overlapping pointer artwork.
public enum CursorMotion {
    /// Dense path sample rate in Hz.
    public static let pathSampleRate = 120.0
    /// Legacy transition argument; stable shapes confirm within 80 ms.
    public static let kindFadeDuration = 0.14

    /// Gaussian smoothing width in seconds for a smoothing style.
    public static func smoothingSigma(for style: CursorAnimationStyle) -> Double {
        switch style {
        case .smooth: return 0.085
        case .medium: return 0.045
        case .rapid: return 0.022
        case .none: return 0
        }
    }

    /// Finish observed movement without rewriting the recording. A long input
    /// gap is a hold, not evidence of a slow sweep. Within each continuous span,
    /// actions and genuine pauses divide free travel from protected dragging.
    public static func smoothedPath(
        samples: [CursorSample],
        clicks: [ClickEvent],
        sigma: Double
    ) -> [CursorSample] {
        let ordered = samples.filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }
            .enumerated().sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map(\.element)
        guard ordered.count > 1, sigma > 0, sigma.isFinite else { return ordered }
        var byTime: [Double: CursorSample] = [:]
        for sample in ordered { byTime[sample.time] = sample }
        let start = ordered[0].time, end = ordered[ordered.count - 1].time
        let validClicks = clicks.filter {
            $0.time.isFinite && $0.x.isFinite && $0.y.isFinite && $0.time >= start && $0.time <= end
        }
        let original = byTime.values.sorted { $0.time < $1.time }
        for click in validClicks {
            var anchor = TimelineMath.cursorPosition(at: click.time, samples: original) ?? ordered[0]
            anchor.time = click.time
            anchor.x = click.x.clamped(to: 0...1)
            anchor.y = click.y.clamped(to: 0...1)
            byTime[click.time] = anchor
        }
        let sorted = byTime.values.sorted { $0.time < $1.time }
        let clickTimes = Set(validClicks.map(\.time))
        var result: [CursorSample] = []
        var lower = 0
        for upper in 1...sorted.count {
            guard upper == sorted.count || sorted[upper].time - sorted[upper - 1].time > 0.25 else { continue }
            let span = Array(sorted[lower..<upper])
            if var hold = result.last, let next = span.first, next.time - hold.time > 0.000_002 {
                // The renderer interpolates the finished path again. An explicit
                // hold at the far end of a gap prevents it inventing motion there.
                hold.time = next.time - 0.000_001
                result.append(hold)
            }
            result += finishContinuousSpan(span, clickTimes: clickTimes, sigma: min(sigma, 0.25))
            lower = upper
        }
        return result
    }

    private struct Dwell {
        var start: Double
        var end: Double
        var x: Double
        var y: Double
    }

    /// A fixed spatial cluster with no sustained direction. Unlike overlapping
    /// sliding windows, this cannot grow into an indefinitely drifting "pause".
    /// A trend check also protects deliberate slow movement within a small area.
    private static func stationaryDwells(_ samples: [CursorSample]) -> [Dwell] {
        guard samples.count > 2 else { return [] }
        let radius = 0.003
        var result: [Dwell] = []
        var lower = 0
        while lower + 1 < samples.count {
            let first = samples[lower]
            guard first.isDragging == false else { lower += 1; continue }
            var upper = lower
            var xmin = first.x, xmax = first.x, ymin = first.y, ymax = first.y
            var travel = 0.0
            // Bound the search even for unusually dense imported metadata.
            while upper + 1 < samples.count && upper - lower < 256 {
                let next = samples[upper + 1]
                guard next.isDragging == false, next.cursorKind == first.cursorKind,
                      next.time - first.time <= 2,
                      hypot(max(xmax, next.x) - min(xmin, next.x), max(ymax, next.y) - min(ymin, next.y)) <= radius * 2 else { break }
                travel += hypot(next.x - samples[upper].x, next.y - samples[upper].y)
                upper += 1
                xmin = min(xmin, next.x); xmax = max(xmax, next.x)
                ymin = min(ymin, next.y); ymax = max(ymax, next.y)
            }
            // The first step arriving at/leaving a stop may still fit the small
            // spatial box. Do not let that edge turn a true pause into apparent
            // monotonic movement (or freeze the first step of the next gesture).
            var settledLower = lower, settledUpper = upper
            while settledUpper > settledLower + 1,
                  hypot(samples[settledLower + 1].x - samples[settledLower].x,
                        samples[settledLower + 1].y - samples[settledLower].y) > 0.0015 {
                settledLower += 1
            }
            while settledUpper > settledLower + 1,
                  hypot(samples[settledUpper].x - samples[settledUpper - 1].x,
                        samples[settledUpper].y - samples[settledUpper - 1].y) > 0.0015 {
                settledUpper -= 1
            }
            let settledFirst = samples[settledLower]
            let duration = samples[settledUpper].time - settledFirst.time
            guard duration >= 0.12 else { lower += 1; continue }
            let values = samples[settledLower...settledUpper]
            travel = zip(values, values.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            let count = Double(values.count)
            let meanTime = values.reduce(0) { $0 + $1.time - settledFirst.time } / count
            let meanX = values.reduce(0) { $0 + $1.x } / count
            let meanY = values.reduce(0) { $0 + $1.y } / count
            var variance = 0.0, covarianceX = 0.0, covarianceY = 0.0
            for point in values {
                let time = point.time - settledFirst.time - meanTime
                variance += time * time
                covarianceX += time * (point.x - meanX)
                covarianceY += time * (point.y - meanY)
            }
            let driftSpeed = hypot(covarianceX, covarianceY) / max(1e-12, variance)
            let trend = driftSpeed * duration
            let net = hypot(samples[settledUpper].x - settledFirst.x, samples[settledUpper].y - settledFirst.y)
            // A monotonic 2 px adjustment is movement, whereas a stationary
            // cluster containing 2 px hand tremor should settle at one position.
            guard trend <= 0.0012, driftSpeed <= 0.0015, travel < 0.0001 || net / max(travel, 1e-12) < 0.45 else {
                lower += 1
                continue
            }
            let dwell = Dwell(start: settledFirst.time, end: samples[settledUpper].time, x: meanX, y: meanY)
            // Merge only around the FIRST cluster centre, never an evolving one.
            if var prior = result.last, dwell.start - prior.end <= 1 / pathSampleRate + 1e-9,
               values.allSatisfy({ hypot($0.x - prior.x, $0.y - prior.y) <= radius }) {
                prior.end = dwell.end
                result[result.count - 1] = prior
            } else { result.append(dwell) }
            lower = settledUpper + 1
        }
        return result
    }

    private static func finishContinuousSpan(
        _ samples: [CursorSample], clickTimes: Set<Double>, sigma: Double
    ) -> [CursorSample] {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return samples }
        var anchors: [Double: CursorSample] = [first.time: first, last.time: last]
        var fixedPositions = clickTimes
        for index in samples.indices {
            let sample = samples[index]
            if clickTimes.contains(sample.time)
                || (index > 0 && (sample.isDragging != samples[index - 1].isDragging
                    || sample.cursorKind != samples[index - 1].cursorKind)) {
                anchors[sample.time] = sample
                fixedPositions.insert(sample.time)
            }
        }
        let actionBoundaries = anchors.keys.sorted()
        var dwells: [Dwell] = []
        var sampleIndex = 0
        for (start, end) in zip(actionBoundaries, actionBoundaries.dropFirst()) {
            while sampleIndex + 1 < samples.count, samples[sampleIndex + 1].time <= start { sampleIndex += 1 }
            var upper = sampleIndex
            while upper + 1 < samples.count, samples[upper + 1].time <= end { upper += 1 }
            let candidates = stationaryDwells(Array(samples[sampleIndex...upper]))
            for dwell in candidates {
                dwells.append(dwell)
                for time in [dwell.start, dwell.end] {
                    var point = TimelineMath.cursorPosition(at: time, samples: samples) ?? first
                    point.time = time
                    if !fixedPositions.contains(time) { point.x = dwell.x; point.y = dwell.y }
                    anchors[time] = point
                }
            }
        }
        let knots = anchors.values.sorted { $0.time < $1.time }
        var output: [CursorSample] = []
        var dwellIndex = 0
        sampleIndex = 0
        for (a, b) in zip(knots, knots.dropFirst()) {
            guard b.time > a.time else { continue }
            while sampleIndex + 1 < samples.count, samples[sampleIndex + 1].time <= a.time { sampleIndex += 1 }
            var upper = sampleIndex
            while upper + 1 < samples.count, samples[upper + 1].time < b.time { upper += 1 }
            let raw = [a] + samples[sampleIndex...upper].filter { $0.time > a.time && $0.time < b.time } + [b]
            let midpoint = (a.time + b.time) / 2
            while dwellIndex < dwells.count, dwells[dwellIndex].end < midpoint { dwellIndex += 1 }
            let dwelling = dwellIndex < dwells.count && dwells[dwellIndex].start <= midpoint && midpoint <= dwells[dwellIndex].end
            let observed = TimelineMath.cursorPosition(at: midpoint, samples: raw) ?? a
            let dragging = observed.isDragging == true
            let distance = hypot(b.x - a.x, b.y - a.y)
            let duration = b.time - a.time
            // Only confirmed free-arrow travel is replanned. Shape changes,
            // pauses, scrolling/unknown metadata and button transitions already
            // split this interval. Long continuous gestures retain their route;
            // they are not assumed to be one reposition. Dragging stays verbatim.
            let glide = !dragging && !dwelling && observed.isDragging == false
                && observed.cursorKind == .arrow && duration >= 0.12 && duration <= 2.5 && distance >= 0.012
            if dragging {
                for point in raw where output.last?.time != point.time { output.append(point) }
                continue
            }
            let count = max(1, Int((duration * pathSampleRate - 1e-9).rounded(.up)))
            let times = (0...count).map { $0 == count ? b.time : min(b.time, a.time + Double($0) / pathSampleRate) }
            var path = times.map { time -> CursorSample in
                var point = TimelineMath.cursorPosition(at: time, samples: raw) ?? a
                point.time = time
                if dwelling || glide {
                    let progress = ((time - a.time) / duration).clamped(to: 0...1)
                    // Slow, deliberate movements keep their linear pacing; a
                    // normal reposition gets one ease-in/out for the WHOLE leg.
                    let phase = glide && distance / duration < 0.05 ? progress : TimelineMath.smootherStep(progress)
                    point.x = a.x + (b.x - a.x) * phase
                    point.y = a.y + (b.y - a.y) * phase
                }
                return point
            }
            if !dwelling && !glide {
                // Shape is not an instruction to replay hand jitter. Hands and
                // I-beams receive a lighter filter, with the original shape times.
                let width = observed.cursorKind == .arrow ? sigma : min(sigma, 0.045)
                let radius = max(1, Int((3 * width * pathSampleRate).rounded()))
                let kernel = (-radius...radius).map { exp(-0.5 * pow(Double($0) / pathSampleRate / width, 2)) }
                let total = kernel.reduce(0, +)
                let unfiltered = path
                for index in path.indices {
                    var x = 0.0, y = 0.0
                    for (delta, weight) in zip(-radius...radius, kernel) {
                        let source = unfiltered[min(path.count - 1, max(0, index + delta))]
                        x += source.x * weight; y += source.y * weight
                    }
                    path[index].x = x / total; path[index].y = y / total
                }
                let startX = a.x - path[0].x, startY = a.y - path[0].y
                let endX = b.x - path[path.count - 1].x, endY = b.y - path[path.count - 1].y
                let reach = min(duration, max(0.12, 3 * width))
                for index in path.indices {
                    let left = 1 - TimelineMath.smootherStep((path[index].time - a.time) / reach)
                    let right = 1 - TimelineMath.smootherStep((b.time - path[index].time) / reach)
                    path[index].x = (path[index].x + left * startX + right * endX).clamped(to: 0...1)
                    path[index].y = (path[index].y + left * startY + right * endY).clamped(to: 0...1)
                }
            }
            path[0] = a
            path[path.count - 1] = b
            for point in path where output.last?.time != point.time { output.append(point) }
        }
        return output
    }

    /// A confirmed semantic shape, switched without overlapping cursor artwork.
    /// Restarting a cross-fade during a rapid arrow/hand round trip can otherwise
    /// flash the old shape at full opacity and appear to move the pointer tip.
    public static func kindTransition(
        at time: Double,
        samples: [CursorSample],
        changeIndices: [Int],
        fadeDuration: Double = kindFadeDuration
    ) -> (from: CursorKind, to: CursorKind, progress: Double) {
        guard let first = samples.first else { return (.arrow, .arrow, 1) }
        let confirmation = min(0.08, max(0, fadeDuration))
        var low = 0, high = changeIndices.count
        while low < high {
            let middle = (low + high) / 2
            if samples[changeIndices[middle]].time + confirmation <= time { low = middle + 1 } else { high = middle }
        }
        let kind = low > 0 ? samples[changeIndices[low - 1]].cursorKind : first.cursorKind
        return (kind, kind, 1)
    }

    /// Precompute stable changes once during renderer preparation. A brief
    /// hover over a neighbouring control must not produce a flickering hand.
    public static func kindChangeIndices(_ samples: [CursorSample]) -> [Int] {
        guard let first = samples.first else { return [] }
        let raw = samples.indices.dropFirst().filter { samples[$0].cursorKind != samples[$0 - 1].cursorKind }
        var result: [Int] = []
        var stable = first.cursorKind
        for (position, index) in raw.enumerated() {
            let followingTime = position + 1 < raw.count ? samples[raw[position + 1]].time : Double.infinity
            guard followingTime - samples[index].time >= 0.08,
                  samples[index].cursorKind != stable else { continue }
            result.append(index)
            stable = samples[index].cursorKind
        }
        return result
    }

    /// Second-difference energy of a path: a plain jitter measure for tests.
    public static func roughness(_ samples: [CursorSample]) -> Double {
        guard samples.count > 2 else { return 0 }
        var total = 0.0
        for index in 1..<(samples.count - 1) {
            let ddx = samples[index + 1].x - 2 * samples[index].x + samples[index - 1].x
            let ddy = samples[index + 1].y - 2 * samples[index].y + samples[index - 1].y
            total += ddx * ddx + ddy * ddy
        }
        return sqrt(total / Double(samples.count - 2))
    }
}

/// While the camera is zoomed in, the focus tracks the pointer the way a
/// camera operator would: small moves inside a soft central zone are ignored,
/// larger moves pull the framing after the pointer. The response is a critically
/// damped spring (no overshoot, a short natural lag), precomputed from the
/// same data preview and export share and scaled by the zoom envelope so it
/// vanishes exactly when the camera returns to the overview.
public enum CursorFollow {
    public struct Sample: Hashable, Sendable {
        public var time: Double
        public var dx: Double
        public var dy: Double
        public init(time: Double, dx: Double, dy: Double) {
            self.time = time
            self.dx = dx
            self.dy = dy
        }
    }

    public static let sampleRate = 60.0
    /// Fraction of the visible half-size inside which the pointer may roam freely.
    public static let softZone = 0.62
    /// Outer zone that triggers reframing; the inner zone is its release threshold.
    public static let hardZone = 0.9
    /// Seconds for the spring to settle (about 98%) after the pointer stops.
    public static let response = 0.32

    public static func offsets(
        duration: Double,
        segments: [ZoomSegment],
        settings: ProjectSettings,
        cursor: [CursorSample],
        strength: Double,
        discontinuities: [Double] = [],
        cursorIsAvailable: ((Double) -> Bool)? = nil
    ) -> [Sample] {
        let strength = strength.isFinite ? strength.clamped(to: 0...1) : 0
        guard strength > 0, duration.isFinite, duration > 0, cursor.count > 1,
              segments.contains(where: { $0.isEnabled }) else { return [] }
        let step = 1 / sampleRate
        let count = max(1, Int((duration / step - 1e-9).rounded(.up))) + 1
        let times = (0..<count).map { $0 == count - 1 ? duration : min(duration, Double($0) * step) }
        let cameras = times.map { TimelineMath.zoomState(at: $0, segments: segments, settings: settings) }
        func moved(_ a: ZoomState, _ b: ZoomState) -> Bool {
            abs(a.scale - b.scale) > 0.000_01 || hypot(a.centerX - b.centerX, a.centerY - b.centerY) > 0.000_01
                || abs(a.rotationRadians - b.rotationRadians) > 0.000_01
                || hypot(a.offsetX - b.offsetX, a.offsetY - b.offsetY) > 0.000_01
        }
        let transitioning = cameras.indices.map { index in
            cameras[index].scale > 1.001 && (cameras[index].progress < 0.999
                || moved(cameras[max(0, index - 1)], cameras[index])
                || moved(cameras[index], cameras[min(count - 1, index + 1)]))
        }
        // One fade follows the authored camera transition. Do not simultaneously
        // spring toward the pointer while that camera is zooming/panning away.
        var transitionEnd = [Double](repeating: duration, count: count)
        var nextEnd = duration
        for index in (0..<count).reversed() {
            if !transitioning[index] { nextEnd = times[index] }
            transitionEnd[index] = nextEnd
        }
        let omega = 5.8 / response
        var positionX = 0.0, positionY = 0.0, velocityX = 0.0, velocityY = 0.0
        var targetX = 0.0, targetY = 0.0
        var trackingStartX: Double?, trackingStartY: Double?
        var trackingOriginX = 0.0, trackingOriginY = 0.0
        var transitionStart: Double?
        var transitionX = 0.0, transitionY = 0.0
        var result: [Sample] = []
        result.reserveCapacity(count)
        // Cursor samples are event-driven. A held sampling gap followed by a
        // fresh observation is NOT a source/navigation cut and must not reset
        // an already settled composition. Only explicit continuity information
        // may clear camera position; otherwise hysteresis retains the framing.
        let cuts = discontinuities.filter { $0.isFinite && $0 >= 0 }.sorted()
        var cutIndex = 0
        for index in 0..<count {
            let time = times[index], zoom = cameras[index]
            let deltaTime = index == 0 ? 0 : time - times[index - 1]
            let available = cursorIsAvailable?(time) ?? true
            var crossedCut = false
            while cutIndex < cuts.count, cuts[cutIndex] <= time { cutIndex += 1; crossedCut = true }
            if crossedCut || !available || zoom.scale <= 1.001 {
                positionX = 0; positionY = 0; velocityX = 0; velocityY = 0
                targetX = 0; targetY = 0; trackingStartX = nil; trackingStartY = nil
                transitionStart = nil
            }
            if !available || zoom.scale <= 1.001 {
                result.append(Sample(time: time, dx: 0, dy: 0))
                continue
            }
            if transitioning[index] {
                if transitionStart == nil {
                    transitionStart = time
                    transitionX = positionX; transitionY = positionY
                }
                let start = transitionStart ?? time
                let amount = 1 - TimelineMath.smootherStep((time - start) / max(step, transitionEnd[index] - start))
                positionX = transitionX * amount; positionY = transitionY * amount
                velocityX = 0; velocityY = 0; targetX = 0; targetY = 0; trackingStartX = nil; trackingStartY = nil
                result.append(Sample(time: time, dx: positionX * strength, dy: positionY * strength))
                continue
            }
            if transitionStart != nil {
                positionX = 0; positionY = 0; velocityX = 0; velocityY = 0
                transitionStart = nil
            }
            if let pointer = TimelineMath.cursorPosition(at: time, samples: cursor) {
                let half = 0.5 / zoom.scale
                // Hysteresis is relative to the NEW framing, not the original
                // zoom centre. Moving back inside that frame must not trigger an
                // unnecessary camera return while the user reads or hovers.
                let previousPointer = index > 0 ? TimelineMath.cursorPosition(at: times[index - 1], samples: cursor) : nil
                func updatedTarget(_ target: Double, started: inout Double?, origin: inout Double,
                                   pointer: Double, previous: Double?, base: Double) -> Double {
                    let delta = pointer - base - target
                    let speed = previous.map { abs(pointer - $0) / max(1e-9, deltaTime) } ?? 0
                    if let start = started {
                        if time - start >= 0.12 && abs(delta) < half * softZone {
                            started = nil
                            return target
                        }
                    } else {
                        guard abs(delta) > half * hardZone else { return target }
                        started = time
                        origin = target
                    }
                    let desired = (pointer - base - (delta < 0 ? -1 : 1) * half * softZone)
                        .clamped(to: (half - base)...(1 - half - base))
                    let elapsed = time - (started ?? time)
                    let updated = origin + (desired - origin) * TimelineMath.smootherStep(elapsed / 0.12)
                    if elapsed >= 0.12 && speed < 0.008 { started = nil }
                    return updated
                }
                targetX = updatedTarget(targetX, started: &trackingStartX, origin: &trackingOriginX,
                                        pointer: pointer.x, previous: previousPointer?.x, base: zoom.centerX)
                targetY = updatedTarget(targetY, started: &trackingStartY, origin: &trackingOriginY,
                                        pointer: pointer.y, previous: previousPointer?.y, base: zoom.centerY)
            }
            func advance(_ position: inout Double, _ velocity: inout Double, toward target: Double) {
                let previous = position
                let error = previous - target, momentum = velocity + omega * error
                let decay = exp(-omega * deltaTime)
                position = target + (error + momentum * deltaTime) * decay
                velocity = (velocity - omega * momentum * deltaTime) * decay
                if position < min(previous, target) || position > max(previous, target) {
                    position = position.clamped(to: min(previous, target)...max(previous, target))
                    velocity = 0
                }
            }
            advance(&positionX, &velocityX, toward: targetX)
            advance(&positionY, &velocityY, toward: targetY)
            result.append(Sample(time: time, dx: positionX * strength, dy: positionY * strength))
        }
        return result
    }

    /// Linear interpolation of the precomputed offsets at `time`.
    public static func offset(at time: Double, samples: [Sample]) -> (dx: Double, dy: Double) {
        guard let first = samples.first else { return (0, 0) }
        if time <= first.time { return (first.dx, first.dy) }
        guard let last = samples.last, time < last.time else { return (samples.last?.dx ?? 0, samples.last?.dy ?? 0) }
        var low = 0
        var high = samples.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if samples[middle].time <= time { low = middle } else { high = middle }
        }
        let lhs = samples[low]
        let rhs = samples[high]
        let fraction = ((time - lhs.time) / max(1e-9, rhs.time - lhs.time)).clamped(to: 0...1)
        return (lhs.dx + (rhs.dx - lhs.dx) * fraction, lhs.dy + (rhs.dy - lhs.dy) * fraction)
    }
}
