@preconcurrency import AVFoundation
import CoreGraphics
import CryptoKit
import FocusStudioCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Real AVFoundation/store integration in a temporary library. This deliberately
/// avoids capture, browser automation, user projects, permissions and the network.
@MainActor
enum DemoEditingRegression {
    static func run() async throws {
        try pacingAndRetimingPreserveExecutionTyping()
        let fixture = try await DemoEditingFixture()
        defer { fixture.cleanup() }
        try await materializesIndependentCut(fixture)
        try await failuresNeverPublishPartialProject(fixture)
        try await modelOpensDerivedContextAndRefusesBusy(fixture)
        try await timelineWorkingCopyAndUndo(fixture)
        try await editorMediaLibraryAndRedo(fixture)
        print("DemoEditingRegression: PASS (real 6-second movie cut to 3 seconds, source SHA256 unchanged, trace/zooms/chapters remapped, dependent assets copied and independently readable, invalid/cancelled/missing-asset edits leave no partial project, media import/insert and Undo/Redo survive reload)")
    }

    private static let ranges = [DemoKeepRange(start: 0, end: 1), DemoKeepRange(start: 3, end: 5)]

    private static func pacingAndRetimingPreserveExecutionTyping() throws {
        var source = RecordingProject(title: "Typing between clicks", sourceVideoPath: "/fixture.mp4",
            duration: 40, sourceWidth: 1000, sourceHeight: 700,
            typingActivity: [.init(time: 15, x: 0.95, y: 0.95)])
        let typing = stride(from: 25.0, through: 25.35, by: 0.035).map { TypingActivity(time: $0, x: 0.4, y: 0.6) }
        source.interactionTrace = .init(sessionID: UUID(), source: .execution, events: [
            .init(sequence: 0, time: 5, kind: .click, x: 0.2, y: 0.3),
            .init(sequence: 1, time: 35, kind: .click, x: 0.8, y: 0.7),
        ], typingActivity: typing)
        let proposed = try DemoPacingAnalyzer.analyze(source, hasSourceAudio: false)
        try expect(proposed.edit.duration < source.duration && typing.allSatisfy { proposed.edit.mappedTime($0.time) != nil },
                   "Pacing may shorten waits but must retain every Codex typing moment 25 seconds into a click-free gap")
        try expect(proposed.edit.mappedTime(15) == nil,
                   "Unrelated physical typing cannot protect an execution-owned wait")
        let edited = proposed.edit.remap(source, sourceVideoPath: "/edited.mp4")
        let expected = typing.map { TypingActivity(time: proposed.edit.mappedTime($0.time)!, x: $0.x, y: $0.y) }
        try expect(edited.resolvedTypingActivity == expected && edited.typingActivity == expected,
                   "Derived trace and report metadata must share remapped execution typing")
        let again = try DemoPacingAnalyzer.analyze(edited, hasSourceAudio: false)
        try expect(edited.resolvedTypingActivity.allSatisfy { again.edit.mappedTime($0.time) != nil },
                   "Reanalyzing a derived take cannot forget its typing")

        source.interactionTrace?.typingActivity = [
            .init(time: 24, x: 0.4, y: 0.6), .init(time: 25, x: 0.4, y: 0.6),
            .init(time: 26, x: 0.4, y: 0.6), .init(time: 27, x: 0.4, y: 0.6),
            .init(time: 40, x: 0.4, y: 0.6), .init(time: 25.5, x: .nan, y: 0.6),
        ]
        let cut = try DemoTimelineEdit(keepRanges: [.init(start: 25, end: 26), .init(start: 27, end: 40)], sourceDuration: 40)
        let remapped = cut.remap(source, sourceVideoPath: "/boundaries.mp4")
        try expect(close(remapped.resolvedTypingActivity.map(\.time), [0, 1, 14]),
                   "Typing respects half-open cut boundaries and final-frame retention; invalid coordinates cannot become valid after editing")
        source.interactionTrace?.typingActivity = nil
        let older = cut.remap(source, sourceVideoPath: "/old-trace.mp4")
        try expect(older.resolvedTypingActivity.isEmpty && older.typingActivity?.isEmpty == true,
                   "Cutting an older execution trace cannot expose legacy physical typing")
    }

    private static func materializesIndependentCut(_ fixture: DemoEditingFixture) async throws {
        let source = fixture.project
        let before = try fixture.sourceHashes()
        let edited = try await fixture.store.createDemoCut(from: source, keepRanges: ranges, title: "Short demo")
        try expect(edited.id != source.id && edited.title == "Short demo", "A cut must create a new identified project")
        try expect(abs(edited.duration - 3) < 0.000_001, "The editable timeline must retain exactly 1 + 2 seconds")
        let asset = AVURLAsset(url: URL(fileURLWithPath: edited.sourceVideoPath))
        let duration = try await asset.load(.duration).seconds
        try expect(abs(duration - 3) <= 1.0 / 30, "The derived movie must actually be 3 seconds, got \(duration)")
        let videos = try await asset.loadTracks(withMediaType: .video)
        try expect(videos.count == 1, "The derived movie must contain a readable video track")
        let frame = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        try expect(frame.width == 64 && frame.height == 64, "The cut must decode at the source resolution")
        try expect(try fixture.sourceHashes() == before, "Store cutting must not rewrite the source movie or project JSON")

        let saved = try await fixture.store.loadProjects()
        guard let reopened = saved.first(where: { $0.id == edited.id }) else { throw DemoEditingFailure("The derived project must reopen from its own metadata") }
        try expect(saved.count == 2 && reopened.duration == edited.duration, "Only the complete derived project should be published")
        let clicks = reopened.resolvedClickEvents
        try expect(clicks.map(\.id) == [fixture.clickIDs[0], fixture.clickIDs[2], fixture.clickIDs[3]], "Removed input must be omitted while retained click identities survive")
        try expect(close(clicks.map(\.time), [0.5, 1.5, 2.8]), "Clicks must follow the shortened movie: \(clicks.map(\.time))")
        try expect(close((reopened.typingActivity ?? []).map(\.time), [1.8]), "Retained typing must use the edited time; omitted typing must disappear")
        try expect(close(reopened.resolvedTypingActivity.map(\.time), [1.8])
                   && reopened.interactionTrace?.typingActivity == reopened.typingActivity,
                   "Saved and reopened cuts retain authoritative execution typing, not the physical metadata mirror")
        try expect(reopened.interactionTrace?.source == .execution && reopened.resolvedInteractions.rejectedEventCount == 0,
                   "The saved cut must keep a valid execution trace")
        let discontinuities = reopened.interactionTrace?.events.filter { $0.kind == .discontinuity }.map(\.time) ?? []
        try expect(discontinuities.contains(1), "A cut boundary must break cursor continuity")
        try expect(reopened.zoomSegments.count == 2 && close(reopened.zoomSegments.map(\.start), [0.1, 1])
                   && close(reopened.zoomSegments.map(\.end), [0.9, 2.5]), "Camera segments must follow the same selected ranges")
        try expect(reopened.zoomSegments.allSatisfy { $0.kind == .manual }, "Authored cuts must survive automatic regeneration")
        let chapters = reopened.chapters ?? []
        try expect(chapters.map(\.title) == ["Intro", "Result"] && close(chapters.map(\.start), [0, 1])
                   && close(chapters.map(\.end), [1, 3]), "Chapter content and timing must survive the cut")

        let folder = fixture.store.projectsDirectory.appendingPathComponent(edited.id.uuidString)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("edit-source.json"))) as? [String: Any]
        try expect(manifest?["sourceProjectID"] as? String == source.id.uuidString && manifest?["editedDuration"] as? Double == 3,
                   "The derived project must retain its edit provenance")
        let originalAssets = try fixture.assetURLs(source)
        let copiedAssets = try fixture.assetURLs(reopened)
        try expect(copiedAssets.count == 4, "Background, music, click and zoom audio must be copied")
        for (original, copied) in zip(originalAssets, copiedAssets) {
            try expect(copied.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path,
                       "Every retained dependency must live inside the new project")
            try expect(try Data(contentsOf: original) == Data(contentsOf: copied), "Copied media must preserve its bytes")
        }

        // Relocate only the temporary fixture's source folder: reopening and
        // decoding the edit must not depend on any source project file.
        let sourceFolder = fixture.store.projectsDirectory.appendingPathComponent(source.id.uuidString)
        let isolated = fixture.root.appendingPathComponent("source-isolated")
        try FileManager.default.moveItem(at: sourceFolder, to: isolated)
        defer { try? FileManager.default.moveItem(at: isolated, to: sourceFolder) }
        let independent = try await fixture.store.loadProjects()
        try expect(independent.count == 1 && independent.first?.id == edited.id, "The edited project must load without its source directory")
        for copied in copiedAssets { try expect(FileManager.default.fileExists(atPath: copied.path), "Copied dependencies must remain available") }
        let music = AVURLAsset(url: copiedAssets[1])
        let tracks = try await music.loadTracks(withMediaType: .audio)
        try expect(tracks.count == 1, "Copied background music must remain readable after the source is unavailable")
        try expect(CGImageSourceCreateWithURL(copiedAssets[0] as CFURL, nil) != nil, "Copied background image must remain readable")
    }

    private static func failuresNeverPublishPartialProject(_ fixture: DemoEditingFixture) async throws {
        let before = try fixture.libraryEntries()
        let hashes = try fixture.sourceHashes()
        var invalidRejected = false
        do {
            _ = try await fixture.store.createDemoCut(from: fixture.project,
                keepRanges: [.init(start: 0, end: 7)], title: nil)
        } catch DemoEditError.invalidRanges { invalidRejected = true }
        try expect(invalidRejected, "Out-of-duration ranges must be refused")
        try expect(try fixture.libraryEntries() == before, "Invalid ranges must not create a project directory")

        let store = fixture.store
        let source = fixture.project
        let task = Task { try await store.createDemoCut(from: source, keepRanges: ranges, title: "Cancelled") }
        // This task inherits MainActor and cannot start before cancellation.
        task.cancel()
        var cancellationRejected = false
        do { _ = try await task.value } catch { cancellationRejected = true }
        try expect(cancellationRejected, "A pre-cancelled cut must not succeed")
        try expect(try fixture.libraryEntries() == before, "Cancellation must remove its temporary project and movie")

        var missingDependency = fixture.project
        missingDependency.settings.backgroundImagePath = fixture.root.appendingPathComponent("missing.png").path
        var dependencyRejected = false
        do { _ = try await fixture.store.createDemoCut(from: missingDependency, keepRanges: ranges, title: nil) }
        catch { dependencyRejected = true }
        try expect(dependencyRejected, "A missing dependency must not silently alter the derived video's appearance")
        try expect(try fixture.libraryEntries() == before, "Failure after materializing video must not publish a partial project")
        try expect(try fixture.sourceHashes() == hashes, "All failed edits must leave source bytes untouched")
    }

    private static func modelOpensDerivedContextAndRefusesBusy(_ fixture: DemoEditingFixture) async throws {
        let model = StudioModel(store: fixture.store, interactionTrackingAccess: { true }, inputMonitoringAccess: { true }, screenCaptureAccess: { true })
        await model.reloadProjects()
        model.open(fixture.project)
        let context = model.assistantSession.context
        let before = try fixture.libraryEntries()
        model.isBusy = true
        var refused = false
        do { _ = try await model.createDemoCut(projectID: fixture.project.id, keepRanges: ranges, title: "Busy") }
        catch { refused = true }
        try expect(refused && model.activeProject?.id == fixture.project.id && model.destination == .editor,
                   "A busy refusal must preserve the current editor")
        try expect(try fixture.libraryEntries() == before, "A busy model must not start a background cut")
        model.isBusy = false
        let edited = try await model.createDemoCut(projectID: fixture.project.id, keepRanges: ranges, title: "Assistant edit")
        try expect(!model.isBusy && model.destination == .editor && model.activeProject?.id == edited.id,
                   "A successful cut must open the new project and clear busy state")
        try expect(context.readProject()?.id == edited.id && context.readProject()?.duration == 3,
                   "The already-created assistant context must now read the edited timeline")
        try expect(model.project(id: fixture.project.id) != nil && model.project(id: edited.id) != nil,
                   "The model library must contain the preserved original and new edit")
        model.closeEditor()
        await model.flushProjectEdits()
    }

    private static func timelineWorkingCopyAndUndo(_ fixture: DemoEditingFixture) async throws {
        let source = fixture.project
        let sourceHashes = try fixture.sourceHashes()
        let before = try fixture.libraryEntries()
        let model = StudioModel(store: fixture.store, interactionTrackingAccess: { true },
                                inputMonitoringAccess: { true }, screenCaptureAccess: { true })
        await model.reloadProjects()
        model.open(source)
        do {
            _ = try await model.applyVideoEdit(projectID: source.id, operation: .split(clipID: source.id, at: 0.02))
            throw DemoEditingFailure("A split too close to the edge should fail")
        } catch DemoVideoTimelineError.invalidOperation { }
        try expect(try fixture.libraryEntries() == before && model.activeProject?.id == source.id,
                   "An invalid clip edit must not publish a project or close the editor")

        let working = try await model.applyVideoEdit(projectID: source.id,
            operation: .split(clipID: source.id, at: 2))
        guard let first = working.videoClips?.first, let second = working.videoClips?.last else {
            throw DemoEditingFailure("Splitting the source should create two editable clips")
        }
        try expect(working.id != source.id && first.id == source.id && first.duration == 2 && second.duration == 4,
                   "The first clip edit should create one working copy with a stable source clip ID")
        try expect(try fixture.libraryEntries().count == before.count + 1 && model.activeProject?.id == working.id,
                   "The first edit should open exactly one new working project")
        try expect(try fixture.sourceHashes() == sourceHashes,
                   "Clip edits must not change the source movie or source project JSON")
        try expect(try Data(contentsOf: URL(fileURLWithPath: source.sourceVideoPath))
                    == Data(contentsOf: URL(fileURLWithPath: working.sourceVideoPath)),
                   "The working project owns a byte-identical copy of its immutable source")

        let transition = try await model.applyVideoEdit(projectID: working.id,
            operation: .setTransition(fromClipID: first.id, preset: .fadeToBlack, duration: 0.4))
        try expect(transition.id == working.id && transition.videoTransitions?.first?.preset == .fadeToBlack,
                   "Transition edits stay in the same working project")
        let quieter = try await model.applyVideoEdit(projectID: working.id,
            operation: .setClipAudio(clipID: first.id, volume: 0.25))
        try expect(quieter.videoClips?.first?.sourceAudioVolume == 0.25,
                   "Source audio can be adjusted per clip without touching background music")
        let trimmed = try await model.applyVideoEdit(projectID: working.id,
            operation: .trim(clipID: first.id, sourceStart: 0, sourceEnd: 1.5))
        try expect(abs(trimmed.duration - 5.5) < 0.000_001,
                   "Trimming one clip changes the whole timeline duration")
        let moved = try await model.applyVideoEdit(projectID: working.id,
            operation: .move(clipID: second.id, toIndex: 0))
        try expect(moved.videoClips?.first?.id == second.id && moved.id == working.id,
                   "Reordering clips changes their sequence without creating another project")
        let shortened = try await model.applyVideoEdit(projectID: working.id,
            operation: .delete(clipID: first.id))
        try expect(shortened.videoClips?.count == 1 && abs(shortened.duration - 4) < 0.000_001,
                   "Deleting a clip removes its footage and retimes the remaining sequence")
        try expect(model.canUndoVideoEdit(projectID: working.id), "The working timeline should offer Undo")
        let restored = try await model.undoVideoEdit(projectID: working.id)
        try expect(restored.videoClips?.count == 2 && restored.videoClips?.first?.id == second.id,
                   "Undo restores the previous clip sequence in the same working project")
        let loaded = try await fixture.store.loadProjects()
        try expect(loaded.first(where: { $0.id == working.id })?.videoClips == restored.videoClips,
                   "The last timeline edit must survive project reload")
        let afterSourceHashes = try fixture.sourceHashes()
        let afterLibraryCount = try fixture.libraryEntries().count
        try expect(afterSourceHashes == sourceHashes && afterLibraryCount == before.count + 1,
                   "Repeated edits and Undo leave the original untouched and publish only one copy")

        let cut = try await model.createDemoCut(projectID: working.id,
            keepRanges: [.init(start: 0, end: 1), .init(start: 4.2, end: 5.5)],
            title: "Cut after clip rearrangement")
        try expect(cut.id != working.id && abs(cut.duration - 2.3) < 0.000_001
                   && cut.videoClips?.count == 2 && cut.videoSourceDuration == 6,
                   "Pacing cuts from an edited clip timeline must select the visible sequence, not the raw movie's first seconds")
        let prepared = try await ProjectVideoRenderer.prepare(project: cut)
        try expect(abs(prepared.duration - cut.duration) < 0.01,
                   "The derived clip cut must prepare a player/export composition of its edited length")
        try expect(try fixture.sourceHashes() == sourceHashes,
                   "A second-generation cut cannot change the initial source project")
    }

    private static func editorMediaLibraryAndRedo(_ fixture: DemoEditingFixture) async throws {
        let source = fixture.project
        let sourceHashes = try fixture.sourceHashes()
        let model = StudioModel(store: fixture.store, interactionTrackingAccess: { true },
                                inputMonitoringAccess: { true }, screenCaptureAccess: { true })
        await model.reloadProjects()
        model.open(source)
        let image = fixture.root.appendingPathComponent("frame.png")
        let movie = fixture.root.appendingPathComponent("original.mp4")
        let invalid = fixture.root.appendingPathComponent("broken.mov")
        try Data("not a movie".utf8).write(to: invalid)
        let entriesBefore = try fixture.libraryEntries()
        var invalidRejected = false
        do { _ = try await model.importEditorMedia(from: [image, invalid], projectID: source.id) }
        catch { invalidRejected = true }
        try expect(invalidRejected && model.activeProject?.id == source.id,
                   "A bad file in a batch must be refused before creating a working copy")
        try expect(try fixture.libraryEntries() == entriesBefore, "Invalid import must not publish a project")

        let working = try await model.importEditorMedia(from: [image, movie], projectID: source.id)
        try expect(working.id != source.id && working.mediaAssets?.count == 2,
                   "Import branches the original into one working media library")
        guard let assets = working.mediaAssets,
              let still = assets.first(where: { $0.kind == .image }),
              let video = assets.first(where: { $0.kind == .video }) else {
            throw DemoEditingFailure("Expected copied image and movie assets")
        }
        let workingDirectory = fixture.store.projectsDirectory.appendingPathComponent(working.id.uuidString)
        for asset in assets {
            try expect(asset.filePath.hasPrefix(workingDirectory.path + "/media/")
                       && FileManager.default.fileExists(atPath: asset.filePath),
                       "Imported media must be a project-owned file")
        }
        try expect(abs(video.duration - 6) < 0.01 && still.duration == 0,
                   "Media inspection retains movie duration and treats a still as duration-free")
        let metadata = try Data(contentsOf: workingDirectory.appendingPathComponent("project.json"))
        let json = try JSONSerialization.jsonObject(with: metadata) as? [String: Any]
        let persistedPaths = (json?["mediaAssets"] as? [[String: Any]])?.compactMap { $0["filePath"] as? String } ?? []
        try expect(persistedPaths.count == 2 && persistedPaths.allSatisfy { $0.hasPrefix("media/") },
                   "Project metadata stores portable relative paths")
        let reloaded = try await fixture.store.loadProjects().first(where: { $0.id == working.id })
        try expect(reloaded?.mediaAssets?.map(\.filePath) == assets.map(\.filePath),
                   "Project reload resolves asset paths for preview and export")

        let inserted = try await model.insertEditorMedia(projectID: working.id, assetID: still.id, atIndex: 1)
        try expect(inserted.videoClips?.count == 2 && abs(inserted.duration - 9) < 0.01,
                   "Dragging an image onto the video track inserts a 3-second editable clip")
        try expect(model.canUndoVideoEdit(projectID: working.id), "Media insertion can be undone")
        let undone = try await model.undoVideoEdit(projectID: working.id)
        try expect(abs(undone.duration - 6) < 0.01 && model.canRedoVideoEdit(projectID: working.id),
                   "Undo restores duration and enables Redo")
        let redone = try await model.redoVideoEdit(projectID: working.id)
        try expect(abs(redone.duration - 9) < 0.01 && redone.videoClips == inserted.videoClips,
                   "Redo replays the inserted clip without copying media again")
        var renamed = redone
        renamed.title = "Edited title"
        try expect(model.updateActiveProject(renamed), "The open editor accepts a title change")
        let titleUndone = try await model.undoVideoEdit(projectID: working.id)
        try expect(titleUndone.title == redone.title && titleUndone.videoClips == redone.videoClips,
                   "Undo also restores ordinary editor metadata without discarding the timeline")
        let titleRedone = try await model.redoVideoEdit(projectID: working.id)
        try expect(titleRedone.title == "Edited title", "Redo restores the editor title change")
        let copied = try await fixture.store.createVideoEditingCopy(from: redone, edited: redone, title: "Next working copy")
        try expect(copied.mediaAssets?.count == 2
                   && copied.mediaAssets?.allSatisfy { $0.filePath.contains(copied.id.uuidString) } == true,
                   "A derived project carries its imported media independently")
        try expect(try fixture.sourceHashes() == sourceHashes,
                   "Import, insertion and Undo/Redo must leave the original recording unchanged")
    }

    private static func close(_ actual: [Double], _ expected: [Double]) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0 - $1) < 0.000_001 }
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw DemoEditingFailure(message) }
    }
}

private struct DemoEditingFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

@MainActor
private final class DemoEditingFixture {
    let root: URL
    let store: ProjectStore
    let project: RecordingProject
    let clickIDs: [UUID]

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FocusStudio-DemoEditing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(projectsDirectory: root.appendingPathComponent("Projects", isDirectory: true))
        let image = root.appendingPathComponent("frame.png")
        try Self.writeImage(image)
        let clip = root.appendingPathComponent("original.mp4")
        _ = try await StillImageVideoBuilder.build(from: image, to: clip, duration: 6, renderSize: CGSize(width: 64, height: 64))
        let clicks = [0.5, 2, 3.5, 4.8].enumerated().map { index, time in
            ClickEvent(time: time, x: Double(index + 1) / 5, y: 0.4, button: .left)
        }
        clickIDs = clicks.map(\.id)
        var created = try await store.createProject(from: clip, title: "Original six seconds", cursorSamples: [], clickEvents: clicks)
        created.interactionTrace = .init(sessionID: UUID(), source: .execution, events: clicks.enumerated().map { index, click in
            .init(id: click.id, sequence: index, time: click.time, kind: .click, x: click.x, y: click.y)
        })
        created.interactionTrace?.typingActivity = [.init(time: 2.5, x: 0.3, y: 0.4), .init(time: 3.8, x: 0.6, y: 0.4)]
        created.typingActivity = [.init(time: 0.7, x: 0.95, y: 0.95)]
        created.zoomSegments = [
            .init(start: 0.1, end: 0.9, targetX: 0.2, targetY: 0.4, scale: 1.5),
            .init(start: 2.5, end: 4.5, targetX: 0.6, targetY: 0.4, scale: 1.8),
        ]
        created.chapters = [.init(start: 0, end: 1, title: "Intro"), .init(start: 1, end: 5, title: "Result")]
        created.settings.backgroundImagePath = try await store.importBackgroundImage(from: image, for: created)
        let sound = root.appendingPathComponent("tone.wav")
        try Self.writeWave(sound)
        let music = try await store.importBackgroundMusic(from: sound, for: created)
        created.settings.productDemoAudio = .init(backgroundMusicPath: music, clickSoundPath: music, zoomTransitionSoundPath: music)
        try await store.save(created)
        project = created
    }

    func sourceHashes() throws -> [String] {
        let metadata = store.projectsDirectory.appendingPathComponent("\(project.id.uuidString)/project.json")
        return try [URL(fileURLWithPath: project.sourceVideoPath), metadata].map {
            SHA256.hash(data: try Data(contentsOf: $0)).map { String(format: "%02x", $0) }.joined()
        }
    }

    func assetURLs(_ project: RecordingProject) throws -> [URL] {
        guard let image = project.settings.backgroundImagePath,
              let audio = project.settings.productDemoAudio,
              let music = audio.backgroundMusicPath, let click = audio.clickSoundPath, let zoom = audio.zoomTransitionSoundPath else {
            throw DemoEditingFailure("Expected all fixture assets")
        }
        return [image, music, click, zoom].map { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : store.projectsDirectory.appendingPathComponent("\(project.id.uuidString)/\(path)")
        }
    }

    func libraryEntries() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: store.projectsDirectory.path))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    private static func writeImage(_ url: URL) throws {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DemoEditingFailure("Could not create fixture image")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage(),
              let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw DemoEditingFailure("Could not encode fixture image")
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw DemoEditingFailure("Could not save fixture image") }
    }

    private static func writeWave(_ url: URL) throws {
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        let count = 8_000
        ascii("RIFF"); u32(UInt32(36 + count * 2)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(8_000); u32(16_000); u16(2); u16(16); ascii("data"); u32(UInt32(count * 2))
        for index in 0..<count {
            let value = Int16(sin(Double(index) * .pi * 2 * 220 / 8_000) * 2_000)
            u16(UInt16(bitPattern: value))
        }
        try data.write(to: url)
    }
}
