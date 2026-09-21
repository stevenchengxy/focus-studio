import Foundation

/// Offline coverage for the AI gateway: provider table, model recommendation,
/// JSON extraction, request bodies for both transports, the store with an
/// in-memory keychain, and HTTP behaviour against a URLProtocol mock.
@main
struct AIGatewayTests {
    @MainActor
    static func main() async throws {
        providerTable()
        recommendations()
        jsonExtraction()
        try requestBuilding()
        try storeRoundTrip()
        try await mockedTransport()
        try await storeTesting()
        print("AIGatewayTests: PASS (provider table, recommendations, JSON extraction, request bodies, store + keychain privacy, mocked HTTP, connection tests)")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
    }

    static func json(_ data: Data?) -> [String: Any] {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("FAIL: body is not a JSON object")
        }
        return object
    }

    // MARK: - Provider table

    static func providerTable() {
        for kind in AIProviderKind.allCases {
            check(kind == .custom || kind.defaultBaseURL.hasPrefix("https://"), "\(kind) has an https default base URL")
            check(kind == .custom || kind.consoleURL != nil, "\(kind) has a console URL")
            check((kind == .anthropic) == (kind.transport == .anthropicMessages), "\(kind) transport")
            check(AIProviderKind(rawValue: kind.rawValue) == kind, "stable raw value")
        }
        check(AIProviderKind.allCases.count == 8, "eight providers")
        check(!AIProviderKind.anthropic.supportsJSONResponseFormat && !AIProviderKind.custom.supportsJSONResponseFormat
              && AIProviderKind.deepSeek.supportsJSONResponseFormat && AIProviderKind.volcengineArk.supportsJSONResponseFormat,
              "json mode support table")
        var configuration = AIProviderConfiguration(kind: .custom)
        configuration.baseURLOverride = " http://localhost:11434/v1/ "
        check(configuration.effectiveBaseURL == "http://localhost:11434/v1", "override is trimmed: \(configuration.effectiveBaseURL)")
        check(AIProviderConfiguration(kind: .openAI).effectiveBaseURL == "https://api.openai.com/v1", "default base URL")
    }

    // MARK: - Recommendations

    static func recommendations() {
        func recommend(_ kind: AIProviderKind, _ ids: [String]) -> String? { kind.recommendedModelID(from: ids) }
        check(recommend(.openAI, ["gpt-4o", "gpt-5.5-2026-04-23", "gpt-5.5-pro", "gpt-5.5", "text-embedding-3-small", "gpt-5-mini"]) == "gpt-5.5",
              "OpenAI prefers the plain newest id")
        check(recommend(.openAI, ["text-embedding-3-small", "gpt-5-mini", "gpt-5-nano"]) == "gpt-5-mini", "OpenAI gpt-5 family substring")
        check(recommend(.openAI, ["text-embedding-3-small"]) == "text-embedding-3-small", "never nil for a non-empty list")
        check(recommend(.openAI, []) == nil, "nil for an empty list")
        check(recommend(.anthropic, ["claude-sonnet-4-5-20250929", "claude-opus-4-8", "claude-opus-4-7", "claude-sonnet-5", "claude-haiku-4-5"]) == "claude-sonnet-5",
              "Anthropic sonnet 5 before opus 4.x")
        check(recommend(.anthropic, ["claude-sonnet-5", "claude-opus-5"]) == "claude-opus-5", "Anthropic opus 5 first")
        check(recommend(.anthropic, ["claude-opus-4-6", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-1-20250805"]) == "claude-opus-4-8",
              "newest sibling among equal-length ids")
        check(recommend(.deepSeek, ["deepseek-chat", "deepseek-reasoner"]) == "deepseek-chat", "DeepSeek chat model")
        check(recommend(.deepSeek, ["deepseek-v4-pro", "deepseek-v4-flash"]) == "deepseek-v4-flash", "DeepSeek V4 flash first")
        check(recommend(.glm, ["glm-4.5", "glm-4.6", "glm-5", "glm-5-flash"]) == "glm-5", "GLM 5 exact match")
        check(recommend(.glm, ["glm-4.5", "glm-4.6v", "glm-4.6"]) == "glm-4.6", "GLM 4.6 exact match beats 4.6v")
        check(recommend(.kimi, ["moonshot-v1-8k", "kimi-k2-turbo-preview", "kimi-k2-0711-preview", "kimi-latest"]) == "kimi-k2-0711-preview",
              "Kimi k2 shortest id")
        check(recommend(.openRouter, ["openai/gpt-5.5", "anthropic/claude-sonnet-5:thinking", "anthropic/claude-sonnet-5"]) == "anthropic/claude-sonnet-5",
              "OpenRouter plain sonnet 5")
        check(recommend(.volcengineArk, ["doubao-seed-1-6-250615", "doubao-seed-1-6-flash-250615", "doubao-seed-2-0-pro-260215"]) == "doubao-seed-2-0-pro-260215",
              "Ark seed 2.0 dashed id")
        check(recommend(.custom, ["text-embedding-3-large", "llama-3.3-70b", "qwen3"]) == "llama-3.3-70b", "custom skips embeddings")
    }

    // MARK: - JSON extraction

    static func jsonExtraction() {
        func extract(_ text: String) -> [String: Any]? {
            guard let data = AIGatewayClient.extractJSONObject(from: text) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        check(extract("```json\n{\"a\": 1}\n```")?["a"] as? Int == 1, "fenced json block")
        check(extract("Sure! Here it is:\n```\n{\"title\": \"Demo {x}\", \"n\": [1, 2]}\n```\nAnything else?")?["title"] as? String == "Demo {x}",
              "fenced block with braces inside strings")
        let nested = extract("Result: {\"outer\": {\"inner\": true}} trailing")
        check((nested?["outer"] as? [String: Any])?["inner"] as? Bool == true, "outermost object with nesting")
        check(extract("Escaped \"quote\" then {\"s\": \"a \\\"b\\\" }\"} done")?["s"] as? String == "a \"b\" }", "escaped quotes inside strings")
        check(extract("prose {not json} then {\"ok\": 1}")?["ok"] as? Int == 1, "skips a non-JSON brace pair")
        check(extract("no object here") == nil, "nil without an object")
        check(extract("{\"a\": ") == nil, "nil for truncated JSON")
        check(extract("[1, 2, 3]") == nil, "arrays are not objects")
    }

    // MARK: - Request building

    static func requestBuilding() throws {
        let key = "FAKE-TEST-KEY-NOT-REAL"
        let completion = AICompletionRequest(system: "You edit demos.", user: "Trim silence.", jsonMode: true, maxTokens: 512, temperature: 0.2)

        let deepSeek = AIGatewayClient(kind: .deepSeek, baseURL: URL(string: AIProviderKind.deepSeek.defaultBaseURL)!, apiKey: key, modelID: "deepseek-chat")
        let request = try deepSeek.completionRequest(completion)
        check(request.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions", "OpenAI-compatible endpoint: \(request.url?.absoluteString ?? "")")
        check(request.httpMethod == "POST" && request.timeoutInterval == 60, "POST with the 60 s timeout")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)", "bearer auth")
        check(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "json content type")
        let body = json(request.httpBody)
        check(body["model"] as? String == "deepseek-chat", "model id in body")
        let messages = body["messages"] as? [[String: String]] ?? []
        check(messages.count == 2 && messages[0]["role"] == "system" && messages[1]["role"] == "user" && messages[1]["content"] == "Trim silence.",
              "system + user messages: \(messages)")
        check(messages[0]["content"]?.contains("You edit demos.") == true && messages[0]["content"]?.contains("JSON") == true,
              "json mode adds the JSON hint to the system prompt")
        check((body["response_format"] as? [String: String])?["type"] == "json_object", "response_format json_object")
        check(body["max_tokens"] as? Int == 512 && body["max_completion_tokens"] == nil, "max_tokens for DeepSeek")
        check(body["temperature"] as? Double == 0.2, "temperature")
        let description = String(describing: deepSeek)
        check(!description.contains(key) && description.contains("[redacted]"), "client description hides the key: \(description)")

        let openAI = AIGatewayClient(kind: .openAI, baseURL: URL(string: AIProviderKind.openAI.defaultBaseURL)!, apiKey: key, modelID: "gpt-5.5")
        let openAIBody = json(try openAI.completionRequest(AICompletionRequest(user: "Return JSON.", jsonMode: true)).httpBody)
        check(openAIBody["max_completion_tokens"] as? Int == 4_096 && openAIBody["max_tokens"] == nil, "OpenAI uses max_completion_tokens")
        check(openAIBody["temperature"] == nil, "no temperature unless requested")
        let openAIMessages = openAIBody["messages"] as? [[String: String]] ?? []
        check(openAIMessages.count == 1 && openAIMessages[0]["role"] == "user", "prompt already mentions JSON: no system message added")
        let models = try openAI.modelsRequest()
        check(models.url?.absoluteString == "https://api.openai.com/v1/models" && models.httpMethod == "GET", "OpenAI models endpoint")

        let anthropic = AIGatewayClient(kind: .anthropic, baseURL: URL(string: AIProviderKind.anthropic.defaultBaseURL)!, apiKey: key, modelID: "claude-opus-5")
        let anthropicRequest = try anthropic.completionRequest(completion)
        check(anthropicRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages", "Anthropic messages endpoint")
        check(anthropicRequest.value(forHTTPHeaderField: "x-api-key") == key
              && anthropicRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Anthropic headers")
        check(anthropicRequest.value(forHTTPHeaderField: "Authorization") == nil, "no bearer header for Anthropic")
        let anthropicBody = json(anthropicRequest.httpBody)
        check(anthropicBody["max_tokens"] as? Int == 512 && anthropicBody["response_format"] == nil, "Anthropic max_tokens, no response_format")
        let anthropicSystem = anthropicBody["system"] as? String ?? ""
        check(anthropicSystem.hasPrefix("You edit demos.") && anthropicSystem.contains("JSON"), "Anthropic system prompt carries the JSON hint")
        let anthropicMessages = anthropicBody["messages"] as? [[String: String]] ?? []
        check(anthropicMessages == [["role": "user", "content": "Trim silence."]], "Anthropic single user message")
        let anthropicModels = try anthropic.modelsRequest(afterID: "claude-x")
        check(anthropicModels.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-x",
              "Anthropic models pagination query: \(anthropicModels.url?.absoluteString ?? "")")

        let openRouter = AIGatewayClient(kind: .openRouter, baseURL: URL(string: AIProviderKind.openRouter.defaultBaseURL)!, apiKey: key,
                                         modelID: "anthropic/claude-sonnet-5", referer: "https://example.com/focus-studio")
        let openRouterRequest = try openRouter.modelsRequest()
        check(openRouterRequest.value(forHTTPHeaderField: "X-Title") == "Focus Studio"
              && openRouterRequest.value(forHTTPHeaderField: "HTTP-Referer") == "https://example.com/focus-studio", "OpenRouter attribution headers")
        check(openRouterRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)", "OpenRouter bearer auth")
        let deepSeekModels = try deepSeek.modelsRequest()
        check(deepSeekModels.value(forHTTPHeaderField: "X-Title") == nil, "attribution headers are OpenRouter-only")

        let custom = AIGatewayClient(kind: .custom, baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: "", modelID: "llama3")
        let customRequest = try custom.completionRequest(completion)
        check(customRequest.value(forHTTPHeaderField: "Authorization") == nil, "custom endpoint without key sends no auth header")
        check(json(customRequest.httpBody)["response_format"] == nil, "custom endpoints never get response_format")

        var options = AIGatewayClient.SendOptions.initial(for: .deepSeek, request: completion)
        check(options.jsonResponseFormat && options.temperature == 0.2 && options.maxTokensField == "max_tokens", "initial options")
        options = options.relaxed(afterBadRequest: "Invalid parameter: response_format is not supported")!
        check(!options.jsonResponseFormat, "drops response_format first")
        options = options.relaxed(afterBadRequest: "Unsupported value: 'temperature' does not support 0.2")!
        check(options.temperature == nil, "drops temperature")
        options = options.relaxed(afterBadRequest: "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.")!
        check(options.maxTokensField == "max_completion_tokens", "switches to max_completion_tokens")
        check(options.relaxed(afterBadRequest: "model not found") == nil, "unrelated 400s are not retried")

        let leaked = Data("{\"error\":{\"message\":\"Incorrect API key provided: sk-FAKE123abc. Bearer \(key) apiKey=\(key)\"}}".utf8)
        let redacted = AIGatewayClient.redacted(body: leaked, apiKey: key)
        check(!redacted.contains(key) && !redacted.contains("FAKE123") && redacted.contains("[redacted]"), "keys are redacted: \(redacted)")
        let error = AIGatewayError.httpStatus(401, redacted)
        check(error.errorDescription?.hasPrefix("HTTP 401 · ") == true && error.errorDescription?.contains(key) == false, "error text has status, no key")
        let long = AIGatewayClient.redact(String(repeating: "x ", count: 400), apiKey: key)
        check(long.count == 241 && long.hasSuffix("…"), "long bodies are truncated: \(long.count)")
        check(AIGatewayError.missingAPIKey(.openAI).errorDescription == "Add an API key for OpenAI.", "missing key message")
    }

    // MARK: - Store

    @MainActor
    static func storeRoundTrip() throws {
        let suiteName = "FocusStudio.AIGatewayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainStore()
        let secret = "FAKE-TEST-SECRET-NOT-A-REAL-KEY"

        let store = AIGatewayStore(defaults: defaults, keychain: keychain)
        check(store.providers.map(\.kind) == AIProviderKind.allCases, "all providers in display order")
        check(store.defaultTextModel == nil && store.providersWithKeys.isEmpty, "fresh store")
        check(store.status(for: .deepSeek) == .unconfigured, "no key: unconfigured")
        do {
            _ = try store.resolvedClient()
            fatalError("FAIL: resolvedClient must fail without a default model")
        } catch AIGatewayError.noDefaultModel {}

        try store.setAPIKey("  \(secret)\n", for: .deepSeek)
        check(store.apiKey(for: .deepSeek) == secret, "key is trimmed and readable")
        check(keychain.values["deepSeek"] == secret, "keychain account is the provider raw value")
        check(store.status(for: .deepSeek) == .needsTest, "key present but untested")
        store.setDefaultModelID("deepseek-chat", for: .deepSeek)
        store.setBaseURL("https://proxy.example.com/v1/", for: .deepSeek)
        store.update(.deepSeek) {
            $0.cachedModelIDs = ["deepseek-chat", "deepseek-reasoner"]
            $0.lastTestSucceeded = true
            $0.lastTestModelCount = 2
        }
        store.defaultTextModel = AITextModelSelection(provider: .deepSeek, modelID: "deepseek-chat")
        check(store.status(for: .deepSeek) == .ready, "tested provider is ready")
        check(store.availableDefaultSelections == [AITextModelSelection(provider: .deepSeek, modelID: "deepseek-chat")], "default candidates")

        let client = try store.resolvedClient()
        check(client.kind == .deepSeek && client.modelID == "deepseek-chat" && client.baseURL.absoluteString == "https://proxy.example.com/v1",
              "resolved client uses override and model: \(client)")
        let resolvedRequest = try client.completionRequest(AICompletionRequest(user: "x"))
        check(resolvedRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(secret)", "resolved client carries the key")

        store.setDefaultModelID("deepseek-reasoner", for: .deepSeek)
        check(store.defaultTextModel?.modelID == "deepseek-reasoner", "default follows the provider model")
        store.setBaseURL(AIProviderKind.deepSeek.defaultBaseURL, for: .deepSeek)
        check(store.configuration(for: .deepSeek).baseURLOverride.isEmpty, "default URL clears the override")
        store.setBaseURL("https://proxy.example.com/v1", for: .deepSeek)

        let payload = defaults.data(forKey: AIGatewayStore.defaultsKey) ?? Data()
        let payloadText = String(decoding: payload, as: UTF8.self)
        check(!payload.isEmpty && !payloadText.contains(secret) && !payloadText.contains("FAKE"), "secrets never reach UserDefaults")
        check(payloadText.contains("proxy.example.com") && payloadText.contains("deepseek-reasoner"), "preferences are persisted")

        let reloaded = AIGatewayStore(defaults: defaults, keychain: keychain)
        check(reloaded.providers == store.providers, "provider settings survive relaunch")
        check(reloaded.defaultTextModel == store.defaultTextModel, "default model survives relaunch")
        check(reloaded.providersWithKeys == [.deepSeek] && reloaded.apiKey(for: .deepSeek) == secret, "key presence is read from the keychain")

        reloaded.update(.deepSeek) { $0.isEnabled = false }
        do {
            _ = try reloaded.resolvedClient()
            fatalError("FAIL: disabled provider must not resolve")
        } catch AIGatewayError.providerDisabled(.deepSeek) {}
        reloaded.update(.deepSeek) { $0.isEnabled = true }
        try reloaded.setAPIKey("", for: .deepSeek)
        check(reloaded.apiKey(for: .deepSeek) == nil && keychain.values["deepSeek"] == nil && !reloaded.providersWithKeys.contains(.deepSeek),
              "empty key deletes")
        check(reloaded.configuration(for: .deepSeek).lastTestSucceeded == nil, "changing the key invalidates the test")
        do {
            _ = try reloaded.resolvedClient()
            fatalError("FAIL: missing key must not resolve")
        } catch AIGatewayError.missingAPIKey(.deepSeek) {}

        check(reloaded.status(for: .custom) == .unconfigured, "custom without URL")
        reloaded.setBaseURL("http://localhost:11434/v1", for: .custom)
        check(reloaded.status(for: .custom) == .needsTest, "custom with URL needs a test")
        let local = try reloaded.client(for: .custom, modelID: "llama3")
        check(local.baseURL.absoluteString == "http://localhost:11434/v1", "custom client without key")
        reloaded.setBaseURL("not a url", for: .custom)
        do {
            _ = try reloaded.client(for: .custom, modelID: "llama3")
            fatalError("FAIL: invalid base URL must not resolve")
        } catch AIGatewayError.invalidBaseURL {}

        defaults.set(Data("{\"providers\":[{\"kind\":\"kimi\",\"defaultModelID\":\"kimi-k2\"}]}".utf8), forKey: AIGatewayStore.defaultsKey)
        let legacy = AIGatewayStore(defaults: defaults, keychain: keychain)
        check(legacy.providers.count == 8 && legacy.configuration(for: .kimi).defaultModelID == "kimi-k2" && legacy.configuration(for: .kimi).isEnabled,
              "lenient decoding of older payloads")
    }

    // MARK: - Mocked HTTP

    @MainActor
    static func mockedTransport() async throws {
        let session = MockURLProtocol.makeSession()
        let key = "FAKE-TEST-KEY-NOT-REAL"
        let openAI = AIGatewayClient(kind: .openAI, baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: key, modelID: "gpt-5.5", session: session)

        MockURLProtocol.reset { request, _ in
            guard request.url?.path == "/v1/models", request.httpMethod == "GET" else { return (404, Data("{}".utf8)) }
            return (200, Data("{\"object\":\"list\",\"data\":[{\"id\":\"gpt-5.5\",\"owned_by\":\"openai\"},{\"id\":\"gpt-5-mini\"},{\"id\":\"gpt-5.5\"}]}".utf8))
        }
        let models = try await openAI.listModels()
        check(models.map(\.id) == ["gpt-5.5", "gpt-5-mini"] && models[0].ownedBy == "openai", "OpenAI-compatible model list, de-duplicated: \(models)")
        check(MockURLProtocol.recorded.count == 1 && MockURLProtocol.recorded[0].request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)",
              "auth header reached the transport")

        MockURLProtocol.reset { request, body in
            guard request.url?.path == "/v1/chat/completions" else { return (404, Data()) }
            let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            if object["response_format"] != nil {
                return (400, Data("{\"error\":{\"message\":\"response_format is not supported for this model\",\"type\":\"invalid_request_error\"}}".utf8))
            }
            return (200, Data("{\"id\":\"chatcmpl-1\",\"model\":\"gpt-5.5-2026-04-23\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"{\\\"cuts\\\": 2}\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":2,\"total_tokens\":12}}".utf8))
        }
        let response = try await openAI.complete(AICompletionRequest(system: "Return JSON.", user: "Plan cuts.", jsonMode: true, maxTokens: 64))
        check(response.text == "{\"cuts\": 2}" && response.modelID == "gpt-5.5-2026-04-23" && response.finishReason == "stop", "completion text and model: \(response)")
        check(response.usage == AITokenUsage(promptTokens: 10, completionTokens: 2), "usage")
        check(MockURLProtocol.recorded.count == 2, "exactly one retry without response_format")
        let retryBody = json(MockURLProtocol.recorded[1].body)
        check(retryBody["response_format"] == nil && retryBody["max_completion_tokens"] as? Int == 64, "retry drops response_format only")
        check(json(AIGatewayClient.extractJSONObject(from: response.text))["cuts"] as? Int == 2, "answer parses as JSON")

        let anthropic = AIGatewayClient(kind: .anthropic, baseURL: URL(string: "https://api.anthropic.com/v1")!, apiKey: key, modelID: "claude-opus-5", session: session)
        MockURLProtocol.reset { request, _ in
            guard request.url?.path == "/v1/models" else { return (404, Data()) }
            if (request.url?.query ?? "").contains("after_id=claude-sonnet-5") {
                return (200, Data("{\"data\":[{\"type\":\"model\",\"id\":\"claude-haiku-4-5\",\"display_name\":\"Claude Haiku 4.5\"}],\"has_more\":false,\"first_id\":\"claude-haiku-4-5\",\"last_id\":\"claude-haiku-4-5\"}".utf8))
            }
            return (200, Data("{\"data\":[{\"type\":\"model\",\"id\":\"claude-opus-5\",\"display_name\":\"Claude Opus 5\"},{\"type\":\"model\",\"id\":\"claude-sonnet-5\",\"display_name\":\"Claude Sonnet 5\"}],\"has_more\":true,\"first_id\":\"claude-opus-5\",\"last_id\":\"claude-sonnet-5\"}".utf8))
        }
        let anthropicModels = try await anthropic.listModels()
        check(anthropicModels.map(\.id) == ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"] && anthropicModels[0].displayName == "Claude Opus 5",
              "Anthropic pagination: \(anthropicModels.map(\.id))")
        check(MockURLProtocol.recorded.count == 2 && MockURLProtocol.recorded[0].request.value(forHTTPHeaderField: "x-api-key") == key
              && MockURLProtocol.recorded[0].request.url?.query?.contains("limit=1000") == true, "Anthropic headers and page size")

        MockURLProtocol.reset { request, body in
            guard request.url?.path == "/v1/messages" else { return (404, Data()) }
            let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            guard object["max_tokens"] as? Int == 32, object["response_format"] == nil else {
                return (400, Data("{\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad body\"}}".utf8))
            }
            return (200, Data("{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-opus-5\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"…\"},{\"type\":\"text\",\"text\":\"Hello \"},{\"type\":\"text\",\"text\":\"there\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":7,\"output_tokens\":3}}".utf8))
        }
        let anthropicResponse = try await anthropic.complete(AICompletionRequest(system: "Be brief.", user: "Hi", maxTokens: 32))
        check(anthropicResponse.text == "Hello there" && anthropicResponse.usage == AITokenUsage(promptTokens: 7, completionTokens: 3)
              && anthropicResponse.finishReason == "end_turn", "Anthropic text blocks joined, thinking skipped: \(anthropicResponse)")

        MockURLProtocol.reset { _, _ in (401, Data("{\"error\":{\"message\":\"Incorrect API key provided: \(key). Bearer sk-abc123\"}}".utf8)) }
        do {
            _ = try await openAI.complete(AICompletionRequest(user: "x"))
            fatalError("FAIL: 401 must throw")
        } catch let error as AIGatewayError {
            guard case let .httpStatus(status, body) = error else { fatalError("FAIL: expected httpStatus, got \(error)") }
            check(status == 401 && !body.contains(key) && !body.contains("abc123") && error.errorDescription?.hasPrefix("HTTP 401") == true,
                  "redacted HTTP error: \(error.errorDescription ?? "")")
        }
        check(MockURLProtocol.recorded.count == 1, "non-400 errors are not retried")

        MockURLProtocol.reset { _, _ in (200, Data("<html>not json</html>".utf8)) }
        do {
            _ = try await openAI.listModels()
            fatalError("FAIL: invalid JSON must throw")
        } catch AIGatewayError.invalidResponse {}

        let impatient = AIGatewayClient(kind: .openAI, baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: key, modelID: "gpt-5.5",
                                        session: session, timeout: 0.4)
        MockURLProtocol.reset { _, _ in (-1, Data()) }
        do {
            _ = try await impatient.listModels()
            fatalError("FAIL: a silent server must time out")
        } catch AIGatewayError.timeout {}
    }

    @MainActor
    static func storeTesting() async throws {
        let suiteName = "FocusStudio.AIGatewayTests.store.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainStore(values: ["openAI": "FAKE-OPENAI-KEY", "glm": "FAKE-GLM-KEY"])
        let store = AIGatewayStore(defaults: defaults, keychain: keychain, session: MockURLProtocol.makeSession())
        check(store.providersWithKeys == [.openAI, .glm], "keys discovered at launch")

        MockURLProtocol.reset { request, _ in
            guard request.url?.host == "api.openai.com", request.url?.path == "/v1/models" else { return (500, Data()) }
            return (200, Data("{\"data\":[{\"id\":\"gpt-5-mini\"},{\"id\":\"gpt-5.5\"},{\"id\":\"text-embedding-3-small\"},{\"id\":\"gpt-4.1\"}]}".utf8))
        }
        await store.test(.openAI)
        let openAI = store.configuration(for: .openAI)
        check(openAI.lastTestSucceeded == true && openAI.lastTestModelCount == 4 && openAI.lastTestSummary == nil && openAI.lastTestedAt != nil,
              "successful test: \(openAI)")
        check(openAI.cachedModelIDs == ["gpt-4.1", "gpt-5-mini", "gpt-5.5", "text-embedding-3-small"], "cached ids are sorted: \(openAI.cachedModelIDs)")
        check(openAI.defaultModelID == "gpt-5.5", "recommended default auto-picked")
        check(store.defaultTextModel == AITextModelSelection(provider: .openAI, modelID: "gpt-5.5"), "first tested provider becomes the app default")
        check(store.status(for: .openAI) == .ready, "ready after test")

        MockURLProtocol.reset { request, body in
            if request.url?.path.hasSuffix("/models") == true {
                return (404, Data("{\"error\":{\"code\":\"404\",\"message\":\"not found\"}}".utf8))
            }
            guard request.url?.path == "/api/paas/v4/chat/completions" else { return (500, Data()) }
            let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            guard object["model"] as? String == "glm-5" else { return (400, Data("{\"error\":{\"message\":\"unknown model\"}}".utf8)) }
            return (200, Data("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"OK\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}".utf8))
        }
        await store.test(.glm)
        var glm = store.configuration(for: .glm)
        check(glm.lastTestSucceeded == false && glm.lastTestSummary?.contains("does not list models") == true,
              "no list and no model id fails with a hint: \(glm.lastTestSummary ?? "")")
        store.setDefaultModelID("glm-5", for: .glm)
        await store.test(.glm)
        glm = store.configuration(for: .glm)
        check(glm.lastTestSucceeded == true && glm.lastTestModelCount == nil && glm.cachedModelIDs == ["glm-5"], "ping fallback marks the provider tested: \(glm)")
        check(store.defaultTextModel?.provider == .openAI, "the app default is not stolen by a later provider")
        check(store.availableDefaultSelections.map(\.provider) == [.openAI, .glm], "both tested providers are default candidates")

        MockURLProtocol.reset { _, _ in (429, Data("{\"error\":{\"message\":\"Rate limit reached for FAKE-OPENAI-KEY\"}}".utf8)) }
        await store.test(.openAI)
        let failed = store.configuration(for: .openAI)
        check(failed.lastTestSucceeded == false && failed.lastTestSummary == "HTTP 429 · Rate limit reached for [redacted]" && failed.cachedModelIDs.count == 4,
              "failed test keeps cache and redacts: \(failed.lastTestSummary ?? "")")
        check(store.status(for: .openAI) == .needsTest, "failed test needs attention")
        let payload = String(decoding: defaults.data(forKey: AIGatewayStore.defaultsKey) ?? Data(), as: UTF8.self)
        check(!payload.contains("FAKE-"), "test results never persist secrets")
    }
}

/// Answers every request of a mocked session from a handler. Bodies arrive
/// as a stream inside URLProtocol, so they are read back into Data here.
final class MockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest, Data) -> (Int, Data)

    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recordedRequests: [(request: URLRequest, body: Data)] = []
    private static let lock = NSLock()

    static var recorded: [(request: URLRequest, body: Data)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    static func reset(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        recordedRequests = []
        lock.unlock()
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.timeoutIntervalForRequest = 2
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        Self.lock.lock()
        Self.recordedRequests.append((request, body))
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request, body)
        // A negative status never answers so the caller's timeout fires.
        guard status > 0 else { return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
