import Foundation

/// Pointer motion finishing shared by preview and export.
///
/// Raw mouse samples carry hand jitter and arrive at an uneven rate. The
/// rendered pointer follows a dense, zero-phase smoothed path that is pinned
/// to every click position at the click time, so the arrow still lands exactly
/// where the click ring appears. Cursor shape changes (arrow ↔ I-beam) are
/// exposed as a short cross-fade instead of a one-frame swap.
public enum CursorMotion {
    /// Dense path sample rate in Hz.
    public static let pathSampleRate = 120.0
    /// Seconds over which a cursor shape change cross-fades.
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

    /// Finish a continuous shot. Callers split at edit cuts and navigation gaps.
    /// Known free arrow movement is simplified within a small spatial error;
    /// clicks, dwell, cursor-kind changes and held buttons remain semantic anchors.
    /// Legacy samples without button state only receive the existing de-jitter pass.
    public static func smoothedPath(
        samples: [CursorSample],
        clicks: [ClickEvent],
        sigma: Double
    ) -> [CursorSample] {
        let ordered = samples.filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }
            .enumerated().sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map(\.element)
        guard ordered.count > 1, sigma > 0, sigma.isFinite else { return ordered }
        var sorted: [CursorSample] = []
        for sample in ordered {
            if sorted.last?.time == sample.time { sorted[sorted.count - 1] = sample }
            else { sorted.append(sample) }
        }
        guard let first = sorted.first, let last = sorted.last, last.time > first.time else { return sorted }
        let start = first.time, end = last.time, step = 1 / pathSampleRate
        let sigma = min(sigma, 0.25)
        let clickAnchors = clicks.filter {
            $0.time.isFinite && $0.x.isFinite && $0.y.isFinite && $0.time >= start && $0.time <= end
        }.sorted { $0.time < $1.time }
        let simplified = simplifiedFreeMovement(sorted, clicks: clickAnchors, tolerance: 0.025 * min(1, sigma / 0.085))
        let count = max(1, Int(((end - start) / step - 1e-9).rounded(.up))) + 1
        var dense: [CursorSample] = []
        dense.reserveCapacity(count)
        for index in 0..<count {
            let time = index == count - 1 ? end : min(end, start + Double(index) * step)
            var sample = TimelineMath.cursorPosition(at: time, samples: simplified.samples) ?? first
            // Shape and pressed state always come from the observed timeline.
            let observed = TimelineMath.cursorPosition(at: time, samples: sorted) ?? first
            sample.cursorKind = observed.cursorKind
            sample.isDragging = observed.isDragging
            dense.append(sample)
        }
        let radius = max(1, Int((3 * sigma / step).rounded()))
        let kernel = (-radius...radius).map { exp(-0.5 * pow(Double($0) * step / sigma, 2)) }
        let kernelSum = kernel.reduce(0, +)
        var smoothed = dense
        var dwellIndex = 0
        for index in dense.indices {
            while dwellIndex < simplified.dwells.count, simplified.dwells[dwellIndex].upperBound < dense[index].time { dwellIndex += 1 }
            let isDwelling = dwellIndex < simplified.dwells.count && simplified.dwells[dwellIndex].contains(dense[index].time)
            // Selection, slider drags and semantic hovers must keep their real
            // path and timing, including turns between two mouse-down events.
            guard dense[index].isDragging != true, dense[index].cursorKind == .arrow, !isDwelling else { continue }
            var x = 0.0, y = 0.0
            for (offset, weight) in zip(-radius...radius, kernel) {
                let source = dense[min(count - 1, max(0, index + offset))]
                x += source.x * weight
                y += source.y * weight
            }
            smoothed[index].x = x / kernelSum
            smoothed[index].y = y / kernelSum
        }
        // Exact anchors plus compact, non-overwriting residual blends. In
        // particular, a rapid second click cannot pull the first off target.
        var anchors = [first, last]
        for range in simplified.dwells {
            for time in [range.lowerBound, range.upperBound] {
                if var anchor = TimelineMath.cursorPosition(at: time, samples: sorted) {
                    anchor.time = time
                    anchors.append(anchor)
                }
            }
        }
        for index in sorted.indices {
            let sample = sorted[index]
            if sample.isDragging == true || sample.cursorKind != .arrow
                || (index > 0 && (sorted[index - 1].isDragging != sample.isDragging
                    || sorted[index - 1].cursorKind != sample.cursorKind)) {
                anchors.append(sample)
            }
        }
        for click in clickAnchors {
            var anchor = TimelineMath.cursorPosition(at: click.time, samples: sorted) ?? first
            anchor.time = click.time
            anchor.x = click.x.clamped(to: 0...1)
            anchor.y = click.y.clamped(to: 0...1)
            anchors.append(anchor)
        }
        var unique: [Double: CursorSample] = [:]
        for anchor in anchors { unique[anchor.time] = anchor }
        anchors = unique.values.sorted { $0.time < $1.time }
        let residuals = anchors.map { anchor -> (x: Double, y: Double) in
            let value = TimelineMath.cursorPosition(at: anchor.time, samples: smoothed) ?? first
            return (anchor.x - value.x, anchor.y - value.y)
        }
        let window = max(0.12, 3 * sigma)
        var anchorIndex = 0
        var result: [CursorSample] = []
        result.reserveCapacity(count + anchors.count)
        for sample in smoothed {
            while anchorIndex < anchors.count && anchors[anchorIndex].time <= sample.time {
                result.append(anchors[anchorIndex])
                anchorIndex += 1
            }
            if result.last?.time == sample.time { continue }
            var output = sample
            for index in [anchorIndex - 1, anchorIndex] where anchors.indices.contains(index) {
                let anchor = anchors[index]
                let neighbour = sample.time < anchor.time ? index - 1 : index + 1
                let reach = anchors.indices.contains(neighbour) ? min(window, abs(anchors[neighbour].time - anchor.time)) : window
                let weight = 1 - TimelineMath.smootherStep(abs(sample.time - anchor.time) / max(1e-9, reach))
                output.x += residuals[index].x * weight
                output.y += residuals[index].y * weight
            }
            output.x = output.x.clamped(to: 0...1)
            output.y = output.y.clamped(to: 0...1)
            result.append(output)
        }
        return result
    }

    /// Bounded polyline simplification, restricted to confirmed free movement.
    /// This is deliberately not a click-to-click shortcut: wide turns, hovering,
    /// pauses and drags remain, and long recordings are split into bounded runs.
    private static func simplifiedFreeMovement(
        _ samples: [CursorSample], clicks: [ClickEvent], tolerance: Double
    ) -> (samples: [CursorSample], dwells: [ClosedRange<Double>]) {
        guard samples.count > 2, tolerance > 0 else { return (samples, []) }
        var dwells: [ClosedRange<Double>] = []
        var keep = [Bool](repeating: false, count: samples.count)
        keep[0] = true
        keep[samples.count - 1] = true
        var clickIndex = 0
        for index in samples.indices {
            let sample = samples[index]
            if sample.isDragging != false || sample.cursorKind != .arrow { keep[index] = true }
            if index > 0 {
                let previous = samples[index - 1]
                if sample.isDragging != previous.isDragging || sample.cursorKind != previous.cursorKind
                    || sample.time - previous.time > 0.25 {
                    keep[index] = true
                    keep[index - 1] = true
                }
                while clickIndex < clicks.count && clicks[clickIndex].time <= sample.time {
                    keep[index] = true
                    keep[index - 1] = true
                    clickIndex += 1
                }
            }
            // A real stop must survive even if no cursor-kind change was observed.
            // Inspect at most a short time window, not the whole recording.
            var upper = index
            var xmin = sample.x, xmax = sample.x, ymin = sample.y, ymax = sample.y
            while upper + 1 < samples.count && upper - index < 64 && samples[upper].time - sample.time < 0.12 {
                upper += 1
                xmin = min(xmin, samples[upper].x); xmax = max(xmax, samples[upper].x)
                ymin = min(ymin, samples[upper].y); ymax = max(ymax, samples[upper].y)
                if hypot(xmax - xmin, ymax - ymin) > 0.006 { break }
            }
            if upper > index && samples[upper].time - sample.time >= 0.12
                && hypot(xmax - xmin, ymax - ymin) <= 0.006 {
                keep[index] = true
                keep[upper] = true
                let range = sample.time...samples[upper].time
                if let previous = dwells.last, previous.upperBound >= range.lowerBound {
                    dwells[dwells.count - 1] = previous.lowerBound...range.upperBound
                } else { dwells.append(range) }
            }
        }
        var boundary = 0
        for index in 1..<samples.count {
            if samples[index].time - samples[boundary].time >= 1.5 { keep[index] = true }
            if keep[index] { boundary = index }
        }
        let anchors = keep.indices.filter { keep[$0] }
        for (start, end) in zip(anchors, anchors.dropFirst()) where end > start + 1 {
            var ranges = [(start, end)]
            while let (lower, upper) = ranges.popLast() {
                guard upper > lower + 1 else { continue }
                let a = samples[lower], b = samples[upper]
                let dx = b.x - a.x, dy = b.y - a.y, length2 = dx * dx + dy * dy
                var furthest = lower, error = tolerance
                for index in (lower + 1)..<upper {
                    let sample = samples[index]
                    let fraction = length2 > 1e-12 ? (((sample.x - a.x) * dx + (sample.y - a.y) * dy) / length2).clamped(to: 0...1) : 0
                    let distance = hypot(sample.x - a.x - fraction * dx, sample.y - a.y - fraction * dy)
                    if distance > error { error = distance; furthest = index }
                }
                if furthest != lower {
                    keep[furthest] = true
                    ranges.append((lower, furthest))
                    ranges.append((furthest, upper))
                }
            }
        }
        return (samples.indices.filter { keep[$0] }.map { samples[$0] }, dwells)
    }

    /// The shape cross-fade in effect at `time`. `progress` is 1 once the
    /// current shape has fully appeared (or when it never changed).
    public static func kindTransition(
        at time: Double,
        samples: [CursorSample],
        changeIndices: [Int],
        fadeDuration: Double = kindFadeDuration
    ) -> (from: CursorKind, to: CursorKind, progress: Double) {
        guard let first = samples.first else { return (.arrow, .arrow, 1) }
        var low = 0
        var high = changeIndices.count
        while low < high {
            let middle = (low + high) / 2
            if samples[changeIndices[middle]].time <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return (first.cursorKind, first.cursorKind, 1) }
        let changeIndex = changeIndices[low - 1]
        let change = samples[changeIndex]
        let previous = samples[max(0, changeIndex - 1)].cursorKind
        guard fadeDuration > 0 else { return (previous, change.cursorKind, 1) }
        let progress = TimelineMath.smootherStep((time - change.time) / fadeDuration)
        return (previous, change.cursorKind, progress)
    }

    /// Indices of samples whose shape differs from the previous sample.
    public static func kindChangeIndices(_ samples: [CursorSample]) -> [Int] {
        samples.indices.dropFirst().filter { samples[$0].cursorKind != samples[$0 - 1].cursorKind }
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
    /// Outer zone where following reaches its full distance response.
    public static let hardZone = 0.9
    /// Seconds for the spring to settle (about 98%) after the pointer stops.
    public static let response = 0.5

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
        let omega = 5.8 / response
        var positionX = 0.0, positionY = 0.0
        var velocityX = 0.0, velocityY = 0.0
        var result: [Sample] = []
        result.reserveCapacity(count)
        let cuts = discontinuities.filter { $0.isFinite && $0 >= 0 }.sorted()
        var cutIndex = 0
        for index in 0..<count {
            let time = index == count - 1 ? duration : min(duration, Double(index) * step)
            let deltaTime = index == 0 ? 0 : time - result[index - 1].time
            let available = cursorIsAvailable?(time) ?? true
            var crossedCut = false
            while cutIndex < cuts.count, cuts[cutIndex] <= time { cutIndex += 1; crossedCut = true }
            if crossedCut || !available {
                positionX = 0; positionY = 0; velocityX = 0; velocityY = 0
            }
            var desiredX = 0.0, desiredY = 0.0
            var progress = 0.0
            let zoom = TimelineMath.zoomState(at: time, segments: segments, settings: settings)
            if zoom.scale > 1.001, available, let pointer = TimelineMath.cursorPosition(at: time, samples: cursor) {
                let half = 0.5 / zoom.scale
                desiredX = desiredOffset(pointer.x - zoom.centerX, half: half)
                desiredY = desiredOffset(pointer.y - zoom.centerY, half: half)
                progress = zoom.progress
            }
            // Closed-form critical damping remains stable at the final partial
            // frame. Discard old momentum when its direction would cause a bounce.
            func advance(_ position: inout Double, _ velocity: inout Double, toward target: Double) {
                let previous = position
                let error = previous - target
                let momentum = velocity + omega * error
                let decay = exp(-omega * deltaTime)
                position = target + (error + momentum * deltaTime) * decay
                velocity = (velocity - omega * momentum * deltaTime) * decay
                if position < min(previous, target) || position > max(previous, target) {
                    position = position.clamped(to: min(previous, target)...max(previous, target))
                    velocity = 0
                }
            }
            advance(&positionX, &velocityX, toward: desiredX)
            advance(&positionY, &velocityY, toward: desiredY)
            result.append(Sample(time: time, dx: positionX * strength * progress, dy: positionY * strength * progress))
        }
        return result
    }

    /// A true quiet centre: tiny hand motion must not move the entire picture.
    /// Pull ramps smoothly between the inner and outer zones; beyond that range
    /// it tracks only the excess distance rather than continually recentring.
    static func desiredOffset(_ delta: Double, half: Double) -> Double {
        guard half > 0, delta.isFinite else { return 0 }
        let excess = abs(delta) - half * softZone
        guard excess > 0 else { return 0 }
        let ramp = TimelineMath.smootherStep(excess / (half * (hardZone - softZone)))
        return (delta < 0 ? -1 : 1) * excess * ramp
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
