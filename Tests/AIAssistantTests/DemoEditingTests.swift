@preconcurrency import AVFoundation
import Foundation
import FocusStudioCore
import ImageIO

extension AIAssistantTests {
    @MainActor
    static func demoEditing(root: URL) async throws {
        try await demoEditingMotionAndReceipts(root: root)
        try await demoEditingRepeatedObservations(root: root)
        let clickA = ClickEvent(time: 1, x: 0.2, y: 0.3, button: .left)
        let removed = ClickEvent(time: 6, x: 0.5, y: 0.5, button: .left)
        let clickB = ClickEvent(time: 10, x: 0.8, y: 0.7, button: .left)
        let invalidID = UUID()
        var source = makeProject(sourceVideoPath: "/original.mp4", duration: 12)
        source.clickEvents = [clickA, removed, clickB]
        source.interactionTrace = InteractionTrace(sessionID: UUID(), source: .execution, events: [
            InteractionEvent(sequence: 0, time: 0, kind: .move, x: 0.1, y: 0.1),
            InteractionEvent(id: clickA.id, sequence: 1, time: 1, kind: .click, x: clickA.x, y: clickA.y),
            InteractionEvent(id: invalidID, sequence: -1, time: 2, kind: .move, x: 0.9, y: 0.9),
            InteractionEvent(id: removed.id, sequence: 2, time: 6, kind: .click, x: removed.x, y: removed.y),
            InteractionEvent(id: clickB.id, sequence: 3, time: 10, kind: .click, x: clickB.x, y: clickB.y, geometryGeneration: 1),
            InteractionEvent(sequence: 4, time: 12, kind: .move, x: 0.8, y: 0.8, geometryGeneration: 1),
        ])
        source.zoomSegments = [ZoomSegment(start: 0.5, end: 11, targetX: 0.2, targetY: 0.3, scale: 2, automaticSource: .init(start: 0.5, targetX: 0.2, targetY: 0.3, eventTime: 1, clickIDs: [clickA.id, removed.id, clickB.id], originalEnd: 11))]
        source.chapters = [DemoChapter(start: 1, end: 11, title: "Example")]
        let sourceSnapshot = source
        let edit = try DemoTimelineEdit(keepRanges: [.init(start: 0, end: 3), .init(start: 9, end: 12)], sourceDuration: 12)
        let derived = edit.remap(source, sourceVideoPath: "/new.mov")
        check(source == sourceSnapshot && derived.id != source.id && derived.duration == 6, "cut remaps a fresh value and preserves original")
        check(derived.resolvedClickEvents.map(\.time) == [1, 4] && derived.resolvedClickEvents.map(\.id) == [clickA.id, clickB.id], "removed clicks disappear while retained IDs and timing follow video")
        check(derived.interactionTrace?.events.contains { $0.id == invalidID } == false, "invalid source events never become valid after retiming")
        check(derived.resolvedInteractions.discontinuityTimes.contains(3) && derived.resolvedInteractions.discontinuityTimes.contains(4), "edit join and original geometry change remain separate discontinuities")
        check(derived.zoomSegments.count == 2 && Set(derived.zoomSegments.map(\.id)).count == 2 && derived.zoomSegments.allSatisfy { $0.kind == .manual }, "zoom crossing a cut splits into editable unique authored blocks")
        check(derived.zoomSegments[1].start == 3 && derived.zoomSegments[1].end == 5 && derived.zoomSegments[0].automaticSource?.clickIDs == [clickA.id, clickB.id], "zoom timing and original cue membership retime with the cut")
        check(derived.chapters?.map(\.start) == [1, 3] && derived.chapters?.map(\.end) == [3, 5], "chapters split and preserve valid intervals")
        check(edit.mappedTime(3) == nil && edit.mappedTime(9) == 3 && edit.mappedTime(12) == 6, "half-open boundaries omit cut endpoints but preserve final frame timestamp")
        let adjacent = try DemoTimelineEdit(keepRanges: [.init(start: 0, end: 1), .init(start: 1, end: 12)], sourceDuration: 12).remap(source, sourceVideoPath: "/adjacent.mov")
        check(adjacent.resolvedClickEvents.filter { $0.id == clickA.id }.count == 1, "adjacent ranges never duplicate a boundary click")
        var legacy = source
        legacy.interactionTrace = nil
        legacy.clickEvents = [clickA]
        legacy.zoomSegments[0].automaticSource = nil
        var legacyCut = edit.remap(legacy, sourceVideoPath: "/legacy.mov")
        let manualIDs = Set(legacyCut.zoomSegments.map(\.id))
        TimelineMath.regenerateAutomaticZoomSegments(in: &legacyCut)
        check(Set(legacyCut.zoomSegments.map(\.id)) == manualIDs, "legacy automatic cue takeover prevents duplicate automatic zooms after cut")
        for ranges in [[DemoKeepRange(start: 2, end: 1)], [.init(start: 0, end: 5), .init(start: 4, end: 8)], [.init(start: -1, end: 2)], [.init(start: 0, end: 13)], [.init(start: .nan, end: 3)], [.init(start: 0, end: 0.01)], []] {
            await expectThrows("invalid timeline is refused") { _ = try DemoTimelineEdit(keepRanges: ranges, sourceDuration: 12) }
        }
        var sparse = makeProject(sourceVideoPath: "/sparse.mp4", duration: 40)
        sparse.clickEvents = [ClickEvent(time: 5, x: 0.5, y: 0.5, button: .left)]
        let suggestion = try DemoPacingAnalyzer.analyze(sparse, hasSourceAudio: false)
        check(suggestion.edit.duration < 40 && suggestion.edit.ranges.first?.start == 0 && suggestion.edit.ranges.last?.end == 40, "pacing keeps beginning, ending and input context")
        check(suggestion.warnings.contains { $0.contains("generated answers") && $0.contains("No visual") }, "input silence never claims that AI-generated results are safe to remove")
        let voiced = try DemoPacingAnalyzer.analyze(sparse, hasSourceAudio: true)
        check(voiced.edit.duration == 40, "source audio is never automatically shortened")
        sparse.clickEvents = []
        let emptyProposal = try DemoPacingAnalyzer.analyze(sparse, hasSourceAudio: false)
        check(emptyProposal.edit.duration == 40, "missing evidence never invents an edit")
        sparse.clickEvents = [ClickEvent(time: 5, x: 0.5, y: 0.5, button: .left)]
        sparse.chapters = [DemoChapter(start: 0, end: 40, title: "Read answer")]
        let chapterProposal = try DemoPacingAnalyzer.analyze(sparse, hasSourceAudio: false)
        check(chapterProposal.edit.duration == 40, "enabled reading chapter is protected in candidate proposal")

        let video = root.appendingPathComponent("edit-source.mp4")
        try await SolidClipWriter.write(to: video, width: 320, height: 180, duration: 3, color: (0.2, 0.4, 0.8), audio: true)
        let originalBytes = try Data(contentsOf: video)
        let exported = root.appendingPathComponent("edited-raw.mov")
        let mediaEdit = try DemoTimelineEdit(keepRanges: [.init(start: 0.25, end: 1), .init(start: 2, end: 2.75)], sourceDuration: 3)
        try await DemoCutExporter.export(sourceURL: video, edit: mediaEdit, to: exported)
        let asset = AVURLAsset(url: exported)
        let actualDuration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        check(abs(actualDuration - 1.5) < 0.05 && !audioTracks.isEmpty, "real AVComposition cut preserves source audio and selected duration")
        let preservedBytes = try Data(contentsOf: video)
        check(preservedBytes == originalBytes, "real export never changes source bytes")
        await expectThrows("cannot replace original") { try await DemoCutExporter.export(sourceURL: video, edit: mediaEdit, to: video) }
        let tooLong = try DemoTimelineEdit(keepRanges: [.init(start: 0, end: 4)], sourceDuration: 4)
        let badOutput = root.appendingPathComponent("too-long.mov")
        await expectThrows("metadata longer than raw file fails") { try await DemoCutExporter.export(sourceURL: video, edit: tooLong, to: badOutput) }
        check(!FileManager.default.fileExists(atPath: badOutput.path), "failed raw validation publishes no partial movie")
        let cancelledOutput = root.appendingPathComponent("cancelled-cut.mov")
        let cancelled = Task { try Task.checkCancellation(); try await DemoCutExporter.export(sourceURL: video, edit: mediaEdit, to: cancelledOutput) }
        cancelled.cancel()
        await expectThrows("cancelled cut") { try await cancelled.value }
        check(!FileManager.default.fileExists(atPath: cancelledOutput.path), "cancelled cut publishes no movie")

        var zoomProject = makeProject(sourceVideoPath: video.path, duration: 3)
        let first = ZoomSegment(start: 0, end: 0.5, targetX: 0.2, targetY: 0.3, scale: 1.5, kind: .manual)
        let click = ClickEvent(time: 1.5, x: 0.7, y: 0.8, button: .left)
        zoomProject.clickEvents = [click]
        zoomProject.zoomSegments = [first, ZoomSegment(start: 1, end: 2.5, targetX: 0.7, targetY: 0.8, scale: 2, automaticSource: .init(start: 1, targetX: 0.7, targetY: 0.8, eventTime: 1.5, clickIDs: [click.id], originalEnd: 2.5))]
        let secondID = zoomProject.zoomSegments[1].id
        let box = ProjectBox(zoomProject)
        let context = makeContext(root: root, box: box)
        let update = try await UpdateZoomTool().run(arguments: ["zoom_id": secondID.uuidString, "start": 1.2, "end": 2.8, "ease_in": 0.15], context: context, progress: { _ in })
        check(update.data?["zoom"]?["index"]?.intValue == 2, "updating second zoom reports its true index")
        check(box.project!.zoomSegments[0] == first && box.project!.zoomSegments[1].id == secondID && box.project!.zoomSegments[1].zoomEaseIn == 0.15, "targeted update preserves other zoom and stable identity")
        TimelineMath.regenerateAutomaticZoomSegments(in: &box.project!)
        check(box.project!.zoomSegments.count == 2 && box.project!.zoomSegments.first { $0.id == secondID }?.end == 2.8, "global automatic regeneration preserves targeted timing without duplicate cue")
        let beforeInvalid = box.project
        await expectThrows("invalid update does not partly apply") { _ = try await UpdateZoomTool().run(arguments: ["zoom_id": secondID.uuidString, "start": 2.7, "end": 1], context: context, progress: { _ in }) }
        check(box.project == beforeInvalid, "invalid targeted edit is atomic")
        let app = FakeApp(box: box)
        app.projects = [box.project!]
        app.openID = box.project!.id
        app.library = root
        var cutContext = context
        cutContext.app = app
        let sourceID = box.project!.id
        let cutResult = try await CreateDemoCutTool().run(arguments: ["project_id": sourceID.uuidString, "keep_ranges": [["start": 0.0, "end": 0.8], ["start": 1.0, "end": 2.5]], "title": "Reviewed demo"], context: cutContext, progress: { _ in })
        check(app.demoCutCalls.count == 1 && app.projects.first?.id == sourceID && box.project!.id != sourceID, "cut tool delegates one derived library project without editing the source")
        check(cutResult.data?["timing_map"]?.arrayValue?.last?["output_start"]?.doubleValue == 0.8 && cutResult.data?["source_project_id"]?.stringValue == sourceID.uuidString, "cut receipt supplies exact source-to-output map and both project identities")
        let normalizedResult = try await CreateDemoCutTool().run(arguments: ["keep_ranges": [["start": 0.0, "end": 0.8], ["start": 0.8, "end": 2.0]]], context: cutContext, progress: { _ in })
        check(app.demoCutCalls.last?.1 == [.init(start: 0, end: 2)], "cut tool dispatches normalized continuous ranges to the store")
        check(normalizedResult.data?["keep_ranges"]?.arrayValue?.count == 1
              && normalizedResult.data?["timing_map"]?.arrayValue?.count == 1
              && normalizedResult.data?["timing_map"]?.arrayValue?.first?["output_end"]?.doubleValue == 2
              && normalizedResult.data?["cut_count"]?.intValue == 0,
              "cut receipt agrees with actual continuous footage: one range, one mapping and no cut")
        let callCount = app.demoCutCalls.count
        await expectThrows("unreviewed automatic cut is refused") { _ = try await CreateDemoCutTool().run(arguments: [:], context: cutContext, progress: { _ in }) }
        await expectThrows("overlapping range tool arguments fail before mutation") { _ = try await CreateDemoCutTool().run(arguments: ["keep_ranges": [["start": 0.0, "end": 1.0], ["start": 0.5, "end": 1.5]]], context: cutContext, progress: { _ in }) }
        check(app.demoCutCalls.count == callCount, "invalid or missing ranges never enter a library mutation")
        box.project = zoomProject
        let analysis = try await AnalyzeDemoPacingTool().run(arguments: [:], context: context, progress: { _ in })
        check(analysis.data?["source_audio_present"]?.boolValue == true && analysis.data?["edited_duration"]?.doubleValue == 3, "pacing tool actually inspects media audio before suggesting cuts")
    }

    @MainActor
    final class EditingReceiptCompletion: TextCompletionProviding {
        var calls = 0
        let response: @MainActor (Int, String) -> String
        init(_ response: @escaping @MainActor (Int, String) -> String) { self.response = response }
        func complete(system: String, user: String, json: Bool) async throws -> String {
            defer { calls += 1 }
            return response(calls, user)
        }
    }

    @MainActor
    static func demoEditingRepeatedObservations(root: URL) async throws {
        let video = root.appendingPathComponent("repeatable-preview-source.mp4")
        try await SolidClipWriter.write(to: video, width: 320, height: 180, duration: 3,
                                        color: (0.15, 0.25, 0.7), audio: false, patterned: true)
        var project = makeProject(sourceVideoPath: video.path, duration: 3, width: 320, height: 180)
        project.cursorSamples = []
        project.zoomSegments = [.init(start: 0, end: 3, targetX: 0.5, targetY: 0.5, scale: 1.2, kind: .manual, isInstant: true)]
        let zoomID = project.zoomSegments[0].id
        let box = ProjectBox(project)
        let context = makeContext(root: root.appendingPathComponent("repeatable-observations"), box: box)
        let preview = action("capture_frame", "{\"time\":1,\"width\":640}")
        let analyze = action("analyze_demo_pacing", "{\"pre_roll\":0.1,\"post_roll\":0.1,\"minimum_gap\":0.5}")
        let add = action("add_zoom", "{\"start\":2,\"end\":2.8,\"x\":0.2,\"y\":0.5,\"scale\":1.5}")
        let scripted = ScriptedCompletion([
            preview,
            action("update_zoom", "{\"zoom_id\":\"\(zoomID)\",\"scale\":2.7}"),
            preview,
            analyze,
            action("set_chapters", "{\"chapters\":[{\"start\":0,\"end\":3,\"title\":\"Read answer\"}]}"),
            analyze,
            add, add,
            reply("The revised frame and protected reading time are checked.")
        ])
        let session = AIAssistantSession(context: context, completion: scripted)
        session.send("Preview, adjust the zoom, preview the same time again, then recheck pacing after adding reading time.")
        try await waitUntil("repeated observations inspect current edits") { !session.isRunning }
        let frames = session.messages.filter { $0.role == .tool && $0.toolName == "capture_frame" }
        check(frames.count == 2 && frames.allSatisfy { $0.attachments.count == 1 },
              "same project/time capture is really invoked twice, rather than replaced by an already-attempted receipt")
        func pixels(_ url: URL) -> Data {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let bitmap = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                         bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                fatalError("FAIL: decode actual preview pixels")
            }
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: bitmap.data!, count: bitmap.bytesPerRow * bitmap.height)
        }
        check(frames[0].attachments[0] != frames[1].attachments[0]
              && pixels(frames[0].attachments[0]) != pixels(frames[1].attachments[0]),
              "the second same-time preview contains newly rendered pixels after update_zoom")
        let analyses = session.messages.filter { $0.role == .tool && $0.toolName == "analyze_demo_pacing" }
        check(analyses.count == 2 && analyses.allSatisfy { $0.text.contains("Pacing proposal:") }
              && analyses[0].text != analyses[1].text && analyses[1].text.contains("\"edited_duration\":3"),
              "repeated pacing re-reads changed chapters and protects the new full-length reading range")
        check(box.project?.zoomSegments.count == 2 && box.writeCount == 3
              && session.messages.filter { $0.toolName == "add_zoom" }.count == 2,
              "read-only repeatability does not let the same add_zoom mutate the project twice (zooms=\(box.project?.zoomSegments.count ?? -1), writes=\(box.writeCount))")

        // Rendering behavior is covered above. Lightweight preview receipts
        // here isolate the capacity boundary without rendering dozens of PNGs.
        let log = ToolLog()
        let previewStub = RecordingTool(name: "capture_frame", summary: "Preview fixture", cost: nil, log: log)
        let budgetContext = makeContext(root: root.appendingPathComponent("editing-budget"), box: box)
        var steps = Array(repeating: preview, count: 26)
        steps += [action("update_zoom", "{\"zoom_id\":\"\(zoomID)\",\"scale\":1.8}"),
                  action("export_project", "{\"width\":1280,\"frame_rate\":24}"),
                  reply("The reviewed edit is exported.")]
        let longProvider = ScriptedCompletion(steps)
        let long = AIAssistantSession(context: budgetContext, completion: longProvider,
                                      tools: [previewStub, UpdateZoomTool(), ExportProjectTool()])
        long.send("Review the edit at each cut, refine the zoom and export the finished demo.")
        try await waitUntil("long editing review reaches its final reply") { !long.isRunning }
        let exports = long.messages.filter { $0.toolName == "export_project" && $0.role == .tool }.flatMap(\.attachments)
        check(longProvider.calls.count == 29 && log.runs.count == 26
              && long.messages.last?.role == .assistant && long.messages.last?.text == "The reviewed edit is exported."
              && exports.count == 1 && FileManager.default.fileExists(atPath: exports[0].path)
              && box.project?.zoomSegments.first { $0.id == zoomID }?.scale == 1.8,
              "a review beyond the old 24-step limit still applies its zoom, exports a real video and returns a normal final reply")
        let runawayLog = ToolLog()
        let runawayProvider = ScriptedCompletion(Array(repeating: preview, count: 49))
        let runaway = AIAssistantSession(context: budgetContext, completion: runawayProvider,
                                         tools: [RecordingTool(name: "capture_frame", summary: "Preview fixture", cost: nil, log: runawayLog)])
        runaway.send("Repeated preview fixture")
        try await waitUntil("read-only loop still stops at the new finite budget") { !runaway.isRunning }
        check(AIAssistantSession.maximumStepsPerTurn == 48 && runawayProvider.calls.count == 48
              && runawayLog.runs.count == 48 && runaway.messages.last?.role == .error,
              "repeatable observations retain a finite 48-step ceiling instead of enabling an endless loop")
    }

    @MainActor
    static func demoEditingMotionAndReceipts(root: URL) async throws {
        var manual = makeProject(sourceVideoPath: "/manual.mp4", duration: 10)
        manual.cursorSamples = [CursorSample(time: 0, x: 0.1, y: 0.5), CursorSample(time: 1, x: 0.1, y: 0.5), CursorSample(time: 8, x: 0.9, y: 0.5), CursorSample(time: 10, x: 0.9, y: 0.5)]
        let untouched = manual
        let cut = try DemoTimelineEdit(keepRanges: [.init(start: 0, end: 1), .init(start: 8, end: 10)], sourceDuration: 10).remap(manual, sourceVideoPath: "/manual-cut.mov")
        check(manual == untouched && manual.editCutTimes == nil && cut.editCutTimes == [1], "only a derived manual timeline gains hard edit boundaries")
        let path = EditedTimelineMotion.cursorPath(samples: cut.cursorSamples, clicks: [], duration: cut.duration, cutTimes: cut.editCutTimes!, sigma: 0.085)
        for time in [0.8, 0.95, 0.99] {
            check(abs(TimelineMath.cursorPosition(at: time, samples: path)!.x - 0.1) < 0.000_1, "manual pointer never anticipates the next shot before the cut")
        }
        for time in [1.0, 1.01, 1.05, 1.2] {
            check(abs(TimelineMath.cursorPosition(at: time, samples: path)!.x - 0.9) < 0.000_1, "manual pointer changes exactly at the edited hard cut")
        }
        let decoded = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(cut))
        check(decoded.editCutTimes == [1], "cut boundaries persist when the editor reloads a derived project")
        let recut = try DemoTimelineEdit(keepRanges: [.init(start: 0.5, end: 3)], sourceDuration: 3).remap(cut, sourceVideoPath: "/manual-recut.mov")
        check(recut.editCutTimes == [0.5], "an existing hard cut follows subsequent trim timing")
        let adjacent = try DemoTimelineEdit(keepRanges: [.init(start: 0, end: 1), .init(start: 1, end: 10)], sourceDuration: 10).remap(manual, sourceVideoPath: "/continuous.mov")
        check(adjacent.editCutTimes == nil, "adjacent keep ranges do not fabricate removed-time discontinuities")
        var continuous = manual
        continuous.zoomSegments = [ZoomSegment(start: 0, end: 10, targetX: 0.5, targetY: 0.5, scale: 2, kind: .manual, isInstant: true)]
        continuous.interactionTrace = InteractionTrace(sessionID: UUID(), source: .execution, events: manual.cursorSamples.enumerated().map { index, point in
            .init(sequence: index, time: point.time, kind: .move, x: point.x, y: point.y)
        })
        let touchingEdit = try DemoTimelineEdit(keepRanges: [.init(start: 0, end: 1), .init(start: 1, end: 3), .init(start: 3, end: 10)], sourceDuration: 10)
        check(touchingEdit.ranges == [.init(start: 0, end: 10)] && touchingEdit.duration == 10, "touching intervals normalize to continuous source footage")
        let touching = touchingEdit.remap(continuous, sourceVideoPath: "/touching.mov")
        check(touching.editCutTimes == nil && touching.resolvedInteractions.discontinuityTimes.filter { $0 > 0 }.isEmpty,
              "continuous execution footage must not fabricate an internal cursor/camera discontinuity")
        check(touching.zoomSegments.count == 1 && touching.zoomSegments[0].id == continuous.zoomSegments[0].id
              && touching.zoomSegments[0].start == 0 && touching.zoomSegments[0].end == 10,
              "continuous keep ranges preserve one authored zoom instead of restarting it at each boundary")
        func executionFollow(_ project: RecordingProject) -> [CursorFollow.Sample] {
            let interactions = project.resolvedInteractions
            return InteractionCursorFollow.offsets(duration: project.duration, segments: project.zoomSegments, settings: project.settings,
                cursor: interactions.renderedCursorSamples(sigma: 0.085), strength: 1,
                discontinuities: interactions.discontinuityTimes, cursorIsAvailable: { interactions.cursorIsAvailable(at: $0) })
        }
        let originalFollow = executionFollow(continuous)
        let touchingFollow = executionFollow(touching)
        for time in [0.99, 1, 1.01, 2.99, 3, 3.01] {
            let expected = CursorFollow.offset(at: time, samples: originalFollow)
            let actual = CursorFollow.offset(at: time, samples: touchingFollow)
            check(abs(expected.dx - actual.dx) < 0.000_001 && abs(expected.dy - actual.dy) < 0.000_001,
                  "a continuous keep boundary must not reset existing camera-follow momentum")
        }
        let stillCut = try DemoTimelineEdit(keepRanges: [.init(start: 0, end: 1), .init(start: 1.0001, end: 10)], sourceDuration: 10)
        check(stillCut.ranges.count == 2, "a real removed interval, even a small one, must not be erased by normalization")
        var visibility = manual
        visibility.settings.autoZoomEnabled = false
        visibility.zoomSegments = [
            .init(start: 0.5, end: 2, targetX: 0.3, targetY: 0.5, scale: 2, kind: .automatic),
            .init(start: 3, end: 5, targetX: 0.5, targetY: 0.5, scale: 2, kind: .manual),
            .init(start: 6, end: 8, targetX: 0.7, targetY: 0.5, scale: 2, kind: .manual, isEnabled: false),
            .init(start: 8, end: 9.5, targetX: 0.7, targetY: 0.5, scale: 2, kind: .automatic, isEnabled: false),
        ]
        let visibilitySnapshot = visibility
        let visibilityCut = touchingEdit.remap(visibility, sourceVideoPath: "/visibility.mov")
        check(visibility == visibilitySnapshot && visibilityCut.zoomSegments.map(\.id) == visibility.zoomSegments.map(\.id),
              "freezing camera visibility preserves source values and retained segment identities")
        check(visibilityCut.zoomSegments.map(\.isEnabled) == [false, true, false, false],
              "a cut preserves globally hidden automatic cues, visible manual cues, and individually disabled cues")
        check(TimelineMath.zoomState(at: 1, segments: visibilityCut.zoomSegments, settings: visibilityCut.settings).scale == 1
              && TimelineMath.zoomState(at: 4, segments: visibilityCut.zoomSegments, settings: visibilityCut.settings).scale > 1
              && TimelineMath.zoomState(at: 7, segments: visibilityCut.zoomSegments, settings: visibilityCut.settings).scale == 1,
              "the rendered edit must not reveal an automatic zoom that was globally hidden in the source")
        visibility.settings.autoZoomEnabled = true
        let visibleAutomaticCut = touchingEdit.remap(visibility, sourceVideoPath: "/visible-automatic.mov")
        check(visibleAutomaticCut.zoomSegments[0].isEnabled && !visibleAutomaticCut.zoomSegments[3].isEnabled,
              "globally enabled automatic cues stay visible without re-enabling individually disabled ones")
        var cameraSettings = ProjectSettings()
        cameraSettings.zoomEaseIn = 0
        cameraSettings.zoomEaseOut = 0
        let zoom = ZoomSegment(start: 0, end: 3, targetX: 0.5, targetY: 0.5, scale: 2, kind: .manual, isInstant: true)
        let follow = EditedTimelineMotion.followOffsets(duration: 3, segments: [zoom], settings: cameraSettings, cursor: path, strength: 1, cutTimes: [1])
        let before = CursorFollow.offset(at: 0.99, samples: follow).dx
        let after = CursorFollow.offset(at: 1.01, samples: follow).dx
        check(before < -0.01 && after > 0, "manual camera follow does not carry old-shot spring momentum across a cut")
        let noMotionSecond = EditedTimelineMotion.followOffsets(duration: 3, segments: [ZoomSegment(start: 0, end: 1, targetX: 0.5, targetY: 0.5, scale: 2, kind: .manual, isInstant: true)], settings: cameraSettings, cursor: path, strength: 1, cutTimes: [1])
        check(CursorFollow.offset(at: 1.01, samples: noMotionSecond).dx == 0, "a shot without active camera movement resets to zero offset")

        var project = makeProject(sourceVideoPath: "/receipt.mp4", duration: 4)
        let first = ZoomSegment(start: 0, end: 1, targetX: 0.2, targetY: 0.3, scale: 1.5, kind: .manual)
        let second = ZoomSegment(start: 1.5, end: 3, targetX: 0.8, targetY: 0.7, scale: 2, kind: .manual, zoomEaseIn: 0.25, zoomEaseOut: 0.4)
        project.zoomSegments = [first, second]
        let box = ProjectBox(project)
        let app = FakeApp(box: box)
        app.projects = [project]
        app.openID = project.id
        var context = makeContext(root: root, box: box)
        context.app = app
        let provider = EditingReceiptCompletion { step, user in
            switch step {
            case 0: return action("get_project")
            case 1:
                check(user.contains(second.id.uuidString) && user.contains("ease_in") && user.contains("0.25"), "text-only model receives stable zoom IDs and easing from structured get_project result")
                return action("update_zoom", "{\"zoom_id\":\"\(second.id.uuidString)\",\"end\":3.6}")
            default: return reply("The second zoom is extended.")
            }
        }
        let session = AIAssistantSession(context: context, completion: provider)
        session.send("Extend the second zoom to end at 3.6 seconds.")
        try await waitUntil("stable zoom IDs reach the editing model") { !session.isRunning }
        check(box.project?.zoomSegments[0] == first && box.project?.zoomSegments[1].id == second.id && box.project?.zoomSegments[1].end == 3.6, "the assistant adjusts the existing zoom rather than replacing it")
        let data: AIJSONValue = ["zoom_id": AIJSONValue(second.id.uuidString)]
        let json = String(decoding: try data.jsonData(), as: UTF8.self)
        let once = AIAssistantSession.modelReceipt(AIToolResult(text: "Result\n" + json, data: data))
        check(once.components(separatedBy: json).count == 2, "already embedded structured JSON is not duplicated")
        let bounded = AIAssistantSession.modelReceipt(AIToolResult(text: String(repeating: "x", count: 60_000)))
        check(bounded.count < AIAssistantSession.toolReceiptCharacterBudget + 100 && bounded.contains("truncated"), "unexpectedly large tool receipts remain bounded and announce omitted evidence")
    }
}
