import Darwin
import FocusStudioAutomation
import Foundation

/// Carries tool calls to Focus Studio.app over the control channel
/// (``ControlChannel``: a Unix domain socket, JSON-RPC 2.0 one message per
/// line) and brings back what the app answered.
///
/// - **Lazily connected.** Nothing happens until the first `tools/call`
///   (`initialize` and `tools/list` never reach the app). The first call
///   connects and sends `hello`; later calls share the connection.
/// - **Opens the app when it is not running** (nothing listens on the
///   socket: ENOENT or ECONNREFUSED): through LaunchServices in the
///   background (``AppLaunching``), then tries to connect every
///   ``AppConnectionSettings/pollInterval`` for up to
///   ``AppConnectionSettings/launchTimeout``. With
///   `FOCUS_STUDIO_MCP_NO_LAUNCH=1` it answers that Focus Studio could not
///   be reached instead. Calls arriving meanwhile wait for the same attempt.
///   It does not open the app while "Allow AI tools to control Focus Studio"
///   is off (the app would only refuse the call), nor while another copy of
///   Focus Studio runs: it waits for that copy to listen instead, since two
///   copies would edit the same library.
/// - **Ready means loaded.** The app answers `hello` once its library has
///   loaded. A reply with another protocol version is an `isError` naming the
///   copy that is running.
/// - **Progress.** While a call waits for the app to start or load, it
///   reports tiny increasing heartbeat values (when its request carried a
///   progress token), so clients with an idle timeout keep waiting; the app's
///   own progress for the call follows.
/// - **Time.** Each call carries the seconds since its `tools/call` reached
///   the helper (`elapsed`: opening the app, connecting), which the app
///   counts toward the moment a long call answers with a job, so the first
///   call of a session also answers within the client's tool timeout.
/// - **Cancellation** (the client's, or the helper shutting down) sends
///   `cancel` for the call; the app answers it as cancelled.
/// - **The app quitting mid-call** ends each running call with an `isError`
///   saying so; the call is not retried (it may have changed something).
///   The next call connects again, opening the app again if needed.
final class SocketAppForwarder: AppForwarding, @unchecked Sendable {
    /// Heartbeat progress while waiting for the app: this much per beat, at
    /// most ``maximumHeartbeats`` beats. The app's own heartbeats while it
    /// asks the person to approve a client start at 0.0001, and progress must
    /// keep increasing, so the helper's stay below that.
    static let heartbeatStep = 0.000_001
    static let maximumHeartbeats = 90

    let settings: AppConnectionSettings
    let helperVersion: String
    /// This executable, named when the app speaks another protocol.
    let helperPath: String?
    let launcher: any AppLaunching
    let log: HelperLog

    private let lock = NSLock()
    private var link: AppLink?
    private var attempt: ConnectAttempt?
    private var isShutDown = false

    init(settings: AppConnectionSettings, helperVersion: String, helperPath: String?, launcher: any AppLaunching, log: HelperLog) {
        self.settings = settings
        self.helperVersion = helperVersion
        self.helperPath = helperPath
        self.launcher = launcher
        self.log = log
    }

    func forward(_ call: ForwardedToolCall) async -> AutomationCallResult {
        // A call that never left the helper (the connection closed just
        // before it was written) is safe to send again, once.
        for _ in 0..<2 {
            switch await readyLink(for: call) {
            case .cancelled:
                return .cancelled
            case let .failed(failure):
                log.warning("tools/call #\(call.sequence) \(call.toolName): \(failure)")
                return .result(.failure(failure.message(for: call.toolName, context: failureContext)))
            case let .ready(link):
                switch await link.call(call, cancelReplyTimeout: settings.cancelReplyTimeout) {
                case let .answered(result):
                    return result
                case .notSent:
                    log.debug("tools/call #\(call.sequence) \(call.toolName): the connection closed before the call was sent; connecting again")
                    linkClosed(link)
                }
            }
        }
        return .result(.failure(ConnectFailure.connectionLost.message(for: call.toolName, context: failureContext)))
    }

    func shutdown() async {
        let (link, attempt) = lock.withLock { () -> (AppLink?, ConnectAttempt?) in
            isShutDown = true
            defer {
                self.link = nil
                self.attempt = nil
            }
            return (self.link, self.attempt)
        }
        attempt?.cancel()
        // The cancel messages for the calls the router just cancelled go out first.
        link?.closeAfterPendingWrites()
    }

    /// Whether a connection to the app is open and ready; for tests.
    var isConnected: Bool { lock.withLock { link?.isUsable ?? false } }

    // MARK: - Connecting

    enum LinkOutcome: Sendable {
        case ready(AppLink)
        case failed(ConnectFailure)
        case cancelled
    }

    private var failureContext: ConnectFailure.Context {
        var socketOverrideIgnoredByApp = false
        if case let .success(location) = settings.socket, location.source == .environment {
            socketOverrideIgnoredByApp = settings.launchEnvironment[ControlChannel.socketPathVariable] == nil
        }
        return ConnectFailure.Context(
            helperVersion: helperVersion,
            helperPath: helperPath,
            launchTimeout: settings.launchTimeout,
            helloTimeout: settings.helloTimeout,
            socketOverrideIgnoredByApp: socketOverrideIgnoredByApp
        )
    }

    /// The open, greeted connection, or the attempt to make one that this
    /// call joins.
    private func readyLink(for call: ForwardedToolCall) async -> LinkOutcome {
        if Task.isCancelled { return .cancelled }
        enum Next { case outcome(LinkOutcome), wait(ConnectAttempt) }
        let next = lock.withLock { () -> Next in
            if isShutDown { return .outcome(.cancelled) }
            if let link {
                if link.isUsable { return .outcome(.ready(link)) }
                self.link = nil
            }
            if let attempt { return .wait(attempt) }
            let hello = ControlHello(
                helperVersion: helperVersion,
                client: call.client.map { ControlClientInfo(name: $0.name, version: $0.version, title: $0.title) },
                workingDirectory: call.workingDirectory.path
            )
            let attempt = ConnectAttempt(heartbeatInterval: settings.heartbeatInterval)
            self.attempt = attempt
            attempt.start { [self] in await establish(attempt, hello: hello) } finished: { [self] result in
                attemptFinished(attempt, result)
            }
            return .wait(attempt)
        }
        switch next {
        case let .outcome(outcome): return outcome
        case let .wait(attempt): return await attempt.wait(progress: call.progress)
        }
    }

    /// Keeps a new link, or closes it when the helper is shutting down; runs
    /// before the waiting calls resume.
    private func attemptFinished(_ attempt: ConnectAttempt, _ result: Result<AppLink, ConnectFailure>) -> LinkOutcome {
        let closeNow = lock.withLock { () -> AppLink? in
            if self.attempt === attempt { self.attempt = nil }
            guard case let .success(link) = result else { return nil }
            if isShutDown { return link }
            self.link = link
            return nil
        }
        if let closeNow {
            closeNow.close()
            return .cancelled
        }
        switch result {
        case let .success(link): return .ready(link)
        case .failure(.shuttingDown): return .cancelled
        case let .failure(failure): return .failed(failure)
        }
    }

    private func linkClosed(_ link: AppLink) {
        lock.withLock {
            if self.link === link { self.link = nil }
        }
    }

    /// Connects (opening the app if needed) and greets it.
    private func establish(_ attempt: ConnectAttempt, hello: ControlHello) async -> Result<AppLink, ConnectFailure> {
        let location: ControlSocketLocation
        switch settings.socket {
        case let .success(found): location = found
        case let .failure(error): return .failure(.socketUnusable(error.errorDescription ?? "\(error)"))
        }
        let descriptor: Int32
        switch await connect(to: location, attempt: attempt) {
        case let .success(connected): descriptor = connected
        case let .failure(failure): return .failure(failure)
        }
        let link = AppLink(fileDescriptor: descriptor, log: log) { [weak self] link in
            self?.linkClosed(link)
        }
        link.start()
        attempt.setStatus("Waiting for Focus Studio to load its library…")
        log.debug("Connected to \(location.path); sending hello")
        switch await link.hello(hello, timeout: settings.helloTimeout) {
        case let .reply(reply):
            guard reply.protocolVersion == ControlChannel.protocolVersion else {
                link.close()
                return .failure(.protocolMismatch(appPath: reply.appPath, appVersion: reply.appVersion, appProtocol: reply.protocolVersion))
            }
            log.debug("Focus Studio \(reply.appVersion) at \(reply.appPath) (pid \(reply.pid)) is ready")
            return .success(link)
        case let .refused(message):
            link.close()
            return .failure(.helloRefused(message))
        case .timedOut:
            link.close()
            return .failure(.helloTimedOut)
        case .connectionLost:
            link.close()
            return .failure(.connectionLost)
        case .cancelled:
            link.close()
            return .failure(.shuttingDown)
        }
    }

    /// A connected descriptor. When nothing listens it opens the app (unless
    /// told not to, or AI tools are turned off in it) and keeps trying until
    /// the app listens, the system refuses to open it, or the launch timeout
    /// passes; while another copy of Focus Studio runs, it only waits for that
    /// copy to listen.
    private func connect(to location: ControlSocketLocation, attempt: ConnectAttempt) async -> Result<Int32, ConnectFailure> {
        /// What the helper waits for while nothing listens yet.
        enum Waiting {
            case launch(PendingLaunch)
            /// Another copy of Focus Studio runs (maybe still starting): the
            /// helper never opens a second copy on the same library.
            case otherCopy(URL, deadline: Date)
        }
        var waiting: Waiting?
        while true {
            if Task.isCancelled { return .failure(.shuttingDown) }
            do {
                let descriptor = try ControlSocket.connect(to: location.path)
                if case let .launch(launch)? = waiting { log.info("Focus Studio at \(launch.appURL.path) is accepting AI tools") }
                return .success(descriptor)
            } catch let error as ControlSocketError where error.meansNoListener {
                if waiting == nil {
                    switch settings.launch {
                    case .disabled:
                        return .failure(.notRunning)
                    case let .unavailable(reason):
                        return .failure(.noAppToLaunch(reason))
                    case let .app(appURL):
                        // Turned off in Settings: opening the app would only get the call refused.
                        guard settings.isAutomationEnabled() else { return .failure(.disabledInApp) }
                        let wasRunning = launcher.isRunning(appAt: appURL)
                        if !wasRunning, let other = launcher.otherRunningCopies(than: appURL).first {
                            log.info("Another copy of Focus Studio runs at \(other.path) and does not listen on \(location.path) yet; waiting for it instead of opening \(appURL.path)")
                            attempt.setStatus("Waiting for Focus Studio to accept AI tools…", beat: true)
                            waiting = .otherCopy(other, deadline: Date().addingTimeInterval(settings.launchTimeout))
                        } else {
                            log.info(wasRunning
                                     ? "Focus Studio at \(appURL.path) runs but does not listen on \(location.path) yet; waiting"
                                     : "Opening Focus Studio at \(appURL.path) in the background")
                            attempt.setStatus(wasRunning ? "Waiting for Focus Studio to accept AI tools…" : "Opening Focus Studio in the background…", beat: true)
                            waiting = .launch(PendingLaunch(appURL: appURL, wasRunning: wasRunning, deadline: Date().addingTimeInterval(settings.launchTimeout),
                                                            launcher: launcher, environment: settings.launchEnvironment))
                        }
                    }
                }
                switch waiting {
                case nil:
                    return .failure(.notRunning)
                case let .otherCopy(other, deadline):
                    if Date() >= deadline {
                        let version = Bundle(url: other)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                        return .failure(.otherCopyRunning(app: other.path, version: version ?? "unknown"))
                    }
                case let .launch(launch):
                    if let refusal = launch.refusal {
                        return .failure(.launchFailed(app: launch.appURL.path, reason: refusal))
                    }
                    if Date() >= launch.deadline {
                        return .failure(.didNotStart(app: launch.appURL.path, wasRunning: launch.wasRunning, launchPending: !launch.isFinished, socket: location.path))
                    }
                }
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0.01, settings.pollInterval) * 1_000_000_000))
                } catch {
                    return .failure(.shuttingDown)
                }
            } catch {
                return .failure(.unreachable(socket: location.path, reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
            }
        }
    }
}

// MARK: - Failures

/// Why a call could not reach the app; each becomes an `isError` result the
/// model can act on.
enum ConnectFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// Nothing listens and the helper may not open the app.
    case notRunning
    /// Nothing listens and there is no app to open.
    case noAppToLaunch(String)
    /// The system refused to open the app.
    case launchFailed(app: String, reason: String)
    /// Opened (or already running), but it did not listen in time.
    case didNotStart(app: String, wasRunning: Bool, launchPending: Bool, socket: String)
    /// Nothing listens, and "Allow AI tools to control Focus Studio" is off:
    /// the app is not opened.
    case disabledInApp
    /// Nothing listens, and another copy of Focus Studio runs (not the one
    /// this helper opens); it did not start listening in time.
    case otherCopyRunning(app: String, version: String)
    /// Connecting failed for another reason than nobody listening.
    case unreachable(socket: String, reason: String)
    /// No usable socket path (a bad `FOCUS_STUDIO_CONTROL_SOCKET`).
    case socketUnusable(String)
    case helloRefused(String)
    case helloTimedOut
    case protocolMismatch(appPath: String, appVersion: String, appProtocol: Int)
    /// The connection closed before the app was ready, or before the call could be sent.
    case connectionLost
    case shuttingDown

    struct Context: Sendable {
        var helperVersion: String
        var helperPath: String?
        var launchTimeout: TimeInterval
        var helloTimeout: TimeInterval
        /// The helper uses `FOCUS_STUDIO_CONTROL_SOCKET`, which an app it
        /// opens does not get.
        var socketOverrideIgnoredByApp: Bool
    }

    var description: String {
        switch self {
        case .notRunning: return "not running (launching disabled)"
        case let .noAppToLaunch(reason): return "no app to open: \(reason)"
        case let .launchFailed(app, reason): return "could not open \(app): \(reason)"
        case let .didNotStart(app, wasRunning, pending, socket): return "\(app) (\(wasRunning ? "already running" : "opened"), launch \(pending ? "pending" : "done")) did not listen on \(socket)"
        case .disabledInApp: return "AI tools turned off in Focus Studio; not opened"
        case let .otherCopyRunning(app, version): return "another copy (\(app), version \(version)) runs but does not listen; not opening a second copy"
        case let .unreachable(socket, reason): return "\(socket) unreachable: \(reason)"
        case let .socketUnusable(reason): return "no socket path: \(reason)"
        case let .helloRefused(message): return "hello refused: \(message)"
        case .helloTimedOut: return "hello timed out"
        case let .protocolMismatch(path, version, number): return "\(path) \(version) speaks protocol \(number)"
        case .connectionLost: return "connection lost"
        case .shuttingDown: return "shutting down"
        }
    }

    /// "30 seconds", or "0.5 seconds" for the short timeouts of tests.
    static func seconds(_ interval: TimeInterval) -> String {
        interval >= 1 ? "\(Int(interval.rounded())) seconds" : String(format: "%.1f seconds", interval)
    }

    func message(for tool: String, context: Context) -> String {
        let nothing = "so \(tool) did not run and nothing was changed."
        switch self {
        case .notRunning:
            return UnreachableAppForwarder.message(for: tool)
        case let .noAppToLaunch(reason):
            return "Focus Studio is not running, \(nothing) \(reason) Ask the person to open Focus Studio, then try again."
        case let .launchFailed(app, reason):
            return "Focus Studio is not running and macOS could not open it (\(reason)), \(nothing) Ask the person to open Focus Studio (\(app)), then try again."
        case let .didNotStart(app, wasRunning, launchPending, socket):
            var text: String
            if wasRunning {
                text = "Focus Studio is running but is not accepting AI tools, \(nothing) Another copy of Focus Studio may be serving AI tools, or it could not set up its connection for them. Ask the person to check Focus Studio › Settings › AI tools, then try again."
            } else {
                text = "Focus Studio (\(app)) was opened in the background but did not start accepting AI tools within \(Self.seconds(context.launchTimeout)), \(nothing)"
                if launchPending { text += " macOS may be asking the person whether to open it." }
                text += " Ask the person to check Focus Studio, then try again."
            }
            if context.socketOverrideIgnoredByApp {
                text += " This focus-studio-mcp connects to \(socket) (set by \(ControlChannel.socketPathVariable)), where a Focus Studio it opens does not listen."
            }
            return text
        case .disabledInApp:
            return AutomationSwitch.disabledMessage(tool: tool)
        case let .otherCopyRunning(app, version):
            return "Another copy of Focus Studio (\(app), version \(version)) is running but is not accepting AI tools, \(nothing) focus-studio-mcp does not open a second copy, because both would edit the same library. Ask the person to quit that copy of Focus Studio (or to update it), then try again."
        case let .unreachable(socket, reason):
            return "Focus Studio could not be reached at \(socket) (\(reason)), \(nothing)"
        case let .socketUnusable(reason):
            return "Focus Studio could not be reached, \(nothing) \(reason)"
        case let .helloRefused(message):
            return "Focus Studio refused the connection (\(message)), \(nothing)"
        case .helloTimedOut:
            return "Focus Studio accepted the connection but was not ready within \(Self.seconds(context.helloTimeout)), \(nothing) It may be busy or waiting for the person; ask them to check Focus Studio, then try again."
        case let .protocolMismatch(appPath, appVersion, appProtocol):
            let helper = context.helperPath.map { " at \($0)" } ?? ""
            return "The Focus Studio that is running (\(appPath), version \(appVersion)) speaks control protocol \(appProtocol), but this focus-studio-mcp (version \(context.helperVersion)\(helper)) speaks protocol \(ControlChannel.protocolVersion), \(nothing) Ask the person to quit that copy of Focus Studio, or to connect this AI tool to the focus-studio-mcp of the copy they use (Focus Studio › Settings › AI tools), then try again."
        case .connectionLost:
            return "The connection to Focus Studio closed before \(tool) could be sent, so it did not run and nothing was changed. Try again."
        case .shuttingDown:
            return ToolCallRouter.shutdownMessage(for: tool)
        }
    }
}

// MARK: - Launching

/// The app being opened: the system's answer arrives in the background
/// while the helper keeps trying to connect.
private final class PendingLaunch: @unchecked Sendable {
    let appURL: URL
    let wasRunning: Bool
    let deadline: Date
    private let lock = NSLock()
    private var finished = false
    private var refusalText: String?

    init(appURL: URL, wasRunning: Bool, deadline: Date, launcher: any AppLaunching, environment: [String: String]) {
        self.appURL = appURL
        self.wasRunning = wasRunning
        self.deadline = deadline
        Task.detached { [self] in
            var refusal: String?
            do {
                try await launcher.launch(appAt: appURL, environment: environment)
            } catch {
                refusal = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            lock.withLock {
                finished = true
                refusalText = refusal
            }
        }
    }

    /// Whether the system has answered.
    var isFinished: Bool { lock.withLock { finished } }
    /// Why the system refused to open the app; nil while pending or when it did.
    var refusal: String? { lock.withLock { refusalText } }
}

// MARK: - Connect attempts

/// One attempt to connect and greet the app, which every call arriving
/// meanwhile waits for. A waiting call that is cancelled stops waiting; the
/// attempt carries on for the others (and the next call). Waiting calls get
/// heartbeat progress.
final class ConnectAttempt: @unchecked Sendable {
    private struct Waiter {
        let continuation: CheckedContinuation<SocketAppForwarder.LinkOutcome, Never>
        let progress: AIToolProgressHandler?
    }

    private let heartbeatInterval: TimeInterval
    private let lock = NSLock()
    private var waiters: [UUID: Waiter] = [:]
    private var outcome: SocketAppForwarder.LinkOutcome?
    private var status = "Connecting to Focus Studio…"
    private var beats = 0
    private var work: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?

    init(heartbeatInterval: TimeInterval) {
        self.heartbeatInterval = max(0.01, heartbeatInterval)
    }

    /// Runs `body`, then `finished` (which turns its result into what the
    /// waiting calls get), then resumes them.
    func start(
        _ body: @escaping @Sendable () async -> Result<AppLink, ConnectFailure>,
        finished: @escaping @Sendable (Result<AppLink, ConnectFailure>) -> SocketAppForwarder.LinkOutcome
    ) {
        let interval = heartbeatInterval
        let heartbeat = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.beat()
            }
        }
        let work = Task.detached { [self] in
            let result = await body()
            heartbeat.cancel()
            finish(finished(result))
        }
        lock.withLock {
            self.heartbeat = heartbeat
            self.work = work
        }
    }

    func cancel() {
        let (work, heartbeat) = lock.withLock { (self.work, self.heartbeat) }
        work?.cancel()
        heartbeat?.cancel()
    }

    /// Waits for the attempt; `.cancelled` at once when the calling task is cancelled.
    func wait(progress: AIToolProgressHandler?) async -> SocketAppForwarder.LinkOutcome {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SocketAppForwarder.LinkOutcome, Never>) in
                let immediate = lock.withLock { () -> SocketAppForwarder.LinkOutcome? in
                    if let outcome { return outcome }
                    // Checked under the lock the cancellation handler takes,
                    // so a cancellation is seen here or finds the waiter.
                    if Task.isCancelled { return .cancelled }
                    waiters[id] = Waiter(continuation: continuation, progress: progress)
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(returning: .cancelled)
        }
    }

    /// What the waiting calls' progress says from now on; with `beat`, one
    /// heartbeat goes out right away.
    func setStatus(_ text: String, beat now: Bool = false) {
        lock.withLock { status = text }
        if now { beat() }
    }

    /// One heartbeat to every waiting call that asked for progress.
    private func beat() {
        let deliveries = lock.withLock { () -> [(AIToolProgressHandler, Double, String)] in
            guard outcome == nil, beats < SocketAppForwarder.maximumHeartbeats else { return [] }
            beats += 1
            let value = Double(beats) * SocketAppForwarder.heartbeatStep
            return waiters.values.compactMap { waiter in waiter.progress.map { ($0, value, status) } }
        }
        for (handler, value, message) in deliveries {
            handler(value, nil, message)
        }
    }

    private func finish(_ result: SocketAppForwarder.LinkOutcome) {
        let waiting = lock.withLock { () -> [Waiter] in
            outcome = result
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for waiter in waiting {
            waiter.continuation.resume(returning: result)
        }
    }
}

// MARK: - The connection

/// One connection to the app: request/response matching by id, progress
/// routed to the call it belongs to, cancellation, and what closing means
/// for the requests still waiting.
final class AppLink: @unchecked Sendable {
    /// What became of one request.
    enum Reply: Sendable {
        case message(ControlMessage)
        /// The connection closed while the request waited.
        case closed(ControlConnection.CloseReason)
        /// The connection was already closed: the request never left the helper.
        case notSent
        case timedOut
        /// The calling task was cancelled: for a call, the app was told and
        /// did not answer in time; for hello, the request was given up.
        case cancelled
    }

    enum HelloOutcome: Sendable {
        case reply(ControlHelloReply)
        case refused(String)
        case timedOut
        case connectionLost
        case cancelled
    }

    enum CallOutcome: Sendable {
        case answered(AutomationCallResult)
        /// The request was never written; safe to send on a new connection.
        case notSent
    }

    private enum Entry {
        /// The id is handed out; the request is not registered yet.
        case allocated
        /// Cancelled before it was registered: never sent.
        case cancelledEarly
        case waiting(CheckedContinuation<Reply, Never>, AIToolProgressHandler?)
    }

    /// What cancelling a waiting request does.
    private enum CancelAction {
        /// Tell the app (`cancel`) and wait up to this long for its answer.
        case tellApp(TimeInterval)
        /// Stop waiting at once.
        case abandon
    }

    let connection: ControlConnection
    private let log: HelperLog
    private let onClose: @Sendable (AppLink) -> Void
    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private var lastID = 0
    private var closeReason: ControlConnection.CloseReason?

    init(fileDescriptor: Int32, log: HelperLog, onClose: @escaping @Sendable (AppLink) -> Void) {
        connection = ControlConnection(fileDescriptor: fileDescriptor, label: "app.focusstudio.mcp.control")
        self.log = log
        self.onClose = onClose
    }

    func start() {
        connection.start(onLine: { [weak self] line in
            self?.received(line)
        }, onClose: { [weak self] reason in
            self?.closed(reason)
        })
    }

    var isUsable: Bool { lock.withLock { closeReason == nil } && connection.isOpen }

    func close() { connection.close() }
    func closeAfterPendingWrites() { connection.closeAfterPendingWrites() }

    // MARK: Requests

    func hello(_ hello: ControlHello, timeout: TimeInterval) async -> HelloOutcome {
        let reply = await request(ControlChannel.Method.hello, timeout: timeout, onCancel: .abandon) { _ in hello.json }
        switch reply {
        case let .message(.result(_, value)):
            guard let decoded = try? ControlHelloReply.decode(value) else {
                return .refused("its answer to hello could not be read")
            }
            return .reply(decoded)
        case let .message(.error(_, error)):
            return .refused(error.message)
        case .message:
            return .refused("its answer to hello was not a reply")
        case .timedOut:
            return .timedOut
        case .closed, .notSent:
            return .connectionLost
        case .cancelled:
            return .cancelled
        }
    }

    func call(_ call: ForwardedToolCall, cancelReplyTimeout: TimeInterval) async -> CallOutcome {
        let tool = call.toolName
        let reply = await request(ControlChannel.Method.call, progress: call.progress, onCancel: .tellApp(cancelReplyTimeout)) { id in
            ControlCall(
                tool: tool,
                arguments: call.arguments,
                workingDirectory: call.workingDirectory.path,
                // Opaque to the app, which only checks that it is there.
                // (Not `cond ? nil : …`: AIJSONValue is ExpressibleByNilLiteral,
                // so that nil would be sent as JSON null.)
                progressToken: call.progress.map { _ in AIJSONValue(id) },
                // Measured as the request is written: the app counts the time
                // spent opening it and connecting toward the call's job threshold.
                elapsed: (call.elapsed * 1_000).rounded() / 1_000
            ).json
        }
        switch reply {
        case let .message(message):
            return .answered(AutomationCallResult(controlReply: message, tool: tool))
        case .notSent:
            return .notSent
        case .cancelled, .timedOut, .closed(.closedLocally):
            return .answered(.cancelled)
        case let .closed(reason):
            return .answered(.result(.failure(Self.lostMessage(tool: tool, reason: reason))))
        }
    }

    /// The `isError` for a call cut short by the connection closing: it may
    /// have changed something, so it is not retried.
    static func lostMessage(tool: String, reason: ControlConnection.CloseReason) -> String {
        let check = "check get_status/list_projects (and get_project) to see what it changed before trying again; the call was not retried."
        switch reason {
        case .endOfStream, .readFailed, .writeFailed:
            return "Focus Studio quit before \(tool) finished; \(check)"
        case .lineTooLong:
            return "The connection to Focus Studio broke before \(tool) finished (Focus Studio sent a message larger than \(ControlChannel.maximumLineLength / (1024 * 1024)) MiB); \(check)"
        case .writeTimedOut:
            return "The connection to Focus Studio broke before \(tool) finished (Focus Studio stopped reading); \(check)"
        case .closedLocally:
            return ToolCallRouter.shutdownMessage(for: tool)
        }
    }

    /// Sends one request and waits for its reply, the connection closing, the
    /// timeout, or cancellation (see ``CancelAction``).
    private func request(
        _ method: String,
        progress: AIToolProgressHandler? = nil,
        timeout: TimeInterval? = nil,
        onCancel action: CancelAction,
        params: (Int) -> AIJSONValue
    ) async -> Reply {
        let id = lock.withLock { () -> Int in
            lastID += 1
            entries[lastID] = .allocated
            return lastID
        }
        // Encoded first, so it is queued under the lock that makes it
        // `.waiting`: a cancel (which needs `.waiting`) is then always queued
        // after it, and the app never sees a call's cancel before the call.
        let line = try? ControlMessage.request(id: AIJSONValue(id), method: method, params: params(id)).encoded()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Reply, Never>) in
                let immediate = lock.withLock { () -> Reply? in
                    guard case .allocated? = entries[id] else {
                        entries[id] = nil
                        return .cancelled
                    }
                    if closeReason != nil {
                        entries[id] = nil
                        return .notSent
                    }
                    guard let line else {
                        entries[id] = nil
                        let failure = ControlError(code: ControlChannel.ErrorCode.internalError, message: "focus-studio-mcp could not encode the request")
                        return .message(.error(id: AIJSONValue(id), failure))
                    }
                    entries[id] = .waiting(continuation, progress)
                    // Only queues the write (and never calls back into this link).
                    connection.send(line: line)
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                    return
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.resolve(id, .timedOut)
                    }
                }
            }
        } onCancel: {
            cancel(id, action)
        }
    }

    private func cancel(_ id: Int, _ action: CancelAction) {
        enum Step { case none, tellApp(TimeInterval), stopWaiting(CheckedContinuation<Reply, Never>) }
        let step = lock.withLock { () -> Step in
            switch entries[id] {
            case .allocated?:
                entries[id] = .cancelledEarly
                return .none
            case let .waiting(continuation, _)?:
                switch action {
                case let .tellApp(timeout):
                    return .tellApp(timeout)
                case .abandon:
                    entries[id] = nil
                    return .stopWaiting(continuation)
                }
            case .cancelledEarly?, nil:
                return .none
            }
        }
        switch step {
        case .none:
            break
        case let .tellApp(timeout):
            log.debug("Asking Focus Studio to cancel request \(id)")
            try? connection.send(.notification(method: ControlChannel.Method.cancel, params: ControlCancel(id: AIJSONValue(id)).json))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id, .cancelled)
            }
        case let .stopWaiting(continuation):
            continuation.resume(returning: .cancelled)
        }
    }

    private func resolve(_ id: Int, _ reply: Reply) {
        let continuation = lock.withLock { () -> CheckedContinuation<Reply, Never>? in
            guard case let .waiting(continuation, _)? = entries[id] else { return nil }
            entries[id] = nil
            return continuation
        }
        continuation?.resume(returning: reply)
    }

    // MARK: Incoming

    private func received(_ line: Data) {
        let message: ControlMessage
        do {
            message = try ControlMessage.decode(line)
        } catch {
            log.warning("Focus Studio sent a line that is not a control message; ignored")
            return
        }
        switch message {
        case let .result(id, _), let .error(id?, _):
            guard let number = id.intValue else { return }
            resolve(number, .message(message))
        case let .error(nil, error):
            log.warning("Focus Studio could not read a message from the helper: \(error.message)")
        case let .notification(method, params) where method == ControlChannel.Method.progress:
            guard let update = try? ControlProgress.decode(params), let number = update.id.intValue else { return }
            let handler = lock.withLock { () -> AIToolProgressHandler? in
                if case let .waiting(_, handler)? = entries[number] { return handler }
                return nil
            }
            handler?(update.progress, update.total, update.message)
        case .notification, .request:
            // The app sends no requests; other notifications are not defined.
            break
        }
    }

    private func closed(_ reason: ControlConnection.CloseReason) {
        let waiting = lock.withLock { () -> [CheckedContinuation<Reply, Never>] in
            closeReason = reason
            var continuations: [CheckedContinuation<Reply, Never>] = []
            for (id, entry) in entries {
                if case let .waiting(continuation, _) = entry {
                    continuations.append(continuation)
                    entries[id] = nil
                }
            }
            return continuations
        }
        if reason != .closedLocally { log.info("The connection to Focus Studio closed (\(reason))") }
        for continuation in waiting {
            continuation.resume(returning: .closed(reason))
        }
        onClose(self)
    }
}
