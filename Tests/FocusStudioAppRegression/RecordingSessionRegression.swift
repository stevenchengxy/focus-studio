import AppKit
import AVFoundation
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
/// - the person's Pause: paused time is neither recorded nor counted toward a
///   duration (the automatic stop waits for the resume, then stops once the
///   rest is recorded), get_status and wait_for_recording report it (also
///   while the capture is still flushing the pause), and stop_recording,
///   Finish and Cancel work while paused;
/// - the countdown names the AI tool whose call started it (the control
///   bar shows it on every display), and the bar belongs on the recorder,
///   the countdown and the recording, never on the other pages or while an
///   area is drawn; only the countdown and the recording stay on screen
///   when the app is hidden (⌘H);
/// - calls during a countdown or a recording never bring the main window
///   over the recorded app;
/// - a saved stop asked for inside Focus Studio (Finish, the in-app
///   assistant's stop_recording, the duration of a recording it started)
///   brings the editor forward; an external AI tool's stop, or the duration
///   of a recording one started, never activates the app;
/// - while the person draws a recording area, start_recording and calls
///   that change what the window shows are refused, and nothing about the
///   recorder's source changes;
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
///   the call's arrival. The recorder's own choices never change;
/// - macOS's microphone permission (scripted: its status and its dialog) is
///   settled before the countdown of a recording that will record the
///   microphone, never while it runs: the controller asks macOS only when
///   the person has never answered, once for everyone waiting, with
///   heartbeats above the sound prompt's, and stops waiting at its timeout
///   or when the caller is cancelled (a late answer is only remembered); an
///   AI tool's start_recording (after the sound prompt, or for the
///   recorder's own microphone) counts down only once macOS allows it and
///   otherwise answers isError with structured data (Don't Allow, turned off
///   before, restricted, no answer in time, AI tools turned off meanwhile),
///   with nothing recorded; a cancelled call records nothing; the wait
///   counts toward the detach threshold; the person's Record and the in-app
///   assistant wait for macOS's answer before their countdown and then
///   record as before, whatever it is.
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
        try await pausedTimeIsNotRecorded()
        try await pauseReadsPausedAtOnce()
        try await stopOrCancelWhilePaused()
        try await countdownNamesTheAITool()
        try await windowStaysBehindTheRecording()
        try await stopsAskedInAppShowTheEditor()
        try await drawingAnAreaRefusesAutomation()
        try codexPlanSaveIsStopping()
        try await soundConsent()
        try await soundPromptWithinTheCallsTime()
        try await microphoneAccessController()
        try await microphoneBeforeTheCountdown()
        try await microphoneWaitWithinTheCallsTime()
        try await microphoneForThePersonsRecord()
        try await automationWaitsForThePersonsRecord()
        try await trackingAlertBeforeTheMicrophone()
        print("RecordingSessionRegression: PASS (countdown and automatic stop on a manual clock, the duration measured from the first frame, Finish/Cancel cancel the automatic stop and Cancel stops the capture, the automatic stop joined by stop_recording and wait_for_recording with one project, get_status and the call queue free while wait_for_recording waits and no job for it, a late wait_for_recording shortened to its maximum from the call's arrival, Cancel ignored and starts refused while saving, per-recording options (browser_content_only's crop, audio shown) with the recorder's choices unchanged, discarding a countdown, a capture start or a live recording (moved to the Trash like Cancel), pause and resume (paused time left out of the duration, elapsed and remaining; reported by get_status and wait_for_recording, also while the pause flushes; stop and cancel while paused), the countdown naming the AI tool and the control bar's pages (only the countdown and the recording stay when the app is hidden), no main window over a recording, the editor brought forward after a stop asked for in the app (Finish, the in-app assistant, its recording's duration, a Finish joining an external stop) but never after an external AI tool's stop or its recording's duration, automation refused while an area is drawn with the recorder's source unchanged, a Codex plan's save is stopping, the sound prompt before the countdown for sound the recorder leaves off (60 s by default as the catalog says, naming the client and the program that started it; allow, record without sound with no sound at all even when the recorder records some, cancel, no answer closes it, turned off meanwhile, a recorder sound turned off while it is up stays off, cancelled call, heartbeats above the approval's and the turn's; none for no sound, the recorder's own sound or the in-app assistant; the recorder's choices unchanged; its wait detaching as a job from the call's arrival), macOS's microphone permission settled before the countdown (the controller: one dialog for every caller, heartbeats above the sound prompt's, its timeout, a cancelled wait, a late answer only remembered; an AI tool's start_recording: never asked then allowed, Don't Allow, turned off before, restricted, no answer in time with the late answer starting nothing, a cancelled call, AI tools turned off meanwhile, the recorder's own microphone, none for record without sound or without the microphone, the wait detaching as a job; the person's Record and the in-app assistant wait for the answer, then record as before; while the person's Record waits, an AI tool's start_recording (with no sound of its own, or after its sound prompt), the in-app start, delete_project and an edit that opens a project are refused with the recorder's source unchanged, and the person's Record then records the source they chose, never a source changed meanwhile; the interaction-tracking alert comes up before macOS's dialog, while the Record click is handled))")
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

    // MARK: - Pause

    /// A 5-second recording paused after 2 s: nothing counts while paused
    /// (the automatic stop no longer waits, elapsed and remaining hold
    /// still), get_status and wait_for_recording say so, and after the
    /// resume's first frame it stops once 3 more seconds are recorded.
    private static func pausedTimeIsNotRecorded() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, clock, capture) = (fixture.model, fixture.clock, fixture.capture)
        let bridge = AutomationBridge(model: model)
        await model.toggleRecordingPause()
        try expect(capture.pauses == 0 && !model.isRecordingPaused, "Nothing to pause before a recording")
        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions(duration: 5))
        try await fixture.runCountdown()
        try await waitUntil("The recording did not start") { model.recordingPhase == .recording && clock.sleeperCount == 1 }
        clock.advance(by: 2)
        try await settle()

        await model.toggleRecordingPause()
        try expect(capture.pauses == 1 && model.isRecordingPaused && model.recordingPhase == .recording, "Pause keeps the recording live and paused")
        try await waitUntil("The automatic stop still waits while paused") { clock.sleeperCount == 0 && !model.hasPendingAutomaticStop }
        clock.advance(by: 30)
        try await settle()
        try expect(capture.finishes == 0 && model.recordingElapsed == 2 && model.recordingRemaining == 3,
                   "Paused time counts toward nothing: \(String(describing: model.recordingElapsed)) recorded, \(String(describing: model.recordingRemaining)) left")
        let session = model.recordingSession
        try expect(session?.isPaused == true && session?.autoStopAt == nil && session?.pausedDuration == 30, "The session is paused with no stop time yet: \(String(describing: session))")
        let status = try await fixture.succeed(bridge, "get_status", [:])
        try expect(status.structuredContent?["recording"]?["state"] == "recording" && status.structuredContent?["recording"]?["paused"] == true
                   && status.structuredContent?["recording"]?["elapsed"] == 2 && status.structuredContent?["recording"]?["remaining"] == 3 && status.text.contains("paused"),
                   "get_status reports the pause: \(status.json)")
        let waited = try await fixture.succeed(bridge, "wait_for_recording", ["timeout_seconds": 0])
        try expect(waited.structuredContent?["state"] == "recording" && waited.structuredContent?["paused"] == true && waited.structuredContent?["remaining"] == 3
                   && waited.structuredContent?["auto_stop_at"] == nil && waited.text.contains("paused"),
                   "wait_for_recording reports the pause: \(waited.json)")

        await model.toggleRecordingPause()
        try expect(capture.resumes == 1 && !model.isRecordingPaused && model.recordingRemaining == 3, "Resume records again from its first frame, 3 s left")
        try await waitUntil("The automatic stop did not wait again") { clock.sleeperCount == 1 && model.hasPendingAutomaticStop }
        let resumed = model.recordingSession
        let pausedFor = 30 + capture.resumeDelay
        try expect(resumed?.isPaused == false && resumed?.pausedDuration == pausedFor
                   && resumed?.autoStopAt.map { abs($0.timeIntervalSince(resumed!.startedAt!) - (5 + pausedFor)) < 0.001 } == true,
                   "auto_stop_at moves later by the time paused: \(String(describing: resumed))")
        clock.advance(by: 2.75)
        try await settle()
        try expect(capture.finishes == 0 && model.recordingPhase == .recording, "Still recording after 4.75 s of recording")
        clock.advance(by: 0.25)
        try await waitUntil("The rest of the duration did not stop the recording") { model.destination == .editor }
        try expect(capture.finishes == 1 && model.projects.count == 1 && model.recordingSession?.outcome == .finished(projectID: model.projects[0].id),
                   "One stop and one project after 5 s of recording")
    }

    /// The engine stops counting the moment Pause is clicked and writes what
    /// it recorded afterwards (up to seconds). Meanwhile the recording reads
    /// as paused everywhere: nothing counts, no automatic stop is due, and
    /// get_status and wait_for_recording say paused, with no auto_stop_at.
    /// Once the flush ends the capture's own intervals say the same.
    private static func pauseReadsPausedAtOnce() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, clock, capture) = (fixture.model, fixture.clock, fixture.capture)
        let bridge = AutomationBridge(model: model)
        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions(duration: 5))
        try await fixture.runCountdown()
        try await waitUntil("The recording did not start") { model.recordingPhase == .recording && clock.sleeperCount == 1 }
        clock.advance(by: 4.5)
        try await settle()

        capture.holdPause = true
        let pausing = Task { @MainActor in await model.toggleRecordingPause() }
        try await waitUntil("The pause did not reach the capture") { capture.pauses == 1 }
        try expect(model.isChangingRecordingPause && model.isRecordingPaused && !model.hasPendingAutomaticStop
                   && model.recordingElapsed == 4.5 && model.recordingRemaining == 0.5,
                   "Paused from the click on: \(String(describing: model.recordingElapsed)) recorded, \(String(describing: model.recordingRemaining)) left")
        try await waitUntil("The automatic stop still waits while the pause flushes") { clock.sleeperCount == 0 }
        clock.advance(by: 1)
        try await settle()
        let session = model.recordingSession
        try expect(capture.finishes == 0 && model.recordingElapsed == 4.5 && model.recordingRemaining == 0.5 && session?.isPaused == true && session?.autoStopAt == nil,
                   "Nothing counts or stops while the pause flushes: \(String(describing: session))")
        let status = try await fixture.succeed(bridge, "get_status", [:])
        let recording = status.structuredContent?["recording"]
        try expect(recording?["state"] == "recording" && recording?["paused"] == true && recording?["elapsed"]?.doubleValue == 4.5 && recording?["remaining"]?.doubleValue == 0.5,
                   "get_status reports the pause while it flushes: \(status.json)")
        let waited = try await fixture.succeed(bridge, "wait_for_recording", ["timeout_seconds": 0])
        try expect(waited.structuredContent?["paused"] == true && waited.structuredContent?["remaining"]?.doubleValue == 0.5
                   && waited.structuredContent?["auto_stop_at"] == nil && waited.text.contains("paused") && !waited.text.contains("stops by itself"),
                   "wait_for_recording reports the pause while it flushes: \(waited.json)")

        capture.holdPause = false
        await pausing.value
        try expect(!model.isChangingRecordingPause && model.isRecordingPaused && model.recordingElapsed == 4.5 && model.recordingRemaining == 0.5,
                   "The capture's own intervals agree once the flush ends")
        await model.toggleRecordingPause()
        try await waitUntil("The automatic stop did not wait again") { clock.sleeperCount == 1 && model.hasPendingAutomaticStop }
        clock.advance(by: 0.5)
        try await waitUntil("The rest of the duration did not stop the recording") { model.destination == .editor }
        try expect(capture.finishes == 1 && model.projects.count == 1, "One stop once 5 s are recorded")
    }

    /// stop_recording and Finish save a paused recording, and Cancel
    /// discards one; a pause while the recording is being saved does nothing.
    private static func stopOrCancelWhilePaused() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, clock, capture) = (fixture.model, fixture.clock, fixture.capture)
        let bridge = AutomationBridge(model: model)
        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions(duration: 5))
        try await fixture.runCountdown()
        try await waitUntil("The recording did not start") { model.recordingPhase == .recording && clock.sleeperCount == 1 }
        await model.toggleRecordingPause()
        let stopped = try await fixture.succeed(bridge, "stop_recording", [:])
        try expect(stopped.structuredContent?["state"] == "finished" && capture.finishes == 1 && model.destination == .editor && !model.isRecordingPaused,
                   "stop_recording saves a paused recording: \(stopped.json)")

        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions())
        try await fixture.runCountdown()
        try await waitUntil("The second recording did not start") { model.recordingPhase == .recording }
        await model.toggleRecordingPause()
        await model.cancelRecording()
        try expect(capture.cancels == 1 && model.recordingSession?.outcome == .cancelled && model.destination == .library && model.projects.count == 1,
                   "Cancel discards a paused recording")

        _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions())
        try await fixture.runCountdown()
        try await waitUntil("The third recording did not start") { model.recordingPhase == .recording }
        capture.holdFinish = true
        let finishing = Task { @MainActor in await model.stopRecording() }
        try await waitUntil("The stop did not begin") { model.isFinishingRecording }
        await model.toggleRecordingPause()
        try expect(capture.pauses == 2 && !model.isRecordingPaused, "No pause while the recording is being saved")
        capture.holdFinish = false
        await finishing.value
        try expect(model.projects.count == 2 && model.destination == .editor, "The save completes")
    }

    // MARK: - Countdown in the control bar

    /// The countdown of a recording an AI tool starts names that tool (the
    /// control bar shows it on every display, window or not); the person's
    /// own countdown names none. The bar is on screen for the recorder, the
    /// countdown and the recording only, and never while an area is drawn.
    private static func countdownNamesTheAITool() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.automationRequester = { "Claude Code" }
        let asked = try model.startRecording(target: fixture.target, options: AIRecordingOptions())
        try expect(model.currentRecording?.id == asked && model.currentRecording?.requester == "Claude Code", "The countdown names the AI tool that asked")
        model.cancelRecordingCountdown()
        model.automationRequester = { nil }
        try expect(model.beginRecordingCountdown(target: fixture.target, settings: model.recorderSettings, duration: nil) != nil
                   && model.currentRecording?.requester == nil, "The person's own countdown names no AI tool")
        model.cancelRecordingCountdown()

        typealias Bar = RecordingControlPanelCoordinator
        for destination in [StudioModel.Destination.recorder, .countdown, .recording] {
            try expect(Bar.showsControls(destination: destination, isSelectingArea: false), "The bar shows on \(destination)")
            try expect(!Bar.showsControls(destination: destination, isSelectingArea: true), "The bar hides while an area is drawn on \(destination)")
        }
        for destination in [StudioModel.Destination.library, .director, .editor] {
            try expect(!Bar.showsControls(destination: destination, isSelectingArea: false), "No bar on \(destination)")
        }
        // ⌘H hides the recorder's ready console with the app, as upstream's
        // did; a countdown or a recording stays so the person can cancel it.
        try expect(!Bar.staysWhenAppHidden(.recorder) && Bar.staysWhenAppHidden(.countdown) && Bar.staysWhenAppHidden(.recording),
                   "Only the countdown and the recording stay on screen when the app is hidden")
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

    // MARK: - Bringing the app forward

    /// A saved stop asked for inside Focus Studio shows the editor in front,
    /// as upstream's stop always did: the person's Finish, the in-app
    /// assistant's stop_recording (which the person confirmed), and the
    /// duration of a recording the in-app assistant started. An external AI
    /// tool's stop_recording, and the duration of a recording one started,
    /// leave the app where it is (the person may be typing elsewhere). A
    /// Finish that joins an external stop in flight still brings it forward.
    private static func stopsAskedInAppShowTheEditor() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, clock, capture) = (fixture.model, fixture.clock, fixture.capture)
        let activations = TestBox(0)
        model.activateAfterStop = { activations.value += 1 }
        let bridge = AutomationBridge(model: model)
        func recordOnce(duration: TimeInterval? = nil) async throws {
            _ = try model.startRecording(target: fixture.target, options: AIRecordingOptions(duration: duration))
            try await fixture.runCountdown()
            try await waitUntil("The recording did not start") { model.recordingPhase == .recording && (duration == nil || clock.sleeperCount == 1) }
        }

        try await recordOnce()
        let external = try await fixture.succeed(bridge, "stop_recording", [:])
        try await settle()
        try expect(external.structuredContent?["state"] == "finished" && model.destination == .editor && activations.value == 0,
                   "An external AI tool's stop leaves the app where it is: \(activations.value) activations")

        try await recordOnce()
        let inAppStop = try unwrap(AIAssistantToolCatalog.standard.first { $0.name == "stop_recording" }, "The in-app assistant has stop_recording")
        let inApp = model.assistantSession.context
        try expect(!inApp.isExternal, "The in-app assistant's context is not external")
        let stopped = try await inAppStop.run(arguments: [:], context: inApp, progress: { _ in })
        try await waitUntil("The in-app assistant's stop did not bring the editor forward") { activations.value == 1 }
        try expect(stopped.data?["state"] == "finished" && model.destination == .editor && model.projects.count == 2, "The in-app assistant's stop saved its project")

        try await recordOnce()
        await model.stopRecording()
        try expect(activations.value == 2 && model.destination == .editor && model.projects.count == 3, "The person's Finish brings the editor forward")

        try await recordOnce(duration: 2)
        try expect(model.currentRecording?.requester == nil, "The in-app assistant's recording names no AI tool")
        clock.advance(by: 2)
        try await waitUntil("The duration did not stop the in-app recording") { model.destination == .editor && !model.isFinishingRecording }
        try await waitUntil("The in-app recording's duration did not bring the editor forward") { activations.value == 3 }

        model.automationRequester = { "Claude Code" }
        try await recordOnce(duration: 2)
        model.automationRequester = nil
        try expect(model.currentRecording?.requester == "Claude Code", "The external recording names its AI tool")
        clock.advance(by: 2)
        try await waitUntil("The duration did not stop the external recording") { model.destination == .editor && !model.isFinishingRecording }
        try await settle()
        try expect(activations.value == 3 && capture.finishes == 5 && model.projects.count == 5, "An external recording's duration leaves the app where it is: \(activations.value)")

        try await recordOnce()
        capture.holdFinish = true
        let externalStop = Task { @MainActor in
            await bridge.call(toolName: "stop_recording", arguments: [:], workingDirectory: nil, clientName: "test", progress: nil)
        }
        try await waitUntil("The external stop did not begin") { model.isFinishingRecording }
        let finish = Task { @MainActor in await model.stopRecording() }
        try await settle()
        capture.holdFinish = false
        await finish.value
        guard case let .result(joined) = await externalStop.value, !joined.isError else { throw SessionFailure("The external stop must succeed") }
        try await settle()
        try expect(capture.finishes == 6 && model.projects.count == 6 && activations.value == 4,
                   "A Finish joining an external stop brings the editor forward once: \(activations.value)")
    }

    // MARK: - Area drawing

    /// While the person draws a recording area (the full-screen overlay),
    /// start_recording and every call that changes what the window shows are
    /// refused before anything changes: the recorder keeps their source
    /// kind and selection, no countdown starts, the editor does not open
    /// under the overlay. The in-app assistant's start is refused the same
    /// way. Once the drawing ends, the area is theirs and calls work again.
    private static func drawingAnAreaRefusesAutomation() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, capture) = (fixture.model, fixture.capture)
        try model.captureEngine.registerAreaTarget(soundArea)
        let project = RecordingProject(title: "Edited later", sourceVideoPath: "raw.mp4", duration: 3, sourceWidth: 64, sourceHeight: 64)
        try await fixture.store.save(project)
        model.projects = [project]
        let bridge = AutomationBridge(model: model)
        let windowRequests = TestBox(0)
        bridge.presentWindow = { windowRequests.value += 1 }
        let drawn = CaptureTargetInfo(id: "area-1-drawn", kind: .area, nativeID: fixture.target.nativeID, title: "Drawn area", frame: CaptureRect(x: 0, y: 0, width: 32, height: 32))
        let drawing = TestBox<CheckedContinuation<CaptureTargetInfo?, Never>?>(nil)
        model.drawRecordingArea = { _, _ in
            await withCheckedContinuation { (continuation: CheckedContinuation<CaptureTargetInfo?, Never>) in drawing.value = continuation }
        }

        model.destination = .recorder
        let selecting = Task { @MainActor in await model.beginAreaSelection(on: fixture.target) }
        try await waitUntil("The area drawing did not begin") { model.isSelectingArea && drawing.value != nil }
        let selectedBefore = model.selectedTargetID

        let refusedStart = try await fixture.fail(bridge, "start_recording", ["source": soundArea.id])
        try expect(refusedStart.contains("drawing a recording area"), "start_recording is refused while an area is drawn: \(refusedStart)")
        try expect(model.selectedTargetID == selectedBefore && model.recordingSourceKind == .area && model.destination == .recorder
                   && model.recordingSession == nil && capture.starts.isEmpty && windowRequests.value == 0,
                   "Nothing changed: \(String(describing: model.selectedTargetID)), \(model.recordingSourceKind), \(model.destination)")
        let zoom: [String: Any] = ["project_id": project.id.uuidString, "start": 0.1, "end": 0.8, "x": 0.5, "y": 0.5]
        let refusedEdit = try await fixture.fail(bridge, "add_zoom", zoom)
        try expect(refusedEdit.contains("drawing a recording area") && model.destination == .recorder && model.activeProject == nil,
                   "An edit does not open the editor under the overlay: \(refusedEdit)")
        do {
            _ = try model.startRecording(target: soundArea, options: AIRecordingOptions())
            throw SessionFailure("The in-app assistant's start must be refused while an area is drawn")
        } catch let error as AIToolError {
            try expect(error.localizedDescription.contains("drawing a recording area"), "The in-app start says why: \(error.localizedDescription)")
        }
        try expect(model.selectedTargetID == selectedBefore && model.recordingSourceKind == .area && model.recordingSession == nil,
                   "The in-app start changed nothing either")

        drawing.value?.resume(returning: drawn)
        await selecting.value
        try expect(!model.isSelectingArea && model.selectedTargetID == drawn.id && model.recordingSourceKind == .area, "The drawn area is selected")
        let started = try result(try await record([:], fixture: fixture, bridge: bridge), "after the drawing")
        try expect(!started.isError && model.recordingPhase == .recording, "start_recording works once the drawing ended: \(started.json)")
        await model.stopRecording()
        try expect(model.destination == .editor && model.projects.count == 2, "The recording saved")
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

    /// A selected area of the main display: the only source the engine lists
    /// (no ScreenCaptureKit), which start_recording can name by its id. Its
    /// display must still be connected when the countdown ends, so it lives on
    /// the Mac's main display (the capture itself is scripted).
    private static let soundArea = CaptureTargetInfo(id: "area-1-sound", kind: .area, nativeID: CGMainDisplayID(), title: "Test area", frame: CaptureRect(x: 0, y: 0, width: 64, height: 64))

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
        try expect(!inApp.isExternal && inApp.recordingAudioConsent == nil && inApp.microphoneAccess != nil, "The in-app assistant's context is not external, and checks macOS's microphone access")
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

    // MARK: - Microphone permission

    /// The controller asks macOS only when the person has never answered,
    /// once for everyone waiting, with heartbeats above the sound prompt's;
    /// a wait ends at its timeout or when its caller is cancelled, while
    /// macOS's dialog stays up and its late answer is only remembered.
    private static func microphoneAccessController() async throws {
        try expect(MicrophoneAuthorization(.notDetermined) == .notDetermined && MicrophoneAuthorization(.authorized) == .authorized
                   && MicrophoneAuthorization(.denied) == .denied && MicrophoneAuthorization(.restricted) == .restricted, "macOS's statuses map one to one")
        // One call's heartbeats rise from the sound prompt's (which comes
        // first) to macOS's microphone dialog's.
        let soundMost = AutomationAudioConsentController.heartbeatBase
            + ((AutomationAudioConsentController.defaultTimeout / AutomationAudioConsentController.defaultHeartbeatInterval).rounded(.up) + 2) * AutomationAudioConsentController.heartbeatStep
        try expect(soundMost < MicrophoneAccessController.heartbeatBase, "The sound prompt's heartbeats (up to \(soundMost)) stay below the microphone dialog's (from \(MicrophoneAccessController.heartbeatBase))")
        // An AI tool's call waits 60 s for macOS's answer (AppServices uses
        // the defaults), as start_recording's description says.
        try expect(MicrophoneAccessController.defaultTimeout == 60 && MicrophoneAccessController().timeout == 60, "The call waits 60 s for macOS's dialog by default")
        let startText = try unwrap(MCPToolCatalog.v1.tool(named: "start_recording"), "start_recording").description
        try expect(startText.contains("no answer to it within \(Int(MicrophoneAccessController.defaultTimeout)) seconds cancels too"), "start_recording promises that wait: \(startText)")

        let microphone = ScriptedMicrophone()
        let access = microphone.controller(timeout: 5, heartbeatInterval: 0.05)
        // Decided already: macOS is not asked, nothing is reported.
        for (status, expected) in [(MicrophoneAuthorization.authorized, AIMicrophoneAccess.authorized(askedNow: false)), (.denied, .denied(askedNow: false)), (.restricted, .restricted)] {
            microphone.status = status
            let reports = ProgressReports()
            let answer = await access.ensure(progress: reports.handler, timeout: 5)
            try expect(answer == expected && microphone.requests == 0 && reports.values.isEmpty, "\(status): \(answer), no dialog, no progress")
        }

        // Never asked: one dialog for both callers, heartbeats while it is up.
        microphone.status = .notDetermined
        let reports = ProgressReports()
        let first = Task { @MainActor in await access.ensure(progress: reports.handler, timeout: 5) }
        let second = Task { @MainActor in await access.ensure(progress: nil, timeout: nil) }
        try await waitUntil("macOS's dialog") { microphone.heldCount == 1 && access.waitingCount == 2 }
        try await Task.sleep(for: .milliseconds(200))
        try expect(microphone.requests == 1 && access.isAsking, "One dialog for both callers: \(microphone.requests)")
        microphone.answer(true)
        let (firstAnswer, secondAnswer) = (await first.value, await second.value)
        try expect(firstAnswer == .authorized(askedNow: true) && secondAnswer == .authorized(askedNow: true) && !access.isAsking && access.waitingCount == 0,
                   "Both get the person's Allow: \(firstAnswer), \(secondAnswer)")
        let values = reports.values
        try expect(values.count >= 4 && zip(values, values.dropFirst()).allSatisfy { $0.progress < $1.progress } && values.allSatisfy { $0.progress > MicrophoneAccessController.heartbeatBase && $0.total == nil }
                   && values.dropLast().allSatisfy { $0.message == MicrophoneAccessController.waitingMessage } && values.last?.message == nil,
                   "Heartbeats while macOS asks, then one without a message: \(values.map { "\($0.progress) \($0.message ?? "-")" })")
        let allowedNow = await access.ensure(progress: nil, timeout: 5)
        try expect(allowedNow == .authorized(askedNow: false) && microphone.requests == 1, "Allowed from then on, without asking again")

        // Don't Allow; and Don't Allow where access turns out restricted.
        for (status, expected) in [(MicrophoneAuthorization.denied, AIMicrophoneAccess.denied(askedNow: true)), (.restricted, .restricted)] {
            microphone.status = .notDetermined
            let asking = Task { @MainActor in await access.ensure(progress: nil, timeout: 5) }
            try await waitUntil("macOS's dialog") { microphone.heldCount == 1 }
            microphone.answer(false, status: status)
            let answer = await asking.value
            try expect(answer == expected, "Don't Allow with macOS then reporting \(status): \(answer)")
        }

        // No answer in time: the wait ends, the dialog stays up; a later
        // caller waits for that same dialog, and a cancelled one stops at once.
        microphone.status = .notDetermined
        let impatient = microphone.controller(timeout: 0.2, heartbeatInterval: 0.05)
        let requestsBefore = microphone.requests
        let unanswered = await impatient.ensure(progress: nil, timeout: impatient.timeout)
        try expect(unanswered == .timedOut(0.2) && microphone.heldCount == 1 && impatient.isAsking && microphone.requests == requestsBefore + 1,
                   "No answer within the timeout: \(unanswered), the dialog still up")
        let again = Task { @MainActor in await impatient.ensure(progress: nil, timeout: 5) }
        let cancelled = Task { @MainActor in await impatient.ensure(progress: nil, timeout: nil) }
        try await waitUntil("both callers waiting") { impatient.waitingCount == 2 }
        cancelled.cancel()
        let cancelledAnswer = await cancelled.value
        try expect(cancelledAnswer == .timedOut(0) && impatient.waitingCount == 1 && microphone.requests == requestsBefore + 1,
                   "A cancelled caller stops waiting at once; nobody asked macOS again: \(cancelledAnswer)")
        microphone.answer(true)
        let late = await again.value
        try expect(late == .authorized(askedNow: true) && !impatient.isAsking, "The caller still waiting gets the late answer: \(late)")
    }

    /// An AI tool's start_recording that will record the microphone has macOS
    /// settle Focus Studio's access after the sound prompt and before the
    /// countdown, and records only when macOS allows it.
    private static func microphoneBeforeTheCountdown() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, capture, microphone) = (fixture.model, fixture.capture, fixture.microphone)
        try model.captureEngine.registerAreaTarget(soundArea)
        let prompter = ScriptedSoundPrompter()
        prompter.mode = .answer(.allow)
        let bridge = AutomationBridge(model: model)
        bridge.audioConsent = AutomationAudioConsentController(timeout: 5, heartbeatInterval: 0.05) { await prompter.prompt($0) }
        let choices = model.recorderSettings
        let settingsPath = "System Settings › Privacy & Security › Microphone"

        // Never asked, then allowed: macOS's dialog comes after the sound
        // prompt and before the countdown, and the call's progress keeps rising.
        microphone.status = .notDetermined
        let beats = ProgressReports()
        let granting = Task { @MainActor in try await record(["microphone": true], fixture: fixture, bridge: bridge, progress: beats.handler) }
        try await waitUntil("macOS's microphone dialog") { microphone.heldCount == 1 }
        try await Task.sleep(for: .milliseconds(250))
        try expect(prompter.requests.count == 1 && model.recordingPhase == .idle && model.destination != .countdown && capture.starts.isEmpty,
                   "No countdown while macOS asks, after the sound prompt")
        microphone.answer(true)
        let allowed = try result(try await granting.value, "allowed in macOS's dialog")
        try expect(!allowed.isError && allowed.text.contains("macOS asked the person whether Focus Studio may use the microphone, and they allowed it")
                   && capture.starts.last?.options.microphone == true && microphone.requests == 1, "Recorded with the microphone once macOS allowed it: \(allowed.json)")
        let values = beats.values
        let lastSound = values.lastIndex { ($0.message ?? "").contains("sound prompt") }
        let firstMicrophone = values.firstIndex { $0.message == MicrophoneAccessController.waitingMessage }
        try expect(zip(values, values.dropFirst()).allSatisfy { $0.progress < $1.progress } && lastSound != nil && firstMicrophone != nil && lastSound! < firstMicrophone!
                   && values.filter { $0.message == MicrophoneAccessController.waitingMessage }.count >= 3 && values.last?.message == nil,
                   "The sound prompt's heartbeats, then macOS's dialog's, always increasing: \(values.map { "\($0.progress) \($0.message ?? "-")" })")
        await model.stopRecording()

        // Allowed before: no dialog, and the text says nothing about one.
        let allowedBefore = try result(try await record(["microphone": true], fixture: fixture, bridge: bridge), "allowed before")
        try expect(!allowedBefore.isError && !allowedBefore.text.contains("macOS asked") && microphone.requests == 1 && capture.starts.last?.options.microphone == true,
                   "Allowed before: recorded without asking: \(allowedBefore.text)")
        await model.stopRecording()

        // Never asked, then Don't Allow: nothing counts down; the model reads why and what to do.
        microphone.status = .notDetermined
        let denying = Task { @MainActor in try await record(["microphone": true], fixture: fixture, bridge: bridge) }
        try await waitUntil("macOS's microphone dialog") { microphone.heldCount == 1 }
        let startsBefore = capture.starts.count
        microphone.answer(false)
        let denied = try result(try await denying.value, "Don't Allow")
        try expect(denied.isError && denied.text.contains("chose Don't Allow") && denied.text.contains(settingsPath) && denied.text.contains("call start_recording again with microphone false")
                   && denied.structuredContent?["status"] == "microphone_unavailable" && denied.structuredContent?["microphone_access"] == "denied"
                   && denied.structuredContent?["asked_now"] == true && denied.structuredContent?["retry_with"] == ["microphone": false], "Don't Allow: \(denied.json)")
        try expect(capture.starts.count == startsBefore && model.recordingPhase == .idle && model.destination != .countdown && model.recorderSettings == choices, "Nothing counted down or recorded")

        // Turned off before, or restricted: refused at once, without a dialog.
        for (status, state) in [(MicrophoneAuthorization.denied, "denied"), (.restricted, "restricted")] {
            microphone.status = status
            let requestsBefore = microphone.requests
            let refused = try result(try await record(["microphone": true], fixture: fixture, bridge: bridge), "\(status)")
            try expect(refused.isError && refused.structuredContent?["microphone_access"] == AIJSONValue(state) && refused.structuredContent?["asked_now"] == false
                       && microphone.requests == requestsBefore && capture.starts.count == startsBefore && model.recordingPhase == .idle, "\(status): refused without a dialog: \(refused.json)")
            if status == .denied {
                try expect(refused.text.contains("the person has turned off Focus Studio's microphone access in \(settingsPath)"), "Turned off before: \(refused.text)")
            }
        }
        // Without the microphone the same call records the screen.
        let screenOnly = try result(try await record(["microphone": false], fixture: fixture, bridge: bridge), "without the microphone")
        try expect(!screenOnly.isError && capture.starts.last?.options.microphone == false, "Recorded without the microphone: \(screenOnly.json)")
        await model.stopRecording()

        // Record without sound, or a call without the microphone, never asks macOS.
        microphone.status = .notDetermined
        prompter.mode = .answer(.withoutSound)
        let requestsBefore = microphone.requests
        let silent = try result(try await record(["microphone": true], fixture: fixture, bridge: bridge), "record without sound")
        try expect(!silent.isError && capture.starts.last?.options.microphone == false && microphone.requests == requestsBefore, "Record without sound: no dialog")
        await model.stopRecording()
        prompter.mode = .answer(.allow)
        let quiet = try result(try await record(["system_audio": true], fixture: fixture, bridge: bridge), "system audio only")
        try expect(!quiet.isError && microphone.requests == requestsBefore, "No microphone, no dialog")
        await model.stopRecording()

        // The recorder's own microphone: no sound prompt, but macOS still
        // settles its access before the countdown.
        model.recordMicrophone = true
        let promptsBefore = prompter.requests.count
        let own = Task { @MainActor in try await record([:], fixture: fixture, bridge: bridge) }
        try await waitUntil("macOS's dialog for the recorder's microphone") { microphone.heldCount == 1 }
        try expect(model.recordingPhase == .idle && prompter.requests.count == promptsBefore, "No sound prompt and no countdown while macOS asks")
        microphone.answer(true)
        let ownResult = try result(try await own.value, "the recorder's own microphone")
        try expect(!ownResult.isError && capture.starts.last?.options.microphone == true, "Recorded with the recorder's microphone: \(ownResult.json)")
        await model.stopRecording()
        microphone.status = .denied
        let ownStarts = capture.starts.count
        let ownRefused = try result(try await record([:], fixture: fixture, bridge: bridge), "the recorder's microphone, turned off in macOS")
        try expect(ownRefused.isError && ownRefused.structuredContent?["status"] == "microphone_unavailable" && capture.starts.count == ownStarts,
                   "The recorder's microphone turned off in macOS: refused: \(ownRefused.text)")
        model.recordMicrophone = false

        // A call cancelled while macOS asks records nothing; the dialog stays.
        microphone.status = .notDetermined
        let cancelledCall = Task { @MainActor in
            await bridge.call(toolName: "start_recording", arguments: ["source": soundArea.id, "microphone": true], workingDirectory: nil, clientName: "Claude Code", progress: nil)
        }
        try await waitUntil("macOS's microphone dialog") { microphone.heldCount == 1 && model.microphoneAccess.waitingCount == 1 }
        cancelledCall.cancel()
        let cancelledOutcome = await cancelledCall.value
        try expect(cancelledOutcome == .cancelled && model.recordingPhase == .idle && capture.starts.count == ownStarts && microphone.heldCount == 1,
                   "A cancelled call records nothing: \(cancelledOutcome)")

        // AI tools turned off (or the client revoked) while macOS asked:
        // refused even after the person allowed the microphone. The call
        // waits for the dialog already up.
        let turnedOff = TestBox(false)
        let offCall = Task { @MainActor in
            try await record(["microphone": true], fixture: fixture, bridge: bridge, stillAllowed: { turnedOff.value ? AutomationSwitch.disabledMessage(tool: "start_recording") : nil })
        }
        try await waitUntil("the call waiting for macOS's dialog") { model.microphoneAccess.waitingCount == 1 }
        let requestsNow = microphone.requests
        turnedOff.value = true
        microphone.answer(true)
        let off = try result(try await offCall.value, "turned off while macOS asked")
        try expect(off.isError && off.text == AutomationSwitch.disabledMessage(tool: "start_recording") && capture.starts.count == ownStarts && model.recordingPhase == .idle
                   && microphone.requests == requestsNow, "Refused after macOS's answer, one dialog for both calls: \(off.text)")
        try expect(model.recorderSettings == choices, "The recorder's own choices never changed")

        // No answer in time: nothing records, and the late answer starts nothing.
        let impatient = try await SessionFixture(microphoneTimeout: 0.3)
        defer { impatient.cleanup() }
        try impatient.model.captureEngine.registerAreaTarget(soundArea)
        let timing = AutomationBridge(model: impatient.model)
        timing.audioConsent = AutomationAudioConsentController(timeout: 5, heartbeatInterval: 0.05) { await prompter.prompt($0) }
        impatient.microphone.status = .notDetermined
        let unanswered = try result(try await record(["microphone": true], fixture: impatient, bridge: timing), "no answer")
        try expect(unanswered.isError && unanswered.text.contains("nobody answered its dialog within 0.3 seconds") && unanswered.text.contains("may still be on screen")
                   && unanswered.structuredContent?["microphone_access"] == "not_determined" && unanswered.structuredContent?["waited"] == 0.3,
                   "No answer: \(unanswered.json)")
        try expect(impatient.capture.starts.isEmpty && impatient.model.recordingPhase == .idle && impatient.microphone.heldCount == 1, "Nothing recorded; macOS's dialog is still up")
        impatient.microphone.answer(true)
        try await Task.sleep(for: .milliseconds(200))
        try expect(impatient.capture.starts.isEmpty && impatient.model.recordingPhase == .idle && impatient.model.destination != .countdown, "The late answer starts nothing")
    }

    /// macOS's dialog counts toward the call's time like the other prompts:
    /// still unanswered when the time is up, the call answers with a job
    /// that says what it waits for; wait_for_job collects the recording.
    private static func microphoneWaitWithinTheCallsTime() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, capture, microphone) = (fixture.model, fixture.capture, fixture.microphone)
        try model.captureEngine.registerAreaTarget(soundArea)
        let prompter = ScriptedSoundPrompter()
        prompter.mode = .answer(.allow)
        let bridge = AutomationBridge(model: model, jobs: AutomationJobs(detachAfter: 1))
        bridge.audioConsent = AutomationAudioConsentController(timeout: 5, heartbeatInterval: 0.05) { await prompter.prompt($0) }
        microphone.status = .notDetermined

        let asked = Date()
        let running = try result(try await record(["microphone": true], fixture: fixture, bridge: bridge, arrivedAt: Date().addingTimeInterval(-0.8)), "detached")
        let took = Date().timeIntervalSince(asked)
        let jobID = try unwrap(running.structuredContent?["job_id"]?.stringValue, "A job id: \(running.json)")
        try expect(!running.isError && running.structuredContent?["status"] == "running" && took < 0.7, "Detached from the call's arrival, after \(took) s: \(running.json)")
        try expect(running.structuredContent?["activity"] == "waiting for the person to answer macOS's microphone access prompt for Focus Studio",
                   "The running status says it waits for macOS's dialog: \(running.json)")
        try expect(microphone.heldCount == 1 && model.recordingPhase == .idle && capture.starts.isEmpty, "The dialog is still up and nothing counts down")

        microphone.answer(true)
        try await waitUntil("The allowed job did not count down") { model.recordingPhase == .countdown }
        try await fixture.runCountdown()
        let collected = try result(await bridge.call(toolName: "wait_for_job", arguments: ["job_id": jobID, "timeout_seconds": 10], workingDirectory: nil, clientName: "Claude Code", progress: nil), "wait_for_job")
        try expect(!collected.isError && collected.structuredContent?["state"] == "recording" && collected.text.contains("macOS asked the person"),
                   "wait_for_job returns the recording: \(collected.json)")
        try expect(capture.starts.last?.options.microphone == true, "Recorded with the microphone")
        await model.stopRecording()
    }

    /// The person's Record and the in-app assistant: macOS asks before the
    /// countdown, not while the recording runs; then they record as before,
    /// whatever the answer.
    private static func microphoneForThePersonsRecord() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, capture, microphone) = (fixture.model, fixture.capture, fixture.microphone)
        try model.captureEngine.registerAreaTarget(soundArea)
        model.destination = .recorder
        model.selectToolbarTarget(soundArea)
        model.recordMicrophone = true

        for granted in [true, false] {
            microphone.status = .notDetermined
            let startsBefore = capture.starts.count
            let requestsBefore = microphone.requests
            model.startRecordingCountdown()
            try await waitUntil("macOS's dialog for the person's Record") { microphone.heldCount == 1 }
            try expect(model.isWaitingForMicrophoneAccess && model.destination == .recorder && model.recordingPhase == .idle && capture.starts.count == startsBefore,
                       "No countdown while macOS asks")
            model.startRecordingCountdown()
            try expect(microphone.requests == requestsBefore + 1, "Record again while macOS asks does nothing more")
            microphone.answer(granted)
            try await waitUntil("The countdown after macOS's answer") { model.recordingPhase == .countdown }
            try await fixture.runCountdown()
            try await waitUntil("The capture after the countdown") { capture.starts.count == startsBefore + 1 }
            try expect(capture.starts.last?.options.microphone == true && !model.isWaitingForMicrophoneAccess,
                       "The person's recording records as they chose, as before (macOS answered \(granted ? "Allow" : "Don't Allow"))")
            await model.stopRecording()
            model.destination = .recorder
            model.selectToolbarTarget(soundArea)
        }
        // Decided already: the countdown starts at once.
        let requestsBefore = microphone.requests
        model.startRecordingCountdown()
        try expect(model.destination == .countdown && microphone.requests == requestsBefore, "Denied before: the countdown starts at once, as before")
        model.cancelRecordingCountdown()
        // Leaving the recorder while macOS asks: its answer starts nothing.
        microphone.status = .notDetermined
        model.startRecordingCountdown()
        try await waitUntil("macOS's dialog") { microphone.heldCount == 1 }
        model.destination = .library
        microphone.answer(true)
        try await waitUntil("The Record to stop waiting") { !model.isWaitingForMicrophoneAccess }
        try await settle()
        try expect(model.destination == .library && model.recordingPhase == .idle, "Nothing counts down once the person has left the recorder")
        model.recordMicrophone = false

        // The in-app assistant: macOS asks before its countdown too, then it
        // records as the person asked, whatever the answer.
        microphone.status = .notDetermined
        let inApp = model.assistantSession.context
        let inAppTool = try unwrap(AIAssistantToolCatalog.standard.first { $0.name == "start_recording" }, "The in-app assistant has start_recording")
        let startsBefore = capture.starts.count
        let done = TestBox(false)
        let call = Task { @MainActor in
            defer { done.value = true }
            return try await inAppTool.run(arguments: ["source": soundArea.id, "microphone": true], context: inApp, progress: { _ in })
        }
        try await waitUntil("macOS's dialog for the in-app assistant") { microphone.heldCount == 1 }
        try await Task.sleep(for: .milliseconds(200))
        try expect(model.recordingPhase == .idle && capture.starts.count == startsBefore && !done.value, "No countdown while macOS asks")
        microphone.answer(false)
        try await waitUntil("The in-app countdown") { done.value || model.recordingPhase == .countdown }
        try await fixture.runCountdown()
        _ = try await call.value
        try expect(capture.starts.last?.options.microphone == true, "The in-app assistant records as asked")
        await model.stopRecording()
    }

    /// While the person's Record waits for macOS's microphone dialog, the
    /// recorder's source is theirs: an AI tool's start_recording (even one
    /// that records no sound, so it asks nothing itself), the in-app start
    /// and every call that would leave the recorder are refused before
    /// anything changes, also when the call passed its first check before
    /// the person clicked Record. Once the person answers, their Record
    /// records the source they chose; a Record whose source changed while
    /// macOS asked records nothing.
    private static func automationWaitsForThePersonsRecord() async throws {
        let fixture = try await SessionFixture()
        defer { fixture.cleanup() }
        let (model, capture, microphone) = (fixture.model, fixture.capture, fixture.microphone)
        // The AI tool's source: the one the engine lists.
        try model.captureEngine.registerAreaTarget(soundArea)
        let project = RecordingProject(title: "Edited later", sourceVideoPath: "raw.mp4", duration: 3, sourceWidth: 64, sourceHeight: 64)
        try await fixture.store.save(project)
        model.projects = [project]
        let prompter = ScriptedSoundPrompter()
        let bridge = AutomationBridge(model: model)
        bridge.audioConsent = AutomationAudioConsentController(timeout: 5, heartbeatInterval: 0.05) { await prompter.prompt($0) }
        let windowRequests = TestBox(0)
        bridge.presentWindow = { windowRequests.value += 1 }

        // The person's source: an area they drew.
        let personArea = CaptureTargetInfo(id: "area-1-person", kind: .area, nativeID: CGMainDisplayID(), title: "Person's area", frame: CaptureRect(x: 0, y: 0, width: 48, height: 48))
        model.drawRecordingArea = { _, _ in personArea }
        model.destination = .recorder
        await model.beginAreaSelection(on: fixture.target)
        try expect(model.selectedTargetID == personArea.id && model.recordingSourceKind == .area, "The person's area is selected")
        model.recordMicrophone = true
        microphone.status = .notDetermined
        model.startRecordingCountdown()
        try await waitUntil("macOS's dialog for the person's Record") { microphone.heldCount == 1 }
        try expect(model.isWaitingForMicrophoneAccess && model.recordingPhase == .idle, "The person's Record waits for macOS")
        let refusal = StudioModel.waitingForMicrophoneRefusal
        func unchanged(_ what: String) throws {
            try expect(model.selectedTargetID == personArea.id && model.recordingSourceKind == .area && model.destination == .recorder
                       && model.recordingSession == nil && capture.starts.isEmpty && model.isWaitingForMicrophoneAccess
                       && microphone.requests == 1 && windowRequests.value == 0 && model.projects.map(\.id) == [project.id] && model.activeProject == nil,
                       "\(what) changed nothing: \(String(describing: model.selectedTargetID)), \(model.recordingSourceKind), \(model.destination)")
        }

        // start_recording without sound: no prompt of its own, refused at once.
        let refusedStart = try await fixture.fail(bridge, "start_recording", ["source": soundArea.id, "microphone": false])
        try expect(refusedStart == refusal && prompter.requests.isEmpty, "start_recording is refused while the person's Record waits: \(refusedStart)")
        try unchanged("start_recording")
        // Calls that would leave the recorder.
        let refusedDelete = try await fixture.fail(bridge, "delete_project", ["project_id": project.id.uuidString])
        try expect(refusedDelete == refusal, "delete_project is refused: \(refusedDelete)")
        let zoom: [String: Any] = ["project_id": project.id.uuidString, "start": 0.1, "end": 0.8, "x": 0.5, "y": 0.5]
        let refusedEdit = try await fixture.fail(bridge, "add_zoom", zoom)
        try expect(refusedEdit == refusal, "An edit does not open the editor: \(refusedEdit)")
        try unchanged("delete_project and add_zoom")
        // The same checks past the bridge's first one (a call that arrived
        // before the person clicked Record), and the in-app start.
        for (what, attempt) in [
            ("The library for a delete", { try model.showLibraryForProjectManagement() }),
            ("Opening the project", { try model.openProjectForAutomation(id: project.id) }),
            ("The in-app start", { _ = try model.startRecording(target: soundArea, options: AIRecordingOptions()) }),
        ] as [(String, () throws -> Void)] {
            do {
                try attempt()
                throw SessionFailure("\(what) must be refused while the person's Record waits")
            } catch let error as AIToolError {
                try expect(error.localizedDescription == refusal, "\(what) says why: \(error.localizedDescription)")
            }
            try unchanged(what)
        }

        microphone.answer(true)
        try await waitUntil("The person's countdown after macOS's answer") { model.recordingPhase == .countdown }
        try await fixture.runCountdown()
        try await waitUntil("The person's capture") { capture.starts.count == 1 }
        try expect(capture.starts.last?.target.id == personArea.id && capture.starts.last?.options.microphone == true,
                   "The person's Record records the area they chose: \(String(describing: capture.starts.last?.target.id))")
        await model.stopRecording()

        // A call already at its sound prompt when the person clicks Record:
        // the person's answer to the prompt no longer lets it start.
        model.destination = .recorder
        await model.beginAreaSelection(on: fixture.target)
        prompter.mode = .hold
        microphone.status = .notDetermined
        let prompted = Task { @MainActor in
            await bridge.call(toolName: "start_recording", arguments: ["source": soundArea.id, "system_audio": true, "microphone": false],
                              workingDirectory: nil, clientName: "Claude Code", progress: nil)
        }
        try await waitUntil("The sound prompt") { prompter.heldCount == 1 }
        model.startRecordingCountdown()
        try await waitUntil("macOS's dialog for the person's Record") { microphone.heldCount == 1 }
        prompter.release(.allow)
        let afterPrompt = try result(await prompted.value, "allowed at the prompt while the person's Record waits")
        try expect(afterPrompt.isError && afterPrompt.text == refusal && model.selectedTargetID == personArea.id && model.isWaitingForMicrophoneAccess && capture.starts.count == 1,
                   "Refused after the prompt, nothing changed: \(afterPrompt.json)")
        microphone.answer(false)
        try await waitUntil("The person's countdown") { model.recordingPhase == .countdown }
        try await fixture.runCountdown()
        try await waitUntil("The person's capture") { capture.starts.count == 2 }
        try expect(capture.starts.last?.target.id == personArea.id && capture.starts.last?.options.systemAudio == false, "The person's own Record, as they chose it")
        await model.stopRecording()

        // Whatever changed the source while macOS asked, the Record never
        // records a source the person did not click Record for.
        model.destination = .recorder
        await model.beginAreaSelection(on: fixture.target)
        microphone.status = .notDetermined
        model.startRecordingCountdown()
        try await waitUntil("macOS's dialog") { microphone.heldCount == 1 }
        model.selectedTargetID = soundArea.id
        microphone.answer(true)
        try await waitUntil("The Record to stop waiting") { !model.isWaitingForMicrophoneAccess }
        try await settle()
        try expect(model.recordingPhase == .idle && model.destination == .recorder && capture.starts.count == 2, "No countdown for a source the person did not click Record for")
        model.recordMicrophone = false
    }

    /// The control bar's Start, clicked in another app, brings Focus Studio
    /// forward only when the interaction-tracking alert is up once
    /// startRecordingCountdown returns. With macOS never asked about the
    /// microphone, that alert still comes first, before macOS's dialog; its
    /// Record with limited tracking then has macOS ask, then counts down.
    private static func trackingAlertBeforeTheMicrophone() async throws {
        let fixture = try await SessionFixture(interactionTracking: false)
        defer { fixture.cleanup() }
        let (model, capture, microphone) = (fixture.model, fixture.capture, fixture.microphone)
        try model.captureEngine.registerAreaTarget(soundArea)
        model.destination = .recorder
        model.selectToolbarTarget(soundArea)
        model.recordMicrophone = true
        try expect(model.automaticZooms, "Automatic zooms are on (the default)")
        microphone.status = .notDetermined

        model.startRecordingCountdown()
        try expect(model.isShowingInteractionSetup && !model.isWaitingForMicrophoneAccess, "The tracking alert is up when Record returns (the control bar then brings Focus Studio forward)")
        try await settle()
        try expect(microphone.requests == 0 && model.recordingPhase == .idle && model.destination == .recorder, "macOS is not asked before the person answers the tracking alert")

        // Record with limited tracking (the alert's button).
        model.isShowingInteractionSetup = false
        model.startRecordingCountdown(allowUnavailableTracking: true)
        try await waitUntil("macOS's dialog after the tracking alert") { microphone.heldCount == 1 }
        try expect(!model.isShowingInteractionSetup && model.recordingPhase == .idle, "No alert and no countdown while macOS asks")
        microphone.answer(true)
        try await waitUntil("The countdown after macOS's answer") { model.recordingPhase == .countdown }
        try expect(!model.isShowingInteractionSetup, "No second tracking alert")
        try await fixture.runCountdown()
        try await waitUntil("The capture") { capture.starts.count == 1 }
        try expect(capture.starts.last?.options.microphone == true, "Recorded with the microphone and limited tracking")
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

/// Stands in for macOS's microphone permission: its status, and its dialog,
/// held until the test answers it (the answer becomes the status, as in
/// macOS). Nothing here reaches the real permission or shows a dialog.
@MainActor
final class ScriptedMicrophone {
    var status: MicrophoneAuthorization = .authorized
    /// Times macOS was asked (its dialog shown).
    private(set) var requests = 0
    private var held: [CheckedContinuation<Bool, Never>] = []

    /// Dialogs up now.
    var heldCount: Int { held.count }

    func request() async -> Bool {
        requests += 1
        return await withCheckedContinuation { held.append($0) }
    }

    /// Answers the dialog: allowed or Don't Allow, and the status macOS then
    /// reports (by default authorized or denied).
    func answer(_ granted: Bool, status: MicrophoneAuthorization? = nil) {
        self.status = status ?? (granted ? .authorized : .denied)
        let waiting = held
        held = []
        waiting.forEach { $0.resume(returning: granted) }
    }

    func controller(timeout: TimeInterval = 5, heartbeatInterval: TimeInterval = 0.05) -> MicrophoneAccessController {
        MicrophoneAccessController(timeout: timeout, heartbeatInterval: heartbeatInterval, status: { self.status }, request: { await self.request() })
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
    /// Captures stopped and thrown away: a start that lost its race with a
    /// cancel (deleted), or Cancel and a discarded live recording (Trash).
    private(set) var cancels = 0
    /// The capture's active intervals on the manual clock, as the engine
    /// keeps them: anchored at the first frame, closed by a pause, reopened
    /// at a resume's first frame `resumeDelay` later.
    private(set) var intervals = RecordingPauseClock()
    let resumeDelay: TimeInterval = 0.25
    private(set) var pauses = 0
    private(set) var resumes = 0
    /// Holds a pause's flush until cleared: like the engine, the pause closes
    /// the capture's interval at once and returns once what was recorded
    /// has been written.
    var holdPause = false

    init(clock: ManualRecordingClock, clip: URL) {
        self.clock = clock
        self.clip = clip
    }

    func start(target: CaptureTargetInfo, options: CaptureOptions) async throws -> TimeInterval {
        if let startError { throw startError }
        starts.append((target, options))
        if holdStart { await withCheckedContinuation { startGate = $0 } }
        clock.advance(by: startupDelay)
        intervals = RecordingPauseClock()
        intervals.anchor(at: clock.now)
        return clock.now
    }

    func cancel() { cancels += 1 }

    var pauseControl: CapturePauseControl {
        CapturePauseControl(
            pause: { _ in
                self.pauses += 1
                self.intervals.pause(at: self.clock.now)
                while self.holdPause { try await Task.sleep(for: .milliseconds(5)) }
            },
            resume: { _ in
                self.resumes += 1
                self.clock.advance(by: self.resumeDelay)
                self.intervals.anchor(at: self.clock.now)
            },
            intervals: { _ in self.intervals }
        )
    }

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
    /// macOS's microphone permission, allowed unless a test says otherwise.
    let microphone: ScriptedMicrophone
    let model: StudioModel
    let target = CaptureTargetInfo(id: "display-1", kind: .display, nativeID: 1, title: "Test display", frame: CaptureRect(x: 0, y: 0, width: 64, height: 64))

    /// `microphoneTimeout`: how long an AI tool's call waits for macOS's
    /// microphone dialog. `interactionTracking`: whether Accessibility is
    /// allowed (Input Monitoring always is).
    init(microphoneTimeout: TimeInterval = 5, interactionTracking: Bool = true) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FocusStudio-Session-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(projectsDirectory: root.appendingPathComponent("Projects", isDirectory: true))
        let clip = try await Self.makeClip(in: root)
        let capture = ScriptedCapture(clock: clock, clip: clip)
        self.capture = capture
        let microphone = ScriptedMicrophone()
        self.microphone = microphone
        model = StudioModel(
            store: store,
            interactionTrackingAccess: { interactionTracking },
            inputMonitoringAccess: { true },
            screenCaptureAccess: { true },
            finishCapture: { _ in try await capture.finish() },
            startCapture: { _, target, _, options in try await capture.start(target: target, options: options) },
            cancelCapture: { _ in capture.cancel() },
            discardCapture: { _ in
                capture.cancel()
                return .trashed
            },
            pauseCapture: capture.pauseControl,
            recordingClock: clock.clock,
            microphoneAccess: microphone.controller(timeout: microphoneTimeout)
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
