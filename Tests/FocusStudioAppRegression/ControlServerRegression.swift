import CoreGraphics
import Darwin
import FocusStudioAutomation
import FocusStudioCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The app's control server end to end, over real Unix sockets in temporary
/// folders, against a StudioModel on a temporary library: hello waits for the
/// library, calls run through approval and the automation bridge with
/// progress, cancel and disconnect cancel calls, peers of other users are
/// turned away, stale and live sockets are handled (relaunch handoff), the
/// socket folder is kept private, approvals (allow, decline, timeout with
/// heartbeat progress, joined prompts, revoke, AI tools turned off,
/// persistence) and the identity of the program behind the current process.
/// No real socket path, preferences or approval prompt are touched: the
/// approver is the test's own and the preferences live in a file in the
/// test's temporary folder.
@MainActor
enum ControlServerRegression {
    static func run() async throws {
        try await handshakeAndCalls()
        try await cancellation()
        try await peers()
        try await connectionLimit()
        try await socketHandling()
        try await approvals()
        try await genericHostApprovals()
        try await accessCheckedBeforeRunning()
        try parentIdentity()
        try await genericHostIdentity()
        print("ControlServerRegression: PASS (hello after bootstrap, call before hello, get_status/add_zoom through the bridge with the window hook, unknown tool/method, malformed lines, duplicate ids, protocol mismatch, progress relay only when asked and never after the reply, activity indicator, cancel and disconnect cancel the tool, cancel while awaiting approval, peers of other users refused, connections over the limit told why, stale socket replaced, relaunch handoff from a live instance, lock held without a socket file, own-inode unlink, private socket folder, symlinked folder and non-socket file refused, approvals allow/decline/timeout with heartbeat/late allow/joined prompts/revoke/off/unidentified/persistence, generic hosts keyed by script or approved per connection only, revoke or off while a call waits its turn, parent process identity, script of a shell or interpreter)")
    }

    // MARK: - Hello and calls

    private static func handshakeAndCalls() async throws {
        let fixture = try await ServerFixture()
        defer { fixture.cleanup() }
        let gate = ReadinessGate()
        var windowRequests = 0
        let server = fixture.makeServer(readiness: { await gate.wait() }, presentWindow: { windowRequests += 1 })
        server.start()
        try expect(server.state == .listening(fixture.socketPath), "The server listens: \(server.state)")
        try expect(mode(of: fixture.socketPath) == 0o600 && mode(of: fixture.socketDirectory) == 0o700, "Socket 0600 in a 0700 folder: \(String(mode(of: fixture.socketPath), radix: 8)) \(String(mode(of: fixture.socketDirectory), radix: 8))")

        let client = try TestClient(path: fixture.socketPath)
        defer { client.close() }
        let early = try await client.request("call", ControlCall(tool: "get_status").json)
        try expect(early.errorCode == ControlChannel.ErrorCode.helloRequired, "A call before hello is refused: \(early.json)")

        // hello waits until the library has loaded.
        let helloID = try client.send("hello", ControlHello(helperVersion: "9.9.9", client: ControlClientInfo(name: "claude-code", version: "2.1.0"), workingDirectory: fixture.cwd.path).json)
        try await Task.sleep(for: .milliseconds(250))
        try expect(client.reply(to: helloID) == nil, "No hello reply before bootstrap has finished")
        gate.open()
        let hello = try await client.waitForReply(to: helloID)
        guard case let .result(_, value) = hello, let reply = try? ControlHelloReply.decode(value) else { throw ServerFailure("hello must succeed: \(hello.json)") }
        try expect(reply == ControlHelloReply(appVersion: "1.5.0-test", appPath: "/Applications/Focus Studio Test.app", pid: getpid()), "hello reply: \(value)")

        // A call through approval and the bridge.
        let status = try await client.request("call", ControlCall(tool: "get_status").json)
        let statusResult = try status.toolResult()
        try expect(!statusResult.isError && statusResult.structuredContent?["library_count"] == 1, "get_status runs in the app: \(status.json)")
        try expect(fixture.approver.requests.count == 1 && fixture.approver.requests[0].clientName == "Claude Code" && fixture.approver.requests[0].toolName == "get_status",
                   "The first call asked the person once: \(fixture.approver.requests)")
        try expect(fixture.store.approval(for: fixture.identity.value!.key)?.clientName == "Claude Code", "The approval is remembered")
        try expect(windowRequests == 0 && fixture.model.destination == .library, "A read-only call does not touch the window")

        let zoom = try await client.request("call", ControlCall(tool: "add_zoom", arguments: ["project_id": AIJSONValue(fixture.project.id.uuidString), "start": 0.1, "end": 0.6, "x": 0.5, "y": 0.5]).json)
        try expect(!(try zoom.toolResult().isError) && fixture.model.destination == .editor && fixture.model.activeProject?.id == fixture.project.id, "add_zoom opens its project: \(zoom.json)")
        try expect(windowRequests == 1 && fixture.approver.requests.count == 1, "A navigating call puts the window on screen; no second prompt")

        let unknown = try await client.request("call", ControlCall(tool: "generate_video").json)
        try expect(unknown.errorCode == -32602 && unknown.json["error"]?["data"]?["tool"] == "generate_video", "Unknown tools are -32602 with the name: \(unknown.json)")
        let noTool = try await client.request("call", ["arguments": [:]])
        try expect(noTool.errorCode == -32602, "A call without a tool: \(noTool.json)")
        let method = try await client.request("frobnicate", nil)
        try expect(method.errorCode == -32601, "Unknown methods are -32601: \(method.json)")
        client.connection.send(line: Data("{not json".utf8))
        let parse = try await client.waitFor("a parse error") { $0.errorCode == -32700 }
        try expect(parse.json["id"] == .null, "A parse error has a null id")

        // Progress only when asked, increasing, all before the reply.
        let progressID = try client.send("call", ControlCall(tool: "slow_tool", arguments: ["seconds": 0.5], progressToken: "tok").json)
        try await waitUntil("the activity indicator to show the call") { fixture.activity.workingClientNames == ["Claude Code"] }
        try client.send("call", ControlCall(tool: "slow_tool", arguments: ["seconds": 0.1]).json, id: progressID)
        let duplicate = try await client.waitFor("the duplicate refusal") { $0.id == progressID && $0.errorCode != nil }
        try expect(duplicate.errorCode == -32600, "A second call with a running id is refused: \(duplicate.json)")
        let slow = try await client.waitFor("the slow result") { $0.id == progressID && $0.resultValue != nil }
        try expect(!(try slow.toolResult().isError), "The slow call finishes: \(slow.json)")
        try await Task.sleep(for: .milliseconds(150))
        let messages = client.messages
        let replyIndex = messages.firstIndex { $0.id == progressID && $0.resultValue != nil } ?? -1
        let progress = messages.enumerated().compactMap { index, message -> (Int, Double)? in
            guard case let .notification("progress", params) = message, params?["id"] == progressID, let value = params?["progress"]?.doubleValue else { return nil }
            return (index, value)
        }
        try expect(progress.count >= 3 && progress.allSatisfy { $0.0 < replyIndex }, "Progress arrives before the reply: \(progress.map(\.1)), reply at \(replyIndex)")
        try expect(zip(progress, progress.dropFirst()).allSatisfy { $0.1 < $1.1 } && progress.last?.1 == 1, "Progress increases to 1: \(progress.map(\.1))")
        try expect(fixture.activity.running.isEmpty, "The indicator clears when the call returns")
        let quietID = try client.send("call", ControlCall(tool: "slow_tool", arguments: ["seconds": 0.3]).json)
        _ = try await client.waitForReply(to: quietID)
        try expect(!client.messages.contains { if case let .notification("progress", params) = $0 { return params?["id"] == quietID } else { return false } },
                   "No progress without a progress token")

        // A helper that speaks another protocol gets the app's hello, then refusals.
        let other = try TestClient(path: fixture.socketPath)
        defer { other.close() }
        var mismatched = ControlHello(helperVersion: "2.0.0", client: nil, workingDirectory: nil)
        mismatched.protocolVersion = 2
        let otherHello = try await other.request("hello", mismatched.json)
        try expect((try? ControlHelloReply.decode(otherHello.resultValue))?.protocolVersion == 1, "The app answers hello with its own protocol: \(otherHello.json)")
        let refused = try await other.request("call", ControlCall(tool: "get_status").json)
        try expect(refused.errorCode == ControlChannel.ErrorCode.protocolMismatch && (refused.json["error"]?["message"]?.stringValue ?? "").contains("/Applications/Focus Studio Test.app"),
                   "Calls are refused, naming the running copy: \(refused.json)")
        server.stop()
        try expect(server.state == .stopped && !FileManager.default.fileExists(atPath: fixture.socketPath), "stop removes its socket")
        _ = try await client.waitForClose()
    }

    // MARK: - Cancellation

    private static func cancellation() async throws {
        let fixture = try await ServerFixture()
        defer { fixture.cleanup() }
        let server = fixture.makeServer()
        server.start()
        defer { server.stop() }

        let client = try TestClient(path: fixture.socketPath)
        try await client.hello()
        let id = try client.send("call", ControlCall(tool: "slow_tool", arguments: ["seconds": 20]).json)
        try await waitUntil("the slow call to start") { fixture.slowStarted.isRaised }
        try client.notify("cancel", ControlCancel(id: id).json)
        let cancelled = try await client.waitForReply(to: id, timeout: 3)
        try expect(cancelled.errorCode == ControlChannel.ErrorCode.cancelled && fixture.slowCancelled.isRaised, "cancel stops the tool and answers -32800: \(cancelled.json)")
        try client.notify("cancel", ControlCancel(id: 999).json)

        // Closing the connection cancels its calls.
        fixture.slowCancelled.reset()
        fixture.slowStarted.reset()
        _ = try client.send("call", ControlCall(tool: "slow_tool", arguments: ["seconds": 20]).json)
        try await waitUntil("the second slow call to start") { fixture.slowStarted.isRaised }
        try expect(server.runningCallCount == 1 && server.connectionCount == 1, "One call runs")
        client.close()
        try await waitUntil("the disconnect to cancel the tool") { fixture.slowCancelled.isRaised && server.connectionCount == 0 }
        try expect(server.runningCallCount == 0, "Nothing keeps running for a closed connection")

        // Cancelling while the approval prompt is up: the call ends, the prompt stays.
        fixture.approver.mode = .hold
        fixture.identity.value = AutomationClientIdentity(programPath: "/opt/other/codex")
        let waiting = try TestClient(path: fixture.socketPath)
        defer { waiting.close() }
        try await waiting.hello()
        let pendingID = try waiting.send("call", ControlCall(tool: "get_status").json)
        try await waitUntil("the prompt to show") { fixture.approver.heldCount == 1 }
        try waiting.notify("cancel", ControlCancel(id: pendingID).json)
        let withdrawn = try await waiting.waitForReply(to: pendingID)
        try expect(withdrawn.errorCode == ControlChannel.ErrorCode.cancelled && fixture.access.pendingRequests.count == 1, "The call is cancelled, the prompt stays: \(withdrawn.json)")
        fixture.approver.release(true)
        try await waitUntil("the late answer to be remembered") { fixture.store.approval(for: "path:/opt/other/codex") != nil }

        // Stopping (the app quitting) cancels running calls and hands back
        // their tasks, which end only once the tool has stopped.
        fixture.slowCancelled.reset()
        fixture.slowStarted.reset()
        let quitting = try TestClient(path: fixture.socketPath)
        defer { quitting.close() }
        try await quitting.hello()
        _ = try quitting.send("call", ControlCall(tool: "slow_tool", arguments: ["seconds": 20]).json)
        try await waitUntil("the slow call to start") { fixture.slowStarted.isRaised }
        let stopped = server.stop()
        try expect(stopped.count == 1, "stop returns the running call's task: \(stopped.count)")
        for task in stopped { await task.value }
        try expect(fixture.slowCancelled.isRaised, "The tool has stopped when its task ends")
        _ = try await quitting.waitForClose()
    }

    // MARK: - Peers

    private static func peers() async throws {
        let fixture = try await ServerFixture()
        defer { fixture.cleanup() }
        var options = ControlServer.Options()
        options.peerValidator = { _ in false }
        let server = fixture.makeServer(options: options)
        server.start()
        defer { server.stop() }
        let client = try TestClient(path: fixture.socketPath)
        _ = try? client.send("hello", ControlHello(helperVersion: "1", client: nil, workingDirectory: nil).json)
        let reason = try await client.waitForClose()
        try expect(client.messages.isEmpty && server.connectionCount == 0, "A refused peer is closed unanswered (\(reason))")

        let me = ControlPeer(uid: geteuid(), gid: getegid(), processID: getpid())
        try expect(ControlPeer.isSameUser(me) && !ControlPeer.isSameUser(ControlPeer(uid: geteuid() &+ 1, gid: getegid(), processID: 1))
                   && !ControlPeer.isSameUser(ControlPeer(uid: nil, gid: nil, processID: nil)), "Only this user's processes pass")
        var pair: [Int32] = [0, 0]
        try expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0, "socketpair")
        defer { close(pair[0]); close(pair[1]) }
        try expect(ControlPeer(fileDescriptor: pair[0]) == me, "A socket peer's uid, gid and pid (getpeereid, LOCAL_PEERPID)")
    }

    // MARK: - Connection limit

    private static func connectionLimit() async throws {
        let fixture = try await ServerFixture()
        defer { fixture.cleanup() }
        var options = ControlServer.Options()
        options.maximumConnections = 1
        let server = fixture.makeServer(options: options)
        server.start()
        defer { server.stop() }
        let first = try TestClient(path: fixture.socketPath)
        defer { first.close() }
        try await first.hello()
        // Over the limit: the hello is answered with an error the helper
        // shows the model ("Focus Studio refused the connection (…)"), then closed.
        let second = try TestClient(path: fixture.socketPath)
        defer { second.close() }
        let refused = try await second.request("hello", ControlHello(helperVersion: "9.9.9", client: nil, workingDirectory: nil).json)
        guard case let .error(_, error) = refused else { throw ServerFailure("Over the limit, hello is refused: \(refused.json)") }
        try expect(error.code == ControlChannel.ErrorCode.tooManyConnections && error.message.contains("AI tool sessions connected") && error.message.contains("Ask the person"),
                   "It says why: \(refused.json)")
        _ = try await second.waitForClose()
        try expect(server.connectionCount == 1, "The refused connection is not a session: \(server.connectionCount)")
        first.close()
        try await waitUntil("the first connection to close") { server.connectionCount == 0 }
        let third = try TestClient(path: fixture.socketPath)
        defer { third.close() }
        try await third.hello()
    }

    // MARK: - Socket files

    private static func socketHandling() async throws {
        let fixture = try await ServerFixture()
        defer { fixture.cleanup() }

        // A stale socket file (its server is gone) is replaced.
        try FileManager.default.createDirectory(atPath: fixture.socketDirectory, withIntermediateDirectories: true)
        try staleSocket(at: fixture.socketPath)
        let first = fixture.makeServer(appPath: "/First.app")
        first.start()
        try expect(first.state == .listening(fixture.socketPath), "A stale socket is replaced: \(first.state)")
        let client = try TestClient(path: fixture.socketPath)
        try expect(try await client.hello().appPath == "/First.app", "The new server answers")
        client.close()

        // A second copy waits while the first serves, even with its socket
        // file gone (the lock), then takes over when the first quits.
        var fast = ControlServer.Options()
        fast.retryInterval = 0.1
        let second = fixture.makeServer(appPath: "/Second.app", options: fast)
        second.start()
        try expect(second.state == .waitingForOtherInstance(fixture.socketPath), "A live owner makes the second wait: \(second.state)")
        unlink(fixture.socketPath)
        try await Task.sleep(for: .milliseconds(350))
        try expect(second.state == .waitingForOtherInstance(fixture.socketPath), "The lock keeps the second waiting: \(second.state)")
        first.stop()
        try await waitUntil("the second copy to take over") { second.state == .listening(fixture.socketPath) }
        let handedOver = try TestClient(path: fixture.socketPath)
        try expect(try await handedOver.hello().appPath == "/Second.app", "The second copy answers")
        handedOver.close()

        // stop removes the socket only if it is still its own.
        unlink(fixture.socketPath)
        try staleSocket(at: fixture.socketPath)
        let foreign = try inode(of: fixture.socketPath)
        second.stop()
        try expect((try? inode(of: fixture.socketPath)) == foreign, "A socket file that is not its own is left alone")
        unlink(fixture.socketPath)

        // The folder: created 0700 with missing parents, made private, never a symlink.
        let nested = fixture.root.appendingPathComponent("a/b/Control", isDirectory: true).path
        let created = fixture.makeServer(socketPath: nested + "/c.sock")
        created.start()
        try expect(created.state == .listening(nested + "/c.sock") && mode(of: nested) == 0o700, "A missing folder is created private")
        created.stop()
        chmod(nested, 0o777)
        let reopened = fixture.makeServer(socketPath: nested + "/c.sock")
        reopened.start()
        try expect(reopened.state == .listening(nested + "/c.sock") && mode(of: nested) == 0o700, "An open folder is made private again")
        reopened.stop()
        let target = fixture.root.appendingPathComponent("target", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        let link = fixture.root.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let linked = fixture.makeServer(socketPath: link + "/c.sock")
        linked.start()
        guard case let .failed(linkMessage) = linked.state, linkMessage.contains("symbolic link") else { throw ServerFailure("A symlinked folder is refused: \(linked.state)") }
        try expect(!FileManager.default.fileExists(atPath: target + "/c.sock"), "Nothing is created through the link")
        linked.stop()
        let plainPath = nested + "/plain.sock"
        try Data("not a socket".utf8).write(to: URL(fileURLWithPath: plainPath))
        let blocked = fixture.makeServer(socketPath: plainPath)
        blocked.start()
        guard case let .failed(plainMessage) = blocked.state, plainMessage.contains("not a socket") else { throw ServerFailure("A file at the socket path is refused: \(blocked.state)") }
        try expect((try? String(contentsOfFile: plainPath, encoding: .utf8)) == "not a socket", "and left alone")
        blocked.stop()
        let unusable = ControlServer(location: nil, unavailableReason: "no path", bridge: AutomationBridge(model: fixture.model), access: fixture.access, activity: fixture.activity, readiness: {})
        unusable.start()
        try expect(unusable.state == .failed("no path"), "Without a usable path the server reports why")
    }

    // MARK: - Approvals

    private static func approvals() async throws {
        let fixture = try await ServerFixture(approvalTimeout: 0.4, heartbeat: 0.05)
        defer { fixture.cleanup() }
        let server = fixture.makeServer()
        server.start()
        defer { server.stop() }
        // The program behind a connection is found once, when it connects.
        func connect(as identity: AutomationClientIdentity?) async throws -> TestClient {
            fixture.identity.value = identity
            let client = try TestClient(path: fixture.socketPath)
            try await client.hello(name: "codex-mcp-client")
            return client
        }
        func call(_ client: TestClient, _ token: AIJSONValue? = nil) async throws -> (message: ControlMessage, id: AIJSONValue) {
            let id = try client.send("call", ControlCall(tool: "get_status", progressToken: token).json)
            return (try await client.waitForReply(to: id, timeout: 5), id)
        }
        let codex = AutomationClientIdentity(programPath: "/Applications/ChatGPT.app/Contents/Resources/codex", teamIdentifier: "2DC432GLL2", signingIdentifier: "codex", signerName: "Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)")
        try expect(codex.key == "codesign:2DC432GLL2/codex" && codex.programName == "ChatGPT" && codex.signerDisplayName == "OpenAI OpCo, LLC (2DC432GLL2)", "A signed identity: \(codex)")
        let client = try await connect(as: codex)
        defer { client.close() }

        // Turned off: refused without asking.
        fixture.store.isEnabled = false
        let off = try await call(client).message.toolResult()
        try expect(off.isError && off.text == AutomationAccessController.disabledMessage(tool: "get_status") && fixture.approver.requests.isEmpty, "Off: \(off.text)")
        fixture.store.isEnabled = true

        // Declined: refused, and not asked again for a while.
        fixture.approver.mode = .deny
        let declined = try await call(client).message.toolResult()
        try expect(declined.isError && declined.text.contains("declined to let Codex control Focus Studio") && fixture.approver.requests.count == 1, "Declined: \(declined.text)")
        try expect(fixture.approver.requests[0].identity == codex && fixture.approver.requests[0].clientName == "Codex", "The prompt shows the program and the client's name")
        let again = try await call(client).message.toolResult()
        try expect(again.isError && fixture.approver.requests.count == 1 && fixture.store.declinedClients.map(\.identity.key) == [codex.key],
                   "A decline is remembered for now, not asked again: \(again.text) \(fixture.approver.requests.count) \(fixture.store.declinedClients.map(\.identity.key))")
        try expect(fixture.store.approval(for: codex.key) == nil, "and not remembered as an approval")
        fixture.store.forgetDecline(key: codex.key)

        // Timeout: heartbeat progress while waiting, then a clear refusal; the prompt stays and a late Allow counts.
        fixture.approver.mode = .hold
        let (timedOut, timedOutID) = try await call(client, "hb")
        let timedOutResult = try timedOut.toolResult()
        try expect(timedOutResult.isError && timedOutResult.text.contains("nobody answered within 0.4 seconds") && timedOutResult.text.contains("click Allow"), "Timed out: \(timedOutResult.text)")
        let beats = client.messages.compactMap { message -> ControlProgress? in
            guard case let .notification("progress", params) = message, params?["id"] == timedOutID else { return nil }
            return try? ControlProgress.decode(params)
        }
        try expect(beats.count >= 4 && zip(beats, beats.dropFirst()).allSatisfy { $0.progress < $1.progress } && beats.allSatisfy { $0.progress < 0.01 && ($0.message ?? "").contains("allow Codex") },
                   "Heartbeats while waiting: \(beats.map(\.progress))")
        try expect(fixture.access.pendingRequests.count == 1 && fixture.approver.heldCount == 1 && fixture.approver.requests.count == 2, "The prompt is still up")
        // A second call joins the same prompt (its first heartbeat shows it waits).
        let joinedID = try client.send("call", ControlCall(tool: "get_status", progressToken: "join").json)
        _ = try await client.waitFor("the joined call's first heartbeat") { message in
            if case let .notification("progress", params) = message { return params?["id"] == joinedID }
            return false
        }
        try expect(fixture.approver.requests.count == 2 && fixture.approver.heldCount == 1, "A waiting call joins the prompt on screen")
        fixture.approver.release(true)
        let joined = try await client.waitForReply(to: joinedID)
        try expect(!(try joined.toolResult().isError) && fixture.store.approval(for: codex.key) != nil, "The late Allow lets the waiting call run and is remembered: \(joined.json)")
        let approved = try await call(client).message.toolResult()
        try expect(!approved.isError && fixture.approver.requests.count == 2, "An approved client is not asked again")
        try expect(fixture.store.approval(for: codex.key)?.lastUsedAt != nil, "Use is recorded")

        // Another program is asked separately.
        fixture.approver.mode = .allow
        let other = try await connect(as: AutomationClientIdentity(programPath: "/usr/local/bin/other-client"))
        defer { other.close() }
        let otherResult = try await call(other).message.toolResult()
        try expect(!otherResult.isError && fixture.approver.requests.count == 3 && fixture.store.approvedClients.count == 2, "Another program is asked separately")

        // Revoke: asked again.
        fixture.store.revoke(key: codex.key)
        _ = try await call(client)
        try expect(fixture.approver.requests.count == 4 && fixture.store.approval(for: codex.key) != nil, "After Revoke the client is asked again")

        // Unidentified: refused.
        let anonymous = try await connect(as: nil)
        defer { anonymous.close() }
        let unidentified = try await call(anonymous).message.toolResult()
        try expect(unidentified.isError && unidentified.text == AutomationAccessController.unidentifiedMessage(tool: "get_status"), "Unidentified: \(unidentified.text)")

        // The switch and approvals persist in the preferences; declines do not.
        fixture.store.isEnabled = false
        fixture.store.decline(AutomationClientIdentity(programPath: "/bin/declined"), clientName: "x")
        let reloaded = AutomationAccessStore(defaults: fixture.defaults)
        try expect(!reloaded.isEnabled && Set(reloaded.approvedClients.map(\.identity.key)) == Set(fixture.store.approvedClients.map(\.identity.key))
                   && reloaded.approvedClients.first { $0.identity.key == codex.key }?.identity == codex && reloaded.declinedClients.isEmpty, "Persisted: \(reloaded.approvedClients.map(\.identity.key))")
        let emptySuite = fixture.suiteName + ".empty"
        try expect(AutomationAccessStore(defaults: UserDefaults(suiteName: emptySuite)!).isEnabled, "AI tools are allowed by default")
        UserDefaults(suiteName: emptySuite)?.removePersistentDomain(forName: emptySuite)
    }

    // MARK: - Generic hosts

    /// A shell or an interpreter runs many programs: approving node as such
    /// would approve every node program. Keyed by the script it runs; with
    /// no script, an approval (or a decline) holds for one connection only.
    private static func genericHostApprovals() async throws {
        let fixture = try await ServerFixture()
        defer { fixture.cleanup() }
        let server = fixture.makeServer()
        server.start()
        defer { server.stop() }
        func connect(as identity: AutomationClientIdentity) async throws -> TestClient {
            fixture.identity.value = identity
            let client = try TestClient(path: fixture.socketPath)
            try await client.hello(name: "claude-code")
            return client
        }
        func call(_ client: TestClient) async throws -> MCPToolCallResult {
            try await client.request("call", ControlCall(tool: "get_status").json).toolResult()
        }

        // Two node programs signed alike are two clients, one per script.
        let nodeA = AutomationClientIdentity(programPath: "/Users/me/.nvm/versions/node/v22.22.0/bin/node", teamIdentifier: "HX7739G8FX", signingIdentifier: "node", scriptPath: "/opt/a/node_modules/@acme/agent/cli.js")
        let nodeB = AutomationClientIdentity(programPath: "/Users/me/.nvm/versions/node/v16.13.0/bin/node", teamIdentifier: "HX7739G8FX", signingIdentifier: "node", scriptPath: "/opt/b/server.js")
        try expect(nodeA.key == "codesign:HX7739G8FX/node|script:/opt/a/node_modules/@acme/agent/cli.js" && nodeA.isRememberable && nodeA.programName == "@acme/agent (node)",
                   "A node program is keyed by its script: \(nodeA.key) \(nodeA.programName)")
        let a = try await connect(as: nodeA)
        defer { a.close() }
        try expect(!(try await call(a)).isError && fixture.approver.requests.count == 1 && fixture.store.approval(for: nodeA.key) != nil, "The first node program is approved and remembered")
        let b = try await connect(as: nodeB)
        defer { b.close() }
        try expect(!(try await call(b)).isError && fixture.approver.requests.count == 2 && fixture.approver.requests[1].identity == nodeB,
                   "Another node program is asked for itself: \(fixture.approver.requests.map(\.identity.key))")

        // A shell with no script: allowed for that connection only, never remembered.
        let shell = AutomationClientIdentity(programPath: "/bin/zsh")
        try expect(shell.isGenericHost && !shell.isRememberable && shell.key == "path:/bin/zsh", "An interactive shell or zsh -c is not remembered")
        let first = try await connect(as: shell)
        defer { first.close() }
        try expect(!(try await call(first)).isError && fixture.approver.requests.count == 3 && !fixture.approver.requests[2].isRemembered, "The shell's connection is asked, as not remembered")
        try expect(!(try await call(first)).isError && fixture.approver.requests.count == 3, "Its later calls on that connection are allowed")
        try expect(fixture.store.approval(for: shell.key) == nil && fixture.store.approvedClients.count == 2, "Nothing is remembered for the shell")
        let second = try await connect(as: shell)
        defer { second.close() }
        fixture.approver.mode = .deny
        let refused = try await call(second)
        try expect(refused.isError && refused.text.contains("declined") && fixture.approver.requests.count == 4, "A new connection from the same shell is asked again: \(refused.text)")
        _ = try await call(second)
        try expect(fixture.approver.requests.count == 4 && fixture.store.declinedClients.isEmpty, "A decline holds for that connection, and is not kept for the shell")
        fixture.approver.mode = .allow
        let third = try await connect(as: shell)
        defer { third.close() }
        try expect(!(try await call(third)).isError && fixture.approver.requests.count == 5, "and a later connection can still be allowed")
        fixture.store.approve(shell, clientName: "Claude Code")
        try expect(fixture.store.approval(for: shell.key) == nil, "The store never remembers a shell")

        // An approval of a generic host saved by an earlier version is dropped on load.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let saved = [ApprovedAutomationClient(identity: shell, clientName: "Claude Code", approvedAt: Date(), lastUsedAt: nil),
                     ApprovedAutomationClient(identity: AutomationClientIdentity(programPath: "/opt/homebrew/bin/node"), clientName: "x", approvedAt: Date(), lastUsedAt: nil),
                     ApprovedAutomationClient(identity: nodeA, clientName: "Agent", approvedAt: Date(), lastUsedAt: nil)]
        fixture.defaults.set(try encoder.encode(saved), forKey: AutomationAccessStore.approvedClientsKey)
        try expect(AutomationAccessStore(defaults: fixture.defaults).approvedClients.map(\.identity.key) == [nodeA.key], "Only the script-keyed approval survives a reload")
    }

    /// A navigating call can wait its turn for minutes; turning AI tools off
    /// or revoking the client meanwhile stops it before its tool runs.
    private static func accessCheckedBeforeRunning() async throws {
        let fixture = try await ServerFixture()
        defer { fixture.cleanup() }
        let server = fixture.makeServer()
        server.start()
        defer { server.stop() }
        let client = try TestClient(path: fixture.socketPath)
        defer { client.close() }
        try await client.hello()
        _ = try await client.request("call", ControlCall(tool: "get_status").json)
        guard let identity = fixture.identity.value, fixture.store.approval(for: identity.key) != nil else { throw ServerFailure("The client is approved first") }

        for change in ["revoke", "off"] {
            fixture.navStarted.reset()
            let holding = try client.send("call", ControlCall(tool: "slow_nav", arguments: ["seconds": 0.6]).json)
            try await waitUntil("slow_nav to hold the queue") { fixture.navStarted.isRaised }
            let deleting = try client.send("call", ControlCall(tool: "delete_project", arguments: ["project_id": AIJSONValue(fixture.project.id.uuidString)]).json)
            try await waitUntil("delete_project to wait its turn") { server.bridge.queue.waitingCount == 1 }
            if change == "revoke" { fixture.store.revoke(key: identity.key) } else { fixture.store.isEnabled = false }
            let deleted = try await client.waitForReply(to: deleting).toolResult()
            let expected = change == "revoke"
                ? AutomationAccessController.revokedMessage(client: "Claude Code", tool: "delete_project")
                : AutomationAccessController.disabledMessage(tool: "delete_project")
            try expect(deleted.isError && deleted.text == expected, "After \(change), the queued delete_project does not run: \(deleted.text)")
            try expect(fixture.model.project(id: fixture.project.id) != nil && fixture.model.projects.count == 1, "The project is still in the library (\(change))")
            _ = try await client.waitForReply(to: holding)
            fixture.store.isEnabled = true
            fixture.store.approve(identity, clientName: "Claude Code")
        }
    }

    /// The script behind a real shell process, and none for zsh -c.
    private static func genericHostIdentity() async throws {
        try expect(AutomationClientIdentity.scriptArgument(in: ["node", "--no-warnings", "/a/cli.js", "--flag"]) == "/a/cli.js"
                   && AutomationClientIdentity.scriptArgument(in: ["node", "--import", "tsx", "src/run.ts"]) == "src/run.ts"
                   && AutomationClientIdentity.scriptArgument(in: ["node", "-r", "pre.js", "main.js"]) == "main.js"
                   && AutomationClientIdentity.scriptArgument(in: ["python3", "-u", "./s.py"]) == "./s.py"
                   && AutomationClientIdentity.scriptArgument(in: ["bash", "--", "-s.sh"]) == "-s.sh"
                   && AutomationClientIdentity.scriptArgument(in: ["zsh", "-l", "run.sh"]) == "run.sh", "Script arguments")
        for inline in [["zsh"], ["-zsh"], ["zsh", "-c", "x"], ["zsh", "-lc", "x"], ["python3", "-m", "pkg"], ["python3", "-c", "x"], ["node", "-e", "x"], ["node", "--eval=x"], ["bash", "-s"], ["sh", "-"], ["node"]] {
            try expect(AutomationClientIdentity.scriptArgument(in: inline) == nil, "No script: \(inline)")
        }
        for (path, identifier) in [("/bin/zsh", nil), ("/opt/homebrew/Cellar/python@3.13/3.13.7/bin/python3.13", nil), ("/usr/bin/perl5.34", nil),
                                   ("/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python", "com.apple.python3"),
                                   ("/usr/local/bin/renamed", "com.apple.zsh"), ("/usr/bin/env", nil), ("/Users/me/.bun/bin/bun", nil)] {
            try expect(AutomationClientIdentity.isGenericHost(programPath: path, signingIdentifier: identifier), "Generic host: \(path)")
        }
        for (path, identifier) in [("/Users/me/Library/Application Support/Claude/claude-code/2.1.280/claude.app/Contents/MacOS/claude", "com.anthropic.claude-code"),
                                   ("/Applications/ChatGPT.app/Contents/Resources/codex", "codex"), ("/usr/local/bin/codex", nil)] {
            try expect(!AutomationClientIdentity.isGenericHost(programPath: path, signingIdentifier: identifier), "A specific program: \(path)")
        }
        try expect(!AutomationClientIdentity(programPath: "/opt/homebrew/bin/node", scriptPath: "/opt/homebrew/lib/node_modules/npm/bin/npx-cli.js").isRememberable,
                   "npx run by node is a launcher too")
        try expect(AutomationClientIdentity.programName(forPath: "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python") == "Python",
                   "The innermost app names a nested Python.app")

        // Real processes: zsh running a script, and zsh -c.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("fsh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("host.sh")
        try Data("sleep 5; :\n".utf8).write(to: script)
        func start(_ arguments: [String]) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = arguments
            process.currentDirectoryURL = folder
            try process.run()
            return process
        }
        let scripted = try start(["host.sh"])
        let inline = try start(["-c", "sleep 5; :"])
        defer {
            scripted.terminate()
            inline.terminate()
        }
        // realpath, not resolvingSymlinksInPath (which turns /private/var back into /var).
        guard let resolved = realpath(script.path, nil) else { throw ServerFailure("realpath \(script.path)") }
        let realScript = String(cString: resolved)
        free(resolved)
        var withScript: AutomationClientIdentity?
        try await waitUntil("zsh to run its script") {
            withScript = AutomationClientIdentity.program(processID: scripted.processIdentifier)
            return withScript?.scriptPath != nil
        }
        guard let withScript else { throw ServerFailure("zsh host.sh resolves") }
        try expect(withScript.isGenericHost && withScript.scriptPath == realScript && withScript.isRememberable
                   && withScript.key == "\(withScript.key.components(separatedBy: "|script:")[0])|script:\(realScript)" && withScript.programName == "host.sh (zsh)",
                   "zsh host.sh is keyed by its script: \(withScript.key)")
        guard let withoutScript = AutomationClientIdentity.program(processID: inline.processIdentifier) else { throw ServerFailure("zsh -c resolves") }
        try expect(withoutScript.isGenericHost && withoutScript.scriptPath == nil && !withoutScript.isRememberable && !withoutScript.key.contains("|script:"),
                   "zsh -c runs no script: \(withoutScript.key)")
    }

    // MARK: - Identity

    private static func parentIdentity() throws {
        let me = getpid()
        try expect(AutomationClientIdentity.parentProcessID(of: me) == getppid(), "The parent pid of this process")
        let ownPath = AutomationClientIdentity.executablePath(of: me)
        try expect(ownPath == Bundle.main.executableURL?.resolvingSymlinksInPath().path, "This process's executable: \(ownPath ?? "nil")")
        guard let parent = AutomationClientIdentity.resolve(helperPID: me) else { throw ServerFailure("The program that started this process resolves") }
        try expect(parent.programPath == AutomationClientIdentity.executablePath(of: getppid()) && !parent.programName.isEmpty, "The parent program: \(parent)")
        // The parent is usually zsh running scripts/test-app-regression.sh: keyed by that script.
        let script = parent.scriptPath.map { "|script:\($0)" } ?? ""
        try expect(parent.scriptPath == nil || parent.isGenericHost, "Only a generic host has a script: \(parent)")
        if let team = parent.teamIdentifier, let identifier = parent.signingIdentifier {
            try expect(parent.key == "codesign:\(team)/\(identifier)\(script)", "A signed parent is keyed by its signature: \(parent.key)")
        } else {
            try expect(parent.key == "path:\(parent.programPath)\(script)", "An unsigned or Apple-platform parent is keyed by its path: \(parent.key)")
        }
        try expect(AutomationClientIdentity.signingIdentity(of: me) == nil, "The ad-hoc signed test binary has no Team ID signature")
        try expect(AutomationClientIdentity.resolve(helperPID: 1) == nil, "An orphaned helper (parent launchd) is not identified")
        try expect(AutomationClientIdentity.parentProcessID(of: 999_999) == nil && AutomationClientIdentity.executablePath(of: 999_999) == nil, "A process that does not exist")
        try expect(AutomationClientIdentity.programName(forPath: "/Users/me/.local/share/claude/versions/2.1.278") == "claude"
                   && AutomationClientIdentity.programName(forPath: "/Applications/ChatGPT.app/Contents/Resources/codex") == "ChatGPT"
                   && AutomationClientIdentity.programName(forPath: "/usr/bin/python3") == "python3", "Program names")
        try expect(AutomationClientIdentity(programPath: "/x/claude", teamIdentifier: nil, signingIdentifier: "com.adhoc").key == "path:/x/claude", "An identifier without a Team ID never keys an approval")
    }

    // MARK: - Helpers

    static func mode(of path: String) -> mode_t {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return info.st_mode & 0o777
    }

    static func inode(of path: String) throws -> ino_t {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw ServerFailure("No file at \(path)") }
        return info.st_ino
    }

    /// A socket file whose server is gone: bound, never listening, closed.
    static func staleSocket(at path: String) throws {
        let descriptor = try ControlSocket.makeSocket()
        defer { close(descriptor) }
        var address = try ControlSocket.address(for: path)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { throw ServerFailure("Could not bind \(path)") }
    }

    static func waitUntil(_ message: String, timeout: TimeInterval = 5, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { throw ServerFailure("Timed out waiting for \(message)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw ServerFailure(message) }
    }
}

// MARK: - Fixtures

struct ServerFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A thread-safe flag.
final class ServerFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isRaised: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
    func reset() { lock.withLock { raised = false } }
}

/// A value shared with the server's identity resolver (another thread).
final class IdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AutomationClientIdentity?
    init(_ value: AutomationClientIdentity?) { stored = value }
    var value: AutomationClientIdentity? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor
final class ReadinessGate {
    private var isOpen = false
    func open() { isOpen = true }
    func wait() async {
        while !isOpen { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Answers approval prompts from the test: allow, deny, or hold until released.
@MainActor
final class ScriptedApprover {
    enum Mode { case allow, deny, hold }
    var mode = Mode.allow
    private(set) var requests: [AutomationApprovalRequest] = []
    private var held: [CheckedContinuation<Bool, Never>] = []

    var heldCount: Int { held.count }

    func approve(_ request: AutomationApprovalRequest) async -> Bool {
        requests.append(request)
        switch mode {
        case .allow: return true
        case .deny: return false
        case .hold: return await withCheckedContinuation { held.append($0) }
        }
    }

    func release(_ allowed: Bool) {
        let waiting = held
        held.removeAll()
        waiting.forEach { $0.resume(returning: allowed) }
    }
}

/// Sleeps for `seconds`, reporting progress every 0.1 s; notes that it
/// started and whether it was cancelled.
private struct SlowServerTool: AIAssistantTool {
    var name = "slow_tool"
    let summary = "Sleep."
    let started: ServerFlag
    let cancelled: ServerFlag
    var parametersSchema: [String: Any] { ["type": "object", "properties": ["seconds": ["type": "number"]]] }

    func run(arguments: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        started.raise()
        let seconds = (arguments["seconds"] as? NSNumber)?.doubleValue ?? 1
        let steps = max(1, Int(seconds * 10))
        do {
            for step in 1...steps {
                try await Task.sleep(for: .milliseconds(100))
                context.numericProgress?(Double(step) / Double(steps), 1, nil)
            }
        } catch {
            cancelled.raise()
            throw error
        }
        return AIToolResult(text: "Slept.", data: ["seconds": AIJSONValue(seconds)])
    }
}

/// A temporary library with one project, a model, a private socket folder,
/// an approval store in its own preferences domain and a scripted approver.
@MainActor
final class ServerFixture {
    let root: URL
    let cwd: URL
    let socketDirectory: String
    let socketPath: String
    let model: StudioModel
    let project: RecordingProject
    let suiteName: String
    let defaults: UserDefaults
    let store: AutomationAccessStore
    let approver = ScriptedApprover()
    let access: AutomationAccessController
    let activity = AutomationActivity()
    let identity = IdentityBox(AutomationClientIdentity(programPath: "/usr/local/bin/claude-test"))
    let slowStarted = ServerFlag()
    let slowCancelled = ServerFlag()
    /// slow_nav: like slow_tool, but it navigates, so it holds the call queue.
    let navStarted = ServerFlag()
    let navCancelled = ServerFlag()

    init(approvalTimeout: TimeInterval = 5, heartbeat: TimeInterval = 0.05) async throws {
        let fileManager = FileManager.default
        // Short: a socket path must fit in 103 bytes.
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("fsc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        cwd = root.appendingPathComponent("client", isDirectory: true)
        socketDirectory = root.appendingPathComponent("Control", isDirectory: true).path
        socketPath = socketDirectory + "/control.sock"
        try fileManager.createDirectory(at: cwd, withIntermediateDirectories: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        let store = ProjectStore(projectsDirectory: root.appendingPathComponent("Projects", isDirectory: true), trashOperation: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
        model = StudioModel(store: store, interactionTrackingAccess: { true }, inputMonitoringAccess: { true }, screenCaptureAccess: { true })
        let image = cwd.appendingPathComponent("shot.png")
        try Self.writeImage(to: image)
        let clip = cwd.appendingPathComponent("clip.mp4")
        _ = try await StillImageVideoBuilder.build(from: image, to: clip, duration: 1, renderSize: CGSize(width: 64, height: 64))
        project = try await store.createProject(from: clip, title: "Served", cursorSamples: [], clickEvents: [])
        await model.reloadProjects()
        // A preferences file inside the temporary folder (a suite named by an
        // absolute path), so nothing lands in ~/Library/Preferences.
        let preferences = root.appendingPathComponent("Preferences", isDirectory: true)
        try fileManager.createDirectory(at: preferences, withIntermediateDirectories: true)
        suiteName = preferences.appendingPathComponent("app.focusstudio.control-tests").path
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw ServerFailure("No test preferences") }
        self.defaults = defaults
        self.store = AutomationAccessStore(defaults: defaults)
        let approver = self.approver
        access = AutomationAccessController(store: self.store, timeout: approvalTimeout, heartbeatInterval: heartbeat) { request in
            await approver.approve(request)
        }
    }

    func makeServer(
        socketPath: String? = nil,
        appPath: String = "/Applications/Focus Studio Test.app",
        options: ControlServer.Options? = nil,
        readiness: (@MainActor () async -> Void)? = nil,
        presentWindow: (@MainActor () -> Void)? = nil
    ) -> ControlServer {
        let slow = MCPToolSpec(tool: SlowServerTool(started: slowStarted, cancelled: slowCancelled), title: "Slow", description: "Sleeps, reporting progress.", scope: .global, annotations: .reads)
        let navigating = MCPToolSpec(tool: SlowServerTool(name: "slow_nav", started: navStarted, cancelled: navCancelled), title: "Slow navigating", description: "Sleeps holding the call queue.",
                                     scope: .global, annotations: MCPToolAnnotations(readOnly: false, idempotent: true), navigates: true)
        let bridge = AutomationBridge(model: model, catalog: MCPToolCatalog(tools: MCPToolCatalog.v1.tools + [slow, navigating]))
        bridge.presentWindow = presentWindow
        var configured = options ?? ControlServer.Options()
        let identity = self.identity
        configured.identityResolver = { _ in identity.value }
        let model = self.model
        return ControlServer(
            location: ControlSocketLocation(path: socketPath ?? self.socketPath, source: .environment),
            bridge: bridge,
            access: access,
            activity: activity,
            appInfo: ControlAppInfo(version: "1.5.0-test", path: appPath, processID: getpid()),
            options: configured,
            readiness: readiness ?? { await model.bootstrap() }
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private static func writeImage(to url: URL) throws {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ServerFailure("Could not create a bitmap context")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ServerFailure("Could not encode the fixture image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ServerFailure("Could not write the fixture image") }
    }
}

/// A helper's end of the control channel, for tests.
final class TestClient: @unchecked Sendable {
    let connection: ControlConnection
    private let lock = NSLock()
    private var inbox: [ControlMessage] = []
    private var closeReason: ControlConnection.CloseReason?
    private var nextID = 0

    init(path: String) throws {
        connection = ControlConnection(fileDescriptor: try ControlSocket.connect(to: path), label: "test.client")
        connection.start(onLine: { [weak self] line in
            guard let self, let message = try? ControlMessage.decode(line) else { return }
            self.lock.withLock { self.inbox.append(message) }
        }, onClose: { [weak self] reason in
            guard let self else { return }
            self.lock.withLock { self.closeReason = reason }
        })
    }

    var messages: [ControlMessage] { lock.withLock { inbox } }

    @discardableResult
    func send(_ method: String, _ params: AIJSONValue?, id: AIJSONValue? = nil) throws -> AIJSONValue {
        let requestID = id ?? lock.withLock { () -> AIJSONValue in
            nextID += 1
            return AIJSONValue(nextID)
        }
        try connection.send(.request(id: requestID, method: method, params: params))
        return requestID
    }

    func notify(_ method: String, _ params: AIJSONValue?) throws {
        try connection.send(.notification(method: method, params: params))
    }

    func reply(to id: AIJSONValue) -> ControlMessage? {
        messages.first { message in
            switch message {
            case .result, .error: return message.id == id
            default: return false
            }
        }
    }

    func request(_ method: String, _ params: AIJSONValue?, timeout: TimeInterval = 5) async throws -> ControlMessage {
        try await waitForReply(to: try send(method, params), timeout: timeout)
    }

    func waitForReply(to id: AIJSONValue, timeout: TimeInterval = 5) async throws -> ControlMessage {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let reply = reply(to: id) { return reply }
            if Date() > deadline { throw ServerFailure("No reply to \(id); got \(messages.map(\.json))") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The latest message matching `predicate`, once there is one.
    func waitFor(_ what: String, timeout: TimeInterval = 5, _ predicate: (ControlMessage) -> Bool) async throws -> ControlMessage {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let match = messages.last(where: predicate) { return match }
            if Date() > deadline { throw ServerFailure("Timed out waiting for \(what); got \(messages.map(\.json))") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @discardableResult
    func hello(name: String = "claude-code") async throws -> ControlHelloReply {
        let reply = try await request("hello", ControlHello(helperVersion: "9.9.9", client: ControlClientInfo(name: name, version: "1.0"), workingDirectory: "/tmp").json)
        return try ControlHelloReply.decode(reply.resultValue)
    }

    func waitForClose(timeout: TimeInterval = 5) async throws -> ControlConnection.CloseReason {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let reason = lock.withLock({ closeReason }) { return reason }
            if Date() > deadline { throw ServerFailure("The connection did not close") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func close() { connection.close() }
}

extension ControlMessage {
    var errorCode: Int? {
        if case let .error(_, error) = self { return error.code }
        return nil
    }

    var resultValue: AIJSONValue? {
        if case let .result(_, value) = self { return value }
        return nil
    }

    func toolResult() throws -> MCPToolCallResult {
        guard let value = resultValue, let result = MCPToolCallResult(json: value) else { throw ServerFailure("Not a tool result: \(json)") }
        return result
    }
}
