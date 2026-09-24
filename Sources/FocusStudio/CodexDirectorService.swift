import AppKit
import Combine
import FocusStudioAutomation
import Foundation

struct CodexDirectorConfiguration: Sendable {
    var executableURL: URL?
    var workingDirectoryURL: URL
    var model: String?
    var requestTimeout: TimeInterval
    var accountDirectoryURL: URL

    init(
        executableURL: URL? = nil,
        workingDirectoryURL: URL? = nil,
        model: String? = nil,
        requestTimeout: TimeInterval = 30,
        accountDirectoryURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.workingDirectoryURL = workingDirectoryURL
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("FocusStudio", isDirectory: true)
                .appendingPathComponent("CodexDirector", isDirectory: true)
        self.model = model
        self.requestTimeout = requestTimeout
        self.accountDirectoryURL = accountDirectoryURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusStudio/Codex", isDirectory: true)
    }
}

enum CodexDirectorServiceError: LocalizedError {
    case executableNotFound
    case invalidExecutable(String)
    case signInRequired
    /// The assistant brain is Codex but no account is signed in.
    case assistantSignInRequired
    /// The assistant could not use Codex; the payload is the connection error.
    case assistantUnavailable(String)
    case modelUnavailable(String)
    case processUnavailable
    case connectionClosed
    case requestTimedOut(String)
    case malformedResponse(String)
    case serverError(code: Int?, message: String)
    case turnAlreadyRunning
    case turnFailed(String)
    case invalidPlan([String])
    case processExited(status: Int32, diagnostics: [String])
    case configurationError(status: Int32, diagnostics: [String])

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Install Codex CLI or the Codex desktop app, then choose its executable in Connection settings."
        case let .invalidExecutable(path):
            return "The selected Codex executable is unavailable: \(path). Choose an executable file or clear the path to auto-detect."
        case .signInRequired:
            return "Open Connection settings and sign in before creating a plan."
        case .assistantSignInRequired:
            return "Sign in to Codex in Settings → Codex"
        case let .assistantUnavailable(message):
            return "Codex is unavailable: \(message)"
        case let .modelUnavailable(model):
            return "The saved model \(model) is not available to this account. Choose an available model or Account default."
        case .processUnavailable:
            return "Codex app-server is not running."
        case .connectionClosed:
            return "Codex app-server closed the connection."
        case let .requestTimedOut(method):
            return "Codex app-server did not answer \(method) in time."
        case let .malformedResponse(details):
            return "Codex app-server returned an unexpected response: \(details)"
        case let .serverError(code, message):
            return code.map { "Codex app-server error \($0): \(message)" } ?? "Codex app-server error: \(message)"
        case .turnAlreadyRunning:
            return "Wait for the current recording plan to finish."
        case let .turnFailed(message):
            return "Codex could not create the plan: \(message)"
        case let .invalidPlan(issues):
            return "Codex returned a plan that needs correction: \(issues.joined(separator: " "))"
        case let .processExited(status, diagnostics):
            return Self.exitDescription(status: status, diagnostics: diagnostics)
        case let .configurationError(status, diagnostics):
            return Self.exitDescription(status: status, diagnostics: diagnostics)
                + "\nUpdate Codex CLI or fix ~/.codex/config.toml."
        }
    }

    /// `diagnostics` are the last stderr lines, already redacted and truncated.
    private static func exitDescription(status: Int32, diagnostics: [String]) -> String {
        let prefix = "Codex app-server exited with status \(status)"
        return diagnostics.isEmpty ? prefix + "." : prefix + ": " + diagnostics.joined(separator: " ")
    }
}

@MainActor
final class CodexDirectorService: ObservableObject {
    @Published private(set) var connectionState: CodexDirectorConnectionState = .disconnected
    @Published private(set) var messages: [CodexDirectorMessage] = []
    @Published private(set) var streamedResponse = ""
    @Published private(set) var currentPlan: CodexRecordingPlan?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var preferences: CodexConnectionPreferences
    @Published private(set) var availableModels: [CodexAvailableModel] = []
    @Published private(set) var accountSummary = "Not connected"
    @Published private(set) var resolvedExecutablePath: String?
    @Published private(set) var connectionTestSummary: String?
    @Published private(set) var loginURL: URL?

    var canCreatePlan: Bool { connectionState == .ready && accountReady }
    var isServerConnected: Bool { process?.isRunning == true && initialized }

    private static let directorInstructions = """
    You are Codex Director inside Focus Studio. Convert the user's product-demo request into a concise, deterministic recording plan. Do not edit files, execute commands, operate the computer, or start a recording. Return only JSON matching the output schema supplied with the turn.

    Capture modes:
    - url: set capture.url to an absolute http/https URL.
    - window: set capture.windowTitle to the visible window or app title.
    - screenshot: use for a still capture; screenshotPath may name a desired local output path or be null.

    When an image is attached, it is the exact visible recording content after any browser toolbar crop. Inspect it carefully and set click x/y coordinates relative to that attached image. Actions execute in order. wait uses seconds. Every click must include x/y coordinates normalized from 0 to 1; label is optional explanatory text. scroll uses pixel-like deltaX/deltaY values; positive deltaY means down. navigate uses an absolute http/https URL. Never propose typing, submitting forms, account changes, purchases, downloads, or destructive actions. Use null for fields that do not apply. Use at most 32 actions, 12 clicks, 4 navigations, and 75 total wait seconds. Include enough waits for navigation and animations to settle, but keep the plan efficient and usually under 40 seconds.
    """

    private let configuration: CodexDirectorConfiguration
    private let preferencesStore: UserDefaults
    private let openLoginURL: @MainActor (URL) -> Void
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var recentDiagnostics: [String] = []
    private var errorStreamClosed = false
    private var pendingExitStatus: Int32?
    private var exitReportTask: Task<Void, Never>?
    private static let diagnosticLineLimit = 20
    private static let diagnosticLengthLimit = 300
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<CodexJSONValue, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var activeThreadID: String?
    private var activeTurnID: String?
    private var completedResponseText: String?
    private var turnDeadlineTask: Task<Void, Never>?
    private var isStopping = false
    private var initialized = false
    private var accountReady = false
    private var pendingLoginID: String?
    private var earlyLoginCompletions: [String: Bool] = [:]
    private var refreshingAccount = false
    private var connectionGeneration = UUID()
    private var activeModel: CodexAvailableModel?

    /// One-shot completions for the AI assistant run on their own thread so the
    /// Director's planning thread and its output schema stay untouched.
    private struct AssistantTurn {
        let token = UUID()
        var id: String?
        var continuation: CheckedContinuation<String, Error>?
        var streamed = ""
        var completedText: String?
        /// A result that arrived before the caller started waiting.
        var pendingResult: Result<String, Error>?
        var deadline: Task<Void, Never>?
    }

    static let assistantTurnTimeout: TimeInterval = 180

    private var assistantThreadID: String?
    private var assistantThreadInstructions: String?
    private var assistantContextGeneration = UUID()
    private var completingAssistantRequest = false
    private var assistantRequestID: UUID?
    private var assistantTurn: AssistantTurn?
    private var interruptingAssistantTurns: Set<UUID> = []
    /// Whether preferences saved by another service instance (Settings › Codex)
    /// are re-read before connecting. Off when the caller supplied explicit
    /// preferences or configuration overrides, as tests do.
    private let syncsPreferencesWithStore: Bool

    init(
        configuration: CodexDirectorConfiguration = .init(),
        preferences: CodexConnectionPreferences? = nil,
        preferencesStore: UserDefaults = .standard,
        openLoginURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.configuration = configuration
        self.preferencesStore = preferencesStore
        self.openLoginURL = openLoginURL
        syncsPreferencesWithStore = preferences == nil && configuration.executableURL == nil && configuration.model == nil
        var saved = preferences ?? .load(from: preferencesStore)
        if let executable = configuration.executableURL { saved.executablePath = executable.path }
        if let model = configuration.model { saved.modelID = model }
        self.preferences = saved
    }

    /// Whether the assistant may send prompts here: signed in, or not yet
    /// connected (the first prompt connects). Sign-in required and failed
    /// connections are excluded until Settings changes something.
    var isAvailableForCompletion: Bool {
        switch connectionState {
        case .needsSignIn, .signingIn, .failed: return false
        case .disconnected, .connecting, .ready, .generating: return true
        }
    }

    deinit {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    func connect() async {
        guard !connectionState.isBusy else { return }
        if isServerConnected {
            await refreshConnection()
            return
        }
        stopProcess()
        let generation = connectionGeneration
        connectionState = .connecting
        lastErrorMessage = nil
        connectionTestSummary = nil

        do {
            try await launchProcess()
            _ = try await request(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("focus_studio_codex_director"),
                        "title": .string("Focus Studio Codex Director"),
                        "version": .string("0.1.0")
                    ])
                ])
            )
            guard generation == connectionGeneration else { return }
            try sendNotification(method: "initialized", params: .object([:]))
            initialized = true
            await refreshConnection()
        } catch {
            guard generation == connectionGeneration else { return }
            stopProcess()
            report(error)
        }
    }

    func savePreferences(_ value: CodexConnectionPreferences) {
        let value = value.normalized
        guard value != preferences else { return }
        disconnect()
        preferences = value
        value.save(to: preferencesStore)
    }

    /// Only metadata is queried; testing the connection never starts a model turn.
    func refreshConnection() async {
        guard isServerConnected, !refreshingAccount else { return }
        refreshingAccount = true
        if pendingLoginID == nil { connectionState = .connecting }
        let generation = connectionGeneration
        defer {
            if generation == connectionGeneration { refreshingAccount = false }
        }
        do {
            let account = try await request(method: "account/read", params: .object(["refreshToken": .bool(false)]))
            guard generation == connectionGeneration else { return }
            let details = account.objectValue?["account"]?.objectValue
            let requiresAuth = account.objectValue?["requiresOpenaiAuth"]?.boolValue ?? true
            accountReady = details != nil || !requiresAuth
            if let details {
                let type = details["type"]?.stringValue ?? "Account"
                if type == "chatgpt" {
                    accountSummary = ["ChatGPT", details["email"]?.stringValue, details["planType"]?.stringValue]
                        .compactMap { $0 }.joined(separator: " · ")
                } else {
                    accountSummary = type == "apiKey" ? "OpenAI API key" : type
                }
            } else {
                accountSummary = requiresAuth ? "Not signed in" : "Configured provider"
            }
            guard accountReady else {
                availableModels = []
                connectionTestSummary = "Codex connected. Sign in to finish setup."
                connectionState = pendingLoginID == nil ? .needsSignIn : .signingIn
                return
            }
            var models: [CodexAvailableModel] = []
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                var params: [String: CodexJSONValue] = ["limit": .number(100), "includeHidden": .bool(false)]
                if let cursor { params["cursor"] = .string(cursor) }
                let result = try await request(method: "model/list", params: .object(params))
                guard generation == connectionGeneration else { return }
                models += result.objectValue?["data"]?.arrayValue?.compactMap(CodexAvailableModel.init(json:)) ?? []
                cursor = result.objectValue?["nextCursor"]?.stringValue
                if let cursor, !seenCursors.insert(cursor).inserted { break }
            } while cursor != nil
            availableModels = models
            if !preferences.modelID.isEmpty, !models.contains(where: { $0.id == preferences.modelID }) {
                throw CodexDirectorServiceError.modelUnavailable(preferences.modelID)
            }
            guard !models.isEmpty else {
                throw CodexDirectorServiceError.malformedResponse("no available models; check account access or update Codex")
            }
            let chosen = models.first { $0.id == preferences.modelID }
                ?? models.first { $0.isDefault } ?? models.first
            // A model change needs a fresh assistant thread, unless a turn is in
            // flight on the current one (its notifications must keep routing).
            if chosen != activeModel, assistantTurn == nil { assistantThreadID = nil }
            activeModel = chosen
            activeThreadID = nil
            lastErrorMessage = nil
            connectionTestSummary = "Connection verified · \(models.count) available models"
            connectionState = .ready
        } catch {
            guard generation == connectionGeneration else { return }
            report(error)
        }
    }

    func signInWithChatGPT() async {
        guard isServerConnected, preferences.accountScope == .focusStudio, !connectionState.isBusy else { return }
        connectionState = .signingIn
        lastErrorMessage = nil
        earlyLoginCompletions.removeAll()
        let generation = connectionGeneration
        do {
            let result = try await request(method: "account/login/start", params: .object(["type": .string("chatgpt")]))
            guard generation == connectionGeneration else { return }
            guard let loginID = result.objectValue?["loginId"]?.stringValue,
                  let address = result.objectValue?["authUrl"]?.stringValue,
                  let url = URL(string: address), url.scheme == "https", url.host != nil else {
                throw CodexDirectorServiceError.malformedResponse("login/start omitted the secure browser login URL")
            }
            pendingLoginID = loginID
            loginURL = url
            if let success = earlyLoginCompletions.removeValue(forKey: loginID) {
                completeBrowserSignIn(success: success)
            } else {
                openLoginURL(url)
            }
        } catch {
            guard generation == connectionGeneration else { return }
            connectionState = .needsSignIn
            lastErrorMessage = error.localizedDescription
        }
    }

    func signInWithAPIKey(_ apiKey: String) async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isServerConnected, preferences.accountScope == .focusStudio,
              !connectionState.isBusy, !key.isEmpty else { return }
        connectionState = .signingIn
        lastErrorMessage = nil
        let generation = connectionGeneration
        do {
            // The key only travels over the local pipe. Codex stores it in Keychain.
            _ = try await request(method: "account/login/start", params: .object([
                "type": .string("apiKey"), "apiKey": .string(key)
            ]))
            guard generation == connectionGeneration else { return }
            await refreshConnection()
        } catch {
            guard generation == connectionGeneration else { return }
            connectionState = .needsSignIn
            // Some third-party CLI versions echo params in errors: never display them.
            lastErrorMessage = "API key sign-in failed. Check the key and Keychain access, then try again."
        }
    }

    func cancelSignIn() async {
        guard let loginID = pendingLoginID else { return }
        let generation = connectionGeneration
        pendingLoginID = nil
        loginURL = nil
        _ = try? await request(method: "account/login/cancel", params: .object(["loginId": .string(loginID)]))
        guard generation == connectionGeneration else { return }
        await refreshConnection()
    }

    func signOut() async {
        guard isServerConnected, preferences.accountScope == .focusStudio, !connectionState.isBusy else { return }
        let generation = connectionGeneration
        connectionState = .connecting
        do {
            _ = try await request(method: "account/logout", params: .object([:]))
            guard generation == connectionGeneration else { return }
            await refreshConnection()
        } catch {
            guard generation == connectionGeneration else { return }
            report(error)
        }
    }

    private func startPlanningThread() async throws {
        guard accountReady else { throw CodexDirectorServiceError.signInRequired }
        let generation = connectionGeneration
        var params: [String: CodexJSONValue] = [
            "cwd": .string(configuration.workingDirectoryURL.path),
            "developerInstructions": .string(Self.directorInstructions),
            "approvalPolicy": .string("never"),
            "sandbox": .string("read-only"),
            "ephemeral": .bool(true)
        ]
        if let activeModel { params["model"] = .string(activeModel.id) }
        let result = try await request(method: "thread/start", params: .object(params))
        guard generation == connectionGeneration else { throw CancellationError() }
        guard let id = result.objectValue?["thread"]?.objectValue?["id"]?.stringValue else {
            throw CodexDirectorServiceError.malformedResponse("thread/start omitted thread.id")
        }
        activeThreadID = id
    }

    func disconnect() {
        stopProcess()
        connectionState = .disconnected
        lastErrorMessage = nil
        connectionTestSummary = nil
        accountSummary = "Not connected"
        availableModels = []
    }

    func interruptCurrentTurn() async {
        guard let threadID = activeThreadID, let turnID = activeTurnID else {
            if connectionState == .generating {
                // Initialization can still be awaiting a thread/turn id. Closing
                // only our local connection cancels it without leaving a queued turn.
                disconnect()
                messages.append(.init(role: .status, text: "Planning stopped. Connect again to create another plan."))
            }
            return
        }
        let generation = connectionGeneration
        turnDeadlineTask?.cancel()
        turnDeadlineTask = nil
        do {
            _ = try await request(
                method: "turn/interrupt",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID)
                ])
            )
        } catch {
            guard generation == connectionGeneration else { return }
            report(error, preserveConnection: process?.isRunning == true)
        }
    }

    func sendPrompt(_ prompt: String, screenshotURL: URL? = nil) async {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard connectionState != .generating else {
            lastErrorMessage = CodexDirectorServiceError.turnAlreadyRunning.localizedDescription
            return
        }

        guard canCreatePlan else {
            lastErrorMessage = CodexDirectorServiceError.signInRequired.localizedDescription
            return
        }
        connectionState = .generating
        let generation = connectionGeneration
        do {
            if activeThreadID == nil { try await startPlanningThread() }
            guard generation == connectionGeneration else { return }
        } catch {
            guard generation == connectionGeneration else { return }
            report(error, preserveConnection: true)
            return
        }
        guard let threadID = activeThreadID, process?.isRunning == true else { return }

        messages.append(.init(role: .user, text: prompt))
        streamedResponse = ""
        completedResponseText = nil
        currentPlan = nil
        activeTurnID = nil
        lastErrorMessage = nil
        connectionState = .generating

        do {
            var input: [CodexJSONValue] = [
                .object([
                    "type": .string("text"),
                    "text": .string(prompt)
                ])
            ]
            if let screenshotURL {
                guard activeModel?.supportsImages != false else {
                    throw CodexDirectorServiceError.turnFailed("The selected model does not accept screenshots. Choose a model with image support in Connection settings.")
                }
                input.append(
                    .object([
                        "type": .string("localImage"),
                        "path": .string(screenshotURL.standardizedFileURL.path),
                        "detail": .string("high")
                    ])
                )
            }
            var turnParameters: [String: CodexJSONValue] = [
                "threadId": .string(threadID),
                "input": .array(input),
                "outputSchema": CodexRecordingPlan.appServerOutputSchema
            ]
            if let effort = activeModel?.defaultEffort { turnParameters["effort"] = .string(effort) }
            let result = try await request(
                method: "turn/start",
                params: .object(turnParameters)
            )
            guard generation == connectionGeneration, connectionState == .generating else { return }
            guard let turnID = result.objectValue?["turn"]?.objectValue?["id"]?.stringValue else {
                throw CodexDirectorServiceError.malformedResponse("turn/start omitted turn.id")
            }
            activeTurnID = turnID
            turnDeadlineTask?.cancel()
            turnDeadlineTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(120))
                    await self?.interruptCurrentTurn()
                } catch {
                    // A completed or manually interrupted turn cancels the deadline.
                }
            }
        } catch {
            guard generation == connectionGeneration else { return }
            report(error, preserveConnection: process?.isRunning == true)
        }
    }

    // MARK: - Assistant completions

    /// Runs one prompt on a dedicated read-only thread and returns the final
    /// agent message. Connects (and re-reads the Settings › Codex preferences)
    /// when needed; a missing sign-in is reported as a clear error. `json`
    /// asks for any JSON object via `outputSchema`. Times out after
    /// ``assistantTurnTimeout``; cancelling the calling task interrupts the turn.
    func completeText(developerInstructions: String, prompt: String, json: Bool) async throws -> String {
        guard assistantRequestID == nil else { throw CodexDirectorServiceError.turnAlreadyRunning }
        let requestID = UUID()
        assistantRequestID = requestID
        defer { assistantRequestID = nil }
        return try await withTaskCancellationHandler {
            do {
                return try await performAssistantCompletion(developerInstructions: developerInstructions, prompt: prompt, json: json)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.assistantRequestID == requestID else { return }
                if self.assistantTurn?.id == nil {
                    // No interruptible turn exists yet. Closing this dedicated
                    // transport cancels preparation requests, not the account.
                    self.disconnect()
                } else {
                    await self.interruptAssistantTurn()
                }
            }
        }
    }

    private func performAssistantCompletion(developerInstructions: String, prompt: String, json: Bool) async throws -> String {
        guard assistantTurn == nil, !completingAssistantRequest else { throw CodexDirectorServiceError.turnAlreadyRunning }
        completingAssistantRequest = true
        defer { completingAssistantRequest = false }
        let contextGeneration = assistantContextGeneration
        if syncsPreferencesWithStore { reloadPreferencesFromStore() }
        try await ensureConnectedForCompletion()
        guard contextGeneration == assistantContextGeneration else { throw CancellationError() }
        if assistantThreadID == nil || assistantThreadInstructions != developerInstructions {
            try await startAssistantThread(instructions: developerInstructions)
        }
        guard contextGeneration == assistantContextGeneration else { throw CancellationError() }
        guard let threadID = assistantThreadID, process?.isRunning == true else {
            throw CodexDirectorServiceError.processUnavailable
        }
        try Task.checkCancellation()

        var parameters: [String: CodexJSONValue] = [
            "threadId": .string(threadID),
            "input": .array([.object(["type": .string("text"), "text": .string(prompt)])])
        ]
        if json {
            parameters["outputSchema"] = .object(["type": .string("object"), "additionalProperties": .bool(true)])
        }
        if let effort = activeModel?.defaultEffort { parameters["effort"] = .string(effort) }

        // The turn record exists before the request goes out: the completion
        // notification can be processed before the turn/start response resumes us.
        assistantTurn = AssistantTurn()
        let generation = connectionGeneration
        let response: CodexJSONValue
        do {
            response = try await request(method: "turn/start", params: .object(parameters))
        } catch {
            if generation == connectionGeneration { assistantTurn = nil }
            throw error
        }
        guard generation == connectionGeneration, assistantTurn != nil else { throw CodexDirectorServiceError.connectionClosed }
        guard let turnID = response.objectValue?["turn"]?.objectValue?["id"]?.stringValue else {
            assistantTurn = nil
            throw CodexDirectorServiceError.malformedResponse("turn/start omitted turn.id")
        }
        assistantTurn?.id = turnID
        if Task.isCancelled {
            await interruptAssistantTurn()
            throw CancellationError()
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            if let result = assistantTurn?.pendingResult {
                assistantTurn = nil
                continuation.resume(with: result)
                return
            }
            assistantTurn?.continuation = continuation
            assistantTurn?.deadline = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(Self.assistantTurnTimeout))
                    await self?.timeoutAssistantTurn()
                } catch {
                    // The turn finished and cancelled its deadline.
                }
            }
        }
    }

    /// Settings › Codex saves through another service instance; pick up its
    /// executable, model and account scope before talking to the server.
    private func reloadPreferencesFromStore() {
        let saved = CodexConnectionPreferences.load(from: preferencesStore).normalized
        guard saved != preferences else { return }
        disconnect()
        preferences = saved
    }

    private func ensureConnectedForCompletion() async throws {
        if !isServerConnected {
            await connect()
        } else if !canCreatePlan, !connectionState.isBusy {
            await refreshConnection()
        }
        // Another caller may already be connecting or refreshing: wait for it.
        var waited = 0
        while connectionState.isBusy, !canCreatePlan, waited < 600 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        guard canCreatePlan else {
            if case let .failed(message) = connectionState {
                throw CodexDirectorServiceError.assistantUnavailable(message)
            }
            throw CodexDirectorServiceError.assistantSignInRequired
        }
    }

    private func startAssistantThread(instructions: String) async throws {
        guard accountReady else { throw CodexDirectorServiceError.assistantSignInRequired }
        let generation = connectionGeneration
        let contextGeneration = assistantContextGeneration
        var params: [String: CodexJSONValue] = [
            "cwd": .string(configuration.workingDirectoryURL.path),
            "developerInstructions": .string(instructions),
            "approvalPolicy": .string("never"),
            "sandbox": .string("read-only"),
            "ephemeral": .bool(true)
        ]
        if let activeModel { params["model"] = .string(activeModel.id) }
        let result = try await request(method: "thread/start", params: .object(params))
        guard generation == connectionGeneration, contextGeneration == assistantContextGeneration else { throw CancellationError() }
        guard let id = result.objectValue?["thread"]?.objectValue?["id"]?.stringValue else {
            throw CodexDirectorServiceError.malformedResponse("thread/start omitted thread.id")
        }
        assistantThreadID = id
        assistantThreadInstructions = instructions
    }

    private func handleAssistantNotification(method: String, params: [String: CodexJSONValue]) {
        switch method {
        case "turn/started":
            if assistantTurn != nil, assistantTurn?.id == nil,
               let turnID = params["turn"]?.objectValue?["id"]?.stringValue {
                assistantTurn?.id = turnID
            }
        case "item/agentMessage/delta":
            guard assistantTurn != nil, assistantTurnMatches(params["turnId"]?.stringValue),
                  let delta = params["delta"]?.stringValue else { return }
            assistantTurn?.streamed += delta
        case "item/completed":
            guard assistantTurn != nil, assistantTurnMatches(params["turnId"]?.stringValue),
                  let item = params["item"]?.objectValue,
                  item["type"]?.stringValue == "agentMessage",
                  item["phase"]?.stringValue != "commentary",
                  let text = item["text"]?.stringValue
            else { return }
            assistantTurn?.completedText = text
        case "turn/completed":
            guard let turn = params["turn"]?.objectValue, assistantTurn != nil,
                  assistantTurnMatches(turn["id"]?.stringValue) else { return }
            finishAssistantTurn(turn)
        case "error":
            guard assistantTurn != nil, let message = params["message"]?.stringValue else { return }
            resolveAssistantTurn(.failure(CodexDirectorServiceError.turnFailed(message)))
        default:
            break
        }
    }

    private func assistantTurnMatches(_ turnID: String?) -> Bool {
        guard let expected = assistantTurn?.id, let turnID else { return true }
        return expected == turnID
    }

    private func finishAssistantTurn(_ turn: [String: CodexJSONValue]) {
        let status = turn["status"]?.stringValue ?? "failed"
        switch status {
        case "interrupted":
            resolveAssistantTurn(.failure(CancellationError()))
        case "completed":
            let text = finalAgentText(in: turn) ?? assistantTurn?.completedText ?? assistantTurn?.streamed ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resolveAssistantTurn(.failure(CodexDirectorServiceError.malformedResponse("the completed turn had no final agent message")))
            } else {
                resolveAssistantTurn(.success(text))
            }
        default:
            let message = turn["error"]?.objectValue?["message"]?.stringValue ?? status
            resolveAssistantTurn(.failure(CodexDirectorServiceError.turnFailed(message)))
        }
    }

    /// Delivers the result to the waiting caller, or parks it until the caller
    /// starts waiting (the notification can precede the turn/start response).
    private func resolveAssistantTurn(_ result: Result<String, Error>) {
        guard var turn = assistantTurn else { return }
        turn.deadline?.cancel()
        turn.deadline = nil
        if let continuation = turn.continuation {
            assistantTurn = nil
            continuation.resume(with: result)
        } else {
            turn.pendingResult = result
            assistantTurn = turn
        }
    }

    private func interruptAssistantTurn() async {
        guard let turn = assistantTurn, interruptingAssistantTurns.insert(turn.token).inserted else { return }
        defer { interruptingAssistantTurns.remove(turn.token) }
        if let threadID = assistantThreadID, let turnID = turn.id, process?.isRunning == true {
            _ = try? await request(
                method: "turn/interrupt",
                params: .object(["threadId": .string(threadID), "turnId": .string(turnID)])
            )
        }
        guard assistantTurn?.token == turn.token else { return }
        resolveAssistantTurn(.failure(CancellationError()))
    }

    /// New chat/provider switches must not retain hidden server-side messages.
    /// Authentication remains connected; the next message starts a fresh thread.
    func resetAssistantConversation() async {
        assistantContextGeneration = UUID()
        await interruptAssistantTurn()
        assistantThreadID = nil
        assistantThreadInstructions = nil
    }

    private func timeoutAssistantTurn() async {
        guard let token = assistantTurn?.token else { return }
        if let threadID = assistantThreadID, let turnID = assistantTurn?.id, process?.isRunning == true {
            _ = try? await request(
                method: "turn/interrupt",
                params: .object(["threadId": .string(threadID), "turnId": .string(turnID)])
            )
        }
        guard assistantTurn?.token == token else { return }
        resolveAssistantTurn(.failure(CodexDirectorServiceError.requestTimedOut("turn/completed")))
    }

    private func launchProcess() async throws {
        let generation = connectionGeneration
        // Automatic detection probes every installation's version off the main
        // actor. A disconnect while probing must not start an orphaned server.
        let executableURL = try await CodexExecutableDiscovery.resolveExecutable(explicitPath: preferences.executablePath)
        guard generation == connectionGeneration else { throw CancellationError() }
        resolvedExecutablePath = executableURL.path
        try FileManager.default.createDirectory(
            at: configuration.workingDirectoryURL,
            withIntermediateDirectories: true
        )
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = executableURL
        // No transport option is required: stdio is the documented default,
        // including on versions that predate the --stdio alias.
        process.arguments = ["app-server"]
        process.currentDirectoryURL = configuration.workingDirectoryURL
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = CodexExecutableDiscovery.launchPath(for: executableURL, environment: environment)
        if preferences.accountScope == .focusStudio {
            try FileManager.default.createDirectory(at: configuration.accountDirectoryURL, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configuration.accountDirectoryURL.path)
            // A separate app-specific Codex home prevents sign-in/sign-out here
            // from replacing the user's desktop/terminal Codex credentials.
            environment["CODEX_HOME"] = configuration.accountDirectoryURL.path
            for key in CodexExecutableDiscovery.credentialEnvironmentKeys {
                environment.removeValue(forKey: key)
            }
            process.arguments = ["app-server", "-c", "cli_auth_credentials_store=\"keyring\""]
        }
        process.environment = environment
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard self?.connectionGeneration == generation else { return }
                self?.processDidExit(status: process.terminationStatus)
            }
        }

        try process.run()
        self.process = process
        inputHandle = standardInput.fileHandleForWriting
        outputHandle = standardOutput.fileHandleForReading
        errorHandle = standardError.fileHandleForReading
        outputBuffer.removeAll(keepingCapacity: true)
        errorBuffer.removeAll(keepingCapacity: true)
        recentDiagnostics.removeAll()
        errorStreamClosed = false
        pendingExitStatus = nil
        isStopping = false

        outputHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                guard self?.connectionGeneration == generation else { return }
                self?.receiveOutput(data)
            }
        }

        errorHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in
                guard self?.connectionGeneration == generation else { return }
                if data.isEmpty {
                    self?.errorStreamDidClose()
                } else {
                    self?.receiveErrorOutput(data)
                }
            }
        }
    }

    private func receiveOutput(_ data: Data) {
        outputBuffer.append(data)
        consumeLines(in: &outputBuffer) { [weak self] line in
            self?.receive(line: line)
        }
    }

    private func receiveErrorOutput(_ data: Data) {
        errorBuffer.append(data)
        consumeLines(in: &errorBuffer) { [weak self] line in
            self?.receiveDiagnostic(line)
        }
    }

    private func consumeLines(
        in buffer: inout Data,
        handler: (String) -> Void
    ) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if lineData.last == 0x0D { lineData.removeLast() }
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8)
            else { continue }
            handler(line)
        }
    }

    private func request(method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        guard process?.isRunning == true else {
            throw CodexDirectorServiceError.processUnavailable
        }

        let id = nextRequestID
        nextRequestID += 1
        let envelope: CodexJSONValue = .object([
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params
        ])

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            do {
                try write(envelope)
                let nanoseconds = UInt64(max(1, configuration.requestTimeout) * 1_000_000_000)
                timeoutTasks[id] = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                        self?.timeoutRequest(id: id, method: method)
                    } catch {
                        // The response arrived and cancelled the timeout.
                    }
                }
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: CodexJSONValue) throws {
        try write(.object([
            "method": .string(method),
            "params": params
        ]))
    }

    private func write(_ message: CodexJSONValue) throws {
        guard let inputHandle else {
            throw CodexDirectorServiceError.processUnavailable
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(message)
        if ProcessInfo.processInfo.environment["FOCUS_STUDIO_PROTOCOL_LOG"] == "1" {
            // Never log payloads: login params contain secrets, while responses
            // and notifications may contain tokens, OAuth URLs, or user content.
            print("[FocusStudio → Codex] \(message.objectValue?["method"]?.stringValue ?? "response")")
        }
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func receive(line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let message: CodexJSONValue
        do {
            message = try JSONDecoder().decode(CodexJSONValue.self, from: data)
        } catch {
            receiveDiagnostic("Invalid app-server JSONL")
            return
        }
        guard let object = message.objectValue else { return }
        if ProcessInfo.processInfo.environment["FOCUS_STUDIO_PROTOCOL_LOG"] == "1" {
            print("[Codex → FocusStudio] \(object["method"]?.stringValue ?? "response")")
        }

        if let id = object["id"]?.integerValue,
           object["result"] != nil || object["error"] != nil {
            completeRequest(id: id, envelope: object)
            return
        }

        guard let method = object["method"]?.stringValue else { return }
        let params = object["params"]?.objectValue ?? [:]
        handleNotification(method: method, params: params)
    }

    private func completeRequest(id: Int, envelope: [String: CodexJSONValue]) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }

        if let error = envelope["error"]?.objectValue {
            continuation.resume(throwing: CodexDirectorServiceError.serverError(
                code: error["code"]?.integerValue,
                message: error["message"]?.stringValue ?? "Unknown error"
            ))
        } else {
            continuation.resume(returning: envelope["result"] ?? .null)
        }
    }

    private func timeoutRequest(id: Int, method: String) {
        timeoutTasks.removeValue(forKey: id)
        pendingRequests.removeValue(forKey: id)?.resume(
            throwing: CodexDirectorServiceError.requestTimedOut(method)
        )
    }

    private func handleNotification(method: String, params: [String: CodexJSONValue]) {
        if let assistantThreadID, params["threadId"]?.stringValue == assistantThreadID {
            handleAssistantNotification(method: method, params: params)
            return
        }
        if let threadID = params["threadId"]?.stringValue,
           let activeThreadID,
           threadID != activeThreadID {
            return
        }

        switch method {
        case "account/login/completed":
            let loginID = params["loginId"]?.stringValue
            let success = params["success"]?.boolValue == true
            // Both lines can arrive in one pipe read, before the awaiting
            // login/start caller resumes and learns its loginId.
            if let loginID, pendingLoginID == nil, connectionState == .signingIn {
                earlyLoginCompletions[loginID] = success
                return
            }
            guard pendingLoginID != nil, loginID == pendingLoginID else { return }
            completeBrowserSignIn(success: success)
        case "account/updated":
            // Explicit auth requests refresh after their response. This also
            // catches auth changes initiated by an existing shared Codex login.
            if connectionState != .signingIn && connectionState != .generating {
                Task { await refreshConnection() }
            }
        case "turn/started":
            if let turnID = params["turn"]?.objectValue?["id"]?.stringValue {
                activeTurnID = turnID
            }
        case "item/agentMessage/delta":
            guard matchesActiveTurn(params) else { return }
            if let delta = params["delta"]?.stringValue {
                streamedResponse += delta
            }
        case "item/completed":
            guard matchesActiveTurn(params),
                  let item = params["item"]?.objectValue,
                  item["type"]?.stringValue == "agentMessage",
                  item["phase"]?.stringValue != "commentary",
                  let text = item["text"]?.stringValue
            else { return }
            completedResponseText = text
        case "turn/completed":
            guard let turn = params["turn"]?.objectValue else { return }
            let turnID = turn["id"]?.stringValue
            guard activeTurnID == nil || turnID == activeTurnID else { return }
            finishTurn(turn)
        case "error":
            if let message = params["message"]?.stringValue {
                report(CodexDirectorServiceError.turnFailed(
                    connectionState == .signingIn ? "Sign-in failed. Please try again." : message
                ), preserveConnection: true)
            }
        default:
            break
        }
    }

    private func matchesActiveTurn(_ params: [String: CodexJSONValue]) -> Bool {
        guard let activeTurnID else { return true }
        return params["turnId"]?.stringValue == activeTurnID
    }

    private func completeBrowserSignIn(success: Bool) {
        pendingLoginID = nil
        loginURL = nil
        if success {
            Task { await refreshConnection() }
        } else {
            connectionState = .needsSignIn
            lastErrorMessage = "Sign-in was not completed. Please try again."
        }
    }

    private func finishTurn(_ turn: [String: CodexJSONValue]) {
        let status = turn["status"]?.stringValue ?? "failed"
        turnDeadlineTask?.cancel()
        turnDeadlineTask = nil
        defer { activeTurnID = nil }

        if status == "interrupted" {
            streamedResponse = ""
            completedResponseText = nil
            messages.append(.init(role: .status, text: "Planning stopped."))
            connectionState = .ready
            lastErrorMessage = nil
            return
        }

        guard status == "completed" else {
            let message = turn["error"]?.objectValue?["message"]?.stringValue ?? status
            report(CodexDirectorServiceError.turnFailed(message), preserveConnection: true)
            return
        }

        let finalText = finalAgentText(in: turn) ?? completedResponseText ?? streamedResponse
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report(
                CodexDirectorServiceError.malformedResponse("the completed turn had no final agent message"),
                preserveConnection: true
            )
            return
        }

        streamedResponse = finalText
        messages.append(.init(role: .assistant, text: finalText))
        do {
            let plan = try decodePlan(from: finalText)
            currentPlan = plan
            lastErrorMessage = nil
            connectionState = .ready
        } catch {
            report(error, preserveConnection: true)
        }
    }

    private func finalAgentText(in turn: [String: CodexJSONValue]) -> String? {
        let messages = turn["items"]?.arrayValue?.compactMap { value -> (String?, String)? in
            guard let item = value.objectValue,
                  item["type"]?.stringValue == "agentMessage",
                  let text = item["text"]?.stringValue
            else { return nil }
            return (item["phase"]?.stringValue, text)
        } ?? []
        return messages.last(where: { $0.0 == "final_answer" })?.1 ?? messages.last?.1
    }

    private func decodePlan(from response: String) throws -> CodexRecordingPlan {
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            let lines = json.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 3 {
                json = lines.dropFirst().dropLast().joined(separator: "\n")
            }
        }
        guard let data = json.data(using: .utf8) else {
            throw CodexDirectorServiceError.malformedResponse("the final response was not UTF-8")
        }
        let plan = try JSONDecoder().decode(CodexRecordingPlan.self, from: data)
        let issues = plan.validationIssues
        guard issues.isEmpty else {
            throw CodexDirectorServiceError.invalidPlan(issues)
        }
        return plan
    }

    /// Diagnostics from an external executable may echo login params. Raw
    /// stderr stays out of console logs; only redacted, truncated lines are
    /// buffered, and they are shown solely when the server dies during setup.
    private func receiveDiagnostic(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["FOCUS_STUDIO_PROTOCOL_LOG"] == "1" {
            print("[Codex app-server] diagnostic received (content omitted)")
        }
        #endif
        recentDiagnostics.append(Self.redactedDiagnostic(trimmed))
        if recentDiagnostics.count > Self.diagnosticLineLimit {
            recentDiagnostics.removeFirst(recentDiagnostics.count - Self.diagnosticLineLimit)
        }
    }

    /// Replaces API keys, bearer tokens, and key=value secrets before a stderr
    /// line can reach the UI, then bounds its length.
    static func redactedDiagnostic(_ line: String) -> String {
        var text = line
        for pattern in [#/sk-[A-Za-z0-9_-]+/#, #/Bearer \S+/#, #/"apiKey"\s*:\s*"[^"]*"/#, #/key=\S+/#] {
            text = text.replacing(pattern.ignoresCase(), with: "[redacted]")
        }
        guard text.count > diagnosticLengthLimit else { return text }
        return String(text.prefix(diagnosticLengthLimit)) + "…"
    }

    private func processDidExit(status: Int32) {
        guard !isStopping else { return }
        // stderr data and termination arrive from separate queues. Wait briefly
        // for the stream to close so the final lines make it into the error.
        guard !errorStreamClosed else {
            finishExit(status: status)
            return
        }
        pendingExitStatus = status
        let generation = connectionGeneration
        exitReportTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.connectionGeneration == generation,
                  let status = self.pendingExitStatus else { return }
            self.finishExit(status: status)
        }
    }

    private func errorStreamDidClose() {
        errorStreamClosed = true
        // A final message without a trailing newline is still a diagnostic.
        if !errorBuffer.isEmpty, let rest = String(data: errorBuffer, encoding: .utf8) {
            errorBuffer.removeAll(keepingCapacity: false)
            receiveDiagnostic(rest)
        }
        if let status = pendingExitStatus { finishExit(status: status) }
    }

    private func finishExit(status: Int32) {
        exitReportTask?.cancel()
        exitReportTask = nil
        pendingExitStatus = nil
        // Only setup-phase output is surfaced: after the handshake, stderr may
        // echo sign-in params or user content.
        let duringSetup = !initialized || connectionState == .connecting
        let diagnostics = status != 0 && duringSetup ? Array(recentDiagnostics.suffix(3)) : []
        stopProcess()
        let mentionsConfiguration = diagnostics.contains { $0.contains("Error loading configuration") }
        report(
            mentionsConfiguration
                ? CodexDirectorServiceError.configurationError(status: status, diagnostics: diagnostics)
                : CodexDirectorServiceError.processExited(status: status, diagnostics: diagnostics),
            preserveConnection: false
        )
    }

    private func stopProcess() {
        connectionGeneration = UUID()
        isStopping = true
        initialized = false
        accountReady = false
        refreshingAccount = false
        pendingLoginID = nil
        earlyLoginCompletions.removeAll()
        loginURL = nil
        activeModel = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        try? outputHandle?.close()
        try? errorHandle?.close()
        outputHandle = nil
        errorHandle = nil
        outputBuffer.removeAll(keepingCapacity: false)
        errorBuffer.removeAll(keepingCapacity: false)
        process?.terminationHandler = nil
        try? inputHandle?.close()
        inputHandle = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        activeThreadID = nil
        activeTurnID = nil
        assistantThreadID = nil
        assistantThreadInstructions = nil
        resolveAssistantTurn(.failure(CodexDirectorServiceError.connectionClosed))
        assistantTurn = nil
        turnDeadlineTask?.cancel()
        turnDeadlineTask = nil
        exitReportTask?.cancel()
        exitReportTask = nil
        pendingExitStatus = nil

        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        let requests = Array(pendingRequests.values)
        pendingRequests.removeAll()
        requests.forEach { $0.resume(throwing: CodexDirectorServiceError.connectionClosed) }
        isStopping = false
    }

    private func report(_ error: Error, preserveConnection: Bool = false) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastErrorMessage = message
        connectionState = preserveConnection && process?.isRunning == true
            ? .ready
            : .failed(message)
    }
}
