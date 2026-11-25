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

/// Precomputed viewport framing shared by the player and the exporter. Follow
/// is expressed in fractions of the visible frame, after sampling the pointer
/// at the presentation time and applying the recording's source crop.
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
    /// Distances from the viewport centre, as a fraction of its visible half-width/height.
    public static let softZone = 0.42
    public static let hardZone = 0.76
    /// Time constant for ordinary tracking. The outer band limits lag on fast moves.
    public static let response = 0.052

    public static func offsets(
        duration: Double,
        segments: [ZoomSegment],
        settings: ProjectSettings,
        cursor: [CursorSample],
        strength: Double,
        sourceCrop: SourceCropInsets = SourceCropInsets(),
        discontinuities: [Double] = [],
        cursorIsAvailable: ((Double) -> Bool)? = nil
    ) -> [Sample] {
        let strength = strength.isFinite ? strength.clamped(to: 0...1) : 0
        let cues = segments.filter { $0.isEnabled && $0.start.isFinite && $0.end.isFinite }
            .sorted { $0.start < $1.start }
        guard strength > 0, duration.isFinite, duration > 0, !cursor.isEmpty, !cues.isEmpty else { return [] }

        let cuts = discontinuities.filter { $0.isFinite && $0 >= 0 }.sorted()
        let count = max(1, Int((duration * sampleRate - 1e-9).rounded(.up))) + 1
        let margin = softZone + (1 - strength) * 0.24
        let limit = hardZone + (1 - strength) * 0.16
        let responseTime = response / settings.resolvedZoomFollowSpeed
        // Below the default follow strength the user can deliberately keep
        // more of the authored framing. The default gets full travel at the
        // edges; stronger settings start panning closer to the centre.
        let travel = min(1, strength / ProjectSettings.defaultZoomFollowsCursor)
        var x = 0.0, y = 0.0
        var previous = ZoomState()
        var startPointer: CGPoint?
        var movedDuringTransition = false
        var followSince: Double?
        var nextCut = 0, nextCue = 0
        var active: [ZoomSegment] = []
        var result: [Sample] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let time = min(duration, Double(index) / sampleRate)
            let dt = index > 0 ? time - Double(index - 1) / sampleRate : 0
            while nextCue < cues.count, cues[nextCue].start <= time {
                active.append(cues[nextCue])
                nextCue += 1
            }
            active.removeAll { $0.end < time }
            let zoom = TimelineMath.zoomState(at: time, segments: active, settings: settings)
            let crossedCut = nextCut < cuts.count && cuts[nextCut] <= time
            while nextCut < cuts.count, cuts[nextCut] <= time { nextCut += 1 }
            let available = cursorIsAvailable?(time) ?? true
            if crossedCut || !available || zoom.scale <= 1.001 {
                x = 0; y = 0; startPointer = nil; movedDuringTransition = false; followSince = nil
            }
            if available && zoom.scale > 1.001 && !crossedCut {
                let half = 0.5 / zoom.scale
                let sampled = TimelineMath.cursorPosition(at: time, samples: cursor, interpolate: settings.cursorAnimation != .none)
                let pointer = sampled.flatMap { sourceCrop.croppedPoint(x: $0.x, y: $0.y) }
                let transitioning = zoom.progress < 0.999
                    || abs(zoom.centerX - previous.centerX) + abs(zoom.centerY - previous.centerY) > 0.00001
                if transitioning {
                    if startPointer == nil { startPointer = pointer }
                    if let startPointer, let pointer,
                       max(abs(pointer.x - startPointer.x), abs(pointer.y - startPointer.y)) > half * 0.10 {
                        movedDuringTransition = true
                    }
                } else {
                    startPointer = nil
                    movedDuringTransition = false
                }
                // A stationary pointer must not steer an authored entrance or
                // handoff. During an automatic move a traveling pointer can
                // already be leaving the shot before the entrance is complete.
                let followTransition = movedDuringTransition && !active.contains { $0.kind == .manual }
                if transitioning && !followTransition {
                    followSince = nil
                    let release = zoom.scale < previous.scale
                        ? (zoom.scale - 1) / (previous.scale - 1)
                        : exp(-dt / 0.15)
                    x *= release
                    y *= release
                } else if let pointer {
                    if followSince == nil { followSince = time }
                    let engage = TimelineMath.smootherStep((time - (followSince ?? time)) / 0.10)
                    let mix = -expm1(-dt / responseTime)
                    func track(_ offset: Double, pointer: Double, base: Double) -> Double {
                        let delta = (pointer - base) * travel
                        // The dead zone moves with the actual framing. A small
                        // reversal or a settled hover therefore leaves it still.
                        let desired = offset.clamped(to: (delta - half * margin)...(delta + half * margin))
                        let eased = offset + (desired - offset) * mix
                        let guarded = eased.clamped(to: (delta - half * limit)...(delta + half * limit))
                        return offset + (guarded - offset) * engage
                    }
                    x = track(x, pointer: pointer.x, base: zoom.centerX)
                    y = track(y, pointer: pointer.y, base: zoom.centerY)
                }
                // Store only camera travel the image can actually show. Latent
                // offsets behind a source edge otherwise delay a reversal.
                x = x.clamped(to: (half - zoom.centerX)...(1 - half - zoom.centerX))
                y = y.clamped(to: (half - zoom.centerY)...(1 - half - zoom.centerY))
            }
            result.append(Sample(time: time, dx: x, dy: y))
            previous = zoom
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
