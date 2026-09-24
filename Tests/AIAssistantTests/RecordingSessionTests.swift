import FocusStudioCore
import Foundation

/// Recording sessions against the fake app: start_recording returns once the
/// recording is live (with started_at, duration and auto_stop_at), its options
/// apply to that recording only, a duration stops the recording by itself
/// through the joined stop while an earlier Finish or stop_recording cancels
/// it, wait_for_recording reports finished (with progress), cancelled, a
/// timeout while still recording, a failed save and idle, stop_recording and
/// wait_for_recording share one outcome, and a start_recording cancelled
/// during the countdown discards it, also through the job layer MCP calls run
/// in; so does one that timed out or was cancelled as it went live. A wait on
/// a recording without a followed attempt (the Codex Director) waits through
/// its save. The in-app assistant replies after the start and stops when the
/// user says so, unless the recording has a duration. An external start that
/// turns on sound the recorder leaves off asks the person first (allow,
/// record without sound, which records no sound at all, cancel, no answer, a
/// refusal meanwhile, a cancelled call), never for sound the recorder records
/// anyway, for no sound, or for the in-app assistant; a sound the call asks
/// for that the person was not asked about records only while the recorder
/// still records it at the start (turned off during the prompt, it stays
/// off); the recorder's own choices never change. Durations
/// are the shortest the tools accept (1 s) with generous deadlines.
extension AIAssistantTests {
    @MainActor
    static func recordingSessions(root: URL) async throws {
        try await startReturnsOnceLive(root: root)
        try await durationStopsByItself(root: root)
        try await earlyFinishCancelsTheTimer(root: root)
        try await waitReportsCancelAndFailure(root: root)
        try await waitTimesOutWhileRecording(root: root)
        try await cancelledStartDiscards(root: root)
        try await startTimeoutDiscards(root: root)
        try await cancelAsItGoesLiveDiscards(root: root)
        try await untrackedRecordingWaitsThroughItsSave(root: root)
        try await soundConsent(root: root)
    }

    static func date(_ value: AIJSONValue?) -> Date? {
        value?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// start_recording answers while the recording runs, with this
    /// recording's options only; the recorder's own choices never change.
    @MainActor
    private static func startReturnsOnceLive(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)
        var external = context
        external.isExternal = true
        // The recorder leaves sound off, so the person is asked; here they allow it.
        let consent = ConsentProbe(answer: .allowed)
        external.recordingAudioConsent = consent.handler
        let preferences = app.recorderPreferences
        let arguments: [String: Any] = ["source": "display", "system_audio": true, "microphone": true, "automatic_zooms": false,
                                        "browser_content_only": false, "frame_rate": 30, "duration": 30]
        let result = try await StartRecordingTool(startTimeout: 5).run(arguments: arguments, context: external, progress: { _ in })
        check(consent.requests == [AIRecordingAudioConsentRequest(audio: AIRecordingAudio(microphone: true, systemAudio: true), sourceName: "Built-in Display")],
              "the person is asked once about both, naming the source: \(consent.requests)")
        let data = try structured(result, "start_recording with a duration")
        check(app.recordingPhase == .recording && data["state"] == "recording" && data["source"]?["id"] == "display-1", "the call returns while recording: \(data)")
        guard let started = date(data["started_at"]), let stops = date(data["auto_stop_at"]) else { fatalError("FAIL: started_at and auto_stop_at are ISO 8601 dates: \(data)") }
        check(data["duration"] == 30 && abs(stops.timeIntervalSince(started) - 30) < 1 && abs(started.timeIntervalSinceNow) < 5, "the automatic stop is 30 s after the real start: \(data)")
        check(result.text.contains("stops by itself once 30.0 s are recorded") && result.text.contains("paused time does not count") && result.text.contains("wait_for_recording") && result.text.contains("cancel")
              && result.text.contains("operate the recorded app yourself") && result.text.contains("bottom centre"), "the text says what happens next: \(result.text)")
        check(app.attemptSettings.last == AIRecordingOptions(systemAudio: true, microphone: true, automaticZooms: false, browserContentOnly: false, frameRate: 30, duration: 30),
              "the recording uses the call's options: \(app.attemptSettings)")
        check(app.recorderPreferences == preferences, "the recorder's own choices are untouched: \(app.recorderPreferences)")
        check(app.recordingSession?.duration == 30 && app.recordingSession?.outcome == nil && app.hasPendingAutomaticStop, "the attempt waits for its duration")

        // stop_recording stops now even with the duration still running, and ends that wait.
        let stopped = try structured(try await StopRecordingTool(stopTimeout: 5).run(arguments: [:], context: context, progress: { _ in }), "stop_recording before the duration")
        check(stopped["state"] == "finished" && stopped["project_id"]?.stringValue == app.projects.first?.id.uuidString, "stop returns the project: \(stopped)")
        check(!app.hasPendingAutomaticStop && app.automaticStopCount == 0 && app.finalizeCount == 1, "the automatic stop is cancelled by the stop")

        // A later recording without options records with the recorder's
        // choices; the in-app assistant is told the user performs the demo,
        // to reply now and stop when the user says they are done (a wait
        // would keep the chat busy for the whole demo).
        let inApp = try await StartRecordingTool(startTimeout: 5).run(arguments: ["source": "display"], context: context, progress: { _ in })
        check(inApp.text.contains("performs the demo now") && inApp.text.contains("Reply to the user now") && inApp.text.contains("stop_recording")
              && !inApp.text.contains("wait_for_recording") && !inApp.text.contains("yourself"), "the in-app text: \(inApp.text)")
        check(app.attemptSettings.last == preferences && app.recordingSession?.duration == nil && !app.hasPendingAutomaticStop, "no overrides and no duration are left over: \(app.attemptSettings)")
        await app.stopRecording()
        // With a duration the in-app assistant waits for it.
        let timed = try await StartRecordingTool(startTimeout: 5).run(arguments: ["source": "display", "duration": 30], context: context, progress: { _ in })
        check(timed.text.contains("call wait_for_recording") && !timed.text.contains("Reply to the user now") && !timed.text.contains("yourself"), "the in-app text with a duration: \(timed.text)")
        await app.stopRecording()

        for bad in [0, 0.5, 601, -5, "soon"] as [Any] {
            await expectToolError("duration \(bad)", { _ = try await StartRecordingTool(startTimeout: 1).run(arguments: ["source": "display", "duration": bad], context: context, progress: { _ in }) }) {
                if case let .invalidArgument(message) = $0 { return message.contains("\"duration\" must be a number of seconds from 1 to 600") } else { return false }
            }
        }
        check(app.startedSourceIDs.count == 3, "a bad duration never reaches the app")
    }

    // MARK: - Sound consent

    /// Answers the sound prompt from the test: a fixed answer, or (with
    /// `hold`) waits until the calling task is cancelled. `meanwhile` runs on
    /// the main actor while the prompt is up, before the answer (the person
    /// changing their recorder settings, say).
    final class ConsentProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [AIRecordingAudioConsentRequest] = []
        private var progressHandlers = 0
        let answer: AIRecordingAudioConsent
        let hold: Bool
        let meanwhile: (@MainActor @Sendable () -> Void)?

        init(answer: AIRecordingAudioConsent, hold: Bool = false, meanwhile: (@MainActor @Sendable () -> Void)? = nil) {
            self.answer = answer
            self.hold = hold
            self.meanwhile = meanwhile
        }

        var requests: [AIRecordingAudioConsentRequest] { lock.withLock { asked } }
        var withProgress: Int { lock.withLock { progressHandlers } }

        var handler: AIRecordingAudioConsentHandler {
            { [self] request, progress in
                lock.withLock {
                    asked.append(request)
                    if progress != nil { progressHandlers += 1 }
                }
                progress?(0.01, nil, "Waiting for the person to answer Focus Studio's sound prompt…")
                if let meanwhile { await meanwhile() }
                if hold {
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
                    return .declined
                }
                return answer
            }
        }
    }

    /// An external start_recording that turns on sound the person's recorder
    /// settings leave off asks the person before the countdown, and does what
    /// they answer; nothing else asks, and the recorder's own choices never change.
    @MainActor
    private static func soundConsent(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)
        var external = context
        external.isExternal = true
        let preferences = app.recorderPreferences
        check(app.recorderAudio == AIRecordingAudio(), "the recorder records no sound")
        func start(_ arguments: [String: Any], _ consent: ConsentProbe?, in base: AIAssistantContext? = nil) async throws -> AIToolResult {
            var call = base ?? external
            call.recordingAudioConsent = consent?.handler
            return try await StartRecordingTool(startTimeout: 5).run(arguments: arguments, context: call, progress: { _ in })
        }

        // Allow: recorded as asked; the result names the answer.
        let allowing = ConsentProbe(answer: .allowed)
        let measured = ProgressLog()
        var withProgress = external
        withProgress.numericProgress = { measured.record($0, $1, $2) }
        let allowed = try await start(["source": "Safari", "microphone": true], allowing, in: withProgress)
        let allowedData = try structured(allowed, "allowed")
        check(allowing.requests == [AIRecordingAudioConsentRequest(audio: AIRecordingAudio(microphone: true), sourceName: "Safari — Focus Studio — Docs")] && allowing.withProgress == 1,
              "asked about the microphone only, with the window's name and the call's progress: \(allowing.requests)")
        check(measured.values.first?.message?.contains("sound prompt") == true, "the prompt's heartbeat reaches the call's progress: \(measured.values)")
        check(app.attemptSettings.last?.microphone == true && app.attemptSettings.last?.systemAudio == false, "the recording records the microphone: \(app.attemptSettings)")
        check(allowedData["audio_consent"] == ["asked": ["microphone"], "answer": "allowed"] && allowedData["options"]?["microphone"] == true,
              "the result says the person allowed it: \(allowedData)")
        check(allowed.text.contains("they allowed the microphone for this recording"), "and the text: \(allowed.text)")
        check(app.recorderPreferences == preferences, "the recorder is unchanged after allow")
        await app.stopRecording()

        // Record without sound: the recording starts with that sound off, and the model is told.
        let silent = ConsentProbe(answer: .withoutSound)
        let withoutSound = try await start(["source": "display", "microphone": true, "system_audio": true, "frame_rate": 30], silent)
        let silentData = try structured(withoutSound, "without sound")
        check(silent.requests.map(\.audio) == [AIRecordingAudio(microphone: true, systemAudio: true)], "asked about both")
        check(app.attemptSettings.last?.microphone == false && app.attemptSettings.last?.systemAudio == false && app.attemptSettings.last?.frameRate == 30,
              "recorded without sound, the other options kept: \(app.attemptSettings)")
        check(app.startedOptions.last?.microphone == false && app.startedOptions.last?.systemAudio == false, "the app was asked for no sound")
        check(silentData["audio_consent"] == ["asked": ["microphone", "system_audio"], "answer": "without_sound"]
              && silentData["options"]?["microphone"] == false && silentData["options"]?["system_audio"] == false && silentData["state"] == "recording",
              "the structured result says so: \(silentData)")
        check(withoutSound.text.contains("chose to record without sound") && withoutSound.text.contains("no sound at all") && withoutSound.text.contains("microphone off")
              && withoutSound.text.contains("Do not turn sound on again"), "and the text: \(withoutSound.text)")
        check(app.recorderPreferences == preferences, "the recorder is unchanged after record without sound")
        await app.stopRecording()

        // Cancel recording, no answer in time, and a refusal meanwhile: nothing starts.
        let started = app.startedSourceIDs.count
        for (answer, expected) in [(AIRecordingAudioConsent.declined, "they chose Cancel recording"), (.timedOut(60), "nobody answered within 60 seconds"),
                                   (.refused("The person revoked Codex's access to Focus Studio."), "revoked Codex's access")] {
            let probe = ConsentProbe(answer: answer)
            await expectToolError("answer \(answer)", { _ = try await start(["source": "display", "system_audio": true], probe) }) {
                guard case let .failed(message) = $0, message.contains(expected) else { return false }
                if case .refused = answer { return true }
                return message.contains("did not allow sound") && message.contains("nothing was recorded")
            }
            check(probe.requests.count == 1 && app.startedSourceIDs.count == started && app.recordingPhase == .idle, "\(answer): asked once, nothing started")
            check(app.recorderPreferences == preferences, "\(answer): the recorder is unchanged")
        }

        // A call cancelled while the prompt is up records nothing.
        let holding = ConsentProbe(answer: .allowed, hold: true)
        let pending = Task { @MainActor in try await start(["source": "display", "microphone": true], holding) }
        try await waitUntil("the held prompt") { !holding.requests.isEmpty }
        pending.cancel()
        do {
            _ = try await pending.value
            fatalError("FAIL: a start cancelled during the prompt must not record")
        } catch is CancellationError {
        } catch {
            fatalError("FAIL: a start cancelled during the prompt throws CancellationError, got \(error)")
        }
        check(app.startedSourceIDs.count == started && app.recordingPhase == .idle, "nothing started after the cancelled prompt")

        // No way to ask: refused, never recorded unasked.
        await expectToolError("no prompt available", { _ = try await start(["source": "display", "microphone": true], nil) }) {
            if case let .failed(message) = $0 { return message.contains("could not ask the person") && message.contains("microphone and system_audio false") } else { return false }
        }
        check(app.startedSourceIDs.count == started, "nothing started without a prompt")

        // No prompt: no sound asked for, sound turned off, or sound the recorder records anyway.
        let never = ConsentProbe(answer: .declined)
        _ = try await start(["source": "display"], never)
        await app.stopRecording()
        _ = try await start(["source": "display", "microphone": false, "system_audio": false], never)
        await app.stopRecording()
        app.recorderPreferences.systemAudio = true
        let recorderSound = try structured(try await start(["source": "display", "system_audio": true], never), "sound the recorder records")
        check(recorderSound["audio_consent"] == nil && app.attemptSettings.last?.systemAudio == true, "no consent needed for the recorder's own sound: \(recorderSound)")
        await app.stopRecording()
        // Only the added sound is asked about; Record without sound then
        // records no sound at all, the recorder's own included, as the
        // prompt says ("records the screen only").
        for arguments in [["source": "display", "system_audio": true, "microphone": true], ["source": "display", "microphone": true]] as [[String: Any]] {
            let added = ConsentProbe(answer: .withoutSound)
            let addedData = try structured(try await start(arguments, added), "mixed \(arguments.keys.sorted())")
            check(added.requests.map(\.audio) == [AIRecordingAudio(microphone: true)] && app.attemptSettings.last?.systemAudio == false && app.attemptSettings.last?.microphone == false,
                  "only the microphone is asked about, and nothing is recorded with Record without sound: \(app.attemptSettings.last.map { "\($0)" } ?? "none")")
            check(addedData["audio_consent"] == ["asked": ["microphone"], "answer": "without_sound"] && addedData["options"]?["microphone"] == false && addedData["options"]?["system_audio"] == false,
                  "the result names the microphone and reports no sound: \(addedData)")
            await app.stopRecording()
        }
        check(app.recorderPreferences.systemAudio == true, "the recorder keeps its system audio")
        app.recorderPreferences.systemAudio = false

        // The person turns a recorder sound off while the prompt is up: a
        // sound the call asked for but the prompt did not (the recorder had
        // it on) follows the recorder as it is at the start, so it is off,
        // whatever the answer; the result says so.
        for answer in [AIRecordingAudioConsent.allowed, .withoutSound] {
            app.recorderPreferences.microphone = true
            let turnedOff = ConsentProbe(answer: answer, meanwhile: { app.recorderPreferences.microphone = false })
            let changed = try await start(["source": "display", "microphone": true, "system_audio": true], turnedOff)
            let changedData = try structured(changed, "recorder changed during the prompt, \(answer)")
            check(turnedOff.requests.map(\.audio) == [AIRecordingAudio(systemAudio: true)], "\(answer): asked about system audio only: \(turnedOff.requests)")
            check(app.attemptSettings.last?.microphone == false && app.attemptSettings.last?.systemAudio == (answer == .allowed),
                  "\(answer): the microphone the person turned off is not recorded: \(app.attemptSettings.last.map { "\($0)" } ?? "none")")
            check(changedData["options"]?["microphone"] == false && changedData["options"]?["system_audio"] == AIJSONValue(answer == .allowed), "\(answer): options say what records: \(changedData)")
            if answer == .allowed {
                check(changed.text.contains("The microphone is off for this recording") && changed.text.contains("turned it off in their recorder settings"), "\(answer): the text says why: \(changed.text)")
            }
            check(app.recorderPreferences.microphone == false, "\(answer): the person's own change stands")
            await app.stopRecording()
        }
        // And a sound the recorder records, turned off before a start that asks nothing.
        app.recorderPreferences.microphone = true
        let unasked = ConsentProbe(answer: .declined)
        let quiet = try await start(["source": "display", "microphone": true], unasked)
        check(unasked.requests.isEmpty && app.attemptSettings.last?.microphone == true, "the recorder's own microphone records without asking: \(quiet.text)")
        await app.stopRecording()
        app.recorderPreferences.microphone = false
        check(StartRecordingTool.withoutUnallowedSound(AIRecordingOptions(systemAudio: true, microphone: true), allowed: AIRecordingAudio(), recorder: AIRecordingAudio(microphone: true))
              == (AIRecordingOptions(systemAudio: false, microphone: true), AIRecordingAudio(systemAudio: true)), "a sound neither allowed nor recorded by the recorder is left off")

        // The in-app assistant: the person drives it, so it never asks.
        _ = try await start(["source": "display", "microphone": true, "system_audio": true], never, in: context)
        check(app.attemptSettings.last?.microphone == true && app.attemptSettings.last?.systemAudio == true, "the in-app assistant records as asked")
        await app.stopRecording()
        check(never.requests.isEmpty, "none of these asked the person: \(never.requests)")
        check(app.recorderPreferences == preferences, "the recorder's own choices never changed: \(app.recorderPreferences)")
    }

    /// A duration stops the recording by itself, through the same joined
    /// stop as the Finish button; wait_for_recording collects the project.
    @MainActor
    private static func durationStopsByItself(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)
        app.stopBehaviour = .succeed(after: 0.05)
        let data = try structured(try await StartRecordingTool(startTimeout: 5).run(arguments: ["source": "Safari", "duration": 1], context: context, progress: { _ in }), "start_recording for 1 s")
        check(data["duration"] == 1 && app.recordingPhase == .recording, "live, not over: \(data)")

        let progress = ProgressLog()
        var waiting = context
        waiting.numericProgress = { progress.record($0, $1, $2) }
        let waited = try structured(try await WaitForRecordingTool(progressInterval: 0.2).run(arguments: ["timeout_seconds": 20], context: waiting, progress: { _ in }), "wait_for_recording until the duration")
        let project = app.projects[0]
        check(waited["state"] == "finished" && waited["project_id"]?.stringValue == project.id.uuidString && waited["open_in_editor"] == true && waited["duration"] == 12, "the saved project comes back: \(waited)")
        check(app.automaticStopCount == 1 && app.finalizeCount == 1 && app.stopRequests == 1 && app.recordingSession?.outcome == .finished(projectID: project.id), "the duration stopped it once")
        let values = progress.values
        check(values.count >= 2 && zip(values, values.dropFirst()).allSatisfy { $0.completed < $1.completed } && values.allSatisfy { $0.total == 20 }, "progress while waiting, increasing: \(values.map(\.completed))")

        // Nothing records any more: idle, with how the last recording ended.
        let idle = try structured(try await WaitForRecordingTool().run(arguments: [:], context: context, progress: { _ in }), "wait_for_recording with nothing recording")
        check(idle["state"] == "idle" && idle["message"]?.stringValue?.contains("Nothing is recording") == true && idle["last_recording"]?["state"] == "finished"
              && idle["last_recording"]?["project_id"]?.stringValue == project.id.uuidString, "idle names the last recording: \(idle)")
        await expectToolError("stop after the duration", { _ = try await StopRecordingTool(stopTimeout: 1).run(arguments: [:], context: context, progress: { _ in }) }) {
            if case let .failed(message) = $0 { return message.contains("No recording is in progress") && message.contains("saved as project") } else { return false }
        }
    }

    /// Finish before the duration: one stop, and the duration never fires later.
    @MainActor
    private static func earlyFinishCancelsTheTimer(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)
        _ = try await StartRecordingTool(startTimeout: 5).run(arguments: ["source": "display", "duration": 1], context: context, progress: { _ in })
        check(app.hasPendingAutomaticStop, "the duration is pending")
        await app.stopRecording()
        check(!app.hasPendingAutomaticStop && app.finalizeCount == 1 && app.projects.count == 1, "Finish stops at once and cancels the automatic stop")
        // Past the duration: a cancelled automatic stop has nothing to fire.
        try await Task.sleep(for: .milliseconds(1_300))
        check(app.automaticStopCount == 0 && app.finalizeCount == 1 && app.stopRequests == 1 && app.projects.count == 1, "no second stop after the duration")
    }

    /// The person's Cancel (control bar or countdown) ends a wait as cancelled;
    /// a failed save is an error; a failed capture is reported at once.
    @MainActor
    private static func waitReportsCancelAndFailure(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)
        _ = try await StartRecordingTool(startTimeout: 5).run(arguments: ["source": "display"], context: context, progress: { _ in })
        let waiting = Task { try await WaitForRecordingTool().run(arguments: ["timeout_seconds": 20], context: context, progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(150))
        app.cancelFromControlBar()
        let cancelled = try structured(try await waiting.value, "wait_for_recording after Cancel")
        check(cancelled["state"] == "cancelled" && cancelled["started_at"] != nil && app.projects.isEmpty && app.finalizeCount == 0, "a cancelled recording is reported as such: \(cancelled)")

        // Cancelled during its countdown.
        app.startBehaviour = .hang
        _ = try app.startRecording(sourceID: "display-1", options: AIRecordingOptions())
        let duringCountdown = Task { try await WaitForRecordingTool().run(arguments: ["timeout_seconds": 20], context: context, progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(150))
        app.cancelFromControlBar()
        let countdown = try structured(try await duringCountdown.value, "wait_for_recording during a cancelled countdown")
        check(countdown["state"] == "cancelled" && countdown["started_at"] == nil, "a cancelled countdown too: \(countdown)")

        // A save that fails is an error, not a project.
        app.startBehaviour = .succeed(after: 0.02)
        app.stopBehaviour = .fail("Disk full", after: 0.05)
        _ = try await StartRecordingTool(startTimeout: 5).run(arguments: ["source": "display"], context: context, progress: { _ in })
        let failing = Task { try await WaitForRecordingTool().run(arguments: ["timeout_seconds": 20], context: context, progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(100))
        await app.stopRecording()
        do {
            _ = try await failing.value
            fatalError("FAIL: a failed save must be an error")
        } catch let error as AIToolError {
            check(error == .failed("The recording could not be saved: Disk full"), "the failure is reported: \(error)")
        }

        // A capture that failed while recording is reported at once.
        app.recordingPhase = .failed("The stream stopped")
        await expectToolError("failed capture", { _ = try await WaitForRecordingTool().run(arguments: [:], context: context, progress: { _ in }) }) {
            $0 == .failed("The recording failed: The stream stopped")
        }
        app.recordingPhase = .idle
    }

    /// A wait that runs out says the recording goes on, with elapsed and
    /// remaining; stop_recording meanwhile ends it with the same project for both.
    @MainActor
    private static func waitTimesOutWhileRecording(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)
        _ = try await StartRecordingTool(startTimeout: 5).run(arguments: ["source": "display", "duration": 60], context: context, progress: { _ in })
        app.elapsed = 3.24
        let still = try structured(try await WaitForRecordingTool().run(arguments: ["timeout_seconds": 0.2], context: context, progress: { _ in }), "wait_for_recording timing out")
        let remaining = still["remaining"]?.doubleValue ?? -1
        check(still["state"] == "recording" && still["elapsed"] == 3.2 && still["waited"] == 0.2 && remaining > 50 && remaining <= 60
              && date(still["auto_stop_at"]) != nil && date(still["started_at"]) != nil, "the recording goes on: \(still)")
        let text = try await WaitForRecordingTool().run(arguments: ["timeout_seconds": 0], context: context, progress: { _ in }).text
        check(text.hasPrefix("Still recording after waiting 0.0 s (3.2 s recorded so far; it stops by itself in") && text.contains("Call wait_for_recording again"), "an immediate check: \(text)")
        for bad in [241, -1, "long"] as [Any] {
            await expectToolError("timeout \(bad)", { _ = try await WaitForRecordingTool().run(arguments: ["timeout_seconds": bad], context: context, progress: { _ in }) }) {
                if case let .invalidArgument(message) = $0 { return message.contains("from 0 to 240") } else { return false }
            }
        }

        // stop_recording while wait_for_recording waits: one stop, one project, both report it.
        app.stopBehaviour = .succeed(after: 0.2)
        let waiting = Task { try await WaitForRecordingTool().run(arguments: ["timeout_seconds": 20], context: context, progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(100))
        let stopped = try structured(try await StopRecordingTool(stopTimeout: 5).run(arguments: [:], context: context, progress: { _ in }), "stop_recording during a wait")
        let waited = try structured(try await waiting.value, "the wait the stop ended")
        check(stopped["project_id"] == waited["project_id"] && waited["state"] == "finished" && app.finalizeCount == 1 && app.projects.count == 1, "both report the one project: \(stopped) / \(waited)")
        check(!app.hasPendingAutomaticStop && app.automaticStopCount == 0, "the duration no longer applies")
    }

    /// A start_recording whose caller gives up during the countdown discards
    /// the countdown: directly, and through the job layer an MCP call runs in.
    @MainActor
    private static func cancelledStartDiscards(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)
        app.startBehaviour = .hang
        let call = Task { try await StartRecordingTool(startTimeout: 30).run(arguments: ["source": "display"], context: context, progress: { _ in }) }
        try await waitUntil("the countdown") { app.recordingPhase == .countdown }
        call.cancel()
        do {
            _ = try await call.value
            fatalError("FAIL: a cancelled start must not answer")
        } catch is CancellationError {
            // expected
        }
        guard let first = app.recordingSession else { fatalError("FAIL: the attempt exists") }
        check(app.discarded == [first.id] && first.outcome == .cancelled && app.recordingPhase == .idle, "the countdown is discarded: \(app.discarded)")

        let jobs = AutomationJobs()
        let mcpCall = Task {
            await jobs.run(tool: "start_recording", progress: nil) { _ in
                MCPToolCallResult(try await StartRecordingTool(startTimeout: 30).run(arguments: ["source": "display"], context: context, progress: { _ in }))
            }
        }
        try await waitUntil("the MCP call's countdown") { app.recordingPhase == .countdown && app.recordingSession?.id != first.id }
        mcpCall.cancel()
        let outcome = await mcpCall.value
        check(outcome == .cancelled && app.discarded.count == 2 && app.recordingSession?.outcome == .cancelled && app.recordingPhase == .idle,
              "the client's cancel discards the countdown before the call answers: \(outcome)")
        check(app.finalizeCount == 0 && app.projects.isEmpty, "nothing was recorded or saved")
    }

    /// A start that did not go live in time is discarded: it never goes live
    /// after the caller was told it did not start.
    @MainActor
    private static func startTimeoutDiscards(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)
        // The capture would go live after the call gave up on it.
        app.startBehaviour = .succeed(after: 0.5)
        await expectToolError("slow start", { _ = try await StartRecordingTool(startTimeout: 0.2).run(arguments: ["source": "display"], context: context, progress: { _ in }) }) {
            if case let .timedOut(message) = $0 { return message.contains("was cancelled") } else { return false }
        }
        guard let attempt = app.recordingSession else { fatalError("FAIL: the attempt exists") }
        check(app.discarded == [attempt.id] && attempt.outcome == .cancelled && app.recordingPhase == .idle, "the timed-out start is discarded: \(app.discarded)")
        try await Task.sleep(for: .milliseconds(700))
        check(app.recordingPhase == .idle && app.recordingSession?.startedAt == nil && app.finalizeCount == 0, "and never goes live afterwards: \(app.recordingPhase)")
    }

    /// A caller that cancels in the very poll that sees the recording live
    /// gets a cancellation, and the live recording is discarded with it.
    @MainActor
    private static func cancelAsItGoesLiveDiscards(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)
        app.startBehaviour = .hang
        let call = Task { try await StartRecordingTool(startTimeout: 30).run(arguments: ["source": "display"], context: context, progress: { _ in }) }
        try await waitUntil("the countdown") { app.recordingPhase == .countdown }
        guard let id = app.recordingSession?.id else { fatalError("FAIL: the attempt exists") }
        app.recordingSession?.startedAt = Date()
        app.recordingPhase = .recording
        // Cancel the tool's task inside its next poll, the one that sees it live.
        app.onSessionRead = {
            app.onSessionRead = nil
            withUnsafeCurrentTask { $0?.cancel() }
        }
        do {
            _ = try await call.value
            fatalError("FAIL: a start cancelled as it went live must not answer")
        } catch is CancellationError {
            // expected
        }
        check(app.discardedLive == [id] && app.recordingPhase == .idle && app.recordingSession?.outcome == .cancelled,
              "the live recording is discarded: \(app.discardedLive)")
    }

    /// A recording with no attempt to follow (a Codex Director plan) that
    /// saves for a while (stopping) is reported finished once its project
    /// opens, never cancelled meanwhile.
    @MainActor
    private static func untrackedRecordingWaitsThroughItsSave(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)
        app.recordingSession = nil
        app.recordingPhase = .recording
        let waiting = Task { try await WaitForRecordingTool().run(arguments: ["timeout_seconds": 20], context: context, progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(150))
        // Saving its capture, for longer than a few polls.
        app.recordingPhase = .stopping
        try await Task.sleep(for: .milliseconds(350))
        var project = makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 9)
        project.title = "Director demo"
        app.projects.insert(project, at: 0)
        app.openID = project.id
        app.recordingPhase = .idle
        let data = try structured(try await waiting.value, "wait_for_recording on a recording without an attempt")
        check(data["state"] == "finished" && data["project_id"]?.stringValue == project.id.uuidString, "its saved project, not a cancel: \(data)")
    }
}

// MARK: - Paused recordings

extension AIAssistantTests {
    /// The person paused the recording from its control bar: it is still
    /// recording (stop_recording works), wait_for_recording and the in-app
    /// assistant's summary say it is paused with the recorded time left, and
    /// wait_for_recording, which answers "call it again", is never stopped by
    /// the in-app replay guard, unlike an action already attempted.
    @MainActor
    static func pausedRecording(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)
        _ = try await StartRecordingTool(startTimeout: 5).run(arguments: ["source": "display", "duration": 10], context: context, progress: { _ in })
        check(app.recordingPhase == .recording, "the recording is live")
        app.elapsed = 4
        app.isRecordingPaused = true
        app.pausedRemaining = 6
        let waited = try await WaitForRecordingTool(pollInterval: 0.01).run(arguments: ["timeout_seconds": 0], context: context, progress: { _ in })
        let data = try structured(waited, "wait_for_recording while paused")
        check(data["state"] == "recording" && data["paused"] == true && data["elapsed"] == 4 && data["remaining"] == 6
              && waited.text.contains("paused by the person") && waited.text.contains("6.0 s of recording remain once they resume") && data["auto_stop_at"] == nil,
              "a wait reports the pause: \(waited.text) \(data)")
        let summary = AIAssistantSession(context: context, completion: nil, tools: []).appSummary() ?? ""
        check(summary.contains("Recording: recording (paused by the user"), "the in-app summary names the pause: \(summary)")
        app.isRecordingPaused = false
        let running = try structured(try await WaitForRecordingTool(pollInterval: 0.01).run(arguments: ["timeout_seconds": 0], context: context, progress: { _ in }), "wait_for_recording resumed")
        check(running["paused"] == false, "a resumed recording is not paused: \(running)")
        app.isRecordingPaused = true
        let stopped = try structured(try await StopRecordingTool(stopTimeout: 5).run(arguments: [:], context: context, progress: { _ in }), "stop_recording while paused")
        check(stopped["state"] == "finished", "stop_recording saves a paused recording: \(stopped)")
        app.isRecordingPaused = false

        let log = ToolLog()
        let waiter = RecordingTool(name: "wait_for_recording", summary: "wait fixture", cost: nil, log: log)
        let lister = RecordingTool(name: "list_projects", summary: "list fixture", cost: nil, log: log)
        let provider = ScriptedCompletion([
            action("wait_for_recording", "{\"timeout_seconds\": 0}"), action("wait_for_recording", "{\"timeout_seconds\": 0}"),
            action("list_projects"), action("list_projects"), reply("Done."),
        ])
        let session = AIAssistantSession(context: context, completion: provider, tools: [waiter, lister])
        session.send("Wait for the recording, then list the projects")
        try await waitUntil("the scripted turn") { !session.isRunning }
        check(log.runs.filter { $0.hasPrefix("wait_for_recording") }.count == 2 && log.runs.filter { $0.hasPrefix("list_projects") }.count == 1
              && session.messages.last?.text == "Done.",
              "wait_for_recording may wait again in one request; other repeated calls are still refused: \(log.runs)")
    }
}
