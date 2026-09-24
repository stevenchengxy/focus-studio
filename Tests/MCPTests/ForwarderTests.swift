import Darwin
import FocusStudioAutomation
import Foundation

/// SocketAppForwarder, the helper's end of the control channel, against an
/// in-process fake of Focus Studio's control server on a real Unix socket
/// (FakeControlApp) and a scripted launcher in place of NSWorkspace: settings
/// from the environment, hello, calls and their replies, progress, unknown
/// tools, the app quitting mid-call and reconnecting, protocol mismatch, hello
/// refused or late (with heartbeat progress), opening the app (once for
/// concurrent calls, with only the allowed environment, heartbeats while it
/// starts, refused, too slow, still pending, already running, opened again
/// after it quit, not opened while AI tools are off or another copy runs),
/// cancellation (during a call, while waiting for the app,
/// unanswered) and shutdown. Nothing is really launched.
extension MCPTests {
    // MARK: - Settings

    static func forwarderSettings() throws {
        let installed = HelperIdentity(name: "focus-studio", title: "Focus Studio", version: "1.5.0", appURL: URL(fileURLWithPath: "/Applications/Focus Studio.app"))
        let development = HelperIdentity.resolve(bundle: .main)
        check(AppConnectionSettings(environment: [:], identity: installed).launch == .app(URL(fileURLWithPath: "/Applications/Focus Studio.app")), "The helper opens the app it ships in")
        for value in ["1", "true", "YES", " 1 "] {
            check(AppConnectionSettings(environment: ["FOCUS_STUDIO_MCP_NO_LAUNCH": value], identity: installed).launch == .disabled, "NO_LAUNCH=\(value) turns launching off")
        }
        for value in ["0", "", "no"] {
            check(AppConnectionSettings(environment: ["FOCUS_STUDIO_MCP_NO_LAUNCH": value], identity: installed).launch != .disabled, "NO_LAUNCH=\(value) leaves launching on")
        }
        guard case let .unavailable(reason) = AppConnectionSettings(environment: [:], identity: development).launch else {
            fatalError("FAIL: a helper outside the app has nothing to open")
        }
        check(reason.contains("FOCUS_STUDIO_APP_PATH"), "It says how to name an app: \(reason)")

        // FOCUS_STUDIO_APP_PATH must be a Focus Studio.app.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fs-fwset-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func bundle(_ name: String, identifier: String) throws -> URL {
            let app = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents", isDirectory: true), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.5.0"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app
        }
        let good = try bundle("Focus Studio QA.app", identifier: HelperIdentity.appBundleIdentifier)
        let other = try bundle("Other.app", identifier: "com.example.other")
        check(AppConnectionSettings(environment: ["FOCUS_STUDIO_APP_PATH": good.path], identity: installed).launch == .app(good.standardizedFileURL), "FOCUS_STUDIO_APP_PATH wins over the enclosing app")
        check(AppConnectionSettings(environment: ["FOCUS_STUDIO_APP_PATH": good.path], identity: development).launch == .app(good.standardizedFileURL), "and gives a development build an app")
        for (path, expected) in [(other.path, "not a Focus Studio.app"), (folder.appendingPathComponent("Missing.app").path, "not a Focus Studio.app"), ("Focus Studio.app", "absolute path")] {
            guard case let .unavailable(reason) = AppConnectionSettings(environment: ["FOCUS_STUDIO_APP_PATH": path], identity: installed).launch else {
                fatalError("FAIL: \(path) must be refused")
            }
            check(reason.contains(expected), "\(path): \(reason)")
        }
        check(AppConnectionSettings(environment: ["FOCUS_STUDIO_APP_PATH": good.path, "FOCUS_STUDIO_MCP_NO_LAUNCH": "1"], identity: installed).launch == .disabled, "NO_LAUNCH wins")

        // The socket, and what an opened app gets from the environment.
        let environment = ["FOCUS_STUDIO_CONTROL_SOCKET": "/tmp/fs-qa.sock", "FOCUS_STUDIO_OPEN_SETTINGS": "1", "PATH": "/usr/bin", "HOME": "/Users/nobody"]
        let debugSettings = AppConnectionSettings(environment: environment, identity: installed, includeTestVariables: true)
        check(debugSettings.socket == .success(ControlSocketLocation(path: "/tmp/fs-qa.sock", source: .environment)), "The socket override: \(debugSettings.socket)")
        check(debugSettings.launchEnvironment == ["FOCUS_STUDIO_CONTROL_SOCKET": "/tmp/fs-qa.sock"], "A development build passes on only the socket override: \(debugSettings.launchEnvironment)")
        check(AppConnectionSettings(environment: environment, identity: installed, includeTestVariables: false).launchEnvironment.isEmpty, "A release build passes on nothing")
        check(AppConnectionSettings(environment: ["FOCUS_STUDIO_CONTROL_SOCKET": "relative.sock"], identity: installed).socket == .failure(.relativeSocketPath("relative.sock")), "A relative override is unusable")
        check(!WorkspaceAppLauncher().isRunning(appAt: folder.appendingPathComponent("Nothing.app")), "An app that does not run is not running")
    }

    // MARK: - Calls

    static func forwarderCalls() async throws {
        let folder = try socketFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/app.sock"
        let forwarder = makeForwarder(socket: path)

        // Nothing listening, then a stale socket file: with launching off, not reachable.
        let unreachable = UnreachableAppForwarder.message(for: "get_status")
        try await expectFailure(forwarder, forwarded("get_status"), equals: unreachable, "No socket file")
        try bindWithoutListening(path)
        try await expectFailure(forwarder, forwarded("get_status"), equals: unreachable, "A stale socket file")
        unlink(path)

        let app = FakeControlApp(path: path)
        try app.start()
        defer { app.quit() }
        let zoomArguments: [String: AIJSONValue] = ["project_id": "8C0F4E4A-2B0A-4F3E-9C55-6A1B2C3D4E5F", "start": 1, "end": 2.5, "x": 0.5, "y": 0.25, "label": "data:,tok"]
        let zoom = await forwarder.forward(forwarded("add_zoom", zoomArguments))
        guard case let .result(zoomResult) = zoom, !zoomResult.isError else { fatalError("FAIL: add_zoom is answered: \(zoom)") }
        check(zoomResult.text == "add_zoom done" && zoomResult.structuredContent?["tool"] == "add_zoom", "The app's result comes back as sent: \(zoomResult.json)")
        let first = app.received
        guard case let .request(helloID, "hello", helloParams)? = first.first?.message, let hello = try? ControlHello.decode(helloParams) else {
            fatalError("FAIL: hello comes first: \(first.map(\.message.json))")
        }
        check(helloID.intValue != nil, "Request ids are the helper's integers")
        check(hello == ControlHello(helperVersion: "7.7.7-test", client: ControlClientInfo(name: "claude-code", version: "2.1.0", title: "Claude Code"), workingDirectory: "/tmp/client-cwd"),
              "hello names the protocol, helper, client and working directory: \(helloParams ?? .null)")
        guard case let .request(_, "call", callParams)? = first.last?.message, var call = try? ControlCall.decode(callParams) else { fatalError("FAIL: then the call") }
        // The seconds since the tools/call reached the helper: connecting and hello here.
        check(call.elapsed.map { $0 >= 0 && $0 < 3 } == true, "The call carries the helper's own time: \(callParams ?? .null)")
        call.elapsed = nil
        check(call == ControlCall(tool: "add_zoom", arguments: zoomArguments, workingDirectory: "/tmp/client-cwd", progressToken: nil),
              "The call carries the tool, the arguments exactly, the working directory and no progress token: \(callParams ?? .null)")
        check(callParams?.objectValue.map { !$0.keys.contains("progress_token") } == true, "not even a null one: \(callParams ?? .null)")
        // A call that waited in the helper (opening the app, connecting) says how long.
        var waited = forwarded("get_status")
        waited.receivedAt = .now - .seconds(3)
        guard case let .result(waitedResult) = await forwarder.forward(waited), !waitedResult.isError, let sentElapsed = app.calls.last?.elapsed else {
            fatalError("FAIL: a call that waited in the helper is answered and carries elapsed")
        }
        check(sentElapsed >= 3 && sentElapsed < 5, "elapsed counts from the tools/call's arrival at the helper: \(sentElapsed)")

        // Calls share the connection, also when they run at the same time.
        let answers = await withTaskGroup(of: AutomationCallResult.self) { group in
            for index in 0..<6 {
                group.addTask { await forwarder.forward(forwarded("get_status", sequence: index)) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        check(answers.count == 6 && answers.allSatisfy { if case let .result(result) = $0 { return !result.isError } else { return false } }, "Concurrent calls: \(answers)")
        check(app.acceptedCount == 1 && forwarder.isConnected, "One connection for all of them: \(app.acceptedCount)")

        // Progress, only for a call that asked for it.
        let progress = LockedList<Double>()
        let export = await forwarder.forward(forwarded("export_project", ["project_id": "8C0F4E4A-2B0A-4F3E-9C55-6A1B2C3D4E5F"]) { value, total, _ in
            progress.append(value)
            check(total == 1, "The total comes along")
        })
        guard case let .result(exportResult) = export, !exportResult.isError else { fatalError("FAIL: export: \(export)") }
        check(progress.items == [0.25, 0.5, 1], "The app's progress arrives in order, before the result: \(progress.items)")
        check(app.calls.last?.progressToken?.intValue != nil, "A call with a progress handler carries a token: \(String(describing: app.calls.last?.progressToken))")

        // An unknown tool (an older app) is -32602 for the client.
        let assets = await forwarder.forward(forwarded("list_assets"))
        check(assets == .unknownTool("list_assets"), "The app does not know list_assets: \(assets)")

        // The app quitting mid-call: an isError, no retry; the next call connects again.
        let stop = await forwarder.forward(forwarded("stop_recording"))
        guard case let .result(stopResult) = stop, stopResult.isError else { fatalError("FAIL: a call cut short is an error: \(stop)") }
        check(stopResult.text.hasPrefix("Focus Studio quit before stop_recording finished; check get_status/list_projects"), "It says the app quit: \(stopResult.text)")
        check(app.calls.filter { $0.tool == "stop_recording" }.count == 1, "The call is not retried")
        try await waitFor("the helper to notice the closed connection") { !forwarder.isConnected }
        guard case let .result(again) = await forwarder.forward(forwarded("get_status")), !again.isError else { fatalError("FAIL: the next call reconnects") }
        check(app.acceptedCount == 2, "A second connection, with its own hello: \(app.acceptedCount)")
        check(app.received.filter { $0.connection == 2 }.first?.message.method == "hello", "hello again on the new connection")

        // A late hello: heartbeat progress while waiting, then the call.
        let slowPath = folder + "/slow.sock"
        let slow = FakeControlApp(path: slowPath, options: .init(helloDelay: 0.6))
        try slow.start()
        defer { slow.quit() }
        let heartbeats = LockedList<(Double, String?)>()
        let slowAnswer = await makeForwarder(socket: slowPath).forward(forwarded("get_status") { value, total, message in
            heartbeats.append((value, message))
            check(total == nil, "Heartbeats have no total")
        })
        guard case let .result(slowResult) = slowAnswer, !slowResult.isError else { fatalError("FAIL: a late hello still leads to the call: \(slowAnswer)") }
        let beats = heartbeats.items
        check(beats.count >= 3 && zip(beats, beats.dropFirst()).allSatisfy { $0.0 < $1.0 } && beats.allSatisfy { $0.0 > 0 && $0.0 < 0.0001 },
              "Tiny increasing heartbeats below the app's own: \(beats.map(\.0))")
        check(beats.allSatisfy { $0.1 == "Waiting for Focus Studio to load its library…" }, "saying what the call waits for: \(beats.map(\.1))")
        // The wait for hello is part of the helper's own time the call reports.
        let slowElapsed = slow.calls.last?.elapsed ?? 0
        check(slowElapsed >= 0.6 && slowElapsed < 5, "elapsed includes the wait for hello: \(slowElapsed)")

        // Another protocol: an isError naming the copy that runs; the connection is closed and the next call tries again.
        let oldPath = folder + "/old.sock"
        let old = FakeControlApp(path: oldPath, options: .init(protocolVersion: 2, appPath: "/Applications/Focus Studio Old.app"))
        try old.start()
        defer { old.quit() }
        let oldForwarder = makeForwarder(socket: oldPath)
        let mismatch = try await failureText(oldForwarder, forwarded("get_status"))
        check(mismatch.contains("(/Applications/Focus Studio Old.app, version 9.9.9-fake) speaks control protocol 2") && mismatch.contains("this focus-studio-mcp (version 7.7.7-test at /tmp/focus-studio-mcp-test) speaks protocol 1")
              && mismatch.contains("get_status did not run"), "Protocol mismatch: \(mismatch)")
        try await waitFor("the mismatched connection to close") { old.closedCount == 1 }
        check(old.calls.isEmpty && !oldForwarder.isConnected, "No call is sent to it")
        _ = try await failureText(oldForwarder, forwarded("get_status"))
        check(old.acceptedCount == 2, "The next call tries again")

        // hello refused, or never answered.
        let refusingPath = folder + "/refuse.sock"
        let refusing = FakeControlApp(path: refusingPath, options: .init(helloError: "Invalid params: missing \"helper_version\"."))
        try refusing.start()
        defer { refusing.quit() }
        let refused = try await failureText(makeForwarder(socket: refusingPath), forwarded("get_status"))
        check(refused.hasPrefix("Focus Studio refused the connection (Invalid params: missing \"helper_version\".)"), "hello refused: \(refused)")
        let silentPath = folder + "/silent.sock"
        let silent = FakeControlApp(path: silentPath, options: .init(answersHello: false))
        try silent.start()
        defer { silent.quit() }
        let started = Date()
        let late = try await failureText(makeForwarder(socket: silentPath) { $0.helloTimeout = 0.4 }, forwarded("get_status"))
        check(late.hasPrefix("Focus Studio accepted the connection but was not ready within 0.4 seconds") && Date().timeIntervalSince(started) < 3, "hello timeout: \(late)")
        try await waitFor("the unready connection to close") { silent.closedCount == 1 }
    }

    // MARK: - Opening the app

    static func forwarderLaunch() async throws {
        let folder = try socketFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/app.sock"
        let appURL = URL(fileURLWithPath: "/Applications/Focus Studio Test.app", isDirectory: true)
        let apps = LockedList<FakeControlApp>()
        defer { apps.items.forEach { $0.quit() } }
        // The system answers at once; the app listens a moment later.
        let launcher = ScriptedLauncher { _ in
            let app = FakeControlApp(path: path)
            apps.append(app)
            Task.detached {
                try? await Task.sleep(nanoseconds: 400_000_000)
                try? app.start()
            }
        }
        let forwarder = makeForwarder(socket: path, launch: .app(appURL), launcher: launcher)
        let progress = [LockedList<(Double, String?)>(), LockedList<(Double, String?)>()]
        let results = await withTaskGroup(of: AutomationCallResult.self, returning: [AutomationCallResult].self) { group in
            for index in 0..<3 {
                group.addTask {
                    var handler: AIToolProgressHandler?
                    if index < 2 {
                        let list = progress[index]
                        handler = { value, _, message in list.append((value, message)) }
                    }
                    return await forwarder.forward(forwarded("get_status", sequence: index, progress: handler))
                }
            }
            var collected: [AutomationCallResult] = []
            for await result in group { collected.append(result) }
            return collected
        }
        check(results.allSatisfy { if case let .result(result) = $0 { return !result.isError } else { return false } }, "Every call runs once the app is up: \(results)")
        check(launcher.launches.count == 1 && launcher.launches.first?.0 == appURL, "Opened once, by its URL, for all waiting calls: \(launcher.launches.map(\.0))")
        check(launcher.launches.first?.1 == ["FOCUS_STUDIO_CONTROL_SOCKET": path], "with only the allowed environment: \(launcher.launches.first?.1 ?? [:])")
        check(apps.items.first?.acceptedCount == 1, "One connection")
        // Opening the app is part of the helper's own time: it listens 0.4 s after the launch.
        let launchElapsed = apps.items.first?.calls.compactMap(\.elapsed) ?? []
        check(launchElapsed.count == 3 && launchElapsed.allSatisfy { $0 >= 0.4 && $0 < 10 }, "elapsed includes opening the app: \(launchElapsed)")
        // The first call started the attempt and saw its first beat; each call's beats increase.
        check(progress.contains { $0.items.first?.1 == "Opening Focus Studio in the background…" }, "The beats say the app is opening: \(progress.map { $0.items.map(\.1) })")
        for (index, list) in progress.enumerated() {
            let values = list.items.map(\.0)
            check(!values.isEmpty && zip(values, values.dropFirst()).allSatisfy { $0 < $1 } && values.allSatisfy { $0 < 0.0001 }, "Call \(index) got increasing heartbeats while the app started: \(values)")
        }

        // The app quits during a call; the next call opens it again.
        let running = Task { await forwarder.forward(forwarded("start_recording", ["source": "display"])) }
        try await waitFor("the call to reach the app") { apps.items.first?.calls.contains { $0.tool == "start_recording" } ?? false }
        apps.items.first?.quit()
        guard case let .result(cut) = await running.value, cut.isError, cut.text.hasPrefix("Focus Studio quit before start_recording finished") else {
            fatalError("FAIL: the quit is reported")
        }
        try await waitFor("the helper to notice") { !forwarder.isConnected }
        guard case let .result(reopened) = await forwarder.forward(forwarded("get_status")), !reopened.isError else { fatalError("FAIL: the app is opened again") }
        check(launcher.launches.count == 2 && apps.count == 2 && apps.items[1].acceptedCount == 1, "Opened again for the next call: \(launcher.launches.count)")
        // With AI tools turned off, a running app still answers for itself (it refuses the call).
        let offButListening = await makeForwarder(socket: path, launch: .app(appURL), launcher: ScriptedLauncher { _ in }) { $0.isAutomationEnabled = { false } }.forward(forwarded("get_status"))
        guard case let .result(answered) = offButListening, !answered.isError else { fatalError("FAIL: a listening app answers whatever the switch says: \(offButListening)") }

        // AI tools turned off and the app not running: it is not opened just to refuse the call.
        let offLauncher = ScriptedLauncher { _ in }
        let off = try await failureText(makeForwarder(socket: folder + "/none.sock", launch: .app(appURL), launcher: offLauncher) { $0.isAutomationEnabled = { false } }, forwarded("get_status"))
        check(off == AutomationSwitch.disabledMessage(tool: "get_status") && offLauncher.launches.isEmpty, "Off: not opened: \(off) \(offLauncher.launches.count)")

        // Another copy runs (an older one without the control channel, or one
        // still starting): no second Focus Studio on the same library.
        let otherCopy = URL(fileURLWithPath: "/Applications/Focus Studio Old.app", isDirectory: true)
        let otherLauncher = ScriptedLauncher(others: [otherCopy]) { _ in }
        let secondCopy = try await failureText(makeForwarder(socket: folder + "/none.sock", launch: .app(appURL), launcher: otherLauncher) { $0.launchTimeout = 0.3 }, forwarded("add_zoom"))
        check(secondCopy.hasPrefix("Another copy of Focus Studio (/Applications/Focus Studio Old.app, version unknown) is running but is not accepting AI tools, so add_zoom did not run and nothing was changed.")
              && secondCopy.contains("does not open a second copy") && otherLauncher.launches.isEmpty, "Another copy: not opened: \(secondCopy)")
        // ... and when that copy starts listening meanwhile, the call goes to it.
        let startingPath = folder + "/starting.sock"
        let starting = FakeControlApp(path: startingPath)
        apps.append(starting)
        Task.detached {
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? starting.start()
        }
        let startingLauncher = ScriptedLauncher(others: [otherCopy]) { _ in }
        let joined = await makeForwarder(socket: startingPath, launch: .app(appURL), launcher: startingLauncher).forward(forwarded("get_status"))
        guard case let .result(joinedResult) = joined, !joinedResult.isError else { fatalError("FAIL: the other copy answers once it listens: \(joined)") }
        check(startingLauncher.launches.isEmpty && starting.acceptedCount == 1, "without opening this helper's copy")

        // The system refuses: an error at once, not after the timeout.
        let refusedLauncher = ScriptedLauncher { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "The application “Focus Studio” can’t be opened."])
        }
        var started = Date()
        let refused = try await failureText(makeForwarder(socket: folder + "/none.sock", launch: .app(appURL), launcher: refusedLauncher), forwarded("add_zoom"))
        check(refused.hasPrefix("Focus Studio is not running and macOS could not open it (The application “Focus Studio” can’t be opened.), so add_zoom did not run and nothing was changed.")
              && refused.contains(appURL.path) && Date().timeIntervalSince(started) < 2, "Refused: \(refused)")

        // Opened, but it never listens: after the timeout.
        started = Date()
        let quiet = try await failureText(makeForwarder(socket: folder + "/none.sock", launch: .app(appURL), launcher: ScriptedLauncher { _ in }) { $0.launchTimeout = 0.5 }, forwarded("get_status"))
        check(quiet.hasPrefix("Focus Studio (\(appURL.path)) was opened in the background but did not start accepting AI tools within 0.5 seconds") && !quiet.contains("macOS may be asking")
              && !quiet.contains("FOCUS_STUDIO_CONTROL_SOCKET") && Date().timeIntervalSince(started) >= 0.5, "Too slow: \(quiet)")
        // The system has not answered yet (a prompt about opening it).
        let pending = try await failureText(makeForwarder(socket: folder + "/none.sock", launch: .app(appURL), launcher: ScriptedLauncher { _ in try await Task.sleep(nanoseconds: 3_000_000_000) }) { $0.launchTimeout = 0.3 }, forwarded("get_status"))
        check(pending.contains("macOS may be asking the person whether to open it"), "Pending: \(pending)")
        // Already running, but not listening.
        let busy = try await failureText(makeForwarder(socket: folder + "/none.sock", launch: .app(appURL), launcher: ScriptedLauncher(running: true) { _ in }) { $0.launchTimeout = 0.3 }, forwarded("get_status"))
        check(busy.hasPrefix("Focus Studio is running but is not accepting AI tools, so get_status did not run and nothing was changed.") && busy.contains("Settings › AI tools"), "Running: \(busy)")
        // A socket override the opened app does not get (a release build).
        let overridden = try await failureText(makeForwarder(socket: folder + "/none.sock", launch: .app(appURL), launcher: ScriptedLauncher { _ in }) {
            $0.launchTimeout = 0.3
            $0.launchEnvironment = [:]
        }, forwarded("get_status"))
        check(overridden.contains("connects to \(folder)/none.sock (set by FOCUS_STUDIO_CONTROL_SOCKET), where a Focus Studio it opens does not listen"), "Override: \(overridden)")
        // No app to open.
        let nothing = try await failureText(makeForwarder(socket: folder + "/none.sock", launch: .unavailable("No app here.")), forwarded("get_status"))
        check(nothing == "Focus Studio is not running, so get_status did not run and nothing was changed. No app here. Ask the person to open Focus Studio, then try again.", "Unavailable: \(nothing)")
    }

    // MARK: - Cancellation and shutdown

    static func forwarderCancellation() async throws {
        let folder = try socketFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/app.sock"
        let app = FakeControlApp(path: path)
        try app.start()
        defer { app.quit() }
        let forwarder = makeForwarder(socket: path)

        // Cancelling a running call tells the app, which answers it as cancelled.
        let recording = Task { await forwarder.forward(forwarded("start_recording", ["source": "display"])) }
        try await waitFor("the call to reach the app") { app.calls.count == 1 }
        recording.cancel()
        let recorded = await recording.value
        check(recorded == .cancelled, "A cancelled call is cancelled: \(recorded)")
        guard let callID = app.received.last(where: { $0.message.method == "call" })?.message.id,
              case let .notification("cancel", params)? = app.received.last?.message, let cancel = try? ControlCancel.decode(params) else {
            fatalError("FAIL: the app gets cancel: \(app.received.map(\.message.json))")
        }
        check(cancel.id == callID, "for that call's id")
        check(forwarder.isConnected, "The connection stays open")

        // An app that does not answer the cancel: given up after the timeout.
        let hanging = makeForwarder(socket: path) { $0.cancelReplyTimeout = 0.3 }
        let stuck = Task { await hanging.forward(forwarded("wait_for_job", ["job_id": "hang"])) }
        try await waitFor("the stuck call to reach the app") { app.calls.contains { $0.tool == "wait_for_job" } }
        var started = Date()
        stuck.cancel()
        let givenUp = await stuck.value
        check(givenUp == .cancelled && Date().timeIntervalSince(started) < 2, "Given up on: \(givenUp)")

        // Cancelled while waiting for the app to open: the call stops waiting;
        // the attempt carries on and the next call uses its connection.
        let launchPath = folder + "/launch.sock"
        let later = FakeControlApp(path: launchPath)
        defer { later.quit() }
        let launcher = ScriptedLauncher { _ in
            Task.detached {
                try? await Task.sleep(nanoseconds: 600_000_000)
                try? later.start()
            }
        }
        let launching = makeForwarder(socket: launchPath, launch: .app(URL(fileURLWithPath: "/Applications/Focus Studio Test.app")), launcher: launcher)
        let waiting = Task { await launching.forward(forwarded("get_status")) }
        try await Task.sleep(nanoseconds: 150_000_000)
        started = Date()
        waiting.cancel()
        let stopped = await waiting.value
        check(stopped == .cancelled && Date().timeIntervalSince(started) < 0.5, "Stops waiting at once: \(stopped)")
        try await waitFor("the attempt to connect anyway") { launching.isConnected }
        guard case let .result(next) = await launching.forward(forwarded("get_status")), !next.isError else { fatalError("FAIL: the next call runs") }
        check(launcher.launches.count == 1 && later.acceptedCount == 1, "Without opening the app again")

        // Shutdown: the running call is cancelled (the router does that), the
        // connection closes after the cancel is written, and later calls are refused.
        let connectionsBefore = app.acceptedCount
        let closing = Task { await forwarder.forward(forwarded("start_recording", ["source": "display"])) }
        try await waitFor("the call to reach the app") { app.calls.filter { $0.tool == "start_recording" }.count == 2 }
        closing.cancel()
        await forwarder.shutdown()
        let ended = await closing.value
        check(ended == .cancelled, "The running call ends: \(ended)")
        try await waitFor("the app to see the connection close") { app.closedCount == 1 }
        check(app.received.last(where: { $0.connection == 1 })?.message.method == "cancel", "after the cancel reached it")
        let refused = await forwarder.forward(forwarded("get_status"))
        check(refused == .cancelled && app.acceptedCount == connectionsBefore, "A call after shutdown is refused without connecting: \(refused)")

        // Shutdown while waiting for the app to open.
        let neverPath = folder + "/never.sock"
        let never = makeForwarder(socket: neverPath, launch: .app(URL(fileURLWithPath: "/Applications/Focus Studio Test.app")), launcher: ScriptedLauncher { _ in })
        let parked = Task { await never.forward(forwarded("get_status")) }
        try await Task.sleep(nanoseconds: 150_000_000)
        started = Date()
        await never.shutdown()
        let parkedOutcome = await parked.value
        check(parkedOutcome == .cancelled && Date().timeIntervalSince(started) < 1, "A call waiting for the app ends with the helper: \(parkedOutcome)")
    }

    /// A call cancelled just as it is sent: the app must never see its
    /// cancel before the call itself (it would ignore the cancel for an id
    /// it does not know, then run the call). Many call-then-cancel rounds on
    /// a socketpair; the fake app answers each cancel so rounds are quick.
    static func forwarderCancelOrder() async throws {
        var fds: [Int32] = [0, 0]
        check(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "socketpair")
        let appFD = fds[1]
        let seen = LockedList<(Int, String)>()
        let reader = Thread {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let count = Darwin.read(appFD, &chunk, chunk.count)
                if count <= 0 { return }
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer = Data(buffer[(newline + 1)...])
                    switch try? ControlMessage.decode(line) {
                    case let .request(id, method, _)?:
                        seen.append((id.intValue ?? -1, method))
                    case let .notification(method, params)? where method == ControlChannel.Method.cancel:
                        guard let cancel = try? ControlCancel.decode(params) else { continue }
                        seen.append((cancel.id.intValue ?? -1, "cancel"))
                        if var reply = try? AutomationCallResult.cancelled.controlReply(id: cancel.id).encoded() {
                            reply.append(0x0A)
                            _ = reply.withUnsafeBytes { Darwin.write(appFD, $0.baseAddress, $0.count) }
                        }
                    default:
                        continue
                    }
                }
            }
        }
        reader.start()
        let link = AppLink(fileDescriptor: fds[0], log: .silent) { _ in }
        link.start()
        let rounds = 5000
        for round in 0..<rounds {
            let call = forwarded("start_recording", ["source": "display"], sequence: round)
            let task = Task.detached { await link.call(call, cancelReplyTimeout: 0.5) }
            let deadline = Date().addingTimeInterval(Double.random(in: 0...0.0005))
            while Date() < deadline {}
            task.cancel()
            _ = await task.value
        }
        link.close()
        try await Task.sleep(nanoseconds: 200_000_000)
        Darwin.close(appFD)
        var first: [Int: String] = [:]
        for (id, kind) in seen.items where first[id] == nil { first[id] = kind }
        let reordered = first.filter { $0.value == "cancel" }.keys.sorted()
        check(reordered.isEmpty, "A cancel reached the app before its call for ids \(reordered) (of \(rounds) rounds)")
        check(first.values.filter { $0 == "call" }.count > rounds / 10, "Most rounds sent their call: \(first.values.filter { $0 == "call" }.count)")
    }

    // MARK: - Fixtures

    static func socketFolder() throws -> String {
        // Short: a socket path must fit in 103 bytes.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fs-fw-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path
    }

    static func makeForwarder(
        socket path: String,
        launch: AppConnectionSettings.Launch = .disabled,
        launcher: any AppLaunching = ScriptedLauncher { _ in },
        _ configure: (inout AppConnectionSettings) -> Void = { _ in }
    ) -> SocketAppForwarder {
        var settings = AppConnectionSettings(
            socket: .success(ControlSocketLocation(path: path, source: .environment)),
            launch: launch,
            launchEnvironment: [ControlChannel.socketPathVariable: path]
        )
        settings.pollInterval = 0.05
        settings.heartbeatInterval = 0.1
        settings.launchTimeout = 3
        settings.helloTimeout = 3
        settings.cancelReplyTimeout = 2
        configure(&settings)
        return SocketAppForwarder(settings: settings, helperVersion: "7.7.7-test", helperPath: "/tmp/focus-studio-mcp-test", launcher: launcher, log: .silent)
    }

    static func forwarded(_ name: String, _ arguments: [String: AIJSONValue] = [:], sequence: Int = 1, progress: AIToolProgressHandler? = nil) -> ForwardedToolCall {
        guard let spec = MCPToolCatalog.v1.tool(named: name) else { fatalError("FAIL: no tool \(name)") }
        return ForwardedToolCall(
            sequence: sequence, tool: spec, arguments: arguments, workingDirectory: URL(fileURLWithPath: "/tmp/client-cwd", isDirectory: true),
            client: MCPClientIdentity(name: "claude-code", version: "2.1.0", title: "Claude Code"), protocolVersion: "2025-11-25", progress: progress, roots: nil
        )
    }

    static func failureText(_ forwarder: SocketAppForwarder, _ call: ForwardedToolCall) async throws -> String {
        let outcome = await forwarder.forward(call)
        guard case let .result(result) = outcome, result.isError, result.structuredContent == nil else { fatalError("FAIL: \(call.toolName) must fail: \(outcome)") }
        return result.text
    }

    static func expectFailure(_ forwarder: SocketAppForwarder, _ call: ForwardedToolCall, equals expected: String, _ what: String) async throws {
        let text = try await failureText(forwarder, call)
        check(text == expected, "\(what): \(text)")
    }

    /// A socket file nobody listens on (ECONNREFUSED), as a crashed app leaves it.
    static func bindWithoutListening(_ path: String) throws {
        let stale = try ControlSocket.makeSocket()
        var address = try ControlSocket.address(for: path)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        check(bound == 0, "bind a socket that never listens")
        Darwin.close(stale)
    }
}

/// Stands in for NSWorkspace: records each launch and runs the test's script.
final class ScriptedLauncher: AppLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(URL, [String: String])] = []
    private let running: Bool
    private let others: [URL]
    private let script: @Sendable (URL) async throws -> Void

    /// `others`: other copies of Focus Studio that run.
    init(running: Bool = false, others: [URL] = [], _ script: @escaping @Sendable (URL) async throws -> Void) {
        self.running = running
        self.others = others
        self.script = script
    }

    var launches: [(URL, [String: String])] { lock.withLock { recorded } }

    func launch(appAt appURL: URL, environment: [String: String]) async throws {
        lock.withLock { recorded.append((appURL, environment)) }
        try await script(appURL)
    }

    func isRunning(appAt appURL: URL) -> Bool { running }

    func otherRunningCopies(than appURL: URL) -> [URL] { others }
}

/// An in-process stand-in for Focus Studio's control server on a real Unix
/// socket: answers hello (optionally late, refused, never, or with another
/// protocol) and calls by tool name, and records everything it receives.
/// - export_project: progress 0.25, 0.5, 1 of 1 when asked for, then a result;
/// - start_recording: runs until cancelled (-32800);
/// - wait_for_job: never answers, not even a cancel;
/// - stop_recording: closes the connection without answering (the app quitting);
/// - list_assets: an unknown tool;
/// - anything else: "<tool> done" with `{"tool": <tool>}`.
final class FakeControlApp: @unchecked Sendable {
    struct Options {
        var protocolVersion = ControlChannel.protocolVersion
        var helloDelay: TimeInterval = 0
        var answersHello = true
        var helloError: String?
        var appPath = "/Applications/Focus Studio Fake.app"
    }

    struct Received {
        let connection: Int
        let message: ControlMessage
    }

    let path: String
    let options: Options
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "test.fake-app.accept")
    private var source: DispatchSourceRead?
    private var connections: [ControlConnection] = []
    private var log: [Received] = []
    private var accepted = 0
    private var closed = 0
    private var cancellable: [String: ControlConnection] = [:]
    private var greeted: Set<Int> = []
    private var stopped = false

    init(path: String, options: Options = Options()) {
        self.path = path
        self.options = options
    }

    var received: [Received] { lock.withLock { log } }
    var acceptedCount: Int { lock.withLock { accepted } }
    var closedCount: Int { lock.withLock { closed } }
    var calls: [ControlCall] {
        received.compactMap { entry in
            guard case let .request(_, "call", params) = entry.message else { return nil }
            return try? ControlCall.decode(params)
        }
    }

    func start() throws {
        let descriptor = try ControlSocket.makeSocket()
        var address = try ControlSocket.address(for: path)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(descriptor, 16) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw ControlSocketError.system(operation: "bind/listen", code: code)
        }
        ControlSocket.setNonBlocking(descriptor)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                self?.accepted(client)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        lock.withLock { self.source = source }
        source.resume()
    }

    /// Like the app quitting: stops listening, removes the socket file and
    /// closes every connection.
    func quit() {
        let (source, open) = lock.withLock { () -> (DispatchSourceRead?, [ControlConnection]) in
            guard !stopped else { return (nil, []) }
            stopped = true
            defer { self.source = nil }
            return (self.source, connections)
        }
        guard let source else { return }
        source.cancel()
        unlink(path)
        open.forEach { $0.close() }
    }

    private func accepted(_ descriptor: Int32) {
        let connection = ControlConnection(fileDescriptor: descriptor, label: "test.fake-app.connection")
        let number = lock.withLock { () -> Int in
            accepted += 1
            connections.append(connection)
            return accepted
        }
        connection.start(onLine: { [weak self, weak connection] line in
            guard let self, let connection, let message = try? ControlMessage.decode(line) else { return }
            self.handle(message, on: connection, number: number)
        }, onClose: { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.closed += 1 }
        })
    }

    private func handle(_ message: ControlMessage, on connection: ControlConnection, number: Int) {
        lock.withLock { log.append(Received(connection: number, message: message)) }
        switch message {
        case let .request(id, "hello", _):
            guard options.answersHello else { return }
            let reply: ControlMessage
            if let error = options.helloError {
                reply = .error(id: id, ControlError(code: ControlChannel.ErrorCode.invalidParams, message: error))
            } else {
                lock.withLock { _ = greeted.insert(number) }
                reply = .result(id: id, ControlHelloReply(protocolVersion: options.protocolVersion, appVersion: "9.9.9-fake", appPath: options.appPath, pid: getpid()).json)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + options.helloDelay) { try? connection.send(reply) }
        case let .request(id, "call", params):
            guard lock.withLock({ greeted.contains(number) }) else {
                try? connection.send(.error(id: id, ControlError(code: ControlChannel.ErrorCode.helloRequired, message: "Send hello before call.")))
                return
            }
            guard let call = try? ControlCall.decode(params) else { return }
            switch call.tool {
            case "export_project":
                if call.progressToken != nil {
                    for value in [0.25, 0.5, 1] {
                        try? connection.send(.notification(method: "progress", params: ControlProgress(id: id, progress: value, total: 1, message: "Exporting").json))
                    }
                }
                try? connection.send(AutomationCallResult.result(MCPToolCallResult(content: [.text("exported")], structuredContent: ["path": "/tmp/out.mp4"])).controlReply(id: id))
            case "start_recording":
                lock.withLock { cancellable["\(number)/\(id)"] = connection }
            case "wait_for_job":
                break
            case "stop_recording":
                connection.close()
            case "list_assets":
                try? connection.send(AutomationCallResult.unknownTool(call.tool).controlReply(id: id))
            default:
                try? connection.send(AutomationCallResult.result(MCPToolCallResult(content: [.text("\(call.tool) done")], structuredContent: ["tool": AIJSONValue(call.tool)])).controlReply(id: id))
            }
        case let .notification("cancel", params):
            guard let cancel = try? ControlCancel.decode(params),
                  let target = lock.withLock({ cancellable.removeValue(forKey: "\(number)/\(cancel.id)") }) else { return }
            try? target.send(AutomationCallResult.cancelled.controlReply(id: cancel.id))
        default:
            break
        }
    }
}

extension ControlMessage {
    var method: String? {
        switch self {
        case let .request(_, method, _), let .notification(method, _): return method
        default: return nil
        }
    }
}
