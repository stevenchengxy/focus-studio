import Foundation

/// A non-looping, nondestructive audio excerpt placed on the output timeline.
/// Source duration is retained so shortening a clip never loses its handles.
public struct VoiceoverClip: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var filePath: String
    public var sourceDuration: Double
    public var sourceStart: Double
    public var sourceEnd: Double
    public var timelineStart: Double
    public var volume: Double
    public var fadeIn: Double
    public var fadeOut: Double
    public var isEnabled: Bool

    public init(id: UUID = UUID(), title: String, filePath: String, sourceDuration: Double,
                sourceStart: Double = 0, sourceEnd: Double? = nil, timelineStart: Double = 0,
                volume: Double = 1, fadeIn: Double = 0.08, fadeOut: Double = 0.12, isEnabled: Bool = true) {
        self.id = id; self.title = title; self.filePath = filePath; self.sourceDuration = sourceDuration
        self.sourceStart = sourceStart; self.sourceEnd = sourceEnd ?? sourceDuration
        self.timelineStart = timelineStart; self.volume = volume
        self.fadeIn = fadeIn; self.fadeOut = fadeOut; self.isEnabled = isEnabled
    }
    public var duration: Double { sourceEnd - sourceStart }
    public var timelineEnd: Double { timelineStart + duration }

    public func validated() throws -> Self {
        guard !filePath.isEmpty, !title.isEmpty,
              [sourceDuration, sourceStart, sourceEnd, timelineStart, volume, fadeIn, fadeOut].allSatisfy(\.isFinite),
              sourceDuration > 0, sourceStart >= 0, sourceEnd <= sourceDuration + 0.001,
              duration >= 0.02, timelineStart >= 0, (0...2).contains(volume),
              (0...30).contains(fadeIn), (0...30).contains(fadeOut) else {
            throw DemoEditError.invalidMedia("Voiceover needs valid source in/out points, a nonnegative timeline start, volume 0–2 and fades 0–30 seconds.")
        }
        return self
    }

    /// Used by ripple trims/cuts/reorders so speech follows the retained picture.
    public func excerpt(keeping range: DemoKeepRange, movedTo outputStart: Double, newID: Bool) -> Self? {
        let lower = max(timelineStart, range.start), upper = min(timelineEnd, range.end)
        guard upper - lower >= 0.02 else { return nil }
        var result = self
        if newID { result.id = UUID() }
        result.sourceStart += lower - timelineStart
        result.sourceEnd = result.sourceStart + upper - lower
        result.timelineStart = outputStart + lower - range.start
        // Newly exposed edit boundaries get a tiny de-click ramp, while the
        // original ends retain the user's fades.
        result.fadeIn = lower > timelineStart ? min(0.008, result.duration / 2) : fadeIn
        result.fadeOut = upper < timelineEnd ? min(0.008, result.duration / 2) : fadeOut
        return result
    }
}

public struct AudioGainPoint: Sendable {
    public let time: Double
    public let gain: Double
}

public enum VoiceoverMix {
    /// A deterministic envelope shared by preview and export. Nearby speech
    /// merges naturally through the minimum duck gain; overlap never pumps up.
    public static func musicEnvelope(duration: Double, volume: Double, fadeIn: Double, fadeOut: Double,
                                     voiceovers: [VoiceoverClip], duckLevel: Double?) -> [AudioGainPoint] {
        guard duration > 0 else { return [] }
        var fi = min(max(0, fadeIn), duration), fo = min(max(0, fadeOut), duration)
        if fi + fo > duration { let scale = duration / (fi + fo); fi *= scale; fo *= scale }
        let voices = voiceovers.filter { $0.isEnabled && $0.volume > 0 && $0.timelineStart < duration }
        let duck = (duckLevel ?? 1).clamped(to: 0...1)
        let attack = 0.16, release = 0.3
        var times = [0.0, fi, max(fi, duration - fo), duration]
        if duck < 1 {
            for voice in voices {
                times += [max(0, voice.timelineStart - attack), voice.timelineStart,
                          min(duration, voice.timelineEnd), min(duration, voice.timelineEnd + release)]
            }
        }
        times = Set(times.filter { $0 >= 0 && $0 <= duration }).sorted()
        func gain(_ time: Double) -> Double {
            let base = min(fi > 0 ? min(1, time / fi) : 1,
                           fo > 0 ? min(1, (duration - time) / fo) : 1)
            var speech = 1.0
            if duck < 1 {
                for v in voices {
                    let amount: Double
                    if time < v.timelineStart { amount = (time - (v.timelineStart - attack)) / attack }
                    else if time <= v.timelineEnd { amount = 1 }
                    else { amount = 1 - (time - v.timelineEnd) / release }
                    speech = min(speech, 1 - (1 - duck) * amount.clamped(to: 0...1))
                }
            }
            return max(0, volume * base * speech)
        }
        var result: [AudioGainPoint] = []
        for (a, b) in zip(times, times.dropFirst()) {
            // Flat spans need one ramp only. Subdivide overlapping fades and
            // overlapping duck ramps for an accurate piecewise-linear mix.
            let mid = (a + b) / 2
            let nonlinear = abs(gain(mid) - (gain(a) + gain(b)) / 2) > 0.0001
            let count = nonlinear ? max(1, Int(ceil((b - a) / 0.04))) : 1
            for index in 0..<count {
                let time = a + (b - a) * Double(index) / Double(count)
                result.append(.init(time: time, gain: gain(time)))
            }
        }
        result.append(.init(time: duration, gain: gain(duration)))
        return result
    }
}
