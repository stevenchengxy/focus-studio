import FocusStudioAutomation
import Foundation

/// What the helper learns about its client while the session runs: who it
/// is and its roots (from `initialize`), and the negotiated protocol version
/// (read off the `initialize` response). Written by the SDK adapter, read
/// for each tool call; safe from any thread.
final class MCPClientSession: @unchecked Sendable {
    private let lock = NSLock()
    private var storedClient: MCPClientIdentity?
    private var storedProtocolVersion: String?
    private var storedRoots: MCPRootsProvider?

    var client: MCPClientIdentity? { lock.withLock { storedClient } }
    var protocolVersion: String? { lock.withLock { storedProtocolVersion } }
    var roots: MCPRootsProvider? { lock.withLock { storedRoots } }

    func setClient(_ client: MCPClientIdentity, roots: MCPRootsProvider?) {
        lock.withLock {
            storedClient = client
            storedRoots = roots
        }
    }

    func setProtocolVersion(_ version: String) {
        lock.withLock { storedProtocolVersion = version }
    }
}

/// Protocol features that depend on the negotiated version. Versions are
/// dates (YYYY-MM-DD), so they compare as strings.
enum MCPProtocolFeatures {
    /// Tool results gained `structuredContent` in this revision.
    static let structuredContentSince = "2025-06-18"

    static func supportsStructuredContent(_ version: String?) -> Bool {
        guard let version, isRevision(version) else { return false }
        return version >= structuredContentSince
    }

    static func isRevision(_ version: String) -> Bool {
        version.count == 10 && version.enumerated().allSatisfy { index, character in
            index == 4 || index == 7 ? character == "-" : character.isASCII && character.isNumber
        }
    }
}

/// A tool result in the form the negotiated protocol version can carry, and
/// that clients pass on whole to their model.
/// - From 2025-06-18 a text-only result carries its data in
///   `structuredContent`, with the English text added as its `summary`
///   (unless the data has one): Claude Code and Codex show the model the
///   structured content in place of the text blocks, and the text holds the
///   hints and next steps.
/// - A result with an image (capture_frame), and any result for an older
///   client, carries its data as a text block holding the JSON after the
///   other blocks instead (the form the spec recommends for backwards
///   compatibility): Codex drops every content block, the image included,
///   when structured content is present, and older clients have no such field.
struct MCPResultPresentation: Equatable {
    var content: [MCPContent]
    var structuredContent: AIJSONValue?
    var isError: Bool

    init(_ result: MCPToolCallResult, protocolVersion: String?) {
        content = result.content
        isError = result.isError
        structuredContent = nil
        guard let structured = result.structuredContent else { return }
        let textOnly = result.content.allSatisfy { block in
            if case .text = block { return true } else { return false }
        }
        if textOnly, MCPProtocolFeatures.supportsStructuredContent(protocolVersion) {
            if case var .object(fields) = structured, fields["summary"] == nil, !result.text.isEmpty {
                fields["summary"] = AIJSONValue(result.text)
                structuredContent = .object(fields)
            } else {
                structuredContent = structured
            }
        } else if let json = try? structured.jsonData(), let text = String(data: json, encoding: .utf8) {
            content.append(.text(text))
        }
    }
}

/// Delivers one call's progress to the client: in order, strictly
/// increasing (MCP requires it), coalesced when reports come faster than
/// they are written, and never after the call's result. Reports may arrive
/// on any thread.
final class OrderedProgressRelay: @unchecked Sendable {
    typealias Sender = @Sendable (_ progress: Double, _ total: Double?, _ message: String?) async -> Void

    private struct Update: Sendable {
        let progress: Double
        let total: Double?
        let message: String?
    }

    private let lock = NSLock()
    private var last: Double?
    private var isFinished = false
    private let continuation: AsyncStream<Update>.Continuation
    private let delivery: Task<Void, Never>

    init(send: @escaping Sender) {
        // Keeping only the newest pending update coalesces bursts; each one
        // kept is larger than the one before, so the order stays increasing.
        let (updates, continuation) = AsyncStream<Update>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        delivery = Task {
            for await update in updates {
                await send(update.progress, update.total, update.message)
            }
        }
    }

    /// The handler to give the call.
    var handler: AIToolProgressHandler {
        { [self] completed, total, message in report(completed, total, message) }
    }

    func report(_ completed: Double, _ total: Double?, _ message: String?) {
        guard completed.isFinite else { return }
        let total = total.flatMap { $0.isFinite ? $0 : nil }
        lock.withLock {
            guard !isFinished, last.map({ completed > $0 }) ?? true else { return }
            last = completed
            continuation.yield(Update(progress: completed, total: total, message: message))
        }
    }

    /// Stops taking reports and waits until the ones taken are written.
    func finish() async {
        lock.withLock { isFinished = true }
        continuation.finish()
        await delivery.value
    }
}

/// Answers `tools/call` for the SDK adapter, without knowing the SDK: checks
/// the name against the catalog, hands the call to the app forwarder with
/// the session's details, and turns cancellation and shutdown into what the
/// client should see. Also refuses new calls once the helper shuts down.
final class ToolCallRouter: @unchecked Sendable {
    let catalog: MCPToolCatalog
    let forwarder: any AppForwarding
    let workingDirectory: URL
    let session: MCPClientSession
    let log: HelperLog

    private let lock = NSLock()
    private var lastSequence = 0
    private var running: [Int: Task<AutomationCallResult, Never>] = [:]
    private var isShuttingDown = false

    init(catalog: MCPToolCatalog, forwarder: any AppForwarding, workingDirectory: URL, session: MCPClientSession, log: HelperLog) {
        self.catalog = catalog
        self.forwarder = forwarder
        self.workingDirectory = workingDirectory
        self.session = session
        self.log = log
    }

    /// The answer to one call:
    /// - `.unknownTool` for a name the catalog does not offer (withheld
    ///   in-app tools included), or one the app does not know: the adapter
    ///   answers JSON-RPC -32602;
    /// - an `isError` result naming the arguments the tool does not take, if
    ///   any (null values aside), without contacting the app;
    /// - `.cancelled` when the client cancelled the request (the calling task
    ///   is cancelled): no response is sent;
    /// - otherwise `.result`, an `isError` one when the call was cancelled for
    ///   another reason, such as the helper shutting down.
    func call(toolName: String, arguments: [String: AIJSONValue], progress: AIToolProgressHandler?) async -> AutomationCallResult {
        guard let spec = catalog.tool(named: toolName) else {
            log.debug("tools/call \(toolName): not in the catalog")
            return .unknownTool(toolName)
        }
        // An argument the tool does not take would be ignored, and the call
        // would succeed with something else than asked (frameRate for
        // export_project's frame_rate, say), so it is refused.
        let unknown = spec.unknownArgumentNames(in: arguments)
        guard unknown.isEmpty else {
            log.debug("tools/call \(toolName): unknown arguments \(unknown)")
            return .result(.failure(Self.unknownArgumentsMessage(toolName, unknown: unknown, accepted: spec.argumentNames)))
        }
        let forwarder = forwarder
        let started: (sequence: Int, task: Task<AutomationCallResult, Never>)? = lock.withLock {
            guard !isShuttingDown else { return nil }
            lastSequence += 1
            let call = ForwardedToolCall(
                sequence: lastSequence, tool: spec, arguments: arguments, workingDirectory: workingDirectory,
                client: session.client, protocolVersion: session.protocolVersion, progress: progress, roots: session.roots
            )
            let task = Task { await forwarder.forward(call) }
            running[lastSequence] = task
            return (lastSequence, task)
        }
        guard let started else { return .result(.failure(Self.shutdownMessage(for: toolName))) }
        log.debug("tools/call #\(started.sequence) \(toolName): forwarding")
        let outcome = await withTaskCancellationHandler {
            await started.task.value
        } onCancel: {
            started.task.cancel()
        }
        let shuttingDown = lock.withLock {
            running[started.sequence] = nil
            return isShuttingDown
        }
        if Task.isCancelled {
            log.debug("tools/call #\(started.sequence) \(toolName): cancelled by the client")
            return .cancelled
        }
        log.debug("tools/call #\(started.sequence) \(toolName): answered")
        if case .cancelled = outcome {
            return .result(.failure(shuttingDown ? Self.shutdownMessage(for: toolName) : "\(toolName) was cancelled before it finished."))
        }
        return outcome
    }

    /// The helper is exiting: refuses new calls, cancels the running ones,
    /// gives them up to `grace` seconds to answer, then shuts the forwarder down.
    func shutdown(grace: TimeInterval) async {
        let tasks = lock.withLock {
            isShuttingDown = true
            return Array(running.values)
        }
        for task in tasks { task.cancel() }
        let deadline = Date().addingTimeInterval(grace)
        while lock.withLock({ !running.isEmpty }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await forwarder.shutdown()
    }

    /// The JSON-RPC error message for a name ``call(toolName:arguments:progress:)``
    /// answered `.unknownTool` for.
    func unknownToolMessage(_ name: String) -> String {
        if MCPToolCatalog.withheldToolNames.contains(name) {
            return "The tool \"\(name)\" is not available to MCP clients. Call tools/list for the tools Focus Studio offers."
        }
        return "Unknown tool \"\(name)\". Call tools/list for the tools Focus Studio offers."
    }

    static func unknownArgumentsMessage(_ toolName: String, unknown: [String], accepted: [String]) -> String {
        func quoted(_ names: [String]) -> String { names.map { "\"\($0)\"" }.joined(separator: ", ") }
        let takes = accepted.isEmpty ? "It takes no arguments." : "Its arguments are \(quoted(accepted))."
        return "\(toolName) does not take \(quoted(unknown)), so it did not run and nothing was changed. \(takes)"
    }

    static func shutdownMessage(for toolName: String) -> String {
        "The focus-studio-mcp helper is shutting down (its standard input closed), so \(toolName) did not finish."
    }
}
