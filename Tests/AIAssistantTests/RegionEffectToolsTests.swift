import FocusStudioCore
import Foundation
import ImageIO

extension AIAssistantTests {
    @MainActor
    static func regionEffectTools(root: URL) async throws {
        var project = makeProject(sourceVideoPath: "/region-fixture.mp4", duration: 10)
        let clip = DemoVideoClip(sourceStart: 4, sourceEnd: 8)
        project.videoSourceDuration = 10; project.videoClips = [clip]; project.duration = 4
        let box = ProjectBox(project), context = makeContext(root: root, box: box)
        let raw: [String: Any] = ["clip_id": clip.id.uuidString, "start": 0.5, "end": 2.5,
                                  "x": 0.2, "y": 0.3, "width": 0.4, "height": 0.2,
                                  "preset": "lift", "background": "blur"]
        let add = try await AddRegionEffectTool().run(arguments: raw, context: context, progress: { _ in })
        let data = try structured(add, "add_region_effect")
        let id = data["effect_id"]!.stringValue!, effect = box.project!.regionEffects!.first!
        check(effect.sourceStart == 4.5 && effect.sourceEnd == 6.5 && effect.clipID == clip.id,
              "output times map to the selected clip's immutable source range")
        check(data["region_effect"]?["start"] == 0.5 && data["region_effect"]?["end"] == 2.5
              && data["region_effect"]?["rect"]?["width"] == 0.4 && data["region_effect"]?["tracking"] == "fixed_rectangle",
              "receipt identifies the actual source rectangle and visible timing")
        check(box.writeCount == 1 && effect.preset == .lift && effect.background == .blur,
              "one atomic edit persists the chosen highlight")
        let updated = try await UpdateRegionEffectTool().run(arguments: ["effect_id": id, "preset": "tilt", "scale": 1.7, "ease_in": 0.6], context: context, progress: { _ in })
        check(updated.data?["effect_id"]?.stringValue == id && box.project!.regionEffects![0].id == effect.id
              && box.project!.regionEffects![0].rect == effect.rect && box.project!.regionEffects![0].preset == .tilt,
              "updating an effect retains its stable ID, source binding and omitted rectangle")

        let before = box.project, writes = box.writeCount
        for invalid: [String: Any] in [["width": 0], ["x": 0.8], ["scale": 3.1], ["intensity": -0.1],
                                       ["ease_out": 6], ["start": -0.1], ["end": 4.1], ["preset": "trackObject"],
                                       ["scale": true], ["x": "0.1"], ["enabled": 1], ["scale": Double.infinity],
                                       ["clip_id": UUID().uuidString, "scale": 2]] {
            await expectThrows("invalid region property is rejected") {
                _ = try await UpdateRegionEffectTool().run(arguments: invalid.merging(["effect_id": id]) { lhs, _ in lhs }, context: context, progress: { _ in })
            }
        }
        await expectThrows("region effects cannot overlap") {
            _ = try await AddRegionEffectTool().run(arguments: raw, context: context, progress: { _ in })
        }
        await expectThrows("unknown clip is not substituted") {
            _ = try await AddRegionEffectTool().run(arguments: raw.merging(["clip_id": UUID().uuidString]) { _, rhs in rhs }, context: context, progress: { _ in })
        }
        check(box.project == before && box.writeCount == writes, "invalid edits never partially mutate the project or undo history")
        let disabled = try await AddRegionEffectTool().run(arguments: raw.merging(["enabled": false]) { _, rhs in rhs }, context: context, progress: { _ in })
        let disabledID = disabled.data!["effect_id"]!.stringValue!
        await expectThrows("enabling an overlapping effect is rejected") {
            _ = try await UpdateRegionEffectTool().run(arguments: ["effect_id": disabledID, "enabled": true], context: context, progress: { _ in })
        }
        _ = try await DeleteRegionEffectTool().run(arguments: ["effect_id": disabledID], context: context, progress: { _ in })

        // Trimming temporarily hides an authored source interval. It remains
        // inspectable and removable; restoring footage must recover the effect.
        box.project!.videoClips![0].sourceStart = 7
        box.project!.duration = 1
        let hidden = AIProjectReport.data(of: box.project!, isOpen: true, assetsDirectory: nil)
        check(hidden["region_effect_count"] == 1 && hidden["region_effects"]?[0]?["id"]?.stringValue == id
              && hidden["region_effects"]?[0]?["start"] == .null
              && hidden["region_effects"]?[0]?["source_start"] == 4.5,
              "trimmed-away effects still report IDs and source ranges, with null visible output ranges")
        _ = try await UpdateRegionEffectTool().run(arguments: ["effect_id": id, "intensity": 0.3], context: context, progress: { _ in })
        check(box.project!.regionEffects![0].sourceStart == 4.5, "non-timing edits preserve hidden source bounds")
        box.project!.videoClips![0].sourceStart = 4; box.project!.duration = 4
        let restored = AIProjectReport.data(of: box.project!, isOpen: true, assetsDirectory: nil)
        check(restored["region_effects"]?[0]?["start"] == 0.5, "restoring clip trim brings the original highlight back")
        let deleted = try await DeleteRegionEffectTool().run(arguments: ["effect_id": id], context: context, progress: { _ in })
        check(deleted.data?["region_effect_count"] == 0 && box.project!.videoClips == project.videoClips,
              "deleting a highlight preserves its clip")

        // Old projects have no explicit track or effects; their stable default
        // clip ID still supports first-use local highlighting.
        let legacy = makeProject(sourceVideoPath: "/legacy.mp4", duration: 4)
        box.project = legacy
        let legacyData = AIProjectReport.data(of: legacy, isOpen: true, assetsDirectory: nil)
        check(legacyData["region_effect_count"] == 0 && legacyData["region_effects"] == [], "legacy report has an empty local-effect list")
        _ = try await AddRegionEffectTool().run(arguments: raw.merging(["clip_id": legacy.id.uuidString]) { _, rhs in rhs }, context: context, progress: { _ in })
        check(box.project!.regionEffects!.first!.sourceStart == 0.5, "legacy implicit clip is addressable without replacing project identity")

        // An interleaved user trim must be resolved from the actual project at
        // the write, not the stale read snapshot.
        box.project = project
        box.afterNextRead = {
            box.project!.videoClips![0].sourceStart = 5
            box.project!.duration = 3
        }
        _ = try await AddRegionEffectTool().run(arguments: raw, context: context, progress: { _ in })
        check(box.project!.regionEffects!.first!.sourceStart == 5.5, "source mapping uses the current clip after concurrent edits")

        try await regionSourceFrameCapture(root: root)
    }

    @MainActor
    static func regionSourceFrameCapture(root: URL) async throws {
        let video = root.appendingPathComponent("region-source.mp4")
        try await SolidClipWriter.write(to: video, width: 320, height: 180, duration: 2, color: (0.2, 0.5, 0.8), audio: false)
        var project = makeProject(sourceVideoPath: video.path, duration: 2)
        let clip = DemoVideoClip(sourceStart: 0.5, sourceEnd: 1.5)
        project.videoClips = [clip]; project.videoSourceDuration = 2; project.duration = 1
        project.settings.padding = 90
        let box = ProjectBox(project), context = makeContext(root: root, box: box)
        let frame = try await CaptureFrameTool().run(arguments: ["time": 0.2, "source_frame": true, "exact_frame": true, "width": 640], context: context, progress: { _ in })
        let data = try structured(frame, "capture source frame")
        check(data["source_frame"] == true && data["clip_id"]?.stringValue == clip.id.uuidString
              && abs((data["source_time_seconds"]?.doubleValue ?? -1) - 0.7) < 0.0001,
              "raw frame lookup maps output time into the chosen source clip")
        check(data["source_width"] == 320 && data["source_height"] == 180
              && data["coordinate_space"] == AIJSONValue(RegionEffectToolSupport.coordinateSpace)
              && data["frame_matches_request"] == true,
              "raw capture reports exact source dimensions and frame provenance")
        check(box.writeCount == 0 && box.project == project && frame.attachments.count == 1,
              "source inspection never changes project look or edits")

        let image = root.appendingPathComponent("region-still.jpg")
        try Pixels.writeJPEG(width: 320, height: 200, color: (0.4, 0.6, 0.2), to: image)
        let media = DemoMediaAsset(title: "Still", filePath: image.path, kind: .image, duration: 0, width: 320, height: 200)
        let imageClip = DemoVideoClip(sourceStart: 0, sourceEnd: 3, mediaAssetID: media.id)
        box.project!.mediaAssets = [media]; box.project!.videoClips = [imageClip]; box.project!.duration = 3
        let still = try await CaptureFrameTool().run(arguments: ["time": 1, "source_frame": true], context: context, progress: { _ in })
        check(still.data?["source_width"] == 320 && still.data?["source_height"] == 200
              && still.data?["clip_id"]?.stringValue == imageClip.id.uuidString,
              "raw frame capture also supports imported still images")
    }
}
