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

    /// Resamples `samples` at `pathSampleRate`, smooths both axes with a
    /// zero-phase Gaussian of width `sigma`, and blends the result back onto
    /// each click position inside a short window so clicks stay exact.
    public static func smoothedPath(
        samples: [CursorSample],
        clicks: [ClickEvent],
        sigma: Double
    ) -> [CursorSample] {
        let sorted = samples
            .filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }
            .sorted { $0.time < $1.time }
        guard sorted.count > 1, sigma > 0, sigma.isFinite else { return sorted }
        let start = sorted[0].time
        let end = sorted[sorted.count - 1].time
        guard end > start else { return sorted }
        let step = 1 / pathSampleRate
        let count = Int(((end - start) / step).rounded(.up)) + 1
        var times = [Double](repeating: 0, count: count)
        var xs = [Double](repeating: 0, count: count)
        var ys = [Double](repeating: 0, count: count)
        var kindIndex = 0
        var kinds = [CursorKind](repeating: sorted[0].cursorKind, count: count)
        for index in 0..<count {
            let time = min(end, start + Double(index) * step)
            times[index] = time
            let sample = TimelineMath.cursorPosition(at: time, samples: sorted) ?? sorted[0]
            xs[index] = sample.x
            ys[index] = sample.y
            while kindIndex + 1 < sorted.count, sorted[kindIndex + 1].time <= time { kindIndex += 1 }
            kinds[index] = sorted[kindIndex].cursorKind
        }
        let radius = max(1, Int((3 * sigma / step).rounded()))
        let kernel = (-radius...radius).map { exp(-0.5 * pow(Double($0) * step / sigma, 2)) }
        let kernelSum = kernel.reduce(0, +)
        func convolve(_ values: [Double]) -> [Double] {
            var result = values
            for index in values.indices {
                var accumulator = 0.0
                for (offset, weight) in zip(-radius...radius, kernel) {
                    let sampleIndex = min(values.count - 1, max(0, index + offset))
                    accumulator += values[sampleIndex] * weight
                }
                result[index] = accumulator / kernelSum
            }
            return result
        }
        var smoothX = convolve(xs)
        var smoothY = convolve(ys)
        // Pin the path to every click: shift the neighbourhood by the residual
        // at the click time with a smootherStep falloff, keeping C1 continuity.
        let window = max(0.12, 3 * sigma)
        for click in clicks where click.time.isFinite && click.x.isFinite && click.y.isFinite {
            guard click.time >= start - window, click.time <= end + window else { continue }
            let clampedTime = min(end, max(start, click.time))
            let position = (clampedTime - start) / step
            let lower = min(count - 1, max(0, Int(position.rounded(.down))))
            let upper = min(count - 1, lower + 1)
            let fraction = position - Double(lower)
            let pathX = smoothX[lower] + (smoothX[upper] - smoothX[lower]) * fraction
            let pathY = smoothY[lower] + (smoothY[upper] - smoothY[lower]) * fraction
            let residualX = click.x - pathX
            let residualY = click.y - pathY
            guard abs(residualX) > 1e-9 || abs(residualY) > 1e-9 else { continue }
            let firstIndex = max(0, Int(((click.time - window - start) / step).rounded(.down)))
            let lastIndex = min(count - 1, Int(((click.time + window - start) / step).rounded(.up)))
            guard firstIndex <= lastIndex else { continue }
            for index in firstIndex...lastIndex {
                let weight = 1 - TimelineMath.smootherStep(abs(times[index] - click.time) / window)
                smoothX[index] += residualX * weight
                smoothY[index] += residualY * weight
            }
        }
        return (0..<count).map { index in
            CursorSample(
                time: times[index],
                x: smoothX[index].clamped(to: 0...1),
                y: smoothY[index].clamped(to: 0...1),
                cursorKind: kinds[index]
            )
        }
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
/// larger moves pull the framing after the pointer, and the pointer is never
/// allowed past the outer edge of the viewport. The response is a critically
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
    /// Fraction of the visible half-size the pointer is never allowed to leave.
    public static let hardZone = 0.9
    /// Seconds for the spring to settle (about 98%) after the pointer stops.
    public static let response = 0.5

    public static func offsets(
        duration: Double,
        segments: [ZoomSegment],
        settings: ProjectSettings,
        cursor: [CursorSample],
        strength: Double
    ) -> [Sample] {
        let strength = strength.isFinite ? strength.clamped(to: 0...1) : 0
        guard strength > 0, duration.isFinite, duration > 0, cursor.count > 1,
              segments.contains(where: { $0.isEnabled }) else { return [] }
        let step = 1 / sampleRate
        let count = Int((duration / step).rounded(.up)) + 1
        let omega = 5.8 / response
        var positionX = 0.0, positionY = 0.0
        var velocityX = 0.0, velocityY = 0.0
        var result: [Sample] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let time = min(duration, Double(index) * step)
            var desiredX = 0.0, desiredY = 0.0
            var progress = 0.0
            let zoom = TimelineMath.zoomState(at: time, segments: segments, settings: settings)
            if zoom.scale > 1.001, let pointer = TimelineMath.cursorPosition(at: time, samples: cursor) {
                let half = 0.5 / zoom.scale
                desiredX = desiredOffset(pointer.x - zoom.centerX, half: half)
                desiredY = desiredOffset(pointer.y - zoom.centerY, half: half)
                progress = zoom.progress
            }
            // Critically damped spring, semi-implicit Euler (stable at 60 Hz).
            velocityX += (omega * omega * (desiredX - positionX) - 2 * omega * velocityX) * step
            velocityY += (omega * omega * (desiredY - positionY) - 2 * omega * velocityY) * step
            positionX += velocityX * step
            positionY += velocityY * step
            result.append(Sample(time: time, dx: positionX * strength * progress, dy: positionY * strength * progress))
        }
        return result
    }

    /// Soft zone: the pull grows smoothly with distance; hard zone: whatever
    /// is needed to keep the pointer inside the outer 90% of the viewport.
    static func desiredOffset(_ delta: Double, half: Double) -> Double {
        guard half > 0, delta.isFinite else { return 0 }
        let soft = delta * TimelineMath.smootherStep(abs(delta) / (half * softZone))
        let limit = half * hardZone
        let hard = abs(delta) > limit ? delta - (delta < 0 ? -limit : limit) : 0
        return abs(hard) > abs(soft) ? hard : soft
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
