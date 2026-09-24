import Foundation

/// Runs automation calls as jobs so no call outlives a client's tool timeout
/// (Codex gives up after 300 s by default). A call still running after
/// ``detachAfter`` (counted from its arrival, time spent queued included)
/// answers at once with `{status: "running", job_id, tool, elapsed}` while
/// the work continues, and wait_for_job collects the result later. Results
/// of such detached jobs are kept for ``retention``, at most ``capacity`` of
/// them; a job that finishes in time is never stored.
@MainActor
public final class AutomationJobs {
    nonisolated public static let defaultDetachAfter: TimeInterval = 200
    nonisolated public static let defaultRetention: TimeInterval = 30 * 60
    nonisolated public static let defaultCapacity = 32
    /// wait_for_job's own limits, well inside Codex's 300-second timeout.
    nonisolated public static let defaultWait: TimeInterval = 120
    nonisolated public static let maximumWait: TimeInterval = 240

    public let detachAfter: TimeInterval
    public let retention: TimeInterval
    public let capacity: Int

    /// Detached jobs, running or finished, by id.
    private var detached: [String: Job] = [:]

    public init(
        detachAfter: TimeInterval = defaultDetachAfter,
        retention: TimeInterval = defaultRetention,
        capacity: Int = defaultCapacity
    ) {
        self.detachAfter = max(0, detachAfter)
        self.retention = max(0, retention)
        self.capacity = max(0, capacity)
    }

    /// Runs `work` as a job and returns its result once it finishes, or a
    /// running status when it is still busy after ``detachAfter``. `progress`
    /// gets the work's measured progress until this call returns. When the
    /// calling task is cancelled first, the work is cancelled and awaited
    /// (an export removes its partial file) and the result is `.cancelled`.
    ///
    /// `arrivedAt` is when the client's call arrived, if it waited for its
    /// turn before this: that wait counts toward ``detachAfter``, so a queued
    /// call answers in time as well. It still gets a short grace (a tenth of
    /// the threshold, at most a second) so a quick call that waited long
    /// answers with its result.
    public func run(
        tool: String,
        clientName: String? = nil,
        arrivedAt: Date? = nil,
        progress: AIToolProgressHandler?,
        _ work: @escaping @Sendable (_ progress: @escaping AIToolProgressHandler) async throws -> MCPToolCallResult
    ) async -> AutomationCallResult {
        prune()
        var budget = detachAfter
        if let arrivedAt {
            budget = max(min(1, detachAfter / 10), detachAfter - Date().timeIntervalSince(arrivedAt))
        }
        let job = Job(id: UUID().uuidString.lowercased(), tool: tool, clientName: clientName)
        let relay = job.progress
        let listener = relay.attach(progress)
        job.task = Task { [weak self] in
            let outcome: Job.Outcome
            do {
                outcome = .finished(try await work { relay.report($0, $1, $2) })
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .finished(.failure(error))
            }
            job.finish(outcome)
            self?.prune()
        }
        let finished = await job.outcome(within: budget)
        relay.detach(listener)
        if let finished { return result(of: finished, tool: tool) }
        if Task.isCancelled {
            job.task?.cancel()
            await job.task?.value
            return .cancelled
        }
        detached[job.id] = job
        return .result(runningStatus(of: job))
    }

    /// wait_for_job: waits up to `timeout_seconds` (default ``defaultWait``,
    /// at most ``maximumWait``) for a detached job and returns its result
    /// exactly as the original call would have, or the running status again.
    /// Cancelling the wait stops only the wait, never the job.
    public func waitForJob(arguments raw: [String: Any], progress: AIToolProgressHandler?) async -> AutomationCallResult {
        let arguments = AIToolArguments(raw)
        guard let id = arguments.string("job_id") else {
            return .result(.failure("Missing required argument \"job_id\" (from a result whose status is \"running\")."))
        }
        var timeout = Self.defaultWait
        if arguments.has("timeout_seconds") {
            guard let value = arguments.double("timeout_seconds"), (0...Self.maximumWait).contains(value) else {
                return .result(.failure("\"timeout_seconds\" must be a number of seconds from 0 to \(Int(Self.maximumWait)) (default \(Int(Self.defaultWait)))."))
            }
            timeout = value
        }
        prune()
        guard let job = detached[id.lowercased()] else {
            return .result(.failure("No job has the id \(id). A result is kept for \(Self.duration(retention)) after its job finishes, and jobs end when Focus Studio quits; run the original call again if you still need it."))
        }
        let listener = job.progress.attach(progress)
        defer { job.progress.detach(listener) }
        if let finished = await job.outcome(within: timeout) { return result(of: finished, tool: job.tool) }
        if Task.isCancelled { return .cancelled }
        return .result(runningStatus(of: job))
    }

    /// The detached jobs still running, oldest first.
    public var runningJobIDs: [String] {
        detached.values.filter { $0.finishedAt == nil }.sorted { $0.startedAt < $1.startedAt }.map(\.id)
    }

    // MARK: - Helpers

    private func result(of outcome: Job.Outcome, tool: String) -> AutomationCallResult {
        switch outcome {
        case let .finished(result):
            return .result(result)
        case .cancelled:
            // Cancelled by someone other than this caller (the app quitting).
            return Task.isCancelled ? .cancelled : .result(.failure("\(tool) was cancelled before it finished; nothing more will happen. Run it again if needed."))
        }
    }

    private func runningStatus(of job: Job) -> MCPToolCallResult {
        let elapsed = Date().timeIntervalSince(job.startedAt)
        let fraction = job.progress.latestFraction
        var text = "\(job.tool) is still running as job \(job.id) (\(AIToolSupport.seconds(elapsed)) s so far"
        if let fraction { text += ", \(Int((fraction * 100).rounded(.down)))% done" }
        text += "). Call wait_for_job with job_id \"\(job.id)\" to get its result."
        let data: AIJSONValue = [
            "status": "running",
            "job_id": AIJSONValue(job.id),
            "tool": AIJSONValue(job.tool),
            "elapsed": .rounded(elapsed, places: 1),
            "progress": fraction.map { .rounded($0) } ?? .null,
        ]
        return MCPToolCallResult(content: [.text(text)], structuredContent: data)
    }

    /// Drops finished results older than ``retention`` and, beyond
    /// ``capacity``, the oldest ones. Running jobs always stay.
    private func prune() {
        let now = Date()
        detached = detached.filter { _, job in
            guard let finishedAt = job.finishedAt else { return true }
            return now.timeIntervalSince(finishedAt) < retention
        }
        let finished = detached.values.compactMap { job in job.finishedAt.map { (job.id, $0) } }.sorted { $0.1 < $1.1 }
        for (id, _) in finished.dropLast(capacity) { detached[id] = nil }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        seconds >= 60 ? "\(Int((seconds / 60).rounded())) minutes" : "\(AIToolSupport.seconds(seconds)) s"
    }
}

// MARK: - Job

@MainActor
private final class Job {
    enum Outcome {
        case finished(MCPToolCallResult)
        case cancelled
    }

    let id: String
    let tool: String
    /// The MCP client that started it, as it named itself.
    let clientName: String?
    let startedAt = Date()
    let progress = AutomationProgressRelay()
    var task: Task<Void, Never>?
    private(set) var outcome: Outcome?
    private(set) var finishedAt: Date?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(id: String, tool: String, clientName: String?) {
        self.id = id
        self.tool = tool
        self.clientName = clientName
    }

    func finish(_ outcome: Outcome) {
        self.outcome = outcome
        finishedAt = Date()
        let pending = waiters.values
        waiters = [:]
        for waiter in pending { waiter.resume() }
    }

    /// The outcome once the job finishes, or nil when `seconds` pass or the
    /// waiting task is cancelled first. The job itself is left running.
    func outcome(within seconds: TimeInterval) async -> Outcome? {
        if let outcome { return outcome }
        let token = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            self?.resume(token)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if outcome != nil || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[token] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(token) }
        }
        timer.cancel()
        return outcome
    }

    private func resume(_ token: UUID) {
        waiters.removeValue(forKey: token)?.resume()
    }
}

/// Forwards a job's measured progress to whoever waits for it: the original
/// call until it returns, then each wait_for_job call. Every listener gets
/// strictly increasing values (MCP requires it), starting with the latest
/// report when it attaches. Reports may arrive on any thread; handlers are
/// called under a lock, in order, and must not call back into the relay.
final class AutomationProgressRelay: @unchecked Sendable {
    private struct Listener {
        let handler: AIToolProgressHandler
        var last: Double?
    }

    private let lock = NSLock()
    private var listeners: [UUID: Listener] = [:]
    private var latest: (completed: Double, total: Double?, message: String?)?

    func report(_ completed: Double, _ total: Double?, _ message: String?) {
        guard completed.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        latest = (completed, total, message)
        for (token, listener) in listeners where listener.last.map({ completed > $0 }) ?? true {
            listeners[token]?.last = completed
            listener.handler(completed, total, message)
        }
    }

    /// Adds a listener (nil adds none) and hands it the latest report.
    func attach(_ handler: AIToolProgressHandler?) -> UUID? {
        guard let handler else { return nil }
        let token = UUID()
        lock.lock()
        defer { lock.unlock() }
        listeners[token] = Listener(handler: handler, last: latest?.completed)
        if let latest { handler(latest.completed, latest.total, latest.message) }
        return token
    }

    func detach(_ token: UUID?) {
        guard let token else { return }
        lock.lock()
        listeners[token] = nil
        lock.unlock()
    }

    /// The latest report as a fraction of its total, when it has one.
    var latestFraction: Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest, let total = latest.total, total > 0 else { return nil }
        return min(1, max(0, latest.completed / total))
    }
}

// MARK: - One at a time

/// Lets calls through one at a time, in the order they arrive. The calls
/// that change what the app shows use it, so an MCP client's parallel calls
/// never open one project under another's edit. A caller cancelled while it
/// waits leaves the queue without taking a turn.
@MainActor
public final class AutomationCallQueue {
    private var isTaken = false
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    public init() {}

    /// Waits for this caller's turn; false when it was cancelled first. Every
    /// true must be followed by ``release()``.
    public func acquire() async -> Bool {
        guard isTaken else {
            isTaken = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.withdraw(id) }
        }
    }

    /// Ends the current turn and hands it to the next caller, if any.
    public func release() {
        if waiting.isEmpty {
            isTaken = false
        } else {
            waiting.removeFirst().continuation.resume(returning: true)
        }
    }

    /// Callers waiting for a turn.
    public var waitingCount: Int { waiting.count }

    private func withdraw(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }
}
