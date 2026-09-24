import Combine
import FocusStudioAutomation
import Foundation

/// A program the person allowed to control Focus Studio over MCP.
struct ApprovedAutomationClient: Codable, Identifiable, Equatable, Sendable {
    var identity: AutomationClientIdentity
    /// What the MCP client called itself when it was approved ("Claude Code").
    var clientName: String
    var approvedAt: Date
    var lastUsedAt: Date?

    var id: String { identity.key }
}

/// A client the person declined; remembered in memory for a while so a
/// model that retries does not raise the prompt again and again.
struct DeclinedAutomationClient: Identifiable, Equatable, Sendable {
    var identity: AutomationClientIdentity
    var clientName: String
    var declinedAt: Date

    var id: String { identity.key }
}

/// Settings › AI tools: whether AI tools may control Focus Studio at all
/// (on by default) and the clients the person approved, kept in the app's
/// preferences. Declines are kept in memory only (``declineMemory``), so the
/// person can still approve such a client later.
@MainActor
final class AutomationAccessStore: ObservableObject {
    static let enabledKey = AutomationSwitch.preferenceKey
    static let approvedClientsKey = "automation.approvedClients.v1"
    /// How long a decline stops new prompts for that client.
    static let declineMemory: TimeInterval = 10 * 60
    /// lastUsedAt is written at most this often.
    static let usageResolution: TimeInterval = 60

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }
    @Published private(set) var approvedClients: [ApprovedAutomationClient]
    @Published private(set) var declinedClients: [DeclinedAutomationClient] = []

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        approvedClients = Self.loadApprovals(from: defaults)
    }

    func approval(for key: String) -> ApprovedAutomationClient? {
        approvedClients.first { $0.identity.key == key }
    }

    /// Remembers an approval; never for a client whose approval holds for
    /// one connection only (``AutomationClientIdentity/isRememberable``).
    func approve(_ identity: AutomationClientIdentity, clientName: String) {
        guard identity.isRememberable else { return }
        declinedClients.removeAll { $0.identity.key == identity.key }
        let approval = ApprovedAutomationClient(identity: identity, clientName: clientName, approvedAt: now(), lastUsedAt: nil)
        if let index = approvedClients.firstIndex(where: { $0.identity.key == identity.key }) {
            approvedClients[index] = approval
        } else {
            approvedClients.append(approval)
        }
        save()
    }

    func revoke(key: String) {
        approvedClients.removeAll { $0.identity.key == key }
        save()
    }

    func recordUse(key: String) {
        guard let index = approvedClients.firstIndex(where: { $0.identity.key == key }) else { return }
        let date = now()
        if let last = approvedClients[index].lastUsedAt, date.timeIntervalSince(last) < Self.usageResolution { return }
        approvedClients[index].lastUsedAt = date
        save()
    }

    func decline(_ identity: AutomationClientIdentity, clientName: String) {
        declinedClients.removeAll { $0.identity.key == identity.key }
        declinedClients.append(DeclinedAutomationClient(identity: identity, clientName: clientName, declinedAt: now()))
    }

    /// A decline still in effect for `key`.
    func decline(for key: String) -> DeclinedAutomationClient? {
        let date = now()
        declinedClients.removeAll { date.timeIntervalSince($0.declinedAt) >= Self.declineMemory }
        return declinedClients.first { $0.identity.key == key }
    }

    func forgetDecline(key: String) {
        declinedClients.removeAll { $0.identity.key == key }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(approvedClients) else { return }
        defaults.set(data, forKey: Self.approvedClientsKey)
    }

    /// The saved approvals, without any for a generic host that runs no
    /// script (a shell, node or python as such), which earlier versions
    /// could remember and which would approve everything that host runs.
    private static func loadApprovals(from defaults: UserDefaults) -> [ApprovedAutomationClient] {
        guard let data = defaults.data(forKey: approvedClientsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = (try? decoder.decode([ApprovedAutomationClient].self, from: data)) ?? []
        return saved.filter { $0.identity.isRememberable }
    }
}

/// What the approval prompt shows.
struct AutomationApprovalRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let identity: AutomationClientIdentity
    /// The MCP client's name, self-reported ("Claude Code").
    let clientName: String
    let clientVersion: String?
    /// The first tool it asked for.
    let toolName: String
    /// Whether an Allow is remembered; otherwise it holds until this AI
    /// tool disconnects (``AutomationClientIdentity/isRememberable``).
    var isRemembered: Bool { identity.isRememberable }
}

/// One helper connection's own approval, for a client whose approval is not
/// remembered (a generic host such as a shell): it holds until the
/// connection closes, and a decline likewise. Owned by the connection.
@MainActor
final class AutomationConnectionAccess {
    let id = UUID()
    fileprivate(set) var decision: Bool?

    init() {}
}

enum AutomationAccessDecision: Equatable, Sendable {
    case allowed
    /// An `isError` text for the model.
    case refused(String)
    /// The caller was cancelled while the prompt was up.
    case cancelled
}

/// Decides whether a call from an AI client may run: never while AI tools
/// are turned off; at once for an approved client; otherwise it asks the
/// person (one prompt per client, which later calls join) and waits up to
/// ``timeout``, relaying heartbeat progress so the client does not give up.
/// The prompt stays up after a call times out, and its answer is still
/// remembered. Nothing outside the app can answer it: the approver is the
/// app's own panel, and tests pass their own.
///
/// A client that cannot be remembered (a generic host with no script, see
/// ``AutomationClientIdentity/isRememberable``) is asked once per
/// connection, and the answer holds for that connection only.
///
/// ``refusalNow(identity:connection:tool:client:)`` checks again right
/// before a tool runs, since a call may wait its turn for minutes, during
/// which the person may turn AI tools off or revoke the client.
@MainActor
final class AutomationAccessController {
    typealias Approver = @MainActor (AutomationApprovalRequest) async -> Bool

    nonisolated static let defaultTimeout: TimeInterval = 120
    nonisolated static let defaultHeartbeatInterval: TimeInterval = 5
    /// Heartbeat progress while waiting: tiny increasing values, so the
    /// tool's own progress (fractions of its total) still reads as increasing.
    nonisolated static let heartbeatStep = 0.0001

    let store: AutomationAccessStore
    let timeout: TimeInterval
    let heartbeatInterval: TimeInterval
    private let approver: Approver
    private var pending: [String: PendingApproval] = [:]

    init(
        store: AutomationAccessStore,
        timeout: TimeInterval = defaultTimeout,
        heartbeatInterval: TimeInterval = defaultHeartbeatInterval,
        approver: @escaping Approver
    ) {
        self.store = store
        self.timeout = max(0, timeout)
        self.heartbeatInterval = max(0.01, heartbeatInterval)
        self.approver = approver
    }

    /// The prompts waiting for the person, one per client.
    var pendingRequests: [AutomationApprovalRequest] {
        pending.values.map(\.request).sorted { $0.identity.key < $1.identity.key }
    }

    func authorize(
        identity: AutomationClientIdentity?,
        client: ControlClientInfo?,
        tool: String,
        connection: AutomationConnectionAccess,
        progress: AIToolProgressHandler?
    ) async -> AutomationAccessDecision {
        guard store.isEnabled else { return .refused(Self.disabledMessage(tool: tool)) }
        guard let identity else { return .refused(Self.unidentifiedMessage(tool: tool)) }
        let name = client?.displayName ?? identity.programName
        let scope: String
        if identity.isRememberable {
            scope = identity.key
            if store.approval(for: identity.key) != nil {
                store.recordUse(key: identity.key)
                return .allowed
            }
            if store.decline(for: identity.key) != nil { return .refused(Self.declinedMessage(client: name, tool: tool)) }
        } else {
            scope = "\(identity.key)#connection:\(connection.id.uuidString)"
            switch connection.decision {
            case true?: return .allowed
            case false?: return .refused(Self.declinedMessage(client: name, tool: tool))
            case nil: break
            }
        }

        let prompt = pending[scope] ?? ask(AutomationApprovalRequest(identity: identity, clientName: name, clientVersion: client?.version, toolName: tool), scope: scope, connection: connection)
        switch await wait(for: prompt, client: name, progress: progress) {
        case .decided(true):
            // Turned off while the prompt was up.
            guard store.isEnabled else { return .refused(Self.disabledMessage(tool: tool)) }
            return .allowed
        case .decided(false):
            return .refused(Self.declinedMessage(client: name, tool: tool))
        case .timedOut:
            return .refused(Self.timeoutMessage(client: name, tool: tool, seconds: timeout))
        case .cancelled:
            return .cancelled
        }
    }

    /// Why a call that was allowed must not run after all, checked right
    /// before the tool runs (the call may have waited its turn meanwhile):
    /// AI tools turned off, or the client revoked. Nil when it may run.
    func refusalNow(identity: AutomationClientIdentity?, connection: AutomationConnectionAccess, tool: String, client: String) -> String? {
        guard store.isEnabled else { return Self.disabledMessage(tool: tool) }
        guard let identity else { return Self.unidentifiedMessage(tool: tool) }
        let allowed = identity.isRememberable ? store.approval(for: identity.key) != nil : connection.decision == true
        return allowed ? nil : Self.revokedMessage(client: client, tool: tool)
    }

    // MARK: - Prompts

    private func ask(_ request: AutomationApprovalRequest, scope: String, connection: AutomationConnectionAccess) -> PendingApproval {
        let prompt = PendingApproval(request: request, scope: scope, connection: request.isRemembered ? nil : connection)
        pending[scope] = prompt
        let approver = self.approver
        Task { @MainActor [weak self] in
            let allowed = await approver(request)
            self?.finish(prompt, allowed: allowed)
        }
        return prompt
    }

    private func finish(_ prompt: PendingApproval, allowed: Bool) {
        let request = prompt.request
        if request.isRemembered {
            if allowed {
                store.approve(request.identity, clientName: request.clientName)
            } else {
                store.decline(request.identity, clientName: request.clientName)
            }
        } else {
            // Holds for that connection only (nothing if it has closed).
            prompt.connection?.decision = allowed
        }
        if pending[prompt.scope] === prompt { pending[prompt.scope] = nil }
        prompt.resolve(allowed)
    }

    private enum WaitOutcome { case decided(Bool), timedOut, cancelled }

    private func wait(for prompt: PendingApproval, client: String, progress: AIToolProgressHandler?) async -> WaitOutcome {
        enum Event: Sendable { case decided(Bool?), timedOut, heartbeatStopped }
        let timeout = self.timeout
        let interval = heartbeatInterval
        let message = "Waiting for the person to allow \(client) in Focus Studio…"
        return await withTaskGroup(of: Event.self) { group in
            group.addTask { @MainActor in .decided(await prompt.wait()) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .timedOut
            }
            if let progress {
                group.addTask {
                    var beat = 1
                    progress(Double(beat) * Self.heartbeatStep, nil, message)
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(interval))
                        if Task.isCancelled { break }
                        beat += 1
                        progress(Double(beat) * Self.heartbeatStep, nil, message)
                    }
                    return .heartbeatStopped
                }
            }
            defer { group.cancelAll() }
            while let event = await group.next() {
                switch event {
                case let .decided(decision?):
                    return .decided(decision)
                case .decided(nil):
                    return .cancelled
                case .timedOut:
                    return Task.isCancelled ? .cancelled : .timedOut
                case .heartbeatStopped:
                    continue
                }
            }
            return .cancelled
        }
    }

    // MARK: - Messages for the model

    static func disabledMessage(tool: String) -> String {
        AutomationSwitch.disabledMessage(tool: tool)
    }

    static func unidentifiedMessage(tool: String) -> String {
        "Focus Studio could not identify the program that started focus-studio-mcp, so \(tool) did not run and nothing was changed. Start the Focus Studio MCP server from your MCP client (such as Claude Code or Codex) and try again."
    }

    static func revokedMessage(client: String, tool: String) -> String {
        "The person revoked \(client)'s access to Focus Studio, so \(tool) did not run and nothing was changed. Do not retry on your own; if the person wants you to use Focus Studio again, they will allow \(client) when Focus Studio asks."
    }

    static func declinedMessage(client: String, tool: String) -> String {
        "The person declined to let \(client) control Focus Studio, so \(tool) did not run and nothing was changed. Do not retry on your own; if the person changes their mind, they can allow \(client) in Focus Studio › Settings › AI tools."
    }

    static func timeoutMessage(client: String, tool: String, seconds: TimeInterval) -> String {
        let wait = seconds >= 1 ? "\(Int(seconds.rounded()))" : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        return "Focus Studio is asking the person whether \(client) may control it, and nobody answered within \(wait) seconds, so \(tool) did not run and nothing was changed. Ask the person to click Allow in the Focus Studio window that asks about \(client) (or to allow it in Focus Studio › Settings › AI tools), then call \(tool) again."
    }
}

/// One prompt on screen and the calls waiting for its answer.
@MainActor
private final class PendingApproval {
    let request: AutomationApprovalRequest
    /// The client's key, or for one that is not remembered its key and connection.
    let scope: String
    /// The connection the answer is for, when it is not remembered.
    weak var connection: AutomationConnectionAccess?
    private(set) var decision: Bool?
    private var waiters: [UUID: CheckedContinuation<Bool?, Never>] = [:]

    init(request: AutomationApprovalRequest, scope: String, connection: AutomationConnectionAccess?) {
        self.request = request
        self.scope = scope
        self.connection = connection
    }

    func resolve(_ allowed: Bool) {
        decision = allowed
        let waiting = waiters.values
        waiters.removeAll()
        waiting.forEach { $0.resume(returning: allowed) }
    }

    /// The person's answer, or nil when the waiting task was cancelled.
    func wait() async -> Bool? {
        if let decision { return decision }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
                if let decision {
                    continuation.resume(returning: decision)
                } else if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.withdraw(id) }
        }
    }

    private func withdraw(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: nil)
    }
}
