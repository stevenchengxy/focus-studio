import AppKit
import Combine
import FocusStudioAutomation
import Foundation

struct NativeAccount: Decodable, Sendable {
    struct Identity: Decodable, Sendable { let id: String; let email: String }
    struct Entitlement: Decodable, Sendable {
        let plan: String
        let subscriptionStatus: String
        let currentPeriodEnd: Double?
        let canExport: Bool
        let freeExportsRemaining: Int
        let activeExportId: String?
    }
    let account: Identity
    let entitlement: Entitlement
    let billingConfigured: Bool
}

struct NativePairing: Decodable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationUriComplete: String
    let expiresIn: Int
    let interval: Int
}

struct SubscriptionServiceError: LocalizedError, ExportCommitFailure, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { L10n.tr(message) }
    var commitOutcomeIsKnown: Bool { !["service_unavailable", "invalid_response"].contains(code) }
}

/// Device access tokens never enter defaults, project files, tool receipts, or
/// logs. Keychain operations run off the main thread (including access prompts).
actor NativeSubscriptionClient: ExportAuthorizing {
    static let serviceURL = URL(string: "https://focus-studio.stevenchengxy19.chatgpt.site")!
    private static let tokenService = "studio.focus.subscription"
    private static let tokenAccount = "device-access-token"
    private let origin: URL
    private let session: URLSession
    private var token: String?
    private var loadedToken = false
    // Reuse the key if the reserve response is lost; a retry must not strand
    // an unknown reservation and create another one for the same project.
    private var pendingKeys: [String: UUID] = [:]
    private var reservingProjects = Set<String>()

    init(origin: URL = serviceURL, session: URLSession = .shared) {
        self.origin = origin; self.session = session
    }

    func hasToken() async throws -> Bool { try await accessToken() != nil }
    private func accessToken() async throws -> String? {
        if !loadedToken {
            token = try await Task.detached {
                try SecurityKeychainStore(service: Self.tokenService).read(account: Self.tokenAccount)
            }.value
            loadedToken = true
        }
        return token
    }
    private func saveToken(_ value: String) async throws {
        try await Task.detached {
            try SecurityKeychainStore(service: Self.tokenService).write(value, account: Self.tokenAccount)
        }.value
        token = value; loadedToken = true
    }
    func signOut() async throws {
        if (try? await accessToken()) != nil { _ = try? await request("device/revoke", body: [:]) }
        try await Task.detached {
            try SecurityKeychainStore(service: Self.tokenService).delete(account: Self.tokenAccount)
        }.value
        token = nil; loadedToken = true
    }

    func account() async throws -> NativeAccount {
        let response = try await request("account", method: "GET")
        return try JSONDecoder().decode(NativeAccount.self, from: response.data)
    }
    func startPairing() async throws -> NativePairing {
        let response = try await request("device/start", body: [:], authenticated: false)
        let pairing = try JSONDecoder().decode(NativePairing.self, from: response.data)
        // Even a malformed service response must not open an unrelated URL.
        guard let url = URL(string: pairing.verificationUriComplete), url.scheme == "https",
              url.host == origin.host else {
            throw SubscriptionServiceError(code: "invalid_response", message: "The sign-in link could not be verified. Try again.")
        }
        return pairing
    }
    func pollPairing(_ pairing: NativePairing) async throws -> Bool {
        let response = try await request("device/token", body: ["deviceCode": pairing.deviceCode], authenticated: false)
        if response.status == 202 { return false }
        struct Token: Decodable { let accessToken: String }
        let token = try JSONDecoder().decode(Token.self, from: response.data)
        guard token.accessToken.hasPrefix("fs_"), token.accessToken.count == 67,
              token.accessToken.dropFirst(3).allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw SubscriptionServiceError(code: "invalid_response", message: "The sign-in response was invalid. Try again.")
        }
        try await saveToken(token.accessToken)
        return true
    }

    func reserve(projectID: String, idempotencyKey: UUID) async throws -> ExportReservation {
        if !ProductAccessPolicy.requiresExportAccount { return ExportReservation(id: idempotencyKey.uuidString) }
        guard reservingProjects.insert(projectID).inserted else {
            throw SubscriptionServiceError(code: "export_in_progress", message: "Another export is already in progress. Try again after it finishes.")
        }
        defer { reservingProjects.remove(projectID) }
        let key = pendingKeys[projectID] ?? idempotencyKey
        pendingKeys[projectID] = key
        let response = try await retry {
            try await self.request("exports/reserve", body: ["idempotencyKey": key.uuidString, "projectId": projectID])
        }
        pendingKeys.removeValue(forKey: projectID)
        struct Reservation: Decodable { let exportId: String; let status: String }
        let reservation = try JSONDecoder().decode(Reservation.self, from: response.data)
        guard reservation.status == "reserved" else {
            throw SubscriptionServiceError(code: "invalid_reservation", message: "This export reservation is no longer available. Start a new export.")
        }
        return ExportReservation(id: reservation.exportId)
    }
    func renew(_ reservation: ExportReservation) async throws {
        if !ProductAccessPolicy.requiresExportAccount { return }
        _ = try await retry { try await self.request("exports/\(reservation.id)/renew", body: [:]) }
    }
    func commit(_ reservation: ExportReservation) async throws {
        // Also recovers renders staged by older versions without requiring
        // an account, a network connection, or a still-valid billing lease.
        if !ProductAccessPolicy.requiresExportAccount { return }
        let response = try await retry { try await self.request("exports/\(reservation.id)/commit", body: [:]) }
        try Self.validateCommitReceipt(response.data, reservation: reservation)
    }
    nonisolated static func validateCommitReceipt(_ data: Data, reservation: ExportReservation) throws {
        struct Receipt: Decodable { let exportId: String; let status: String }
        // A successful HTTP status alone cannot authorize publishing footage.
        // Malformed or unrelated receipts may hide a completed server commit,
        // so retain the staged video and recovery journal for the same job.
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.exportId == reservation.id, receipt.status == "committed" else {
            throw SubscriptionServiceError(code: "invalid_response", message: "Account service is unavailable. Your recording is safe; try again later.")
        }
    }
    func release(_ reservation: ExportReservation) async {
        if !ProductAccessPolicy.requiresExportAccount { return }
        _ = try? await retry { try await self.request("exports/\(reservation.id)/release", body: [:]) }
    }
    private func retry<T>(_ action: () async throws -> T) async throws -> T {
        for attempt in 0..<3 {
            do { return try await action() }
            catch {
                let transient = error is URLError || (error as? SubscriptionServiceError)?.code == "service_unavailable"
                if attempt == 2 || !transient || Task.isCancelled { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
            }
        }
        throw SubscriptionServiceError(code: "service_unavailable", message: "Account service is unavailable. Your recording is safe; try again later.")
    }
    private struct Response { let data: Data; let status: Int }
    private func request(_ path: String, method: String = "POST", body: [String: String]? = nil,
                         authenticated: Bool = true) async throws -> Response {
        var request = URLRequest(url: origin.appendingPathComponent("api").appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard let token = try await accessToken() else {
                throw SubscriptionServiceError(code: "sign_in_required", message: "Sign in in Settings → Account to use your free export or subscription.")
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            struct ErrorBody: Decodable { struct Detail: Decodable { let code: String; let message: String }; let error: Detail }
            let detail = try? JSONDecoder().decode(ErrorBody.self, from: data).error
            let message: String
            switch response.statusCode {
            case 401: message = "Your session expired. Sign in again in Settings → Account."
            case 402: message = "Your free export has been used. Choose a plan in Settings → Account to continue."
            case 409: message = detail?.code == "export_in_progress" ? "Another export is already in progress. Try again after it finishes." : "The export reservation expired. Please export again."
            case 410: message = "This sign-in code expired. Please try again."
            case 429: message = "Too many requests. Please wait a moment and try again."
            default: message = "Account service is unavailable. Your recording is safe; try again later."
            }
            throw SubscriptionServiceError(code: response.statusCode == 401 ? "sign_in_required" : (response.statusCode == 402 ? "subscription_required" : (response.statusCode >= 500 ? "service_unavailable" : (detail?.code ?? "request_failed"))), message: message)
        }
        return Response(data: data, status: response.statusCode)
    }
}

@MainActor
final class NativeSubscriptionStore: ObservableObject {
    let client = NativeSubscriptionClient()
    @Published private(set) var account: NativeAccount?
    @Published private(set) var pairing: NativePairing?
    @Published private(set) var recoveries: [ExportRecoveryRecord] = ExportRecoveryStore.records()
    @Published private(set) var isWorking = false
    @Published private(set) var error: String?
    private var pairingTask: Task<Void, Never>?

    func refresh() async {
        guard !isWorking else { return }
        guard ProductAccessPolicy.requiresExportAccount else {
            recoveries = ExportRecoveryStore.records()
            error = nil
            return
        }
        isWorking = true; defer { isWorking = false }
        do {
            if try await client.hasToken() { account = try await client.account() }
            else { account = nil }
            error = nil
        } catch {
            if (error as? SubscriptionServiceError)?.code == "sign_in_required" { account = nil }
            self.error = error.localizedDescription
        }
        recoveries = ExportRecoveryStore.records()
    }
    func signIn() {
        guard pairingTask == nil else { return }
        error = nil; isWorking = true
        pairingTask = Task {
            defer { isWorking = false; pairingTask = nil; pairing = nil }
            do {
                let pairing = try await client.startPairing()
                self.pairing = pairing
                if let url = URL(string: pairing.verificationUriComplete) { NSWorkspace.shared.open(url) }
                let deadline = Date().addingTimeInterval(Double(min(600, max(1, pairing.expiresIn))))
                while Date() < deadline {
                    try Task.checkCancellation()
                    if try await client.pollPairing(pairing) {
                        account = try await client.account(); return
                    }
                    try await Task.sleep(nanoseconds: UInt64(min(30, max(5, pairing.interval))) * 1_000_000_000)
                }
                throw SubscriptionServiceError(code: "code_expired", message: "This sign-in code expired. Please try again.")
            } catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func cancelSignIn() { pairingTask?.cancel() }
    func signOut() async {
        cancelSignIn()
        do { try await client.signOut(); account = nil; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func recover(_ record: ExportRecoveryRecord, to destination: URL) async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false; recoveries = ExportRecoveryStore.records() }
        do {
            try await ExportRecoveryStore.recover(record, authorizer: client, to: destination)
            error = nil
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            if ProductAccessPolicy.requiresExportAccount { account = try await client.account() }
        } catch { self.error = error.localizedDescription }
    }
    func openAccount() { NSWorkspace.shared.open(NativeSubscriptionClient.serviceURL.appendingPathComponent("account")) }
}
