import CoreGraphics
import FocusStudioAutomation
import FocusStudioCapture
import FocusStudioCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// StudioModel behaviour the assistant (and later external clients) relies on:
/// dropped editor writes surface as errors, exports know the library root,
/// concurrent bootstraps all wait for the loaded library, a second stop joins
/// the one in flight (and a late one changes nothing), and a refused Screen
/// Recording permission is reported as such, until the next start. Everything
/// runs against a temporary library; no capture, network or real secrets are touched.
@MainActor
enum AssistantControlRegression {
    static func run() async throws {
        try await droppedEditsThrow()
        try await concurrentBootstrapWaitsForLibrary()
        try await secondStopJoinsTheFirst()
        try await permissionFailureIsReported()
        try await automationReadsStayPut()
        print("AssistantControlRegression: PASS (dropped assistant edits throw, export library guard wiring, concurrent bootstrap, joined stops with one finalization, permission failure reporting, get_project/get_status read the model without navigating)")
    }

    /// get_project and get_status read StudioModel through AppControlling: the
    /// editor's copy of the open project, the library's copy of any other,
    /// never a navigation, and permissions from the non-prompting probes.
    private static func automationReadsStayPut() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = StudioModel(store: fixture.store, interactionTrackingAccess: { true }, inputMonitoringAccess: { false }, screenCaptureAccess: { false })
        var first = RecordingProject(title: "Open one", sourceVideoPath: "raw.mp4", duration: 10, sourceWidth: 1280, sourceHeight: 720)
        first.clickEvents = [ClickEvent(time: 2, x: 0.25, y: 0.5, button: .left)]
        let second = RecordingProject(title: "Library one", sourceVideoPath: "raw.mp4", duration: 6, sourceWidth: 640, sourceHeight: 360)
        for project in [first, second] { try await fixture.store.save(project) }
        model.projects = [first, second]
        model.open(first)
        var edited = first
        edited.title = "Edited in the editor"
        try expect(model.updateActiveProject(edited), "The editor must take the edit")
        let context = model.assistantSession.context

        let other = try await GetProjectTool().run(arguments: ["project_id": second.id.uuidString], context: context, progress: { _ in })
        try expect(model.destination == .editor && model.activeProject?.id == first.id, "get_project must not open another project")
        try expect(other.data?["title"] == "Library one" && other.data?["open_in_editor"] == false && other.data?["duration"] == 6,
                   "A closed project is read from the library, got \(other.data.map { "\($0)" } ?? "nil")")
        let expectedAssets = fixture.store.projectsDirectory.appendingPathComponent("\(second.id.uuidString)/ai").path
        try expect(other.data?["assets_dir"]?.stringValue == expectedAssets, "A relative recording's assets folder is inside its library folder, got \(other.data?["assets_dir"]?.stringValue ?? "nil")")
        let open = try await GetProjectTool().run(arguments: ["project_id": first.id.uuidString], context: context, progress: { _ in })
        try expect(open.data?["title"] == "Edited in the editor" && open.data?["open_in_editor"] == true && open.data?["clicks"]?["count"] == 1,
                   "The open project is read from the editor")
        try expect(model.project(id: UUID()) == nil && model.project(id: second.id)?.title == "Library one", "Unknown ids read as nil")

        let status = try await GetStatusTool().run(arguments: [:], context: context, progress: { _ in })
        try expect(status.data?["library_count"] == 2 && status.data?["open_project_id"]?.stringValue == first.id.uuidString && status.data?["recording"]?["state"] == "idle",
                   "get_status reads the model, got \(status.data.map { "\($0)" } ?? "nil")")
        try expect(status.data?["permissions"] == ["screen_recording": false, "accessibility": true, "input_monitoring": false],
                   "Permissions come from the injected probes, got \(status.data?["permissions"].map { "\($0)" } ?? "nil")")
        try expect(model.permissionStatus == AIPermissionStatus(screenRecording: false, accessibility: true, inputMonitoring: false) && model.recordingElapsed == nil,
                   "Nothing is recording")
        try expect(model.libraryDirectory == fixture.store.projectsDirectory && model.destination == .editor, "The library root is the store's; reads never navigate")

        model.closeEditor()
        await model.flushProjectEdits()
        let closed = try await GetProjectTool().run(arguments: ["project_id": first.id.uuidString], context: context, progress: { _ in })
        try expect(closed.data?["title"] == "Edited in the editor" && closed.data?["open_in_editor"] == false && model.destination == .library,
                   "After closing, the saved edit is read from the library without reopening it")
    }

    private static func droppedEditsThrow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.makeModel()
        let project = RecordingProject(title: "Assistant edits", sourceVideoPath: "raw.mp4", duration: 10, sourceWidth: 1280, sourceHeight: 720)
        model.projects = [project]
        model.open(project)
        let context = model.assistantSession.context
        _ = try await AddZoomTool().run(arguments: ["start": 1, "end": 2, "x": 0.5, "y": 0.5], context: context, progress: { _ in })
        try expect(model.activeProject?.zoomSegments.count == 1 && model.projects[0].zoomSegments.count == 1, "An edit in the open editor must apply")

        // The app's context knows the library root, so an export can never
        // replace another project's recording.
        try expect(context.projectsDirectory?.standardizedFileURL == fixture.store.projectsDirectory.standardizedFileURL,
                   "The assistant context must carry the library root, got \(context.projectsDirectory?.path ?? "nil")")
        let otherRecording = fixture.store.projectsDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("raw.mp4")
        var guarded = false
        do {
            _ = try ExportProjectTool.resolveOutputURL(path: otherRecording.path, context: context, project: project, overwrite: true)
        } catch AIToolError.invalidArgument(let message) {
            guarded = message.contains("inside the Focus Studio library")
        }
        try expect(guarded, "An export into another project's folder must be refused")

        // The editor went away without clearing the project (or between a
        // tool's read and its write): the write is refused loudly.
        model.destination = .recorder
        var refused = false
        do {
            _ = try await AddZoomTool().run(arguments: ["start": 3, "end": 4, "x": 0.5, "y": 0.5], context: context, progress: { _ in })
        } catch AIToolError.noProject {
            refused = true
        }
        try expect(refused, "A dropped write must fail instead of reporting success")
        try expect(model.activeProject?.zoomSegments.count == 1 && model.projects[0].zoomSegments.count == 1, "A refused write must change nothing")
        refused = false
        do { try context.updateProject { $0.title = "Must not land" } } catch AIToolError.noProject { refused = true }
        try expect(refused && model.activeProject?.title == "Assistant edits", "The context itself must throw for a dropped write")

        // A different project in the editor is not edited by a call that read the first one.
        let other = RecordingProject(title: "Other", sourceVideoPath: "raw.mp4", duration: 10, sourceWidth: 1280, sourceHeight: 720)
        model.open(other)
        var switched = false
        do {
            try await AIToolSupport.edit(context, projectID: project.id) { $0.title = "Wrong project" }
        } catch AIToolError.failed {
            switched = true
        }
        try expect(switched && model.activeProject?.title == "Other", "An edit must not land in a project opened meanwhile")
        model.closeEditor()
        await model.flushProjectEdits()
    }

    private static func concurrentBootstrapWaitsForLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // Never touch the real ark.env, secrets or network from a test.
        let environment = ProcessInfo.processInfo.environment
        setenv("FOCUS_STUDIO_IMPORT_ARK_ENV", "0", 1)
        unsetenv("FOCUS_STUDIO_START_DESTINATION")
        unsetenv("FOCUS_STUDIO_ASSISTANT_PROMPT")
        defer {
            for key in ["FOCUS_STUDIO_IMPORT_ARK_ENV", "FOCUS_STUDIO_START_DESTINATION", "FOCUS_STUDIO_ASSISTANT_PROMPT"] {
                if let value = environment[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        for index in 1...3 {
            try await fixture.store.save(RecordingProject(title: "Library \(index)", sourceVideoPath: "raw.mp4", duration: 4, sourceWidth: 640, sourceHeight: 360))
        }
        let model = fixture.makeModel()
        // The first caller suspends while the store loads; the second used to
        // return at once and see an empty library.
        let first = Task { await model.bootstrap(); return model.projects.count }
        let second = Task { await model.bootstrap(); return model.projects.count }
        let counts = (await first.value, await second.value)
        try expect(counts == (3, 3), "Every bootstrap caller must see the loaded library, got \(counts)")

        try await fixture.store.save(RecordingProject(title: "Added later", sourceVideoPath: "raw.mp4", duration: 4, sourceWidth: 640, sourceHeight: 360))
        await model.bootstrap()
        try expect(model.projects.count == 3, "Bootstrap runs once; later calls reuse the finished pass")
    }

    private static func secondStopJoinsTheFirst() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let clip = try await fixture.makeClip()
        let finisher = ScriptedFinisher(clip: clip)
        let model = StudioModel(
            store: fixture.store,
            interactionTrackingAccess: { true },
            inputMonitoringAccess: { true },
            finishCapture: { _ in try await finisher.finish() }
        )
        model.destination = .recording
        var returned: [String] = []
        let first = Task { await model.stopRecording(); returned.append("first") }
        try await waitUntil("The first stop did not reach the capture") { finisher.calls == 1 }
        try expect(model.isFinishingRecording && model.recordingPhase == .stopping, "A stop in flight must read as stopping")
        let second = Task { await model.stopRecording(); returned.append("second") }
        try await Task.sleep(for: .milliseconds(150))
        try expect(returned.isEmpty && finisher.calls == 1, "A second stop must wait for the first, not finalize again")

        finisher.release()
        await first.value
        await second.value
        try expect(finisher.calls == 1, "The capture must be finalized exactly once, got \(finisher.calls)")
        try expect(Set(returned) == ["first", "second"], "Both stops must return")
        try expect(model.projects.count == 1 && model.destination == .editor && model.activeProject?.id == model.projects.first?.id,
                   "One project must be created and opened")
        try expect(try await fixture.store.loadProjects().count == 1, "Exactly one project must be saved")
        try expect(!model.isFinishingRecording && model.recordingPhase == .idle, "The stop must be over once the editor shows it")

        // A request arriving after the stop finished (a joined call, a second
        // click) finds nothing recording and must leave the new editor alone.
        await model.stopRecording()
        try expect(finisher.calls == 1 && !model.isShowingError && model.destination == .editor,
                   "A stop with nothing recording must change nothing")

        // With a recording showing again, a stop runs afresh (and here fails cleanly).
        model.destination = .recording
        await model.stopRecording()
        try expect(finisher.calls == 2 && model.isShowingError && model.destination == .recorder && model.projects.count == 1,
                   "A later stop must not be swallowed by the finished one")
    }

    private static func permissionFailureIsReported() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.makeModel()
        // What startRecordingNow leaves behind when ScreenCaptureKit refuses:
        // back on the recorder with the permission notice, no alert.
        let details = CaptureEngineError.screenRecordingPermissionDenied("Enable Focus Studio in System Settings.").localizedDescription
        model.destination = .recorder
        model.capturePermissionDenied = true
        model.captureFailureDetails = details
        try expect(model.recordingPhase == .idle, "A refused start is not a running recording")
        try expect(model.lastReportedError == details, "The permission notice must be the reported error, got \(model.lastReportedError ?? "nil")")
        model.captureFailureDetails = nil
        try expect(model.lastReportedError == L10n.tr("Screen Recording permission is required."), "A permission failure without details still names the permission")
        model.errorMessage = "Disk full"
        model.isShowingError = true
        try expect(model.lastReportedError == "Disk full", "A visible alert stays the reported error")
        model.isShowingError = false
        model.capturePermissionDenied = false
        try expect(model.lastReportedError == nil, "Nothing is reported once the notice is gone")

        // The next start clears what the refused one left, so its own outcome
        // (a cancelled countdown, say) is not read back as the old refusal.
        model.capturePermissionDenied = true
        model.captureFailureDetails = details
        let target = CaptureTargetInfo(id: "display-1", kind: .display, nativeID: 1, title: "Test display",
                                       frame: CaptureRect(x: 0, y: 0, width: 64, height: 64))
        let attempt = try model.startRecording(target: target, options: AIRecordingOptions())
        try expect(!model.capturePermissionDenied && model.captureFailureDetails == nil, "A new start must clear the last permission notice")
        try expect(model.lastReportedError == nil && model.recordingPhase == .countdown && model.recordingSession?.id == attempt,
                   "The start must report its own outcome, got \(model.lastReportedError ?? "nil")")
        model.cancelRecordingCountdown()
        try expect(model.recordingSession?.outcome == .cancelled && model.lastReportedError == nil && model.recordingPhase == .idle,
                   "A cancelled countdown reads as cancelled, not as the old refusal")

        // A capture start refused for the permission ends the attempt with that
        // failure, which start_recording reports instead of a cancelled countdown.
        let refusing = StudioModel(
            store: fixture.store, interactionTrackingAccess: { true }, inputMonitoringAccess: { true },
            startCapture: { _, _, _, _ in throw CaptureEngineError.screenRecordingPermissionDenied("Enable Focus Studio in System Settings.") },
            recordingClock: RecordingClock(now: { 0 }, sleep: { _ in })
        )
        let refused = try refusing.startRecording(target: target, options: AIRecordingOptions())
        try await waitUntil("The refused capture did not end the attempt") { refusing.recordingSession?.outcome != nil }
        try expect(refusing.recordingSession?.id == refused && refusing.recordingSession?.outcome == .failed(details) && refusing.capturePermissionDenied
                   && refusing.lastReportedError == details && refusing.recordingPhase == .idle && refusing.destination == .recorder,
                   "The permission failure is the attempt's outcome: \(String(describing: refusing.recordingSession?.outcome))")
    }

    private static func waitUntil(_ message: String, predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            if ContinuousClock.now >= deadline { throw AssistantRegressionFailure(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw AssistantRegressionFailure(message) }
    }
}

private struct AssistantRegressionFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Stands in for `CaptureEngine.stopRecording()`: counts calls, holds the
/// first one until released, then hands back a real clip; later calls fail
/// like an engine with nothing to stop.
@MainActor
private final class ScriptedFinisher {
    let clip: URL
    private(set) var calls = 0
    private var released = false

    init(clip: URL) { self.clip = clip }

    func release() { released = true }

    func finish() async throws -> RecordingResult {
        calls += 1
        guard calls == 1 else { throw CaptureEngineError.noActiveRecording }
        while !released { try await Task.sleep(for: .milliseconds(5)) }
        let frame = CaptureRect(x: 0, y: 0, width: 64, height: 64)
        return RecordingResult(
            outputURL: clip,
            duration: 1,
            sourceWidth: 64,
            sourceHeight: 64,
            cursorSamples: [],
            clickEvents: [],
            target: CaptureTargetInfo(id: "display-1", kind: .display, nativeID: 1, title: "Test display", frame: frame)
        )
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let store: ProjectStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FocusStudio-Assistant-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(projectsDirectory: root.appendingPathComponent("Projects", isDirectory: true))
    }

    func makeModel() -> StudioModel {
        StudioModel(store: store, interactionTrackingAccess: { true }, inputMonitoringAccess: { true })
    }

    /// A one-second H.264 clip so the stopped "recording" becomes a real project.
    func makeClip() async throws -> URL {
        let image = root.appendingPathComponent("frame.png")
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AssistantRegressionFailure("Could not create a bitmap context")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let frame = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(image as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AssistantRegressionFailure("Could not encode the clip frame")
        }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else { throw AssistantRegressionFailure("Could not write the clip frame") }
        let clip = root.appendingPathComponent("finished-recording.mp4")
        _ = try await StillImageVideoBuilder.build(from: image, to: clip, duration: 1, renderSize: CGSize(width: 64, height: 64))
        return clip
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
