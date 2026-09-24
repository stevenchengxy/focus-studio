import FocusStudioAutomation
import FocusStudioCore
import Foundation

/// Runs MCP tool calls from an external client (Claude Code, Codex) inside
/// the app. It knows nothing of the transport: the control channel hands it
/// a tool name, the JSON arguments and the client's working directory, and
/// answers with what it returns. The library must be loaded (`bootstrap()`)
/// before calls arrive.
///
/// For each call it:
/// - accepts only the tools of its MCP catalog (anything else, the paid and
///   navigation tools included, is an unknown tool);
/// - takes `project_id` out of the arguments (update_settings and
///   set_zoom_style reject unknown keys) and pins the call to that project;
/// - for an editing or output tool, opens the project in the editor first,
///   saving and closing any other, so the person using the app watches each
///   change (a main window is put on screen first, without activating the
///   app, except during a countdown or a recording, when the recorded app
///   stays in front); refused while recording or busy. Every call that
///   changes what the app shows is also refused while the in-app assistant
///   is partway through a request, an export from the editor runs or a save
///   or open panel is up. Read-only tools never navigate;
/// - runs the calls that change what the app shows one at a time, in order,
///   so parallel calls never switch the editor under each other. A call
///   waits for its turn at most until its time is up (see the next point,
///   plus the jobs' short grace), with heartbeat progress meanwhile; it then
///   answers "waiting_for_turn" without running, and the model calls again;
/// - builds a fresh English tool context with the client's working directory
///   and the project's assets folder;
/// - runs the tool as a job, which answers with a running status and a
///   job_id when the call outlasts ``AutomationJobs/detachAfter`` counted
///   from its arrival (`arrivedAt`: when it reached the app, less what the
///   helper had already spent on it), the approval prompt, its wait for a
///   turn and start_recording's sound prompt and macOS microphone dialog
///   included. A tool that bounds
///   its own wait (wait_for_recording, which also never takes a turn, so
///   status reads and stop_recording go on while it waits) and wait_for_job
///   are never detached; their wait is shortened instead so that it ends
///   within ``AutomationJobs/maximumWait`` of the arrival;
/// - lets an external start_recording ask the person before it records
///   sound their recorder settings leave off (``audioConsent``, naming the
///   client and the program that started it), and checks again after the
///   answer that the call may still run;
/// - has macOS settle Focus Studio's microphone access before such a call's
///   countdown when it will record the microphone
///   (``StudioModel/microphoneAccess``), waiting at most that controller's
///   timeout for macOS's dialog (the tool refuses a microphone macOS does
///   not allow), and checks again after the person allowed it;
/// - returns MCP's result shape: text, an inline JPEG for capture_frame,
///   the structured data, and `isError` with the error's text on failure.
@MainActor
final class AutomationBridge {
    let model: StudioModel
    let catalog: MCPToolCatalog
    let jobs: AutomationJobs
    /// Turns for the calls that navigate, held until the call returns (a
    /// detached job lets the next call go while it keeps running).
    let queue = AutomationCallQueue()
    /// Puts a main window on screen, without activating the app, before a
    /// call changes what it shows, unless a countdown or a recording is
    /// under way (``MainWindowPresenter`` in the app; nil in tests).
    var presentWindow: (@MainActor () -> Void)?
    /// Asks the person before a start_recording records sound their
    /// recorder settings leave off (the app's prompt; tests pass their own).
    /// Without it such a call is refused, never recorded unasked.
    var audioConsent: AutomationAudioConsentController?
    /// How often a call waiting for its turn sends heartbeat progress.
    var turnHeartbeatInterval: TimeInterval = 5

    /// Heartbeat progress while a call waits for its turn: tiny increasing
    /// values above the approval prompt's (which a new client's first call
    /// sent before) and below the sound prompt's (which may follow inside
    /// the tool), since a call's progress must keep increasing. At most
    /// ``turnHeartbeatLimit`` beats are counted, so they stay below it.
    nonisolated static let turnHeartbeatBase = 0.005
    nonisolated static let turnHeartbeatStep = 0.00001
    nonisolated static let turnHeartbeatLimit = 450
    nonisolated static let waitingForTurnMessage = "Waiting for another AI tool call in Focus Studio to finish…"

    init(model: StudioModel, catalog: MCPToolCatalog = .v1, jobs: AutomationJobs? = nil) {
        self.model = model
        self.catalog = catalog
        self.jobs = jobs ?? AutomationJobs()
    }

    /// `progress` receives measured progress (always increasing, on any
    /// thread) until the call returns. A cancelled caller gets `.cancelled`
    /// once the tool has stopped; nothing is sent to the client then.
    /// `arrivedAt` is when the call's time started (the control server passes
    /// its arrival less the helper's own time; nil: now). `programName` is
    /// the program that started the client as the app identified it, shown
    /// in the sound prompt. `stillAllowed` is asked right before the tool
    /// runs, after any wait for a turn, and again after the person answers a
    /// sound prompt; a refusal it returns is the call's `isError` result.
    func call(
        toolName: String,
        arguments: [String: Any],
        workingDirectory: URL?,
        clientName: String?,
        programName: String? = nil,
        arrivedAt: Date? = nil,
        progress: AIToolProgressHandler?,
        stillAllowed: (@MainActor () -> String?)? = nil
    ) async -> AutomationCallResult {
        guard let spec = catalog.tool(named: toolName) else { return .unknownTool(toolName) }
        // Waits for approval and for a turn count toward the detach threshold.
        let arrived = arrivedAt ?? Date()
        if spec.name == MCPToolCatalog.waitForJobName {
            return await jobs.waitForJob(arguments: arguments, arrivedAt: arrived, progress: progress)
        }
        guard let tool = spec.tool else { return .unknownTool(toolName) }
        if spec.navigates {
            // A turn held by a call that arrived later (this one waited for
            // the person's approval meanwhile) may outlast this call's time:
            // it then answers without running, like an unanswered approval.
            switch await waitForTurn(until: arrived.addingTimeInterval(jobs.detachAfter + jobs.grace), progress: progress) {
            case .acquired: break
            case .cancelled: return .cancelled
            case .timedOut: return .result(Self.waitingForTurnResult(tool: spec.name))
            }
        }
        defer { if spec.navigates { queue.release() } }
        // AI tools may have been turned off, or the client revoked, while this call waited.
        if let refusal = stillAllowed?() { return .result(.failure(refusal)) }
        let prepared: (arguments: ToolArguments, context: AIAssistantContext)
        do {
            var toolArguments = arguments
            if !spec.detaches { Self.boundWait(&toolArguments, spec: spec, arrivedAt: arrived) }
            prepared = try prepare(spec, arguments: toolArguments, workingDirectory: workingDirectory)
        } catch {
            return .result(.failure(error))
        }
        let includesImage = spec.returnsImage
        let consent = audioConsentHandler(clientName: clientName, programName: programName, stillAllowed: stillAllowed)
        let microphone = microphoneAccessHandler(stillAllowed: stillAllowed)
        return await jobs.run(tool: spec.name, clientName: clientName, arrivedAt: arrived, detaches: spec.detaches, progress: progress) { report in
            var context = prepared.context
            context.numericProgress = report
            context.recordingAudioConsent = consent
            context.microphoneAccess = microphone
            do {
                let result = try await tool.run(arguments: prepared.arguments.values, context: context, progress: { _ in })
                return MCPToolCallResult(result, includesImage: includesImage)
            } catch {
                // A tool may wrap the cancellation it was interrupted by.
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                return .failure(error)
            }
        }
    }

    /// The person's answer to start_recording's sound prompt, through
    /// ``audioConsent``; nil (such a call is refused) without one. An answer
    /// that lets the recording go ahead is refused after all when, while the
    /// prompt was up, AI tools were turned off or the client revoked, or the
    /// app became busy in a way that refuses a call that changes what it
    /// shows (the in-app assistant working, an editor export, a dialog).
    private func audioConsentHandler(clientName: String?, programName: String?, stillAllowed: (@MainActor () -> String?)?) -> AIRecordingAudioConsentHandler? {
        guard let consent = audioConsent else { return nil }
        let client = clientName ?? "An AI tool"
        let model = self.model
        return { @MainActor request, progress in
            let answer = await consent.ask(clientName: client, programName: programName, audio: request.audio, sourceName: request.sourceName, progress: progress)
            switch answer {
            case .allowed, .withoutSound:
                if let refusal = stillAllowed?() ?? model.automationNavigationRefusal { return .refused(refusal) }
                return answer
            case .declined, .timedOut, .refused:
                return answer
            }
        }
    }

    /// macOS's answer about the microphone for an external start_recording
    /// that will record it: asked, when the person has never answered, with
    /// a wait of at most the controller's timeout (the call's time keeps
    /// running meanwhile, so a long wait detaches it as a job). A person who
    /// just allowed it lets the recording go ahead only if the call may
    /// still run, as after the sound prompt.
    private func microphoneAccessHandler(stillAllowed: (@MainActor () -> String?)?) -> AIMicrophoneAccessHandler {
        let access = model.microphoneAccess
        let model = self.model
        return { @MainActor progress in
            let answer = await access.ensure(progress: progress, timeout: access.timeout)
            guard case .authorized(askedNow: true) = answer else { return answer }
            if let refusal = stillAllowed?() ?? model.automationNavigationRefusal { return .refused(refusal) }
            return answer
        }
    }

    /// Waits for this call's turn until `deadline`, sending heartbeat
    /// progress meanwhile when the turn is taken.
    private func waitForTurn(until deadline: Date, progress: AIToolProgressHandler?) async -> AutomationCallQueue.AcquireOutcome {
        guard let progress, queue.isBusy else { return await queue.acquire(until: deadline) }
        let interval = max(0.01, turnHeartbeatInterval)
        let heartbeat = Task.detached {
            var beat = 0
            while !Task.isCancelled {
                beat = min(beat + 1, Self.turnHeartbeatLimit)
                progress(Self.turnHeartbeatBase + Double(beat) * Self.turnHeartbeatStep, nil, Self.waitingForTurnMessage)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        defer { heartbeat.cancel() }
        return await queue.acquire(until: deadline)
    }

    /// The answer for a call whose time ran out while it waited for its turn:
    /// not run, nothing changed, and calling again waits again.
    nonisolated static func waitingForTurnResult(tool: String) -> MCPToolCallResult {
        let text = "Focus Studio is still busy with another AI tool call that changes what it shows, so \(tool) has not run yet and nothing was changed. Call \(tool) again with the same arguments; it runs once that call is done."
        let data: AIJSONValue = [
            "status": "waiting_for_turn",
            "tool": AIJSONValue(tool),
            "retry": true,
        ]
        return MCPToolCallResult(content: [.text(text)], structuredContent: data, isError: true)
    }

    /// A tool that bounds its own wait (wait_for_recording) waits at most
    /// ``AutomationJobs/maximumWait`` counted from the call's arrival, so a
    /// wait for approval does not push its answer past a client's timeout:
    /// its `timeout_seconds` (or the schema's default) is shortened by the
    /// time already spent. An invalid value is left for the tool to refuse.
    private static func boundWait(_ arguments: inout [String: Any], spec: MCPToolSpec, arrivedAt: Date) {
        let spent = Date().timeIntervalSince(arrivedAt)
        guard spent >= 1, let property = spec.inputSchema["properties"]?["timeout_seconds"] else { return }
        let requested: Double
        switch arguments["timeout_seconds"] {
        case nil, is NSNull:
            guard let fallback = property["default"]?.doubleValue else { return }
            requested = fallback
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            requested = number.doubleValue
        default:
            return
        }
        // Out of range: the tool refuses it, whatever the time.
        if let minimum = property["minimum"]?.doubleValue, requested < minimum { return }
        if let maximum = property["maximum"]?.doubleValue, requested > maximum { return }
        let left = max(0, AutomationJobs.maximumWait - spent)
        if left < requested { arguments["timeout_seconds"] = left }
    }

    /// Validates `project_id`, refuses a call that would change what the app
    /// shows when now is not the time, opens the project for an editing or
    /// output tool, and returns the tool's own arguments with the call's context.
    private func prepare(
        _ spec: MCPToolSpec,
        arguments: [String: Any],
        workingDirectory: URL?
    ) throws -> (arguments: ToolArguments, context: AIAssistantContext) {
        var arguments = arguments
        let rawID = arguments.removeValue(forKey: "project_id")
        var projectID: UUID?
        if spec.acceptsProjectID, let rawID, !(rawID is NSNull) {
            guard let text = rawID as? String, let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw AIToolError.invalidArgument("\"project_id\" must be a project id from list_projects (a UUID), not \(rawID).")
            }
            projectID = id
        }
        if spec.requiresProjectID, projectID == nil {
            throw AIToolError.invalidArgument("Missing required argument \"project_id\" (a project id from list_projects).")
        }
        if let projectID, model.project(id: projectID) == nil {
            throw AIToolError.invalidArgument("No project has the id \(projectID.uuidString). Call list_projects for the current ids.")
        }
        if spec.navigates {
            if let refusal = model.automationNavigationRefusal { throw AIToolError.failed(refusal) }
            // During a countdown or a recording the recorded app stays in
            // front (the person or the AI is operating it); the countdown
            // panel and the control bar keep the recording visible. A call
            // refused afterwards, or one allowed then (list_recording_sources,
            // stop_recording), must not put the main window over it.
            switch model.recordingPhase {
            case .countdown, .recording, .stopping:
                break
            case .idle, .failed:
                presentWindow?()
            }
        }
        if let projectID, spec.scope == .project { try model.openProjectForAutomation(id: projectID) }
        let context = model.makeAutomationContext(projectID: projectID, workingDirectory: workingDirectory)
        return (ToolArguments(values: arguments), context)
    }
}

/// A call's decoded JSON arguments, handed to the job that runs the tool.
/// Never mutated after decoding, so sharing them across tasks is safe.
private struct ToolArguments: @unchecked Sendable {
    let values: [String: Any]
}
