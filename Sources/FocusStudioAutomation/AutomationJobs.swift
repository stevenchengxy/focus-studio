import Foundation

/// Runs automation calls as jobs so no call outlives a client's tool timeout
/// (Codex gives up after 300 s by default). A call still running after
/// ``detachAfter`` answers at once with `{status: "running", job_id, tool,
/// elapsed}` (and `activity`, what a job without measured progress waits
/// for) while the work continues, and wait_for_job collects the result
/// later. The threshold counts from when the call reached the app, less the
/// time focus-studio-mcp had already spent on it (opening the app,
/// connecting), so the approval prompt, a wait for a turn and a prompt
/// inside the tool (start_recording's sound prompt) all count. Results of
/// such detached jobs are kept for ``retention``, at most ``capacity`` of
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

    /// The short grace a call gets past ``detachAfter`` when it reaches its
    /// tool late (a tenth of the threshold, at most a second), so a quick
    /// call that waited long still answers with its result.
    public var grace: TimeInterval { min(1, detachAfter / 10) }

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
    /// `arrivedAt` is when the client's call started counting (see the type's
    /// description), if it waited before this (for approval, for its turn):
    /// that wait counts toward ``detachAfter``, so such a call answers in
    /// time as well. It still gets a short grace (a tenth of the threshold,
    /// at most a second) so a quick call that waited long answers with its
    /// result.
    ///
    /// With `detaches` false the call is never detached: it answers when the
    /// work does, for work that bounds its own time (wait_for_recording).
    public func run(
        tool: String,
        clientName: String? = nil,
        arrivedAt: Date? = nil,
        detaches: Bool = true,
        progress: AIToolProgressHandler?,
        _ work: @escaping @Sendable (_ progress: @escaping AIToolProgressHandler) async throws -> MCPToolCallResult
    ) async -> AutomationCallResult {
        prune()
        var budget: TimeInterval? = detachAfter
        if let arrivedAt {
            budget = max(grace, detachAfter - Date().timeIntervalSince(arrivedAt))
        }
        if !detaches { budget = nil }
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
    /// With `arrivedAt` (when the call's time started, before any wait for
    /// approval) the wait ends at most ``maximumWait`` after it. Cancelling
    /// the wait stops only the wait, never the job.
    public func waitForJob(arguments raw: [String: Any], arrivedAt: Date? = nil, progress: AIToolProgressHandler?) async -> AutomationCallResult {
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
        if let arrivedAt {
            timeout = min(timeout, max(0, Self.maximumWait - Date().timeIntervalSince(arrivedAt)))
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

    /// Cancels every detached job still running (the app is quitting) and
    /// returns their tasks, so the caller can wait for their cleanup (an
    /// export removes its partial file).
    public func cancelRunning() -> [Task<Void, Never>] {
        detached.values.filter { $0.finishedAt == nil }.compactMap { job in
            job.task?.cancel()
            return job.task
        }
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
        // What a job without measured progress is waiting for, such as the
        // person's answer to start_recording's sound prompt.
        let waitingFor = fraction == nil ? job.progress.latestMessage.map(Self.sentence) : nil
        var text = "\(job.tool) is still running as job \(job.id) (\(AIToolSupport.seconds(elapsed)) s so far"
        if let fraction { text += ", \(Int((fraction * 100).rounded(.down)))% done" }
        text += ")"
        if let waitingFor { text += ": \(waitingFor)" }
        text += ". Call wait_for_job with job_id \"\(job.id)\" to get its result."
        var data: [String: AIJSONValue] = [
            "status": "running",
            "job_id": AIJSONValue(job.id),
            "tool": AIJSONValue(job.tool),
            "elapsed": .rounded(elapsed, places: 1),
            "progress": fraction.map { .rounded($0) } ?? .null,
        ]
        if let waitingFor { data["activity"] = AIJSONValue(waitingFor) }
        return MCPToolCallResult(content: [.text(text)], structuredContent: .object(data))
    }

    /// A progress message as part of a sentence: without its trailing
    /// ellipsis or full stop, and starting in lower case.
    private static func sentence(_ message: String) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, last == "…" || last == "." { text.removeLast() }
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
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

    /// The outcome once the job finishes, or nil when `seconds` pass (never,
    /// for nil) or the waiting task is cancelled first. The job itself is
    /// left running.
    func outcome(within seconds: TimeInterval?) async -> Outcome? {
        if let outcome { return outcome }
        let token = UUID()
        let timer = seconds.map { seconds in
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                self?.resume(token)
            }
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
        timer?.cancel()
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

    /// The latest report's message, if it had one.
    var latestMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let message = latest?.message, !message.isEmpty else { return nil }
        return message
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
/// waits, or whose deadline passes first, leaves the queue without taking a
/// turn.
@MainActor
public final class AutomationCallQueue {
    /// How a wait for a turn ended.
    public enum AcquireOutcome: Equatable, Sendable {
        /// The caller has the turn; ``release()`` must follow.
        case acquired
        /// The caller was cancelled first.
        case cancelled
        /// The deadline passed first.
        case timedOut
    }

    private var isTaken = false
    private var waiting: [(id: UUID, continuation: CheckedContinuation<AcquireOutcome, Never>)] = []

    public init() {}

    /// Waits for this caller's turn; false when it was cancelled first. Every
    /// true must be followed by ``release()``.
    public func acquire() async -> Bool {
        await acquire(until: nil) == .acquired
    }

    /// Waits for this caller's turn, at most until `deadline` (nil: no
    /// limit). Every ``AcquireOutcome/acquired`` must be followed by
    /// ``release()``; the other outcomes hold no turn.
    public func acquire(until deadline: Date?) async -> AcquireOutcome {
        guard isTaken else {
            isTaken = true
            return .acquired
        }
        if let deadline, deadline <= Date() { return .timedOut }
        let id = UUID()
        let timer = deadline.map { deadline in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                self?.leave(id, .timedOut)
            }
        }
        defer { timer?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AcquireOutcome, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.leave(id, .cancelled) }
        }
    }

    /// Ends the current turn and hands it to the next caller, if any.
    public func release() {
        if waiting.isEmpty {
            isTaken = false
        } else {
            waiting.removeFirst().continuation.resume(returning: .acquired)
        }
    }

    /// Whether a caller has the turn now, so the next one would wait.
    public var isBusy: Bool { isTaken }

    /// Callers waiting for a turn.
    public var waitingCount: Int { waiting.count }

    /// Takes a caller that is still waiting out of the queue.
    private func leave(_ id: UUID, _ outcome: AcquireOutcome) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: outcome)
    }
}
