@preconcurrency import AVFoundation
import CoreGraphics
import FocusStudioCore
import Foundation

/// Deterministic codec and rendered-pixel checks; uses only the synthetic
/// source created by the E2E runner and never opens a user's project.
enum CursorVisibilityValidation {
    private struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static func run(project source: RecordingProject, outputDirectory: URL) async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure(description: "Cursor visibility: " + message) }
        }

        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectSettings())) as! [String: Any]
        legacyJSON.removeValue(forKey: "showCursor")
        let legacy = try JSONDecoder().decode(ProjectSettings.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        try check(legacy.showCursor == nil && legacy.resolvedShowCursor, "older project settings must keep the pointer visible")
        for flag in [false, true] {
            var settings = legacy
            settings.showCursor = flag
            let restored = try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(settings))
            try check(restored.showCursor == flag && restored.resolvedShowCursor == flag, "explicit visibility must survive JSON round trips")
        }

        var visible = source
        visible.settings.showCursor = true
        visible.settings.hideIdleCursor = false
        visible.settings.cursorScale = 2.5
        visible.settings.motionBlur = 0
        // Keep the synthetic pointer inside both test zooms; otherwise a
        // roaming fixture can move it off screen and falsely fail visibility.
        visible.cursorSamples = [
            CursorSample(time: 0, x: 0.5, y: 0.5),
            CursorSample(time: 0.8, x: 0.5, y: 0.5, cursorKind: .iBeam),
            CursorSample(time: 1.4, x: 0.5, y: 0.5, cursorKind: .iBeam),
            CursorSample(time: source.duration, x: 0.5, y: 0.5),
        ]
        let visibleGenerator = generator(try await ProjectVideoRenderer.prepare(project: visible))
        var implicit = visible
        implicit.settings.showCursor = nil
        let implicitGenerator = generator(try await ProjectVideoRenderer.prepare(project: implicit))
        var hidden = visible
        hidden.settings.showCursor = false
        // Persist/reopen before rendering, just like an editor setting change.
        hidden = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(hidden))
        try check(hidden.cursorSamples == visible.cursorSamples && hidden.clickEvents == source.clickEvents && hidden.zoomSegments == source.zoomSegments,
                  "hiding the pointer must not discard captured input or editable zooms")
        let hiddenGenerator = generator(try await ProjectVideoRenderer.prepare(project: hidden))
        var noPointerMetadata = hidden
        noPointerMetadata.cursorSamples = []
        let noPointerGenerator = generator(try await ProjectVideoRenderer.prepare(project: noPointerMetadata))
        var restoredVisible = hidden
        restoredVisible.settings.showCursor = true
        let restoredGenerator = generator(try await ProjectVideoRenderer.prepare(project: restoredVisible))

        // The synthetic project includes arrow and I-beam samples.
        var pointerChangedPixels = [Int]()
        for seconds in [0.25, 1.0] {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let shown = try await frame(visibleGenerator, at: time)
            let old = try await frame(implicitGenerator, at: time)
            let absent = try await frame(hiddenGenerator, at: time)
            let empty = try await frame(noPointerGenerator, at: time)
            let shownAgain = try await frame(restoredGenerator, at: time)
            let changed = difference(shown, absent)
            try check(changed.changedPixels > 50, "pointer toggle must visibly change arrow/I-beam pixels at \(seconds)s")
            try check(difference(shown, old).mean < 0.001, "missing setting must preserve the old rendered appearance")
            try check(difference(absent, empty).mean < 0.001, "hidden pointer must render exactly like absent cursor metadata")
            try check(difference(shown, shownAgain).mean < 0.001, "turning the pointer back on must restore its rendered appearance")
            pointerChangedPixels.append(changed.changedPixels)
        }

        var noFeedback = hidden
        noFeedback.settings.showClickRing = false
        let noFeedbackGenerator = generator(try await ProjectVideoRenderer.prepare(project: noFeedback))
        let clickTime = CMTime(seconds: 0.85, preferredTimescale: 600)
        let clickFrame = try await frame(hiddenGenerator, at: clickTime)
        let noClickFrame = try await frame(noFeedbackGenerator, at: clickTime)
        let clickPixels = difference(clickFrame, noClickFrame).changedPixels
        try check(clickPixels > 30, "click feedback must remain visible while the pointer is hidden")

        var noZoom = hidden
        noZoom.zoomSegments = []
        let noZoomGenerator = generator(try await ProjectVideoRenderer.prepare(project: noZoom))
        let zoomTime = CMTime(seconds: 1, preferredTimescale: 600)
        let zoomFrame = try await frame(hiddenGenerator, at: zoomTime)
        let noZoomFrame = try await frame(noZoomGenerator, at: zoomTime)
        let zoomDifference = difference(zoomFrame, noZoomFrame).mean
        try check(zoomDifference > 4, "zoom must remain active while the pointer is hidden")

        let exportURL = outputDirectory.appendingPathComponent("focus-studio-hidden-cursor.mp4")
        _ = try await ProjectVideoRenderer.export(project: hidden, to: exportURL)
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: exportURL))
        exported.requestedTimeToleranceBefore = .zero
        exported.requestedTimeToleranceAfter = .zero
        var exportDifference = 0.0
        for seconds in [0.25, 0.85, 1.0, 1.7] {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let preview = try await frame(hiddenGenerator, at: time)
            let encoded = try await frame(exported, at: time)
            let delta = difference(preview, encoded).mean
            try check(delta < 3, "preview and exported hidden-cursor frame diverged at \(seconds)s")
            exportDifference = max(exportDifference, delta)
        }
        let report: [String: Any] = [
            "status": "PASS", "legacyDefaultVisible": true,
            "pointerChangedPixels": pointerChangedPixels,
            "hiddenPointerClickFeedbackPixels": clickPixels,
            "hiddenPointerZoomDifference": zoomDifference,
            "maximumPreviewExportDifference": exportDifference,
            "outputPath": exportURL.path,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDirectory.appendingPathComponent("cursor-visibility-validation.json"), options: .atomic)
        print("CursorVisibilityValidation: PASS (legacy codec, editable visibility, arrow/I-beam, independent click feedback/zoom, preview/export)")
    }

    private static func generator(_ prepared: PreparedProjectVideo) -> AVAssetImageGenerator {
        let result = AVAssetImageGenerator(asset: prepared.asset)
        result.videoComposition = prepared.videoComposition
        result.appliesPreferredTrackTransform = true
        result.requestedTimeToleranceBefore = .zero
        result.requestedTimeToleranceAfter = .zero
        return result
    }

    private static func frame(_ generator: AVAssetImageGenerator, at time: CMTime) async throws -> CGImage {
        try await generator.image(at: time).image
    }

    private static func difference(_ lhs: CGImage, _ rhs: CGImage) -> (mean: Double, changedPixels: Int) {
        let width = lhs.width, height = lhs.height
        func pixels(_ image: CGImage) -> [UInt8] {
            var output = [UInt8](repeating: 0, count: width * height * 4)
            output.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return output
        }
        let a = pixels(lhs), b = pixels(rhs)
        var total = 0, changed = 0
        for index in 0..<(width * height) {
            let offset = index * 4
            let r = abs(Int(a[offset]) - Int(b[offset]))
            let g = abs(Int(a[offset + 1]) - Int(b[offset + 1]))
            let blue = abs(Int(a[offset + 2]) - Int(b[offset + 2]))
            total += r + g + blue
            if max(r, g, blue) >= 24 { changed += 1 }
        }
        return (Double(total) / Double(width * height * 3), changed)
    }
}
