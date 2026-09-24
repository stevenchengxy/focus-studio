// The only file that uses the MCP Swift SDK (modelcontextprotocol/swift-sdk,
// pinned exactly in Package.swift) and its swift-log logger. The rest of the
// helper works with Focus Studio's own types (MCPToolCatalog,
// MCPToolCallResult, AIJSONValue), so an SDK upgrade touches this file only.
//
// What the SDK provides here: JSON-RPC message handling, `initialize`
// with version negotiation (2025-11-25, 2025-06-18, 2025-03-26 and
// 2024-11-05; an unknown version gets the newest), `ping`, method dispatch,
// and `notifications/cancelled`, which cancels the Swift task running the
// request's handler and suppresses its response. This file adds:
// - the stdio transport (StdioLineTransport): blocking reads on a thread of
//   their own and whole-message writes on a serial queue. The SDK's
//   StdioTransport makes both descriptors non-blocking and polls standard
//   input every 10 ms, which would keep an idle helper waking all session long;
// - a transport wrapper (SessionTransport) that
//   - keeps each `tools/call` request's params and its result away from the
//     SDK's JSON value type, which turns any string that looks like a data
//     URL ("data:…,…") into bytes and back into a different string: the SDK
//     handler gets a reference, reads the params as the client sent them and
//     leaves its result, which the wrapper writes as the helper encoded it;
//   - refuses JSON-RPC batches with -32600 (MCP removed batching in
//     2025-06-18, and the SDK would run a batch inside its receive loop,
//     where cancellation and the end of input cannot reach it);
//   - reads the negotiated version off the `initialize` response (the SDK
//     keeps it private), serializes writes, and tracks unanswered requests
//     so the helper can finish them before it exits;
// - the tools, progress notifications and result mapping.
//
// Deviations left to the SDK (0.12.1), all for input that is not valid
// JSON-RPC: a parse error (-32700) carries a random string id instead of
// null; a request whose id is neither a string nor an integer (1.5, true, {})
// is taken for a notification and gets no response; `"id": null` is
// answered with `"id": ""`.

import Darwin
import FocusStudioAutomation
import Foundation
import Logging
import MCP
import System

/// Focus Studio's MCP server: serves `initialize` and `tools/list` from the
/// catalog without contacting the app, and hands each `tools/call` to the
/// router, which forwards it to the app.
final class MCPServerHost: Sendable {
    let identity: HelperIdentity
    let instructions: String
    let settings: HelperSettings
    let session: MCPClientSession
    let router: ToolCallRouter
    let log: HelperLog
    private let logger: Logger
    private let tools: [Tool]

    init(
        identity: HelperIdentity,
        catalog: MCPToolCatalog,
        instructions: String = MCPToolCatalog.instructions,
        forwarder: any AppForwarding,
        workingDirectory: URL,
        settings: HelperSettings,
        logHandler: (@Sendable (String) -> any LogHandler)? = nil
    ) {
        var logger = Logger(label: "focus-studio-mcp", factory: logHandler ?? { StreamLogHandler.standardError(label: $0) })
        logger.logLevel = settings.logLevel.swiftLog
        let log = HelperLog(level: settings.logLevel) { [logger] level, message in
            logger.log(level: level.swiftLog, "\(message)")
        }
        let session = MCPClientSession()
        self.identity = identity
        self.instructions = instructions
        self.settings = settings
        self.session = session
        self.log = log
        self.logger = logger
        self.tools = Self.tools(from: catalog)
        self.router = ToolCallRouter(catalog: catalog, forwarder: forwarder, workingDirectory: workingDirectory, session: session, log: log)
    }

    /// Serves MCP on the helper's standard streams until standard input
    /// closes; returns the exit status.
    func runStdio(_ streams: HelperStandardStreams) async -> Int32 {
        await run(transport: StdioLineTransport(input: streams.input, output: streams.protocolOutput, logger: logger))
    }

    /// Serves MCP on `transport` until its input ends. Then the requests
    /// already read get the settle time to be answered; calls still running
    /// after it are cancelled (they answer that the helper is shutting down)
    /// and get the cancel time to answer and be written. Returns 0, or 1 when
    /// the server could not start.
    func run(transport inner: any Transport) async -> Int32 {
        let transport = SessionTransport(wrapping: inner, session: session, logger: logger)
        let server = Server(
            name: identity.name,
            version: identity.version,
            title: identity.title,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        let roots = ClientRoots(server: server)
        let tools = tools
        let router = router
        let session = session
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools)
        }
        await server.withMethodHandler(ToolsCall.self) { params in
            try await Self.callTool(params, transport: transport, router: router, session: session, server: server)
        }
        await server.onNotification(RootsListChangedNotification.self) { _ in
            await roots.invalidate()
        }
        do {
            try await server.start(transport: transport) { client, capabilities in
                var provider: MCPRootsProvider?
                if capabilities.roots != nil {
                    provider = { await roots.fileURLs() }
                }
                session.setClient(MCPClientIdentity(name: client.name, version: client.version, title: client.title), roots: provider)
            }
        } catch {
            log.error("Could not start the MCP server: \(error)")
            return 1
        }
        log.info("\(identity.name) \(identity.version) is serving MCP")
        await server.waitUntilCompleted()
        log.debug("Input closed; answering the requests already read before exiting")
        if await !transport.waitUntilAnswered(timeout: settings.settleTime) {
            log.debug("Cancelling the calls still running")
        }
        await router.shutdown(grace: settings.cancelTime)
        if await !transport.waitUntilAnswered(timeout: settings.cancelTime) {
            log.warning("Exiting with requests unanswered")
        }
        return 0
    }

    // MARK: - tools/call

    /// `tools/call` as the SDK dispatches it here: its params are any JSON
    /// value (normally the reference SessionTransport put in their place),
    /// so malformed params get -32602 from ``toolCall(from:)`` rather than
    /// the SDK's -32603 for params that do not decode.
    private enum ToolsCall: MCP.Method {
        static let name = CallTool.name
        typealias Parameters = MCP.Value
        typealias Result = CallTool.Result
    }

    /// Answers one `tools/call`. The transport normally replaced its params
    /// with a reference to them as the client sent them; the result then goes
    /// back the same way, and the SDK sends a placeholder that the transport
    /// swaps for it.
    private static func callTool(
        _ params: MCP.Value,
        transport: SessionTransport,
        router: ToolCallRouter,
        session: MCPClientSession,
        server: Server
    ) async throws -> CallTool.Result {
        guard let reference = SessionTransport.callReference(in: params) else {
            // Params the transport did not take (a request id it cannot
            // track), as the SDK decoded them.
            let token = params.objectValue?["_meta"]?.objectValue?["progressToken"]
            let call = RawToolCall(params: AIJSONValue(mcp: params), progressToken: ProgressToken(token))
            return try await answer(call, router: router, session: session, server: server)
        }
        // A request loses its params before its handler runs only when the
        // client cancelled it.
        guard let call = await transport.takeCall(reference) else { throw CancellationError() }
        let result = try await answer(call, router: router, session: session, server: server)
        try await transport.keep(result, for: reference)
        return CallTool.Result(content: [], _meta: SessionTransport.placeholderMetadata(reference))
    }

    private static func answer(
        _ call: RawToolCall,
        router: ToolCallRouter,
        session: MCPClientSession,
        server: Server
    ) async throws -> CallTool.Result {
        let (name, arguments) = try toolCall(from: call.params)
        let relay = call.progressToken.map { token in
            OrderedProgressRelay { progress, total, message in
                try? await server.notify(ProgressNotification.message(
                    .init(progressToken: token, progress: progress, total: total, message: message)
                ))
            }
        }
        let outcome = await router.call(toolName: name, arguments: arguments, progress: relay?.handler)
        await relay?.finish()
        switch outcome {
        case .cancelled:
            // The SDK sends no response for a cancelled handler, as MCP requires.
            throw CancellationError()
        case let .unknownTool(name):
            throw MCPError.invalidParams(router.unknownToolMessage(name))
        case let .result(result):
            return callToolResult(result, protocolVersion: session.protocolVersion)
        }
    }

    /// The tool name and arguments of `tools/call` params; -32602 (invalid
    /// params) with what is wrong when they are malformed.
    static func toolCall(from params: AIJSONValue) throws -> (name: String, arguments: [String: AIJSONValue]) {
        guard case let .object(fields) = params else {
            throw MCPError.invalidParams("tools/call needs params: an object with the tool's \"name\" and its \"arguments\" object.")
        }
        guard case let .string(name)? = fields["name"] else {
            throw MCPError.invalidParams("tools/call needs params.name, the tool's name as a string. Call tools/list for the tools Focus Studio offers.")
        }
        switch fields["arguments"] {
        case nil, .null?:
            return (name, [:])
        case let .object(arguments)?:
            return (name, arguments)
        default:
            throw MCPError.invalidParams("tools/call params.arguments must be an object of named arguments.")
        }
    }

    // MARK: - Mapping

    /// The `tools/list` entries: each spec's name, title, description,
    /// inputSchema and annotations, exactly as its catalog descriptor has them.
    static func tools(from catalog: MCPToolCatalog) -> [Tool] {
        catalog.tools.map { spec in
            let descriptor = spec.descriptor
            let annotations = descriptor["annotations"]
            return Tool(
                name: spec.name,
                title: spec.title,
                description: spec.description,
                inputSchema: MCP.Value(focusStudio: spec.inputSchema),
                annotations: Tool.Annotations(
                    title: annotations?["title"]?.stringValue,
                    readOnlyHint: annotations?["readOnlyHint"]?.boolValue,
                    destructiveHint: annotations?["destructiveHint"]?.boolValue,
                    idempotentHint: annotations?["idempotentHint"]?.boolValue,
                    openWorldHint: annotations?["openWorldHint"]?.boolValue
                )
            )
        }
    }

    /// A tool result as the SDK sends it, shaped for the negotiated version
    /// (see ``MCPResultPresentation``).
    static func callToolResult(_ result: MCPToolCallResult, protocolVersion: String?) -> CallTool.Result {
        let presentation = MCPResultPresentation(result, protocolVersion: protocolVersion)
        return CallTool.Result(
            content: presentation.content.map { block -> Tool.Content in
                switch block {
                case let .text(text):
                    return .text(text: text, annotations: nil, _meta: nil)
                case let .image(data, mimeType):
                    return .image(data: data.base64EncodedString(), mimeType: mimeType, annotations: nil, _meta: nil)
                }
            },
            structuredContent: presentation.structuredContent.map(MCP.Value.init(focusStudio:)),
            isError: presentation.isError
        )
    }

    /// A `tools/call` result as the helper writes it: the SDK's encoding,
    /// which keeps every string as it is (only decoding into its JSON value
    /// type changes strings that look like data URLs).
    static func encoded(_ result: CallTool.Result) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(result)
    }
}

// MARK: - JSON values

extension MCP.Value {
    /// Whole numbers become integers, so schemas read `"minimum": 0`, not `0.0`.
    init(focusStudio json: AIJSONValue) {
        switch json {
        case .null:
            self = .null
        case let .bool(value):
            self = .bool(value)
        case let .number(value):
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992, let whole = Int(exactly: value) {
                self = .int(whole)
            } else {
                self = .double(value)
            }
        case let .string(value):
            self = .string(value)
        case let .array(items):
            self = .array(items.map(MCP.Value.init(focusStudio:)))
        case let .object(fields):
            self = .object(fields.mapValues(MCP.Value.init(focusStudio:)))
        }
    }
}

extension AIJSONValue {
    /// Only for values the SDK decoded itself. It decodes a string that looks
    /// like a data URL as `.data`, which comes back as a canonical base64 data
    /// URL, not always the original text; SessionTransport keeps `tools/call`
    /// params out of the SDK for that reason.
    init(mcp value: MCP.Value) {
        switch value {
        case .null:
            self = .null
        case let .bool(flag):
            self = .bool(flag)
        case let .int(number):
            self = .number(Double(number))
        case let .double(number):
            self = number.isFinite ? .number(number) : .null
        case let .string(text):
            self = .string(text)
        case let .data(mimeType, data):
            self = .string(data.dataURLEncoded(mimeType: mimeType))
        case let .array(items):
            self = .array(items.map(AIJSONValue.init(mcp:)))
        case let .object(fields):
            self = .object(fields.mapValues(AIJSONValue.init(mcp:)))
        }
    }
}

extension ProgressToken {
    /// A string or integer token; nil for anything else.
    init?(_ value: MCP.Value?) {
        switch value {
        case let .string(text)?: self = .string(text)
        case let .int(number)?: self = .integer(number)
        default: return nil
        }
    }

    /// A token as JSONSerialization read it, exactly: a string or an integer.
    init?(jsonObject value: Any?) {
        switch RequestKey(value) {
        case let .string(text)?: self = .string(text)
        case let .number(number)?: self = .integer(number)
        case nil: return nil
        }
    }
}

extension HelperLogLevel {
    var swiftLog: Logger.Level {
        switch self {
        case .trace: return .trace
        case .debug: return .debug
        case .info: return .info
        case .notice: return .notice
        case .warning: return .warning
        case .error: return .error
        case .critical: return .critical
        }
    }
}

extension HelperLog {
    /// Lines on standard error through swift-log, as the server writes its
    /// own; for the parts of the helper made before the server (the app
    /// forwarder).
    static func standardError(level: HelperLogLevel) -> HelperLog {
        var logger = Logger(label: "focus-studio-mcp", factory: { StreamLogHandler.standardError(label: $0) })
        logger.logLevel = level.swiftLog
        return HelperLog(level: level) { [logger] level, message in
            logger.log(level: level.swiftLog, "\(message)")
        }
    }
}

// MARK: - Roots

/// The client's roots, fetched with `roots/list` on first use and again after
/// `notifications/roots/list_changed`.
private actor ClientRoots {
    private let server: Server
    private var cached: [URL]?

    init(server: Server) {
        self.server = server
    }

    func invalidate() {
        cached = nil
    }

    /// File roots only; nil when the client fails to answer within `timeout`.
    func fileURLs(timeout: TimeInterval = 5) async -> [URL]? {
        if let cached { return cached }
        let server = server
        // The SDK's request cannot be cancelled, so it races a timer rather
        // than running in a task group that would wait for it.
        let listed: [URL]? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task {
                let roots = try? await server.listRoots()
                once.resume(roots.map { $0.compactMap { URL(string: $0.uri) }.filter(\.isFileURL) })
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                once.resume(nil)
            }
        }
        if let listed { cached = listed }
        return listed
    }
}

private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}

// MARK: - Stdio transport

/// Newline-delimited JSON-RPC on two descriptors, with blocking I/O. A thread
/// of its own blocks in read(2), so an idle helper does not wake; writes run
/// whole and in order on a serial queue. It never makes the descriptors
/// non-blocking (their open file descriptions may be shared with the client,
/// or with a terminal); should someone else have, it waits in poll(2) rather
/// than spinning. Blank lines are skipped, and a last message without a
/// newline still counts.
private actor StdioLineTransport: Transport {
    nonisolated let logger: Logger
    private let input: Int32
    private let output: Int32
    private let writes = DispatchQueue(label: "focus-studio-mcp.stdout")
    private let messages: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var reader: Thread?

    init(input: Int32, output: Int32, logger: Logger) {
        self.input = input
        self.output = output
        self.logger = logger
        (messages, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
    }

    func connect() async throws {
        guard reader == nil else { return }
        let input = input
        let continuation = continuation
        let thread = Thread { Self.readLines(from: input, into: continuation) }
        thread.name = "focus-studio-mcp stdin"
        reader = thread
        thread.start()
    }

    func disconnect() async {
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        let line = data + Data([UInt8(ascii: "\n")])
        let output = output
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Swift.Error>) in
            writes.async {
                if let code = Self.writeAll(line, to: output) {
                    done.resume(throwing: MCPError.transportError(Errno(rawValue: code)))
                } else {
                    done.resume()
                }
            }
        }
    }

    nonisolated func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messages
    }

    private static func readLines(from descriptor: Int32, into continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                pending.append(contentsOf: buffer[..<count])
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = pending[pending.startIndex..<newline]
                    if !isBlank(line) { continuation.yield(Data(line)) }
                    pending = Data(pending[(newline + 1)...])
                }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                waitUntilReady(descriptor, for: Int16(POLLIN))
            } else {
                continuation.finish(throwing: MCPError.transportError(Errno(rawValue: errno)))
                return
            }
        }
        if !isBlank(pending) { continuation.yield(pending) }
        continuation.finish()
    }

    /// Writes all of `data`; the errno of a failed write, or nil.
    private static func writeAll(_ data: Data, to descriptor: Int32) -> Int32? {
        data.withUnsafeBytes { raw -> Int32? in
            guard let base = raw.baseAddress else { return nil }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base + offset, raw.count - offset)
                if written >= 0 {
                    offset += written
                } else if errno == EAGAIN {
                    waitUntilReady(descriptor, for: Int16(POLLOUT))
                } else if errno != EINTR {
                    return errno
                }
            }
            return nil
        }
    }

    private static func waitUntilReady(_ descriptor: Int32, for events: Int16) {
        var entry = pollfd(fd: descriptor, events: events, revents: 0)
        _ = poll(&entry, 1, -1)
    }

    private static func isBlank(_ bytes: Data) -> Bool {
        bytes.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
    }
}

// MARK: - Session transport

/// A `tools/call` request's params as the client sent them (null when it
/// sent none), and its progress token read exactly.
struct RawToolCall: Sendable {
    let params: AIJSONValue
    let progressToken: ProgressToken?
}

/// Wraps the transport the server runs on:
/// - swaps each `tools/call` request's params for a reference (see the file
///   header) and each such result, which the handler leaves here, back in;
/// - answers a JSON-RPC batch with -32600 instead of passing it on;
/// - writes one message at a time, in order;
/// - records the protocol version the `initialize` response carries;
/// - tracks requests read and not yet answered (a cancelled request needs no
///   answer), so the helper can wait for them after its input closes.
private actor SessionTransport: Transport {
    /// The `_meta` key of the reference that replaces a `tools/call`
    /// request's params, and marks the placeholder result the SDK sends.
    static let callReferenceKey = "com.local.focusstudio/call"
    static let batchMessage = "Batched JSON-RPC messages are not supported; send each message on its own line."

    nonisolated let logger: Logger
    private let inner: any Transport
    private let session: MCPClientSession
    private var messages: AsyncThrowingStream<Data, Swift.Error>?
    private var lastWrite: Task<Void, Never>?
    private var writesInFlight = 0
    private var unanswered: Set<RequestKey> = []
    private var initializeRequest: RequestKey?
    /// `tools/call` params by reference, until the handler takes them.
    private var calls: [String: RawToolCall] = [:]
    /// The reference of each `tools/call` request not yet answered.
    private var callReferences: [RequestKey: String] = [:]
    /// Encoded results by reference, until they are written.
    private var results: [String: Data] = [:]

    init(wrapping inner: any Transport, session: MCPClientSession, logger: Logger) {
        self.inner = inner
        self.session = session
        self.logger = logger
    }

    static func callReference(in params: MCP.Value) -> String? {
        params.objectValue?["_meta"]?.objectValue?[callReferenceKey]?.stringValue
    }

    static func placeholderMetadata(_ reference: String) -> Metadata {
        Metadata(additionalFields: [callReferenceKey: .string(reference)])
    }

    func connect() async throws {
        try await inner.connect()
    }

    func disconnect() async {
        await inner.disconnect()
    }

    func takeCall(_ reference: String) -> RawToolCall? {
        calls.removeValue(forKey: reference)
    }

    func keep(_ result: CallTool.Result, for reference: String) throws {
        results[reference] = try MCPServerHost.encoded(result)
    }

    func send(_ data: Data) async throws {
        var data = data
        let envelopes = JSONRPCEnvelope.parse(data)
        if envelopes.count == 1, let response = envelopes.first, response.isResponse, let id = response.id,
           let reference = response.resultReference, let result = results.removeValue(forKey: reference) {
            data = Self.response(id: id, result: result)
        }
        noteVersion(in: envelopes)
        let previous = lastWrite
        let inner = inner
        let write = Task {
            await previous?.value
            try await inner.send(data)
        }
        lastWrite = Task { _ = await write.result }
        writesInFlight += 1
        defer {
            writesInFlight -= 1
            for envelope in envelopes where envelope.isResponse {
                guard let id = envelope.id else { continue }
                unanswered.remove(id)
                if let reference = callReferences.removeValue(forKey: id) { calls.removeValue(forKey: reference) }
            }
        }
        try await write.value
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        if let messages { return messages }
        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        let inner = inner
        let pump = Task {
            do {
                for try await data in await inner.receive() {
                    if let admitted = await self.admit(data) { continuation.yield(admitted) }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in pump.cancel() }
        messages = stream
        return stream
    }

    /// Waits until every request read has been answered (or cancelled) and
    /// nothing is being written; false if that takes longer than `timeout`.
    func waitUntilAnswered(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !unanswered.isEmpty || writesInFlight > 0 {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    /// What the SDK gets for one message read: nothing for a batch, which is
    /// answered here; a `tools/call` request with its params replaced by a
    /// reference; anything else as it is (including what does not parse,
    /// which the SDK answers).
    private func admit(_ data: Data) async -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return data }
        if let batch = object as? [Any] {
            try? await send(Self.batchRejection(batch))
            return nil
        }
        guard var message = object as? [String: Any] else { return data }
        let envelope = JSONRPCEnvelope(message)
        noteIncoming(envelope)
        guard envelope.isRequest, envelope.method == CallTool.name, let id = envelope.id else { return data }
        let params = message["params"]
        let reference = UUID().uuidString
        let meta = (params as? [String: Any])?["_meta"] as? [String: Any]
        calls[reference] = RawToolCall(
            params: params.flatMap(AIJSONValue.init(jsonObject:)) ?? .null,
            progressToken: ProgressToken(jsonObject: meta?["progressToken"])
        )
        callReferences[id] = reference
        message["params"] = ["_meta": [Self.callReferenceKey: reference]]
        guard let rewritten = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
            calls.removeValue(forKey: reference)
            callReferences.removeValue(forKey: id)
            return data
        }
        return rewritten
    }

    private func noteIncoming(_ envelope: JSONRPCEnvelope) {
        if envelope.isRequest, let id = envelope.id {
            unanswered.insert(id)
            if envelope.method == Initialize.name { initializeRequest = id }
        } else if envelope.method == CancelledNotification.name, let id = envelope.cancelledRequest {
            unanswered.remove(id)
            // A call cancelled before its handler took its params never runs.
            if let reference = callReferences.removeValue(forKey: id) { calls.removeValue(forKey: reference) }
        }
    }

    private func noteVersion(in envelopes: [JSONRPCEnvelope]) {
        guard let request = initializeRequest,
              let response = envelopes.first(where: { $0.isResponse && $0.id == request }) else { return }
        initializeRequest = nil
        if let version = response.protocolVersion { session.setProtocolVersion(version) }
    }

    /// A response carrying an already encoded result, keys sorted as the SDK writes them.
    private static func response(id: RequestKey, result: Data) -> Data {
        Data(#"{"id":"#.utf8) + id.json + Data(#","jsonrpc":"2.0","result":"#.utf8) + result + Data("}".utf8)
    }

    /// The answer to a batch: an Invalid Request error for each request in
    /// it, or a single one with a null id when it holds no request.
    static func batchRejection(_ batch: [Any]) -> Data {
        let error: [String: Any] = ["code": -32600, "message": batchMessage]
        let ids = batch.compactMap { item -> Any? in
            guard let message = item as? [String: Any], message["method"] is String, let id = message["id"], RequestKey(id) != nil else { return nil }
            return id
        }
        let reply: Any = ids.isEmpty
            ? ["jsonrpc": "2.0", "id": NSNull(), "error": error] as [String: Any]
            : ids.map { ["jsonrpc": "2.0", "id": $0, "error": error] as [String: Any] }
        return (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
    }
}

/// A JSON-RPC request id, compared the way the SDK compares them.
private enum RequestKey: Hashable {
    case string(String)
    case number(Int)

    init?(_ value: Any?) {
        if let text = value as? String {
            self = .string(text)
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !CFNumberIsFloatType(number) {
            self = .number(number.intValue)
        } else {
            return nil
        }
    }

    /// The id as JSON.
    var json: Data {
        switch self {
        case let .string(text):
            return (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed])) ?? Data(#""""#.utf8)
        case let .number(number):
            return Data(String(number).utf8)
        }
    }
}

/// The parts of a JSON-RPC message (or of each message in a batch) the
/// transport wrapper looks at.
private struct JSONRPCEnvelope {
    let id: RequestKey?
    let method: String?
    let hasOutcome: Bool
    let cancelledRequest: RequestKey?
    let protocolVersion: String?
    /// The reference of a placeholder `tools/call` result.
    let resultReference: String?

    var isRequest: Bool { method != nil && id != nil }
    var isResponse: Bool { method == nil && id != nil && hasOutcome }

    init(_ message: [String: Any]) {
        let params = message["params"] as? [String: Any]
        let result = message["result"] as? [String: Any]
        id = RequestKey(message["id"])
        method = message["method"] as? String
        hasOutcome = message["result"] != nil || message["error"] != nil
        cancelledRequest = RequestKey(params?["requestId"])
        protocolVersion = result?["protocolVersion"] as? String
        resultReference = (result?["_meta"] as? [String: Any])?[SessionTransport.callReferenceKey] as? String
    }

    static func parse(_ data: Data) -> [JSONRPCEnvelope] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
        let items = (object as? [Any]) ?? [object]
        return items.compactMap { ($0 as? [String: Any]).map(JSONRPCEnvelope.init) }
    }
}
