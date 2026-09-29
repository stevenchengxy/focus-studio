import Combine
import Foundation
import Security

/// Secret storage. The app keeps keys in a 0600 file under Application Support
/// (see `FileSecretStore`); tests keep values in memory. `SecurityKeychainStore`
/// remains available but is not the default: an ad-hoc-signed build is a new
/// app to the Keychain after every rebuild, and the resulting access prompt
/// blocks the main thread inside SecItemCopyMatching.
protocol KeychainStore {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
    func contains(account: String) -> Bool
}

struct KeychainError: Error, LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return "Keychain: \(message)"
    }
}

/// Provider keys in `~/Library/Application Support/FocusStudio/secrets.json`,
/// directory 0700 and file 0600, written atomically. The same model as Codex's
/// own `auth.json`: readable only by this user, never prompting, never bundled.
final class FileSecretStore: KeychainStore {
    static let defaultURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FocusStudio", isDirectory: true)
        .appendingPathComponent("secrets.json")

    private let url: URL
    private let lock = NSLock()

    init(url: URL = FileSecretStore.defaultURL) {
        self.url = url
    }

    func read(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try load()[account]
    }

    func write(_ value: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        var values = try load()
        values[account] = value
        try save(values)
    }

    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        var values = try load()
        guard values.removeValue(forKey: account) != nil else { return }
        try save(values)
    }

    func contains(account: String) -> Bool {
        (try? read(account: account)).flatMap { $0 } != nil
    }

    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func save(_ values: [String: String]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(values)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Generic-password items under one service name, one per provider. Items are
/// bound to this Mac and readable once it has been unlocked after boot.
struct SecurityKeychainStore: KeychainStore {
    var service = AIGatewayStore.keychainService

    func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Focus Studio AI · \(account)"
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Attribute-only lookup: it never reads the secret, so it cannot prompt.
    func contains(account: String) -> Bool {
        var query = baseQuery(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

final class InMemoryKeychainStore: KeychainStore {
    private(set) var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func read(account: String) throws -> String? { values[account] }
    func write(_ value: String, account: String) throws { values[account] = value }
    func delete(account: String) throws { values[account] = nil }
    func contains(account: String) -> Bool { values[account] != nil }
}

/// Which model answers the conversational assistant.
enum AssistantBrain: String, CaseIterable, Codable, Identifiable, Sendable {
    /// The app-wide default text model from the gateway.
    case gatewayModel
    /// A Codex app-server thread using the Codex Director sign-in.
    case codex

    nonisolated static let defaultsKey = "assistant.brain"

    var id: String { rawValue }

    /// Localizable key.
    var title: String {
        switch self {
        case .gatewayModel: return "Default text model"
        case .codex: return "Codex (ChatGPT sign-in)"
        }
    }
}

/// Outcome of copying `ARK_API_KEY` from `~/.config/focus-studio/ark.env`.
enum ArkEnvironmentImport: Equatable, Sendable {
    case fileMissing
    case keyMissing
    case keychainFailed(String)
    /// The key was stored; `connected` is the result of the provider test.
    case imported(connected: Bool, summary: String?)
}

/// The UserDefaults payload. It never carries a secret.
struct AIGatewayPreferences: Codable, Equatable {
    var providers: [AIProviderConfiguration] = []
    var defaultTextModel: AITextModelSelection?
    var preferredVideoProvider: AIVideoProvider = .ark
    /// Exact Ark model IDs. Media generation must never silently downgrade to
    /// a cheaper model when the selected one is unavailable.
    var preferredVideoModelID = AIGatewayStore.recommendedVideoModelID
    var preferredImageModelID = AIGatewayStore.recommendedImageModelID

    private enum CodingKeys: String, CodingKey {
        case providers, defaultTextModel, preferredVideoProvider, preferredVideoModelID, preferredImageModelID
    }

    init(providers: [AIProviderConfiguration] = [], defaultTextModel: AITextModelSelection? = nil,
         preferredVideoProvider: AIVideoProvider = .ark,
         preferredVideoModelID: String = AIGatewayStore.recommendedVideoModelID,
         preferredImageModelID: String = AIGatewayStore.recommendedImageModelID) {
        self.providers = providers
        self.defaultTextModel = defaultTextModel
        self.preferredVideoProvider = preferredVideoProvider
        self.preferredVideoModelID = preferredVideoModelID
        self.preferredImageModelID = preferredImageModelID
    }

    /// Older installations have no media preferences. Preserve their provider
    /// and text settings while providing an explicit, quality-first video pick.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decodeIfPresent([AIProviderConfiguration].self, forKey: .providers) ?? []
        defaultTextModel = try container.decodeIfPresent(AITextModelSelection.self, forKey: .defaultTextModel)
        preferredVideoProvider = try container.decodeIfPresent(AIVideoProvider.self, forKey: .preferredVideoProvider) ?? .ark
        preferredVideoModelID = try container.decodeIfPresent(String.self, forKey: .preferredVideoModelID)
            ?? AIGatewayStore.recommendedVideoModelID
        preferredImageModelID = try container.decodeIfPresent(String.self, forKey: .preferredImageModelID)
            ?? AIGatewayStore.recommendedImageModelID
    }
}

enum AIProviderStatus: Equatable {
    /// No key (or, for a custom endpoint, no base URL).
    case unconfigured
    /// Credentials exist but the last test failed or never ran.
    case needsTest
    /// The last test succeeded.
    case ready
}

/// Provider settings for every AI feature. Preferences live in UserDefaults,
/// keys in the Keychain; other features call `resolvedClient()`.
@MainActor
final class AIGatewayStore: ObservableObject {
    nonisolated static let defaultsKey = "aiGateway.v1"
    nonisolated static let keychainService = "com.local.focusstudio.ai"
    /// Exact ID from Ark's model list. Keeping the dated ID visible makes the
    /// requested model release reviewable before a paid generation task.
    nonisolated static let recommendedVideoModelID = "doubao-seedance-2-5-260628"
    nonisolated static let recommendedGeminiVideoModelID = "veo-3.1-generate-preview"
    nonisolated static let geminiVideoModelIDs = [
        "veo-3.1-generate-preview", "veo-3.1-fast-generate-preview", "veo-3.1-lite-generate-preview"
    ]
    nonisolated static let recommendedImageModelID = "doubao-seedream-4-5-251128"

    @Published var providers: [AIProviderConfiguration] {
        didSet { persist() }
    }
    @Published var defaultTextModel: AITextModelSelection? {
        didSet { persist() }
    }
    @Published var preferredVideoProvider: AIVideoProvider {
        didSet {
            if videoModelProvider(for: preferredVideoModelID) != preferredVideoProvider {
                preferredVideoModelID = preferredVideoProvider == .ark
                    ? Self.recommendedVideoModelID : Self.recommendedGeminiVideoModelID
            }
            persist()
        }
    }
    @Published var preferredVideoModelID: String {
        didSet {
            if let provider = videoModelProvider(for: preferredVideoModelID), provider != preferredVideoProvider {
                preferredVideoProvider = provider
            }
            persist()
        }
    }
    @Published var preferredImageModelID: String {
        didSet { persist() }
    }
    /// Persisted separately under `assistant.brain`; read by the assistant on every send.
    @Published var assistantBrain: AssistantBrain {
        didSet { defaults.set(assistantBrain.rawValue, forKey: AssistantBrain.defaultsKey) }
    }
    @Published private(set) var providersWithKeys: Set<AIProviderKind> = []
    @Published private(set) var testingProviders: Set<AIProviderKind> = []

    private let defaults: UserDefaults
    private let keychain: any KeychainStore
    private let session: URLSession

    init(defaults: UserDefaults = .standard,
         keychain: any KeychainStore = FileSecretStore(),
         session: URLSession = .shared) {
        self.defaults = defaults
        self.keychain = keychain
        self.session = session
        let saved = Self.load(from: defaults)
        providers = Self.completeProviderList(saved.providers)
        defaultTextModel = saved.defaultTextModel
        preferredVideoProvider = saved.preferredVideoProvider
        preferredVideoModelID = saved.preferredVideoModelID
        preferredImageModelID = saved.preferredImageModelID
        assistantBrain = AssistantBrain(rawValue: defaults.string(forKey: AssistantBrain.defaultsKey) ?? "") ?? .gatewayModel
        refreshKeyPresence()
    }

    // MARK: - ark.env

    /// `~/.config/focus-studio/ark.env`, the file the Claude Code skills read.
    /// The app only ever reads it.
    nonisolated static var arkEnvironmentFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/focus-studio/ark.env")
    }

    nonisolated static var arkEnvironmentFileExists: Bool {
        FileManager.default.fileExists(atPath: arkEnvironmentFileURL.path)
    }

    /// `ARK_API_KEY=…` from the env file (quotes and `export` tolerated).
    nonisolated static func arkEnvironmentKey(from url: URL = arkEnvironmentFileURL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces) }
            guard line.hasPrefix("ARK_API_KEY=") else { continue }
            var value = String(line.dropFirst("ARK_API_KEY=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, let first = value.first, let last = value.last, first == last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Copies the env file's key into the Keychain, tests Volcengine Ark and,
    /// when no default text model exists, lets the test pick the recommended
    /// Doubao model. Safe to call at every launch: nothing happens without a file.
    func importArkEnvironmentKey(from url: URL = arkEnvironmentFileURL) async -> ArkEnvironmentImport {
        guard FileManager.default.fileExists(atPath: url.path) else { return .fileMissing }
        guard let key = Self.arkEnvironmentKey(from: url) else { return .keyMissing }
        do {
            try setAPIKey(key, for: .volcengineArk)
        } catch {
            return .keychainFailed(error.localizedDescription)
        }
        await test(.volcengineArk)
        let configuration = configuration(for: .volcengineArk)
        return .imported(connected: configuration.lastTestSucceeded == true, summary: configuration.lastTestSummary)
    }

    // MARK: - Configuration

    func configuration(for kind: AIProviderKind) -> AIProviderConfiguration {
        providers.first { $0.kind == kind } ?? AIProviderConfiguration(kind: kind)
    }

    func update(_ kind: AIProviderKind, _ change: (inout AIProviderConfiguration) -> Void) {
        guard let index = providers.firstIndex(where: { $0.kind == kind }) else { return }
        var configuration = providers[index]
        change(&configuration)
        guard configuration != providers[index] else { return }
        providers[index] = configuration
    }

    /// Sets a provider's model and keeps the app default in step when that
    /// provider is the default.
    func setDefaultModelID(_ modelID: String, for kind: AIProviderKind) {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        update(kind) { $0.defaultModelID = trimmed }
        if defaultTextModel?.provider == kind {
            defaultTextModel = trimmed.isEmpty ? nil : AITextModelSelection(provider: kind, modelID: trimmed)
        }
    }

    /// An empty or default URL clears the override.
    func setBaseURL(_ url: String, for kind: AIProviderKind) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        update(kind) { current in
            let value = trimmed == kind.defaultBaseURL ? "" : trimmed
            guard current.baseURLOverride != value else { return }
            current.baseURLOverride = value
            current.lastTestedAt = nil
            current.lastTestSucceeded = nil
            current.lastTestSummary = nil
            current.lastTestModelCount = nil
        }
    }

    /// Providers that can serve as the app-wide default: enabled, tested, with
    /// a model. The current default stays listed even if it no longer qualifies.
    var availableDefaultSelections: [AITextModelSelection] {
        var selections = providers
            .filter { $0.kind.supportsTextChat && $0.isEnabled && $0.lastTestSucceeded == true && !$0.defaultModelID.isEmpty }
            .map { AITextModelSelection(provider: $0.kind, modelID: $0.defaultModelID) }
        if let current = defaultTextModel, !selections.contains(current) { selections.append(current) }
        return selections
    }

    /// Only IDs returned by the last successful Ark model-list request count
    /// as listed. A stored or built-in preference alone does not prove access.
    var availableVideoModelIDs: [String] {
        listedVideoModels(for: preferredVideoProvider)
    }

    func listedVideoModels(for provider: AIVideoProvider) -> [String] {
        let kind = provider.gatewayKind
        guard status(for: kind) == .ready else { return [] }
        return configuration(for: kind).cachedModelIDs.filter { id in
            switch provider {
            case .ark: return id.localizedCaseInsensitiveContains("seedance")
            case .gemini: return id.lowercased().hasPrefix("veo-")
            }
        }
    }

    func videoModelProvider(for id: String) -> AIVideoProvider? {
        let lowered = id.lowercased()
        if lowered.contains("seedance") { return .ark }
        if lowered.hasPrefix("veo-") { return .gemini }
        return nil
    }

    func isVideoModelListed(_ id: String) -> Bool {
        guard let provider = videoModelProvider(for: id) else { return false }
        switch provider {
        case .ark where !Self.canPriceArkVideoModel(id): return false
        case .gemini where !Self.geminiVideoModelIDs.contains(id): return false
        default: break
        }
        return listedVideoModels(for: provider).contains(id)
    }

    var availableImageModelIDs: [String] {
        guard status(for: .volcengineArk) == .ready else { return [] }
        return configuration(for: .volcengineArk).cachedModelIDs
            .filter { $0.localizedCaseInsensitiveContains("seedream") }
    }

    /// The preset is selectable before connection, but the UI labels it as
    /// unverified until Ark has returned the exact ID for this account.
    var videoModelChoices: [String] {
        Self.uniqueModelIDs(
            [preferredVideoModelID, Self.recommendedVideoModelID]
                + listedVideoModels(for: .ark).filter(Self.canPriceArkVideoModel)
                + Self.geminiVideoModelIDs
                + listedVideoModels(for: .gemini).filter { Self.geminiVideoModelIDs.contains($0) }
        )
    }

    /// A provider may list models that the editor cannot yet price or call.
    /// Keep those out of the generation picker instead of offering a paid
    /// selection that later fails validation.
    private static func canPriceArkVideoModel(_ id: String) -> Bool {
        let knownFamilies = [
            "doubao-seedance-2-5", "doubao-seedance-2-0-mini",
            "doubao-seedance-2-0-fast", "doubao-seedance-2-0",
            "doubao-seedance-1-0-pro-fast", "doubao-seedance-1-0-pro",
        ]
        let lowered = id.lowercased()
        return knownFamilies.contains { lowered == $0 || lowered.hasPrefix($0 + "-") }
    }

    var imageModelChoices: [String] {
        Self.uniqueModelIDs([preferredImageModelID, Self.recommendedImageModelID] + availableImageModelIDs)
    }

    func videoModelDisplayName(_ id: String) -> String {
        let normalized = id.lowercased()
        if normalized.hasPrefix("veo-3.1-fast") { return "Veo 3.1 Fast" }
        if normalized.hasPrefix("veo-3.1-lite") { return "Veo 3.1 Lite" }
        if normalized.hasPrefix("veo-3.1") { return "Veo 3.1" }
        if normalized.contains("seedance-2-5") { return "Seedance 2.5" }
        if normalized.contains("seedance-2-0-mini") { return "Seedance 2.0 mini" }
        if normalized.contains("seedance-2-0-fast") { return "Seedance 2.0 fast" }
        if normalized.contains("seedance-2-0") { return "Seedance 2.0" }
        return id
    }

    func imageModelDisplayName(_ id: String) -> String {
        let normalized = id.lowercased()
        if normalized.contains("seedream-5-0-pro") { return "Seedream 5.0 pro" }
        if normalized.contains("seedream-5-0") { return "Seedream 5.0" }
        if normalized.contains("seedream-4-5") { return "Seedream 4.5" }
        return id
    }

    private static func uniqueModelIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func isConfigured(_ kind: AIProviderKind) -> Bool {
        if kind.requiresAPIKey { return providersWithKeys.contains(kind) }
        return !configuration(for: kind).effectiveBaseURL.isEmpty
    }

    func status(for kind: AIProviderKind) -> AIProviderStatus {
        guard isConfigured(kind) else { return .unconfigured }
        return configuration(for: kind).lastTestSucceeded == true ? .ready : .needsTest
    }

    // MARK: - Secrets

    func apiKey(for kind: AIProviderKind) -> String? {
        guard let key = try? keychain.read(account: kind.rawValue), !key.isEmpty else { return nil }
        return key
    }

    /// An empty key deletes the stored one. Any change invalidates the last test.
    func setAPIKey(_ key: String, for kind: AIProviderKind) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.delete(account: kind.rawValue)
            providersWithKeys.remove(kind)
        } else {
            try keychain.write(trimmed, account: kind.rawValue)
            providersWithKeys.insert(kind)
        }
        update(kind) {
            $0.lastTestedAt = nil
            $0.lastTestSucceeded = nil
            $0.lastTestSummary = nil
            $0.lastTestModelCount = nil
        }
    }

    func refreshKeyPresence() {
        providersWithKeys = Set(AIProviderKind.allCases.filter { keychain.contains(account: $0.rawValue) })
    }

    // MARK: - Clients

    /// A client for the default text model, or a clear error about what is missing.
    func resolvedClient() throws -> AIGatewayClient {
        guard let selection = defaultTextModel else { throw AIGatewayError.noDefaultModel }
        guard selection.provider.supportsTextChat else {
            throw AIGatewayError.invalidResponse("The selected provider is for video generation only")
        }
        guard configuration(for: selection.provider).isEnabled else {
            throw AIGatewayError.providerDisabled(selection.provider)
        }
        guard !selection.modelID.isEmpty else { throw AIGatewayError.missingModelID(selection.provider) }
        return try client(for: selection.provider, modelID: selection.modelID)
    }

    func client(for kind: AIProviderKind, modelID: String) throws -> AIGatewayClient {
        guard kind.supportsTextChat else {
            throw AIGatewayError.invalidResponse("\(kind.title) is for video generation only")
        }
        let base = configuration(for: kind).effectiveBaseURL
        guard let url = URL(string: base), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else {
            throw AIGatewayError.invalidBaseURL(base)
        }
        let key = apiKey(for: kind) ?? ""
        if key.isEmpty, kind.requiresAPIKey { throw AIGatewayError.missingAPIKey(kind) }
        return AIGatewayClient(kind: kind, baseURL: url, apiKey: key, modelID: modelID, session: session)
    }

    // MARK: - Testing

    /// Lists the provider's models, caches them and picks a recommended default
    /// when none is set. APIs without a model list are verified with one short
    /// completion on the chosen model instead. Errors land in `lastTestSummary`.
    func test(_ kind: AIProviderKind) async {
        guard !testingProviders.contains(kind) else { return }
        testingProviders.insert(kind)
        defer { testingProviders.remove(kind) }
        if kind == .googleGemini {
            await testGeminiModels()
            return
        }
        do {
            let configuration = configuration(for: kind)
            let client = try client(for: kind, modelID: configuration.defaultModelID)
            var modelIDs: [String]
            var modelCount: Int?
            do {
                modelIDs = try await client.listModels().map(\.id)
                modelCount = modelIDs.count
                modelIDs.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            } catch AIGatewayError.httpStatus(let status, _) where status == 404 || status == 405 {
                guard !configuration.defaultModelID.isEmpty else { throw AIGatewayError.modelListUnavailable(kind) }
                _ = try await client.complete(AICompletionRequest(user: "Reply with OK.", maxTokens: 16))
                modelIDs = configuration.cachedModelIDs
                if !modelIDs.contains(configuration.defaultModelID) { modelIDs.append(configuration.defaultModelID) }
            }
            let ids = modelIDs
            let textIDs = kind == .volcengineArk
                ? ids.filter { id in
                    let lowered = id.lowercased()
                    return !AIProviderKind.nonChatModelMarkers.contains { lowered.contains($0) }
                }
                : ids
            update(kind) { current in
                current.cachedModelIDs = ids
                if current.defaultModelID.isEmpty { current.defaultModelID = kind.recommendedModelID(from: textIDs) ?? "" }
                current.lastTestedAt = Date()
                current.lastTestSucceeded = true
                current.lastTestSummary = nil
                current.lastTestModelCount = modelCount
            }
            let chosen = self.configuration(for: kind).defaultModelID
            if !chosen.isEmpty, defaultTextModel == nil || defaultTextModel?.provider == kind {
                defaultTextModel = AITextModelSelection(provider: kind, modelID: chosen)
            }
        } catch {
            let message = (error as? AIGatewayError)?.errorDescription ?? error.localizedDescription
            update(kind) { current in
                current.lastTestedAt = Date()
                current.lastTestSucceeded = false
                current.lastTestSummary = message
                current.lastTestModelCount = nil
            }
        }
    }

    /// Gemini's native API is not OpenAI-compatible. A read-only `/models`
    /// request checks the key and records exact Veo IDs without starting a
    /// paid generation task or trying a chat/completions endpoint.
    private func testGeminiModels() async {
        let kind: AIProviderKind = .googleGemini
        do {
            guard let key = apiKey(for: kind), !key.isEmpty else { throw AIGatewayError.missingAPIKey(kind) }
            let base = configuration(for: kind).effectiveBaseURL
            guard let url = URL(string: base), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw AIGatewayError.invalidBaseURL(base)
            }
            var ids: [String] = []
            var nextPageToken: String?
            var seenTokens = Set<String>()
            repeat {
                var components = URLComponents(url: url.appendingPathComponent("models"), resolvingAgainstBaseURL: false)
                var query = [URLQueryItem(name: "pageSize", value: "1000")]
                if let nextPageToken { query.append(URLQueryItem(name: "pageToken", value: nextPageToken)) }
                components?.queryItems = query
                guard let endpoint = components?.url else { throw AIGatewayError.invalidBaseURL(base) }
                var request = URLRequest(url: endpoint)
                request.timeoutInterval = 20
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw AIGatewayError.invalidResponse("no HTTP response") }
                guard (200...299).contains(http.statusCode) else {
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let remote = ((object?["error"] as? [String: Any])?["message"] as? String) ?? ""
                    let message = String(remote.replacingOccurrences(of: key, with: "[redacted]").prefix(200))
                    throw AIGatewayError.httpStatus(http.statusCode, message)
                }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let models = object["models"] as? [[String: Any]] else {
                    throw AIGatewayError.invalidResponse("Gemini did not return a model list")
                }
                ids += models.compactMap { entry in
                    guard let name = entry["name"] as? String else { return nil }
                    return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
                }
                nextPageToken = object["nextPageToken"] as? String
                if let nextPageToken, !seenTokens.insert(nextPageToken).inserted { break }
            } while nextPageToken != nil && seenTokens.count < 10

            let listed = Array(Set(ids)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            update(kind) { current in
                current.cachedModelIDs = listed
                current.lastTestedAt = Date()
                current.lastTestSucceeded = true
                current.lastTestSummary = nil
                current.lastTestModelCount = listed.count
            }
        } catch {
            let message = (error as? AIGatewayError)?.errorDescription ?? error.localizedDescription
            update(kind) { current in
                current.lastTestedAt = Date()
                current.lastTestSucceeded = false
                current.lastTestSummary = message
                current.lastTestModelCount = nil
            }
        }
    }

    // MARK: - Persistence

    private func persist() {
        let preferences = AIGatewayPreferences(
            providers: providers, defaultTextModel: defaultTextModel,
            preferredVideoProvider: preferredVideoProvider,
            preferredVideoModelID: preferredVideoModelID,
            preferredImageModelID: preferredImageModelID
        )
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> AIGatewayPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              let preferences = try? JSONDecoder().decode(AIGatewayPreferences.self, from: data)
        else { return AIGatewayPreferences() }
        return preferences
    }

    /// Every provider exactly once, in display order; saved settings win.
    private static func completeProviderList(_ saved: [AIProviderConfiguration]) -> [AIProviderConfiguration] {
        AIProviderKind.allCases.map { kind in
            saved.first { $0.kind == kind } ?? AIProviderConfiguration(kind: kind)
        }
    }
}
