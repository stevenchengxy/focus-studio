import FocusStudioAutomation
import Foundation
import Logging
import MCP

/// The helper's server over a scripted transport: raw JSON-RPC lines in, the
/// lines it writes out, a scripted AppForwarding in place of the app.
extension MCPTests {
    /// Feeds messages to the server and records what it writes. Each write
    /// takes a moment and the most writes ever in progress at once is kept,
    /// which shows whether the helper serializes them.
    actor ScriptedTransport: Transport {
        nonisolated let logger = Logger(label: "MCPTests") { _ in SwiftLogNoOpLogHandler() }
        private let input: AsyncThrowingStream<Data, Swift.Error>
        private let inputContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
        private var written: [AIJSONValue] = []
        private var writing = 0
        private(set) var mostConcurrentWrites = 0

        init() {
            (input, inputContinuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        }

        func connect() async throws {}
        func disconnect() async {}

        func send(_ data: Data) async throws {
            writing += 1
            mostConcurrentWrites = max(mostConcurrentWrites, writing)
            try? await Task.sleep(nanoseconds: 300_000)
            writing -= 1
            guard let object = try? JSONSerialization.jsonObject(with: data), let message = AIJSONValue(jsonObject: object) else {
                fatalError("FAIL: the server wrote something that is not JSON: \(String(decoding: data, as: UTF8.self))")
            }
            written.append(message)
        }

        func receive() -> AsyncThrowingStream<Data, Swift.Error> { input }

        nonisolated func push(_ message: AIJSONValue) {
            inputContinuation.yield(try! message.jsonData())
        }

        /// End of input, like the client closing the helper's stdin.
        nonisolated func close() {
            inputContinuation.finish()
        }

        var messages: [AIJSONValue] { written }
    }

    /// Stands in for the app: runs a closure per call and records the calls.
    final class ScriptedForwarder: AppForwarding, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ForwardedToolCall] = []
        private var shutDown = false
        let behavior: @Sendable (ForwardedToolCall) async -> AutomationCallResult

        init(_ behavior: @escaping @Sendable (ForwardedToolCall) async -> AutomationCallResult) {
            self.behavior = behavior
        }

        var calls: [ForwardedToolCall] { lock.withLock { recorded } }
        var didShutDown: Bool { lock.withLock { shutDown } }

        func forward(_ call: ForwardedToolCall) async -> AutomationCallResult {
            lock.withLock { recorded.append(call) }
            return await behavior(call)
        }

        func shutdown() async {
            lock.withLock { shutDown = true }
        }
    }

    /// A server run on a scripted transport, with a JSON-RPC client's helpers.
    final class Session: @unchecked Sendable {
        let transport = ScriptedTransport()
        let host: MCPServerHost
        let forwarder: ScriptedForwarder
        /// The exit status once `run` returned.
        private let exitStatus = Recorder<Int32>()

        init(workingDirectory: URL = URL(fileURLWithPath: "/tmp/client-project", isDirectory: true),
             settleTime: TimeInterval = 2,
             cancelTime: TimeInterval = 1,
             _ behavior: @escaping @Sendable (ForwardedToolCall) async -> AutomationCallResult) {
            forwarder = ScriptedForwarder(behavior)
            host = MCPServerHost(
                identity: HelperIdentity(name: HelperIdentity.serverName, title: HelperIdentity.serverTitle, version: "9.9.9", appURL: nil),
                catalog: .v1,
                forwarder: forwarder,
                workingDirectory: workingDirectory,
                settings: HelperSettings(logLevel: .critical, settleTime: settleTime, cancelTime: cancelTime),
                logHandler: { _ in SwiftLogNoOpLogHandler() }
            )
            let host = host
            let transport = transport
            let exitStatus = exitStatus
            Task { exitStatus.append(await host.run(transport: transport)) }
        }

        func send(_ message: AIJSONValue) {
            transport.push(message)
        }

        func request(_ id: Int, _ method: String, _ params: AIJSONValue? = nil) {
            var message: AIJSONValue = ["jsonrpc": "2.0", "id": AIJSONValue(id), "method": AIJSONValue(method)]
            if let params, case var .object(fields) = message {
                fields["params"] = params
                message = .object(fields)
            }
            send(message)
        }

        func notify(_ method: String, _ params: AIJSONValue? = nil) {
            var fields: [String: AIJSONValue] = ["jsonrpc": "2.0", "method": AIJSONValue(method)]
            if let params { fields["params"] = params }
            send(.object(fields))
        }

        /// Waits for the response to request `id`.
        func response(_ id: Int, timeout: TimeInterval = 10) async throws -> AIJSONValue {
            try await response(id: AIJSONValue(id), timeout: timeout)
        }

        func response(id: AIJSONValue, timeout: TimeInterval = 10) async throws -> AIJSONValue {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let found = await transport.messages.first(where: { $0.objectValue != nil && $0["id"] == id && $0["method"] == nil }) { return found }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let written = await transport.messages
            fatalError("FAIL: no response to request \(id); wrote \(written)")
        }

        func initialize(version: String = "2025-11-25", capabilities: AIJSONValue = [:], client: AIJSONValue = ["name": "scripted-client", "version": "1.2.3"]) async throws -> AIJSONValue {
            request(1, "initialize", ["protocolVersion": AIJSONValue(version), "capabilities": capabilities, "clientInfo": client])
            let reply = try await response(1)
            notify("notifications/initialized")
            return reply
        }

        /// Ends the input and waits for the server to return its exit status.
        func finish(timeout: TimeInterval = 10) async -> Int32? {
            transport.close()
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let status = exitStatus.items.first { return status }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return nil
        }
    }

    static func waitUntil(_ message: String, timeout: TimeInterval = 10, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            guard Date() < deadline else { fatalError("FAIL: timed out waiting for \(message)") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Handshake

    static func protocolHandshake() async throws {
        let session = Session { _ in .result(.failure("unused")) }
        let reply = try await session.initialize(version: "2025-06-18")
        let result = reply["result"]
        check(result?["protocolVersion"] == "2025-06-18", "echoes a supported version: \(reply)")
        check(result?["serverInfo"] == ["name": "focus-studio", "title": "Focus Studio", "version": "9.9.9"], "serverInfo: \(result?["serverInfo"] ?? .null)")
        check(result?["capabilities"] == ["tools": ["listChanged": false]], "tools only, no list changes: \(result?["capabilities"] ?? .null)")
        check(result?["instructions"]?.stringValue == MCPToolCatalog.instructions, "the catalog's instructions")
        check(session.host.session.protocolVersion == "2025-06-18", "the negotiated version is recorded: \(session.host.session.protocolVersion ?? "nil")")
        check(session.host.session.client == MCPClientIdentity(name: "scripted-client", version: "1.2.3", title: nil), "the client is recorded")

        session.request(2, "tools/list")
        let list = try await session.response(2)
        let tools = list["result"]?["tools"]?.arrayValue ?? []
        check(tools == MCPToolCatalog.v1.tools.map(\.descriptor), "tools/list is the catalog's descriptors")
        check(list["result"]?["nextCursor"] == nil, "one page")
        session.request(3, "ping")
        let pong = try await session.response(3)
        check(pong["result"] == [:], "ping answers {}")
        check(session.forwarder.calls.isEmpty, "initialize, tools/list and ping never reach the app")
        let status = await session.finish()
        check(status == 0, "exits 0 at end of input: \(status.map(String.init) ?? "still running")")
        check(session.forwarder.didShutDown, "the forwarder is shut down")

        // An unknown version gets the newest the SDK supports.
        let newer = Session { _ in .result(.failure("unused")) }
        let newest = try await newer.initialize(version: "2099-01-01")
        check(newest["result"]?["protocolVersion"] == "2025-11-25", "an unknown version gets 2025-11-25")
        check(newer.host.session.protocolVersion == "2025-11-25", "and that is recorded")
        _ = await newer.finish()
    }

    // MARK: - Forwarding

    static func protocolForwarding() async throws {
        let rootsSeen = Recorder<[URL]?>()
        let result = sampleResult
        let session = Session { call in
            rootsSeen.append(await call.roots?())
            return .result(result)
        }
        // A 2024-11-05 client with roots.
        _ = try await session.initialize(version: "2024-11-05", capabilities: ["roots": ["listChanged": true]], client: ["name": "old-client", "version": "0.1", "title": "Old Client"])
        session.request(2, "tools/call", ["name": "add_zoom", "arguments": ["project_id": "8C0F4E4A-2B0A-4F3E-9C55-6A1B2C3D4E5F", "start": 1, "end": 2.5, "x": 0.5, "y": 0.25, "scale": 2]])
        // The server asks for the roots while the call runs; answer like a client.
        try await waitUntil("roots/list") { await session.transport.messages.contains { $0["method"] == "roots/list" } }
        let rootsRequest = await session.transport.messages.first { $0["method"] == "roots/list" }!
        session.send(["jsonrpc": "2.0", "id": rootsRequest["id"]!, "result": ["roots": [["uri": "file:///Users/someone/project", "name": "project"], ["uri": "https://example.com/not-a-file"]]]])
        let old = try await session.response(2)
        let content = old["result"]?["content"]?.arrayValue ?? []
        check(old["result"]?["structuredContent"] == nil && old["result"]?["isError"] == false, "2024-11-05 gets no structuredContent: \(old)")
        let jsonBlock = String(decoding: try result.structuredContent!.jsonData(), as: UTF8.self)
        check(content.count == 3 && content[2]["text"]?.stringValue == jsonBlock, "the data follows as a JSON text block: \(content)")

        let call = session.forwarder.calls[0]
        check(call.toolName == "add_zoom" && call.sequence == 1, "the call is forwarded")
        check(call.arguments == ["project_id": "8C0F4E4A-2B0A-4F3E-9C55-6A1B2C3D4E5F", "start": 1, "end": 2.5, "x": 0.5, "y": 0.25, "scale": 2], "arguments arrive as sent: \(call.arguments)")
        check(call.workingDirectory.path == "/tmp/client-project", "with the helper's working directory")
        check(call.client == MCPClientIdentity(name: "old-client", version: "0.1", title: "Old Client") && call.protocolVersion == "2024-11-05", "with the client and the version: \(String(describing: call.client)) \(call.protocolVersion ?? "nil")")
        check(call.progress == nil, "no progress handler without a progress token")
        check(rootsSeen.items.first.flatMap { $0 } == [URL(string: "file:///Users/someone/project")!], "file roots only: \(rootsSeen.items)")

        // The second call reuses the roots it fetched.
        session.request(3, "tools/call", ["name": "get_status"])
        _ = try await session.response(3)
        let rootsRequests = await session.transport.messages.filter { $0["method"] == "roots/list" }.count
        check(rootsRequests == 1, "roots are fetched once")
        check(rootsSeen.items.count == 2 && rootsSeen.items[1] == rootsSeen.items[0], "and cached")
        // After roots/list_changed they are fetched again.
        session.notify("notifications/roots/list_changed")
        try await Task.sleep(nanoseconds: 50_000_000)
        session.request(4, "tools/call", ["name": "get_status"])
        try await waitUntil("roots/list again") { await session.transport.messages.filter { $0["method"] == "roots/list" }.count == 2 }
        let again = await session.transport.messages.last { $0["method"] == "roots/list" }!
        session.send(["jsonrpc": "2.0", "id": again["id"]!, "result": ["roots": []]])
        _ = try await session.response(4)
        check(rootsSeen.items.last.flatMap { $0 } == [], "the new roots: \(rootsSeen.items)")
        _ = await session.finish()

        // 2025-06-18, no roots capability, no roots provider. An image result
        // carries its data as a JSON block, so a client that shows the model
        // only structuredContent (Codex) still passes the image on.
        let modern = Session { call in
            check(call.roots == nil, "no roots provider for a client without roots")
            return .result(call.toolName == "capture_frame" ? result : MCPToolCallResult(content: [.text("3 zooms")], structuredContent: ["zoom_count": 3]))
        }
        _ = try await modern.initialize(version: "2025-06-18")
        modern.request(2, "tools/call", ["name": "capture_frame", "arguments": ["project_id": "8C0F4E4A-2B0A-4F3E-9C55-6A1B2C3D4E5F", "time": 2]])
        let reply = try await modern.response(2)
        let modernContent = reply["result"]?["content"]?.arrayValue ?? []
        check(reply["result"]?["structuredContent"] == nil && modernContent.count == 3 && modernContent[2]["text"]?.stringValue == jsonBlock, "2025-06-18 image result: the data as a JSON block: \(reply)")
        check(modernContent[1]["type"] == "image", "and the image block")
        modern.request(3, "tools/call", ["name": "get_project", "arguments": ["project_id": "8C0F4E4A-2B0A-4F3E-9C55-6A1B2C3D4E5F"]])
        let textReply = try await modern.response(3)
        check(textReply["result"]?["structuredContent"] == ["zoom_count": 3, "summary": "3 zooms"] && textReply["result"]?["content"]?.arrayValue?.count == 1, "2025-06-18 text result: structuredContent with the summary: \(textReply)")

        // A call the app reports cancelled on its own is an error result.
        let cancelledByApp = Session { _ in .cancelled }
        _ = try await cancelledByApp.initialize()
        cancelledByApp.request(2, "tools/call", ["name": "export_project", "arguments": ["project_id": "8C0F4E4A-2B0A-4F3E-9C55-6A1B2C3D4E5F"]])
        let cancelledReply = try await cancelledByApp.response(2)
        check(cancelledReply["result"]?["isError"] == true && cancelledReply["result"]?["content"]?[0]?["text"]?.stringValue?.contains("cancelled before it finished") == true, "cancelled by the app: \(cancelledReply)")
        _ = await cancelledByApp.finish()
        _ = await modern.finish()
    }

    // MARK: - Progress

    static func protocolProgress() async throws {
        let session = Session { call in
            guard let progress = call.progress else { return .result(.failure("no progress handler")) }
            // Repeated, backwards and fast reports; 30 of them, then a big result.
            for step in [0.0, 1, 1, 0.5, 2, 3] { progress(step, 10, "step \(step)") }
            for step in 4...30 { progress(Double(step), 30, nil) }
            let big = MCPToolCallResult(content: [.text("done"), .image(data: Data(repeating: 7, count: 300_000), mimeType: "image/jpeg")], structuredContent: ["ok": true])
            return .result(big)
        }
        _ = try await session.initialize()
        // Four calls at once, so their progress and large results are written
        // concurrently; string and integer tokens.
        let tokens: [AIJSONValue] = ["export-1", 42, "export-3", 7]
        for (offset, token) in tokens.enumerated() {
            session.request(2 + offset, "tools/call", ["name": "export_project", "arguments": ["project_id": "8C0F4E4A-2B0A-4F3E-9C55-6A1B2C3D4E5F"], "_meta": ["progressToken": token]])
        }
        for offset in tokens.indices { _ = try await session.response(2 + offset) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let messages = await session.transport.messages
        for (offset, token) in tokens.enumerated() {
            let id = 2 + offset
            guard let responseIndex = messages.firstIndex(where: { $0["id"] == AIJSONValue(id) && $0["method"] == nil }) else { fatalError("FAIL: no response \(id)") }
            let notifications = messages.enumerated().filter { $0.element["method"] == "notifications/progress" && $0.element["params"]?["progressToken"] == token }
            let values = notifications.compactMap { $0.element["params"]?["progress"]?.doubleValue }
            check(!values.isEmpty && zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "progress for \(token) strictly increases: \(values)")
            check(values.last == 30, "the last report arrives: \(values)")
            check(notifications.allSatisfy { $0.offset < responseIndex }, "no progress after the result for \(token)")
        }
        let overlap = await session.transport.mostConcurrentWrites
        check(overlap == 1, "writes never overlap: \(overlap)")
        _ = await session.finish()
    }

    // MARK: - Cancellation

    static func protocolCancellation() async throws {
        let sawCancellation = Recorder<Bool>()
        let session = Session { call in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            sawCancellation.append(true)
            return .cancelled
        }
        _ = try await session.initialize()
        session.request(7, "tools/call", ["name": "start_recording", "arguments": ["source": "display"]])
        try await waitUntil("the call reaches the forwarder") { session.forwarder.calls.count == 1 }
        session.notify("notifications/cancelled", ["requestId": 7, "reason": "user pressed Esc"])
        try await waitUntil("the forwarder sees the cancellation") { !sawCancellation.items.isEmpty }
        // Cancelling an unknown or finished request, or with no id, is ignored.
        session.notify("notifications/cancelled", ["requestId": 999])
        session.notify("notifications/cancelled", ["reason": "no id"])
        session.request(8, "ping")
        _ = try await session.response(8)
        try await Task.sleep(nanoseconds: 100_000_000)
        let answeredCancelled = await session.transport.messages.contains { $0["id"] == 7 }
        check(!answeredCancelled, "a cancelled request gets no response")
        let status = await session.finish()
        check(status == 0, "a cancelled request does not hold up the exit")
    }

    // MARK: - Unknown tools

    static func protocolUnknownTools() async throws {
        let session = Session { call in call.toolName == "list_assets" ? .unknownTool(call.toolName) : .result(.failure("unused")) }
        _ = try await session.initialize()
        session.request(2, "tools/call", ["name": "no_such_tool", "arguments": [:]])
        let unknown = try await session.response(2)
        check(unknown["error"]?["code"] == -32602 && unknown["error"]?["message"]?.stringValue?.contains("Unknown tool \"no_such_tool\"") == true, "unknown tool: -32602: \(unknown)")
        for (id, withheld) in MCPToolCatalog.withheldToolNames.enumerated() {
            session.request(10 + id, "tools/call", ["name": AIJSONValue(withheld)])
            let reply = try await session.response(10 + id)
            check(reply["error"]?["code"] == -32602 && reply["error"]?["message"]?.stringValue?.contains("not available to MCP clients") == true, "\(withheld) is withheld: \(reply)")
        }
        check(session.forwarder.calls.isEmpty, "unknown and withheld tools never reach the app")
        // The app not knowing a catalog tool (an older app) is the same error.
        session.request(3, "tools/call", ["name": "list_assets"])
        let older = try await session.response(3)
        let olderText = older["error"]?["message"]?.stringValue ?? ""
        check(older["error"]?["code"] == -32602 && olderText.contains("The Focus Studio that is running does not offer \"list_assets\"") && !olderText.contains("Call tools/list"),
              "a tool the app does not know: -32602 saying the running app is older, not pointing at tools/list (which lists it): \(older)")
        _ = await session.finish()
    }

    // MARK: - Malformed calls

    static func protocolMalformedCalls() async throws {
        let projectID: AIJSONValue = "8C0F4E4A-2B0A-4F3E-9C55-6A1B2C3D4E5F"
        let session = Session { _ in .result(.failure("ran")) }
        _ = try await session.initialize()
        // Malformed params are invalid params (-32602) with what is wrong,
        // not the SDK's -32603 "Internal error".
        let malformed: [(Int, AIJSONValue?, String)] = [
            (2, ["name": "get_status", "arguments": [1, 2]], "arguments must be an object"),
            (3, ["arguments": [:]], "params.name"),
            (4, nil, "needs params"),
            (5, ["name": 5], "params.name"),
            (6, [1, 2], "needs params"),
        ]
        for (id, params, phrase) in malformed {
            session.request(id, "tools/call", params)
            let reply = try await session.response(id)
            check(reply["error"]?["code"] == -32602 && reply["error"]?["message"]?.stringValue?.contains(phrase) == true, "malformed tools/call \(params ?? .null): -32602: \(reply)")
        }
        check(session.forwarder.calls.isEmpty, "malformed calls never reach the app")
        // Extra _meta keys and null arguments are fine.
        session.request(7, "tools/call", ["name": "get_status", "arguments": nil, "_meta": ["claudecode/toolUseId": "toolu_1"]])
        let plain = try await session.response(7)
        check(plain["result"]?["content"]?[0]?["text"] == "ran" && session.forwarder.calls.count == 1, "a call with extra _meta keys runs: \(plain)")
        // An argument the tool does not take is refused before the app sees
        // it, naming the arguments it does take.
        session.request(8, "tools/call", ["name": "export_project", "arguments": ["project_id": projectID, "frameRate": 60, "exportWidth": 1920]])
        let unknown = try await session.response(8)
        let text = unknown["result"]?["content"]?[0]?["text"]?.stringValue ?? ""
        check(unknown["result"]?["isError"] == true && text.contains("does not take \"exportWidth\", \"frameRate\"") && text.contains("\"frame_rate\"") && text.contains("\"width\""), "unknown arguments are refused: \(unknown)")
        check(session.forwarder.calls.count == 1, "the refused call never reaches the app")
        // Null values, and remove_zoom's zoom_id (what add_zoom returns), are accepted.
        session.request(9, "tools/call", ["name": "remove_zoom", "arguments": ["project_id": projectID, "zoom_id": projectID, "index": nil]])
        _ = try await session.response(9)
        check(session.forwarder.calls.count == 2 && session.forwarder.calls[1].arguments["zoom_id"] == projectID, "zoom_id and null values pass")
        check(session.forwarder.calls.allSatisfy { $0.toolName != "export_project" }, "export_project never ran")
        _ = await session.finish()
    }

    // MARK: - Values kept as sent

    /// The SDK's JSON value type turns strings that look like data URLs into
    /// bytes and back into different text; tools/call params, results and
    /// progress tokens must never go through it.
    static func protocolRawValues() async throws {
        let projectID: AIJSONValue = "8C0F4E4A-2B0A-4F3E-9C55-6A1B2C3D4E5F"
        let titles = [
            "data: Q3 revenue, by region", "data:text/html,<b>Hi</b>", "data:application/json;charset=utf-8,{}",
            "data:text/plain;charset=utf-8,hello", "data:image/png;base64,iVBORw0KGgo=", "Q3 revenue, by region",
        ]
        let session = Session { call in
            call.progress?(1, 2, "data:,half")
            let title = call.arguments["title"] ?? .null
            return .result(MCPToolCallResult(content: [.text(title.stringValue ?? "")], structuredContent: ["title": title, "arguments": .object(call.arguments)]))
        }
        _ = try await session.initialize()
        for (offset, title) in titles.enumerated() {
            let id: AIJSONValue = offset.isMultiple(of: 2) ? AIJSONValue(10 + offset) : AIJSONValue("call-\(offset) \"/é")
            let arguments: AIJSONValue = ["project_id": projectID, "title": AIJSONValue(title)]
            session.send(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": "rename_project", "arguments": arguments, "_meta": ["progressToken": AIJSONValue("data:,tok-\(offset)")]]])
            let reply = try await session.response(id: id)
            let call = session.forwarder.calls[offset]
            check(call.arguments["title"] == AIJSONValue(title) && .object(call.arguments) == arguments, "\(title): the arguments reach the app as sent: \(call.arguments)")
            check(call.progress != nil, "\(title): a data-URL-like progress token still asks for progress")
            let result = reply["result"]
            check(result?["content"]?[0]?["text"] == AIJSONValue(title), "\(title): the result text as written: \(reply)")
            check(result?["structuredContent"]?["title"] == AIJSONValue(title) && result?["structuredContent"]?["arguments"] == arguments && result?["structuredContent"]?["summary"] == AIJSONValue(title), "\(title): the structured content as written: \(reply)")
            check(result?["_meta"] == nil, "no reference is left in the result: \(reply)")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let progress = await session.transport.messages.filter { $0["method"] == "notifications/progress" }
        for offset in titles.indices {
            let token = AIJSONValue("data:,tok-\(offset)")
            check(progress.contains { $0["params"]?["progressToken"] == token && $0["params"]?["message"] == "data:,half" }, "progress for \(token) with its token and message unchanged: \(progress)")
        }
        // A call cancelled before its handler ran: no response, nothing kept.
        _ = await session.finish()
    }

    // MARK: - Batches

    static func protocolBatches() async throws {
        let projectID: AIJSONValue = "8C0F4E4A-2B0A-4F3E-9C55-6A1B2C3D4E5F"
        // The SDK would run a batch in its receive loop, where cancellation,
        // pings and the end of input cannot reach it; the helper refuses it.
        let session = Session(settleTime: 0.5, cancelTime: 0.5) { _ in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            return .cancelled
        }
        _ = try await session.initialize(version: "2025-03-26")
        session.send([
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "export_project", "arguments": ["project_id": projectID]]],
            ["jsonrpc": "2.0", "id": "three", "method": "ping"],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
        ])
        let started = Date()
        session.request(4, "ping")
        let pong = try await session.response(4)
        check(pong["result"] == [:] && Date().timeIntervalSince(started) < 1, "a ping after a batch is answered at once")
        try await waitUntil("the batch is answered") { await session.transport.messages.contains { $0.arrayValue != nil } }
        let batchReply = await session.transport.messages.first { $0.arrayValue != nil }?.arrayValue ?? []
        check(batchReply.map { $0["id"] } == [2, "three"] && batchReply.allSatisfy { $0["error"]?["code"] == -32600 && $0["jsonrpc"] == "2.0" }, "each request in a batch gets -32600: \(batchReply)")
        // A batch without requests, and an empty one, get a single -32600 with a null id.
        session.send([["jsonrpc": "2.0", "method": "notifications/initialized"]])
        session.send([])
        try await waitUntil("both are answered") { await session.transport.messages.filter { $0["error"]?["code"] == -32600 && $0["id"] == .null }.count == 2 }
        check(session.forwarder.calls.isEmpty, "nothing in a batch reaches the app")
        let finishing = Date()
        let status = await session.finish()
        check(status == 0 && Date().timeIntervalSince(finishing) < 0.4, "a refused batch leaves nothing to wait for at exit")
    }

    // MARK: - Shutdown

    static func protocolShutdown() async throws {
        // A call that finishes within the settle time after the end of input
        // gets its real answer.
        let slow = Session { _ in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return .cancelled
            }
            return .result(.failure("finished after stdin closed"))
        }
        _ = try await slow.initialize()
        slow.request(2, "tools/call", ["name": "get_status"])
        try await waitUntil("the call reaches the forwarder") { slow.forwarder.calls.count == 1 }
        let slowStatus = await slow.finish()
        check(slowStatus == 0, "exits 0")
        let slowReply = try await slow.response(2, timeout: 0.1)
        check(slowReply["result"]?["content"]?[0]?["text"] == "finished after stdin closed", "a call finishing within the settle time is answered: \(slowReply)")

        // A call still running after the settle time is cancelled, answers
        // that the helper is shutting down, and the helper exits 0 after
        // writing that.
        let session = Session(settleTime: 0.3) { _ in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            return .cancelled
        }
        _ = try await session.initialize()
        session.request(2, "tools/call", ["name": "stop_recording"])
        try await waitUntil("the call reaches the forwarder") { session.forwarder.calls.count == 1 }
        let started = Date()
        let status = await session.finish()
        let elapsed = Date().timeIntervalSince(started)
        check(status == 0 && elapsed >= 0.3 && elapsed < 1.5, "exits 0 once the settle time is over: \(status.map(String.init) ?? "still running") after \(elapsed) s")
        let reply = try await session.response(2, timeout: 0.1)
        check(reply["result"]?["isError"] == true && reply["result"]?["content"]?[0]?["text"]?.stringValue?.contains("shutting down") == true, "the running call is answered: \(reply)")
        check(session.forwarder.didShutDown, "the forwarder is shut down")

        // A forwarder that ignores cancellation cannot keep the helper alive
        // past settle + 2 × cancel time.
        let stuck = Session(settleTime: 0.2, cancelTime: 0.2) { _ in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return .result(.failure("late"))
        }
        _ = try await stuck.initialize()
        stuck.request(2, "tools/call", ["name": "stop_recording"])
        try await waitUntil("the call reaches the forwarder") { stuck.forwarder.calls.count == 1 }
        let stuckStarted = Date()
        let stuckStatus = await stuck.finish()
        let stuckElapsed = Date().timeIntervalSince(stuckStarted)
        check(stuckStatus == 0 && stuckElapsed < 1.5, "exits after the grace periods: \(stuckElapsed) s")

        // Requests read just before the end of input, as when a script pipes
        // them and closes stdin, are all answered before the helper exits.
        let piped = Session { call in .result(UnreachableAppForwarder().forwardResult(call.toolName)) }
        piped.request(1, "initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "pipe", "version": "1"]])
        piped.notify("notifications/initialized")
        piped.request(2, "tools/list")
        piped.request(3, "tools/call", ["name": "get_status"])
        piped.request(4, "ping")
        let pipedStarted = Date()
        let pipedStatus = await piped.finish()
        check(pipedStatus == 0 && Date().timeIntervalSince(pipedStarted) < 1, "exits 0 without waiting out the settle time")
        // Everything is written by the time run returns (the helper exits then).
        let written = await piped.transport.messages
        let answered = Set(written.filter { $0["method"] == nil }.compactMap { $0["id"]?.intValue })
        check(answered == [1, 2, 3, 4], "every request read before the end of input is answered before run returns: \(answered)")
        let piped3 = try await piped.response(3, timeout: 0.1)
        check(piped3["result"]?["content"]?[0]?["text"]?.stringValue?.contains("could not be reached") == true, "the piped call ran: \(piped3)")
    }
}

extension UnreachableAppForwarder {
    func forwardResult(_ toolName: String) -> MCPToolCallResult {
        .failure(Self.message(for: toolName))
    }
}
