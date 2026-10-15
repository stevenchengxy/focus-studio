import AppKit
import Combine
import Foundation
import FocusStudioAutomation

struct NativeCommunityError: LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { L10n.tr(message) }
}

struct NativeCommunityPairing: Decodable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationUriComplete: String
    let expiresIn: Int
    let interval: Int
    let purpose: String
}

protocol NativeCommunityTokenStoring: Sendable {
    func read() async throws -> String?
    func write(_ token: String) async throws
    func delete() async throws
    func delete(ifMatching token: String) async throws
}

/// Community credentials never replace the legacy export/account credential.
private actor NativeCommunityKeychainStore: NativeCommunityTokenStoring {
    private let service = "studio.focus.community"
    private let account = "community-device-token"
    func read() throws -> String? { try SecurityKeychainStore(service: service).read(account: account) }
    func write(_ token: String) throws { try SecurityKeychainStore(service: service).write(token, account: account) }
    func delete() throws { try SecurityKeychainStore(service: service).delete(account: account) }
    func delete(ifMatching token: String) throws {
        if try read() == token { try delete() }
    }
}

private final class CommunityRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor NativeCommunityClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let origin = URL(string: "https://focus-studio.stevenchengxy19.chatgpt.site")!
    private static let session = URLSession(configuration: .ephemeral, delegate: CommunityRedirectBlocker(), delegateQueue: nil)
    private let origin: URL
    private let vault: any NativeCommunityTokenStoring
    private let transport: Transport
    private let isInstalledClient: @Sendable () -> Bool
    private var generation: UInt64 = 0
    private var activeDeviceCode: String?

    init(origin: URL = NativeCommunityClient.origin, vault: (any NativeCommunityTokenStoring)? = nil,
         isInstalledClient: @escaping @Sendable () -> Bool = { NativeCommunityClient.isRunningInstalledApp },
         transport: Transport? = nil) {
        self.origin = origin
        self.vault = vault ?? NativeCommunityKeychainStore()
        self.isInstalledClient = isInstalledClient
        self.transport = transport ?? { request in
            let (data, response) = try await Self.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, response)
        }
    }

    nonisolated static var isRunningInstalledApp: Bool {
        let url = Bundle.main.bundleURL.standardizedFileURL
        let canonical = AppInstaller.canonicalURL.standardizedFileURL
        return url.path == canonical.path && url.resolvingSymlinksInPath().path == canonical.path
            && Bundle.main.bundleIdentifier == "com.local.focusstudio"
            && Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "FocusStudio"
    }

    func canConfirm() -> Bool { isInstalledClient() }
    func hasToken() async throws -> Bool { try await vault.read() != nil }

    func startPairing() async throws -> NativeCommunityPairing {
        try requireInstalledClient()
        generation &+= 1
        let current = generation
        activeDeviceCode = nil
        let (data, status) = try await request("device/start", body: ["purpose": "community"])
        guard generation == current else { throw CancellationError() }
        guard status == 200 else { throw Self.invalidResponse }
        guard let pairing = try? JSONDecoder().decode(NativeCommunityPairing.self, from: data) else { throw Self.invalidResponse }
        let url = URL(string: pairing.verificationUriComplete)
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let query = components?.queryItems ?? []
        guard pairing.purpose == "community", Self.isSecret(pairing.deviceCode),
              pairing.userCode.range(of: "^[A-F0-9]{6}-[A-F0-9]{6}$", options: .regularExpression) != nil,
              (30...900).contains(pairing.expiresIn), (1...30).contains(pairing.interval),
              let url, url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port,
              url.user == nil, url.password == nil, url.fragment == nil, url.path == "/account",
              query.count == 2, query.filter({ $0.name == "code" && $0.value == pairing.userCode }).count == 1,
              query.filter({ $0.name == "purpose" && $0.value == "community" }).count == 1 else {
            throw Self.invalidResponse
        }
        activeDeviceCode = pairing.deviceCode
        return pairing
    }

    func pollPairing(_ pairing: NativeCommunityPairing) async throws -> Bool {
        guard activeDeviceCode == pairing.deviceCode else { throw CancellationError() }
        let current = generation
        let (data, status) = try await request("device/token", body: ["deviceCode": pairing.deviceCode])
        guard generation == current, activeDeviceCode == pairing.deviceCode else { throw CancellationError() }
        if status == 202 { return false }
        guard status == 200 else { throw Self.invalidResponse }
        struct Token: Decodable { let accessToken: String; let purpose: String }
        guard let token = try? JSONDecoder().decode(Token.self, from: data) else { throw Self.invalidResponse }
        guard token.purpose == "community", token.accessToken.hasPrefix("fs_"),
              Self.isSecret(String(token.accessToken.dropFirst(3))) else { throw Self.invalidResponse }
        try await vault.write(token.accessToken)
        // Cancellation can arrive while the OS keychain is saving the token.
        guard generation == current, activeDeviceCode == pairing.deviceCode else {
            try await vault.delete(ifMatching: token.accessToken)
            throw CancellationError()
        }
        activeDeviceCode = nil
        return true
    }

    /// A successful pairing alone is never a confirmation receipt.
    func confirm() async throws {
        try requireInstalledClient()
        let current = generation
        guard let token = try await vault.read() else {
            throw NativeCommunityError(code: "community_sign_in_required", message: "Connect your ChatGPT account to confirm this client.")
        }
        do {
            let (data, status) = try await request("device/activate", token: token)
            struct Receipt: Decodable { let confirmed: Bool }
            guard status == 200, let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.confirmed else { throw Self.invalidResponse }
            guard try await vault.read() == token, generation == current else { throw CancellationError() }
        } catch {
            if (error as? NativeCommunityError)?.code == "device_expired" {
                try await vault.delete(ifMatching: token)
            }
            throw error
        }
    }

    func cancelPendingConnection() { generation &+= 1; activeDeviceCode = nil }

    func disconnect() async throws {
        generation &+= 1
        activeDeviceCode = nil
        let token = try await vault.read()
        try await vault.delete()
        if let token { _ = try? await request("device/revoke", token: token) }
    }

    private func requireInstalledClient() throws {
        guard isInstalledClient() else {
            throw NativeCommunityError(code: "installation_required", message: "Open Focus Studio from Applications to confirm this client.")
        }
    }

    private static func isSecret(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    private static var invalidResponse: NativeCommunityError {
        NativeCommunityError(code: "invalid_response", message: "Client confirmation was not completed. Please retry.")
    }

    private func request(_ path: String, body: [String: String] = [:], token: String? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: origin.appendingPathComponent("api").appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport(request)
        guard data.count <= 128 * 1024, response.url?.scheme == origin.scheme, response.url?.host == origin.host,
              response.url?.port == origin.port, response.url?.path == request.url?.path,
              response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true else {
            throw Self.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            struct ErrorBody: Decodable { struct Detail: Decodable { let code: String }; let error: Detail }
            let code = (try? JSONDecoder().decode(ErrorBody.self, from: data).error.code) ?? "service_error"
            if response.statusCode == 401 {
                throw NativeCommunityError(code: "device_expired", message: "Your community connection expired. Connect your ChatGPT account again.")
            }
            if ["community_device_required", "community_sign_in_required"].contains(code) {
                throw NativeCommunityError(code: code, message: "Connect your ChatGPT account again to confirm this client for community publishing.")
            }
            if response.statusCode == 410 {
                throw NativeCommunityError(code: "code_expired", message: "This connection code expired. Connect again to get a new code.")
            }
            throw NativeCommunityError(code: code, message: "Community connection is temporarily unavailable. Your local recordings and exports are unaffected.")
        }
        return (data, response.statusCode)
    }
}

@MainActor
final class NativeCommunityConnectionStore: ObservableObject {
    static let shared = NativeCommunityConnectionStore()
    enum State { case disconnected, pairing, confirming, confirmed, reconnectRequired, error }
    @Published private(set) var state: State = .disconnected
    @Published private(set) var pairing: NativeCommunityPairing?
    @Published private(set) var error: String?
    @Published private(set) var isWorking = false
    private let client: NativeCommunityClient
    private var connectionTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(client: NativeCommunityClient = NativeCommunityClient()) { self.client = client }

    func refresh() async {
        guard !isWorking, await client.canConfirm() else { return }
        isWorking = true
        let current = generation
        defer { if generation == current { isWorking = false } }
        do {
            let hasToken = try await client.hasToken()
            guard generation == current else { return }
            guard hasToken else { state = .disconnected; error = nil; return }
            state = .confirming
            try await client.confirm()
            guard generation == current else { return }
            state = .confirmed; error = nil
        } catch { if generation == current { report(error) } }
    }

    func connect() {
        guard !isWorking else { return }
        generation &+= 1
        let current = generation
        isWorking = true; error = nil; state = .pairing
        connectionTask = Task {
            defer { if generation == current { isWorking = false; connectionTask = nil; pairing = nil } }
            do {
                let pending = try await client.startPairing()
                try Task.checkCancellation()
                guard generation == current else { return }
                pairing = pending
                guard let url = URL(string: pending.verificationUriComplete), NSWorkspace.shared.open(url) else {
                    throw NativeCommunityError(code: "browser_unavailable", message: "Your browser could not open. Try connecting again.")
                }
                let deadline = Date().addingTimeInterval(Double(pending.expiresIn))
                while Date() < deadline {
                    try Task.checkCancellation()
                    if try await client.pollPairing(pending) {
                        try Task.checkCancellation()
                        state = .confirming
                        try await client.confirm()
                        guard generation == current else { return }
                        state = .confirmed; return
                    }
                    try await Task.sleep(for: .seconds(max(5, pending.interval)))
                }
                throw NativeCommunityError(code: "code_expired", message: "This connection code expired. Connect again to get a new code.")
            } catch { if generation == current { report(error) } }
        }
    }

    func cancel() async {
        generation &+= 1
        connectionTask?.cancel(); connectionTask = nil
        await client.cancelPendingConnection()
        pairing = nil; isWorking = false; error = nil; state = .disconnected
    }

    func disconnect() async {
        await cancel()
        isWorking = true
        defer { isWorking = false }
        do { try await client.disconnect(); state = .disconnected }
        catch { report(error) }
    }

    private func report(_ failure: Error) {
        if failure is CancellationError { state = .disconnected; return }
        let code = (failure as? NativeCommunityError)?.code
        state = ["device_expired", "community_device_required", "community_sign_in_required"].contains(code ?? "") ? .reconnectRequired : .error
        error = (failure as? NativeCommunityError)?.errorDescription ?? L10n.tr("Community connection is temporarily unavailable. Your local recordings and exports are unaffected.")
    }
}
