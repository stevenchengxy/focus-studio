import CoreGraphics
import FocusStudioAutomation
import FocusStudioCapture
import FocusStudioCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Recorder-owned actions fail before touching the desktop when their session,
/// recording mode, pause state or observation is invalid. A scripted capture
/// also verifies that saving selects one authoritative interaction source.
@MainActor
enum RecordingActionRegression {
    static func run() async throws {
        // Reproduce Codex's signed, pass-through virtual cursor without reading
        // accessibility or sending input to any real desktop application.
        let cursorPoint = CGPoint(x: 802.39, y: 432.58)
        let cursorOverlay = CodexPlanRunner.InputWindow(id: 76265, layer: 8,
            frame: CGRect(x: 685, y: 315, width: 126, height: 126), ownerPID: 92433)
        let chromeWindow = CodexPlanRunner.InputWindow(id: 123, layer: 0,
            frame: CGRect(x: 0, y: 29, width: 1496, height: 933), ownerPID: 23192)
        func inputOwner(signed: Bool, exactWindow: Bool, additional: [CodexPlanRunner.InputWindow] = []) -> UInt32? {
            CodexPlanRunner.resolvedInputWindow(at: cursorPoint, in: [cursorOverlay] + additional + [chromeWindow],
                targetID: chromeWindow.id, isVerifiedCursorProcess: { $0 == cursorOverlay.ownerPID && signed },
                hitsExactTargetWindow: { exactWindow })?.id
        }
        precondition(inputOwner(signed: true, exactWindow: true) == chromeWindow.id,
                     "The observed 126-point Codex cursor can pass through to the exact prepared window")
        precondition(inputOwner(signed: false, exactWindow: true) == cursorOverlay.id
                     && inputOwner(signed: true, exactWindow: false) == cursorOverlay.id,
                     "Both verified running code and the exact AX window are mandatory")
        let systemDialog = CodexPlanRunner.InputWindow(id: 456, layer: 8, frame: cursorOverlay.frame, ownerPID: 777)
        precondition(inputOwner(signed: true, exactWindow: true, additional: [systemDialog]) == systemDialog.id,
                     "A system confirmation or unknown helper remains a blocker underneath the Codex cursor")
        let nativePoint = CGPoint(x: 1355.015, y: 178.002)
        let nativeCursor = CodexPlanRunner.InputWindow(id: 3, layer: Int(CGWindowLevelForKey(.cursorWindow)),
            frame: CGRect(x: 1350, y: 172, width: 28, height: 40), ownerPID: 172)
        func nativeInputOwner(signed: Bool, exactWindow: Bool) -> UInt32? {
            CodexPlanRunner.resolvedInputWindow(at: nativePoint, in: [nativeCursor, chromeWindow], targetID: chromeWindow.id,
                isVerifiedCursorProcess: { _ in false }, isVerifiedSystemCursorProcess: { $0 == nativeCursor.ownerPID && signed },
                hitsExactTargetWindow: { exactWindow })?.id
        }
        precondition(nativeInputOwner(signed: true, exactWindow: true) == chromeWindow.id,
                     "The reproduced 28x40 native cursor plane cannot interrupt a valid Send approach")
        precondition(nativeInputOwner(signed: false, exactWindow: true) == nativeCursor.id
                     && nativeInputOwner(signed: true, exactWindow: false) == nativeCursor.id,
                     "The system-cursor exception requires both the running Apple code identity and exact AX target")
        precondition(StudioModel.codexInputIsActive(engineState: .recording, isBusy: false, isPaused: false, isTransitioning: false))
        for state: RecordingState in [.idle, .preparing, .stopping, .completed(URL(fileURLWithPath: "/tmp/fixture.mp4")), .failed("fixture")] {
            precondition(!StudioModel.codexInputIsActive(engineState: state, isBusy: false, isPaused: false, isTransitioning: false),
                         "Preparing and stopping are not input-enabled recording states")
        }
        precondition(!StudioModel.codexInputIsActive(engineState: .recording, isBusy: true, isPaused: false, isTransitioning: false),
                     "Discard blocks input immediately, before the engine starts flushing")
        precondition(!StudioModel.codexInputIsActive(engineState: .recording, isBusy: false, isPaused: true, isTransitioning: false)
                     && !StudioModel.codexInputIsActive(engineState: .recording, isBusy: false, isPaused: false, isTransitioning: true))
        let captured = CaptureRect(x: 100, y: 100, width: 1000, height: 700)
        precondition(StudioModel.recordingWindowSizeMatches(CGRect(x: 400, y: 200, width: 1000, height: 700), captured: captured),
                     "Moving without resizing does not change the captured pixel mapping")
        precondition(StudioModel.recordingWindowSizeMatches(CGRect(x: 100, y: 100, width: 1000.4, height: 700), captured: captured),
                     "Subpixel metadata rounding stays within half a logical point")
        precondition(!StudioModel.recordingWindowSizeMatches(CGRect(x: 100, y: 100, width: 1001, height: 700), captured: captured)
                     && !StudioModel.recordingWindowSizeMatches(CGRect(x: 100, y: 100, width: 1000, height: 800), captured: captured),
                     "Either resized dimension invalidates the fixed-size recording mapping")

        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let click = CodexRecordingAction(type: .click, x: 0.2, y: 0.3)
        let observationID = UUID()
        let manualID = try model.startRecording(target: fixture.target, options: .init(automaticZooms: true))
        try await refused("countdown is not live", containing: "no longer live") {
            _ = try await model.performRecordingAction(recordingID: manualID, actionID: "countdown", observationID: observationID, action: click)
        }
        try await refused("countdown text is not live", containing: "no longer live") {
            _ = try await model.performRecordingText(recordingID: manualID, actionID: "countdown-text", observationID: observationID, text: "demo")
        }
        try await fixture.runCountdown()
        precondition(model.recordingInteractionTrace == nil)
        try await refused("manual recording", containing: "manual recording") {
            _ = try await model.performRecordingAction(recordingID: manualID, actionID: "manual", observationID: observationID, action: click)
        }
        try await refused("manual text recording", containing: "manual recording") {
            _ = try await model.performRecordingText(recordingID: manualID, actionID: "manual-text", observationID: observationID, text: "demo")
        }
        try await refused("manual observation", containing: "Codex window recording") {
            _ = try await model.captureRecordingFrame(recordingID: manualID, to: fixture.root.appendingPathComponent("never-manual.png"))
        }
        await model.stopRecording()
        precondition(model.activeProject?.interactionTrace == nil)
        precondition(model.activeProject?.clickEvents.count == 1 && model.activeProject?.clickEvents.first?.x == 0.9,
                     "Manual capture retains the actual system clicks")
        precondition(model.activeProject?.resolvedTypingActivity == [.init(time: 1, x: 0.9, y: 0.9)],
                     "Manual recording retains its existing physical typing timing")
        precondition(model.activeProject?.zoomSegments.isEmpty == false,
                     "Manual clicks continue to generate automatic zooms")

        let id = try model.startRecording(target: fixture.target, options: .init(automaticZooms: true, interactionMode: "codex"))
        try await fixture.runCountdown()
        precondition(model.recordingInteractionTrace?.sessionID == id && model.recordingInteractionTrace?.source == .execution)
        let firstTyping = TypingActivity(time: 0.4, x: 0.2, y: 0.3)
        model.appendCodexTypingActivity(recordingID: id, activity: firstTyping)
        model.appendCodexTypingActivity(recordingID: manualID, activity: .init(time: 0.5, x: 0.9, y: 0.9))
        for invalid in [TypingActivity(time: .nan, x: 0.2, y: 0.3), .init(time: -1, x: 0.2, y: 0.3),
                        .init(time: 0.6, x: 1.1, y: 0.3), .init(time: 0.3, x: 0.2, y: 0.3)] {
            model.appendCodexTypingActivity(recordingID: id, activity: invalid)
        }
        precondition(model.recordingInteractionTrace?.typingActivity == [firstTyping]
                     && model.recordingInteractionTrace?.events.isEmpty == true,
                     "Typing records only valid activity for its live owner, without moving the execution cursor")
        let ownedTrace = model.recordingInteractionTrace
        model.recordingInteractionTrace?.sessionID = UUID()
        model.appendCodexTypingActivity(recordingID: id, activity: .init(time: 0.6, x: 0.2, y: 0.3))
        precondition(model.recordingInteractionTrace?.typingActivity == [firstTyping],
                     "A callback cannot append into a trace belonging to a different recording")
        model.recordingInteractionTrace = ownedTrace
        model.recordingInteractionTrace?.source = .system
        model.appendCodexTypingActivity(recordingID: id, activity: .init(time: 0.6, x: 0.2, y: 0.3))
        precondition(model.recordingInteractionTrace?.typingActivity == [firstTyping],
                     "A Codex text callback cannot become physical-source activity")
        model.recordingInteractionTrace = ownedTrace
        try await refused("stale session", containing: "no longer live") {
            _ = try await model.performRecordingAction(recordingID: manualID, actionID: "old", observationID: observationID, action: click)
        }
        try await refused("stale text session", containing: "no longer live") {
            _ = try await model.performRecordingText(recordingID: manualID, actionID: "stale-text", observationID: observationID, text: "demo")
        }
        try await refused("missing observation", containing: "Missing, stale") {
            _ = try await model.performRecordingAction(recordingID: id, actionID: "unobserved", observationID: observationID, action: click)
        }
        model.recordingObservation = RecordingObservation(id: observationID, recordingID: id, frame: .zero,
                                                          uptime: ProcessInfo.processInfo.systemUptime - 61)
        try await refused("expired observation", containing: "Missing, stale") {
            _ = try await model.performRecordingAction(recordingID: id, actionID: "expired", observationID: observationID, action: click)
        }
        model.recordingObservation = RecordingObservation(id: observationID, recordingID: manualID, frame: .zero,
                                                          uptime: ProcessInfo.processInfo.systemUptime)
        try await refused("observation from another session", containing: "Missing, stale") {
            _ = try await model.performRecordingAction(recordingID: id, actionID: "foreign", observationID: observationID, action: click)
        }
        try await refused("unsupported live action", containing: "Only move, click and scroll") {
            _ = try await model.performRecordingAction(recordingID: id, actionID: "navigate", observationID: observationID,
                                                       action: .init(type: .navigate, url: "https://example.com"))
        }
        model.isPerformingRecordingAction = true
        try await refused("overlapping action", containing: "still running") {
            _ = try await model.performRecordingAction(recordingID: id, actionID: "overlap", observationID: observationID, action: click)
        }
        model.isPerformingRecordingAction = false
        model.appendCodexTypingActivity(recordingID: id, activity: .init(time: 1.2, x: 0.2, y: 0.3))
        fixture.clock.advance(by: 1)
        await model.toggleRecordingPause()
        precondition(model.isRecordingPaused)
        model.appendCodexTypingActivity(recordingID: id, activity: .init(time: 1.5, x: 0.2, y: 0.3))
        precondition(model.recordingInteractionTrace?.typingActivity == [firstTyping],
                     "Pause trims activity beyond the flushed media tail and rejects input while paused")
        try await refused("paused input", containing: "paused") {
            _ = try await model.performRecordingAction(recordingID: id, actionID: "paused", observationID: observationID, action: click)
        }
        try await refused("paused observation", containing: "unpaused") {
            _ = try await model.captureRecordingFrame(recordingID: id, to: fixture.root.appendingPathComponent("never-paused.png"))
        }
        try await refused("paused text", containing: "unpaused") {
            _ = try await model.performRecordingText(recordingID: id, actionID: "paused-text", observationID: observationID, text: "demo")
        }
        let previousReceipt: AIJSONValue = ["status": "performed", "action_id": "one-click", "trace_events": 4]
        model.recordingActionReceipts["one-click"] = previousReceipt
        let replay = try await model.performRecordingAction(recordingID: id, actionID: "one-click", observationID: observationID, action: click)
        precondition(replay == previousReceipt && model.recordingInteractionTrace?.events.isEmpty == true,
                     "An uncertain response is retrievable without another click, even during a pause")
        let textReceipt: AIJSONValue = ["status": "interrupted", "action": "type_text", "action_id": "text-once", "typed_characters": 4]
        model.recordingActionReceipts["text-once"] = textReceipt
        let textReplay = try await model.performRecordingText(recordingID: id, actionID: "text-once", observationID: observationID, text: "do not repeat")
        precondition(textReplay == textReceipt, "Partial text entry must never repeat after a transport retry or pause")
        await model.toggleRecordingPause()
        precondition(!model.isRecordingPaused)
        let resumedTyping = TypingActivity(time: 1.5, x: 0.2, y: 0.3)
        model.appendCodexTypingActivity(recordingID: id, activity: resumedTyping)
        let recordedTyping = [firstTyping, resumedTyping]
        precondition(model.recordingInteractionTrace?.typingActivity == recordedTyping,
                     "A resumed capture records media-time typing independently of physical input")
        let executionClick = InteractionEvent(sequence: 2, time: 1, kind: .click, x: 0.2, y: 0.3)
        let trace = InteractionTrace(sessionID: id, source: .execution, events: [
            .init(sequence: 0, time: 0.1, kind: .move, x: 0.5, y: 0.5),
            .init(sequence: 1, time: 0.8, kind: .move, x: 0.2, y: 0.3),
            executionClick,
        ], typingActivity: recordedTyping)
        model.recordingInteractionTrace = trace
        await model.stopRecording()
        guard let project = model.activeProject else { preconditionFailure("Stop must open the editable recording") }
        precondition(project.interactionTrace == trace && project.clickEvents.map(\.id) == [executionClick.id],
                     "Saved Codex recording uses execution clicks and discards unrelated physical clicks")
        precondition(project.typingActivity == recordedTyping && project.resolvedTypingActivity == recordedTyping,
                     "Saved project and authoritative trace retain only Codex typing timing")
        precondition(project.cursorSamples.allSatisfy { $0.x != 0.9 }
                     && project.resolvedInteractions.cursorSamples.count == 3,
                     "The saved cursor follows exactly the same source as its zoom clicks")
        precondition(!project.zoomSegments.isEmpty && project.zoomSegments.allSatisfy { abs($0.targetX - 0.2) < 1e-9 },
                     "Automatic zoom targets the execution click rather than the physical pointer")
        let reloaded = try await fixture.store.loadProjects().first { $0.id == project.id }
        precondition(reloaded?.interactionTrace == trace && reloaded?.resolvedInteractions.clickEvents.first?.id == executionClick.id,
                     "Trace identity and provenance survive saving and loading")
        precondition(reloaded?.resolvedTypingActivity == recordedTyping,
                     "Actual project save and reopen preserve executed typing for subsequent pacing analysis")
        precondition(model.recordingInteractionTrace == nil)
        model.appendCodexTypingActivity(recordingID: id, activity: .init(time: 2, x: 0.2, y: 0.3))
        precondition(model.recordingInteractionTrace == nil && model.activeProject?.resolvedTypingActivity == recordedTyping,
                     "A callback after stop cannot create a new trace or modify the saved project")
        try await refused("finished session", containing: "no longer live") {
            _ = try await model.performRecordingAction(recordingID: id, actionID: "after-stop", observationID: observationID, action: click)
        }
        try await refused("finished text session", containing: "no longer live") {
            _ = try await model.performRecordingText(recordingID: id, actionID: "ended-text", observationID: observationID, text: "demo")
        }
        var display = fixture.target
        display.kind = .display
        do {
            _ = try model.startRecording(target: display, options: .init(interactionMode: "codex"))
            preconditionFailure("Codex mode must require a window")
        } catch is AIToolError { }
        let discardID = try model.startRecording(target: fixture.target, options: .init(interactionMode: "codex"))
        try await fixture.runCountdown()
        model.appendCodexTypingActivity(recordingID: id, activity: .init(time: 0.2, x: 0.2, y: 0.3))
        precondition(model.recordingInteractionTrace?.typingActivity == nil,
                     "An old recording cannot add typing evidence to a later recording")
        fixture.state.holdDiscard = true
        let discarding = Task { @MainActor in await model.cancelRecording() }
        try await RecordingSessionRegression.waitUntil("Discard must begin") { fixture.state.discards == 1 }
        precondition(model.isBusy && model.currentRecording?.isLive == true,
                     "The discard flush is asynchronous while the attempt still exists")
        try await refused("discarding input", containing: "no longer live") {
            _ = try await model.performRecordingAction(recordingID: discardID, actionID: "discarding", observationID: observationID, action: click)
        }
        try await refused("discarding text", containing: "no longer live") {
            _ = try await model.performRecordingText(recordingID: discardID, actionID: "discarding-text", observationID: observationID, text: "demo")
        }
        try await refused("discarding observation", containing: "unpaused") {
            _ = try await model.captureRecordingFrame(recordingID: discardID, to: fixture.root.appendingPathComponent("never-discard.png"))
        }
        fixture.state.holdDiscard = false
        await discarding.value
        precondition(model.recordingSession?.outcome == .cancelled)

        precondition(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("never-manual.png").path)
                     && !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("never-paused.png").path)
                     && !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("never-discard.png").path))
        print("RecordingActionRegression: PASS (manual and Codex save paths, automatic zooms, trace persistence, stale/missing/paused/overlapping action refusal, idempotent receipts; no desktop input)")
    }

    private static func refused(_ label: String, containing expected: String, _ action: () async throws -> Void) async throws {
        do {
            try await action()
            preconditionFailure("\(label) must be refused")
        } catch let error as AIToolError {
            precondition(String(describing: error).contains(expected), "\(label): \(error)")
        }
    }

    @MainActor
    private final class State {
        var intervals = RecordingPauseClock()
        var holdDiscard = false
        var discards = 0
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let store: ProjectStore
        let clock = ManualRecordingClock()
        let state = State()
        let model: StudioModel
        let target = CaptureTargetInfo(id: "window-trace-fixture", kind: .window, nativeID: 4_242_424,
                                       title: "Fixture", frame: CaptureRect(x: 0, y: 0, width: 64, height: 64))

        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("FocusStudio-Action-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = ProjectStore(projectsDirectory: root.appendingPathComponent("Projects", isDirectory: true))
            let imageURL = root.appendingPathComponent("frame.png")
            let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(destination))
            let clip = root.appendingPathComponent("capture.mp4")
            _ = try await StillImageVideoBuilder.build(from: imageURL, to: clip, duration: 3, renderSize: CGSize(width: 64, height: 64))
            let clock = self.clock, target = self.target, state = self.state
            model = StudioModel(
                store: store, interactionTrackingAccess: { true }, inputMonitoringAccess: { true }, screenCaptureAccess: { true },
                finishCapture: { _ in
                    RecordingResult(outputURL: clip, duration: 3, sourceWidth: 64, sourceHeight: 64,
                                    cursorSamples: [.init(time: 0.2, x: 0.9, y: 0.9), .init(time: 1, x: 0.9, y: 0.9)],
                                    clickEvents: [.init(time: 1, x: 0.9, y: 0.9, button: .left)], target: target,
                                    typingActivity: [.init(time: 1, x: 0.9, y: 0.9)])
                },
                startCapture: { _, _, _, _ in state.intervals = RecordingPauseClock(); state.intervals.anchor(at: clock.now); return clock.now },
                cancelCapture: { _ in }, discardCapture: { _ in
                    state.discards += 1
                    while state.holdDiscard { try? await Task.sleep(for: .milliseconds(5)) }
                    return .trashed
                },
                pauseCapture: CapturePauseControl(pause: { _ in state.intervals.pause(at: clock.now) },
                                                  resume: { _ in state.intervals.anchor(at: clock.now) }, intervals: { _ in state.intervals }),
                recordingClock: clock.clock
            )
            model.prepareRecordingTarget = { _ in }
            model.activateAfterStop = { }
        }

        func runCountdown() async throws {
            for _ in 1...3 {
                try await RecordingSessionRegression.waitUntil("Action fixture countdown") { clock.sleeperCount == 1 }
                clock.advance(by: 1)
            }
            try await RecordingSessionRegression.waitUntil("Action fixture first frame") { model.recordingPhase == .recording }
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
