@preconcurrency import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import FocusStudioCapture
import FocusStudioCore
import Foundation
import ImageIO

@main
enum FocusStudioE2E {
    static func main() async {
        do {
            let outputDirectory = try outputDirectory(from: CommandLine.arguments)
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            if CommandLine.arguments.contains("--validate-recorded-project") {
                guard let path = argumentValue(after: "--validate-recorded-project", in: CommandLine.arguments),
                      (path as NSString).isAbsolutePath else {
                    throw E2EError.assertionFailed("--validate-recorded-project requires an absolute project.json path")
                }
                try await validateRecordedProject(at: URL(fileURLWithPath: path), outputDirectory: outputDirectory)
                return
            }
            try runCoreSelfChecks()
            #if DEBUG
            try await runEventMonitorSelfCheck()
            #endif
            if CommandLine.arguments.contains("--capture-smoke") {
                try await runCaptureSmoke(
                    outputDirectory: outputDirectory,
                    requestedWindowTitle: argumentValue(
                        after: "--capture-window",
                        in: CommandLine.arguments
                    )
                )
                return
            }
            let sourceURL = outputDirectory.appendingPathComponent("synthetic-grid.mp4")
            let renderedURL = outputDirectory.appendingPathComponent("focus-studio-e2e.mp4")
            let audioFixtureURL = outputDirectory.appendingPathComponent("synthetic-demo-audio.m4a")
            let audioRenderedURL = outputDirectory.appendingPathComponent("focus-studio-audio-e2e.mp4")
            let backgroundFixtureURL = outputDirectory.appendingPathComponent("synthetic-background.png")
            let backgroundRenderedURL = outputDirectory.appendingPathComponent("focus-studio-background-e2e.mp4")
            let cleanBrowserRenderedURL = outputDirectory.appendingPathComponent("focus-studio-clean-browser-e2e.mp4")
            let clickFeedbackURL = outputDirectory.appendingPathComponent("focus-studio-click-feedback.mp4")
            for url in [
                sourceURL,
                renderedURL,
                audioFixtureURL,
                audioRenderedURL,
                backgroundFixtureURL,
                backgroundRenderedURL,
                cleanBrowserRenderedURL,
                clickFeedbackURL,
            ]
            where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }

            let specification = SyntheticVideoSpecification()
            try await SyntheticGridVideoWriter.write(specification, to: sourceURL)
            try await SyntheticGridVideoWriter.writeToneAudio(
                duration: 0.31,
                sampleRate: specification.audioSampleRate,
                to: audioFixtureURL
            )
            try writeBackgroundFixture(to: backgroundFixtureURL)
            // Exercise the atomic replacement path used after NSSavePanel confirms overwrite.
            try Data("stale-output".utf8).write(to: renderedURL, options: .atomic)
            let project = makeProject(sourceURL: sourceURL, specification: specification)
            let export = try await ProjectVideoRenderer.export(project: project, to: renderedURL)
            let validation = try await validate(
                sourceURL: sourceURL,
                renderedURL: renderedURL,
                expected: export,
                project: project
            )
            try await validateCropRendering(
                project: project,
                outputURL: cleanBrowserRenderedURL
            )
            try await validateClickFeedback(project: project, outputURL: clickFeedbackURL)
            try await CursorVisibilityValidation.run(project: project, outputDirectory: outputDirectory)
            try await PauseRecordingValidation.run(sourceURL: sourceURL, outputDirectory: outputDirectory)
            try await validateZoomTimingRendering(project: project, outputDirectory: outputDirectory)
            let chapterCaptionDifference = try await validateChapterCaptionRendering(
                project: project,
                exportedURL: renderedURL,
                outputDirectory: outputDirectory
            )
            try await validateTypingFocusRendering(outputDirectory: outputDirectory)
            try await validateInputHandoffRendering(outputDirectory: outputDirectory)
            try await validateAudioFinishing(
                project: project,
                audioFixtureURL: audioFixtureURL,
                outputURL: audioRenderedURL
            )
            try await validateImageBackground(
                project: project,
                imageURL: backgroundFixtureURL,
                outputURL: backgroundRenderedURL
            )

            let report = E2EReport(
                status: "PASS",
                sourcePath: sourceURL.path,
                outputPath: renderedURL.path,
                duration: validation.duration,
                width: validation.width,
                height: validation.height,
                frameRate: export.frameRate,
                videoTrackCount: validation.videoTrackCount,
                audioTrackCount: validation.audioTrackCount,
                outputBytes: validation.outputBytes,
                distinctFrameCount: validation.distinctFrameCount,
                zoomFrameDifference: validation.zoomFrameDifference,
                returnFrameDifference: validation.returnFrameDifference,
                cursorChangedPixels: validation.cursorChangedPixels,
                chapterCaptionDifference: chapterCaptionDifference,
                zoomSegmentCount: project.zoomSegments.count,
                cursorSampleCount: project.cursorSamples.count,
                clickEventCount: project.clickEvents.count
            )
            print(try jsonString(report))
        } catch {
            let failure = FailureReport(status: "FAIL", error: String(describing: error))
            let line = (try? jsonString(failure)) ?? #"{"status":"FAIL","error":"Could not encode error"}"#
            print(line)
            exit(EXIT_FAILURE)
        }
    }

    /// This mode never creates or substitutes event metadata. It validates the
    /// exact saved recording and exports only a smaller review copy elsewhere.
    private static func validateRecordedProject(at metadataURL: URL, outputDirectory: URL) async throws {
        let originalData = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var project = try decoder.decode(RecordingProject.self, from: originalData)
        try require(project.duration.isFinite && project.duration > 0 && project.duration <= 180, "recorded-project validation requires a recording between 0 and 180 seconds")
        try require(project.settings.autoZoomEnabled && project.settings.resolvedTypingZoom.enabled, "automatic zoom and hold-while-typing must both be enabled in the saved recording")
        let recordedTyping = project.typingActivity ?? []
        try require(!recordedTyping.isEmpty, "the saved recording has no genuine typingActivity metadata; no events will be synthesized")
        let crop = project.settings.sourceCropInsets ?? SourceCropInsets()
        let typing = recordedTyping.filter {
            $0.time.isFinite && $0.x.isFinite && $0.y.isFinite && $0.time >= 0 && $0.time < project.duration
                && crop.croppedPoint(x: $0.x, y: $0.y) != nil
        }.sorted { $0.time < $1.time }
        try require(!typing.isEmpty, "all recorded typing activity is outside the visible crop or recording duration")
        let automatic = project.zoomSegments.filter {
            $0.kind == .automatic && $0.isEnabled && crop.croppedPoint(x: $0.targetX, y: $0.targetY) != nil
        }
        try require(!automatic.isEmpty, "genuine typing was captured but the saved project contains no enabled automatic zoom cues")

        let directory = metadataURL.deletingLastPathComponent()
        func resolve(_ path: String?) -> String? {
            guard let path, !path.isEmpty else { return path }
            return (path as NSString).isAbsolutePath ? path : directory.appendingPathComponent(path).standardizedFileURL.path
        }
        project.sourceVideoPath = resolve(project.sourceVideoPath)!
        project.settings.backgroundImagePath = resolve(project.settings.backgroundImagePath)
        if var audio = project.settings.productDemoAudio {
            audio.backgroundMusicPath = resolve(audio.backgroundMusicPath)
            audio.clickSoundPath = resolve(audio.clickSoundPath)
            audio.zoomTransitionSoundPath = resolve(audio.zoomTransitionSoundPath)
            project.settings.productDemoAudio = audio
        }
        try require(FileManager.default.fileExists(atPath: project.sourceVideoPath), "the recording's source video is missing")

        // Transition seconds now match the editor exactly; animation style
        // changes the curve but never secretly multiplies entry/exit duration.
        let timelineSettings = project.settings
        let idleDelay = project.settings.resolvedTypingZoom.idleDelay
        var bursts: [[TypingActivity]] = []
        for event in typing {
            if let previous = bursts.last,
               event.time - previous.last!.time <= idleDelay,
               hypot(event.x - previous[0].x, event.y - previous[0].y) <= 0.08 {
                bursts[bursts.count - 1].append(event)
            } else {
                bursts.append([event])
            }
        }
        let threshold = 1 + max(0.05, project.settings.zoomScale - 1) * 0.90
        var burstChecks: [RecordedTypingBurstCheck] = []
        for burst in bursts {
            let first = burst[0].time
            let last = burst.last!.time
            let settled = max(0, first - project.settings.zoomLeadIn) + timelineSettings.zoomEaseIn
            let plateauEnd = min(project.duration - 1 / 24, last + idleDelay + project.settings.zoomEaseOut - timelineSettings.zoomEaseOut)
            try require(plateauEnd >= settled, "typing burst at \(first)s ends before its zoom can settle; record a longer pause after typing for validation")
            let middle = max(settled, min(plateauEnd, (first + last) / 2))
            let checkTimes = Array(Set([settled, middle, min(plateauEnd, max(settled, last))]
                .map { (ceil($0 * 24) / 24).clamped(to: settled...plateauEnd) })).sorted()
            let scales = checkTimes.map { TimelineMath.zoomState(at: $0, segments: automatic, settings: timelineSettings).scale }
            let minimum = scales.min() ?? 1
            try require(minimum >= threshold, "saved automatic zoom did not stay near full scale during typing burst \(first)...\(last)s (minimum \(minimum), expected >= \(threshold))")
            burstChecks.append(RecordedTypingBurstCheck(firstTime: first, lastTime: last, eventCount: burst.count, checkedTimes: checkTimes, minimumScale: minimum))
        }

        let longestBurst = burstChecks.max { ($0.lastTime - $0.firstTime) < ($1.lastTime - $1.firstTime) }!
        let holdTime = longestBurst.checkedTimes[longestBurst.checkedTimes.count / 2]
        let expectedReturn = typing.last!.time + idleDelay + project.settings.zoomEaseOut + 0.15
        var returnTime: Double?
        var returnCheck = "Not checked: recording ended before the post-typing hold and ease-out finished."
        if expectedReturn < project.duration - 1 / 24 {
            let activeManual = project.zoomSegments.contains { $0.kind == .manual && $0.isEnabled && expectedReturn >= $0.start && expectedReturn <= $0.end }
            let laterClick = project.clickEvents.contains { $0.time > typing.last!.time && $0.time <= expectedReturn }
            if activeManual || laterClick {
                returnCheck = "Not checked: a later click or manually authored zoom overlaps the post-typing return."
            } else {
                let scale = TimelineMath.zoomState(at: expectedReturn, segments: automatic, settings: timelineSettings).scale
                try require(scale <= 1.01, "saved automatic zoom remained active after the final typing burst's idle and ease-out")
                returnTime = expectedReturn
                returnCheck = "PASS: overview restored after the final typing burst."
            }
        }

        project.settings.exportWidth = 960
        project.settings.frameRate = 24
        let stem = "recorded-typing-" + project.id.uuidString.lowercased()
        let outputURL = outputDirectory.appendingPathComponent(stem).appendingPathExtension("mp4")
        try require(outputURL.standardizedFileURL.path != URL(fileURLWithPath: project.sourceVideoPath).standardizedFileURL.path, "review export must not overwrite the original recording")
        let export = try await ProjectVideoRenderer.export(project: project, to: outputURL)
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
        exported.requestedTimeToleranceBefore = .zero
        exported.requestedTimeToleranceAfter = .zero
        let preview = makeImageGenerator(for: try await ProjectVideoRenderer.prepare(project: project))
        var unzoomed = project
        unzoomed.zoomSegments = []
        let baseline = makeImageGenerator(for: try await ProjectVideoRenderer.prepare(project: unzoomed))
        let frameTime = CMTime(seconds: floor(holdTime * 24) / 24, preferredTimescale: 600)
        let (holdFrame, _) = try await exported.image(at: frameTime)
        let (holdPreview, _) = try await preview.image(at: frameTime)
        let (holdBaseline, _) = try await baseline.image(at: frameTime)
        let zoomDifference = imageDifference(holdPreview, holdBaseline).meanAbsolute
        try require(zoomDifference > 0.1, "the real typing frame is visually indistinguishable from its unzoomed source")
        try require(imageDifference(holdPreview, holdFrame).meanAbsolute < 3, "real-project preview and export diverged beyond video compression")
        let holdURL = outputDirectory.appendingPathComponent(stem + "-during.png")
        try writeReviewFrame(holdFrame, to: holdURL)
        var returnURL: URL?
        var returnedDifference: Double?
        if let returnTime {
            let time = CMTime(seconds: floor(returnTime * 24) / 24, preferredTimescale: 600)
            let (returned, _) = try await exported.image(at: time)
            let (overview, _) = try await baseline.image(at: time)
            let difference = imageDifference(returned, overview).meanAbsolute
            try require(difference < 3, "real exported frame did not restore the overview after typing stopped")
            let destination = outputDirectory.appendingPathComponent(stem + "-returned.png")
            try writeReviewFrame(returned, to: destination)
            returnURL = destination
            returnedDifference = difference
        }
        let metadataAfterValidation = try Data(contentsOf: metadataURL)
        try require(metadataAfterValidation == originalData, "original project metadata changed during validation")
        let report = RecordedProjectValidationReport(
            status: "PASS", projectPath: metadataURL.path, outputPath: outputURL.path,
            duration: export.duration, width: export.width, height: export.height, frameRate: export.frameRate,
            cursorSampleCount: project.cursorSamples.count, clickEventCount: project.clickEvents.count,
            typingActivityCount: recordedTyping.count, visibleTypingActivityCount: typing.count,
            automaticZoomCues: automatic.map { RecordedZoomCue(start: $0.start, end: $0.end, scale: $0.scale) },
            typingBursts: burstChecks, duringFrameTime: frameTime.seconds, duringFramePath: holdURL.path,
            zoomFrameDifference: zoomDifference, returnCheck: returnCheck, returnFrameTime: returnTime,
            returnFramePath: returnURL?.path, returnFrameDifference: returnedDifference, originalMetadataUnchanged: true
        )
        let reportText = try jsonString(report)
        try Data(reportText.utf8).write(to: outputDirectory.appendingPathComponent(stem + "-report.json"), options: .atomic)
        print(reportText)
    }

    private static func writeReviewFrame(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw E2EError.assertionFailed("could not create review frame")
        }
        CGImageDestinationAddImage(destination, image, nil)
        try require(CGImageDestinationFinalize(destination), "could not save review frame")
    }

    @MainActor
    private static func runCaptureSmoke(
        outputDirectory: URL,
        requestedWindowTitle: String?
    ) async throws {
        let outputURL = outputDirectory.appendingPathComponent("real-capture-smoke.mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let engine = CaptureEngine()
        let targets = try await engine.refreshAvailableTargets(
            onScreenWindowsOnly: requestedWindowTitle == nil
        )
        let target: CaptureTargetInfo?
        if let requestedWindowTitle {
            target = targets
                .filter {
                    $0.kind == .window && (
                        $0.title.compare(requestedWindowTitle, options: .caseInsensitive) == .orderedSame
                            || $0.appName?.compare(
                                requestedWindowTitle,
                                options: .caseInsensitive
                            ) == .orderedSame
                    )
                }
                .max {
                    ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
                }
        } else {
            target = targets.first(where: { $0.kind == .display })
        }
        guard let target else {
            let description = requestedWindowTitle.map { "window matching \($0)" } ?? "display"
            throw E2EError.assertionFailed("ScreenCaptureKit returned no \(description) target")
        }

        var options = CaptureOptions()
        options.frameRate = 30
        options.maximumOutputDimension = 1_920
        options.capturesSystemAudio = false
        options.capturesMicrophone = false
        try await engine.startRecording(target: target, outputURL: outputURL, options: options)
        try await Task.sleep(nanoseconds: 2_200_000_000)
        let liveDuration = engine.duration
        try require(
            liveDuration >= 1.5,
            "live recording timer did not advance (reported \(liveDuration)s)"
        )
        let screenshotURL = outputDirectory.appendingPathComponent("capture-smoke-screenshot.png")
        if FileManager.default.fileExists(atPath: screenshotURL.path) {
            try FileManager.default.removeItem(at: screenshotURL)
        }
        try await engine.captureScreenshot(to: screenshotURL)
        let screenshotBytes = ((try FileManager.default.attributesOfItem(
            atPath: screenshotURL.path
        )[.size]) as? NSNumber)?.intValue ?? 0
        try require(screenshotBytes > 10_000, "recording screenshot was unexpectedly small")
        let result = try await engine.stopRecording()

        let asset = AVURLAsset(url: result.outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        let bytes = ((try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        try require(tracks.count == 1, "real capture should contain one video track")
        try require(duration >= 1.5, "real capture duration was only \(duration)s")
        try require(bytes > 20_000, "real capture file was unexpectedly small")

        let report = CaptureSmokeReport(
            status: "PASS",
            outputPath: outputURL.path,
            duration: duration,
            bytes: bytes,
            target: target.title,
            width: result.sourceWidth,
            height: result.sourceHeight,
            cursorSampleCount: result.cursorSamples.count,
            clickEventCount: result.clickEvents.count,
            eventCaptureWarning: engine.eventCaptureWarning
        )
        print(try jsonString(report))
    }

    private static func runCoreSelfChecks() throws {
        try validateClickAnimationMath()
        try validateTypingZoomMath()
        try validateZoomTimingEditing()
        try validateZoomRegenerationOwnership()
        var settings = ProjectSettings()

        // Audio finishing is deliberately opt-in. A fresh project must not
        // silently add a bundled track, click sound, or zoom transition sound.
        try require(
            settings.productDemoAudio == nil,
            "new projects must not attach audio finishing automatically"
        )
        let defaultAudio = settings.resolvedProductDemoAudio
        try require(
            defaultAudio.backgroundMusicPath == nil,
            "new projects must not select background music automatically"
        )
        try require(
            !defaultAudio.clickSoundEnabled && defaultAudio.clickSoundPath == nil,
            "new projects must keep click sound effects disabled"
        )
        try require(
            !defaultAudio.zoomTransitionSoundEnabled && defaultAudio.zoomTransitionSoundPath == nil,
            "new projects must keep zoom transition sound effects disabled"
        )

        // Load the same machine-readable catalog used by the editor. Its
        // initializer validates that every referenced resource exists.
        let audioCatalog = try AudioAssetCatalog.loadBundled()
        try require(audioCatalog.music.count >= 8, "the audio library must include at least eight music tracks")
        try require(
            audioCatalog.soundEffects.count >= 3,
            "the audio library must include multiple distinct sound effects"
        )
        try require(
            Set(audioCatalog.assets.map(\.id)).count == audioCatalog.assets.count,
            "audio catalog asset identifiers must be unique"
        )
        try require(
            Set(audioCatalog.assets.map(\.relativePath)).count == audioCatalog.assets.count,
            "audio catalog asset paths must be unique"
        )
        for asset in audioCatalog.assets {
            let fileURL = audioCatalog.fileURL(for: asset)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            try require(byteCount > 0, "audio catalog asset \(asset.id) must not be empty")
            try require(asset.durationSeconds > 0, "audio catalog asset \(asset.id) needs a positive duration")
            try require(
                (0...1).contains(asset.suggestedVolume),
                "audio catalog asset \(asset.id) has an invalid suggested volume"
            )
        }

        try require(
            settings.backgroundImagePath == nil
                && settings.resolvedBackgroundBlur == 0
                && settings.resolvedBackgroundBrightness == 0,
            "new projects must use safe image-background defaults"
        )
        try require(
            settings.cursorAppearance == nil && settings.resolvedCursorAppearance == .system,
            "new projects must resolve a missing cursor appearance to the system cursor"
        )

        settings.zoomScale = 2
        settings.zoomLeadIn = 0.1
        settings.zoomEaseIn = 0.2
        settings.zoomHold = 0.8
        settings.zoomEaseOut = 0.4

        let click = ClickEvent(time: 1, x: 0.8, y: 0.2, button: .left)
        let segments = TimelineMath.generateZoomSegments(
            from: [click],
            duration: 3,
            settings: settings
        )
        try require(segments.count == 1, "one click should create one zoom segment")
        try require(abs(segments[0].start - 0.9) < 0.0001, "zoom lead-in is incorrect")
        try require(abs(segments[0].end - 2.2) < 0.0001, "zoom hold/ease-out is incorrect")

        let before = TimelineMath.zoomState(at: 0.5, segments: segments, settings: settings)
        let active = TimelineMath.zoomState(at: 1.45, segments: segments, settings: settings)
        let after = TimelineMath.zoomState(at: 2.5, segments: segments, settings: settings)
        try require(before.scale == 1 && after.scale == 1, "zoom must return to identity outside its segment")
        try require(active.scale > 1.9, "zoom should reach the configured scale during its hold")
        try require(active.centerX <= 0.75 && active.centerY >= 0.25, "zoom focus clamping exposed source edges")

        let overlapping = TimelineMath.generateZoomSegments(
            from: [
                ClickEvent(time: 1, x: 0.25, y: 0.4, button: .left),
                ClickEvent(time: 1.8, x: 0.75, y: 0.6, button: .left),
            ],
            duration: 4,
            settings: settings
        )
        try require(overlapping.count == 2, "separate nearby clicks should create two zoom segments")
        let secondStart = overlapping[1].start
        let handoff = TimelineMath.zoomState(at: secondStart, segments: overlapping, settings: settings)
        try require(handoff.scale > 1.9, "overlapping zooms must not snap back to 1x at handoff")
        // Hand-off pans take up to handoffPanExtension longer than the ease-in
        // when the regions are far apart (these are 0.5 apart).
        let settledHandoff = TimelineMath.zoomState(
            at: secondStart + settings.zoomEaseIn + TimelineMath.handoffPanExtension,
            segments: overlapping,
            settings: settings
        )
        try require(
            settledHandoff.centerX > 0.72,
            "a newer click must finish the camera handoff at its own focus point"
        )

        var smoothSettings = settings
        smoothSettings.screenAnimation = .smooth
        let smoothStart = TimelineMath.zoomState(
            at: segments[0].start + 0.001,
            segments: segments,
            settings: smoothSettings
        )
        try require(
            smoothStart.scale - 1 < 0.001,
            "smooth zoom should start without a visible velocity jump"
        )

        let styleProbe = ZoomSegment(
            start: 0,
            end: 2,
            targetX: 0.5,
            targetY: 0.5,
            scale: 2
        )
        var gentleSettings = settings
        gentleSettings.zoomEaseIn = 1
        gentleSettings.screenAnimation = .gentle
        var snappySettings = gentleSettings
        snappySettings.screenAnimation = .snappy
        let gentleScale = TimelineMath.zoomState(
            at: 0.2,
            segments: [styleProbe],
            settings: gentleSettings
        ).scale
        let snappyScale = TimelineMath.zoomState(
            at: 0.2,
            segments: [styleProbe],
            settings: snappySettings
        ).scale
        try require(snappyScale > gentleScale, "Snappy animation must respond faster than Gentle")

        let backgroundPairs = Set(
            BackgroundPreset.allCases.map { "\($0.primaryHex)|\($0.secondaryHex)" }
        )
        try require(
            backgroundPairs.count == BackgroundPreset.allCases.count,
            "background presets must have unique color pairs"
        )
        try require(
            BackgroundPreset.aurora.matches(primary: "#6d5dfb", secondary: "#18a6c9"),
            "background preset matching should be case-insensitive"
        )

        var retimed = [
            ZoomSegment(start: 0.5, end: 1.8, targetX: 0.5, targetY: 0.5, scale: 2),
            ZoomSegment(start: 2, end: 3, targetX: 0.5, targetY: 0.5, scale: 2, kind: .manual),
        ]
        TimelineMath.adjustAutomaticHold(in: &retimed, by: 0.4, duration: 4)
        try require(abs(retimed[0].end - 2.2) < 0.0001, "Hold must retime existing automatic zooms")
        try require(abs(retimed[1].end - 3) < 0.0001, "Hold must not retime manual zooms")

        let cursor = TimelineMath.cursorPosition(
            at: 0.5,
            samples: [
                CursorSample(time: 0, x: 0, y: 0),
                CursorSample(time: 1, x: 1, y: 1)
            ]
        )
        try require(abs((cursor?.x ?? -1) - 0.5) < 0.0001, "cursor interpolation is incorrect")

        let constantVelocityCursor = TimelineMath.cursorPosition(
            at: 1.25,
            samples: [
                CursorSample(time: 0, x: 0, y: 0.2),
                CursorSample(time: 1, x: 0.25, y: 0.3),
                CursorSample(time: 2, x: 0.5, y: 0.4),
                CursorSample(time: 3, x: 0.75, y: 0.5),
            ]
        )
        try require(
            abs((constantVelocityCursor?.x ?? -1) - 0.3125) < 0.0001,
            "smooth cursor interpolation must preserve velocity across sample boundaries"
        )

        let legacyCursor = try JSONDecoder().decode(
            CursorSample.self,
            from: Data(#"{"time":0.5,"x":0.25,"y":0.75}"#.utf8)
        )
        try require(
            legacyCursor.cursorKind == .arrow,
            "legacy cursor samples without semantic metadata must decode as arrows"
        )
        let iBeamCursor = CursorSample(time: 1, x: 0.4, y: 0.6, cursorKind: .iBeam)
        let decodedIBeam = try JSONDecoder().decode(
            CursorSample.self,
            from: JSONEncoder().encode(iBeamCursor)
        )
        try require(
            decodedIBeam.cursorKind == .iBeam,
            "I-beam cursor metadata must survive project JSON round trips"
        )
        try require(
            CursorKindSemantics.classify(
                role: "AXTextField",
                subrole: nil,
                isEditable: false,
                hasEditableAncestor: false
            ) == .iBeam
                && CursorKindSemantics.classify(
                    role: "AXStaticText",
                    subrole: nil,
                    isEditable: false,
                    hasEditableAncestor: true
                ) == .iBeam
                && CursorKindSemantics.classify(
                    role: "AXButton",
                    subrole: nil,
                    isEditable: false,
                    hasEditableAncestor: false
                ) == .arrow,
            "accessibility cursor semantics must distinguish editable controls"
        )

        var geometrySettings = ProjectSettings()
        geometrySettings.aspectRatio = .wide
        geometrySettings.exportWidth = 1_921
        geometrySettings.padding = 64
        let geometryProject = RecordingProject(
            title: "Geometry self-check",
            sourceVideoPath: "/unused.mp4",
            duration: 1,
            sourceWidth: 1_600,
            sourceHeight: 900,
            settings: geometrySettings
        )
        let geometry = ProjectVideoRenderer.geometry(for: geometryProject)
        try require(geometry.outputSize == CGSize(width: 1_920, height: 1_080), "wide canvas dimensions must be even and 16:9")
        try require(geometry.screenFrame.minX >= 64 && geometry.screenFrame.minY >= 64, "canvas padding was not preserved")

        let crop = SourceCropInsets(top: 0.20, leading: 0.10, bottom: 0.10, trailing: 0.20)
        let cropRect = crop.sourceRect(in: CGSize(width: 1_000, height: 500))
        try require(
            abs(cropRect.minX - 100) < 0.0001
                && abs(cropRect.minY - 50) < 0.0001
                && abs(cropRect.width - 700) < 0.0001
                && abs(cropRect.height - 350) < 0.0001,
            "source crop must convert top-origin insets to Core Image bottom-origin coordinates"
        )
        let cropTopLeading = crop.croppedPoint(x: 0.10, y: 0.20)
        let cropBottomTrailing = crop.croppedPoint(x: 0.80, y: 0.90)
        try require(
            abs(cropTopLeading?.x ?? -1) < 0.0001
                && abs(cropTopLeading?.y ?? -1) < 0.0001
                && abs((cropBottomTrailing?.x ?? -1) - 1) < 0.0001
                && abs((cropBottomTrailing?.y ?? -1) - 1) < 0.0001,
            "cursor and zoom points must remap into the cropped coordinate space"
        )
        try require(
            crop.croppedPoint(x: 0.5, y: 0.10) == nil,
            "points removed by the top crop must not render"
        )
        let visiblePoint = CGPoint(x: 0.25, y: 0.40)
        let sourcePoint = crop.sourcePoint(x: visiblePoint.x, y: visiblePoint.y)
        let roundTrippedPoint = crop.croppedPoint(x: sourcePoint.x, y: sourcePoint.y)
        try require(
            abs((roundTrippedPoint?.x ?? -1) - visiblePoint.x) < 0.0001
                && abs((roundTrippedPoint?.y ?? -1) - visiblePoint.y) < 0.0001,
            "sourcePoint and croppedPoint must be inverse transforms inside the visible crop"
        )

        let oversizedCrop = SourceCropInsets(top: 0.85, leading: 0.85, bottom: 0.85, trailing: 0.85).sanitized
        try require(
            oversizedCrop.top + oversizedCrop.bottom <= 0.900_001
                && oversizedCrop.leading + oversizedCrop.trailing <= 0.900_001,
            "sanitized crop must retain at least ten percent of each source dimension"
        )

        try require(
            BrowserFamily.detect(applicationName: "Google Chrome") == .chrome
                && BrowserFamily.detect(applicationName: "Microsoft Edge") == .edge
                && BrowserFamily.detect(applicationName: "Brave Browser") == .brave
                && BrowserFamily.detect(applicationName: "Chromium") == .chromium
                && BrowserFamily.detect(applicationName: "Firefox Developer Edition") == .firefox
                && BrowserFamily.detect(applicationName: "Safari") == .safari
                && BrowserFamily.detect(applicationName: "Notes") == nil,
            "browser family detection must cover supported browsers without matching unrelated apps"
        )

        let shortChromeCrop = BrowserContentCrop.insets(for: .chrome, windowHeightPoints: 600)
        let tallChromeCrop = BrowserContentCrop.insets(for: .chrome, windowHeightPoints: 1_200)
        try require(
            abs(shortChromeCrop.top * 600 - BrowserFamily.chrome.contentOffsetPoints) < 0.000_001
                && abs(tallChromeCrop.top * 1_200 - BrowserFamily.chrome.contentOffsetPoints) < 0.000_001
                && shortChromeCrop.top > tallChromeCrop.top,
            "browser chrome crop must preserve a point-sized toolbar instead of a fixed percentage"
        )
        let chromeWithBookmarks = BrowserContentCrop.insets(
            for: .chrome,
            windowHeightPoints: 800,
            hidesBookmarksBar: true
        )
        try require(
            abs(chromeWithBookmarks.top * 800
                - BrowserFamily.chrome.contentOffsetPoints
                - BrowserFamily.chrome.bookmarksBarOffsetPoints) < 0.000_001,
            "the optional bookmarks-bar crop must remove the saved-links row without changing the base preset"
        )
        let browserTarget = CaptureTargetInfo(
            id: "window-browser",
            kind: .window,
            nativeID: 42,
            title: "Finlyze AI",
            appName: "Google Chrome",
            frame: CaptureRect(x: 20, y: 40, width: 1_280, height: 800),
            scaleFactor: 2
        )
        try require(
            abs((BrowserContentCrop.insets(for: browserTarget)?.top ?? -1) - 92.0 / 800.0) < 0.000_001,
            "a browser window target must receive a dimension-aware content crop"
        )
        var displayTarget = browserTarget
        displayTarget.kind = .display
        try require(
            BrowserContentCrop.insets(for: displayTarget) == nil,
            "a display target must not guess which browser window should be cropped"
        )

        let displayFrame = CGRect(x: 0, y: 0, width: 1_496, height: 967)
        let chromeWindowFrame = CGRect(x: 24, y: 25, width: 1_448, height: 920)
        let displayBrowserCrop = BrowserContentCrop.displayInsets(
            for: .chrome,
            displayFrame: displayFrame,
            browserWindowFrame: chromeWindowFrame
        )
        try require(
            abs((displayBrowserCrop?.top ?? -1) * 967 - 117) < 0.000_001
                && abs((displayBrowserCrop?.leading ?? -1) * 1_496 - 24) < 0.000_001
                && abs((displayBrowserCrop?.trailing ?? -1) * 1_496 - 24) < 0.000_001
                && abs((displayBrowserCrop?.bottom ?? -1) * 967 - 22) < 0.000_001,
            "display-to-browser crop must remove menu bar, desktop margins, and browser chrome"
        )
        try require(
            BrowserContentCrop.displayInsets(
                for: .safari,
                displayFrame: displayFrame,
                browserWindowFrame: CGRect(x: 2_000, y: 2_000, width: 400, height: 300)
            ) == nil,
            "display crop must reject a browser window outside the selected display"
        )

        // `sourceCropInsets` is optional so metadata written before this feature
        // remains decodable. Explicitly remove the key to exercise that exact path.
        let currentSettingsData = try JSONEncoder().encode(ProjectSettings())
        var legacySettingsObject = try requireJSONObject(currentSettingsData)
        legacySettingsObject.removeValue(forKey: "sourceCropInsets")
        let legacySettingsData = try JSONSerialization.data(withJSONObject: legacySettingsObject)
        let legacySettings = try JSONDecoder().decode(ProjectSettings.self, from: legacySettingsData)
        try require(
            legacySettings.sourceCropInsets == nil,
            "legacy settings without crop metadata must decode as an uncropped project"
        )

        legacySettingsObject.removeValue(forKey: "cursorAppearance")
        let preCursorAppearanceData = try JSONSerialization.data(withJSONObject: legacySettingsObject)
        let preCursorAppearanceSettings = try JSONDecoder().decode(
            ProjectSettings.self,
            from: preCursorAppearanceData
        )
        try require(
            preCursorAppearanceSettings.cursorAppearance == nil
                && preCursorAppearanceSettings.resolvedCursorAppearance == .system,
            "legacy settings without a cursor theme must use the system cursor"
        )

        var cursorAppearanceRoundTrip = ProjectSettings()
        cursorAppearanceRoundTrip.cursorAppearance = .highContrast
        let decodedCursorAppearance = try JSONDecoder().decode(
            ProjectSettings.self,
            from: JSONEncoder().encode(cursorAppearanceRoundTrip)
        )
        try require(
            decodedCursorAppearance.resolvedCursorAppearance == .highContrast,
            "cursor appearance must survive project metadata round trips"
        )

        legacySettingsObject.removeValue(forKey: "backgroundImagePath")
        legacySettingsObject.removeValue(forKey: "backgroundBlur")
        legacySettingsObject.removeValue(forKey: "backgroundBrightness")
        let preImageBackgroundData = try JSONSerialization.data(withJSONObject: legacySettingsObject)
        let preImageBackgroundSettings = try JSONDecoder().decode(
            ProjectSettings.self,
            from: preImageBackgroundData
        )
        try require(
            preImageBackgroundSettings.backgroundImagePath == nil
                && preImageBackgroundSettings.resolvedBackgroundBlur == 0
                && preImageBackgroundSettings.resolvedBackgroundBrightness == 0,
            "legacy settings without image-background metadata must use safe defaults"
        )

        legacySettingsObject.removeValue(forKey: "productDemoAudio")
        let preAudioSettingsData = try JSONSerialization.data(withJSONObject: legacySettingsObject)
        let preAudioSettings = try JSONDecoder().decode(ProjectSettings.self, from: preAudioSettingsData)
        try require(
            preAudioSettings.productDemoAudio == nil
                && preAudioSettings.resolvedProductDemoAudio.sourceAudioVolume == 1,
            "legacy settings without product-demo audio metadata must use non-destructive defaults"
        )

        var audioSettingsRoundTrip = ProjectSettings()
        audioSettingsRoundTrip.productDemoAudio = ProductDemoAudioSettings(
            sourceAudioVolume: 0.42,
            backgroundMusicPath: "demo.m4a",
            clickSoundEnabled: true,
            zoomTransitionSoundEnabled: true
        )
        let roundTrippedAudioSettings = try JSONDecoder().decode(
            ProjectSettings.self,
            from: JSONEncoder().encode(audioSettingsRoundTrip)
        )
        try require(
            roundTrippedAudioSettings.productDemoAudio == audioSettingsRoundTrip.productDemoAudio,
            "product-demo audio settings must survive project metadata round trips"
        )

        var imageBackgroundRoundTrip = ProjectSettings()
        imageBackgroundRoundTrip.backgroundStyle = .image
        imageBackgroundRoundTrip.backgroundImagePath = "/System/Library/Desktop Pictures/example.heic"
        imageBackgroundRoundTrip.backgroundBlur = 18
        imageBackgroundRoundTrip.backgroundBrightness = -0.16
        let decodedImageBackground = try JSONDecoder().decode(
            ProjectSettings.self,
            from: JSONEncoder().encode(imageBackgroundRoundTrip)
        )
        try require(
            decodedImageBackground.backgroundStyle == .image
                && decodedImageBackground.backgroundImagePath == imageBackgroundRoundTrip.backgroundImagePath
                && decodedImageBackground.resolvedBackgroundBlur == 18
                && abs(decodedImageBackground.resolvedBackgroundBrightness + 0.16) < 0.0001,
            "image-background settings must survive project metadata round trips"
        )
    }

    private static func validateClickAnimationMath() throws {
        for style in ClickAnimationStyle.allCases {
            let settings = ClickAnimationSettings(style: style)
            for age in [-1.0, 0, settings.duration, settings.duration + 1, .nan] {
                try require(
                    ClickAnimationMath.layers(age: age, settings: settings).isEmpty,
                    "click feedback must be absent outside its exact event interval"
                )
            }
            let visible = ClickAnimationMath.layers(age: 0.16, settings: settings)
            try require(!visible.isEmpty && visible.contains { $0.opacity > 0.1 }, "each click style must have visible feedback")
            let start = ClickAnimationMath.layers(age: 0.0001, settings: settings)
            let end = ClickAnimationMath.layers(age: settings.duration - 0.0001, settings: settings)
            try require(
                start.allSatisfy { $0.opacity < 0.00001 } && end.allSatisfy { $0.opacity < 0.00001 },
                "click animation must fade in and out continuously without a one-frame flash"
            )
            let smaller = ClickAnimationMath.layers(age: 0.16, settings: ClickAnimationSettings(style: style, size: 0.5))
            try require(abs(smaller[0].radius * 2 - visible[0].radius) < 0.00001, "effect size must scale its geometry")
        }
        let settings = ClickAnimationSettings()
        try require(ClickAnimationMath.cursorPressScale(age: 0, settings: settings) == 1, "cursor press must begin at its unmodified size")
        try require(ClickAnimationMath.cursorPressScale(age: 0.1, settings: settings) < 0.9, "cursor press must visibly compress")
        try require(ClickAnimationMath.cursorPressScale(age: 1, settings: settings) == 1, "cursor press must settle at its original size")
        try require(ClickAnimationMath.cursorPressScale(age: 0.1, settings: ClickAnimationSettings(pressCursor: false)) == 1, "cursor press can be disabled independently")
        let sanitized = ClickAnimationSettings(size: .infinity, duration: -.infinity, intensity: .nan).sanitized
        try require(sanitized.size.isFinite && sanitized.duration > 0 && sanitized.intensity.isFinite, "invalid saved animation values must not reach rendering")

        let encoded = try JSONEncoder().encode(ProjectSettings())
        var legacy = try requireJSONObject(encoded)
        legacy.removeValue(forKey: "clickAnimation")
        let decoded = try JSONDecoder().decode(ProjectSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(decoded.clickAnimation == nil && decoded.resolvedClickAnimation.style == .ripple, "legacy project settings must decode without click animation metadata")
        var edited = decoded
        edited.clickAnimation = ClickAnimationSettings(style: .halo, colorHex: "#FF42B5", size: 1.8, duration: 0.9, intensity: 0.6, pressCursor: false)
        let restored = try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(edited))
        try require(restored.clickAnimation == edited.clickAnimation, "every edited click feedback control must survive save and reopen")
    }

    private static func validateZoomTimingEditing() throws {
        var settings = ProjectSettings()
        settings.screenAnimation = .focused
        settings.zoomEaseIn = 0.2
        settings.zoomEaseOut = 0.4
        settings.zoomLeadIn = 0.1
        settings.zoomHold = 2
        let original = ZoomSegment(start: 1, end: 5, targetX: 0.35, targetY: 0.65, scale: 2)

        var legacyObject = try requireJSONObject(JSONEncoder().encode(original))
        legacyObject.removeValue(forKey: "zoomEaseIn")
        legacyObject.removeValue(forKey: "zoomEaseOut")
        legacyObject.removeValue(forKey: "automaticSource")
        let legacy = try JSONDecoder().decode(ZoomSegment.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        try require(legacy.zoomEaseIn == nil && legacy.zoomEaseOut == nil, "old zoom JSON must inherit project transition durations")
        let inherited = ZoomTiming.resolve(legacy, settings: settings)
        try require(abs(inherited.easeIn - 0.2) < 0.000001 && abs(inherited.easeOut - 0.4) < 0.000001, "legacy zooms must keep the existing global entry/exit timing")

        let startEdited = ZoomTiming.applying(.start(2), to: original, projectDuration: 10, settings: settings)
        try require(startEdited.start == 2 && startEdited.end == 5 && startEdited.id == original.id && startEdited.kind == .manual, "editing start must preserve end and selection identity and mark the block manual")
        let endEdited = ZoomTiming.applying(.end(4), to: original, projectDuration: 10, settings: settings)
        try require(endEdited.start == 1 && endEdited.end == 4, "editing end must leave start fixed")
        let durationEdited = ZoomTiming.applying(.duration(2.5), to: original, projectDuration: 10, settings: settings)
        try require(durationEdited.start == 1 && durationEdited.end == 3.5, "editing total duration must change end relative to its existing start")
        let holdEdited = ZoomTiming.applying(.hold(1), to: original, projectDuration: 10, settings: settings)
        let resolvedHold = ZoomTiming.resolve(holdEdited, settings: settings)
        try require(holdEdited.start == 1 && abs(resolvedHold.hold - 1) < 0.000001 && abs(resolvedHold.duration - 1.6) < 0.000001, "hold duration must exclude entry and exit transitions")
        let compressed = ZoomSegment(start: 0, end: 1, targetX: 0.35, targetY: 0.65, scale: 2, zoomEaseIn: 2, zoomEaseOut: 2)
        let expandedHold = ZoomTiming.applying(.hold(2), to: compressed, projectDuration: 10, settings: settings)
        let expandedTiming = ZoomTiming.resolve(expandedHold, settings: settings)
        try require(abs(expandedTiming.duration - 3) < 0.000001 && abs(expandedTiming.hold - 2) < 0.000001 && expandedTiming.easeIn == 0.5 && expandedTiming.easeOut == 0.5, "increasing hold after compressed transitions must keep the displayed effective speeds instead of reviving long overrides")
        let moved = ZoomTiming.applying(.move(9), to: original, projectDuration: 10, settings: settings)
        try require(moved.start == 6 && moved.end == 10, "moving a block to the project edge must preserve its duration and clamp the whole block")
        let tooLate = ZoomTiming.applying(.start(100), to: original, projectDuration: 10, settings: settings)
        let tooEarly = ZoomTiming.applying(.end(-100), to: original, projectDuration: 10, settings: settings)
        try require(tooLate.end == 5 && tooLate.start < tooLate.end && tooEarly.start == 1 && tooEarly.end > tooEarly.start, "start/end edits cannot invert the selected block")

        var custom = ZoomTiming.applying(.easeIn(0.08), to: original, projectDuration: 10, settings: settings)
        custom = ZoomTiming.applying(.easeOut(0.75), to: custom, projectDuration: 10, settings: settings)
        let restored = try JSONDecoder().decode(ZoomSegment.self, from: JSONEncoder().encode(custom))
        try require(restored == custom && restored.zoomEaseIn == 0.08 && restored.zoomEaseOut == 0.75, "per-block transition edits must survive save/reopen without modifying start/end")
        try require(custom.start == original.start && custom.end == original.end, "changing zoom speed must not silently change the block's interval")
        var slowerGlobals = settings
        slowerGlobals.zoomEaseIn = 1.5
        slowerGlobals.zoomEaseOut = 1.5
        let customState = TimelineMath.zoomState(at: 1.15, segments: [custom], settings: settings)
        let customWithNewGlobals = TimelineMath.zoomState(at: 1.15, segments: [custom], settings: slowerGlobals)
        let inheritedWithNewGlobals = TimelineMath.zoomState(at: 1.15, segments: [legacy], settings: slowerGlobals)
        try require(abs(customState.scale - customWithNewGlobals.scale) < 0.000001 && customState.scale > 1.99 && customState.scale - inheritedWithNewGlobals.scale > 0.5, "a block's transition override must take precedence over changed global defaults")
        let reset = ZoomTiming.applying(.resetTransitions, to: custom, projectDuration: 10, settings: settings)
        try require(reset.zoomEaseIn == nil && reset.zoomEaseOut == nil && reset.start == custom.start && reset.end == custom.end, "resetting transition overrides must restore inheritance without moving the block")
        var immediate = ZoomTiming.applying(.easeIn(0), to: original, projectDuration: 10, settings: settings)
        immediate = ZoomTiming.applying(.easeOut(0), to: immediate, projectDuration: 10, settings: settings)
        try require(TimelineMath.zoomState(at: immediate.start, segments: [immediate], settings: settings).scale == 2 && TimelineMath.zoomState(at: immediate.end + 0.001, segments: [immediate], settings: settings).scale == 1, "zero-second transitions must be instantaneous while preserving the selected interval")

        for invalid in [Double.nan, .infinity, -.infinity] {
            for edit in [ZoomTimingEdit.start(invalid), .end(invalid), .duration(invalid), .hold(invalid), .easeIn(invalid), .easeOut(invalid), .move(invalid)] {
                try require(ZoomTiming.applying(edit, to: original, projectDuration: 10, settings: settings) == original, "nonfinite UI timing edits must leave the existing block untouched")
            }
            try require(ZoomTiming.applying(.duration(2), to: original, projectDuration: invalid, settings: settings) == original, "invalid recording duration must not corrupt an otherwise valid block")
        }
        for invalidDuration in [0.0, -1.0] {
            try require(ZoomTiming.applying(.duration(2), to: original, projectDuration: invalidDuration, settings: settings) == original, "zero/negative recording duration must reject edits without corrupting the block")
        }
        for requestedDuration in [0.0, -1.0] {
            let clamped = ZoomTiming.applying(.duration(requestedDuration), to: original, projectDuration: 10, settings: settings)
            try require(clamped.start == original.start && abs(clamped.end - clamped.start - ZoomTiming.minimumDuration) < 0.000001, "zero/negative requested block duration must clamp to a usable minimum")
        }
        var extreme = original
        extreme.zoomEaseIn = Double.greatestFiniteMagnitude
        extreme.zoomEaseOut = Double.greatestFiniteMagnitude
        let extremeTiming = ZoomTiming.resolve(extreme, settings: settings)
        try require(extremeTiming.easeIn.isFinite && extremeTiming.easeOut.isFinite && abs(extremeTiming.easeIn + extremeTiming.easeOut - 4) < 0.000001, "very large but finite transition values must compress without overflowing")
        for clipDuration in [0.001, 0.02, 0.049, 0.05, 0.08, 0.2] {
            var short = ZoomSegment(start: 0, end: clipDuration, targetX: 0.4, targetY: 0.6, scale: 2, kind: .manual)
            short.zoomEaseIn = 4
            short.zoomEaseOut = 2
            short = ZoomTiming.applying(.duration(10), to: short, projectDuration: clipDuration, settings: settings)
            let resolved = ZoomTiming.resolve(short, settings: settings)
            try require(short.start == 0 && abs(short.end - clipDuration) < 0.000001 && resolved.duration > 0, "shorter-than-minimum recordings must still fit a valid full-clip block")
            try require(resolved.easeIn >= 0 && resolved.easeOut >= 0 && resolved.hold >= -0.000001 && resolved.easeIn + resolved.easeOut <= clipDuration + 0.000001, "short blocks must compress transitions into their available time")
            let peak = TimelineMath.zoomState(at: short.start + resolved.easeIn, segments: [short], settings: settings)
            try require(peak.scale.isFinite && abs(peak.scale - 2) < 0.0001, "even a short block must reach its requested zoom instead of remaining permanently half-zoomed")
        }
        var invalidSaved = original
        invalidSaved.zoomEaseIn = .nan
        invalidSaved.zoomEaseOut = -.infinity
        let sanitized = ZoomTiming.resolve(invalidSaved, settings: settings)
        try require(sanitized.easeIn.isFinite && sanitized.easeOut.isFinite && sanitized.hold.isFinite, "invalid saved transition values must never reach the renderer")
        let overlapping = [custom, extreme, invalidSaved]
        for time in [0.9, 1.0, 1.15, 2, 4.9, 5.0, 5.1] {
            let state = TimelineMath.zoomState(at: time, segments: overlapping, settings: settings)
            try require(state.scale.isFinite && state.centerX.isFinite && state.centerY.isFinite && (1...2).contains(state.scale), "overlapping custom transitions must produce finite bounded camera states")
        }

        // Preserve the visible edit, not merely the presence of a manual record:
        // regenerating the source click must not restore an overlapping auto cue
        // that keeps the camera zoomed after the user's newly chosen end time.
        let click = ClickEvent(time: 2, x: 0.35, y: 0.65, button: .left)
        var project = RecordingProject(title: "Manual zoom timing", sourceVideoPath: "/tmp/zoom-timing.mp4", duration: 8, sourceWidth: 960, sourceHeight: 540, clickEvents: [click], settings: settings)
        TimelineMath.regenerateAutomaticZoomSegments(in: &project)
        try require(project.zoomSegments.count == 1, "timing-regeneration fixture needs exactly one original auto cue")
        let generated = project.zoomSegments[0]
        var override = ZoomTiming.applying(.end(2.7), to: generated, projectDuration: project.duration, settings: settings)
        override = ZoomTiming.applying(.easeOut(0.1), to: override, projectDuration: project.duration, settings: settings)
        project.zoomSegments = [override]
        project.settings.typingZoom = TypingZoomSettings(idleDelay: 2.5)
        TimelineMath.regenerateAutomaticZoomSegments(in: &project)
        try require(project.zoomSegments == [override], "regeneration must retain the edited manual block's ID, interval, and transition overrides without duplicating its source cue")
        try require(TimelineMath.zoomState(at: 3, segments: project.zoomSegments, settings: project.settings).scale == 1, "regeneration must not restore the replaced automatic cue under a manually shortened block")
        let movedOverride = ZoomTiming.applying(.move(4), to: override, projectDuration: project.duration, settings: settings)
        project.zoomSegments = [movedOverride]
        TimelineMath.regenerateAutomaticZoomSegments(in: &project)
        try require(project.zoomSegments.contains(movedOverride) && TimelineMath.zoomState(at: 2.5, segments: project.zoomSegments, settings: project.settings).scale == 1, "moving an edited automatic block must not resurrect its original source-click zoom during regeneration")
        TimelineMath.adjustAutomaticClickHold(in: &project, by: 1)
        try require(project.zoomSegments.contains(movedOverride), "global hold edits must not overwrite a manually retimed block")
        var reopenedProject = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(project))
        TimelineMath.regenerateAutomaticZoomSegments(in: &reopenedProject)
        try require(reopenedProject.zoomSegments == project.zoomSegments, "manual ownership of a replaced automatic cue must survive save/reopen and subsequent regeneration")
        var oldCueObject = try requireJSONObject(JSONEncoder().encode(generated))
        oldCueObject.removeValue(forKey: "automaticSource")
        oldCueObject.removeValue(forKey: "zoomEaseIn")
        oldCueObject.removeValue(forKey: "zoomEaseOut")
        let oldCue = try JSONDecoder().decode(ZoomSegment.self, from: JSONSerialization.data(withJSONObject: oldCueObject))
        let editedOldCue = ZoomTiming.applying(.end(2.7), to: oldCue, projectDuration: project.duration, settings: settings)
        project.zoomSegments = [editedOldCue]
        TimelineMath.regenerateAutomaticZoomSegments(in: &project)
        try require(project.zoomSegments == [editedOldCue], "editing a legacy auto cue without source metadata must still prevent its duplicate on regeneration")
        let unrelatedManual = ZoomSegment(start: 4, end: 5, targetX: 0.35, targetY: 0.65, scale: 1.8, kind: .manual)
        project.zoomSegments = [unrelatedManual]
        TimelineMath.regenerateAutomaticZoomSegments(in: &project)
        try require(project.zoomSegments.contains(unrelatedManual) && project.zoomSegments.contains { $0.kind == .automatic }, "a newly authored manual zoom must not suppress unrelated automatic events merely because its focus is similar")
    }

    private static func validateZoomRegenerationOwnership() throws {
        var settings = ProjectSettings()
        settings.zoomLeadIn = 0.1
        settings.zoomEaseOut = 0.4
        settings.typingZoom = TypingZoomSettings(idleDelay: 5)
        let activities = [
            TypingActivity(time: 1, x: 0.35, y: 0.65),
            TypingActivity(time: 3, x: 0.35, y: 0.65),
        ]
        var merged = RecordingProject(title: "Merged typing ownership", sourceVideoPath: "/tmp/zoom-ownership.mp4", duration: 16, sourceWidth: 960, sourceHeight: 540, typingActivity: activities, settings: settings)
        TimelineMath.regenerateAutomaticZoomSegments(in: &merged)
        try require(merged.zoomSegments.count == 1, "ownership fixture must initially merge both typing activities")
        let aggregate = merged.zoomSegments[0]
        try require(aggregate.automaticSource?.typingActivity == activities && aggregate.automaticSource?.clickIDs == [], "a generated typing aggregate must retain every source activity, not only its first anchor")
        let sourceRoundTrip = try JSONDecoder().decode(ZoomSegment.self, from: JSONEncoder().encode(aggregate))
        try require(sourceRoundTrip == aggregate, "complete automatic source members must survive JSON roundtrip")
        var shortened = ZoomTiming.applying(.end(1.8), to: aggregate, projectDuration: merged.duration, settings: settings)
        shortened = ZoomTiming.applying(.easeOut(0.1), to: shortened, projectDuration: merged.duration, settings: settings)
        merged.zoomSegments = [shortened]
        merged.settings.typingZoom = TypingZoomSettings(idleDelay: 0.4)
        TimelineMath.regenerateAutomaticZoomSegments(in: &merged)
        try require(merged.zoomSegments == [shortened], "splitting a manually shortened aggregate with a lower typing idle delay must not resurrect its later source activity")
        try require(TimelineMath.zoomState(at: 3.2, segments: merged.zoomSegments, settings: merged.settings).scale == 1, "the later typing activity taken over by a manual aggregate must stay at overview after its edited end")
        let relocated = ZoomTiming.applying(.move(9), to: shortened, projectDuration: merged.duration, settings: settings)
        merged.zoomSegments = [relocated]
        merged = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(merged))
        TimelineMath.regenerateAutomaticZoomSegments(in: &merged)
        try require(merged.zoomSegments == [relocated], "saved and moved aggregate ownership must suppress all original source times, not only its new interval")

        var separated = merged
        separated.zoomSegments = []
        TimelineMath.regenerateAutomaticZoomSegments(in: &separated)
        try require(separated.zoomSegments.count == 2, "short idle delay must split the typing fixture into two automatic blocks")
        let firstAuto = separated.zoomSegments[0]
        let secondAuto = separated.zoomSegments[1]
        let firstManual = ZoomTiming.applying(.move(7), to: firstAuto, projectDuration: separated.duration, settings: separated.settings)
        let secondManual = ZoomTiming.applying(.move(10), to: secondAuto, projectDuration: separated.duration, settings: separated.settings)
        separated.zoomSegments = [firstManual, secondManual]
        separated.settings.typingZoom = TypingZoomSettings(idleDelay: 5)
        TimelineMath.regenerateAutomaticZoomSegments(in: &separated)
        try require(separated.zoomSegments == [firstManual, secondManual], "increasing typing delay must not merge or regenerate events already owned by separate manual blocks")
        var partial = separated
        partial.zoomSegments = [firstAuto, secondManual]
        TimelineMath.regenerateAutomaticZoomSegments(in: &partial)
        let remaining = partial.zoomSegments.filter { $0.kind == .automatic }
        try require(partial.zoomSegments.contains(secondManual) && remaining.count == 1 && remaining[0].automaticSource?.typingActivity == [activities[0]], "regeneration must exclude an owned later input before merging, while retaining the untouched earlier automatic input")

        let clicks = [
            ClickEvent(time: 1, x: 0.32, y: 0.65, button: .left),
            ClickEvent(time: 1.2, x: 0.35, y: 0.65, button: .left),
        ]
        let mixedTyping = [TypingActivity(time: 1.3, x: 0.35, y: 0.65), TypingActivity(time: 3, x: 0.35, y: 0.65)]
        var mixed = RecordingProject(title: "Mixed source ownership", sourceVideoPath: "/tmp/zoom-ownership.mp4", duration: 16, sourceWidth: 960, sourceHeight: 540, clickEvents: clicks, typingActivity: mixedTyping, settings: settings)
        TimelineMath.regenerateAutomaticZoomSegments(in: &mixed)
        try require(mixed.zoomSegments.count == 1, "merged clicks and same-field typing should form one source-owned camera block")
        let mixedAuto = mixed.zoomSegments[0]
        try require(Set(mixedAuto.automaticSource?.clickIDs ?? []) == Set(clicks.map(\.id)) && mixedAuto.automaticSource?.typingActivity == mixedTyping, "merged click and typing sources must accumulate every event identity despite target changes")
        let mixedManual = ZoomTiming.applying(.end(1.45), to: mixedAuto, projectDuration: mixed.duration, settings: mixed.settings)
        mixed.zoomSegments = [mixedManual]
        mixed = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(mixed))
        mixed.settings.typingZoom = TypingZoomSettings(idleDelay: 0.4)
        TimelineMath.regenerateAutomaticZoomSegments(in: &mixed)
        try require(mixed.zoomSegments == [mixedManual], "complete click and typing ownership must survive saving and prevent hidden regeneration after an aggregate is split")
        let newUnownedActivity = TypingActivity(time: 2, x: 0.35, y: 0.65)
        mixed.typingActivity?.append(newUnownedActivity)
        TimelineMath.regenerateAutomaticZoomSegments(in: &mixed)
        try require(mixed.zoomSegments.contains(mixedManual) && mixed.zoomSegments.filter { $0.kind == .automatic }.flatMap { $0.automaticSource?.typingActivity ?? [] } == [newUnownedActivity], "exact source membership must not suppress an unrelated event merely because it falls inside the old aggregate span")

        for keepFirstAnchor in [false, true] {
            var oldObject = try requireJSONObject(JSONEncoder().encode(aggregate))
            if keepFirstAnchor {
                var oldSource = oldObject["automaticSource"] as! [String: Any]
                for key in ["clickIDs", "typingActivity", "originalEnd"] { oldSource.removeValue(forKey: key) }
                oldObject["automaticSource"] = oldSource
            } else {
                oldObject.removeValue(forKey: "automaticSource")
            }
            let oldAuto = try JSONDecoder().decode(ZoomSegment.self, from: JSONSerialization.data(withJSONObject: oldObject))
            let oldManual = ZoomTiming.applying(.end(1.8), to: oldAuto, projectDuration: merged.duration, settings: settings)
            try require(oldManual.automaticSource?.originalEnd == aggregate.end, "editing a legacy aggregate must preserve its unedited source end for compatibility")
            var migrated = merged
            migrated.zoomSegments = [oldManual]
            migrated = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(migrated))
            TimelineMath.regenerateAutomaticZoomSegments(in: &migrated)
            try require(migrated.zoomSegments == [oldManual], "legacy aggregate ownership must prevent later source activities resurfacing when typing delay splits the old span")
        }
    }

    private static func validateTypingZoomMath() throws {
        let settings = ProjectSettings()
        let click = ClickEvent(time: 0.5, x: 0.3, y: 0.65, button: .left)
        let activity = stride(from: 0.6, through: 6.0, by: 0.25).map {
            TypingActivity(time: $0, x: 0.3, y: 0.65)
        }
        let cues = TimelineMath.generateZoomSegments(from: [click], duration: 10, settings: settings, typingActivity: activity)
        let last = activity.last!.time
        try require(cues.count == 1 && abs(cues[0].end - (last + 1.4 + settings.zoomEaseOut)) < 0.0001, "typing must extend the clicked input through its last activity plus quiet delay and ease out")
        let held = TimelineMath.zoomState(at: 5.5, segments: cues, settings: settings)
        try require(abs(held.scale - settings.zoomScale) < 0.0001 && abs(held.centerX - 0.3) < 0.0001, "long typing must remain fully zoomed on the input after ordinary click hold expires")
        let leaving = TimelineMath.zoomState(at: last + 1.4 + settings.zoomEaseOut / 2, segments: cues, settings: settings)
        let left = TimelineMath.zoomState(at: last + 1.4 + settings.zoomEaseOut + 0.001, segments: cues, settings: settings)
        try require(leaving.scale > 1 && leaving.scale < settings.zoomScale && left.scale == 1, "typing must ease out only after its idle delay, then restore the overview")
        let keyboardOnly = TimelineMath.generateZoomSegments(from: [], duration: 10, settings: settings, typingActivity: activity)
        try require(keyboardOnly.count == 1 && keyboardOnly[0].targetX == 0.3, "keyboard-focused inputs must generate a zoom without a preceding click")
        let paused = TimelineMath.generateZoomSegments(from: [], duration: 10, settings: settings, typingActivity: [
            TypingActivity(time: 1, x: 0.3, y: 0.65), TypingActivity(time: 4, x: 0.3, y: 0.65),
        ])
        try require(paused.count == 2 && TimelineMath.zoomState(at: 3.2, segments: paused, settings: settings).scale == 1, "long pauses must release zoom and begin a fresh burst when typing resumes")
        let changingInputs = TimelineMath.generateZoomSegments(from: [], duration: 6, settings: settings, typingActivity: [
            TypingActivity(time: 1, x: 0.3, y: 0.65), TypingActivity(time: 1.4, x: 0.3, y: 0.65),
            TypingActivity(time: 1.7, x: 0.7, y: 0.35), TypingActivity(time: 2.0, x: 0.7, y: 0.35),
        ])
        let switchTime = changingInputs[1].start
        let before = TimelineMath.zoomState(at: switchTime - 0.0001, segments: changingInputs, settings: settings)
        let during = TimelineMath.zoomState(at: switchTime + 0.0001, segments: changingInputs, settings: settings)
        let settled = TimelineMath.zoomState(at: switchTime + settings.zoomEaseIn, segments: changingInputs, settings: settings)
        try require(abs(before.scale - during.scale) < 0.001 && abs(before.centerX - during.centerX) < 0.001 && settled.centerX > 0.69, "changing inputs must smoothly transfer zoom without first returning to the overview")

        var disabled = settings
        disabled.typingZoom = TypingZoomSettings(enabled: false)
        let clickOnly = TimelineMath.generateZoomSegments(from: [click], duration: 10, settings: disabled, typingActivity: activity)
        try require(abs(clickOnly[0].end - (click.time + settings.zoomHold + settings.zoomEaseOut)) < 0.0001, "turning typing hold off must retain ordinary click timing")
        disabled.autoZoomEnabled = false
        try require(TimelineMath.generateZoomSegments(from: [click], duration: 10, settings: disabled, typingActivity: activity).isEmpty, "automatic zoom off must disable typing cues too")
        let clamped = TimelineMath.generateZoomSegments(from: [], duration: 1, settings: settings, typingActivity: [TypingActivity(time: 0.9, x: 0.4, y: 0.6)])
        try require(clamped[0].end == 1, "typing hold must never extend past the recording")
        var pageSettings = settings
        pageSettings.sourceCropInsets = SourceCropInsets(top: 0.2)
        let browserTyping = [TypingActivity(time: 1.2, x: 0.3, y: 0.12), TypingActivity(time: 5, x: 0.3, y: 0.12)]
        let pageCues = TimelineMath.generateZoomSegments(from: [ClickEvent(time: 0.5, x: 0.3, y: 0.21, button: .left)], duration: 8, settings: pageSettings, typingActivity: browserTyping)
        try require(pageCues.count == 1 && pageCues[0].end < 2, "typing in a cropped-out browser address bar must not prolong a nearby visible product zoom")
        try require(TimelineMath.generateZoomSegments(from: [], duration: 8, settings: pageSettings, typingActivity: browserTyping).isEmpty, "cropped-out browser typing must not create camera cues")

        var project = RecordingProject(title: "Typing metadata", sourceVideoPath: "/tmp/input.mp4", duration: 10, sourceWidth: 960, sourceHeight: 540, clickEvents: [click], typingActivity: activity)
        let manual = ZoomSegment(start: 8, end: 9, targetX: 0.5, targetY: 0.5, scale: 1.3, kind: .manual)
        project.zoomSegments = [manual]
        TimelineMath.regenerateAutomaticZoomSegments(in: &project)
        try require(project.zoomSegments.contains(manual) && project.zoomSegments.contains { $0.kind == .automatic && $0.end > 7 }, "typing regeneration must preserve all manually authored blocks")
        let autoIndex = project.zoomSegments.firstIndex { $0.kind == .automatic }!
        project.zoomSegments[autoIndex].scale = 2.2
        project.zoomSegments[autoIndex].isEnabled = false
        let previousAuto = project.zoomSegments[autoIndex]
        project.settings.typingZoom = TypingZoomSettings(idleDelay: 2)
        TimelineMath.regenerateAutomaticZoomSegments(in: &project)
        try require(project.zoomSegments.contains { $0.id == previousAuto.id && $0.scale == 2.2 && !$0.isEnabled && $0.end > previousAuto.end }, "editing typing delay must retain matching block selection, custom scale, and disabled state")
        let heldBlock = project.zoomSegments.first { $0.id == previousAuto.id }!
        let retimedClick = ZoomSegment(start: 8.1, end: 8.4, targetX: 0.8, targetY: 0.8, scale: 2, kind: .automatic)
        project.zoomSegments.append(retimedClick)
        TimelineMath.adjustAutomaticClickHold(in: &project, by: 0.5)
        try require(project.zoomSegments.contains(heldBlock) && project.zoomSegments.contains(manual), "ordinary click hold changes must preserve typing holds and manual blocks")
        try require(project.zoomSegments.contains { $0.id == retimedClick.id && $0.start == 8.1 && abs($0.end - 8.9) < 0.0001 }, "click hold changes must adjust existing auto cues without replacing a user's retiming")
        let activityJSON = try requireJSONObject(JSONEncoder().encode(activity[0]))
        try require(Set(activityJSON.keys) == Set(["time", "x", "y"]), "typing metadata must contain timing and focus only, never characters, text, or key codes")
        var legacy = try requireJSONObject(JSONEncoder().encode(project))
        legacy.removeValue(forKey: "typingActivity")
        var legacySettings = legacy["settings"] as! [String: Any]
        legacySettings.removeValue(forKey: "typingZoom")
        legacy["settings"] = legacySettings
        let decoded = try JSONDecoder().decode(RecordingProject.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(decoded.typingActivity == nil && decoded.settings.resolvedTypingZoom.enabled, "old recordings must decode without typing metadata or settings")
    }

    #if DEBUG
    @MainActor
    private static func runEventMonitorSelfCheck() async throws {
        let monitor = EventMonitor()
        try monitor.prepare(captureRect: CaptureRect(x: 100, y: 200, width: 400, height: 200))
        monitor.anchor(at: 1_000)
        monitor.injectEventForTesting(
            uptime: 1_000.5,
            x: 300,
            y: 250,
            button: .left
        )
        monitor.injectEventForTesting(
            uptime: 1_000.6,
            x: 320,
            y: 260,
            cursorKind: .iBeam
        )
        let trace = monitor.snapshot()
        monitor.stop()

        guard let click = trace.clickEvents.last else {
            throw E2EError.assertionFailed("the event monitor did not store an injected mouse-down")
        }
        try require(abs(click.time - 0.5) < 0.0001, "captured click timing was not anchored to video time")
        try require(abs(click.x - 0.5) < 0.0001, "captured click x-coordinate was not normalized")
        try require(abs(click.y - 0.25) < 0.0001, "captured click y-coordinate was not normalized")
        try require(
            trace.cursorSamples.last?.cursorKind == .iBeam,
            "event monitor did not persist an injected I-beam cursor sample"
        )

        var settings = ProjectSettings()
        settings.autoZoomEnabled = true
        let zooms = TimelineMath.generateZoomSegments(from: trace.clickEvents, duration: 2, settings: settings)
        try require(zooms.count == 1, "a captured click did not generate an automatic zoom")
    }
    #endif

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw E2EError.assertionFailed(message) }
    }

    private static func requireJSONObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw E2EError.assertionFailed("encoded settings were not a JSON object")
        }
        return object
    }

    private static func outputDirectory(from arguments: [String]) throws -> URL {
        guard let index = arguments.firstIndex(of: "--output-dir") else {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("FocusStudioE2E", isDirectory: true)
        }
        guard arguments.indices.contains(index + 1) else {
            throw E2EError.missingOutputDirectoryArgument
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    private static func argumentValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func makeProject(
        sourceURL: URL,
        specification: SyntheticVideoSpecification
    ) -> RecordingProject {
        var settings = ProjectSettings()
        settings.autoZoomEnabled = true
        settings.zoomScale = 1.85
        settings.zoomLeadIn = 0.12
        settings.zoomEaseIn = 0.28
        settings.zoomHold = 0.40
        settings.zoomEaseOut = 0.30
        settings.cursorScale = 1.25
        settings.cursorAnimation = .smooth
        settings.cursorAppearance = .highContrast
        settings.hideIdleCursor = false
        settings.showClickRing = true
        settings.backgroundStyle = .gradient
        settings.backgroundColor = "#7958FF"
        settings.secondaryBackgroundColor = "#18B8C9"
        settings.padding = 52
        settings.cornerRadius = 20
        settings.shadow = 0.36
        settings.aspectRatio = .wide
        settings.frameRate = specification.frameRate
        settings.exportWidth = specification.width

        let clicks = [
            ClickEvent(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                time: 0.68,
                x: 0.28,
                y: 0.34,
                button: .left
            ),
            ClickEvent(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                time: 1.30,
                x: 0.76,
                y: 0.68,
                button: .left
            )
        ]
        let samples = stride(from: 0.0, through: specification.duration, by: 0.08).map { time in
            let progress = time / specification.duration
            return CursorSample(
                time: time,
                x: 0.12 + progress * 0.76,
                y: 0.22 + 0.48 * (0.5 - 0.5 * cos(progress * .pi * 2)),
                cursorKind: (0.8...1.4).contains(time) ? .iBeam : .arrow
            )
        }
        let zooms = TimelineMath.generateZoomSegments(
            from: clicks,
            duration: specification.duration,
            settings: settings
        )

        // One narrated chapter spanning the click/zoom hold period (0.8–1.9 s),
        // fully faded in between 1.08 s and 1.62 s.
        let chapters = [
            DemoChapter(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000C4A1")!,
                start: 0.8,
                end: 1.9,
                title: "Chapter 1",
                caption: "Every click zooms in automatically"
            )
        ]

        return RecordingProject(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000E2E0")!,
            title: "FocusStudio deterministic E2E",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceVideoPath: sourceURL.path,
            duration: specification.duration,
            sourceWidth: specification.width,
            sourceHeight: specification.height,
            cursorSamples: samples,
            clickEvents: clicks,
            zoomSegments: zooms,
            chapters: chapters,
            settings: settings
        )
    }

    private static func validate(
        sourceURL: URL,
        renderedURL: URL,
        expected: VideoExportResult,
        project: RecordingProject
    ) async throws -> ValidationResult {
        let source = AVURLAsset(url: sourceURL)
        let output = AVURLAsset(url: renderedURL)
        let sourceAudioTracks = try await source.loadTracks(withMediaType: .audio)
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        let duration = try await output.load(.duration).seconds

        guard videoTracks.count == 1, let videoTrack = videoTracks.first else {
            throw E2EError.invalidVideoTrackCount(videoTracks.count)
        }
        guard !sourceAudioTracks.isEmpty, audioTracks.count == sourceAudioTracks.count,
              expected.includesAudio else {
            throw E2EError.audioWasNotPreserved(
                source: sourceAudioTracks.count,
                output: audioTracks.count,
                exporterReportedAudio: expected.includesAudio
            )
        }
        guard abs(duration - expected.duration) < 0.08 else {
            throw E2EError.durationMismatch(expected: expected.duration, actual: duration)
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let width = Int(abs(transformed.width).rounded())
        let height = Int(abs(transformed.height).rounded())
        guard width == expected.width, height == expected.height else {
            throw E2EError.sizeMismatch(
                expectedWidth: expected.width,
                expectedHeight: expected.height,
                actualWidth: width,
                actualHeight: height
            )
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: renderedURL.path)
        let outputBytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard outputBytes > 20_000 else { throw E2EError.outputTooSmall(outputBytes) }

        let imageGenerator = AVAssetImageGenerator(asset: output)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero
        let requestedTimes = [0.12, 0.72, 1.18, 1.62, 2.16, 2.25].map {
            CMTime(seconds: $0, preferredTimescale: 600)
        }
        let frameFingerprints = try await requestedTimes.asyncMap { time in
            let (image, _) = try await imageGenerator.image(at: time)
            return fingerprint(image)
        }
        let distinctFrameCount = Set(frameFingerprints).count
        guard distinctFrameCount >= 4 else {
            throw E2EError.renderedFramesWereNotDistinct(distinctFrameCount)
        }

        var zoomlessProject = project
        zoomlessProject.zoomSegments = []
        let zoomless = try await ProjectVideoRenderer.prepare(project: zoomlessProject)
        let zoomlessGenerator = makeImageGenerator(for: zoomless)

        let zoomTime = CMTime(seconds: 1, preferredTimescale: 600)
        let returnTime = CMTime(seconds: 2.25, preferredTimescale: 600)
        let (zoomedImage, _) = try await imageGenerator.image(at: zoomTime)
        let (zoomlessImage, _) = try await zoomlessGenerator.image(at: zoomTime)
        let zoomDifference = imageDifference(zoomedImage, zoomlessImage)
        let (returnedImage, _) = try await imageGenerator.image(at: returnTime)
        let (returnBaselineImage, _) = try await zoomlessGenerator.image(at: returnTime)
        let returnDifference = imageDifference(returnedImage, returnBaselineImage)
        try require(
            zoomDifference.meanAbsolute > returnDifference.meanAbsolute + 4,
            "exported active-zoom frame did not differ materially from the zoomless baseline"
        )

        var cursorlessProject = project
        cursorlessProject.cursorSamples = []
        cursorlessProject.clickEvents = []
        let cursorless = try await ProjectVideoRenderer.prepare(project: cursorlessProject)
        let cursorlessGenerator = makeImageGenerator(for: cursorless)
        let cursorTime = CMTime(seconds: 0.25, preferredTimescale: 600)
        let (cursorImage, _) = try await imageGenerator.image(at: cursorTime)
        let (cursorlessImage, _) = try await cursorlessGenerator.image(at: cursorTime)
        let cursorDifference = imageDifference(cursorImage, cursorlessImage)
        try require(
            cursorDifference.changedPixels >= 12,
            "exported cursor pixels were not visible above the compression baseline"
        )

        return ValidationResult(
            duration: duration,
            width: width,
            height: height,
            videoTrackCount: videoTracks.count,
            audioTrackCount: audioTracks.count,
            outputBytes: outputBytes,
            distinctFrameCount: distinctFrameCount,
            zoomFrameDifference: zoomDifference.meanAbsolute,
            returnFrameDifference: returnDifference.meanAbsolute,
            cursorChangedPixels: cursorDifference.changedPixels
        )
    }

    private static func validateClickFeedback(project: RecordingProject, outputURL: URL) async throws {
        var feedbackProject = project
        feedbackProject.title = "Click feedback — anchored overlapping ripples"
        feedbackProject.zoomSegments = []
        feedbackProject.settings.showClickRing = true
        feedbackProject.settings.hideIdleCursor = false
        feedbackProject.settings.clickAnimation = ClickAnimationSettings(
            colorHex: "#FF42B5", size: 1.45, duration: 0.85, intensity: 1, pressCursor: false
        )
        feedbackProject.clickEvents = [
            ClickEvent(time: 0.50, x: 0.26, y: 0.36, button: .left),
            ClickEvent(time: 0.64, x: 0.74, y: 0.64, button: .left),
            ClickEvent(time: 1.55, x: 0.50, y: 0.50, button: .left),
        ]
        feedbackProject.cursorSamples = [
            CursorSample(time: 0, x: 0.26, y: 0.36),
            CursorSample(time: 0.50, x: 0.26, y: 0.36),
            CursorSample(time: 0.64, x: 0.74, y: 0.64),
            CursorSample(time: 0.78, x: 0.85, y: 0.22),
            CursorSample(time: 1.10, x: 0.85, y: 0.22),
            CursorSample(time: 1.55, x: 0.50, y: 0.50),
            CursorSample(time: 2.4, x: 0.50, y: 0.50),
        ]
        let prepared = try await ProjectVideoRenderer.prepare(project: feedbackProject)
        let generator = makeImageGenerator(for: prepared)
        var baselineProject = feedbackProject
        baselineProject.settings.showClickRing = false
        let baseline = try await ProjectVideoRenderer.prepare(project: baselineProject)
        let baselineGenerator = makeImageGenerator(for: baseline)
        let time = CMTime(seconds: 0.8333333333, preferredTimescale: 600)
        let (image, _) = try await generator.image(at: time)
        let (baselineImage, _) = try await baselineGenerator.image(at: time)

        func region(at click: ClickEvent) -> CGRect {
            let frame = prepared.geometry.screenFrame
            return CGRect(
                x: frame.minX + CGFloat(click.x) * frame.width - 42,
                y: prepared.geometry.outputSize.height - frame.maxY + CGFloat(click.y) * frame.height - 42,
                width: 84,
                height: 84
            ).integral
        }
        for click in feedbackProject.clickEvents.prefix(2) {
            guard let focused = image.cropping(to: region(at: click)),
                  let blank = baselineImage.cropping(to: region(at: click)) else {
                throw E2EError.assertionFailed("could not inspect click feedback pixels")
            }
            try require(
                imageDifference(focused, blank).changedPixels > 100,
                "rapid clicks must remain visible at BOTH captured positions after the cursor has moved away"
            )
            let pixels = sampledPixels(focused, width: 84, height: 84)
            let baselinePixels = sampledPixels(blank, width: 84, height: 84)
            let tintedPixels = (0..<(84 * 84)).filter { index in
                let p = index * 4
                let deltaR = Int(pixels[p]) - Int(baselinePixels[p])
                let deltaB = Int(pixels[p + 2]) - Int(baselinePixels[p + 2])
                let deltaG = Int(pixels[p + 1]) - Int(baselinePixels[p + 1])
                return max(deltaR, deltaB) - deltaG > 20
            }.count
            try require(tintedPixels > 20, "rendered click feedback must use the user's chosen accent color")
        }
        var styleFingerprints = Set<UInt64>()
        for style in ClickAnimationStyle.allCases {
            feedbackProject.settings.clickAnimation?.style = style
            let styled = try await ProjectVideoRenderer.prepare(project: feedbackProject)
            let (styledImage, _) = try await makeImageGenerator(for: styled).image(at: time)
            styleFingerprints.insert(fingerprint(styledImage))
        }
        try require(styleFingerprints.count == ClickAnimationStyle.allCases.count, "ripple, halo, and pulse must render distinct visual effects")

        feedbackProject.settings.clickAnimation?.style = .ripple
        _ = try await ProjectVideoRenderer.export(project: feedbackProject, to: outputURL)
        let exportedGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
        exportedGenerator.requestedTimeToleranceBefore = .zero
        exportedGenerator.requestedTimeToleranceAfter = .zero
        let (exportedFrame, _) = try await exportedGenerator.image(at: time)
        try require(imageDifference(image, exportedFrame).meanAbsolute < 3, "click feedback preview and exported MP4 must match apart from compression")
        let frameURL = outputURL.deletingPathExtension().appendingPathExtension("png")
        guard let destination = CGImageDestinationCreateWithURL(frameURL as CFURL, "public.png" as CFString, 1, nil) else {
            throw E2EError.assertionFailed("could not create click feedback review frame")
        }
        CGImageDestinationAddImage(destination, exportedFrame, nil)
        try require(CGImageDestinationFinalize(destination), "could not save click feedback review frame")
    }

    private static func validateZoomTimingRendering(project: RecordingProject, outputDirectory: URL) async throws {
        var fast = project
        fast.title = "Zoom timing — fast transitions, long duration"
        fast.cursorSamples = []
        fast.clickEvents = []
        fast.typingActivity = []
        fast.settings.showClickRing = false
        fast.settings.motionBlur = 0
        fast.settings.screenAnimation = .focused
        let base = ZoomSegment(start: 0.25, end: 2.125, targetX: 0.32, targetY: 0.63, scale: 2, kind: .manual)
        var fastCue = ZoomTiming.applying(.easeIn(0.1), to: base, projectDuration: fast.duration, settings: fast.settings)
        fastCue = ZoomTiming.applying(.easeOut(0.1), to: fastCue, projectDuration: fast.duration, settings: fast.settings)
        fast.zoomSegments = [fastCue]
        var slow = fast
        slow.title = "Zoom timing — slow transitions, same duration"
        var slowCue = ZoomTiming.applying(.easeIn(0.8), to: fastCue, projectDuration: slow.duration, settings: slow.settings)
        slowCue = ZoomTiming.applying(.easeOut(0.8), to: slowCue, projectDuration: slow.duration, settings: slow.settings)
        slow.zoomSegments = [slowCue]
        var brief = fast
        brief.title = "Zoom timing — same speed, shorter duration"
        brief.zoomSegments = [ZoomTiming.applying(.duration(1), to: fastCue, projectDuration: brief.duration, settings: brief.settings)]
        var inheritedGentle = fast
        inheritedGentle.title = "Zoom timing — inherited seconds with gentle curve"
        inheritedGentle.settings.screenAnimation = .gentle
        inheritedGentle.settings.zoomEaseIn = 0.5
        inheritedGentle.settings.zoomEaseOut = 0.5
        inheritedGentle.zoomSegments = [base]

        let variants: [(String, RecordingProject)] = [("fast", fast), ("slow", slow), ("brief", brief), ("inherited-gentle", inheritedGentle)]
        var previews: [String: AVAssetImageGenerator] = [:]
        var encoded: [String: AVAssetImageGenerator] = [:]
        var outputPaths: [String: String] = [:]
        for (name, editedProject) in variants {
            // Save/reopen before rendering so the test covers persisted edits.
            let restored = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(editedProject))
            let outputURL = outputDirectory.appendingPathComponent("focus-studio-zoom-timing-\(name).mp4")
            previews[name] = makeImageGenerator(for: try await ProjectVideoRenderer.prepare(project: restored))
            let result = try await ProjectVideoRenderer.export(project: restored, to: outputURL)
            try require(result.width == project.settings.exportWidth && abs(result.duration - project.duration) < 0.08, "timing edits must not alter the recording's export dimensions or duration")
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            encoded[name] = generator
            outputPaths[name] = outputURL.path
        }
        let probes = [0.5, 0.75, 1.125, 1.5, 1.625, 1.875, 2.25]
        var maximumPreviewExportDifference = 0.0
        var frameComparisons: [ZoomTimingFrameComparison] = []
        for seconds in probes {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            var frames: [String: CGImage] = [:]
            for (name, _) in variants {
                let (previewFrame, _) = try await previews[name]!.image(at: time)
                let (encodedFrame, _) = try await encoded[name]!.image(at: time)
                let difference = imageDifference(previewFrame, encodedFrame).meanAbsolute
                maximumPreviewExportDifference = max(maximumPreviewExportDifference, difference)
                try require(difference < 3, "\(name) timing edit preview/export diverged at \(seconds)s beyond video compression")
                frames[name] = encodedFrame
            }
            let speedDifference = imageDifference(frames["fast"]!, frames["slow"]!).meanAbsolute
            let durationDifference = imageDifference(frames["fast"]!, frames["brief"]!).meanAbsolute
            if seconds == 0.5 || seconds == 1.875 {
                try require(speedDifference > 3, "different per-block entry/exit durations must visibly affect actual encoded frames at \(seconds)s")
            }
            if seconds == 1.5 {
                try require(durationDifference > 5, "extending a block must visibly retain zoom after the shorter block has returned to overview")
                try writeReviewFrame(frames["fast"]!, to: outputDirectory.appendingPathComponent("focus-studio-zoom-timing-long-hold.png"))
                try writeReviewFrame(frames["brief"]!, to: outputDirectory.appendingPathComponent("focus-studio-zoom-timing-short-return.png"))
            }
            if seconds == 0.5 {
                try writeReviewFrame(frames["fast"]!, to: outputDirectory.appendingPathComponent("focus-studio-zoom-timing-fast-entry.png"))
                try writeReviewFrame(frames["slow"]!, to: outputDirectory.appendingPathComponent("focus-studio-zoom-timing-slow-entry.png"))
            }
            if seconds == 2.25 {
                try require(speedDifference < 2 && durationDifference < 2, "all timing variants must return to the same overview after their end time")
            }
            if seconds == 0.75 || seconds == 1.625 {
                try require(imageDifference(frames["fast"]!, frames["inherited-gentle"]!).meanAbsolute < 2, "Gentle style must honor the displayed inherited 0.5-second entry/exit durations without hidden renderer multipliers")
            }
            frameComparisons.append(ZoomTimingFrameComparison(time: seconds, speedDifference: speedDifference, durationDifference: durationDifference))
        }
        let timingVariants = variants.map { name, project in
            let timing = ZoomTiming.resolve(project.zoomSegments[0], settings: project.settings)
            return ZoomTimingVariantCheck(name: name, start: timing.start, end: timing.end, duration: timing.duration, easeIn: timing.easeIn, hold: timing.hold, easeOut: timing.easeOut)
        }
        let report = ZoomTimingValidationReport(status: "PASS", outputPaths: outputPaths, variants: timingVariants, maximumPreviewExportDifference: maximumPreviewExportDifference, frameComparisons: frameComparisons)
        try Data(try jsonString(report).utf8).write(to: outputDirectory.appendingPathComponent("focus-studio-zoom-timing-report.json"), options: .atomic)
    }

    /// Chapter captions are part of the shared compositor: the pill must show
    /// only while its chapter is active, fade in, honour position/enabled
    /// state, render CJK text, and match between preview and export.
    private static func validateChapterCaptionRendering(
        project: RecordingProject,
        exportedURL: URL,
        outputDirectory: URL
    ) async throws -> Double {
        guard let chapter = project.chapters?.first else {
            throw E2EError.assertionFailed("the synthetic project must carry a chapter")
        }
        var baselineProject = project
        baselineProject.chapters = nil
        let captioned = makeImageGenerator(for: try await ProjectVideoRenderer.prepare(project: project))
        let baseline = makeImageGenerator(for: try await ProjectVideoRenderer.prepare(project: baselineProject))
        let sampleRows = 135

        // Frame-aligned probes (k/24) keep composition and encoded frames in step.
        let insideTime = CMTime(value: 32, timescale: 24)
        let (captionFrame, _) = try await captioned.image(at: insideTime)
        let (baselineFrame, _) = try await baseline.image(at: insideTime)
        let inside = imageDifference(captionFrame, baselineFrame)
        try require(
            inside.meanAbsolute > 0.3 && inside.changedPixels >= 80,
            "the caption pill must visibly change the frame during its chapter (mean \(inside.meanAbsolute), pixels \(inside.changedPixels))"
        )
        guard let bottomRows = changedRowBounds(captionFrame, baselineFrame) else {
            throw E2EError.assertionFailed("could not locate the caption pill")
        }
        try require(
            bottomRows.first >= Int(Double(sampleRows) * 0.6),
            "a bottom caption must only touch the lower part of the canvas (rows \(bottomRows))"
        )

        var outsideDifference = 0.0
        for frame in [7, 54] as [CMTimeValue] {
            let time = CMTime(value: frame, timescale: 24)
            let (withChapter, _) = try await captioned.image(at: time)
            let (without, _) = try await baseline.image(at: time)
            let difference = imageDifference(withChapter, without).meanAbsolute
            outsideDifference = max(outsideDifference, difference)
            try require(difference < 0.05, "frames outside the chapter must be unchanged at \(time.seconds)s (\(difference))")
        }

        // 0.875 s is 0.075 s into the chapter: the pill is at roughly 12% opacity.
        let fadeTime = CMTime(value: 21, timescale: 24)
        let (fadeFrame, _) = try await captioned.image(at: fadeTime)
        let (fadeBaseline, _) = try await baseline.image(at: fadeTime)
        let fading = imageDifference(fadeFrame, fadeBaseline).meanAbsolute
        try require(
            fading > 0.02 && fading < inside.meanAbsolute * 0.6,
            "the caption must fade in rather than pop (fading \(fading), visible \(inside.meanAbsolute))"
        )

        let exportedGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: exportedURL))
        exportedGenerator.appliesPreferredTrackTransform = true
        exportedGenerator.requestedTimeToleranceBefore = .zero
        exportedGenerator.requestedTimeToleranceAfter = .zero
        let (exportedFrame, _) = try await exportedGenerator.image(at: insideTime)
        let previewExportDifference = imageDifference(captionFrame, exportedFrame).meanAbsolute
        try require(previewExportDifference < 3, "caption preview and exported MP4 must match apart from compression (\(previewExportDifference))")
        let (exportedBaselineTime, _) = try await exportedGenerator.image(at: CMTime(value: 7, timescale: 24))
        let (previewBaselineTime, _) = try await captioned.image(at: CMTime(value: 7, timescale: 24))
        try require(imageDifference(exportedBaselineTime, previewBaselineTime).meanAbsolute < 3, "exported frames before the chapter must still match the preview")
        let reviewURL = outputDirectory.appendingPathComponent("focus-studio-chapter-caption.png")
        try writeReviewFrame(exportedFrame, to: reviewURL)

        // Top placement, larger size, no number, Chinese text.
        var topProject = project
        topProject.settings.captionStyle = CaptionStyle(position: .top, scale: 1.2, showsChapterNumber: false)
        topProject.chapters = [DemoChapter(start: chapter.start, end: chapter.end, title: "第一章", caption: "每次点击都会自动放大")]
        let restoredTop = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(topProject))
        try require(restoredTop.chapters == topProject.chapters && restoredTop.settings.captionStyle == topProject.settings.captionStyle, "chapters and caption style must survive save/reopen")
        let top = makeImageGenerator(for: try await ProjectVideoRenderer.prepare(project: restoredTop))
        let (topFrame, _) = try await top.image(at: insideTime)
        let topDifference = imageDifference(topFrame, baselineFrame)
        try require(topDifference.changedPixels >= 80, "a Chinese caption at the top must render visibly (\(topDifference.changedPixels) pixels)")
        guard let topRows = changedRowBounds(topFrame, baselineFrame) else {
            throw E2EError.assertionFailed("could not locate the top caption pill")
        }
        try require(
            topRows.last <= Int(Double(sampleRows) * 0.4),
            "a top caption must only touch the upper part of the canvas (rows \(topRows))"
        )
        try require(imageDifference(topFrame, captionFrame).meanAbsolute > 0.3, "moving the caption to the top must change the frame")
        try writeReviewFrame(topFrame, to: outputDirectory.appendingPathComponent("focus-studio-chapter-caption-top.png"))

        var disabledProject = project
        disabledProject.chapters?[0].isEnabled = false
        let disabled = makeImageGenerator(for: try await ProjectVideoRenderer.prepare(project: disabledProject))
        let (disabledFrame, _) = try await disabled.image(at: insideTime)
        try require(imageDifference(disabledFrame, baselineFrame).meanAbsolute < 0.05, "a disabled chapter must not render")

        let report = ChapterCaptionValidationReport(
            status: "PASS",
            visibleDifference: inside.meanAbsolute,
            visibleChangedPixels: inside.changedPixels,
            fadeDifference: fading,
            outsideDifference: outsideDifference,
            previewExportDifference: previewExportDifference,
            bottomRows: [bottomRows.first, bottomRows.last],
            topRows: [topRows.first, topRows.last],
            reviewFramePath: reviewURL.path
        )
        try Data(try jsonString(report).utf8).write(
            to: outputDirectory.appendingPathComponent("focus-studio-chapter-caption-report.json"),
            options: .atomic
        )
        return inside.meanAbsolute
    }

    /// First and last sampled rows (0 = top) where two frames differ noticeably.
    private static func changedRowBounds(_ lhs: CGImage, _ rhs: CGImage) -> (first: Int, last: Int)? {
        let width = 240
        let height = 135
        let lhsPixels = sampledPixels(lhs, width: width, height: height)
        let rhsPixels = sampledPixels(rhs, width: width, height: height)
        var first: Int?
        var last: Int?
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                let red = abs(Int(lhsPixels[offset]) - Int(rhsPixels[offset]))
                let green = abs(Int(lhsPixels[offset + 1]) - Int(rhsPixels[offset + 1]))
                let blue = abs(Int(lhsPixels[offset + 2]) - Int(rhsPixels[offset + 2]))
                if max(red, green, blue) >= 24 {
                    if first == nil { first = row }
                    last = row
                    break
                }
            }
        }
        guard let first, let last else { return nil }
        return (first, last)
    }

    private static func validateTypingFocusRendering(outputDirectory: URL) async throws {
        let sourceURL = outputDirectory.appendingPathComponent("synthetic-typing-input.mp4")
        let outputURL = outputDirectory.appendingPathComponent("focus-studio-typing-focus.mp4")
        for url in [sourceURL, outputURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var specification = SyntheticVideoSpecification()
        specification.duration = 7
        specification.includesAudio = false
        try await SyntheticGridVideoWriter.write(specification, to: sourceURL)
        var project = makeProject(sourceURL: sourceURL, specification: specification)
        project.title = "Typing focus — keep input zoomed until typing stops"
        project.settings.zoomEaseIn = 0.42
        project.settings.zoomEaseOut = 0.60
        project.settings.typingZoom = TypingZoomSettings()
        project.settings.showClickRing = false
        project.settings.motionBlur = 0
        project.clickEvents = [ClickEvent(time: 0.35, x: 0.30, y: 0.65, button: .left)]
        project.typingActivity = stride(from: 0.6, through: 3.8, by: 0.2).map {
            TypingActivity(time: $0, x: 0.30, y: 0.65)
        }
        project.cursorSamples = [
            CursorSample(time: 0, x: 0.3, y: 0.65, cursorKind: .iBeam),
            CursorSample(time: 1.4, x: 0.3, y: 0.65, cursorKind: .iBeam),
            CursorSample(time: 1.8, x: 0.8, y: 0.2),
            CursorSample(time: 7, x: 0.8, y: 0.2),
        ]
        TimelineMath.regenerateAutomaticZoomSegments(in: &project)
        _ = try await ProjectVideoRenderer.export(project: project, to: outputURL)
        let actual = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
        actual.requestedTimeToleranceBefore = .zero
        actual.requestedTimeToleranceAfter = .zero
        var overview = project
        overview.zoomSegments = []
        let baseline = makeImageGenerator(for: try await ProjectVideoRenderer.prepare(project: overview))
        let holdTime = CMTime(seconds: 3.0, preferredTimescale: 600)
        let returnTime = CMTime(seconds: 6.2, preferredTimescale: 600)
        let (held, _) = try await actual.image(at: holdTime)
        let (heldBaseline, _) = try await baseline.image(at: holdTime)
        let (returned, _) = try await actual.image(at: returnTime)
        let (returnBaseline, _) = try await baseline.image(at: returnTime)
        try require(imageDifference(held, heldBaseline).meanAbsolute > 8, "encoded video must remain zoomed several seconds into typing even after cursor moves away")
        try require(imageDifference(returned, returnBaseline).meanAbsolute < 3, "encoded video must restore overview after typing idle and ease-out")
        let frameURL = outputDirectory.appendingPathComponent("focus-studio-typing-focus.png")
        guard let destination = CGImageDestinationCreateWithURL(frameURL as CFURL, "public.png" as CFString, 1, nil) else {
            throw E2EError.assertionFailed("could not create typing focus review frame")
        }
        CGImageDestinationAddImage(destination, held, nil)
        try require(CGImageDestinationFinalize(destination), "could not save typing focus review frame")
    }

    /// Pure synthetic evidence for rapid-click target ownership and resuming
    /// typing after a toolbar click. Never loads or rewrites user recordings.
    private static func validateInputHandoffRendering(outputDirectory: URL) async throws {
        var specification = SyntheticVideoSpecification()
        specification.duration = 7
        specification.includesAudio = false
        let sourceURL = outputDirectory.appendingPathComponent("synthetic-typing-input.mp4")
        let outputURL = outputDirectory.appendingPathComponent("focus-studio-input-handoff.mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) { try FileManager.default.removeItem(at: outputURL) }
        var project = makeProject(sourceURL: sourceURL, specification: specification)
        project.title = "Synthetic rapid clicks and resumed input focus"
        project.settings.zoomEaseIn = 0.42
        project.settings.zoomEaseOut = 0.60
        project.settings.zoomHold = 0.9
        project.settings.typingZoom = TypingZoomSettings()
        project.settings.motionBlur = 0
        project.clickEvents = [
            ClickEvent(time: 0.35, x: 0.30, y: 0.65, button: .left),
            ClickEvent(time: 0.55, x: 0.76, y: 0.28, button: .left),
            ClickEvent(time: 2.20, x: 0.76, y: 0.28, button: .left),
        ]
        project.typingActivity = stride(from: 0.85, through: 4.0, by: 0.2).map {
            TypingActivity(time: $0, x: 0.30, y: 0.65)
        }
        project.cursorSamples = [
            CursorSample(time: 0, x: 0.3, y: 0.65),
            CursorSample(time: 0.35, x: 0.3, y: 0.65),
            CursorSample(time: 0.55, x: 0.76, y: 0.28),
            CursorSample(time: 0.85, x: 0.3, y: 0.65, cursorKind: .iBeam),
            CursorSample(time: 2.0, x: 0.3, y: 0.65, cursorKind: .iBeam),
            CursorSample(time: 2.2, x: 0.76, y: 0.28),
            CursorSample(time: 2.8, x: 0.85, y: 0.18),
            CursorSample(time: 7, x: 0.85, y: 0.18),
        ]
        project.chapters = [
            DemoChapter(start: 0, end: 0.85, title: "快速点击", caption: "每次点击保留自己的焦点"),
            DemoChapter(start: 0.85, end: 2.2, title: "持续输入", caption: "光标离开，输入框仍保持放大"),
            DemoChapter(start: 2.2, end: 4.6, title: "焦点交接", caption: "点击工具栏后继续输入，镜头回到输入框"),
            DemoChapter(start: 5.9, end: 7, title: "回到全景", caption: "停止输入后平滑收回"),
        ]
        TimelineMath.regenerateAutomaticZoomSegments(in: &project)
        try require(project.zoomSegments.count == 5, "synthetic input handoff needs separate rapid clicks and resumed typing cues")
        _ = try await ProjectVideoRenderer.export(project: project, to: outputURL)
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
        exported.requestedTimeToleranceBefore = .zero
        exported.requestedTimeToleranceAfter = .zero
        let preview = makeImageGenerator(for: try await ProjectVideoRenderer.prepare(project: project))
        var overviewProject = project
        overviewProject.zoomSegments = []
        let overview = makeImageGenerator(for: try await ProjectVideoRenderer.prepare(project: overviewProject))
        var probes: [[String: Any]] = []
        for (name, frame): (String, CMTimeValue) in [("first-click", 9), ("resumed-input", 72), ("returned", 156)] {
            let time = CMTime(value: frame, timescale: 24)
            let state = TimelineMath.zoomState(at: time.seconds, segments: project.zoomSegments, settings: project.settings)
            let (actual, _) = try await exported.image(at: time)
            let (expected, _) = try await preview.image(at: time)
            let (wide, _) = try await overview.image(at: time)
            let parity = imageDifference(actual, expected).meanAbsolute
            let overviewDifference = imageDifference(actual, wide).meanAbsolute
            try require(parity < 3, "input handoff preview and MP4 must share the same camera math at \(time.seconds)s")
            if name == "first-click" {
                try require(state.centerX < 0.5, "a future rapid click must not rewrite the first rendered camera target")
            } else if name == "resumed-input" {
                try require(abs(state.centerX - 0.3) < 0.0001 && state.scale > 1.8 && overviewDifference > 8,
                    "resumed input must promptly own both focus and full zoom in the actual output")
            } else {
                try require(state.scale == 1 && overviewDifference < 3, "input handoff must finally restore the overview")
            }
            try writeReviewFrame(actual, to: outputDirectory.appendingPathComponent("focus-studio-input-handoff-\(name).png"))
            probes.append(["name": name, "time": time.seconds, "scale": state.scale, "centerX": state.centerX,
                           "previewExportDifference": parity, "overviewDifference": overviewDifference])
        }
        let report: [String: Any] = ["status": "PASS", "synthetic": true, "outputPath": outputURL.path,
                                    "zoomSegmentCount": project.zoomSegments.count, "probes": probes]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDirectory.appendingPathComponent("focus-studio-input-handoff-report.json"), options: .atomic)
    }

    private static func validateCropRendering(
        project: RecordingProject,
        outputURL: URL
    ) async throws {
        var topCropProject = project
        topCropProject.zoomSegments = []
        topCropProject.cursorSamples = []
        topCropProject.clickEvents = []
        topCropProject.settings.aspectRatio = .automatic
        topCropProject.settings.exportWidth = project.sourceWidth
        topCropProject.settings.padding = 0
        topCropProject.settings.cornerRadius = 0
        topCropProject.settings.shadow = 0
        topCropProject.settings.motionBlur = 0
        // Exactly 60 pixels in the 540p deterministic source, leaving a 960x480 frame.
        topCropProject.settings.sourceCropInsets = SourceCropInsets(top: 1.0 / 9.0)

        let topGeometry = ProjectVideoRenderer.geometry(for: topCropProject)
        try require(
            topGeometry.outputSize == CGSize(width: 960, height: 480),
            "automatic canvas ratio must follow the cropped source dimensions"
        )
        try require(
            abs(topGeometry.screenFrame.minX) < 0.001
                && abs(topGeometry.screenFrame.minY) < 0.001
                && abs(topGeometry.screenFrame.width - 960) < 0.001
                && abs(topGeometry.screenFrame.height - 480) < 0.001,
            "an automatic zero-padding crop must fill its output canvas"
        )

        var bottomCropProject = topCropProject
        bottomCropProject.settings.sourceCropInsets = SourceCropInsets(bottom: 1.0 / 9.0)
        let export = try await ProjectVideoRenderer.export(project: topCropProject, to: outputURL)
        try require(
            export.width == 960 && export.height == 480,
            "clean browser export must use the cropped webpage aspect ratio (got \(export.width)x\(export.height))"
        )

        let exportedAsset = AVURLAsset(url: outputURL)
        let exportedTracks = try await exportedAsset.loadTracks(withMediaType: .video)
        guard let exportedTrack = exportedTracks.first else {
            throw E2EError.assertionFailed("clean browser export has no video track")
        }
        let naturalSize = try await exportedTrack.load(.naturalSize)
        let preferredTransform = try await exportedTrack.load(.preferredTransform)
        let encodedBounds = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        try require(
            abs(encodedBounds.width - 960) < 0.01 && abs(encodedBounds.height - 480) < 0.01,
            "encoded clean browser track dimensions must match the renderer result"
        )

        let bottomPrepared = try await ProjectVideoRenderer.prepare(project: bottomCropProject)
        let topGenerator = AVAssetImageGenerator(asset: exportedAsset)
        topGenerator.appliesPreferredTrackTransform = true
        topGenerator.requestedTimeToleranceBefore = .zero
        topGenerator.requestedTimeToleranceAfter = .zero
        let bottomGenerator = makeImageGenerator(for: bottomPrepared)
        let probeTime = CMTime(seconds: 0.72, preferredTimescale: 600)
        let (topImage, _) = try await topGenerator.image(at: probeTime)
        let (bottomImage, _) = try await bottomGenerator.image(at: probeTime)
        let difference = imageDifference(topImage, bottomImage)
        try require(
            difference.meanAbsolute > 2 && difference.changedPixels > 250,
            "top and bottom crop renders must select visibly different source regions"
        )

        // The synthetic source has two high-chroma bars in its top 60 pixels:
        // a red macOS-menu marker and an orange browser-toolbar marker. A clean
        // webpage export removes both; the inverse crop deliberately keeps both
        // as a control so this test detects crop-direction regressions.
        let cleanMarkers = chromeMarkerPixelCount(topImage)
        let controlMarkers = chromeMarkerPixelCount(bottomImage)
        try require(
            controlMarkers > 1_500,
            "synthetic browser fixture did not expose enough menu/toolbar marker pixels"
        )
        try require(
            cleanMarkers < max(12, controlMarkers / 40),
            "clean browser export still contains menu-bar or browser-toolbar pixels (clean \(cleanMarkers), control \(controlMarkers))"
        )
    }

    private static func validateAudioFinishing(
        project: RecordingProject,
        audioFixtureURL: URL,
        outputURL: URL
    ) async throws {
        var audioProject = project
        audioProject.settings.productDemoAudio = ProductDemoAudioSettings(
            sourceAudioVolume: 0.30,
            backgroundMusicPath: audioFixtureURL.path,
            backgroundMusicVolume: 0.24,
            backgroundMusicFadeIn: 0.20,
            backgroundMusicFadeOut: 0.30,
            clickSoundEnabled: true,
            clickSoundVolume: 0.35,
            clickSoundPath: audioFixtureURL.path,
            zoomTransitionSoundEnabled: true,
            zoomTransitionSoundVolume: 0.22,
            zoomTransitionSoundPath: audioFixtureURL.path
        )
        let prepared = try await ProjectVideoRenderer.prepare(project: audioProject)
        try require(prepared.audioMix != nil, "audio finishing must create a preview audio mix")
        let previewHasAudioMix = await MainActor.run {
            prepared.makePlayerItem().audioMix != nil
        }
        try require(
            previewHasAudioMix,
            "the preview player item must receive the prepared audio mix"
        )

        let result = try await ProjectVideoRenderer.export(project: audioProject, to: outputURL)
        let asset = AVURLAsset(url: outputURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        try require(result.includesAudio, "audio finishing export must report included audio")
        try require(!audioTracks.isEmpty, "audio finishing export must contain an audio track")
        try require(
            abs(duration - project.duration) < 0.08,
            "looped background music must be trimmed to the project duration"
        )
    }

    private static func validateImageBackground(
        project: RecordingProject,
        imageURL: URL,
        outputURL: URL
    ) async throws {
        var unblurredProject = project
        unblurredProject.settings.backgroundStyle = .image
        unblurredProject.settings.backgroundImagePath = imageURL.path
        unblurredProject.settings.backgroundBlur = 0
        unblurredProject.settings.backgroundBrightness = -0.12
        unblurredProject.settings.padding = 120
        unblurredProject.settings.shadow = 0
        unblurredProject.cursorSamples = []
        unblurredProject.clickEvents = []
        unblurredProject.zoomSegments = []

        let unblurred = try await ProjectVideoRenderer.prepare(project: unblurredProject)
        let unblurredGenerator = makeImageGenerator(for: unblurred)

        var blurredProject = unblurredProject
        blurredProject.settings.backgroundBlur = 24
        let result = try await ProjectVideoRenderer.export(project: blurredProject, to: outputURL)
        try require(
            result.width == project.settings.exportWidth && result.height > 0,
            "an image background export must preserve the configured canvas"
        )

        let outputAsset = AVURLAsset(url: outputURL)
        let blurredGenerator = AVAssetImageGenerator(asset: outputAsset)
        blurredGenerator.appliesPreferredTrackTransform = true
        blurredGenerator.requestedTimeToleranceBefore = .zero
        blurredGenerator.requestedTimeToleranceAfter = .zero
        let probeTime = CMTime(seconds: 0.24, preferredTimescale: 600)
        let (unblurredImage, _) = try await unblurredGenerator.image(at: probeTime)
        let (blurredImage, _) = try await blurredGenerator.image(at: probeTime)
        let difference = imageDifference(unblurredImage, blurredImage)
        try require(
            difference.meanAbsolute > 0.15 && difference.changedPixels > 100,
            "the image-background blur setting must visibly affect rendered pixels"
        )
    }

    private static func writeBackgroundFixture(to url: URL) throws {
        let width = 640
        let height = 360
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw E2EError.assertionFailed("could not create the image-background fixture context")
        }

        let cell = 30
        for y in stride(from: 0, to: height, by: cell) {
            for x in stride(from: 0, to: width, by: cell) {
                let alternate = ((x / cell) + (y / cell)).isMultiple(of: 2)
                context.setFillColor(
                    alternate
                        ? CGColor(red: 0.98, green: 0.12, blue: 0.52, alpha: 1)
                        : CGColor(red: 0.05, green: 0.78, blue: 0.92, alpha: 1)
                )
                context.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  "public.png" as CFString,
                  1,
                  nil
              ) else {
            throw E2EError.assertionFailed("could not create the image-background fixture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw E2EError.assertionFailed("could not write the image-background fixture")
        }
    }

    private static func makeImageGenerator(for prepared: PreparedProjectVideo) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: prepared.asset)
        generator.videoComposition = prepared.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    private static func imageDifference(_ lhs: CGImage, _ rhs: CGImage) -> ImageDifference {
        let lhsPixels = sampledPixels(lhs, width: 240, height: 135)
        let rhsPixels = sampledPixels(rhs, width: 240, height: 135)
        var totalDifference = 0
        var changedPixels = 0
        for pixel in 0..<(240 * 135) {
            let offset = pixel * 4
            let red = abs(Int(lhsPixels[offset]) - Int(rhsPixels[offset]))
            let green = abs(Int(lhsPixels[offset + 1]) - Int(rhsPixels[offset + 1]))
            let blue = abs(Int(lhsPixels[offset + 2]) - Int(rhsPixels[offset + 2]))
            totalDifference += red + green + blue
            if max(red, green, blue) >= 24 { changedPixels += 1 }
        }
        let componentCount = Double(240 * 135 * 3)
        return ImageDifference(
            meanAbsolute: Double(totalDifference) / componentCount,
            changedPixels: changedPixels
        )
    }

    private static func sampledPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    private static func chromeMarkerPixelCount(_ image: CGImage) -> Int {
        let width = 240
        let height = 135
        let pixels = sampledPixels(image, width: width, height: height)
        var count = 0
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            let menuMarker = red >= 175 && green <= 90 && blue <= 100
            let toolbarMarker = red >= 185 && green >= 90 && green <= 190 && blue <= 90
            if menuMarker || toolbarMarker { count += 1 }
        }
        return count
    }

    private static func fingerprint(_ image: CGImage) -> UInt64 {
        let sampleWidth = 64
        let sampleHeight = 36
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: sampleWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        }
        return pixels.reduce(UInt64(1_469_598_103_934_665_603)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func jsonString<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw E2EError.jsonEncodingFailed
        }
        return string
    }
}

private struct SyntheticVideoSpecification {
    let width = 960
    let height = 540
    let frameRate = 24
    var duration = 2.4
    var includesAudio = true
    let audioSampleRate = 48_000
}

private enum SyntheticGridVideoWriter {
    static func write(_ specification: SyntheticVideoSpecification, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: specification.width,
                AVVideoHeightKey: specification.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 2_400_000,
                    AVVideoMaxKeyFrameIntervalKey: specification.frameRate
                ]
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: specification.width,
                kCVPixelBufferHeightKey as String: specification.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: specification.audioSampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000
            ]
        )
        audioInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput), !specification.includesAudio || writer.canAdd(audioInput) else {
            throw E2EError.couldNotAddSyntheticWriterInputs
        }
        writer.add(videoInput)
        if specification.includesAudio { writer.add(audioInput) }
        guard writer.startWriting() else {
            throw E2EError.writerFailed(writer.error?.localizedDescription ?? "unknown start error")
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int((specification.duration * Double(specification.frameRate)).rounded())
        let formatDescription = specification.includesAudio
            ? try makeAudioFormatDescription(sampleRate: specification.audioSampleRate)
            : nil
        let totalSamples = Int(specification.duration * Double(specification.audioSampleRate))
        var sampleOffset = 0
        var frameIndex = 0
        func appendFrame() throws {
            guard let pool = adaptor.pixelBufferPool else {
                throw E2EError.pixelBufferPoolUnavailable
            }
            var maybeBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer = maybeBuffer else {
                throw E2EError.pixelBufferCreationFailed(status)
            }
            drawGrid(
                into: pixelBuffer,
                frameIndex: frameIndex,
                frameCount: frameCount,
                width: specification.width,
                height: specification.height
            )
            let presentationTime = CMTime(
                value: CMTimeValue(frameIndex),
                timescale: CMTimeScale(specification.frameRate)
            )
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw E2EError.writerFailed(writer.error?.localizedDescription ?? "video append failed")
            }
            frameIndex += 1
        }
        func appendAudio(_ formatDescription: CMAudioFormatDescription) throws {
            let count = min(1_024, totalSamples - sampleOffset)
            let sampleBuffer = try makeToneSampleBuffer(
                offset: sampleOffset,
                count: count,
                sampleRate: specification.audioSampleRate,
                formatDescription: formatDescription
            )
            guard audioInput.append(sampleBuffer) else {
                throw E2EError.writerFailed(writer.error?.localizedDescription ?? "audio append failed")
            }
            sampleOffset += count
        }
        // AVAssetWriter's offline inputs backpressure each other, and the
        // encoders hold samples back, so waiting on one input while the writer
        // waits for the other can deadlock. Feed whichever input is ready and
        // finish each input as soon as all of its samples are in.
        var videoDone = false
        var audioDone = formatDescription == nil
        var lastProgress = ProcessInfo.processInfo.systemUptime
        while !videoDone || !audioDone {
            var progressed = false
            if !videoDone, videoInput.isReadyForMoreMediaData {
                if frameIndex < frameCount { try appendFrame() }
                if frameIndex >= frameCount {
                    videoInput.markAsFinished()
                    videoDone = true
                }
                progressed = true
            }
            if !audioDone, let formatDescription, audioInput.isReadyForMoreMediaData {
                if sampleOffset < totalSamples { try appendAudio(formatDescription) }
                if sampleOffset >= totalSamples {
                    audioInput.markAsFinished()
                    audioDone = true
                }
                progressed = true
            }
            if progressed {
                lastProgress = ProcessInfo.processInfo.systemUptime
                continue
            }
            guard writer.status == .writing else {
                throw E2EError.writerFailed(writer.error?.localizedDescription ?? "writer stopped")
            }
            guard ProcessInfo.processInfo.systemUptime < lastProgress + 15 else {
                writer.cancelWriting()
                throw E2EError.writerFailed("synthetic writer readiness timed out")
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw E2EError.writerFailed(writer.error?.localizedDescription ?? "unknown finish error")
        }
    }

    static func writeToneAudio(
        duration: Double,
        sampleRate: Int,
        to url: URL
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000
            ]
        )
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw E2EError.couldNotAddSyntheticWriterInputs
        }
        writer.add(audioInput)
        guard writer.startWriting() else {
            throw E2EError.writerFailed(writer.error?.localizedDescription ?? "audio start failed")
        }
        writer.startSession(atSourceTime: .zero)

        let formatDescription = try makeAudioFormatDescription(sampleRate: sampleRate)
        let totalSamples = Int(duration * Double(sampleRate))
        let chunkSize = 1_024
        var sampleOffset = 0
        while sampleOffset < totalSamples {
            try await waitUntilReady(audioInput, writer: writer)
            let count = min(chunkSize, totalSamples - sampleOffset)
            let sampleBuffer = try makeToneSampleBuffer(
                offset: sampleOffset,
                count: count,
                sampleRate: sampleRate,
                formatDescription: formatDescription
            )
            guard audioInput.append(sampleBuffer) else {
                throw E2EError.writerFailed(writer.error?.localizedDescription ?? "audio append failed")
            }
            sampleOffset += count
        }
        audioInput.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw E2EError.writerFailed(writer.error?.localizedDescription ?? "audio finish failed")
        }
    }

    private static func waitUntilReady(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) async throws {
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 15
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw E2EError.writerFailed(writer.error?.localizedDescription ?? "writer stopped")
            }
            guard ProcessInfo.processInfo.systemUptime < readyDeadline else {
                writer.cancelWriting()
                throw E2EError.writerFailed("synthetic \(input.mediaType.rawValue) writer readiness timed out")
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private static func drawGrid(
        into pixelBuffer: CVPixelBuffer,
        frameIndex: Int,
        frameCount: Int,
        width: Int,
        height: Int
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }

        context.setFillColor(CGColor(red: 0.055, green: 0.063, blue: 0.086, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineWidth(2)
        for x in stride(from: 0, through: width, by: 80) {
            let major = x.isMultiple(of: 240)
            context.setStrokeColor(CGColor(
                red: major ? 0.35 : 0.20,
                green: major ? 0.42 : 0.24,
                blue: major ? 0.60 : 0.34,
                alpha: 1
            ))
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: height))
            context.strokePath()
        }
        for y in stride(from: 0, through: height, by: 60) {
            let major = y.isMultiple(of: 180)
            context.setStrokeColor(CGColor(
                red: major ? 0.35 : 0.20,
                green: major ? 0.42 : 0.24,
                blue: major ? 0.60 : 0.34,
                alpha: 1
            ))
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: width, y: y))
            context.strokePath()
        }

        // Browser-clean-capture fixture: these two bars represent the desktop
        // menu bar and browser tabs/address toolbar. They occupy exactly the top
        // 60 pixels, matching validateCropRendering's webpage-only crop.
        context.setFillColor(CGColor(red: 0.96, green: 0.08, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 20, width: width, height: 20))
        context.setFillColor(CGColor(red: 0.98, green: 0.48, blue: 0.06, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 60, width: width, height: 40))

        let progress = CGFloat(frameIndex) / CGFloat(max(1, frameCount - 1))
        let card = CGRect(x: 80 + progress * 620, y: 105 + sin(progress * .pi * 2) * 80, width: 180, height: 112)
        context.setFillColor(CGColor(red: 0.24, green: 0.76, blue: 0.95, alpha: 1))
        context.fillEllipse(in: CGRect(x: card.midX - 24, y: card.maxY + 36, width: 48, height: 48))
        context.setFillColor(CGColor(red: 0.96, green: 0.97, blue: 1, alpha: 1))
        context.fill(card)
        context.setFillColor(CGColor(red: 0.42, green: 0.32, blue: 0.98, alpha: 1))
        context.fill(CGRect(x: card.minX + 18, y: card.maxY - 34, width: 92, height: 12))
        context.setFillColor(CGColor(red: 0.72, green: 0.75, blue: 0.82, alpha: 1))
        context.fill(CGRect(x: card.minX + 18, y: card.maxY - 58, width: 142, height: 8))
        context.fill(CGRect(x: card.minX + 18, y: card.maxY - 78, width: 116, height: 8))
    }

    private static func makeAudioFormatDescription(
        sampleRate: Int
    ) throws -> CMAudioFormatDescription {
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var maybeDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &maybeDescription
        )
        guard status == noErr, let description = maybeDescription else {
            throw E2EError.audioFormatCreationFailed(status)
        }
        return description
    }

    private static func makeToneSampleBuffer(
        offset: Int,
        count: Int,
        sampleRate: Int,
        formatDescription: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let absoluteSample = offset + index
            let time = Double(absoluteSample) / Double(sampleRate)
            samples[index] = Float(sin(time * 440 * .pi * 2) * 0.12)
        }

        let byteCount = count * MemoryLayout<Float>.size
        var maybeBlockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &maybeBlockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer = maybeBlockBuffer else {
            throw E2EError.audioBlockBufferCreationFailed(status)
        }
        status = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw E2EError.audioBlockBufferCopyFailed(status)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Float>.size
        var maybeSampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &maybeSampleBuffer
        )
        guard status == noErr, let sampleBuffer = maybeSampleBuffer else {
            throw E2EError.audioSampleBufferCreationFailed(status)
        }
        return sampleBuffer
    }
}

private struct ValidationResult {
    let duration: Double
    let width: Int
    let height: Int
    let videoTrackCount: Int
    let audioTrackCount: Int
    let outputBytes: Int
    let distinctFrameCount: Int
    let zoomFrameDifference: Double
    let returnFrameDifference: Double
    let cursorChangedPixels: Int
}

private struct ImageDifference {
    let meanAbsolute: Double
    let changedPixels: Int
}

private struct E2EReport: Codable {
    let status: String
    let sourcePath: String
    let outputPath: String
    let duration: Double
    let width: Int
    let height: Int
    let frameRate: Int
    let videoTrackCount: Int
    let audioTrackCount: Int
    let outputBytes: Int
    let distinctFrameCount: Int
    let zoomFrameDifference: Double
    let returnFrameDifference: Double
    let cursorChangedPixels: Int
    let chapterCaptionDifference: Double
    let zoomSegmentCount: Int
    let cursorSampleCount: Int
    let clickEventCount: Int
}

private struct FailureReport: Codable {
    let status: String
    let error: String
}

private struct ZoomTimingFrameComparison: Codable {
    let time: Double
    let speedDifference: Double
    let durationDifference: Double
}

private struct ZoomTimingValidationReport: Codable {
    let status: String
    let outputPaths: [String: String]
    let variants: [ZoomTimingVariantCheck]
    let maximumPreviewExportDifference: Double
    let frameComparisons: [ZoomTimingFrameComparison]
}

private struct ChapterCaptionValidationReport: Codable {
    let status: String
    let visibleDifference: Double
    let visibleChangedPixels: Int
    let fadeDifference: Double
    let outsideDifference: Double
    let previewExportDifference: Double
    let bottomRows: [Int]
    let topRows: [Int]
    let reviewFramePath: String
}

private struct ZoomTimingVariantCheck: Codable {
    let name: String
    let start: Double
    let end: Double
    let duration: Double
    let easeIn: Double
    let hold: Double
    let easeOut: Double
}

private struct RecordedTypingBurstCheck: Codable {
    let firstTime: Double
    let lastTime: Double
    let eventCount: Int
    let checkedTimes: [Double]
    let minimumScale: Double
}

private struct RecordedZoomCue: Codable {
    let start: Double
    let end: Double
    let scale: Double
}

private struct RecordedProjectValidationReport: Codable {
    let status: String
    let projectPath: String
    let outputPath: String
    let duration: Double
    let width: Int
    let height: Int
    let frameRate: Int
    let cursorSampleCount: Int
    let clickEventCount: Int
    let typingActivityCount: Int
    let visibleTypingActivityCount: Int
    let automaticZoomCues: [RecordedZoomCue]
    let typingBursts: [RecordedTypingBurstCheck]
    let duringFrameTime: Double
    let duringFramePath: String
    let zoomFrameDifference: Double
    let returnCheck: String
    let returnFrameTime: Double?
    let returnFramePath: String?
    let returnFrameDifference: Double?
    let originalMetadataUnchanged: Bool
}

private struct CaptureSmokeReport: Codable {
    let status: String
    let outputPath: String
    let duration: Double
    let bytes: Int
    let target: String
    let width: Int
    let height: Int
    let cursorSampleCount: Int
    let clickEventCount: Int
    let eventCaptureWarning: String?
}

private enum E2EError: LocalizedError {
    case assertionFailed(String)
    case missingOutputDirectoryArgument
    case couldNotAddSyntheticWriterInputs
    case pixelBufferPoolUnavailable
    case pixelBufferCreationFailed(CVReturn)
    case audioFormatCreationFailed(OSStatus)
    case audioBlockBufferCreationFailed(OSStatus)
    case audioBlockBufferCopyFailed(OSStatus)
    case audioSampleBufferCreationFailed(OSStatus)
    case writerFailed(String)
    case invalidVideoTrackCount(Int)
    case audioWasNotPreserved(source: Int, output: Int, exporterReportedAudio: Bool)
    case durationMismatch(expected: Double, actual: Double)
    case sizeMismatch(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
    case outputTooSmall(Int)
    case renderedFramesWereNotDistinct(Int)
    case jsonEncodingFailed

    var errorDescription: String? {
        switch self {
        case .assertionFailed(let message):
            return "Core self-check failed: \(message)"
        case .missingOutputDirectoryArgument:
            return "--output-dir requires a path."
        case .couldNotAddSyntheticWriterInputs:
            return "Could not add the synthetic video/audio writer inputs."
        case .pixelBufferPoolUnavailable:
            return "The synthetic video pixel buffer pool was unavailable."
        case .pixelBufferCreationFailed(let status):
            return "Could not create a synthetic frame (CVReturn \(status))."
        case .audioFormatCreationFailed(let status):
            return "Could not create the PCM audio format (OSStatus \(status))."
        case .audioBlockBufferCreationFailed(let status):
            return "Could not create the audio block buffer (OSStatus \(status))."
        case .audioBlockBufferCopyFailed(let status):
            return "Could not copy tone samples (OSStatus \(status))."
        case .audioSampleBufferCreationFailed(let status):
            return "Could not create an audio sample buffer (OSStatus \(status))."
        case .writerFailed(let message):
            return "Synthetic asset writer failed: \(message)"
        case .invalidVideoTrackCount(let count):
            return "Expected one output video track, got \(count)."
        case .audioWasNotPreserved(let source, let output, let exporterReportedAudio):
            return "Audio preservation failed (source=\(source), output=\(output), reported=\(exporterReportedAudio))."
        case .durationMismatch(let expected, let actual):
            return "Duration mismatch (expected \(expected), got \(actual))."
        case .sizeMismatch(let expectedWidth, let expectedHeight, let actualWidth, let actualHeight):
            return "Size mismatch (expected \(expectedWidth)x\(expectedHeight), got \(actualWidth)x\(actualHeight))."
        case .outputTooSmall(let bytes):
            return "Rendered MP4 was unexpectedly small (\(bytes) bytes)."
        case .renderedFramesWereNotDistinct(let count):
            return "Only \(count) distinct rendered frame fingerprints were found."
        case .jsonEncodingFailed:
            return "Could not encode the E2E report as UTF-8 JSON."
        }
    }
}

private extension Array {
    func asyncMap<Result>(_ transform: (Element) async throws -> Result) async rethrows -> [Result] {
        var values: [Result] = []
        values.reserveCapacity(count)
        for element in self {
            try await values.append(transform(element))
        }
        return values
    }
}
