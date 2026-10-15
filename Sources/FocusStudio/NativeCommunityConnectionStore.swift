import AppKit
import Combine
import Foundation

@MainActor
final class NativeCommunityConnectionStore: ObservableObject {
    static let shared = NativeCommunityConnectionStore()
    enum Operation: Equatable { case idle, refreshing, starting, polling, confirming, disconnecting, cancelling }
    @Published private(set) var connection = CommunityConnectionSnapshot.disconnected
    @Published private(set) var operation: Operation = .idle
    @Published private(set) var error: String?
    private let client: NativeCommunityConnectionClient
    private let openURL: @MainActor (URL) -> Bool
    private var task: Task<Void, Never>?
    private var operationID = UUID()

    init(client: NativeCommunityConnectionClient = NativeCommunityConnectionClient(),
         openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.client = client; self.openURL = openURL
    }
    var isWorking: Bool { operation != .idle && operation != .polling }
    var isPairing: Bool { operation == .starting || operation == .polling || connection.pairing != nil }
    private func isCurrent(_ id: UUID) -> Bool { operationID == id && !Task.isCancelled }
    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        operation = .idle; task = nil
    }
    private func present(_ error: Error) {
        if error is CancellationError { return }
        self.error = (error as? CommunityConnectionError)?.message
            ?? "The community service is unavailable. Your local projects and exports are unaffected."
    }
    func refresh() {
        guard task == nil else { return }
        let id = UUID(); operationID = id; operation = .refreshing; error = nil
        task = Task {
            defer { finish(id) }
            do {
                let snapshot = try await client.restore()
                guard isCurrent(id) else { return }
                connection = snapshot
                if let pairing = snapshot.pairing { try await poll(pairing, id: id) }
            } catch {
                guard isCurrent(id) else { return }
                connection = await client.snapshot()
                guard isCurrent(id) else { return }
                present(error)
            }
        }
    }
    func connect() {
        guard task == nil, !connection.hasCredential, connection.pairing == nil else { return }
        let id = UUID(); operationID = id; operation = .starting; error = nil
        task = Task {
            defer { finish(id) }
            do {
                let pairing = try await client.startPairing()
                guard isCurrent(id) else { return }
                connection = await client.snapshot()
                guard isCurrent(id) else { return }
                if !openURL(pairing.verificationURL) {
                    error = "The sign-in page could not be opened. Reopen it or copy the code."
                }
                try await poll(pairing, id: id)
            } catch {
                guard isCurrent(id) else { return }
                connection = await client.snapshot()
                guard isCurrent(id) else { return }
                present(error)
            }
        }
    }
    private func poll(_ pairing: CommunityConnectionPairing, id: UUID) async throws {
        guard isCurrent(id) else { throw CancellationError() }
        operation = .polling
        while isCurrent(id) {
            if let snapshot = try await client.pollPairing(pairing) {
                guard isCurrent(id) else { throw CancellationError() }
                connection = snapshot; error = nil
                // Pairing only establishes identity. Activation is a separate,
                // explicit user action, including after restarting the app.
                return
            }
            try await Task.sleep(nanoseconds: UInt64(pairing.interval) * 1_000_000_000)
        }
        throw CancellationError()
    }
    func reopenBrowser() {
        guard let pairing = connection.pairing else { return }
        if openURL(pairing.verificationURL) { error = nil }
        else { error = "The sign-in page could not be opened. Reopen it or copy the code." }
    }
    func cancel() {
        guard isPairing else { return }
        operationID = UUID(); let id = operationID
        task?.cancel(); operation = .cancelling; error = nil
        task = Task {
            defer { finish(id) }
            do {
                try await client.cancelPairing()
                guard isCurrent(id) else { return }
                connection = .disconnected
            } catch {
                guard isCurrent(id) else { return }
                connection = await client.snapshot()
                guard isCurrent(id) else { return }
                present(error)
            }
        }
    }
    func confirmClient() {
        guard task == nil, connection.hasCredential, connection.identity != nil, !connection.clientConfirmed else { return }
        let id = UUID(); operationID = id; operation = .confirming; error = nil
        task = Task {
            defer { finish(id) }
            do {
                let snapshot = try await client.confirmClient()
                guard isCurrent(id) else { return }
                connection = snapshot
            } catch {
                guard isCurrent(id) else { return }
                connection = await client.snapshot()
                guard isCurrent(id) else { return }
                present(error)
            }
        }
    }
    func disconnect() {
        guard task == nil, connection.hasCredential else { return }
        let id = UUID(); operationID = id; operation = .disconnecting; error = nil
        task = Task {
            defer { finish(id) }
            do {
                try await client.disconnect()
                guard isCurrent(id) else { return }
                connection = .disconnected
            } catch {
                guard isCurrent(id) else { return }
                connection = await client.snapshot()
                guard isCurrent(id) else { return }
                present(error)
            }
        }
    }
    func openCommunity() {
        if !openURL(NativeCommunityConnectionClient.serviceURL.appendingPathComponent("community")) {
            error = "The community page could not be opened. Please try again."
        }
    }
}
