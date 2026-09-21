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
        print("CodexConnectionTests: PASS (setup, auth, cancellation, models, privacy, planning)")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
    }
}
