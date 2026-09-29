import Foundation

@main
struct CodexConnectionTests {
    @MainActor
    static func main() async throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexDirectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        let suiteName = "FocusStudio.CodexTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: testDirectory)
        }

        if CommandLine.arguments.contains("--live-read-only") {
            let service = CodexDirectorService(
                configuration: .init(workingDirectoryURL: testDirectory),
                preferences: .init(accountScope: .existingCodex), preferencesStore: defaults
            )
            await service.connect()
            check(service.canCreatePlan, "live account/model connection: \(service.lastErrorMessage ?? "not ready")")
            print("CodexConnectionTests: LIVE READ-ONLY PASS (\(service.availableModels.count) models, no auth changes or model turn)")
            service.disconnect()
            return
        }

        guard let fixturePath = CommandLine.arguments.dropFirst().first else { fatalError("Fixture path required") }
        var configured = CodexConnectionPreferences(executablePath: " /invalid/path ", modelID: " model ")
        configured = configured.normalized
        configured.save(to: defaults)
        check(CodexConnectionPreferences.load(from: defaults) == configured, "preferences round trip")
        do {
            _ = try CodexExecutableDiscovery.resolve(explicitPath: "/missing/codex/fixture")
            fatalError("Explicit invalid executable must not silently fall back")
        } catch CodexDirectorServiceError.invalidExecutable { }

        // Version-aware discovery: the newest installation wins regardless of
        // PATH order, and candidates that cannot answer --version rank last.
        check(CodexVersion(parsing: "codex-cli 0.155.0-alpha.9.2")! > CodexVersion(parsing: "codex-cli 0.42.0")!, "0.155.x beats 0.42.0")
        check(CodexVersion(parsing: "0.155.0-alpha.9.2")! < CodexVersion(parsing: "0.155.0")!, "pre-release ranks below its release")
        check(CodexVersion(parsing: "0.155.0-alpha.9.2")! < CodexVersion(parsing: "0.155.0-alpha.10")!, "numeric pre-release identifiers")
        check(CodexVersion(parsing: "0.155.0-alpha")! < CodexVersion(parsing: "0.155.0-alpha.1")!, "longer pre-release ranks higher")
        check(CodexVersion(parsing: "no version here") == nil, "unparseable version output")
        func writeCandidate(_ name: String, _ body: String, executable: Bool = true) throws -> String {
            let directory = testDirectory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("codex")
            try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
            return file.path
        }
        let older = try writeCandidate("older", "printf 'codex-cli 0.42.0\\n'")
        // Would rank last if the probe leaked the caller's API key.
        let newer = try writeCandidate("newer", "[ -z \"$OPENAI_API_KEY\" ] || exit 3\nprintf 'codex-cli 0.155.0-alpha.9.2\\n'")
        let desktopApp = testDirectory.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let nestedCLI = desktopApp.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        try FileManager.default.createDirectory(at: nestedCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: newer, toPath: nestedCLI.path)
        check(CodexExecutableDiscovery.executable(in: desktopApp)?.path == nestedCLI.path,
              "choosing a current ChatGPT.app finds its nested CodexCLI executable")
        let broken = try writeCandidate("broken", "exit 1")
        let slow = try writeCandidate("slow", "sleep 5")
        _ = try writeCandidate("plain", "printf 'codex-cli 8.0.0\\n'", executable: false)
        let alias = testDirectory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: alias.appendingPathComponent("codex").path, withDestinationPath: newer)
        func searchPath(_ names: [String]) -> String {
            names.map { testDirectory.appendingPathComponent($0).path }.joined(separator: ":")
        }
        let fakeEnvironment = [
            "PATH": searchPath(["older", "broken", "newer", "alias", "slow", "plain", "older"]),
            "OPENAI_API_KEY": "FAKE-TEST-SECRET-NOT-A-REAL-KEY"
        ]
        // A fresh script's first launch takes a few hundred milliseconds here;
        // only the deliberately hanging candidate should exceed the timeout.
        let installations = await CodexExecutableDiscovery.installations(
            environment: fakeEnvironment, searchesStandardLocations: false, probeTimeout: 2
        )
        check(installations.map(\.path) == [newer, older, broken, slow],
              "newest first, failing candidates last, duplicates and non-executables skipped: \(installations.map(\.path))")
        check(installations[0].isRecommended && installations[0].versionString == "codex-cli 0.155.0-alpha.9.2",
              "recommended badge on the highest version")
        check(installations.dropFirst().allSatisfy { !$0.isRecommended } && installations[2].version == nil && installations[3].version == nil,
              "single recommendation; failing and timed-out candidates have no version")
        let chosen = try await CodexExecutableDiscovery.resolveAutomatic(
            environment: ["PATH": searchPath(["older", "broken", "newer"])], searchesStandardLocations: false
        )
        check(chosen.path == newer, "automatic detection launches the newest installation")
        let fixtureInstallations = await CodexExecutableDiscovery.installations(
            environment: ["CODEX_EXECUTABLE": fixturePath, "PATH": "/usr/bin:/bin"], searchesStandardLocations: false
        )
        check(fixtureInstallations.map(\.version) == [CodexVersion(major: 9, minor: 9, patch: 9)],
              "CODEX_EXECUTABLE candidate answers --version: \(fixtureInstallations)")
        let redacted = CodexDirectorService.redactedDiagnostic(
            "token sk-ABC123 Bearer FAKE \"apiKey\": \"FAKE-VALUE\" key=FAKE-K " + String(repeating: "x", count: 400)
        )
        check(!redacted.contains("ABC123") && !redacted.contains("FAKE") && redacted.count == 301,
              "stderr redaction and truncation: \(redacted)")

        let configuration = CodexDirectorConfiguration(
            executableURL: URL(fileURLWithPath: fixturePath), workingDirectoryURL: testDirectory,
            requestTimeout: 2, accountDirectoryURL: testDirectory.appendingPathComponent("Account")
        )
        var openedLoginURLs: [URL] = []
        func makeService(scope: CodexConnectionPreferences.AccountScope = .focusStudio, model: String = "") -> CodexDirectorService {
            CodexDirectorService(configuration: configuration,
                preferences: .init(modelID: model, accountScope: scope), preferencesStore: defaults,
                openLoginURL: { openedLoginURLs.append($0) })
        }

        setenv("FOCUS_STUDIO_CODEX_FIXTURE", "new-user", 1)
        let service = makeService()
        await service.connect()
        check(service.connectionState == .needsSignIn && !service.canCreatePlan, "new user must sign in")
        await service.sendPrompt("Create a plan")
        check(service.messages.isEmpty && service.currentPlan == nil, "signed-out prompt must not start a thread")
        await service.signInWithChatGPT()
        check(service.connectionState == .signingIn && openedLoginURLs.count == 1, "ChatGPT browser handoff")
        await service.cancelSignIn()
        check(service.connectionState == .needsSignIn && service.loginURL == nil, "cancel sign-in returns to setup")
        await service.signInWithAPIKey("FAKE-TEST-SECRET-NOT-A-REAL-KEY")
        check(service.canCreatePlan, "API key sign-in discovers account/models")
        check(service.availableModels.count == 2, "model list pagination")
        check(!service.availableModels[0].supportsImages && service.availableModels[1].isDefault, "model capabilities")
        let data = defaults.data(forKey: CodexConnectionPreferences.defaultsKey) ?? Data()
        check(!String(decoding: data, as: UTF8.self).contains("FAKE-TEST-SECRET"), "secrets are not preferences")
        await service.sendPrompt("Show example.com")
        for _ in 0..<30 where service.currentPlan == nil && service.lastErrorMessage == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        check(service.currentPlan?.title == "Fixture demo", "authenticated plan uses discovered default model/effort")
        await service.signOut()
        check(service.connectionState == .needsSignIn, "separate account sign-out")
        service.disconnect()

        setenv("FOCUS_STUDIO_CODEX_FIXTURE", "instant-browser-login", 1)
        let instantLogin = makeService()
        await instantLogin.connect()
        await instantLogin.signInWithChatGPT()
        for _ in 0..<30 where !instantLogin.canCreatePlan {
            try await Task.sleep(for: .milliseconds(20))
        }
        check(instantLogin.canCreatePlan && instantLogin.loginURL == nil, "batched login response/completion cannot get stuck")
        instantLogin.disconnect()

        setenv("FOCUS_STUDIO_CODEX_FIXTURE", "slow-turn", 1)
        let delayedTurn = makeService()
        await delayedTurn.connect()
        await delayedTurn.signInWithAPIKey("FAKE-TEST-SECRET-NOT-A-REAL-KEY")
        let firstPrompt = Task { await delayedTurn.sendPrompt("First request") }
        try await Task.sleep(for: .milliseconds(70))
        await delayedTurn.sendPrompt("Duplicate request")
        check(delayedTurn.connectionState == .generating, "duplicate prompt cannot unlock active generation")
        await delayedTurn.interruptCurrentTurn()
        await firstPrompt.value
        check(delayedTurn.connectionState == .disconnected, "stop planning cancels pending turn start")

        setenv("FOCUS_STUDIO_CODEX_FIXTURE", "existing", 1)
        let existing = makeService(scope: .existingCodex)
        await existing.connect()
        check(existing.canCreatePlan, "existing login reuse")
        await existing.signOut()
        check(existing.canCreatePlan, "shared account sign-out is blocked")
        existing.disconnect()

        setenv("FOCUS_STUDIO_CODEX_FIXTURE", "stale-model", 1)
        let staleModel = makeService(scope: .existingCodex, model: "removed-model")
        await staleModel.connect()
        check(!staleModel.canCreatePlan && staleModel.availableModels.count == 2, "unavailable saved model is recoverable")
        var repaired = staleModel.preferences
        repaired.modelID = ""
        staleModel.savePreferences(repaired)
        await staleModel.connect()
        check(staleModel.canCreatePlan, "switching back to account default recovers")
        staleModel.disconnect()

        setenv("FOCUS_STUDIO_CODEX_FIXTURE", "slow-connect", 1)
        let cancelled = makeService()
        let connecting = Task { await cancelled.connect() }
        try await Task.sleep(for: .milliseconds(70))
        cancelled.disconnect()
        await connecting.value
        check(cancelled.connectionState == .disconnected, "disconnect cancels pending handshake")

        setenv("FOCUS_STUDIO_CODEX_FIXTURE", "slow-login", 1)
        let cancelledLogin = makeService()
        await cancelledLogin.connect()
        let signingIn = Task { await cancelledLogin.signInWithAPIKey("FAKE-TEST-SECRET-NOT-A-REAL-KEY") }
        try await Task.sleep(for: .milliseconds(70))
        cancelledLogin.disconnect()
        await signingIn.value
        check(cancelledLogin.connectionState == .disconnected, "disconnect cancels pending authentication")

        // The AI assistant's brain: one-shot completions on a dedicated thread.
        setenv("FOCUS_STUDIO_CODEX_FIXTURE", "assistant-turn", 1)
        let requestLog = testDirectory.appendingPathComponent("assistant-methods.log")
        setenv("FOCUS_STUDIO_CODEX_REQUEST_LOG", requestLog.path, 1)
        let assistant = makeService(scope: .existingCodex)
        check(assistant.isAvailableForCompletion, "a disconnected service connects on the first completion")
        func object(_ text: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        }
        try await assistant.prepareAssistantConversation(developerInstructions: "You are a test.")
        try await assistant.prepareAssistantConversation(developerInstructions: "You are a test.")
        func assistantMethods() throws -> [String] {
            try String(contentsOf: requestLog, encoding: .utf8).split(separator: "\n").map(String.init)
        }
        let warmedMethods = try assistantMethods()
        check(warmedMethods.filter { $0 == "thread/start" }.count == 1
              && warmedMethods.filter { $0 == "config/read" }.count == 1 && !warmedMethods.contains("turn/start"),
              "preparation reads effective config once and reuses the exact assistant thread with zero model turns")
        let first = try object(await assistant.completeText(developerInstructions: "You are a test.", prompt: "hello", json: true))
        let firstMethods = try assistantMethods()
        check(firstMethods.filter { $0 == "thread/start" }.count == 1 && firstMethods.filter { $0 == "turn/start" }.count == 1,
              "first live completion immediately reuses the prewarmed thread")
        check(first["reply"] as? String == "echo: hello" && first["schema"] as? Bool == true, "completeText returns the final agent text (completion batched before the turn/start response): \(first)")
        check((first["instructions"] as? String)?.hasPrefix("You are a test.") == true && (first["thread"] as? String)?.hasPrefix("assistant-thread-") == true, "the thread carries the developer instructions: \(first)")
        check(assistant.canCreatePlan && assistant.messages.isEmpty && assistant.currentPlan == nil, "assistant turns never touch the Director transcript or plan")
        let second = try object(await assistant.completeText(developerInstructions: "You are a test.", prompt: "again", json: false))
        check(second["schema"] as? Bool == false && second["thread"] as? String == first["thread"] as? String, "json: false sends no schema; the thread is reused: \(second)")
        let third = try object(await assistant.completeText(developerInstructions: "Different instructions.", prompt: "third", json: true))
        check((third["instructions"] as? String)?.hasPrefix("Different instructions.") == true && third["thread"] as? String != first["thread"] as? String, "changed instructions start a new thread: \(third)")
        await assistant.resetAssistantConversation()
        let fresh = try object(await assistant.completeText(developerInstructions: "Different instructions.", prompt: "new chat", json: true))
        check(fresh["thread"] as? String != third["thread"] as? String && assistant.canCreatePlan, "new chat drops server history without disconnecting authentication")

        let snapshotHeader = "[App]\nRecording: active"
        let originalTranscript = "User: demonstrate the page\n\nTool capture_recording_frame: first observed frame"
        let snapshotOne = try object(await assistant.completeText(developerInstructions: "Snapshot test.", prompt: snapshotHeader + "\n\n[Conversation]\n" + originalTranscript, json: true, conversationSnapshot: true, interactive: true))
        let snapshotTwo = try object(await assistant.completeText(developerInstructions: "Snapshot test.", prompt: snapshotHeader + " (updated)\n\n[Conversation]\n" + originalTranscript + "\n\nTool perform_recording_action: click performed", json: true, conversationSnapshot: true, interactive: true))
        let incrementalPrompt = snapshotTwo["reply"] as? String ?? ""
        check(snapshotOne["thread"] as? String == snapshotTwo["thread"] as? String && incrementalPrompt.contains("[New conversation entries]") && incrementalPrompt.contains("click performed") && incrementalPrompt.contains("(updated)") && !incrementalPrompt.contains("first observed frame") && !incrementalPrompt.contains("demonstrate the page"), "snapshot adapter reuses the thread and sends only new transcript entries with current app state")
        check(snapshotTwo["effort"] as? String == "low", "live interaction explicitly uses advertised low effort on the selected model")
        let rebased = try object(await assistant.completeText(developerInstructions: "Snapshot test.", prompt: snapshotHeader + "\n\n[Conversation]\nUser: replaced local history", json: true, conversationSnapshot: true))
        let afterRebase = try object(await assistant.completeText(developerInstructions: "Snapshot test.", prompt: snapshotHeader + "\n\n[Conversation]\nUser: replaced local history\n\nTool: new result", json: true, conversationSnapshot: true))
        check(rebased["thread"] as? String != snapshotTwo["thread"] as? String && afterRebase["thread"] as? String == rebased["thread"] as? String, "changed or truncated history rebases once, then resumes incremental turns")
        check(afterRebase["effort"] as? String == "medium", "ordinary editing restores model default effort after live interaction")
        let unsupportedLow = CodexAvailableModel(json: .object(["model": .string("test"), "defaultReasoningEffort": .string("high"), "supportedReasoningEfforts": .array([.object(["reasoningEffort": .string("high")])])]))!
        check(unsupportedLow.assistantEffort(interactive: true) == "high", "low effort is never guessed for a model that does not advertise it")
        let _ = try await assistant.completeText(developerInstructions: "Diagnostics test.", prompt: "diagnostic fixture SECRET_PROMPT_MUST_NOT_LOG", json: true)
        let diagnosticData = try Data(contentsOf: assistant.assistantDiagnosticsURL)
        let diagnosticText = String(decoding: diagnosticData, as: UTF8.self)
        let diagnosticRows = try diagnosticText.split(separator: "\n").map { try object(String($0)) }
        check(diagnosticData.count <= 64_000 && !diagnosticText.contains("SECRET_") && diagnosticText.contains("commandExecution") && diagnosticText.contains("reasoning") && diagnosticText.contains("elapsed_ms") && diagnosticText.contains("input_chars"), "bounded diagnostics reveal lifecycle and internal item types without prompt, reasoning, or command content")
        check(diagnosticRows.filter { $0["method"] as? String == "item/reasoning/textDelta" }.count == 1, "streaming diagnostics record each delta notification kind once per turn")
        let frameURL = testDirectory.appendingPathComponent("assistant-frame.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!.write(to: frameURL)
        let visual = try object(await assistant.completeText(developerInstructions: "Different instructions.", prompt: "inspect this frame", json: true, imageURLs: [frameURL]))
        let images = visual["images"] as? [[String: String]]
        check(images == [["type": "localImage", "path": frameURL.path, "detail": "high"]], "the assistant sends the actual frame as an image input: \(visual)")
        let invalidFrame = testDirectory.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalidFrame)
        do {
            _ = try await assistant.completeText(developerInstructions: "Different instructions.", prompt: "bad frame", json: true, imageURLs: [invalidFrame])
            fatalError("FAIL: invalid image must fail before a model turn")
        } catch CodexDirectorServiceError.malformedResponse { }
        for invalid in ["malformed envelope", "non-object envelope"] {
            do {
                _ = try await assistant.completeText(developerInstructions: "Different instructions.", prompt: invalid, json: true)
                fatalError("FAIL: malformed structured JSON must not reach the tool parser")
            } catch CodexDirectorServiceError.malformedResponse { }
        }
        let slowCompletion = Task { try await assistant.completeText(developerInstructions: "Different instructions.", prompt: "slow one", json: false) }
        try await Task.sleep(for: .milliseconds(150))
        slowCompletion.cancel()
        let slowResult = await slowCompletion.result
        switch slowResult {
        case let .failure(error): check(error is CancellationError, "cancelling the caller interrupts the turn: \(error)")
        case .success: fatalError("FAIL: a cancelled completion must not succeed")
        }
        let afterCancel = try object(await assistant.completeText(developerInstructions: "Different instructions.", prompt: "after cancel", json: true))
        check(afterCancel["reply"] as? String == "echo: after cancel" && assistant.canCreatePlan, "the service stays usable after an interruption: \(afterCancel)")
        let delayedCompletion = Task { try await assistant.completeText(developerInstructions: "Different instructions.", prompt: "slow late completion", json: true) }
        try await Task.sleep(for: .milliseconds(100))
        delayedCompletion.cancel()
        switch await delayedCompletion.result {
        case let .failure(error): check(error is CancellationError, "interrupt acknowledgement cancels without waiting for the old completed notification")
        case .success: fatalError("FAIL: delayed interrupted turn must not return success")
        }
        let afterLateCompletion = try object(await assistant.completeText(developerInstructions: "Different instructions.", prompt: "after delayed interruption", json: true))
        check(afterLateCompletion["reply"] as? String == "echo: after delayed interruption" && afterLateCompletion["thread"] as? String != afterCancel["thread"] as? String, "retry uses a new thread and ignores the old completion delivered before its new turn ID")
        check(assistant.messages.isEmpty && assistant.currentPlan == nil && assistant.canCreatePlan, "retired assistant notifications cannot fall through into the legacy Director")
        do {
            _ = try await assistant.completeText(developerInstructions: "Different instructions.", prompt: "please fail", json: true)
            fatalError("FAIL: a failed turn must throw")
        } catch CodexDirectorServiceError.turnFailed(let message) {
            check(message.contains("fixture failure"), "a failed turn surfaces its error: \(message)")
        }
        let warming = Task { try await assistant.prepareAssistantConversation(developerInstructions: "Slow preparation.") }
        try await Task.sleep(for: .milliseconds(100))
        let warmCancelAt = Date()
        warming.cancel()
        switch await warming.result {
        case let .failure(error): check(error is CancellationError, "warmup cancellation surfaces cancellation")
        case .success: fatalError("FAIL: cancelled warmup succeeded")
        }
        check(Date().timeIntervalSince(warmCancelAt) < 1, "cancelled warmup closes pending thread setup promptly without auth changes")
        try await assistant.prepareAssistantConversation(developerInstructions: "Different instructions.")
        let resumed = try object(await assistant.completeText(developerInstructions: "Different instructions.", prompt: "after warmup cancellation", json: true))
        check(resumed["reply"] as? String == "echo: after warmup cancellation", "a cancelled warmup cannot poison the next prepared conversation")
        let preparing = Task { try await assistant.completeText(developerInstructions: "Slow preparation.", prompt: "cancel setup", json: true) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelledAt = Date()
        preparing.cancel()
        switch await preparing.result {
        case let .failure(error): check(error is CancellationError, "preparation cancellation surfaces cancellation")
        case .success: fatalError("FAIL: cancelled preparation succeeded")
        }
        check(Date().timeIntervalSince(cancelledAt) < 1, "stopping preparation does not wait for protocol timeout")
        assistant.disconnect()
        unsetenv("FOCUS_STUDIO_CODEX_REQUEST_LOG")

        // Config is read from the assistant's effective cwd and applied only
        // to each new thread. The fixture checks literal dotted/escaped IDs,
        // disabled flags only (no credential copies), and untouched Director
        // behavior. A failed read must never silently start inherited MCPs.
        for configCase in ["no-servers", "null-servers", "read-error", "missing-config", "invalid-servers", "invalid-server-entry"] {
            setenv("FOCUS_STUDIO_CODEX_CONFIG_CASE", configCase, 1)
            let methodsURL = testDirectory.appendingPathComponent("config-\(configCase)-methods.log")
            setenv("FOCUS_STUDIO_CODEX_REQUEST_LOG", methodsURL.path, 1)
            let configService = makeService(scope: .existingCodex)
            let allowsStart = ["no-servers", "null-servers"].contains(configCase)
            do {
                try await configService.prepareAssistantConversation(developerInstructions: "Read inherited tools safely.")
                check(allowsStart, "invalid/unreadable config must prevent a new assistant thread")
            } catch {
                check(!allowsStart && error.localizedDescription.contains("configuration could not be read")
                      && !error.localizedDescription.contains("SECRET"),
                      "config read failure is actionable without surfacing configuration values")
            }
            let methods = try String(contentsOf: methodsURL, encoding: .utf8).split(separator: "\n")
            check(methods.filter { $0 == "config/read" }.count == 1
                  && methods.filter { $0 == "thread/start" }.count == (allowsStart ? 1 : 0)
                  && !methods.contains("turn/start")
                  && !methods.contains(where: { $0.contains("write") || $0 == "config/mcpServer/reload" }),
                  "config isolation never writes global settings or spends a model turn")
            configService.disconnect()
        }
        setenv("FOCUS_STUDIO_CODEX_CONFIG_CASE", "slow-read", 1)
        let readCancelLog = testDirectory.appendingPathComponent("config-cancel-methods.log")
        setenv("FOCUS_STUDIO_CODEX_REQUEST_LOG", readCancelLog.path, 1)
        let readCancelled = makeService(scope: .existingCodex)
        let reading = Task { try await readCancelled.prepareAssistantConversation(developerInstructions: "Cancel config read.") }
        for _ in 0..<40 {
            let log = (try? String(contentsOf: readCancelLog, encoding: .utf8)) ?? ""
            if log.contains("config/read") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        reading.cancel()
        switch await reading.result {
        case let .failure(error): check(error is CancellationError, "cancelling config read remains a cancellation")
        case .success: fatalError("FAIL: cancelled config read started a thread")
        }
        let readMethods = try String(contentsOf: readCancelLog, encoding: .utf8)
        check(readMethods.contains("config/read") && !readMethods.contains("thread/start"),
              "a late configuration response cannot start a cancelled assistant thread")
        readCancelled.disconnect()
        unsetenv("FOCUS_STUDIO_CODEX_CONFIG_CASE")
        unsetenv("FOCUS_STUDIO_CODEX_REQUEST_LOG")

        setenv("FOCUS_STUDIO_CODEX_FIXTURE", "new-user", 1)
        let signedOut = makeService()
        do {
            _ = try await signedOut.completeText(developerInstructions: "You are a test.", prompt: "hello", json: true)
            fatalError("FAIL: a signed-out completion must throw")
        } catch CodexDirectorServiceError.assistantSignInRequired {
            check(signedOut.connectionState == .needsSignIn && !signedOut.isAvailableForCompletion,
                  "sign-in required is reported clearly and blocks the assistant: \(signedOut.connectionState)")
            check(CodexDirectorServiceError.assistantSignInRequired.localizedDescription == "Sign in to Codex in Settings → Codex", "sign-in message")
        }
        signedOut.disconnect()
        check(signedOut.isAvailableForCompletion, "disconnecting lets the next completion retry")

        // A failed discovery can leave the pipe alive. Retrying unchanged
        // preferences must replace that failed server, without signing in again.
        setenv("FOCUS_STUDIO_CODEX_FIXTURE", "routing-recovery", 1)
        let launchCounter = testDirectory.appendingPathComponent("routing-launches.txt")
        setenv("FOCUS_STUDIO_CODEX_RECONNECT_STATE", launchCounter.path, 1)
        defer { unsetenv("FOCUS_STUDIO_CODEX_RECONNECT_STATE") }
        let recovering = makeService(scope: .existingCodex)
        let savedPreferences = recovering.preferences
        await recovering.connect()
        guard case .failed = recovering.connectionState else {
            fatalError("FAIL: the fixture must start with a discovery failure")
        }
        check(recovering.isServerConnected, "the failed discovery leaves its original server running")
        await recovering.refreshConnection()
        let failedLaunches = try String(contentsOf: launchCounter, encoding: .utf8)
        check(!recovering.canCreatePlan && failedLaunches == "1", "refresh alone retains the server's cached discovery failure")
        await recovering.connect()
        check(recovering.canCreatePlan && recovering.availableModels.count == 2 && recovering.lastErrorMessage == nil,
              "retry establishes a fresh working connection: \(recovering.lastErrorMessage ?? "no error")")
        let recoveredLaunches = try String(contentsOf: launchCounter, encoding: .utf8)
        check(recoveredLaunches == "2" && recovering.preferences == savedPreferences,
              "retry launches exactly one replacement without changing account or preferences")
        await recovering.connect()
        let healthyLaunches = try String(contentsOf: launchCounter, encoding: .utf8)
        check(healthyLaunches == "2", "testing a healthy connection reuses its server")
        recovering.disconnect()

        setenv("FOCUS_STUDIO_CODEX_FIXTURE", "config-error", 1)
        let brokenConfig = makeService()
        await brokenConfig.connect()
        guard case .failed = brokenConfig.connectionState else {
            fatalError("FAIL: a server that dies during setup must fail the connection: \(brokenConfig.connectionState)")
        }
        let exitMessage = brokenConfig.lastErrorMessage ?? ""
        check(exitMessage.contains("exited with status 1") && exitMessage.contains("unknown variant"),
              "exit diagnostics surface stderr: \(exitMessage)")
        check(exitMessage.contains("config.toml"), "configuration error hint: \(exitMessage)")
        check(!exitMessage.contains("FAKE") && exitMessage.contains("[redacted]"), "stderr secrets are redacted: \(exitMessage)")
        check(!exitMessage.contains("older diagnostic"), "only the last three stderr lines are shown: \(exitMessage)")
        check(brokenConfig.resolvedExecutablePath == fixturePath, "the launched executable is reported")
        brokenConfig.disconnect()
        print("CodexConnectionTests: PASS (discovery, setup, auth, cancellation, models, privacy, planning, assistant completions, failed discovery reconnect, exit diagnostics)")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
    }
}
