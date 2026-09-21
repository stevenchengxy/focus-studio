import Combine
import Foundation
import Security

/// Secret storage. The app uses the macOS Keychain; tests keep values in memory.
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

/// The UserDefaults payload. It never carries a secret.
struct AIGatewayPreferences: Codable, Equatable {
    var providers: [AIProviderConfiguration] = []
    var defaultTextModel: AITextModelSelection?
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

    @Published var providers: [AIProviderConfiguration] {
        didSet { persist() }
    }
    @Published var defaultTextModel: AITextModelSelection? {
        didSet { persist() }
    }
    @Published private(set) var providersWithKeys: Set<AIProviderKind> = []
    @Published private(set) var testingProviders: Set<AIProviderKind> = []

    private let defaults: UserDefaults
    private let keychain: any KeychainStore
    private let session: URLSession

    init(defaults: UserDefaults = .standard,
         keychain: any KeychainStore = SecurityKeychainStore(),
         session: URLSession = .shared) {
        self.defaults = defaults
        self.keychain = keychain
        self.session = session
        let saved = Self.load(from: defaults)
        providers = Self.completeProviderList(saved.providers)
        defaultTextModel = saved.defaultTextModel
        refreshKeyPresence()
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
        update(kind) { $0.baseURLOverride = trimmed == kind.defaultBaseURL ? "" : trimmed }
    }

    /// Providers that can serve as the app-wide default: enabled, tested, with
    /// a model. The current default stays listed even if it no longer qualifies.
    var availableDefaultSelections: [AITextModelSelection] {
        var selections = providers
            .filter { $0.isEnabled && $0.lastTestSucceeded == true && !$0.defaultModelID.isEmpty }
            .map { AITextModelSelection(provider: $0.kind, modelID: $0.defaultModelID) }
        if let current = defaultTextModel, !selections.contains(current) { selections.append(current) }
        return selections
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
        guard configuration(for: selection.provider).isEnabled else {
            throw AIGatewayError.providerDisabled(selection.provider)
        }
        guard !selection.modelID.isEmpty else { throw AIGatewayError.missingModelID(selection.provider) }
        return try client(for: selection.provider, modelID: selection.modelID)
    }

    func client(for kind: AIProviderKind, modelID: String) throws -> AIGatewayClient {
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
            update(kind) { current in
                current.cachedModelIDs = ids
                if current.defaultModelID.isEmpty { current.defaultModelID = kind.recommendedModelID(from: ids) ?? "" }
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

    // MARK: - Persistence

    private func persist() {
        let preferences = AIGatewayPreferences(providers: providers, defaultTextModel: defaultTextModel)
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
