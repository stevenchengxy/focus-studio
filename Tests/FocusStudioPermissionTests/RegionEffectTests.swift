import Foundation
import FocusStudioCore

func regionEffectFailures() -> [String] {
    var failures: [String] = []
    func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { failures.append("Local highlight: " + message) }
    }
    func rejects(_ effect: RegionEffect, project: RecordingProject) -> Bool {
        do { try RegionEffectValidator.validate(effect, in: project); return false }
        catch { return true }
    }
    do {
        var project = RecordingProject(title: "Regions", sourceVideoPath: "/tmp/regions.mov",
            duration: 10, sourceWidth: 1920, sourceHeight: 1080)
        let effect = RegionEffect(clipID: project.id, sourceStart: 2, sourceEnd: 8,
            rect: .init(x: 0.2, y: 0.3, width: 0.4, height: 0.25), preset: .lift)
        try RegionEffectValidator.validate(effect, in: project)
        project.regionEffects = [effect]
        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(RecordingProject.self, from: encoded)
        expect(decoded.regionEffects == project.regionEffects, "selection and source timing must persist exactly")
        var legacyJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacyJSON.removeValue(forKey: "regionEffects")
        let legacy = try JSONDecoder().decode(RecordingProject.self,
            from: JSONSerialization.data(withJSONObject: legacyJSON))
        expect(legacy.regionEffects == nil, "old recordings must decode without an effects migration")

        let original = try RegionEffectTimeline(project: project)
        expect(original.placements.count == 1, "implicit recording clip resolves")
        let p = original.placements[0]
        expect(p.start == 2 && p.end == 8, "source times map to the implicit timeline")
        expect(p.progress(at: 2) == 0 && p.progress(at: 8) == 0,
               "first and final boundary must be the untouched source")
        expect(p.progress(at: 4) == 1 && p.progress(at: 2.1) > 0 && p.progress(at: 2.1) < 1,
               "entrance must ease into a steady reading hold")
        expect(original.active(at: 8) == nil, "effect never leaks across a hard boundary")

        var invalid = effect
        invalid.rect.x = .nan
        expect(rejects(invalid, project: project), "NaN selection must be rejected")
        invalid = effect; invalid.rect.width = 0.95
        expect(rejects(invalid, project: project), "selection outside source must be rejected")
        invalid = effect; invalid.scale = .infinity
        expect(rejects(invalid, project: project), "infinite transform must be rejected")
        invalid = effect; invalid.sourceEnd = 11
        expect(rejects(invalid, project: project), "range beyond source must be rejected")
        invalid = effect; invalid.clipID = UUID()
        expect(rejects(invalid, project: project), "stale clip must be rejected")
        invalid = effect; invalid.id = UUID(); invalid.sourceStart = 7
        expect(rejects(invalid, project: project), "two active overlapping highlights must be rejected")
        invalid.isEnabled = false
        expect(!rejects(invalid, project: project), "disabled alternatives may overlap")
        invalid = effect; invalid.id = UUID(); invalid.sourceStart = 8; invalid.sourceEnd = 9
        expect(!rejects(invalid, project: project), "adjacent highlights may share a boundary")

        let timeline = try DemoVideoTimeline(project: project)
        let trimmed = try timeline.applying(.trim(clipID: project.id, sourceStart: 3, sourceEnd: 7), to: project)
        let trimPlacement = try RegionEffectTimeline(project: trimmed).placements[0]
        expect(trimPlacement.start == 0 && trimPlacement.end == 4, "trim clips the visible span")
        expect(trimmed.regionEffects == [effect], "trim must retain hidden selection timing for restoration")
        let restored = try DemoVideoTimeline(project: trimmed).applying(
            .trim(clipID: project.id, sourceStart: 0, sourceEnd: 10), to: trimmed)
        let restoredEffects = try RegionEffectTimeline(project: restored)
        expect(restoredEffects.placements == original.placements,
               "lengthening a trimmed clip must restore the highlight")

        let split = try timeline.applying(.split(clipID: project.id, at: 5), to: project)
        let splitEffects = split.regionEffects ?? []
        expect(splitEffects.count == 2 && Set(splitEffects.map(\.id)).count == 2,
               "split makes two unique source-bound effects")
        expect(splitEffects.map(\.sourceStart) == [2, 5] && splitEffects.map(\.sourceEnd) == [5, 8],
               "split must separate selection ranges at the source cut")
        var hiddenBefore = project
        hiddenBefore.regionEffects?[0].sourceStart = 1
        hiddenBefore.regionEffects?[0].sourceEnd = 3
        let hide = try DemoVideoTimeline(project: hiddenBefore).applying(
            .trim(clipID: project.id, sourceStart: 5, sourceEnd: 10), to: hiddenBefore)
        let hideSplit = try DemoVideoTimeline(project: hide).applying(
            .split(clipID: project.id, at: 2), to: hide)
        expect(hideSplit.regionEffects?.first?.sourceStart == 1 && hideSplit.regionEffects?.first?.sourceEnd == 3,
               "splitting a trimmed clip must retain a hidden effect on the correct side")
        let revealed = try DemoVideoTimeline(project: hideSplit).applying(
            .trim(clipID: project.id, sourceStart: 0, sourceEnd: 7), to: hideSplit)
        let revealedEffects = try RegionEffectTimeline(project: revealed).placements
        expect(revealedEffects.count == 1 && revealedEffects.first?.start == 1 && revealedEffects.first?.end == 3,
               "trim, split, then restore must recover hidden highlights")
        var small = project
        small.regionEffects?[0].sourceStart = 4.96; small.regionEffects?[0].sourceEnd = 5.08
        let smallSplit = try timeline.applying(.split(clipID: project.id, at: 5), to: small)
        let smallEffects = try RegionEffectTimeline(project: smallSplit).placements
        expect(smallEffects.count == 2 && abs(smallEffects.reduce(0) { $0 + $1.duration } - 0.12) < 0.000_001,
               "splitting must not drop sub-0.1-second tails of an authored effect")
        var full = project
        full.regionEffects = (0..<128).map { _ in
            var copy = effect; copy.id = UUID(); copy.isEnabled = false; return copy
        }
        do {
            _ = try timeline.applying(.split(clipID: project.id, at: 5), to: full)
            expect(false, "split must refuse an effect count exceeding the renderer budget")
        } catch DemoVideoTimelineError.invalidOperation { }
        let splitTimeline = try DemoVideoTimeline(project: split)
        let secondID = splitTimeline.clips[1].id
        let moved = try splitTimeline.applying(.move(clipID: secondID, toIndex: 0), to: split)
        let movedEffects = try RegionEffectTimeline(project: moved).placements
        expect(movedEffects.map(\.start) == [0, 7] && movedEffects.map(\.end) == [3, 10],
               "highlights follow their source clips when reordered")
        let deleted = try DemoVideoTimeline(project: moved).applying(.delete(clipID: secondID), to: moved)
        expect(deleted.regionEffects?.count == 1 && deleted.regionEffects?.first?.clipID == project.id,
               "deleting a clip removes only its highlights")

        // A source may be inserted repeatedly. Keep edits must not attach an
        // effect to the wrong copy merely because its source ranges match.
        let keep = try DemoTimelineEdit(keepRanges: [.init(start: 1, end: 4), .init(start: 6, end: 9)],
                                       sourceDuration: project.duration)
        let cutTimeline = try timeline.clipped(to: keep)
        let kept = RegionEffectRemapping.clipped([effect], from: timeline, keeping: keep, to: cutTimeline)
        expect(kept.count == 2 && kept.map(\.clipID) == cutTimeline.clips.map(\.id),
               "keep ranges preserve clip lineage")
        expect(kept.map(\.sourceStart) == [2, 6] && kept.map(\.sourceEnd) == [4, 8],
               "non-destructive keeps retain original source seconds")
        let rawCut = keep.remap(project, sourceVideoPath: "/tmp/new.mov")
        expect(rawCut.regionEffects?.map(\.sourceStart) == [1, 3]
               && rawCut.regionEffects?.map(\.sourceEnd) == [3, 5]
               && rawCut.regionEffects?.allSatisfy { $0.clipID == rawCut.id } == true,
               "materialized raw cuts must rebase effect times and implicit clip ID")

        var fork = project
        fork.materializeRegionEffectClipIdentity()
        fork.id = UUID()
        let forkEffects = try RegionEffectTimeline(project: fork)
        expect(forkEffects.placements.count == 1,
               "forking a project must not orphan an implicit clip's highlights")

        var hidden = trimmed
        hidden.regionEffects?[0].sourceStart = 8; hidden.regionEffects?[0].sourceEnd = 9
        let hiddenEffects = try RegionEffectTimeline(project: hidden)
        expect(hiddenEffects.placements.isEmpty,
               "a fully trimmed highlight remains saved without affecting other frames")
        var disabled = project; disabled.regionEffects?[0].isEnabled = false
        let disabledEffects = try RegionEffectTimeline(project: disabled)
        expect(disabledEffects.active(at: 4) == nil,
               "disabled highlights do not render")
    } catch { failures.append("Local highlight tests failed: \(error)") }
    return failures
}
