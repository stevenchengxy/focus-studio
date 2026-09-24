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
/// user says so, unless the recording has a duration. Durations are the
/// shortest the tools accept (1 s) with generous deadlines.
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
        let preferences = app.recorderPreferences
        let arguments: [String: Any] = ["source": "display", "system_audio": true, "microphone": true, "automatic_zooms": false,
                                        "browser_content_only": false, "frame_rate": 30, "duration": 30]
        let result = try await StartRecordingTool(startTimeout: 5).run(arguments: arguments, context: external, progress: { _ in })
        let data = try structured(result, "start_recording with a duration")
        check(app.recordingPhase == .recording && data["state"] == "recording" && data["source"]?["id"] == "display-1", "the call returns while recording: \(data)")
        guard let started = date(data["started_at"]), let stops = date(data["auto_stop_at"]) else { fatalError("FAIL: started_at and auto_stop_at are ISO 8601 dates: \(data)") }
        check(data["duration"] == 30 && abs(stops.timeIntervalSince(started) - 30) < 1 && abs(started.timeIntervalSinceNow) < 5, "the automatic stop is 30 s after the real start: \(data)")
        check(result.text.contains("stops by itself 30.0 s after it started") && result.text.contains("wait_for_recording") && result.text.contains("cancel")
              && result.text.contains("operate the recorded app yourself") && result.text.contains("top centre"), "the text says what happens next: \(result.text)")
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
