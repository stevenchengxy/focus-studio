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
        let assistant = makeService(scope: .existingCodex)
        check(assistant.isAvailableForCompletion, "a disconnected service connects on the first completion")
        func object(_ text: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        }
        let first = try object(await assistant.completeText(developerInstructions: "You are a test.", prompt: "hello", json: true))
        check(first["reply"] as? String == "echo: hello" && first["schema"] as? Bool == true, "completeText returns the final agent text (completion batched before the turn/start response): \(first)")
        check(first["instructions"] as? String == "You are a test." && (first["thread"] as? String)?.hasPrefix("assistant-thread-") == true, "the thread carries the developer instructions: \(first)")
        check(assistant.canCreatePlan && assistant.messages.isEmpty && assistant.currentPlan == nil, "assistant turns never touch the Director transcript or plan")
        let second = try object(await assistant.completeText(developerInstructions: "You are a test.", prompt: "again", json: false))
        check(second["schema"] as? Bool == false && second["thread"] as? String == first["thread"] as? String, "json: false sends no schema; the thread is reused: \(second)")
        let third = try object(await assistant.completeText(developerInstructions: "Different instructions.", prompt: "third", json: true))
        check(third["instructions"] as? String == "Different instructions." && third["thread"] as? String != first["thread"] as? String, "changed instructions start a new thread: \(third)")
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
        do {
            _ = try await assistant.completeText(developerInstructions: "Different instructions.", prompt: "please fail", json: true)
            fatalError("FAIL: a failed turn must throw")
        } catch CodexDirectorServiceError.turnFailed(let message) {
            check(message.contains("fixture failure"), "a failed turn surfaces its error: \(message)")
        }
        assistant.disconnect()

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
        print("CodexConnectionTests: PASS (discovery, setup, auth, cancellation, models, privacy, planning, assistant completions, exit diagnostics)")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
    }
}
