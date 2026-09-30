import AppKit
@preconcurrency import AVFoundation
import FocusStudioCore
import Foundation

extension AIAssistantTests {
    @MainActor
    static func videoTimelineRendering(root: URL) async throws {
        let sourceURL = root.appendingPathComponent("timeline-original.mp4")
        try await SolidClipWriter.write(to: sourceURL, width: 320, height: 180,
                                        duration: 3, color: (0.15, 0.45, 0.85), audio: true)
        let sourceBytes = try Data(contentsOf: sourceURL)
        var project = RecordingProject(title: "Timeline", sourceVideoPath: sourceURL.path,
                                       duration: 3, sourceWidth: 320, sourceHeight: 180,
                                       clickEvents: [
                                        .init(time: 0.5, x: 0.2, y: 0.5, button: .left),
                                        .init(time: 1.5, x: 0.5, y: 0.5, button: .left),
                                        .init(time: 2.5, x: 0.8, y: 0.5, button: .left)
                                       ])
        let originalID = project.id
        let first = try DemoVideoTimeline(project: project)
        check(first.clips.count == 1 && first.clips[0].id == originalID,
              "legacy projects expose a stable implicit full-length clip")
        project = try first.applying(.split(clipID: originalID, at: 1), to: project)
        let secondID = try DemoVideoTimeline(project: project).clips[1].id
        project = try DemoVideoTimeline(project: project).applying(.split(clipID: secondID, at: 2), to: project)
        let thirdID = try DemoVideoTimeline(project: project).clips[2].id
        project = try DemoVideoTimeline(project: project).applying(.move(clipID: thirdID, toIndex: 0), to: project)
        let moved = try DemoVideoTimeline(project: project)
        check(moved.clips.map(\.id) == [thirdID, originalID, secondID]
                && moved.placements.map(\.start) == [0, 1, 2],
              "split and move preserve clip identity and calculate cumulative time")
        check(project.resolvedClickEvents.map(\.time) == [0.5, 1.5, 2.5],
              "interaction events follow the video clips after reordering")
        check(project.resolvedClickEvents.map(\.x) == [0.8, 0.2, 0.5],
              "interaction events stay attached to their original visual content")
        check(project.editCutTimes == [1],
              "reordering marks the real content jump without inventing a cut between continuous halves")
        project = try moved.applying(.trim(clipID: thirdID, sourceStart: 2.2, sourceEnd: 3), to: project)
        let expectedTrimmedClickTimes = [0.3, 1.3, 2.3]
        let actualTrimmedClickTimes = project.resolvedClickEvents.map(\.time)
        check(abs(project.duration - 2.8) < 0.000_001
                && actualTrimmedClickTimes.count == expectedTrimmedClickTimes.count
                && zip(actualTrimmedClickTimes, expectedTrimmedClickTimes).allSatisfy { abs($0 - $1) < 0.000_001 },
              "trimming remaps interaction times without changing the source: \(actualTrimmedClickTimes)")
        project = try DemoVideoTimeline(project: project).applying(
            .setTransition(fromClipID: thirdID, preset: .fadeToBlack, duration: 0.4), to: project)
        project = try DemoVideoTimeline(project: project).applying(.setClipAudio(clipID: thirdID, volume: 0), to: project)
        let transitionTimeline = try DemoVideoTimeline(project: project)
        check(transitionTimeline.transition(after: thirdID)?.preset == .fadeToBlack,
              "transition edits persist on the outgoing clip")
        let encoded = try JSONEncoder().encode(project)
        let restored = try JSONDecoder().decode(RecordingProject.self, from: encoded)
        let restoredTimeline = try DemoVideoTimeline(project: restored)
        check(restoredTimeline.clips.first?.sourceAudioVolume == 0,
              "timeline edits survive a project JSON round trip")
        let legacyTransitionJSON = Data("""
            {"fromClipID":"\(thirdID.uuidString)","preset":"fadeToBlack","duration":0.4}
            """.utf8)
        let legacyTransition = try JSONDecoder().decode(DemoVideoTransition.self, from: legacyTransitionJSON)
        check(legacyTransition.outgoingDuration == nil && legacyTransition.incomingDuration == nil
                && legacyTransition.resolvedOutgoingDuration == 0.2
                && legacyTransition.resolvedIncomingDuration == 0.2
                && legacyTransition.resolvedOutgoingCurve == .linear
                && legacyTransition.resolvedIncomingCurve == .linear,
              "a transition saved before in/out controls still decodes as an even linear effect")
        let shaped = try restoredTimeline.applying(
            .setTransitionParameters(fromClipID: thirdID, preset: .fadeToBlack,
                                     outgoingDuration: 0.1, incomingDuration: 0.3,
                                     outgoingCurve: .easeIn, incomingCurve: .easeOut), to: restored)
        let shapedRoundTrip = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(shaped))
        let shapedTimeline = try DemoVideoTimeline(project: shapedRoundTrip)
        let shapedTransition = shapedTimeline.transition(after: thirdID)
        check(shapedTransition?.duration == 0.4
                && shapedTransition?.resolvedOutgoingDuration == 0.1
                && shapedTransition?.resolvedIncomingDuration == 0.3
                && shapedTransition?.resolvedOutgoingCurve == .easeIn
                && shapedTransition?.resolvedIncomingCurve == .easeOut,
              "different exit/entry times and visual curves survive a full project JSON round trip")
        check(DemoTransitionCurve.easeIn.value(at: 0.5) == 0.25
                && DemoTransitionCurve.easeOut.value(at: 0.5) == 0.75
                && DemoTransitionCurve.smooth.value(at: 0.5) == 0.5,
              "transition curves shape the two visual halves independently")
        let keptEffect = try shapedTimeline.clipped(to: DemoTimelineEdit(
            keepRanges: [.init(start: 0, end: 1.3)], sourceDuration: shapedTimeline.duration))
        check(keptEffect.transition(after: thirdID)?.resolvedOutgoingDuration == 0.1
                && keptEffect.transition(after: thirdID)?.resolvedIncomingDuration == 0.3
                && keptEffect.transition(after: thirdID)?.resolvedIncomingCurve == .easeOut,
              "a full join preserved by a keep-range cut retains its asymmetric effect")
        let cutEffect = try shapedTimeline.clipped(to: DemoTimelineEdit(
            keepRanges: [.init(start: 0, end: 0.8), .init(start: 0.9, end: 1.3)],
            sourceDuration: shapedTimeline.duration))
        check(cutEffect.transition(after: thirdID)?.preset == .cut,
              "a keep-range cut through the incoming effect removes that incomplete transition")
        await expectThrows("an exit cannot extend beyond its outgoing clip") {
            _ = try restoredTimeline.applying(
                .setTransitionParameters(fromClipID: thirdID, preset: .flash,
                                         outgoingDuration: 0.85, incomingDuration: 0.15,
                                         outgoingCurve: .linear, incomingCurve: .linear), to: restored)
        }
        let longEntry = try restoredTimeline.applying(
            .setTransitionParameters(fromClipID: thirdID, preset: .fadeToBlack,
                                     outgoingDuration: 0.1, incomingDuration: 0.75,
                                     outgoingCurve: .linear, incomingCurve: .linear), to: restored)
        await expectThrows("incoming and outgoing effects cannot overlap inside a middle clip") {
            _ = try DemoVideoTimeline(project: longEntry).applying(
                .setTransitionParameters(fromClipID: originalID, preset: .flash,
                                         outgoingDuration: 0.4, incomingDuration: 0.1,
                                         outgoingCurve: .linear, incomingCurve: .linear), to: longEntry)
        }
        let prepared = try await ProjectVideoRenderer.prepare(project: restored)
        check(abs(prepared.duration - 2.8) < 0.000_001 && prepared.audioMix != nil,
              "preview composes the edited clips and source-audio mix")
        let player = prepared.makePlayerItem()
        check(player.videoComposition != nil && player.audioMix != nil,
              "editor playback receives the same transition and audio mix as export")
        let outputURL = root.appendingPathComponent("timeline-rendered.mp4")
        let result = try await ProjectVideoRenderer.export(project: restored, to: outputURL)
        let asset = AVURLAsset(url: outputURL)
        let actualDuration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        check(result.includesAudio && !audioTracks.isEmpty && abs(actualDuration - 2.8) < 0.07,
              "export preserves source sound and edited duration")
        func audioLevel(start: Double, duration: Double) throws -> Double {
            guard let track = audioTracks.first else { return 0 }
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                           duration: CMTime(seconds: duration, preferredTimescale: 600))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? NSError(domain: "VideoTimelineTests", code: 2) }
            var sum = 0.0
            var count = 0
            while let sample = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var data = [UInt8](repeating: 0, count: length)
                let status = data.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                               destination: bytes.baseAddress!)
                }
                guard status == noErr else { continue }
                data.withUnsafeBytes { bytes in
                    for value in bytes.bindMemory(to: Int16.self) {
                        sum += Double(abs(Int(value)))
                        count += 1
                    }
                }
            }
            return count == 0 ? 0 : sum / Double(count)
        }
        let muted = try audioLevel(start: 0.15, duration: 0.3)
        let audible = try audioLevel(start: 1.2, duration: 0.3)
        check(audible > 100 && muted < audible * 0.05,
              "per-clip mute changes the actual exported source sound")
        let preservedBytes = try Data(contentsOf: sourceURL)
        check(preservedBytes == sourceBytes,
              "the source movie remains byte-for-byte unchanged")

        func centerBrightness(_ targetAsset: AVAsset, _ seconds: Double) throws -> Double {
            let generator = AVAssetImageGenerator(asset: targetAsset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                              bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw NSError(domain: "VideoTimelineTests", code: 1)
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])
        }
        let normal = try centerBrightness(asset, 0.4)
        let blackout = try centerBrightness(asset, 0.8)
        check(normal > 80 && blackout < normal * 0.3,
              "fade-to-black changes exported pixels at the join")
        let flashProject = try DemoVideoTimeline(project: restored).applying(
            .setTransition(fromClipID: thirdID, preset: .flash, duration: 0.4), to: restored)
        let flashOutput = root.appendingPathComponent("timeline-flash.mp4")
        _ = try await ProjectVideoRenderer.export(project: flashProject, to: flashOutput)
        let flashAsset = AVURLAsset(url: flashOutput)
        let whiteness = try centerBrightness(flashAsset, 0.8)
        check(whiteness > normal * 1.5,
              "flash transition visibly brightens the exported join")
        await expectThrows("cannot delete the only clip") {
            let single = try DemoVideoTimeline(project: RecordingProject(title: "Single", sourceVideoPath: sourceURL.path,
                duration: 3, sourceWidth: 320, sourceHeight: 180))
            _ = try single.applying(.delete(clipID: single.clips[0].id), to: project)
        }
        try await mixedMediaTimelineRendering(root: root)
        try await importedZoomAndOrientation(root: root)
    }

    @MainActor
    private static func mixedMediaTimelineRendering(root: URL) async throws {
        let sourceURL = root.appendingPathComponent("mixed-original.mp4")
        let importedVideoURL = root.appendingPathComponent("mixed-insert.mp4")
        let imageURL = root.appendingPathComponent("mixed-still.png")
        try await SolidClipWriter.write(to: sourceURL, width: 320, height: 180,
                                        duration: 2, color: (0.12, 0.17, 0.9), audio: false)
        try await SolidClipWriter.write(to: importedVideoURL, width: 180, height: 320,
                                        duration: 1.2, color: (0.9, 0.12, 0.13), audio: true)
        let sourceBytes = try Data(contentsOf: sourceURL)
        let imageContext = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        imageContext.setFillColor(CGColor(red: 0.12, green: 0.88, blue: 0.18, alpha: 1))
        imageContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = NSBitmapImageRep(cgImage: imageContext.makeImage()!)
        try image.representation(using: .png, properties: [:])!.write(to: imageURL)

        let imageAsset = DemoMediaAsset(title: "Green still", filePath: imageURL.path,
                                        kind: .image, duration: 0, width: 64, height: 64)
        let videoAsset = DemoMediaAsset(title: "Red product clip", filePath: importedVideoURL.path,
                                        kind: .video, duration: 1.2, width: 180, height: 320)
        var project = RecordingProject(title: "Mixed media", sourceVideoPath: sourceURL.path,
                                       duration: 2, sourceWidth: 320, sourceHeight: 180,
                                       clickEvents: [.init(time: 0.5, x: 0.5, y: 0.5, button: .left)],
                                       mediaAssets: [imageAsset, videoAsset])
        let originalID = project.id
        project = try DemoVideoTimeline(project: project).applying(
            .insertMedia(assetID: imageAsset.id, atIndex: 0, duration: 0.6), to: project)
        let imageClipID = try DemoVideoTimeline(project: project).clips[0].id
        project = try DemoVideoTimeline(project: project).applying(
            .insertMedia(assetID: videoAsset.id, atIndex: 1, duration: 0.8), to: project)
        project = try DemoVideoTimeline(project: project).applying(
            .setImageDuration(clipID: imageClipID, duration: 1), to: project)
        project = try DemoVideoTimeline(project: project).applying(
            .setTransition(fromClipID: imageClipID, preset: .fadeToBlack, duration: 0.2), to: project)
        let videoClipID = try DemoVideoTimeline(project: project).clips[1].id
        project = try DemoVideoTimeline(project: project).applying(
            .split(clipID: videoClipID, at: 1.4), to: project)
        let edited = try DemoVideoTimeline(project: project)
        check(edited.clips.count == 4 && abs(edited.duration - 3.8) < 0.000_001,
              "a still, imported movie and original recording share one persistent timeline")
        check(project.resolvedClickEvents.count == 1
                && abs(project.resolvedClickEvents[0].time - 2.3) < 0.000_001,
              "original recording interactions move with their video after media insertion")
        check(edited.clips[3].id == originalID
                && edited.clips[1].mediaAssetID == videoAsset.id
                && edited.clips[2].mediaAssetID == videoAsset.id,
              "split imported footage retains its media source in both halves")
        let decoded = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(project))
        check(decoded.mediaAssets?.count == 2 && decoded.videoClips?.first?.mediaAssetID == imageAsset.id,
              "project JSON retains all imported media references")

        let prepared = try await ProjectVideoRenderer.prepare(project: decoded)
        let preview = prepared.makePlayerItem()
        check(abs(prepared.duration - 3.8) < 0.000_001
                && preview.videoComposition != nil && preview.audioMix != nil,
              "mixed media preview uses the same composed picture and audio as export")

        let outputURL = root.appendingPathComponent("mixed-rendered.mp4")
        let rendered = try await ProjectVideoRenderer.export(project: decoded, to: outputURL)
        let outputAsset = AVURLAsset(url: outputURL)
        let outputDuration = try await outputAsset.load(.duration).seconds
        check(abs(outputDuration - 3.8) < 0.07 && rendered.includesAudio,
              "mixed timeline exports its full duration with imported-video sound")
        let mixedAudioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
        check(!mixedAudioTracks.isEmpty, "imported video contributes an audio track to the output")
        let imageGenerator = AVAssetImageGenerator(asset: outputAsset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero
        func color(at seconds: Double) throws -> (Double, Double, Double) {
            let frame = try imageGenerator.copyCGImage(
                at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
            let center = CGRect(x: CGFloat(frame.width) / 2 - 1, y: CGFloat(frame.height) / 2 - 1,
                                width: 2, height: 2)
            let sample = frame.cropping(to: center) ?? frame
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
        }
        let stillColor = try color(at: 0.4)
        let joinColor = try color(at: 1.0)
        let videoColor = try color(at: 1.4)
        let recordingColor = try color(at: 2.6)
        check(stillColor.1 > stillColor.0 * 1.8 && stillColor.1 > stillColor.2 * 1.8,
              "the still image's green pixels render instead of the placeholder recording")
        check(videoColor.0 > videoColor.1 * 1.8 && videoColor.0 > videoColor.2 * 1.8,
              "the imported red video renders at its clip position")
        check(recordingColor.2 > recordingColor.0 * 1.8 && recordingColor.2 > recordingColor.1 * 1.8,
              "the immutable blue recording resumes after imported media")
        check(joinColor.0 + joinColor.1 + joinColor.2 < stillColor.0 + stillColor.1 + stillColor.2,
              "a fade-to-black works on an image-to-video join")
        let preservedSourceBytes = try Data(contentsOf: sourceURL)
        check(preservedSourceBytes == sourceBytes,
              "mixed edits leave the original capture byte-for-byte unchanged")

        var missing = decoded
        missing.mediaAssets?[0].filePath = root.appendingPathComponent("missing.png").path
        await expectThrows("missing imported still is reported before export") {
            _ = try await ProjectVideoRenderer.prepare(project: missing)
        }
    }

    @MainActor
    private static func importedZoomAndOrientation(root: URL) async throws {
        func pixel(_ image: CGImage, x: Double = 0.5, y: Double = 0.5) -> (Double, Double, Double) {
            let px = max(0, min(image.width - 1, Int(Double(image.width) * x)))
            let py = max(0, min(image.height - 1, Int(Double(image.height) * y)))
            let cropped = image.cropping(to: CGRect(x: px, y: py, width: 1, height: 1))!
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return (Double(bytes[0]), Double(bytes[1]), Double(bytes[2]))
        }
        func preview(_ prepared: PreparedProjectVideo, at seconds: Double) throws -> CGImage {
            let generator = AVAssetImageGenerator(asset: prepared.asset)
            generator.videoComposition = prepared.videoComposition
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        }
        func exportFrame(_ project: RecordingProject, to path: URL, at seconds: Double) async throws -> CGImage {
            _ = try await ProjectVideoRenderer.export(project: project, to: path)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: path))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        }

        let squareSource = root.appendingPathComponent("zoom-placeholder.mp4")
        try await SolidClipWriter.write(to: squareSource, width: 96, height: 96,
                                        duration: 1, color: (0.1, 0.1, 0.8), audio: false)
        let imageURL = root.appendingPathComponent("zoom-bands.png")
        let imageContext = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (index, color) in [CGColor(red: 0.95, green: 0.06, blue: 0.05, alpha: 1),
                               CGColor(red: 0.05, green: 0.9, blue: 0.06, alpha: 1),
                               CGColor(red: 0.05, green: 0.08, blue: 0.9, alpha: 1)].enumerated() {
            imageContext.setFillColor(color)
            imageContext.fill(CGRect(x: index * 32, y: 0, width: 32, height: 96))
        }
        try NSBitmapImageRep(cgImage: imageContext.makeImage()!)
            .representation(using: .png, properties: [:])!.write(to: imageURL)
        let still = DemoMediaAsset(title: "Zoom target", filePath: imageURL.path,
                                   kind: .image, duration: 0, width: 96, height: 96)
        var imageProject = RecordingProject(title: "Imported image zoom", sourceVideoPath: squareSource.path,
                                            duration: 1, sourceWidth: 96, sourceHeight: 96,
                                            mediaAssets: [still])
        imageProject.settings.exportWidth = 640
        imageProject = try DemoVideoTimeline(project: imageProject).applying(
            .insertMedia(assetID: still.id, atIndex: 0, duration: 1), to: imageProject)
        let flatImage = pixel(try preview(await ProjectVideoRenderer.prepare(project: imageProject), at: 0.5))
        check(flatImage.1 > flatImage.0 * 2,
              "unzoomed imported image has the green center band")
        imageProject.zoomSegments = [.init(start: 0, end: 1, targetX: 0.22, targetY: 0.5,
                                           scale: 2, kind: .manual, isInstant: true)]
        let imagePreview = pixel(try preview(await ProjectVideoRenderer.prepare(project: imageProject), at: 0.5))
        let imageExport = pixel(try await exportFrame(imageProject,
            to: root.appendingPathComponent("image-zoom.mp4"), at: 0.5))
        check(imagePreview.0 > imagePreview.1 * 2 && imageExport.0 > imageExport.1 * 2,
              "manual zoom on an imported image changes preview and exported pixels")

        let movieSource = root.appendingPathComponent("zoom-imported-video.mp4")
        try await SolidClipWriter.write(to: movieSource, width: 320, height: 180,
                                        duration: 1, color: (0.1, 0.3, 0.8), audio: false,
                                        patterned: true)
        let movie = DemoMediaAsset(title: "Zoom movie", filePath: movieSource.path,
                                   kind: .video, duration: 1, width: 320, height: 180)
        var movieProject = RecordingProject(title: "Imported video zoom", sourceVideoPath: movieSource.path,
                                            duration: 1, sourceWidth: 320, sourceHeight: 180,
                                            mediaAssets: [movie])
        movieProject.settings.exportWidth = 640
        movieProject = try DemoVideoTimeline(project: movieProject).applying(
            .insertMedia(assetID: movie.id, atIndex: 0, duration: 1), to: movieProject)
        let flatMovie = pixel(try preview(await ProjectVideoRenderer.prepare(project: movieProject), at: 0.5))
        check(flatMovie.2 > flatMovie.0 * 2,
              "unzoomed imported video retains its blue center background")
        movieProject.zoomSegments = [.init(start: 0, end: 1, targetX: 0.26, targetY: 0.5,
                                           scale: 2, kind: .manual, isInstant: true)]
        let moviePreview = pixel(try preview(await ProjectVideoRenderer.prepare(project: movieProject), at: 0.5))
        let movieExport = pixel(try await exportFrame(movieProject,
            to: root.appendingPathComponent("video-zoom.mp4"), at: 0.5))
        check(moviePreview.0 > 190 && moviePreview.1 > 190 && moviePreview.2 > 190
                && movieExport.0 > 190 && movieExport.1 > 190 && movieExport.2 > 190,
              "manual zoom on imported video reaches the white target in preview and export")

        let rotatedURL = root.appendingPathComponent("portrait-transform.mp4")
        let encodedAsset = AVURLAsset(url: movieSource)
        let encodedTrack = try await encodedAsset.loadTracks(withMediaType: .video).first!
        let composition = AVMutableComposition()
        let rotatedTrack = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid)!
        try rotatedTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
                                         of: encodedTrack, at: .zero)
        rotatedTrack.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await session.export(to: rotatedURL, as: .mp4)
        let rotatedAsset = AVURLAsset(url: rotatedURL)
        let rotatedInput = try await rotatedAsset.loadTracks(withMediaType: .video).first!
        let natural = try await rotatedInput.load(.naturalSize)
        let preferred = try await rotatedInput.load(.preferredTransform)
        let upright = CGRect(origin: .zero, size: natural).applying(preferred).standardized
        check(natural.width > natural.height && upright.height > upright.width,
              "fixture is a landscape-encoded movie with portrait preferredTransform")

        let portraitSource = root.appendingPathComponent("portrait-placeholder.mp4")
        try await SolidClipWriter.write(to: portraitSource, width: 180, height: 320,
                                        duration: 1, color: (0.1, 0.2, 0.8), audio: false)
        let portrait = DemoMediaAsset(title: "Portrait transform", filePath: rotatedURL.path,
                                      kind: .video, duration: 1, width: 180, height: 320)
        var portraitProject = RecordingProject(title: "Portrait output", sourceVideoPath: portraitSource.path,
                                               duration: 1, sourceWidth: 180, sourceHeight: 320,
                                               mediaAssets: [portrait])
        portraitProject.settings.exportWidth = 360
        portraitProject.settings.aspectRatio = .automatic
        portraitProject = try DemoVideoTimeline(project: portraitProject).applying(
            .insertMedia(assetID: portrait.id, atIndex: 0, duration: 1), to: portraitProject)
        let portraitPrepared = try await ProjectVideoRenderer.prepare(project: portraitProject)
        let portraitPreview = try preview(portraitPrepared, at: 0.5)
        let portraitExportURL = root.appendingPathComponent("portrait-rendered.mp4")
        let portraitExport = try await exportFrame(portraitProject, to: portraitExportURL, at: 0.5)
        check(portraitExport.width == 360 && portraitExport.height == 640,
              "portrait footage exports in a portrait canvas")
        func verticalMarkersAreVisible(_ image: CGImage) -> Bool {
            var redPositions: [Double] = []
            var whitePositions: [Double] = []
            for step in 2...18 {
                let y = Double(step) / 20
                let p = pixel(image, x: 0.5, y: y)
                if p.0 > p.1 * 2 && p.0 > p.2 * 2 { redPositions.append(y) }
                if p.0 > 180 && p.1 > 180 && p.2 > 180 { whitePositions.append(y) }
            }
            return redPositions.contains { red in
                whitePositions.contains { abs($0 - red) > 0.2 }
            }
        }
        check(verticalMarkersAreVisible(portraitPreview)
                && verticalMarkersAreVisible(portraitExport),
              "portrait preferredTransform puts horizontal source markers above and below, in preview and export")

        var orientedRecording = RecordingProject(title: "Oriented source",
            sourceVideoPath: rotatedURL.path, duration: 1, sourceWidth: 180, sourceHeight: 320)
        orientedRecording.settings.exportWidth = 360
        orientedRecording.settings.aspectRatio = .automatic
        let sourcePreview = try preview(await ProjectVideoRenderer.prepare(project: orientedRecording), at: 0.5)
        let sourceExport = try await exportFrame(orientedRecording,
            to: root.appendingPathComponent("oriented-source-rendered.mp4"), at: 0.5)
        check(verticalMarkersAreVisible(sourcePreview) && verticalMarkersAreVisible(sourceExport),
              "orienting imported clips does not break a rotated recording source")
    }
}
