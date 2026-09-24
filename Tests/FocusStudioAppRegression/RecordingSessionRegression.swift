import AppKit
import CoreGraphics
import FocusStudioAutomation
import FocusStudioCapture
import FocusStudioCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Recording sessions on the real StudioModel. The capture is scripted
/// (StudioModel's startCapture and finishCapture seams) and time runs on a
/// manual clock, so nothing captures the screen, prompts for a permission or
/// waits on the wall clock for a countdown or a duration:
/// - the countdown runs on the clock, and a duration is measured from the
///   capture's first frame, not from the countdown;
/// - Finish or Cancel before the duration cancels the automatic stop;
/// - the automatic stop is the Finish button's joined stop: stop_recording
///   and wait_for_recording (through the automation bridge) report the same
///   single project, and get_status answers while wait_for_recording waits,
///   which never becomes a job and never holds the navigating calls' turn;
/// - start_recording's options apply to that recording only: the capture and
///   the project get them, the recorder's own choices stay as they were;
/// - a Cancel while a stop saves the recording changes nothing, and a start
///   is refused meanwhile;
/// - discarding an attempt (a cancelled start_recording) ends its countdown,
///   its capture start or the live recording, stops the capture and keeps
///   nothing;
/// - the floating countdown opens while another app is active or as soon as
///   the person switches to one, names the AI tool, and closes when the
///   countdown ends however it ends;
/// - calls during a countdown or a recording never bring the main window
///   over the recorded app;
/// - a Codex Director plan saving its capture is stopping, not idle;
/// - start_recording from an AI tool (through the bridge, with a scripted
///   sound prompt) records sound the recorder leaves off only as the person
///   answers, before any countdown: allow, record without sound (no sound at
///   all, also when the recorder records some), cancel, no answer in time
///   (the prompt closes), AI tools turned off meanwhile, the call cancelled;
///   a recorder sound the person turns off while the prompt is up is not
///   recorded whatever they answer; never asks for no sound, for the
///   recorder's own sound or for the in-app assistant; names the client and
///   the program that started it; waits 60 s by default; keeps the client
///   alive with heartbeats above the approval prompt's and the wait for a
///   turn's; and the prompt's wait counts toward the detach threshold from
///   the call's arrival. The recorder's own choices never change.
@MainActor
enum RecordingSessionRegression {
    static func run() async throws {
        try await automaticStopFromTheRealStart()
        try await finishOrCancelEndsTheTimer()
        try await oneOutcomeForEveryCaller()
        try await cancelDuringSaveIsIgnored()
        try await optionsForThisRecordingOnly()
        try await browserContentOnlyForThisRecording()
        try await discardEndsTheAttempt()
        try await floatingCountdownFollowsTheCountdown()
        try await windowStaysBehindTheRecording()
        try codexPlanSaveIsStopping()
        try await soundConsent()
        try await soundPromptWithinTheCallsTime()
        print("RecordingSessionRegression: PASS (countdown and automatic stop on a manual clock, the duration measured from the first frame, Finish/Cancel cancel the automatic stop and Cancel stops the capture, the automatic stop joined by stop_recording and wait_for_recording with one project, get_status and the call queue free while wait_for_recording waits and no job for it, a late wait_for_recording shortened to its maximum from the call's arrival, Cancel ignored and starts refused while saving, per-recording options (browser_content_only's crop, audio shown) with the recorder's choices unchanged, discarding a countdown, a capture start or a live recording, the floating countdown's lifecycle, no main window over a recording, a Codex plan's save is stopping, the sound prompt before the countdown for sound the recorder leaves off (60 s by default as the catalog says, naming the client and the program that started it; allow, record without sound with no sound at all even when the recorder records some, cancel, no answer closes it, turned off meanwhile, a recorder sound turned off while it is up stays off, cancelled call, heartbeats above the approval's and the turn's; none for no sound, the recorder's own sound or the in-app assistant; the recorder's choices unchanged; its wait detaching as a job from the call's arrival))")
    }

    // MARK: - Duration

    /// The countdown takes 3 s and the capture 0.5 s more to deliver its
    /// first frame; a 5-second recording stops 5 s after that frame.
    private static func automaticStopFromTheRealStart() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, clock, capture) = (fixture.model, fixture.clock, fixture.capture)
        let countdownStart = clock.now
        let id = try model.startRecording(target: fixture.target, options: AIRecordingOptions(duration: 5))
        try expect(model.recordingPhase == .countdown && model.recordingSession?.id == id && model.recordingSession?.startedAt == nil, "The countdown runs first")
        try await fixture.runCountdown()
        try await waitUntil("The capture did not start") { model.recordingPhase == .recording }
        let firstFrame = countdownStart + 3 + capture.startupDelay
        try expect(model.currentRecording?.startUptime == firstFrame && model.destination == .recording, "The start is the first frame, got \(String(describing: model.currentRecording?.startUptime))")
        try expect(model.recordingElapsed == 0 && model.recordingRemaining == 5 && model.hasPendingAutomaticStop, "5 s remain from the first frame")
        let session = model.recordingSession
        try expect(session?.duration == 5 && session?.autoStopAt.map { abs($0.timeIntervalSince(session!.startedAt!) - 5) < 0.001 } == true, "auto_stop_at is 5 s after started_at")

        try await waitUntil("The automatic stop did not wait on the clock") { clock.sleeperCount == 1 }
        // 5 s after the countdown began, and 5 s after it ended: still recording.
        clock.advance(by: 4.5)
        try await settle()
        try expect(capture.finishes == 0 && model.recordingPhase == .recording && model.recordingRemaining == 0.5, "No stop before 5 s of recording, got \(capture.finishes) stops")
        clock.advance(by: 0.5)
        try await waitUntil("The duration did not stop the recording") { model.destination == .editor }
        try expect(capture.finishes == 1 && model.projects.count == 1 && model.recordingPhase == .idle, "One stop, one project")
        try expect(model.recordingSession?.outcome == .finished(projectID: model.projects[0].id) && !model.hasPendingAutomaticStop, "The attempt ended with its project")
        clock.advance(by: 30)
        try await settle()
        try expect(capture.finishes == 1, "Nothing stops again later")
    }

    /// Finish, or Cancel, before the duration: the automatic stop is gone.
    private static func finishOrCancelEndsTheTimer() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, clock, capture) = (fixture.model, fixture.clock, fixture.capture)
        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions(duration: 5))
        try await fixture.runCountdown()
        try await waitUntil("The automatic stop did not wait") { model.recordingPhase == .recording && clock.sleeperCount == 1 }
        clock.advance(by: 2)
        await model.stopRecording()
        try expect(capture.finishes == 1 && model.destination == .editor && !model.hasPendingAutomaticStop, "Finish stops at once")
        try await waitUntil("The automatic stop's wait was not cancelled") { clock.sleeperCount == 0 }
        clock.advance(by: 10)
        try await settle()
        try expect(capture.finishes == 1 && model.projects.count == 1, "The duration never stops it a second time")

        // Cancel from the control bar during another recording with a duration.
        let second = try model.startRecording(target: fixture.target, options: AIRecordingOptions(duration: 3))
        try await fixture.runCountdown()
        try await waitUntil("The second recording did not start") { model.recordingPhase == .recording && clock.sleeperCount == 1 }
        await model.cancelRecording()
        try expect(capture.cancels == 1, "Cancel stops the capture, got \(capture.cancels) cancels")
        try expect(model.recordingSession?.id == second && model.recordingSession?.outcome == .cancelled && model.recordingPhase == .idle && !model.hasPendingAutomaticStop,
                   "Cancel ends the attempt and its automatic stop")
        clock.advance(by: 10)
        try await settle()
        try expect(capture.finishes == 1 && model.projects.count == 1, "A cancelled recording is never stopped or saved")
    }

    // MARK: - Joined stop

    /// The duration starts the stop; stop_recording joins it and
    /// wait_for_recording collects it. One finalization, one project, the
    /// same answer, and reads go on meanwhile.
    private static func oneOutcomeForEveryCaller() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, clock, capture) = (fixture.model, fixture.clock, fixture.capture)
        let bridge = AutomationBridge(model: model)
        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions(duration: 4))
        try await fixture.runCountdown()
        try await waitUntil("The recording did not start") { model.recordingPhase == .recording && clock.sleeperCount == 1 }

        // A short wait runs out with the state. With a detach threshold below
        // its timeout it is still no job: it bounds its own wait.
        let detaching = AutomationBridge(model: model, jobs: AutomationJobs(detachAfter: 0.2))
        let short = try await fixture.succeed(detaching, "wait_for_recording", ["timeout_seconds": 0.4])
        try expect(short.structuredContent?["state"] == "recording" && short.structuredContent?["job_id"] == nil && short.structuredContent?["remaining"] == 4,
                   "A wait that runs out reports the recording: \(short.json)")

        // A wait whose call arrived long ago (it waited for approval) ends
        // within its maximum counted from the arrival; an invalid timeout is
        // still refused.
        let lateAt = Date()
        let arrivedLongAgo = Date().addingTimeInterval(-(AutomationJobs.maximumWait - 0.3))
        guard case let .result(bounded) = await bridge.call(toolName: "wait_for_recording", arguments: ["timeout_seconds": 60], workingDirectory: nil, clientName: "test",
                                                             arrivedAt: arrivedLongAgo, progress: nil) else { throw SessionFailure("The bounded wait must answer") }
        try expect(!bounded.isError && bounded.structuredContent?["state"] == "recording" && (bounded.structuredContent?["waited"]?.doubleValue ?? 99) < 1
                   && Date().timeIntervalSince(lateAt) < 2, "A late wait is shortened to its maximum from the arrival: \(bounded.json)")
        guard case let .result(invalid) = await bridge.call(toolName: "wait_for_recording", arguments: ["timeout_seconds": 500], workingDirectory: nil, clientName: "test",
                                                             arrivedAt: arrivedLongAgo, progress: nil) else { throw SessionFailure("The invalid wait must answer") }
        try expect(invalid.isError && invalid.text.contains("timeout_seconds"), "An invalid timeout is refused whatever the time: \(invalid.text)")

        let waiting = Task { @MainActor in
            await bridge.call(toolName: "wait_for_recording", arguments: ["timeout_seconds": 60], workingDirectory: nil, clientName: "test", progress: nil)
        }
        try await Task.sleep(for: .milliseconds(100))
        // get_status answers at once, and the navigating calls' turn is free.
        let asked = Date()
        let status = try await fixture.succeed(bridge, "get_status", [:])
        try expect(Date().timeIntervalSince(asked) < 1 && status.structuredContent?["recording"]?["state"] == "recording" && status.structuredContent?["recording"]?["remaining"] == 4,
                   "get_status answers while wait_for_recording waits: \(status.json)")
        try expect(bridge.queue.waitingCount == 0 && bridge.jobs.runningJobIDs.isEmpty && detaching.jobs.runningJobIDs.isEmpty, "wait_for_recording holds no turn and is no job")

        capture.holdFinish = true
        clock.advance(by: 4)
        try await waitUntil("The duration did not start the stop") { capture.finishes == 1 && model.recordingPhase == .stopping && model.isFinishingRecording }
        let stopping = Task { @MainActor in
            await bridge.call(toolName: "stop_recording", arguments: [:], workingDirectory: nil, clientName: "test", progress: nil)
        }
        try await Task.sleep(for: .milliseconds(150))
        try expect(capture.finishes == 1, "stop_recording joins the stop under way")
        capture.holdFinish = false
        guard case let .result(stopped) = await stopping.value, !stopped.isError,
              case let .result(waited) = await waiting.value, !waited.isError else {
            throw SessionFailure("stop_recording and wait_for_recording must both succeed")
        }
        let project = model.projects.first
        try expect(capture.finishes == 1 && model.projects.count == 1 && model.destination == .editor, "One finalization and one project")
        try expect(stopped.structuredContent?["project_id"]?.stringValue == project?.id.uuidString && waited.structuredContent?["project_id"] == stopped.structuredContent?["project_id"]
                   && stopped.structuredContent?["state"] == "finished" && waited.structuredContent?["state"] == "finished" && waited.structuredContent?["open_in_editor"] == true,
                   "Both report the same project: \(stopped.json) / \(waited.json)")
        let idle = try await fixture.succeed(bridge, "wait_for_recording", [:])
        try expect(idle.structuredContent?["state"] == "idle" && idle.structuredContent?["last_recording"]?["project_id"] == stopped.structuredContent?["project_id"], "Afterwards nothing records: \(idle.json)")
    }

    /// Cancel while the duration's stop is saving is ignored: the project is
    /// kept and every caller reports it; a start is refused meanwhile.
    private static func cancelDuringSaveIsIgnored() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, clock, capture) = (fixture.model, fixture.clock, fixture.capture)
        let bridge = AutomationBridge(model: model)
        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions(duration: 4))
        try await fixture.runCountdown()
        try await waitUntil("The recording did not start") { model.recordingPhase == .recording && clock.sleeperCount == 1 }
        capture.holdFinish = true
        clock.advance(by: 4)
        try await waitUntil("The duration did not start the stop") { capture.finishes == 1 && model.isFinishingRecording }
        let stopping = Task { @MainActor in await bridge.call(toolName: "stop_recording", arguments: [:], workingDirectory: nil, clientName: "test", progress: nil) }
        let waiting = Task { @MainActor in await bridge.call(toolName: "wait_for_recording", arguments: ["timeout_seconds": 30], workingDirectory: nil, clientName: "test", progress: nil) }
        try await Task.sleep(for: .milliseconds(150))
        await model.cancelRecording()
        try expect(model.recordingSession?.outcome == nil && model.destination == .recording && capture.cancels == 0, "Cancel during the save must change nothing")
        do {
            _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions())
            throw SessionFailure("A start during the save must be refused")
        } catch let error as AIToolError {
            try expect("\(error)".contains("still being saved") && model.destination == .recording, "A start during the save is refused as such, got \(error)")
        }
        capture.holdFinish = false
        guard case let .result(stopped) = await stopping.value, !stopped.isError, stopped.structuredContent?["state"] == "finished",
              case let .result(waited) = await waiting.value, !waited.isError, waited.structuredContent?["state"] == "finished" else {
            throw SessionFailure("stop_recording and wait_for_recording must report the saved project")
        }
        try expect(model.projects.count == 1 && model.destination == .editor && capture.finishes == 1
                   && model.recordingSession?.outcome == .finished(projectID: model.projects[0].id),
                   "The save wins: one project, open in the editor, outcome finished")
    }

    // MARK: - Options

    /// Overrides reach the capture and the project; the recorder keeps the
    /// person's choices, which the next recording uses again.
    private static func optionsForThisRecordingOnly() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, capture) = (fixture.model, fixture.capture)
        let choices = model.recorderSettings
        try expect(choices == RecordingSettings(systemAudio: false, microphone: false, automaticZooms: true, browserContentOnly: true, frameRate: 60), "The recorder's defaults: \(choices)")
        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions(systemAudio: true, microphone: true, automaticZooms: false, browserContentOnly: false, frameRate: 30))
        try expect(model.recorderSettings == choices, "Starting changes none of the recorder's choices")
        try expect(model.currentRecording?.settings.audioDescription == "Recording microphone and system audio" && model.recorderSettings.audioDescription == nil,
                   "The countdown and the control bar name this recording's audio, not the recorder's")
        try await fixture.runCountdown()
        try await waitUntil("The recording did not start") { model.recordingPhase == .recording }
        let options = capture.starts.last?.options
        try expect(options?.systemAudio == true && options?.microphone == true && options?.frameRate == 30, "The capture records with the call's options: \(String(describing: options))")
        await model.stopRecording()
        let recorded = model.projects.first
        try expect(recorded?.settings.autoZoomEnabled == false && recorded?.settings.frameRate == 30, "The project keeps this recording's options")
        try expect(model.recorderSettings == choices && model.recordSystemAudio == false && model.automaticZooms && model.frameRate == 60 && model.browserContentOnly,
                   "The recorder's choices are unchanged after the recording: \(model.recorderSettings)")

        // The person's own next recording records with their choices.
        // As the Record button does: the recorder's choices, no duration.
        try expect(model.beginRecordingCountdown(target: fixture.target, settings: model.recorderSettings, duration: nil) != nil, "The person's own recording starts")
        try await fixture.runCountdown()
        try await waitUntil("The next recording did not start") { model.recordingPhase == .recording }
        let next = capture.starts.last?.options
        try expect(next?.systemAudio == false && next?.microphone == false && next?.frameRate == 60, "The next recording uses the recorder's choices: \(String(describing: next))")
        await model.stopRecording()
        try expect(model.projects.first?.settings.autoZoomEnabled == true && model.projects.first?.settings.frameRate == 60, "And so does its project")
    }

    /// browser_content_only decides this recording's crop, against the
    /// recorder's opposite choice, on a browser window (a display is never cropped).
    private static func browserContentOnlyForThisRecording() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let browser = CaptureTargetInfo(id: "window-9", kind: .window, nativeID: 9, title: "Page", appName: "Safari",
                                        frame: CaptureRect(x: 0, y: 0, width: 800, height: 600))
        for (recorder, call) in [(true, false), (false, true)] {
            model.browserContentOnly = recorder
            _ = try model.startRecording(target: browser, options: AIRecordingOptions(browserContentOnly: call))
            try await fixture.runCountdown()
            try await waitUntil("The recording did not start") { model.recordingPhase == .recording }
            await model.stopRecording()
            try expect((model.projects.first?.settings.sourceCropInsets != nil) == call && model.browserContentOnly == recorder,
                       "browser_content_only \(call) decides this recording's crop, recorder \(recorder): \(String(describing: model.projects.first?.settings.sourceCropInsets))")
        }
    }

    // MARK: - Discard

    /// A start_recording cancelled during the countdown or the capture start
    /// discards the attempt; an ended attempt is left alone.
    private static func discardEndsTheAttempt() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, clock, capture) = (fixture.model, fixture.clock, fixture.capture)
        let counting = try model.startRecording(target: fixture.target, options: AIRecordingOptions(duration: 5))
        try await waitUntil("The countdown did not tick") { clock.sleeperCount == 1 }
        await model.discardRecording(id: counting)
        try expect(model.recordingSession?.outcome == .cancelled && model.destination == .recorder && model.recordingPhase == .idle, "The countdown is discarded")
        try await waitUntil("The countdown's wait was not cancelled") { clock.sleeperCount == 0 }
        clock.advance(by: 10)
        try await settle()
        try expect(capture.starts.isEmpty && model.recordingPhase == .idle, "No capture starts after a discarded countdown")

        // During the capture start (the countdown is over, no frame yet).
        capture.holdStart = true
        let starting = try model.startRecording(target: fixture.target, options: AIRecordingOptions())
        try await fixture.runCountdown()
        try await waitUntil("The capture start did not begin") { capture.starts.count == 1 }
        await model.discardRecording(id: starting)
        try expect(model.recordingSession?.outcome == .cancelled && model.destination == .recorder, "The capture start is discarded")
        try expect(capture.cancels == 0, "Nothing to stop before the held start returns")
        capture.holdStart = false
        try await waitUntil("A capture that started after its discard was not stopped") { capture.cancels == 1 }
        try await settle()
        try expect(model.destination == .recorder && model.recordingPhase == .idle && model.recordingSession?.startedAt == nil && capture.finishes == 0,
                   "A capture that starts after its discard is not kept")

        // A live recording (a start_recording cancelled as it went live).
        let live = try model.startRecording(target: fixture.target, options: AIRecordingOptions(duration: 5))
        try await fixture.runCountdown()
        try await waitUntil("The live recording did not start") { model.recordingPhase == .recording && clock.sleeperCount == 1 }
        await model.discardRecording(id: live)
        try expect(model.recordingSession?.id == live && model.recordingSession?.outcome == .cancelled && model.destination == .library
                   && model.recordingPhase == .idle && !model.hasPendingAutomaticStop && capture.cancels == 2,
                   "A live recording is discarded and its capture stopped, got \(capture.cancels) cancels")
        try await waitUntil("The discarded recording's automatic stop still waits") { clock.sleeperCount == 0 }
        clock.advance(by: 10)
        try await settle()
        try expect(capture.finishes == 0 && model.projects.isEmpty, "A discarded live recording is never stopped or saved")

        // An attempt that ended is left alone.
        let finished = try model.startRecording(target: fixture.target, options: AIRecordingOptions())
        try await fixture.runCountdown()
        try await waitUntil("The recording did not start") { model.recordingPhase == .recording }
        await model.stopRecording()
        await model.discardRecording(id: finished)
        try expect(model.recordingSession?.outcome == .finished(projectID: model.projects[0].id) && model.destination == .editor, "Discarding an ended attempt changes nothing")
    }

    // MARK: - Floating countdown

    /// The floating countdown opens while another app is active, or when the
    /// person switches to one during the countdown, names the AI tool that
    /// asked, and closes when the countdown ends: cancelled, discarded,
    /// failed or started. Nothing opens without an application.
    private static func floatingCountdownFollowsTheCountdown() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, capture) = (fixture.model, fixture.capture)
        let probe = PanelProbe()
        let notifications = NotificationCenter()
        let panels = RecordingCountdownPanelCoordinator(appIsActive: { probe.active }, notifications: notifications) { _, requester in
            probe.open += 2
            probe.requesters.append(requester)
            return [{ probe.open -= 1 }, { probe.open -= 1 }]
        }
        panels.automationRequester = { "Claude Code" }
        model.countdownPanels = panels

        // Focus Studio in front: its window shows the countdown, until the
        // person switches to another app during it.
        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions())
        try expect(probe.open == 0 && !panels.isShowing, "No floating countdown while Focus Studio is active")
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        try await waitUntil("Switching away did not show the floating countdown") { probe.open == 2 }
        try expect(panels.isShowing && probe.requesters == ["Claude Code"], "The countdown floats on every display and names the AI tool: \(probe.requesters)")
        model.cancelRecordingCountdown()
        try expect(probe.open == 0 && !panels.isShowing, "Cancel closes the floating countdown")
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        notifications.post(name: NSApplication.didHideNotification, object: nil)
        try await settle()
        try expect(probe.open == 0, "Nothing opens once the countdown is over")

        // Hiding Focus Studio during the countdown shows it too.
        let hidden = try model.startRecording(target: fixture.target, options: AIRecordingOptions())
        notifications.post(name: NSApplication.didHideNotification, object: nil)
        try await waitUntil("Hiding Focus Studio did not show the floating countdown") { probe.open == 2 }
        await model.discardRecording(id: hidden)
        try expect(probe.open == 0, "A discarded countdown closes it")

        // Another app in front from the start.
        probe.active = false
        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions())
        try expect(probe.open == 2, "The countdown floats at once while another app is active")
        model.cancelRecordingCountdown()
        try expect(probe.open == 0, "Cancel closes it")

        capture.startError = SessionFailure("The stream could not start")
        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions())
        try expect(probe.open == 2, "The countdown floats for a start that will fail")
        try await fixture.runCountdown()
        try await waitUntil("A failed start left the floating countdown") { probe.open == 0 && model.destination == .recorder && model.recordingSession?.outcome != nil }
        capture.startError = nil

        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions())
        try await fixture.runCountdown()
        try await waitUntil("The capture did not start") { model.recordingPhase == .recording }
        try expect(probe.open == 0, "The control bar takes the floating countdown's place")
        await model.cancelRecording()

        // No application (a command-line run): never a panel.
        probe.active = nil
        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions())
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        try await settle()
        try expect(probe.open == 0 && !panels.isShowing, "Nothing opens without an application")
        model.cancelRecordingCountdown()
        try expect(probe.requesters.count == 5, "One set of panels per countdown that needed one: \(probe.requesters.count)")
    }

    // MARK: - Main window

    /// A call during a countdown or a recording never brings the main window
    /// over the recorded app, refused or not; an editing call afterwards does.
    private static func windowStaysBehindTheRecording() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        var windowRequests = 0
        let bridge = AutomationBridge(model: model)
        bridge.presentWindow = { windowRequests += 1 }
        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions())
        try await fixture.runCountdown()
        try await waitUntil("The first recording did not start") { model.recordingPhase == .recording }
        await model.stopRecording()
        let project = try unwrap(model.projects.first, "The first recording has a project")
        let zoom: [String: Any] = ["project_id": project.id.uuidString, "start": 0.1, "end": 0.8, "x": 0.5, "y": 0.5]

        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions())
        let duringCountdown = try await fixture.fail(bridge, "start_recording", ["source": "display"])
        try expect(duringCountdown.contains("already"), "A second start during the countdown is refused: \(duringCountdown)")
        try await fixture.runCountdown()
        try await waitUntil("The second recording did not start") { model.recordingPhase == .recording }
        let refused = try await fixture.fail(bridge, "add_zoom", zoom)
        try expect(refused.contains("recording"), "Editing is refused while recording: \(refused)")
        let stopped = try await fixture.succeed(bridge, "stop_recording", [:])
        try expect(stopped.structuredContent?["state"] == "finished" && windowRequests == 0,
                   "Calls during the countdown and the recording never raise the main window: \(windowRequests)")

        _ = try await fixture.succeed(bridge, "add_zoom", zoom)
        try expect(windowRequests == 1, "An editing call afterwards shows the main window: \(windowRequests)")
    }

    // MARK: - Codex Director

    /// A Codex Director plan has no recording attempt: between the engine's
    /// stop and the editor opening its project it is saving (stopping), so a
    /// wait never reads that save as a cancel. Its success (the editor) and
    /// its failure (the Director) are idle; other recordings are unchanged.
    private static func codexPlanSaveIsStopping() throws {
        let clip = URL(fileURLWithPath: "/nonexistent/recording.mp4")
        func phase(_ destination: StudioModel.Destination, _ engine: RecordingState, live: Bool = false, codex: Bool) -> AIRecordingPhase {
            StudioModel.recordingPhase(destination: destination, isFinishingRecording: false, engineState: engine, attemptIsLive: live, isRunningCodexPlan: codex)
        }
        try expect(phase(.recording, .recording, codex: true) == .recording, "A plan's capture records")
        try expect(phase(.recording, .completed(clip), codex: true) == .stopping && phase(.recording, .idle, codex: true) == .stopping,
                   "A plan saving its capture is stopping")
        try expect(phase(.editor, .completed(clip), codex: true) == .idle && phase(.director, .completed(clip), codex: true) == .idle,
                   "The plan's editor or its Director afterwards is idle")
        try expect(phase(.recording, .completed(clip), codex: false) == .idle && phase(.recording, .idle, live: true, codex: false) == .recording,
                   "Other recordings keep their phases")
    }

    // MARK: - Sound consent

    /// A selected area of the fixture's display: the only source the engine
    /// lists (no ScreenCaptureKit), which start_recording can name by its id.
    private static let soundArea = CaptureTargetInfo(id: "area-1-sound", kind: .area, nativeID: 1, title: "Test area", frame: CaptureRect(x: 0, y: 0, width: 64, height: 64))

    /// start_recording through `bridge` for Claude Code; once its countdown
    /// starts, the countdown runs on the manual clock.
    private static func record(
        _ arguments: [String: Any],
        fixture: SessionFixture,
        bridge: AutomationBridge,
        arrivedAt: Date? = nil,
        progress: AIToolProgressHandler? = nil,
        stillAllowed: (@MainActor () -> String?)? = nil
    ) async throws -> AutomationCallResult {
        let model = fixture.model
        let done = TestBox(false)
        let call = Task { @MainActor in
            let outcome = await bridge.call(toolName: "start_recording", arguments: ["source": soundArea.id].merging(arguments) { $1 }, workingDirectory: nil,
                                            clientName: "Claude Code", programName: "Claude (claude)", arrivedAt: arrivedAt, progress: progress, stillAllowed: stillAllowed)
            done.value = true
            return outcome
        }
        try await waitUntil("start_recording neither counted down nor answered") { done.value || model.recordingPhase == .countdown }
        if !done.value { try await fixture.runCountdown() }
        return await call.value
    }

    private static func result(_ outcome: AutomationCallResult, _ what: String) throws -> MCPToolCallResult {
        guard case let .result(result) = outcome else { throw SessionFailure("\(what): expected a result, got \(outcome)") }
        return result
    }

    private static func soundConsent() async throws {
        // The app's prompt waits 60 s (AppServices builds it with the
        // defaults), which start_recording's description, SKILL.md, README
        // and INSTALL promise.
        try expect(AutomationAudioConsentController.defaultTimeout == 60 && AutomationAudioConsentController { _ in nil }.timeout == 60,
                   "The sound prompt waits 60 s by default")
        let startText = try unwrap(MCPToolCatalog.v1.tool(named: "start_recording"), "start_recording").description
        try expect(startText.contains("within \(Int(AutomationAudioConsentController.defaultTimeout)) seconds"), "start_recording promises the prompt's default wait: \(startText)")
        // One call's progress must keep increasing, and a new client's first
        // start_recording sends the approval prompt's heartbeats, then (when
        // it waits for its turn) the queue's, then the sound prompt's: each
        // starts above the most the one before can reach.
        let approvalMost = ((AutomationAccessController.defaultTimeout / AutomationAccessController.defaultHeartbeatInterval).rounded(.up) + 1) * AutomationAccessController.heartbeatStep
        let turnMost = AutomationBridge.turnHeartbeatBase + Double(AutomationBridge.turnHeartbeatLimit) * AutomationBridge.turnHeartbeatStep
        try expect(approvalMost < AutomationBridge.turnHeartbeatBase && turnMost < AutomationAudioConsentController.heartbeatBase,
                   "Heartbeats rise from the approval prompt (up to \(approvalMost)) to the wait for a turn (\(AutomationBridge.turnHeartbeatBase)–\(turnMost)) to the sound prompt (from \(AutomationAudioConsentController.heartbeatBase))")

        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, capture) = (fixture.model, fixture.capture)
        try model.captureEngine.registerAreaTarget(soundArea)
        let prompter = ScriptedSoundPrompter()
        let consent = AutomationAudioConsentController(timeout: 5, heartbeatInterval: 0.05) { await prompter.prompt($0) }
        let bridge = AutomationBridge(model: model)
        bridge.audioConsent = consent
        let choices = model.recorderSettings
        try expect(choices.microphone == false && choices.systemAudio == false && model.recorderAudio == AIRecordingAudio(), "The recorder records no sound: \(choices)")

        // Allow: recorded with the microphone; the prompt names the AI tool, the sound and the source.
        prompter.mode = .answer(.allow)
        let allowed = try result(try await record(["microphone": true], fixture: fixture, bridge: bridge), "allow")
        try expect(!allowed.isError && allowed.structuredContent?["audio_consent"] == ["asked": ["microphone"], "answer": "allowed"]
                   && allowed.structuredContent?["options"]?["microphone"] == true, "Allowed: \(allowed.json)")
        let asked = try unwrap(prompter.requests.last, "The person was asked")
        try expect(prompter.requests.count == 1 && asked.clientName == "Claude Code" && asked.programName == "Claude (claude)" && asked.audio == AIRecordingAudio(microphone: true)
                   && asked.sourceName == "Test area" && asked.timeout == 5, "The prompt names the client, the program that started it, the sound, the source and its wait (injected here): \(asked)")
        try expect(capture.starts.last?.options.microphone == true && capture.starts.last?.options.systemAudio == false, "The capture records the microphone")
        try expect(model.recorderSettings == choices, "Allow changes none of the recorder's choices")
        await model.stopRecording()

        // Record without sound: the capture has none, and the result says so.
        prompter.mode = .answer(.withoutSound)
        let silent = try result(try await record(["microphone": true, "system_audio": true, "frame_rate": 30], fixture: fixture, bridge: bridge), "without sound")
        try expect(!silent.isError && silent.structuredContent?["audio_consent"] == ["asked": ["microphone", "system_audio"], "answer": "without_sound"]
                   && silent.structuredContent?["options"]?["microphone"] == false && silent.structuredContent?["options"]?["system_audio"] == false
                   && silent.text.contains("chose to record without sound"), "Without sound: \(silent.json)")
        let silentOptions = capture.starts.last?.options
        try expect(silentOptions?.microphone == false && silentOptions?.systemAudio == false && silentOptions?.frameRate == 30, "The capture records no sound: \(String(describing: silentOptions))")
        try expect(model.currentRecording?.settings.audioDescription == nil && model.recorderSettings == choices, "No sound shown, the recorder unchanged")
        await model.stopRecording()

        // Record without sound while the recorder records system audio: the
        // prompt asks about the microphone only and promises the screen only,
        // so the recording has no sound at all.
        model.recordSystemAudio = true
        let ownSound = model.recorderSettings
        let screenOnly = try result(try await record(["microphone": true], fixture: fixture, bridge: bridge), "without sound, recorder sound on")
        try expect(prompter.requests.last?.audio == AIRecordingAudio(microphone: true) && !screenOnly.isError
                   && screenOnly.structuredContent?["options"]?["microphone"] == false && screenOnly.structuredContent?["options"]?["system_audio"] == false,
                   "Asked about the microphone; the result says no sound: \(screenOnly.json)")
        try expect(capture.starts.last?.options.microphone == false && capture.starts.last?.options.systemAudio == false && model.currentRecording?.settings.audioDescription == nil,
                   "Record without sound records no sound, the recorder's system audio included: \(String(describing: capture.starts.last?.options))")
        try expect(model.recorderSettings == ownSound, "The recorder still records system audio for the person's own recordings")
        await model.stopRecording()
        model.recordSystemAudio = false

        // The person turns the recorder's microphone off while the prompt
        // (about system audio only: the microphone was on) is up: whatever
        // they answer, the microphone they turned off is not recorded.
        for answer in [AutomationAudioConsentAnswer.allow, .withoutSound] {
            model.recordMicrophone = true
            prompter.mode = .hold
            let changing = Task { @MainActor in try await record(["microphone": true, "system_audio": true], fixture: fixture, bridge: bridge) }
            try await waitUntil("The prompt did not come up") { prompter.heldCount == 1 }
            try expect(prompter.requests.last?.audio == AIRecordingAudio(systemAudio: true), "\(answer): the prompt asks about system audio only")
            model.recordMicrophone = false
            prompter.release(answer)
            let changed = try result(try await changing.value, "recorder changed during the prompt, \(answer)")
            let options = capture.starts.last?.options
            try expect(!changed.isError && options?.microphone == false && options?.systemAudio == (answer == .allow) && changed.structuredContent?["options"]?["microphone"] == false,
                       "\(answer): the microphone turned off during the prompt is not recorded: \(String(describing: options)) \(changed.json)")
            try expect(model.recordMicrophone == false && model.recorderSettings == choices, "\(answer): the person's own change stands")
            await model.stopRecording()
        }
        prompter.mode = .answer(.allow)

        // Cancel recording: no countdown, no capture, a clear refusal.
        let startsBefore = capture.starts.count
        let attemptBefore = model.currentRecording?.id
        prompter.mode = .answer(.cancel)
        let cancelled = try result(try await record(["system_audio": true], fixture: fixture, bridge: bridge), "cancel")
        try expect(cancelled.isError && cancelled.text.contains("did not allow sound") && cancelled.text.contains("Cancel recording") && cancelled.text.contains("system audio"),
                   "Cancelled: \(cancelled.text)")
        try expect(capture.starts.count == startsBefore && model.currentRecording?.id == attemptBefore && model.recordingPhase == .idle && model.recorderSettings == choices,
                   "Nothing counted down or recorded after Cancel recording")

        // Held: no countdown while the person decides; heartbeats keep the client waiting.
        prompter.mode = .hold
        let beats = ProgressReports()
        let heldCall = Task { @MainActor in try await record(["microphone": true], fixture: fixture, bridge: bridge, progress: beats.handler) }
        try await waitUntil("The prompt did not come up") { prompter.heldCount == 1 }
        try await Task.sleep(for: .milliseconds(250))
        try expect(model.recordingPhase == .idle && model.destination != .countdown && consent.pendingRequests.count == 1, "No countdown before the answer")
        let values = beats.values
        try expect(values.count >= 3 && zip(values, values.dropFirst()).allSatisfy { $0.progress < $1.progress }
                   && values.allSatisfy { $0.progress >= AutomationAudioConsentController.heartbeatBase && $0.total == nil && ($0.message ?? "").contains("sound prompt") },
                   "Heartbeats while the prompt is up: \(values.map(\.progress))")
        prompter.release(.allow)
        let heldResult = try result(try await heldCall.value, "held then allowed")
        try expect(!heldResult.isError && capture.starts.last?.options.microphone == true && consent.pendingRequests.isEmpty, "Allowed after a while: \(heldResult.json)")
        try expect(beats.values.last?.message == nil, "The last report no longer says it waits for the person")
        await model.stopRecording()

        // Turned off (or revoked) while the prompt was up: refused even after Allow.
        let turnedOff = TestBox(false)
        let offCall = Task { @MainActor in
            try await record(["microphone": true], fixture: fixture, bridge: bridge, stillAllowed: { turnedOff.value ? AutomationSwitch.disabledMessage(tool: "start_recording") : nil })
        }
        try await waitUntil("The prompt did not come up") { prompter.heldCount == 1 }
        let startsBeforeOff = capture.starts.count
        turnedOff.value = true
        prompter.release(.allow)
        let off = try result(try await offCall.value, "turned off")
        try expect(off.isError && off.text == AutomationSwitch.disabledMessage(tool: "start_recording") && capture.starts.count == startsBeforeOff && model.recordingPhase == .idle,
                   "Refused after the answer: \(off.text)")

        // The call cancelled while the prompt is up: the prompt closes, nothing records.
        let cancelledCall = Task { @MainActor in
            await bridge.call(toolName: "start_recording", arguments: ["source": soundArea.id, "microphone": true], workingDirectory: nil, clientName: "Claude Code", progress: nil)
        }
        try await waitUntil("The prompt did not come up") { prompter.heldCount == 1 }
        let closedBefore = prompter.closedUnanswered
        cancelledCall.cancel()
        let cancelledOutcome = await cancelledCall.value
        try expect(cancelledOutcome == .cancelled && prompter.closedUnanswered == closedBefore + 1 && prompter.heldCount == 0 && consent.pendingRequests.isEmpty,
                   "A cancelled call closes its prompt: \(cancelledOutcome)")
        try expect(model.recordingPhase == .idle && capture.starts.count == startsBeforeOff, "and records nothing")

        // No answer in time: the prompt closes and nothing records.
        let impatient = AutomationAudioConsentController(timeout: 0.3, heartbeatInterval: 0.05) { await prompter.prompt($0) }
        let timing = AutomationBridge(model: model)
        timing.audioConsent = impatient
        let unanswered = try result(try await record(["system_audio": true], fixture: fixture, bridge: timing), "no answer")
        try expect(unanswered.isError && unanswered.text.contains("did not allow sound") && unanswered.text.contains("nobody answered within 0.3 seconds"),
                   "No answer: \(unanswered.text)")
        try expect(prompter.closedUnanswered == closedBefore + 2 && prompter.heldCount == 0 && impatient.pendingRequests.isEmpty, "The unanswered prompt was closed")
        try expect(capture.starts.count == startsBeforeOff && model.recordingPhase == .idle && model.recorderSettings == choices, "Nothing recorded without an answer")

        // No prompt: no sound, sound turned off, the recorder's own sound.
        let promptsBefore = prompter.requests.count
        prompter.mode = .answer(.cancel)
        for arguments in [[:], ["microphone": false, "system_audio": false]] as [[String: Any]] {
            let quiet = try result(try await record(arguments, fixture: fixture, bridge: bridge), "no sound \(arguments)")
            try expect(!quiet.isError && quiet.structuredContent?["audio_consent"] == nil && capture.starts.last?.options.microphone == false, "No sound, no prompt: \(quiet.json)")
            await model.stopRecording()
        }
        model.recordMicrophone = true
        let own = model.recorderSettings
        let recorderSound = try result(try await record(["microphone": true], fixture: fixture, bridge: bridge), "the recorder's own sound")
        try expect(!recorderSound.isError && capture.starts.last?.options.microphone == true && model.recorderSettings == own, "The recorder's own microphone: no prompt")
        await model.stopRecording()
        model.recordMicrophone = false

        // The in-app assistant: the person drives it, so it never asks.
        let inApp = model.assistantSession.context
        try expect(!inApp.isExternal && inApp.recordingAudioConsent == nil, "The in-app assistant's context is not external")
        let inAppTool = try unwrap(AIAssistantToolCatalog.standard.first { $0.name == "start_recording" }, "The in-app assistant has start_recording")
        let inAppDone = TestBox(false)
        let inAppCall = Task { @MainActor in
            defer { inAppDone.value = true }
            return try await inAppTool.run(arguments: ["source": soundArea.id, "microphone": true, "system_audio": true], context: inApp, progress: { _ in })
        }
        try await waitUntil("The in-app start did not count down") { inAppDone.value || model.recordingPhase == .countdown }
        try await fixture.runCountdown()
        _ = try await inAppCall.value
        try expect(capture.starts.last?.options.microphone == true && capture.starts.last?.options.systemAudio == true, "The in-app assistant records as asked")
        await model.stopRecording()
        try expect(prompter.requests.count == promptsBefore, "None of these asked the person: \(prompter.requests.count - promptsBefore)")
        try expect(model.recorderSettings == choices, "The recorder's own choices never changed: \(model.recorderSettings)")
    }

    /// The sound prompt's wait counts toward the detach threshold from the
    /// call's arrival: still unanswered when the time is up, the call answers
    /// with a job that says it waits for the person; wait_for_job collects
    /// the recording once they allow it.
    private static func soundPromptWithinTheCallsTime() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, capture) = (fixture.model, fixture.capture)
        try model.captureEngine.registerAreaTarget(soundArea)
        let prompter = ScriptedSoundPrompter()
        prompter.mode = .hold
        let bridge = AutomationBridge(model: model, jobs: AutomationJobs(detachAfter: 1))
        bridge.audioConsent = AutomationAudioConsentController(timeout: 30, heartbeatInterval: 0.05) { await prompter.prompt($0) }
        let choices = model.recorderSettings

        // 0.8 s of the call's second went by before it reached the bridge
        // (the helper, the approval prompt): it answers about 0.2 s later.
        let asked = Date()
        let running = try result(try await record(["microphone": true], fixture: fixture, bridge: bridge, arrivedAt: Date().addingTimeInterval(-0.8)), "detached")
        let took = Date().timeIntervalSince(asked)
        let jobID = try unwrap(running.structuredContent?["job_id"]?.stringValue, "A job id: \(running.json)")
        try expect(!running.isError && running.structuredContent?["status"] == "running" && took < 0.7, "Detached from the call's arrival, after \(took) s: \(running.json)")
        try expect(running.structuredContent?["activity"] == "waiting for the person to answer Focus Studio's sound prompt" && running.text.contains("sound prompt"),
                   "The running status says it waits for the person: \(running.json)")
        try expect(prompter.heldCount == 1 && model.recordingPhase == .idle && capture.starts.isEmpty, "The prompt is still up and nothing counts down")

        // The person allows it: the job counts down and records; wait_for_job returns what start_recording did.
        prompter.release(.allow)
        try await waitUntil("The allowed job did not count down") { model.recordingPhase == .countdown }
        try await fixture.runCountdown()
        let collected = try result(await bridge.call(toolName: "wait_for_job", arguments: ["job_id": jobID, "timeout_seconds": 10], workingDirectory: nil, clientName: "Claude Code", progress: nil), "wait_for_job")
        try expect(!collected.isError && collected.structuredContent?["state"] == "recording" && collected.structuredContent?["audio_consent"] == ["asked": ["microphone"], "answer": "allowed"],
                   "wait_for_job returns the recording: \(collected.json)")
        try expect(capture.starts.last?.options.microphone == true && model.recorderSettings == choices, "Recorded with the microphone; the recorder unchanged")
        await model.stopRecording()
    }

    // MARK: - Helpers

    /// Lets tasks the clock resumed run.
    private static func settle() async throws {
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(30))
    }

    static func waitUntil(_ message: String, predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate() {
            if ContinuousClock.now >= deadline { throw SessionFailure(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw SessionFailure(message) }
    }

    static func unwrap<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw SessionFailure(message) }
        return value
    }
}

/// Stands in for the floating countdown's panels: whether Focus Studio is
/// active (nil: no application), how many are open and who asked for each set.
@MainActor
private final class PanelProbe {
    var active: Bool? = true
    var open = 0
    var requesters: [String?] = []
}

/// Answers the sound prompt from the test: at once, or held until released
/// (a held prompt whose task is cancelled closes unanswered).
@MainActor
final class ScriptedSoundPrompter {
    enum Mode { case answer(AutomationAudioConsentAnswer), hold }
    var mode = Mode.answer(.allow)
    private(set) var requests: [AutomationAudioConsentRequest] = []
    /// Prompts closed without an answer: their call gave up or timed out.
    private(set) var closedUnanswered = 0
    private var held: [UUID: CheckedContinuation<AutomationAudioConsentAnswer?, Never>] = [:]

    var heldCount: Int { held.count }

    func prompt(_ request: AutomationAudioConsentRequest) async -> AutomationAudioConsentAnswer? {
        requests.append(request)
        guard case .hold = mode else {
            if case let .answer(answer) = mode { return answer }
            return nil
        }
        let id = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AutomationAudioConsentAnswer?, Never>) in
                if Task.isCancelled {
                    closedUnanswered += 1
                    continuation.resume(returning: nil)
                } else {
                    held[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.close(id) }
        }
    }

    func release(_ answer: AutomationAudioConsentAnswer) {
        let waiting = held
        held.removeAll()
        waiting.values.forEach { $0.resume(returning: answer) }
    }

    private func close(_ id: UUID) {
        guard let continuation = held.removeValue(forKey: id) else { return }
        closedUnanswered += 1
        continuation.resume(returning: nil)
    }
}

/// A value a test shares with the tasks it starts.
@MainActor
final class TestBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Progress reports from any thread, in order.
final class ProgressReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [(progress: Double, total: Double?, message: String?)] = []
    var values: [(progress: Double, total: Double?, message: String?)] { lock.withLock { reports } }
    var handler: AIToolProgressHandler { { [self] progress, total, message in lock.withLock { reports.append((progress, total, message)) } } }
}

private struct SessionFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Uptime that moves only when a test advances it. `sleep` waits until then
/// and throws when its task is cancelled.
@MainActor
final class ManualRecordingClock {
    private(set) var now: TimeInterval = 1_000
    private var sleepers: [(id: UUID, deadline: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = []

    var sleeperCount: Int { sleepers.count }

    var clock: RecordingClock {
        RecordingClock(now: { self.now }, sleep: { seconds in try await self.sleep(seconds) })
    }

    func sleep(_ seconds: TimeInterval) async throws {
        let deadline = now + max(0, seconds)
        guard deadline > now else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers.append((id, deadline, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        let due = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        for sleeper in due { sleeper.continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Stands in for ScreenCaptureKit: a start that delivers its first frame
/// `startupDelay` after the countdown (on the manual clock), optionally held,
/// and a finish that hands back a real clip, optionally held.
@MainActor
private final class ScriptedCapture {
    let clock: ManualRecordingClock
    let clip: URL
    let startupDelay: TimeInterval = 0.5
    /// Holds the next start until cleared; like ScreenCaptureKit's start, a
    /// held start does not end early when its task is cancelled.
    var holdStart = false {
        didSet {
            guard !holdStart else { return }
            startGate?.resume()
            startGate = nil
        }
    }
    var holdFinish = false
    /// Thrown by the next starts while set, like a capture that cannot start.
    var startError: Error?
    private var startGate: CheckedContinuation<Void, Never>?
    private(set) var starts: [(target: CaptureTargetInfo, options: CaptureOptions)] = []
    private(set) var finishes = 0
    /// Captures stopped and deleted by a cancel (Cancel, a discarded start).
    private(set) var cancels = 0

    init(clock: ManualRecordingClock, clip: URL) {
        self.clock = clock
        self.clip = clip
    }

    func start(target: CaptureTargetInfo, options: CaptureOptions) async throws -> TimeInterval {
        if let startError { throw startError }
        starts.append((target, options))
        if holdStart { await withCheckedContinuation { startGate = $0 } }
        clock.advance(by: startupDelay)
        return clock.now
    }

    func cancel() { cancels += 1 }

    func finish() async throws -> RecordingResult {
        finishes += 1
        while holdFinish { try await Task.sleep(for: .milliseconds(5)) }
        let frame = CaptureRect(x: 0, y: 0, width: 64, height: 64)
        return RecordingResult(
            outputURL: clip, duration: 1, sourceWidth: 64, sourceHeight: 64, cursorSamples: [], clickEvents: [],
            target: CaptureTargetInfo(id: "display-1", kind: .display, nativeID: 1, title: "Test display", frame: frame)
        )
    }
}

/// A temporary library, a one-second clip, the manual clock, the scripted
/// capture and a model built on them.
@MainActor
private final class SessionFixture {
    let root: URL
    let store: ProjectStore
    let clock = ManualRecordingClock()
    let capture: ScriptedCapture
    let model: StudioModel
    let target = CaptureTargetInfo(id: "display-1", kind: .display, nativeID: 1, title: "Test display", frame: CaptureRect(x: 0, y: 0, width: 64, height: 64))

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FocusStudio-Session-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(projectsDirectory: root.appendingPathComponent("Projects", isDirectory: true))
        let clip = try await Self.makeClip(in: root)
        let capture = ScriptedCapture(clock: clock, clip: clip)
        self.capture = capture
        model = StudioModel(
            store: store,
            interactionTrackingAccess: { true },
            inputMonitoringAccess: { true },
            screenCaptureAccess: { true },
            finishCapture: { _ in try await capture.finish() },
            startCapture: { _, target, _, options in try await capture.start(target: target, options: options) },
            cancelCapture: { _ in capture.cancel() },
            recordingClock: clock.clock
        )
    }

    /// Ticks the 3-2-1 countdown: each second once the countdown waits for it.
    func runCountdown() async throws {
        for tick in 1...3 {
            try await RecordingSessionRegression.waitUntil("Countdown tick \(tick) did not wait on the clock") { clock.sleeperCount == 1 }
            try RecordingSessionRegression.expect(model.recordingCountdown == 4 - tick && model.recordingPhase == .countdown, "The countdown shows \(4 - tick), got \(model.recordingCountdown)")
            clock.advance(by: 1)
        }
    }

    func succeed(_ bridge: AutomationBridge, _ tool: String, _ arguments: [String: Any]) async throws -> MCPToolCallResult {
        let outcome = await bridge.call(toolName: tool, arguments: arguments, workingDirectory: nil, clientName: "test", progress: nil)
        guard case let .result(result) = outcome, !result.isError else { throw SessionFailure("\(tool) must succeed: \(outcome)") }
        return result
    }

    /// The error text of a call that must fail.
    func fail(_ bridge: AutomationBridge, _ tool: String, _ arguments: [String: Any]) async throws -> String {
        let outcome = await bridge.call(toolName: tool, arguments: arguments, workingDirectory: nil, clientName: "test", progress: nil)
        guard case let .result(result) = outcome, result.isError else { throw SessionFailure("\(tool) must fail: \(outcome)") }
        return result.text
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    private static func makeClip(in root: URL) async throws -> URL {
        let image = root.appendingPathComponent("frame.png")
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SessionFailure("Could not create a bitmap context")
        }
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let frame = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(image as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SessionFailure("Could not encode the clip frame")
        }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else { throw SessionFailure("Could not write the clip frame") }
        let clip = root.appendingPathComponent("scripted-recording.mp4")
        _ = try await StillImageVideoBuilder.build(from: image, to: clip, duration: 1, renderSize: CGSize(width: 64, height: 64))
        return clip
    }
}
