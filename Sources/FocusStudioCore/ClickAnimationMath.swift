import Foundation

/// Shared, time-based animation envelopes keep scrubbing, preview, and export
/// deterministic. Every click has its own envelope, including rapid double clicks.
public enum ClickAnimationMath {
    public struct Layer: Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case ring, fill, halo }
        public var kind: Kind
        /// Radius in 1080p canvas pixels, before the user's size multiplier.
        public var radius: Double
        public var opacity: Double
    }

    public static func layers(age: Double, settings: ClickAnimationSettings) -> [Layer] {
        let settings = settings.sanitized
        guard age.isFinite, age > 0, age < settings.duration, settings.intensity > 0 else {
            return []
        }
        let t = age / settings.duration
        let expansion = 1 - pow(1 - t, 3)
        // A short, eased attack avoids a one-frame flash. Both ends have zero
        // velocity so the ring neither appears nor disappears abruptly.
        let attack = TimelineMath.smootherStep(t / 0.12)
        let fade = 1 - TimelineMath.smootherStep((t - 0.12) / 0.88)
        let envelope = attack * fade * settings.intensity
        let size = settings.size
        switch settings.style {
        case .ripple:
            let delayed = ((t - 0.13) / 0.87).clamped(to: 0...1)
            let secondEnvelope = TimelineMath.smootherStep(delayed / 0.16)
                * (1 - TimelineMath.smootherStep(delayed)) * settings.intensity
            return [
                Layer(kind: .halo, radius: (18 + 34 * expansion) * size, opacity: envelope * 0.50),
                Layer(kind: .ring, radius: (12 + 35 * expansion) * size, opacity: envelope * 0.88),
                Layer(kind: .ring, radius: (9 + 23 * (1 - pow(1 - delayed, 3))) * size, opacity: secondEnvelope * 0.40),
            ]
        case .halo:
            return [
                Layer(kind: .halo, radius: (24 + 24 * expansion) * size, opacity: envelope),
                Layer(kind: .fill, radius: (8 + 10 * expansion) * size, opacity: envelope * 0.15),
            ]
        case .pulse:
            return [
                Layer(kind: .fill, radius: (10 + 21 * expansion) * size, opacity: envelope * 0.23),
                Layer(kind: .ring, radius: (11 + 22 * expansion) * size, opacity: envelope * 0.95),
            ]
        }
    }

    /// Compress around the cursor hotspot, then settle with a restrained rebound.
    /// No spring integrator is used, so seeking directly to a frame is exact.
    public static func cursorPressScale(age: Double, settings: ClickAnimationSettings) -> Double {
        let settings = settings.sanitized
        let duration = min(0.42, settings.duration * 0.72)
        guard settings.pressCursor, age.isFinite, age > 0, age < duration else { return 1 }
        let t = age / duration
        if t < 0.24 {
            return 1 - 0.14 * TimelineMath.smootherStep(t / 0.24)
        }
        if t < 0.65 {
            return 0.86 + 0.17 * TimelineMath.smootherStep((t - 0.24) / 0.41)
        }
        return 1.03 - 0.03 * TimelineMath.smootherStep((t - 0.65) / 0.35)
    }
}
