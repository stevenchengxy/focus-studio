import Foundation

struct AICompletionRequest: Equatable, Sendable {
    var system: String?
    var user: String
    /// Ask for a JSON object. Sent as `response_format` where supported and
    /// always reinforced in the prompt; use `extractJSONObject` on the answer.
    var jsonMode: Bool
    var maxTokens: Int
    /// nil leaves the provider default, which some reasoning models require.
    var temperature: Double?

    init(system: String? = nil, user: String, jsonMode: Bool = false, maxTokens: Int = 4_096, temperature: Double? = nil) {
        self.system = system
        self.user = user
        self.jsonMode = jsonMode
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

struct AITokenUsage: Codable, Equatable, Sendable {
    var promptTokens: Int
    var completionTokens: Int

    var totalTokens: Int { promptTokens + completionTokens }
}

struct AICompletionResponse: Equatable, Sendable {
    var text: String
    var modelID: String
    var usage: AITokenUsage?
    var finishReason: String?
}

/// Every message is safe to show: API keys never appear in them.
enum AIGatewayError: Error, LocalizedError, Equatable, Sendable {
    case missingAPIKey(AIProviderKind)
    case missingModelID(AIProviderKind)
    case modelListUnavailable(AIProviderKind)
    case invalidBaseURL(String)
    case noDefaultModel
    case providerDisabled(AIProviderKind)
    /// HTTP status plus a short, redacted excerpt of the server's message.
    case httpStatus(Int, String)
    case timeout(TimeInterval)
    case network(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case let .missingAPIKey(kind):
            return "Add an API key for \(kind.title)."
        case let .missingModelID(kind):
            return "Choose a model for \(kind.title)."
        case let .modelListUnavailable(kind):
            return "\(kind.title) does not list models. Enter a model ID under Advanced."
        case let .invalidBaseURL(url):
            return url.isEmpty ? "Enter a base URL." : "Invalid base URL: \(url)"
        case .noDefaultModel:
            return "Choose a default text model in Settings › AI models."
        case let .providerDisabled(kind):
            return "\(kind.title) is turned off in Settings › AI models."
        case let .httpStatus(status, body):
            return body.isEmpty ? "HTTP \(status)" : "HTTP \(status) · \(body)"
        case let .timeout(seconds):
            return "No answer within \(Int(seconds)) seconds."
        case let .network(message):
            return message
        case let .invalidResponse(detail):
            return "Unexpected response: \(detail)"
        }
    }
}

/// Chat completions and model listing for one provider, model and key.
/// Values are immutable and Sendable, so a client can be handed to any task.
struct AIGatewayClient: Sendable, CustomStringConvertible {
    static let anthropicVersion = "2023-06-01"
    static let appTitle = "Focus Studio"
    static let defaultTimeout: TimeInterval = 60

    let kind: AIProviderKind
    let baseURL: URL
    let modelID: String
    let timeout: TimeInterval
    /// Sent as `HTTP-Referer` to OpenRouter when set.
    let referer: String?
    private let apiKey: String
    private let session: URLSession

    init(kind: AIProviderKind, baseURL: URL, apiKey: String, modelID: String,
         session: URLSession = .shared, timeout: TimeInterval = AIGatewayClient.defaultTimeout, referer: String? = nil) {
        self.kind = kind
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelID = modelID
        self.session = session
        self.timeout = timeout
        self.referer = referer
    }

    var description: String {
        "AIGatewayClient(\(kind.rawValue), \(baseURL.absoluteString), model: \(modelID), apiKey: \(apiKey.isEmpty ? "none" : "[redacted]"))"
    }

    // MARK: - Requests

    /// Request details that are dropped one by one when a server answers 400,
    /// so strict or older OpenAI-compatible endpoints still work.
    struct SendOptions: Equatable, Sendable {
        var jsonResponseFormat: Bool
        var temperature: Double?
        var maxTokensField: String

        static func initial(for kind: AIProviderKind, request: AICompletionRequest) -> SendOptions {
            SendOptions(
                jsonResponseFormat: request.jsonMode && kind.supportsJSONResponseFormat,
                temperature: request.temperature,
                maxTokensField: kind.usesMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"
            )
        }

        /// The options for a retry, or nil when the complaint is about something else.
        func relaxed(afterBadRequest body: String) -> SendOptions? {
            let lowered = body.lowercased()
            var next = self
            if jsonResponseFormat, lowered.contains("response_format") {
                next.jsonResponseFormat = false
                return next
            }
            if temperature != nil, lowered.contains("temperature") {
                next.temperature = nil
                return next
            }
            if maxTokensField == "max_tokens", lowered.contains("max_completion_tokens") {
                next.maxTokensField = "max_completion_tokens"
                return next
            }
            return nil
        }
    }

    func modelsRequest(afterID: String? = nil) throws -> URLRequest {
        var components = URLComponents(url: endpoint("models"), resolvingAgainstBaseURL: false)
        if kind.transport == .anthropicMessages {
            var items = [URLQueryItem(name: "limit", value: "1000")]
            if let afterID { items.append(URLQueryItem(name: "after_id", value: afterID)) }
            components?.queryItems = items
        }
        guard let url = components?.url else { throw AIGatewayError.invalidBaseURL(baseURL.absoluteString) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        applyHeaders(to: &request)
        return request
    }

    func completionRequest(_ completion: AICompletionRequest, options: SendOptions? = nil) throws -> URLRequest {
        let options = options ?? .initial(for: kind, request: completion)
        let path = kind.transport == .anthropicMessages ? "messages" : "chat/completions"
        var request = URLRequest(url: endpoint(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body(for: completion, options: options), options: [.sortedKeys])
        return request
    }

    /// JSON mode needs the word "JSON" in the prompt (OpenAI rejects the
    /// request otherwise) and the prompt is the only hint Anthropic gets.
    static func systemPrompt(for completion: AICompletionRequest) -> String? {
        let system = completion.system?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mentionsJSON = system.lowercased().contains("json") || completion.user.lowercased().contains("json")
        guard completion.jsonMode, !mentionsJSON else { return system.isEmpty ? nil : system }
        let hint = "Respond with a single valid JSON object and nothing else."
        return system.isEmpty ? hint : system + "\n\n" + hint
    }

    private func body(for completion: AICompletionRequest, options: SendOptions) -> [String: Any] {
        let system = Self.systemPrompt(for: completion)
        var body: [String: Any] = ["model": modelID]
        switch kind.transport {
        case .openAICompatible:
            var messages: [[String: String]] = []
            if let system { messages.append(["role": "system", "content": system]) }
            messages.append(["role": "user", "content": completion.user])
            body["messages"] = messages
            body[options.maxTokensField] = completion.maxTokens
            if let temperature = options.temperature { body["temperature"] = temperature }
            if options.jsonResponseFormat { body["response_format"] = ["type": "json_object"] }
        case .anthropicMessages:
            body["max_tokens"] = completion.maxTokens
            if let system { body["system"] = system }
            body["messages"] = [["role": "user", "content": completion.user]]
            if let temperature = options.temperature { body["temperature"] = temperature }
        }
        return body
    }

    private func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch kind.transport {
        case .openAICompatible:
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            if kind == .openRouter {
                request.setValue(Self.appTitle, forHTTPHeaderField: "X-Title")
                if let referer, !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "HTTP-Referer") }
            }
        case .anthropicMessages:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        }
    }

    // MARK: - Calls

    func listModels() async throws -> [AIModelInfo] {
        var models: [AIModelInfo] = []
        var seen = Set<String>()
        var afterID: String?
        for _ in 0..<20 {
            let request = try modelsRequest(afterID: afterID)
            let (data, status) = try await perform(request)
            guard (200..<300).contains(status) else {
                throw AIGatewayError.httpStatus(status, Self.redacted(body: data, apiKey: apiKey))
            }
            let page = try Self.parseModelList(data)
            for model in page.models where seen.insert(model.id).inserted { models.append(model) }
            guard kind.transport == .anthropicMessages, page.hasMore, let last = page.lastID, last != afterID else { break }
            afterID = last
        }
        return models
    }

    func complete(_ completion: AICompletionRequest) async throws -> AICompletionResponse {
        var options = SendOptions.initial(for: kind, request: completion)
        for attempt in 0..<4 {
            let request = try completionRequest(completion, options: options)
            let (data, status) = try await perform(request)
            if (200..<300).contains(status) { return try parseCompletion(data) }
            let body = Self.redacted(body: data, apiKey: apiKey)
            if status == 400, attempt < 3, let relaxed = options.relaxed(afterBadRequest: body) {
                options = relaxed
                continue
            }
            throw AIGatewayError.httpStatus(status, body)
        }
        throw AIGatewayError.invalidResponse("request could not be adapted")
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIGatewayError.invalidResponse("not an HTTP response")
            }
            return (data, http.statusCode)
        } catch let error as AIGatewayError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw AIGatewayError.timeout(timeout)
        } catch let error as URLError {
            throw AIGatewayError.network(Self.redact(error.localizedDescription, apiKey: apiKey))
        }
    }

    // MARK: - Parsing

    struct ModelListPage: Equatable {
        var models: [AIModelInfo]
        var hasMore: Bool
        var lastID: String?
    }

    /// OpenAI-style `{"data": [{"id": …}]}`, Anthropic's paginated variant, or a bare array.
    static func parseModelList(_ data: Data) throws -> ModelListPage {
        let json = try jsonObject(data)
        let entries: [Any]
        var hasMore = false
        var lastID: String?
        if let object = json as? [String: Any] {
            guard let list = (object["data"] as? [Any]) ?? (object["models"] as? [Any]) else {
                throw AIGatewayError.invalidResponse("no model list")
            }
            entries = list
            hasMore = object["has_more"] as? Bool ?? false
            lastID = object["last_id"] as? String
        } else if let list = json as? [Any] {
            entries = list
        } else {
            throw AIGatewayError.invalidResponse("no model list")
        }
        let models = entries.compactMap { entry -> AIModelInfo? in
            if let id = entry as? String { return AIModelInfo(id: id) }
            guard let dictionary = entry as? [String: Any],
                  let id = (dictionary["id"] as? String) ?? (dictionary["name"] as? String) else { return nil }
            return AIModelInfo(
                id: id,
                displayName: (dictionary["display_name"] as? String) ?? (dictionary["name"] as? String),
                ownedBy: dictionary["owned_by"] as? String
            )
        }
        return ModelListPage(models: models, hasMore: hasMore, lastID: lastID ?? models.last?.id)
    }

    private func parseCompletion(_ data: Data) throws -> AICompletionResponse {
        guard let object = try Self.jsonObject(data) as? [String: Any] else {
            throw AIGatewayError.invalidResponse("not a JSON object")
        }
        // Some proxies answer 200 with an error body.
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            throw AIGatewayError.invalidResponse(Self.redact(message, apiKey: apiKey))
        }
        let model = object["model"] as? String ?? modelID
        let usage = object["usage"] as? [String: Any]
        switch kind.transport {
        case .openAICompatible:
            guard let choice = (object["choices"] as? [[String: Any]])?.first else {
                throw AIGatewayError.invalidResponse("no choices")
            }
            let message = choice["message"] as? [String: Any]
            return AICompletionResponse(
                text: Self.text(fromContent: message?["content"]),
                modelID: model,
                usage: Self.usage(usage, prompt: "prompt_tokens", completion: "completion_tokens"),
                finishReason: choice["finish_reason"] as? String
            )
        case .anthropicMessages:
            return AICompletionResponse(
                text: Self.text(fromContent: object["content"]),
                modelID: model,
                usage: Self.usage(usage, prompt: "input_tokens", completion: "output_tokens"),
                finishReason: object["stop_reason"] as? String
            )
        }
    }

    /// A plain string, or the joined `text` parts of a content array
    /// (thinking and other block types are skipped).
    private static func text(fromContent content: Any?) -> String {
        if let string = content as? String { return string }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { part -> String? in
            guard ((part["type"] as? String) ?? "text") == "text" else { return nil }
            return part["text"] as? String
        }.joined()
    }

    private static func usage(_ usage: [String: Any]?, prompt: String, completion: String) -> AITokenUsage? {
        guard let usage, let promptTokens = usage[prompt] as? Int, let completionTokens = usage[completion] as? Int else {
            return nil
        }
        return AITokenUsage(promptTokens: promptTokens, completionTokens: completionTokens)
    }

    private static func jsonObject(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AIGatewayError.invalidResponse("invalid JSON")
        }
    }

    // MARK: - Redaction

    /// The server's `error.message` when the body is JSON, otherwise the raw
    /// text, with secrets removed and the length bounded.
    static func redacted(body: Data, apiKey: String) -> String {
        var text = String(decoding: body.prefix(8_192), as: UTF8.self)
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                text = message
            } else if let error = object["error"] as? String {
                text = error
            } else if let message = object["message"] as? String {
                text = message
            }
        }
        return redact(text, apiKey: apiKey)
    }

    static func redact(_ text: String, apiKey: String) -> String {
        var text = text
        if apiKey.count >= 4 { text = text.replacingOccurrences(of: apiKey, with: "[redacted]") }
        for pattern in [#/\bsk-[A-Za-z0-9_.-]+/#, #/Bearer \S+/#, #/"?api[_-]?key"?\s*[:=]\s*"?[^"\s,]+/#] {
            text = text.replacing(pattern.ignoresCase(), with: "[redacted]")
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.count > 240 ? String(text.prefix(240)) + "…" : text
    }

    // MARK: - JSON extraction

    /// The first JSON object in a model answer: fenced ``` blocks are tried
    /// first, then the outermost balanced `{…}` in the whole text.
    static func extractJSONObject(from text: String) -> Data? {
        let fence = #/```[A-Za-z0-9_-]*[ \t]*\r?\n?(.*?)```/#.dotMatchesNewlines()
        var candidates = text.matches(of: fence).map(\.1)
        candidates.append(text[...])
        for candidate in candidates {
            if let data = balancedObject(in: candidate) { return data }
        }
        return nil
    }

    private static func balancedObject(in text: Substring) -> Data? {
        var searchStart = text.startIndex
        while let start = text[searchStart...].firstIndex(of: "{") {
            if let end = closingBrace(in: text, from: start), let data = validObject(text[start...end]) { return data }
            searchStart = text.index(after: start)
        }
        // Unbalanced text: take the widest span and let the parser decide.
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last {
            return validObject(text[first...last])
        }
        return nil
    }

    /// The index of the brace closing the object opened at `start`, ignoring
    /// braces inside JSON strings.
    private static func closingBrace(in text: Substring, from start: Substring.Index) -> Substring.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func validObject(_ candidate: Substring) -> Data? {
        let data = Data(candidate.utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return data
    }
}
