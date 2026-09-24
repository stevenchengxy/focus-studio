import Darwin
import FocusStudioAutomation
import Foundation

/// The control channel's shared pieces (FocusStudioAutomation), which both
/// the app and focus-studio-mcp use: NDJSON framing, JSON-RPC messages and
/// parameters, the mapping between call replies and AutomationCallResult,
/// socket path resolution, and a connection over a real socket pair.
extension MCPTests {
    // MARK: - Framing

    static func controlFraming() throws {
        var framer = LineFramer(maximumLineLength: 64)
        try verify(try framer.append(Data("a\nb\n".utf8)) == [Data("a".utf8), Data("b".utf8)], "Two lines in one read")
        try verify(try framer.append(Data("x\r\ny\rz\n".utf8)) == [Data("x".utf8), Data("y\rz".utf8)], "A trailing CR is dropped, an inner one kept")
        try verify(try framer.append(Data("\n\r\n  \n\t\r\n".utf8)).isEmpty, "Blank lines are skipped")
        try verify(try framer.append(Data("1\n2\n3".utf8)) == [Data("1".utf8), Data("2".utf8)] && framer.bufferedByteCount == 1, "A partial line waits")
        try verify(try framer.append(Data("4\n".utf8)) == [Data("34".utf8)], "and completes with the next read")
        try verify(try framer.append(Data("tail".utf8)).isEmpty && framer.finish() == Data("tail".utf8) && framer.finish() == nil, "finish returns an unterminated last line once")
        try verify(try framer.append(Data("   ".utf8)).isEmpty && framer.finish() == nil, "finish skips a blank remainder")

        // Byte by byte, with multi-byte characters, U+2028/U+2029 and escaped
        // newlines inside JSON strings: the bytes come back unchanged.
        let text = "line\u{2028}separator\u{2029}paragraph — 录制 🎬 \"quoted\" \\ back\nslash/"
        let message = ControlMessage.request(id: 7, method: ControlChannel.Method.call, params: ["tool": "set_chapters", "arguments": ["title": AIJSONValue(text)]])
        let encoded = try message.encoded()
        check(!encoded.contains(0x0A) && !encoded.contains(0x0D), "An encoded message has no raw line breaks")
        check(!String(decoding: encoded, as: UTF8.self).contains("\\/"), "Slashes are not escaped")
        var slow = LineFramer()
        var lines: [Data] = []
        for byte in encoded + Data([0x0A]) { lines += try slow.append([byte]) }
        check(lines == [encoded], "Byte-by-byte reads frame one line")
        try verify(try ControlMessage.decode(lines[0]) == message, "and it decodes to the same message")
        try verify(try ControlMessage.decode(lines[0]).json["params"]?["arguments"]?["title"]?.stringValue == text, "with U+2028, U+2029 and the escaped newline intact")

        // The cap: exactly the limit passes, one more byte fails, also before any line feed.
        var capped = LineFramer(maximumLineLength: 8)
        try verify(try capped.append(Data("12345678\n".utf8)) == [Data("12345678".utf8)], "A line of exactly the limit passes")
        var tooLong = LineFramer(maximumLineLength: 8)
        check((try? tooLong.append(Data("123456789\n".utf8))) == nil, "A longer line fails")
        check((try? tooLong.append(Data("1\n".utf8))) == nil, "and the framer stays failed")
        var unterminated = LineFramer(maximumLineLength: 8)
        try verify(try unterminated.append(Data("12345678".utf8)).isEmpty, "The limit may wait for its line feed")
        check((try? unterminated.append(Data("9".utf8))) == nil, "but a ninth byte without one fails at once")
        check(LineFramer().maximumLineLength == 16 * 1_024 * 1_024 && ControlChannel.maximumLineLength == 16 * 1_024 * 1_024, "The default cap is 16 MiB")
    }

    // MARK: - Messages

    static func controlMessages() throws {
        func roundTrip(_ message: ControlMessage) throws -> ControlMessage {
            try ControlMessage.decode(try message.encoded())
        }
        let hello = ControlHello(helperVersion: "1.5.0", client: ControlClientInfo(name: "claude-code", version: "2.1.0", title: nil), workingDirectory: "/Users/me/project")
        check(hello.json == ["protocol": 1, "helper_version": "1.5.0", "client": ["name": "claude-code", "version": "2.1.0"], "working_directory": "/Users/me/project"],
              "hello uses the wire names: \(hello.json)")
        try verify(try ControlHello.decode(hello.json) == hello && hello.client?.displayName == "Claude Code", "hello decodes; the client reads as Claude Code")
        check(ControlClientInfo(name: "codex-mcp-client", version: "0.1").displayName == "Codex"
              && ControlClientInfo(name: "x", version: "1", title: "My Tool").displayName == "My Tool"
              && ControlClientInfo(name: "  ", version: "1").displayName == "AI tool", "Display names")
        let reply = ControlHelloReply(appVersion: "1.5.0", appPath: "/Applications/Focus Studio.app", pid: 42)
        check(reply.json == ["protocol": 1, "app_version": "1.5.0", "app_path": "/Applications/Focus Studio.app", "pid": 42], "hello reply: \(reply.json)")
        try verify(try ControlHelloReply.decode(reply.json) == reply, "hello reply decodes")

        let call = ControlCall(tool: "add_zoom", arguments: ["project_id": "A", "start": 0.5, "nested": ["list": [1, "two", nil, true]]], workingDirectory: "/tmp", progressToken: "tok-1")
        check(call.json["progress_token"] == "tok-1" && call.json["working_directory"] == "/tmp", "call uses the wire names: \(call.json)")
        try verify(try ControlCall.decode(call.json) == call, "call round-trips")
        try verify(try ControlCall.decode(["tool": "get_status"]) == ControlCall(tool: "get_status"), "Missing arguments decode as none")
        try verify(try ControlCall.decode(["tool": "x", "progress_token": 5]).progressToken == 5, "Numeric progress tokens")
        // elapsed: the helper's own time, optional in protocol 1 both ways.
        let timed = ControlCall(tool: "export_project", elapsed: 12.5)
        check(timed.json["elapsed"] == 12.5 && call.json["elapsed"] == nil, "elapsed is sent only when known: \(timed.json)")
        try verify(try ControlCall.decode(timed.json) == timed, "elapsed round-trips")
        try verify(try ControlCall.decode(["tool": "x"]).elapsed == nil && ControlCall(tool: "x").countedElapsed == 0, "A helper that predates elapsed counts as none")
        check(ControlCall(tool: "x", elapsed: -3).countedElapsed == 0 && ControlCall(tool: "x", elapsed: 1e9).countedElapsed == ControlCall.maximumElapsed
              && ControlCall(tool: "x", elapsed: .infinity).countedElapsed == 0 && timed.countedElapsed == 12.5, "The app clamps what a helper claims")
        struct OlderCall: Decodable, Equatable { let tool: String; let working_directory: String? }
        check((try? JSONDecoder().decode(OlderCall.self, from: timed.json.jsonData())) == OlderCall(tool: "export_project", working_directory: nil),
              "A decoder that predates elapsed skips it")
        check(ControlChannel.protocolVersion == 1, "An optional field keeps protocol 1")
        do {
            _ = try ControlCall.decode(["arguments": [:]])
            check(false, "A call without a tool must fail")
        } catch let error as ControlError {
            check(error.code == -32602 && error.message.contains("\"tool\""), "The error names the missing key: \(error.message)")
        }
        do {
            _ = try ControlCall.decode(["tool": 3])
            check(false, "A numeric tool must fail")
        } catch let error as ControlError {
            check(error.code == -32602, "Wrong types are invalid params: \(error.message)")
        }
        let progress = ControlProgress(id: 3, progress: 0.25, total: 1, message: "Rendering")
        check(progress.json == ["id": 3, "progress": 0.25, "total": 1, "message": "Rendering"] && ControlProgress(id: 3, progress: 1).json == ["id": 3, "progress": 1], "progress: \(progress.json)")
        check(ControlCancel(id: 9).json == ["id": 9], "cancel")

        let messages: [ControlMessage] = [
            .request(id: 1, method: "hello", params: hello.json),
            .request(id: "s-1", method: "call", params: nil),
            .notification(method: "progress", params: progress.json),
            .notification(method: "cancel", params: ["id": 1]),
            .result(id: 1, reply.json),
            .error(id: 2, ControlError(code: -32602, message: "Unknown tool: x", data: ["tool": "x"])),
            .error(id: nil, ControlError(code: -32700, message: "Parse error")),
        ]
        for message in messages {
            try verify(try roundTrip(message) == message, "Round trip: \(message.json)")
        }
        check(ControlMessage.notification(method: "cancel", params: nil).json == ["jsonrpc": "2.0", "method": "cancel"], "Notifications carry no id")
        check(ControlMessage.error(id: nil, ControlError(code: -32700, message: "x")).json["id"] == .null, "An unknown id is null")

        func failure(_ text: String) -> ControlMessageError? {
            do {
                _ = try ControlMessage.decode(Data(text.utf8))
                return nil
            } catch {
                return error as? ControlMessageError
            }
        }
        check(failure("{not json")?.error.code == -32700 && failure("{not json")?.id == nil, "Invalid JSON is a parse error without id")
        check(failure("[1,2]")?.error.code == -32600, "An array is not a message")
        check(failure(#"{"jsonrpc":"2.0","id":true,"method":"hello"}"#)?.error.code == -32600, "A boolean id is invalid")
        check(failure(#"{"jsonrpc":"2.0","id":4,"method":7}"#)?.id == 4, "An invalid request keeps its id for the reply")
        check(failure(#"{"jsonrpc":"2.0","id":4,"method":"call","params":"x"}"#)?.error.code == -32600, "String params are invalid")
        check(failure(#"{"jsonrpc":"2.0","id":4}"#)?.error.code == -32600, "Neither request nor response")
        try verify(try ControlMessage.decode(Data(#"{"jsonrpc":"2.0","id":null,"method":"cancel","params":{"id":1}}"#.utf8)) == .notification(method: "cancel", params: ["id": 1]),
              "A null id is a notification")
        check(failure(#"{"jsonrpc":"2.0","id":1,"error":{"message":"no code"}}"#)?.error.code == -32600, "An error needs an integer code")
    }

    // MARK: - Call results

    static func controlCallResults() throws {
        let image = Data([0xFF, 0xD8, 0xFF, 0x00, 0x2F])
        let rich = MCPToolCallResult(content: [.text("Frame at 1.0 s."), .image(data: image, mimeType: "image/jpeg")], structuredContent: ["path": "/tmp/a b/frame.png", "time": 1])
        for outcome: AutomationCallResult in [.result(rich), .result(.failure("No project has the id X.")), .unknownTool("generate_video"), .cancelled] {
            let reply = outcome.controlReply(id: 12)
            check(reply.id == 12, "The reply answers its request")
            let decoded = try ControlMessage.decode(try reply.encoded())
            check(AutomationCallResult(controlReply: decoded, tool: "capture_frame") == outcome, "Round trip: \(outcome)")
        }
        check(AutomationCallResult.unknownTool("generate_video").controlReply(id: 1).json["error"]?["code"] == -32602, "Unknown tools are -32602")
        check(AutomationCallResult.cancelled.controlReply(id: 1).json["error"]?["code"] == -32800, "Cancelled calls are -32800")

        let other = AutomationCallResult(controlReply: .error(id: 1, ControlError(code: -32003, message: "protocol 2")), tool: "get_status")
        guard case let .result(otherResult) = other else { fatalError("FAIL: other errors become results") }
        check(otherResult.isError && otherResult.text == "Focus Studio could not run get_status: protocol 2", "Other errors are isError results: \(otherResult.text)")
        let unreadable = AutomationCallResult(controlReply: .result(id: 1, ["content": "text"]), tool: "get_status")
        guard case let .result(unreadableResult) = unreadable else { fatalError("FAIL: an unreadable result becomes an error result") }
        check(unreadableResult.isError && unreadableResult.text.contains("could not read"), "An unreadable result is an isError result")
        check(MCPToolCallResult(json: ["content": [["type": "audio", "data": "AA=="]]]) == nil, "Unknown block types are not read")
        check(MCPToolCallResult(json: ["content": [], "structuredContent": [1]]) == nil, "structuredContent must be an object")
        check(MCPToolCallResult(json: ["content": [["type": "text", "text": "ok"]], "structuredContent": nil])?.structuredContent == nil, "A null structuredContent is none")
    }

    // MARK: - Socket location

    static func controlSocketLocation() throws {
        check(ControlChannel.maximumSocketPathLength == 103, "sun_path holds 103 bytes and a NUL")
        let explicit = try ControlChannel.socketLocation(environment: ["FOCUS_STUDIO_CONTROL_SOCKET": "/tmp/fs-test/control.sock"])
        check(explicit == ControlSocketLocation(path: "/tmp/fs-test/control.sock", source: .environment), "The override wins: \(explicit)")
        check(explicit.directory == "/tmp/fs-test" && explicit.lockPath == "/tmp/fs-test/control.sock.lock", "Directory and lock file")
        check((try? ControlChannel.socketLocation(environment: ["FOCUS_STUDIO_CONTROL_SOCKET": "relative.sock"])) == nil, "A relative override is refused")
        let long = "/" + String(repeating: "x", count: 110)
        check((try? ControlChannel.socketLocation(environment: ["FOCUS_STUDIO_CONTROL_SOCKET": long])) == nil, "An override that does not fit is refused, not shortened")
        let standard = try ControlChannel.socketLocation(environment: [:], homeDirectory: "/Users/me", temporaryDirectory: "/var/folders/xy/T/")
        check(standard == ControlSocketLocation(path: "/Users/me/Library/Application Support/FocusStudio/Control/control.sock", source: .applicationSupport), "The standard path: \(standard)")
        let longHome = "/Users/" + String(repeating: "h", count: 60)
        let fallback = try ControlChannel.socketLocation(environment: ["FOCUS_STUDIO_CONTROL_SOCKET": ""], homeDirectory: longHome, temporaryDirectory: "/var/folders/xy/T/")
        check(fallback == ControlSocketLocation(path: "/var/folders/xy/T/FocusStudio-Control/control.sock", source: .temporaryDirectory), "A long home falls back to the temporary folder: \(fallback)")
        check((try? ControlChannel.socketLocation(environment: [:], homeDirectory: longHome, temporaryDirectory: "/" + String(repeating: "t", count: 100))) == nil, "Nothing fits: an error")
        let home = ControlChannel.userHomeDirectory()
        let temporary = ControlChannel.userTemporaryDirectory() ?? ""
        check(home.hasPrefix("/") && temporary.hasPrefix("/") && temporary.hasSuffix("/T/"), "The account's home and private temporary folder: \(home), \(temporary)")
        let real = try ControlChannel.socketLocation(environment: [:])
        check(real.path.hasPrefix(home) || real.source == .temporaryDirectory, "The real path derives from the account record: \(real.path)")
    }

    // MARK: - Connections

    static func controlConnections() async throws {
        // Two connections over a socket pair.
        var pair: [Int32] = [0, 0]
        check(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0, "socketpair")
        let left = ControlConnection(fileDescriptor: pair[0], label: "test.left")
        let right = ControlConnection(fileDescriptor: pair[1], label: "test.right", maximumLineLength: 2 * 1_024 * 1_024)
        let received = LockedList<Data>()
        let leftClosed = LockedList<ControlConnection.CloseReason>()
        let rightClosed = LockedList<ControlConnection.CloseReason>()
        left.start(onLine: { _ in }, onClose: { leftClosed.append($0) })
        right.start(onLine: { received.append($0) }, onClose: { rightClosed.append($0) })
        check(ControlSocket.peerCredentials(of: pair[0])?.uid == geteuid() && ControlSocket.peerProcessID(of: pair[0]) == getpid(), "Peer credentials and pid")

        // Many messages from many threads arrive whole; one thread's arrive in order.
        let big = String(repeating: "é录", count: 300_000)
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            for index in 0..<250 {
                try? left.send(.notification(method: "progress", params: ["id": AIJSONValue(worker), "progress": AIJSONValue(index)]))
            }
        }
        try left.send(.notification(method: "big", params: ["text": AIJSONValue(big)]))
        try await waitFor("1001 lines") { received.count == 1_001 }
        let messages = try received.items.map { try ControlMessage.decode($0) }
        for worker in 0..<4 {
            let values = messages.compactMap { message -> Int? in
                guard case let .notification("progress", params) = message, params?["id"]?.intValue == worker else { return nil }
                return params?["progress"]?.intValue
            }
            check(values == Array(0..<250), "Worker \(worker)'s messages arrive in order")
        }
        check(messages.last?.json["params"]?["text"]?.stringValue == big, "A 1.5 MB line arrives whole")

        // Closing one end: the other sees the end of the stream; sending after close is a no-op.
        left.close()
        try await waitFor("both ends closed") { leftClosed.count == 1 && rightClosed.count == 1 }
        check(leftClosed.items == [.closedLocally] && rightClosed.items == [.endOfStream], "Close reasons: \(leftClosed.items), \(rightClosed.items)")
        check(!left.isOpen && left.closedBecause == .closedLocally, "The closed end says why")
        try left.send(.notification(method: "late", params: nil))
        left.close()
        check(leftClosed.count == 1, "The close handler runs once")

        // A line over the limit closes the connection.
        var second: [Int32] = [0, 0]
        check(socketpair(AF_UNIX, SOCK_STREAM, 0, &second) == 0, "socketpair")
        let writer = ControlConnection(fileDescriptor: second[0], label: "test.writer")
        let limited = ControlConnection(fileDescriptor: second[1], label: "test.limited", maximumLineLength: 1_024)
        let limitedClosed = LockedList<ControlConnection.CloseReason>()
        writer.start(onLine: { _ in }, onClose: { _ in })
        limited.start(onLine: { _ in }, onClose: { limitedClosed.append($0) })
        writer.send(line: Data(repeating: 0x61, count: 4_096))
        try await waitFor("the limited end to close") { limitedClosed.count == 1 }
        check(limitedClosed.items == [.lineTooLong], "Too long: \(limitedClosed.items)")
        writer.close()

        // Closing before starting releases the descriptor without a handler.
        var third: [Int32] = [0, 0]
        check(socketpair(AF_UNIX, SOCK_STREAM, 0, &third) == 0, "socketpair")
        let unstarted = ControlConnection(fileDescriptor: third[0])
        unstarted.close()
        unstarted.start(onLine: { _ in }, onClose: { _ in fatalError("FAIL: a closed connection must not start") })
        let peer = ControlConnection(fileDescriptor: third[1])
        let peerClosed = LockedList<ControlConnection.CloseReason>()
        peer.start(onLine: { _ in }, onClose: { peerClosed.append($0) })
        try await waitFor("the peer of an unstarted connection to see it close") { peerClosed.count == 1 }

        // Connecting: nothing there, a stale socket file, a path too long.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fs-cc-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("c.sock").path
        do {
            _ = try ControlSocket.connect(to: path)
            check(false, "Connecting to nothing must fail")
        } catch let error as ControlSocketError {
            check(error.code == ENOENT && error.meansNoListener, "No socket file: ENOENT (\(error))")
        }
        let stale = try ControlSocket.makeSocket()
        var address = try ControlSocket.address(for: path)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        check(bound == 0, "bind a socket that never listens")
        Darwin.close(stale)
        do {
            _ = try ControlSocket.connect(to: path)
            check(false, "Connecting to a stale socket must fail")
        } catch let error as ControlSocketError {
            check(error.code == ECONNREFUSED && error.meansNoListener, "A stale socket file: ECONNREFUSED (\(error))")
        }
        do {
            _ = try ControlSocket.connect(to: "/" + String(repeating: "p", count: 120))
            check(false, "A path that does not fit must fail")
        } catch let error as ControlSocketError {
            check(error == .pathTooLong("/" + String(repeating: "p", count: 120)) && !error.meansNoListener, "Too long: \(error)")
        }
    }

    /// `check` for conditions that may throw.
    static func verify(_ condition: @autoclosure () throws -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) throws {
        guard try condition() else { fatalError("FAIL: \(message)", file: file, line: line) }
    }

    static func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { fatalError("FAIL: timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A thread-safe list for values reported from other queues.
final class LockedList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Element] = []

    func append(_ item: Element) { lock.withLock { stored.append(item) } }
    var items: [Element] { lock.withLock { stored } }
    var count: Int { lock.withLock { stored.count } }
}
