import Foundation

/// The wire protocol a provider speaks. Everything except Anthropic exposes an
/// OpenAI-style `chat/completions` endpoint.
enum AITransport: String, Codable, Sendable {
    case openAICompatible
    case anthropicMessages
}

/// Providers the gateway knows how to talk to. Raw values are persisted in
/// preferences and used as Keychain account names, so they must stay stable.
enum AIProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI
    case anthropic
    case deepSeek
    case glm
    case kimi
    case openRouter
    case volcengineArk
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .deepSeek: return "DeepSeek"
        case .glm: return "Zhipu GLM"
        case .kimi: return "Kimi"
        case .openRouter: return "OpenRouter"
        case .volcengineArk: return "Volcengine Ark"
        case .custom: return "Custom"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .glm: return "https://open.bigmodel.cn/api/paas/v4"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .volcengineArk: return "https://ark.cn-beijing.volces.com/api/v3"
        case .custom: return ""
        }
    }

    var transport: AITransport { self == .anthropic ? .anthropicMessages : .openAICompatible }

    /// Where the user creates an API key.
    var consoleURL: URL? {
        let string: String
        switch self {
        case .openAI: string = "https://platform.openai.com/api-keys"
        case .anthropic: string = "https://console.anthropic.com/settings/keys"
        case .deepSeek: string = "https://platform.deepseek.com/api_keys"
        case .glm: string = "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys"
        case .kimi: string = "https://platform.moonshot.cn/console/api-keys"
        case .openRouter: string = "https://openrouter.ai/settings/keys"
        case .volcengineArk: string = "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey"
        case .custom: return nil
        }
        return URL(string: string)
    }

    /// Custom endpoints (a local server, a corporate proxy) may run without a key.
    var requiresAPIKey: Bool { self != .custom }

    /// Whether `response_format: {"type": "json_object"}` may be sent. Anthropic
    /// has no such field and unknown custom servers often reject it.
    var supportsJSONResponseFormat: Bool {
        switch self {
        case .openAI, .deepSeek, .glm, .kimi, .openRouter, .volcengineArk: return true
        case .anthropic, .custom: return false
        }
    }

    /// OpenAI's current chat models reject `max_tokens` in favour of
    /// `max_completion_tokens`; the other OpenAI-compatible APIs expect `max_tokens`.
    var usesMaxCompletionTokens: Bool { self == .openAI }

    /// Substrings, most preferred first, matched against the live model list to
    /// pick a recommended default. Loose on purpose so point releases still match.
    var preferredModelPatterns: [String] {
        switch self {
        case .openAI:
            return ["gpt-5.6", "gpt-5.5", "gpt-5.4", "gpt-5.2", "gpt-5.1", "gpt-5", "gpt-4.1", "gpt-4o"]
        case .anthropic:
            return ["claude-opus-5", "claude-sonnet-5", "claude-opus-4", "claude-sonnet-4", "claude-haiku-4"]
        case .deepSeek:
            return ["deepseek-v4-flash", "deepseek-chat", "deepseek-v4-pro", "deepseek-reasoner", "deepseek"]
        case .glm:
            return ["glm-5.3", "glm-5.2", "glm-5.1", "glm-5", "glm-4.7", "glm-4.6", "glm-4.5", "glm-4"]
        case .kimi:
            return ["kimi-k3", "kimi-k2.6", "kimi-k2.5", "kimi-k2", "kimi-latest", "kimi", "moonshot-v1-128k", "moonshot"]
        case .openRouter:
            return ["anthropic/claude-sonnet-5", "anthropic/claude-opus-5", "openai/gpt-5.5", "openai/gpt-5",
                    "anthropic/claude-sonnet-4", "deepseek/deepseek-v4", "deepseek/deepseek-chat", "google/gemini"]
        case .volcengineArk:
            return ["doubao-seed-2.0", "doubao-seed-2-0", "doubao-seed-2", "doubao-seed-1.6", "doubao-seed-1-6", "doubao-seed", "doubao"]
        case .custom:
            return []
        }
    }

    /// Ids that are clearly not text-chat models and must never be auto-picked.
    static let nonChatModelMarkers = [
        "embed", "whisper", "tts", "dall-e", "image", "audio", "realtime", "moderation", "transcri", "rerank",
        "sora", "seedance", "seedream", "cogview", "cogvideo", "babbage", "davinci", "instruct", "computer-use",
        "codex", "guard", "vision", "search-preview"
    ]

    func recommendedModelID(from ids: [String]) -> String? {
        Self.recommendedModelID(from: ids, patterns: preferredModelPatterns)
    }

    /// The first pattern with a match wins. Among matches an exact id is
    /// preferred, then the shortest (the plain, undated variant); numbered
    /// siblings such as `claude-opus-4-8` beat `claude-opus-4-7`, and
    /// otherwise the provider's order stands. Never nil for a non-empty list:
    /// with no match the first chat-like id is returned.
    static func recommendedModelID(from ids: [String], patterns: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        let chatIDs = ids.filter { id in
            let lowered = id.lowercased()
            return !nonChatModelMarkers.contains { lowered.contains($0) }
        }
        let pool = chatIDs.isEmpty ? ids : chatIDs
        for pattern in patterns {
            let needle = pattern.lowercased()
            let candidates = pool.filter { $0.lowercased().contains(needle) }
            guard let shortest = candidates.map(\.count).min() else { continue }
            if let exact = candidates.first(where: { $0.lowercased() == needle }) { return exact }
            let shortestCandidates = candidates.filter { $0.count == shortest }
            let numbered = shortestCandidates.compactMap { id in versionNumbers(in: id, after: needle).map { (id: id, numbers: $0) } }
            if numbered.count == shortestCandidates.count,
               let newest = numbered.max(by: { $0.numbers.lexicographicallyPrecedes($1.numbers) }) {
                return newest.id
            }
            return shortestCandidates.first
        }
        return pool.first
    }

    /// The numbers following `needle` in `id` (`claude-opus-4-8` after
    /// `claude-opus-4` gives `[8]`), or nil when the suffix has letters, as in
    /// `gpt-5-mini`.
    private static func versionNumbers(in id: String, after needle: String) -> [Int]? {
        guard let range = id.lowercased().range(of: needle) else { return nil }
        let suffix = id[range.upperBound...]
        guard suffix.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else { return nil }
        return suffix.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}

/// Non-secret settings for one provider. API keys live in the Keychain only.
struct AIProviderConfiguration: Codable, Equatable, Identifiable, Sendable {
    var kind: AIProviderKind
    var isEnabled = true
    /// Empty means the provider's default base URL.
    var baseURLOverride = ""
    var defaultModelID = ""
    var cachedModelIDs: [String] = []
    var lastTestedAt: Date?
    var lastTestSucceeded: Bool?
    /// The failure message of the last test; nil after a successful test.
    var lastTestSummary: String?
    /// Models reported by the last test; nil when the API has no model list.
    var lastTestModelCount: Int?

    var id: AIProviderKind { kind }

    init(kind: AIProviderKind) {
        self.kind = kind
    }

    var effectiveBaseURL: String {
        let override = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = override.isEmpty ? kind.defaultBaseURL : override
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    private enum CodingKeys: String, CodingKey {
        case kind, isEnabled, baseURLOverride, defaultModelID, cachedModelIDs
        case lastTestedAt, lastTestSucceeded, lastTestSummary, lastTestModelCount
    }

    /// Tolerates missing keys so older preference payloads keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(AIProviderKind.self, forKey: .kind)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        baseURLOverride = try container.decodeIfPresent(String.self, forKey: .baseURLOverride) ?? ""
        defaultModelID = try container.decodeIfPresent(String.self, forKey: .defaultModelID) ?? ""
        cachedModelIDs = try container.decodeIfPresent([String].self, forKey: .cachedModelIDs) ?? []
        lastTestedAt = try container.decodeIfPresent(Date.self, forKey: .lastTestedAt)
        lastTestSucceeded = try container.decodeIfPresent(Bool.self, forKey: .lastTestSucceeded)
        lastTestSummary = try container.decodeIfPresent(String.self, forKey: .lastTestSummary)
        lastTestModelCount = try container.decodeIfPresent(Int.self, forKey: .lastTestModelCount)
    }
}

/// The app-wide default text model: a provider plus one of its model ids.
struct AITextModelSelection: Codable, Hashable, Identifiable, Sendable {
    var provider: AIProviderKind
    var modelID: String

    var id: String { "\(provider.rawValue):\(modelID)" }
}

/// One entry of a provider's model list.
struct AIModelInfo: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var displayName: String?
    var ownedBy: String?

    init(id: String, displayName: String? = nil, ownedBy: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.ownedBy = ownedBy
    }
}
