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
///   app); refused while recording or busy. Every call that changes what
///   the app shows is also refused while the in-app assistant is partway
///   through a request, an export from the editor runs or a save or open
///   panel is up. Read-only tools never navigate;
/// - runs the calls that change what the app shows one at a time, in order,
///   so parallel calls never switch the editor under each other;
/// - builds a fresh English tool context with the client's working directory
///   and the project's assets folder;
/// - runs the tool as a job, which answers with a running status and a
///   job_id when the call outlasts ``AutomationJobs/detachAfter`` counted
///   from its arrival, its wait for a turn included;
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
    /// call changes what it shows (``MainWindowPresenter`` in the app; nil
    /// in tests).
    var presentWindow: (@MainActor () -> Void)?

    init(model: StudioModel, catalog: MCPToolCatalog = .v1, jobs: AutomationJobs? = nil) {
        self.model = model
        self.catalog = catalog
        self.jobs = jobs ?? AutomationJobs()
    }

    /// `progress` receives measured progress (always increasing, on any
    /// thread) until the call returns. A cancelled caller gets `.cancelled`
    /// once the tool has stopped; nothing is sent to the client then.
    /// `stillAllowed` is asked right before the tool runs, after any wait
    /// for a turn; a refusal it returns is the call's `isError` result.
    func call(
        toolName: String,
        arguments: [String: Any],
        workingDirectory: URL?,
        clientName: String?,
        progress: AIToolProgressHandler?,
        stillAllowed: (@MainActor () -> String?)? = nil
    ) async -> AutomationCallResult {
        guard let spec = catalog.tool(named: toolName) else { return .unknownTool(toolName) }
        if spec.name == MCPToolCatalog.waitForJobName {
            return await jobs.waitForJob(arguments: arguments, progress: progress)
        }
        guard let tool = spec.tool else { return .unknownTool(toolName) }
        // The wait for a turn counts toward the detach threshold.
        let arrived = Date()
        if spec.navigates {
            guard await queue.acquire() else { return .cancelled }
        }
        defer { if spec.navigates { queue.release() } }
        // AI tools may have been turned off, or the client revoked, while this call waited.
        if let refusal = stillAllowed?() { return .result(.failure(refusal)) }
        let prepared: (arguments: ToolArguments, context: AIAssistantContext)
        do {
            prepared = try prepare(spec, arguments: arguments, workingDirectory: workingDirectory)
        } catch {
            return .result(.failure(error))
        }
        let includesImage = spec.returnsImage
        return await jobs.run(tool: spec.name, clientName: clientName, arrivedAt: arrived, progress: progress) { report in
            var context = prepared.context
            context.numericProgress = report
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
            presentWindow?()
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
