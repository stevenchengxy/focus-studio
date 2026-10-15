import Foundation
import Security

struct CommunityConnectionError: LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
    static let invalidResponse = Self(code: "invalid_response", message: "The community response could not be verified. Please try again.")
    static let expired = Self(code: "connection_expired", message: "This community connection expired. Connect again.")
}

struct CommunityConnectionIdentity: Codable, Equatable, Sendable {
    let id: String
    let email: String
    let displayName: String?
}
struct CommunityConnectionPairing: Codable, Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: Int
}
struct CommunityConnectionSnapshot: Equatable, Sendable {
    var pairing: CommunityConnectionPairing?
    var identity: CommunityConnectionIdentity?
    var hasCredential = false
    var clientConfirmed = false
    static let disconnected = Self()
}

protocol CommunityCredentialVault: Sendable {
    func read() async throws -> Data?
    func write(_ data: Data) async throws
    func delete() async throws
}

/// A separate, device-only Keychain item. No Codex, provider or subscription
/// credentials are read, migrated, or removed by community connection.
actor CommunityKeychainVault: CommunityCredentialVault {
    static let service = "studio.focus.community"
    static let account = "community-connection-v1"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }
    func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure() }
        return data
    }
    func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw failure() }
        var values = query
        values[kSecValueData as String] = data
        values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        values[kSecAttrLabel as String] = "Focus Studio · Community connection"
        guard SecItemAdd(values as CFDictionary, nil) == errSecSuccess else { throw failure() }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() }
    }
    private func failure() -> CommunityConnectionError {
        .init(code: "credential_storage", message: "The community connection could not be saved in Keychain. Please try again.")
    }
}

protocol CommunityConnectionTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
private final class CommunityRedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Even an unauthenticated exchange carries the secret deviceCode.
        completionHandler(nil)
    }
}
final class CommunityURLSessionTransport: CommunityConnectionTransport, @unchecked Sendable {
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: CommunityRedirectRefuser(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CommunityConnectionError.invalidResponse }
        return (data, response)
    }
}

/// Only purpose=community credentials are accepted. Its closed endpoint enum
/// cannot send that credential to billing, export, Codex, or browser APIs.
actor NativeCommunityConnectionClient {
    static let serviceURL = URL(string: "https://focus-studio.stevenchengxy19.chatgpt.site")!
    private struct Token: Codable, Sendable {
        let accessToken: String
        var expiresAt: Date
        var identity: CommunityConnectionIdentity?
        var clientConfirmed: Bool
    }
    private struct Saved: Codable, Sendable {
        let version: Int
        let origin: String
        let purpose: String
        var pairing: CommunityConnectionPairing?
        var token: Token?
    }
    private enum Endpoint: String {
        case start = "device/start", exchange = "device/token", identity = "device/community"
        case activate = "device/activate", revoke = "device/revoke"
    }
    private let origin: URL
    private let transport: any CommunityConnectionTransport
    private let vault: any CommunityCredentialVault
    private let now: @Sendable () -> Date
    private var saved: Saved?
    private var loaded = false
    private var generation: UInt64 = 0
    private var credentialMutation: Task<Void, Error>?

    init(origin: URL = serviceURL, transport: any CommunityConnectionTransport = CommunityURLSessionTransport(),
         vault: any CommunityCredentialVault = CommunityKeychainVault(), now: @escaping @Sendable () -> Date = Date.init) {
        precondition(origin.scheme == "https" && origin.host != nil && origin.user == nil && origin.password == nil
                     && origin.query == nil && origin.fragment == nil && (origin.path.isEmpty || origin.path == "/"))
        self.origin = origin; self.transport = transport; self.vault = vault; self.now = now
    }
    func snapshot() -> CommunityConnectionSnapshot {
        .init(pairing: saved?.pairing, identity: saved?.token?.identity, hasCredential: saved?.token != nil,
              clientConfirmed: saved?.token?.clientConfirmed ?? false)
    }
    private func begin() -> UInt64 { generation &+= 1; return generation }
    private func check(_ operation: UInt64) throws {
        try Task.checkCancellation()
        guard operation == generation else { throw CancellationError() }
    }
    private func load(_ operation: UInt64) async throws {
        if loaded { return }
        if let pending = credentialMutation { try await pending.value; try check(operation) }
        let data = try await vault.read()
        try check(operation)
        if let data {
            guard let value = try? JSONDecoder().decode(Saved.self, from: data), value.version == 1,
                  value.origin == origin.absoluteString, value.purpose == "community",
                  (value.pairing != nil) != (value.token != nil),
                  value.token.map({ Self.validToken($0.accessToken) && $0.expiresAt.timeIntervalSince1970.isFinite }) ?? true,
                  value.pairing.map({ Self.validSecret($0.deviceCode) && Self.validUserCode($0.userCode)
                    && (5...30).contains($0.interval) && $0.expiresAt.timeIntervalSince1970.isFinite
                    && Self.browserURL(origin: origin, userCode: $0.userCode) == $0.verificationURL }) ?? true else {
                // Reject incompatible credentials without sending them. Clear
                // only this community item so the next connection can recover.
                try await persist(nil, operation: operation)
                throw CommunityConnectionError.invalidResponse
            }
            saved = value
        }
        loaded = true
    }
    private func persist(_ value: Saved?, operation: UInt64) async throws {
        try check(operation)
        let data = try value.map { try JSONEncoder().encode($0) }
        let previous = credentialMutation, vault = vault
        // Serialize writes, including a cancellation's delete, even if a vault
        // implementation completes an earlier write asynchronously.
        let mutation = Task {
            if let previous { _ = try? await previous.value }
            if let data { try await vault.write(data) } else { try await vault.delete() }
        }
        credentialMutation = mutation
        try await mutation.value
        try check(operation)
        saved = value; loaded = true
    }
    func restore() async throws -> CommunityConnectionSnapshot {
        let operation = begin()
        try await load(operation)
        if let pairing = saved?.pairing {
            guard pairing.expiresAt > now() else { try await persist(nil, operation: operation); throw CommunityConnectionError.expired }
            return snapshot()
        }
        guard let token = saved?.token else { return .disconnected }
        guard token.expiresAt > now() else { try await persist(nil, operation: operation); throw CommunityConnectionError.expired }
        return try await refreshIdentity(token, operation: operation)
    }
    func startPairing() async throws -> CommunityConnectionPairing {
        let operation = begin()
        try await load(operation)
        guard saved?.token == nil else { throw CommunityConnectionError(code: "already_connected", message: "Disconnect this community account before connecting another.") }
        let response = try await request(.start, body: ["purpose": "community"])
        try check(operation)
        struct Start: Decodable {
            let deviceCode: String; let userCode: String; let verificationUriComplete: String
            let expiresIn: Int; let interval: Int; let purpose: String
        }
        guard response.status == 200, let value = try? JSONDecoder().decode(Start.self, from: response.data), value.purpose == "community",
              Self.validSecret(value.deviceCode), Self.validUserCode(value.userCode), (1...600).contains(value.expiresIn),
              (1...30).contains(value.interval), let url = URL(string: value.verificationUriComplete),
              url == Self.browserURL(origin: origin, userCode: value.userCode) else { throw CommunityConnectionError.invalidResponse }
        let pairing = CommunityConnectionPairing(deviceCode: value.deviceCode, userCode: value.userCode, verificationURL: url,
                                                 expiresAt: now().addingTimeInterval(Double(value.expiresIn)), interval: max(5, value.interval))
        try await persist(.init(version: 1, origin: origin.absoluteString, purpose: "community", pairing: pairing), operation: operation)
        return pairing
    }
    func pollPairing(_ pairing: CommunityConnectionPairing) async throws -> CommunityConnectionSnapshot? {
        let operation = begin()
        try await load(operation)
        guard saved?.pairing?.deviceCode == pairing.deviceCode else { throw CancellationError() }
        guard pairing.expiresAt > now() else { try await persist(nil, operation: operation); throw CommunityConnectionError.expired }
        let response: Response
        do { response = try await request(.exchange, body: ["deviceCode": pairing.deviceCode]) }
        catch {
            try check(operation)
            if let error = error as? CommunityConnectionError, ["code_expired", "device_revoked"].contains(error.code) {
                try await persist(nil, operation: operation)
            }
            throw error
        }
        try check(operation)
        if response.status == 202 {
            struct Pending: Decodable { let status: String }
            guard let pending = try? JSONDecoder().decode(Pending.self, from: response.data), pending.status == "authorization_pending" else { throw CommunityConnectionError.invalidResponse }
            return nil
        }
        struct Exchange: Decodable { let accessToken: String; let tokenType: String; let expiresIn: Int; let purpose: String }
        guard response.status == 200, let value = try? JSONDecoder().decode(Exchange.self, from: response.data),
              value.purpose == "community", value.tokenType == "Bearer", Self.validToken(value.accessToken),
              (1...(30 * 86400)).contains(value.expiresIn) else { throw CommunityConnectionError.invalidResponse }
        let token = Token(accessToken: value.accessToken, expiresAt: now().addingTimeInterval(Double(value.expiresIn)), clientConfirmed: false)
        try await persist(.init(version: 1, origin: origin.absoluteString, purpose: "community", token: token), operation: operation)
        return try await refreshIdentity(token, operation: operation)
    }
    private func refreshIdentity(_ token: Token, operation: UInt64) async throws -> CommunityConnectionSnapshot {
        let response: Response
        do { response = try await request(.identity, method: "GET", token: token.accessToken) }
        catch {
            try check(operation)
            if let error = error as? CommunityConnectionError, error.code == "connection_expired" { try await persist(nil, operation: operation) }
            throw error
        }
        try check(operation)
        struct Status: Decodable {
            let purpose: String; let account: CommunityConnectionIdentity; let clientConfirmed: Bool; let expiresAt: Double
        }
        guard response.status == 200, let status = try? JSONDecoder().decode(Status.self, from: response.data), status.purpose == "community",
              !status.account.id.isEmpty, status.account.id.count <= 256, !status.account.email.isEmpty,
              status.account.email.count <= 320, status.expiresAt.isFinite, status.expiresAt > now().timeIntervalSince1970,
              status.expiresAt <= now().addingTimeInterval(31 * 86400).timeIntervalSince1970,
              token.identity == nil || token.identity?.id == status.account.id else { throw CommunityConnectionError.invalidResponse }
        var updated = token
        updated.expiresAt = Date(timeIntervalSince1970: status.expiresAt)
        updated.identity = status.account; updated.clientConfirmed = status.clientConfirmed
        try await persist(.init(version: 1, origin: origin.absoluteString, purpose: "community", token: updated), operation: operation)
        return snapshot()
    }
    func confirmClient() async throws -> CommunityConnectionSnapshot {
        let operation = begin()
        try await load(operation)
        guard var token = saved?.token, token.identity != nil else { throw CommunityConnectionError.expired }
        guard token.expiresAt > now() else { try await persist(nil, operation: operation); throw CommunityConnectionError.expired }
        let response: Response
        do { response = try await request(.activate, body: [:], token: token.accessToken) }
        catch {
            try check(operation)
            if let error = error as? CommunityConnectionError, error.code == "connection_expired" { try await persist(nil, operation: operation) }
            throw error
        }
        try check(operation)
        struct Receipt: Decodable { let confirmed: Bool }
        guard response.status == 200, let receipt = try? JSONDecoder().decode(Receipt.self, from: response.data), receipt.confirmed else { throw CommunityConnectionError.invalidResponse }
        token.clientConfirmed = true
        try await persist(.init(version: 1, origin: origin.absoluteString, purpose: "community", token: token), operation: operation)
        return snapshot()
    }
    func cancelPairing() async throws {
        let operation = begin()
        try await persist(nil, operation: operation)
    }
    func disconnect() async throws {
        let operation = begin()
        try await load(operation)
        let token = saved?.token?.accessToken
        try await persist(nil, operation: operation)
        if let token {
            do {
                let response = try await request(.revoke, body: [:], token: token)
                try check(operation)
                struct Receipt: Decodable { let revoked: Bool }
                guard response.status == 200, let receipt = try? JSONDecoder().decode(Receipt.self, from: response.data), receipt.revoked else {
                    throw CommunityConnectionError.invalidResponse
                }
            }
            catch {
                try check(operation)
                if let error = error as? CommunityConnectionError, error.code == "connection_expired" { return }
                throw CommunityConnectionError(code: "remote_revoke_failed", message: "Disconnected on this Mac. Remote sign-out could not be confirmed; manage connected devices in your browser.")
            }
        }
    }
    private struct Response { let data: Data; let status: Int }
    private func request(_ endpoint: Endpoint, method: String = "POST", body: [String: String]? = nil, token: String? = nil) async throws -> Response {
        var request = URLRequest(url: origin.appendingPathComponent("api").appendingPathComponent(endpoint.rawValue))
        request.httpMethod = method; request.timeoutInterval = 20; request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.send(request)
        guard response.url == request.url, data.count <= 65_536 else { throw CommunityConnectionError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { struct Detail: Decodable { let code: String }; let error: Detail }
            let detail = try? JSONDecoder().decode(Failure.self, from: data)
            switch response.statusCode {
            case 401: throw CommunityConnectionError.expired
            case 410: throw CommunityConnectionError(code: detail?.error.code ?? "code_expired", message: "This community sign-in code expired. Connect again.")
            case 429: throw CommunityConnectionError(code: "rate_limited", message: "Too many connection requests. Please wait a moment and try again.")
            case 300..<400: throw CommunityConnectionError.invalidResponse
            default: throw CommunityConnectionError(code: "service_unavailable", message: "The community service is unavailable. Your local projects and exports are unaffected.")
            }
        }
        return .init(data: data, status: response.statusCode)
    }
    private static func validSecret(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    private static func validToken(_ value: String) -> Bool { value.hasPrefix("fs_") && validSecret(String(value.dropFirst(3))) }
    private static func validUserCode(_ value: String) -> Bool {
        value.count == 13 && value[value.index(value.startIndex, offsetBy: 6)] == "-"
            && value.replacingOccurrences(of: "-", with: "").count == 12
            && value.replacingOccurrences(of: "-", with: "").allSatisfy { "0123456789ABCDEF".contains($0) }
    }
    private static func browserURL(origin: URL, userCode: String) -> URL {
        var url = URLComponents(url: origin.appendingPathComponent("account"), resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "code", value: userCode), .init(name: "purpose", value: "community")]
        return url.url!
    }
}
