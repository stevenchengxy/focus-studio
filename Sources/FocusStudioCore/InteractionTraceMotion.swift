import Foundation

/// Motion finishing for execution traces only. Manual recordings continue to
/// use the established CursorMotion implementation without changes.
public enum InteractionCursorMotion {
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
        let step = 1 / CursorMotion.pathSampleRate
        // Floating-point noise at an exact grid boundary must not create two
        // terminal samples with the same time and different smoothed positions.
        let count = max(1, Int(((end - start) / step - 1e-9).rounded(.up))) + 1
        var times = [Double](repeating: 0, count: count)
        var xs = [Double](repeating: 0, count: count)
        var ys = [Double](repeating: 0, count: count)
        var kindIndex = 0
        var kinds = [CursorKind](repeating: sorted[0].cursorKind, count: count)
        for index in 0..<count {
            let time = index == count - 1 ? end : min(end, start + Double(index) * step)
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
            let lower = clampedTime == end ? count - 1 : min(count - 1, max(0, Int(position.rounded(.down))))
            let upper = min(count - 1, lower + 1)
            let fraction = ((clampedTime - times[lower]) / max(1e-9, times[upper] - times[lower])).clamped(to: 0...1)
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
        // Keep a sample at the exact event time. A click can fall between the
        // 120 Hz samples, and a later click's smoothing window can move an
        // earlier anchor; explicit knots keep every rendered press on target.
        let anchors = clicks.filter {
            $0.time.isFinite && $0.x.isFinite && $0.y.isFinite && $0.time >= start && $0.time <= end
        }.sorted { $0.time < $1.time }
        var anchorIndex = 0
        var result: [CursorSample] = []
        result.reserveCapacity(count + anchors.count)
        for index in 0..<count {
            while anchorIndex < anchors.count, anchors[anchorIndex].time <= times[index] {
                let click = anchors[anchorIndex]
                let anchor = CursorSample(
                    time: click.time, x: click.x.clamped(to: 0...1), y: click.y.clamped(to: 0...1),
                    cursorKind: TimelineMath.cursorPosition(at: click.time, samples: sorted)?.cursorKind ?? .arrow
                )
                if result.last?.time == click.time { result[result.count - 1] = anchor }
                else { result.append(anchor) }
                anchorIndex += 1
            }
            if result.last?.time == times[index] { continue }
            result.append(CursorSample(
                time: times[index],
                x: smoothX[index].clamped(to: 0...1),
                y: smoothY[index].clamped(to: 0...1),
                cursorKind: kinds[index]
            ))
        }
        return result
    }
}

/// Camera following for execution traces, including explicit navigation cuts.
/// Returns the shared sample representation while leaving manual follow intact.
public enum InteractionCursorFollow {
    public static func offsets(
        duration: Double,
        segments: [ZoomSegment],
        settings: ProjectSettings,
        cursor: [CursorSample],
        strength: Double,
        discontinuities: [Double] = [],
        cursorIsAvailable: ((Double) -> Bool)? = nil
    ) -> [CursorFollow.Sample] {
        let strength = strength.isFinite ? strength.clamped(to: 0...1) : 0
        guard strength > 0, duration.isFinite, duration > 0, cursor.count > 1,
              segments.contains(where: { $0.isEnabled }) else { return [] }
        let step = 1 / CursorFollow.sampleRate
        let count = Int((duration / step).rounded(.up)) + 1
        let omega = 5.8 / CursorFollow.response
        var positionX = 0.0, positionY = 0.0
        var velocityX = 0.0, velocityY = 0.0
        var result: [CursorFollow.Sample] = []
        let cuts = discontinuities.filter { $0.isFinite && $0 >= 0 }.sorted()
        var cutIndex = 0
        result.reserveCapacity(count)
        for index in 0..<count {
            let time = min(duration, Double(index) * step)
            while cutIndex < cuts.count, cuts[cutIndex] <= time {
                positionX = 0
                positionY = 0
                velocityX = 0
                velocityY = 0
                cutIndex += 1
            }
            var desiredX = 0.0, desiredY = 0.0
            var progress = 0.0
            let zoom = TimelineMath.zoomState(at: time, segments: segments, settings: settings)
            if zoom.scale > 1.001, cursorIsAvailable?(time) ?? true,
               let pointer = TimelineMath.cursorPosition(at: time, samples: cursor) {
                let half = 0.5 / zoom.scale
                desiredX = CursorFollow.desiredOffset(pointer.x - zoom.centerX, half: half)
                desiredY = CursorFollow.desiredOffset(pointer.y - zoom.centerY, half: half)
                progress = zoom.progress
            }
            // Critically damped spring, semi-implicit Euler (stable at 60 Hz).
            velocityX += (omega * omega * (desiredX - positionX) - 2 * omega * velocityX) * step
            velocityY += (omega * omega * (desiredY - positionY) - 2 * omega * velocityY) * step
            positionX += velocityX * step
            positionY += velocityY * step
            result.append(CursorFollow.Sample(time: time, dx: positionX * strength * progress, dy: positionY * strength * progress))
        }
        return result
    }
}
