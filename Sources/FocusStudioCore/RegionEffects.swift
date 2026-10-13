import Foundation

/// Coordinates in the untrimmed source image, with a top-left origin. These
/// survive changes to output aspect ratio, framing and the camera transform.
public struct NormalizedRegionRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0 && y >= 0 && width >= 0.01 && height >= 0.01
            && x + width <= 1.000_001 && y + height <= 1.000_001
    }
}

public enum RegionEffectPreset: String, Codable, CaseIterable, Hashable, Sendable {
    case spotlight, lift, tilt
}

public enum RegionEffectBackground: String, Codable, CaseIterable, Hashable, Sendable {
    case dim, blur, none
}

/// A fixed rectangular selection, not an object tracker. Source times and
/// clip identity prevent edits to earlier footage from changing its target.
public struct RegionEffect: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var clipID: UUID
    public var sourceStart: Double
    public var sourceEnd: Double
    public var rect: NormalizedRegionRect
    public var preset: RegionEffectPreset
    public var background: RegionEffectBackground
    public var scale: Double
    public var intensity: Double
    public var easeIn: Double
    public var easeOut: Double
    public var isEnabled: Bool

    public init(id: UUID = UUID(), clipID: UUID, sourceStart: Double, sourceEnd: Double,
                rect: NormalizedRegionRect, preset: RegionEffectPreset = .spotlight,
                background: RegionEffectBackground = .dim, scale: Double = 1.35,
                intensity: Double = 0.55, easeIn: Double = 0.35, easeOut: Double = 0.35,
                isEnabled: Bool = true) {
        self.id = id; self.clipID = clipID
        self.sourceStart = sourceStart; self.sourceEnd = sourceEnd; self.rect = rect
        self.preset = preset; self.background = background; self.scale = scale
        self.intensity = intensity; self.easeIn = easeIn; self.easeOut = easeOut
        self.isEnabled = isEnabled
    }
}

public struct RegionEffectPlacement: Hashable, Sendable {
    public let effect: RegionEffect
    public let start: Double
    public let end: Double
    public let clip: DemoVideoClip
    public var duration: Double { end - start }

    /// A smooth entrance, readable hold and return. Short visible spans scale
    /// the ramps together; hard clip boundaries never leak a selection.
    public func progress(at seconds: Double) -> Double {
        guard seconds.isFinite, seconds > start, seconds < end else { return 0 }
        let total = effect.easeIn + effect.easeOut
        let factor = total > duration ? duration / total : 1
        let entering = effect.easeIn * factor
        let leaving = effect.easeOut * factor
        func smooth(_ t: Double) -> Double {
            let x = min(1, max(0, t))
            return x * x * x * (x * (x * 6 - 15) + 10)
        }
        return min(entering > 0 ? smooth((seconds - start) / entering) : 1,
                   leaving > 0 ? smooth((end - seconds) / leaving) : 1)
    }
}

public enum RegionEffectError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public enum RegionEffectValidator {
    public static func validateParameters(_ effect: RegionEffect) throws {
        guard effect.rect.isValid else {
            throw RegionEffectError.invalid("Select a rectangle inside the source frame (at least 1% wide and high).")
        }
        guard effect.sourceStart.isFinite, effect.sourceEnd.isFinite,
              effect.sourceStart >= 0, effect.sourceEnd - effect.sourceStart > 0.000_001 else {
            // Authored tools require 0.1 seconds, but splitting a valid effect
            // may leave a shorter tail that still owns real source frames.
            throw RegionEffectError.invalid("A local highlight needs a positive source duration.")
        }
        guard effect.scale.isFinite, (1...3).contains(effect.scale),
              effect.intensity.isFinite, (0...1).contains(effect.intensity),
              effect.easeIn.isFinite, (0...5).contains(effect.easeIn),
              effect.easeOut.isFinite, (0...5).contains(effect.easeOut) else {
            throw RegionEffectError.invalid("Use scale 1–3, intensity 0–1, and entrance/exit durations 0–5 seconds.")
        }
    }

    public static func validate(_ effect: RegionEffect, in project: RecordingProject,
                                excludingID: UUID? = nil) throws {
        try validateParameters(effect)
        let timeline = try DemoVideoTimeline(project: project)
        guard let clip = timeline.clips.first(where: { $0.id == effect.clipID }) else {
            throw RegionEffectError.invalid("The selected clip no longer exists. Refresh the timeline.")
        }
        let bounds = timeline.sourceBounds(for: clip)
        guard effect.sourceStart >= bounds.lowerBound,
              effect.sourceEnd <= bounds.upperBound + 0.000_001 else {
            throw RegionEffectError.invalid("The highlight must stay inside its source media.")
        }
        let other = (project.regionEffects ?? []).filter { $0.id != (excludingID ?? effect.id) }
        guard other.count < 128 else { throw RegionEffectError.invalid("A project supports up to 128 local highlights.") }
        // Keep the first version predictable: one focus at a time. Compare the
        // complete source ranges so restoring a trim cannot uncover a clash.
        if effect.isEnabled, other.contains(where: {
            $0.isEnabled && $0.clipID == effect.clipID
                && min($0.sourceEnd, effect.sourceEnd) - max($0.sourceStart, effect.sourceStart) > 0.000_001
        }) {
            throw RegionEffectError.invalid("Local highlights cannot overlap. Shorten or move the other highlight first.")
        }
    }
}

public struct RegionEffectTimeline: Sendable {
    public let placements: [RegionEffectPlacement]

    public init(project: RecordingProject) throws {
        let timeline = try DemoVideoTimeline(project: project)
        var seen = Set<UUID>()
        placements = (project.regionEffects ?? []).prefix(128).compactMap { effect in
            guard seen.insert(effect.id).inserted,
                  (try? RegionEffectValidator.validateParameters(effect)) != nil,
                  let placement = timeline.placements.first(where: { $0.clip.id == effect.clipID }) else { return nil }
            let lower = max(effect.sourceStart, placement.clip.sourceStart)
            let upper = min(effect.sourceEnd, placement.clip.sourceEnd)
            guard upper > lower else { return nil }
            return RegionEffectPlacement(effect: effect,
                start: placement.start + lower - placement.clip.sourceStart,
                end: placement.start + upper - placement.clip.sourceStart, clip: placement.clip)
        }.sorted { $0.start == $1.start ? $0.effect.id.uuidString < $1.effect.id.uuidString : $0.start < $1.start }
    }

    public func active(at seconds: Double) -> RegionEffectPlacement? {
        placements.first { $0.effect.isEnabled && seconds >= $0.start && seconds < $0.end }
    }
}

public enum RegionEffectRemapping {
    /// Retain exact clip lineage when one keep-range edit makes multiple
    /// pieces of a source clip. Media identity alone is ambiguous when the
    /// same asset has been inserted more than once.
    public static func clipped(_ effects: [RegionEffect], from original: DemoVideoTimeline,
                               keeping edit: DemoTimelineEdit, to clipped: DemoVideoTimeline) -> [RegionEffect] {
        var result: [RegionEffect] = []
        var usedIDs = Set<UUID>()
        var pieceIndex = 0
        for range in edit.ranges {
            for old in original.placements {
                let lower = max(range.start, old.start), upper = min(range.end, old.end)
                guard upper - lower > 0.000_001 else { continue }
                guard clipped.clips.indices.contains(pieceIndex) else { return result }
                let clip = clipped.clips[pieceIndex]
                pieceIndex += 1
                for effect in effects where effect.clipID == old.clip.id {
                    let start = max(effect.sourceStart, clip.sourceStart)
                    let end = min(effect.sourceEnd, clip.sourceEnd)
                    guard end - start > 0.000_001 else { continue }
                    var copy = effect
                    if !usedIDs.insert(copy.id).inserted { copy.id = UUID() }
                    copy.clipID = clip.id
                    copy.sourceStart = start; copy.sourceEnd = end
                    result.append(copy)
                }
            }
        }
        return result
    }
}

extension RecordingProject {
    /// Call before replacing a project's identity during a working-copy fork.
    /// Otherwise an implicit clip would change ID and orphan its effects.
    public mutating func materializeRegionEffectClipIdentity() {
        guard videoClips == nil, !(regionEffects ?? []).isEmpty else { return }
        let sourceDuration = videoSourceDuration ?? duration
        videoClips = [DemoVideoClip(id: id, sourceStart: 0, sourceEnd: sourceDuration)]
        videoSourceDuration = sourceDuration
    }
}
