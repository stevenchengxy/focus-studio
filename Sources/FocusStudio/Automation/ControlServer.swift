import Darwin
import Dispatch
import FocusStudioAutomation
import Foundation

/// The process at the other end of an accepted connection.
struct ControlPeer: Equatable, Sendable {
    var uid: uid_t?
    var gid: gid_t?
    var processID: pid_t?

    init(uid: uid_t?, gid: gid_t?, processID: pid_t?) {
        self.uid = uid
        self.gid = gid
        self.processID = processID
    }

    init(fileDescriptor: Int32) {
        let credentials = ControlSocket.peerCredentials(of: fileDescriptor)
        self.init(uid: credentials?.uid, gid: credentials?.gid, processID: ControlSocket.peerProcessID(of: fileDescriptor))
    }

    /// Only processes of the user running Focus Studio may connect.
    static func isSameUser(_ peer: ControlPeer) -> Bool {
        peer.uid == geteuid()
    }
}

/// What the app says about itself in its `hello` reply.
struct ControlAppInfo: Equatable, Sendable {
    var version: String
    var path: String
    var processID: Int32

    static func current() -> ControlAppInfo {
        let bundle = Bundle.main
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0-dev"
        let location = bundle.bundleURL.pathExtension == "app" ? bundle.bundleURL : (bundle.executableURL ?? bundle.bundleURL)
        return ControlAppInfo(version: version, path: location.resolvingSymlinksInPath().path, processID: getpid())
    }
}

/// The app's end of the control channel (see ``ControlChannel``): listens
/// on the socket, accepts connections from focus-studio-mcp helpers of the
/// same user, and runs each `call` through the approval check and then
/// ``AutomationBridge`` on the main actor.
///
/// - Listening: the socket's folder is made private (0700; a symlink or a
///   folder of another user is refused), a lock file makes sure only one
///   Focus Studio serves the socket, a stale socket file (connecting is
///   refused) is replaced, and while another instance serves, binding is
///   retried every ``Options/retryInterval`` (so a relaunched copy takes
///   over when the old one quits). On ``stop()`` the socket file is removed
///   only if it is still the one this server created.
/// - Each connection reads on its own serial queue and writes whole lines in
///   order; messages are handled on the main queue in arrival order.
/// - `hello` is answered once `readiness` returns (the library has loaded).
/// - Each call is a task: `cancel` cancels it, closing the connection
///   cancels all of that connection's calls.
/// - Access is checked when a call arrives (asking the person if needed) and
///   again right before its tool runs, after any wait for its turn.
/// - A call's time starts when it arrives, less the seconds the helper says
///   it already spent on it (`elapsed`: opening the app, connecting): the
///   approval prompt waits at most until then plus
///   ``AutomationJobs/detachAfter`` (a "waiting_for_approval" result the
///   model can call again with), the bridge's wait for a turn likewise (a
///   "waiting_for_turn" result), and the bridge detaches the tool as a job
///   by the same measure.
@MainActor
final class ControlServer: ObservableObject {
    enum State: Equatable {
        case stopped
        case listening(String)
        /// Another Focus Studio serves the socket; binding is retried.
        case waitingForOtherInstance(String)
        case failed(String)
    }

    struct Options {
        var retryInterval: TimeInterval = 2
        /// Connections beyond this get a ``ControlChannel/ErrorCode/tooManyConnections``
        /// answer (a few at a time; more are closed unanswered).
        var maximumConnections = 32
        var maximumLineLength = ControlChannel.maximumLineLength
        /// Decides on the accept queue whether a peer may talk to the app.
        var peerValidator: @Sendable (ControlPeer) -> Bool = { ControlPeer.isSameUser($0) }
        /// Finds the program behind a helper, off the main thread.
        var identityResolver: @Sendable (pid_t) -> AutomationClientIdentity? = { AutomationClientIdentity.resolve(helperPID: $0) }
    }

    @Published private(set) var state: State = .stopped

    /// Nil when no usable socket path exists (``unavailableReason`` says why).
    let location: ControlSocketLocation?
    let unavailableReason: String?
    let bridge: AutomationBridge
    let access: AutomationAccessController
    let activity: AutomationActivity
    let appInfo: ControlAppInfo
    let options: Options
    private let readiness: @MainActor () async -> Void
    private var listener: ControlListener?
    private var retryTask: Task<Void, Never>?
    private var sessions: [UUID: ControlSession] = [:]
    /// Connections over the limit, until they have been told so.
    private var refusing: [UUID: ControlConnection] = [:]
    private var isRunning = false
    /// How many over-the-limit connections are answered at a time.
    private static let maximumRefusingConnections = 8

    init(
        location: ControlSocketLocation?,
        unavailableReason: String? = nil,
        bridge: AutomationBridge,
        access: AutomationAccessController,
        activity: AutomationActivity,
        appInfo: ControlAppInfo = .current(),
        options: Options = Options(),
        readiness: @escaping @MainActor () async -> Void
    ) {
        self.location = location
        self.unavailableReason = unavailableReason
        self.bridge = bridge
        self.access = access
        self.activity = activity
        self.appInfo = appInfo
        self.options = options
        self.readiness = readiness
    }

    /// Open connections.
    var connectionCount: Int { sessions.count }
    /// Calls running now, over all connections.
    var runningCallCount: Int { sessions.values.reduce(0) { $0 + $1.calls.count } }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        attemptToListen()
    }

    /// Stops listening, removes the socket file if it is still this server's,
    /// and closes every connection, cancelling their calls. Returns the
    /// cancelled calls' tasks, so a quitting app can wait for their cleanup
    /// (a cancelled export removes its partial file); the helpers see their
    /// connection close at once either way.
    @discardableResult
    func stop() -> [Task<Void, Never>] {
        isRunning = false
        retryTask?.cancel()
        retryTask = nil
        listener?.stop()
        listener = nil
        let cancelled = sessions.values.flatMap { Array($0.calls.values) }
        for session in sessions.values {
            session.cancelCalls()
            session.connection.close()
        }
        sessions.removeAll()
        refusing.values.forEach { $0.close() }
        refusing.removeAll()
        state = .stopped
        return cancelled
    }

    // MARK: - Listening

    private func attemptToListen() {
        guard isRunning, listener == nil else { return }
        guard let location else {
            state = .failed(unavailableReason ?? "The control socket has no usable path.")
            return
        }
        do {
            let listener = try ControlListener.open(location)
            self.listener = listener
            state = .listening(location.path)
            let validator = options.peerValidator
            listener.startAccepting { [weak self] descriptor in
                let peer = ControlPeer(fileDescriptor: descriptor)
                guard validator(peer) else {
                    Darwin.close(descriptor)
                    return
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let self { self.accept(descriptor, peer: peer) } else { Darwin.close(descriptor) }
                    }
                }
            }
        } catch ControlListener.OpenError.busy {
            state = .waitingForOtherInstance(location.path)
            let interval = options.retryInterval
            retryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.retryTask = nil
                self.attemptToListen()
            }
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func accept(_ descriptor: Int32, peer: ControlPeer) {
        guard isRunning else {
            Darwin.close(descriptor)
            return
        }
        guard sessions.count < options.maximumConnections else {
            refuseOverLimit(descriptor)
            return
        }
        let connection = ControlConnection(fileDescriptor: descriptor, label: "app.focusstudio.control.connection", maximumLineLength: options.maximumLineLength)
        let resolver = options.identityResolver
        let identity = Task.detached(priority: .userInitiated) { peer.processID.flatMap(resolver) }
        let session = ControlSession(connection: connection, peer: peer, identity: identity)
        let id = session.id
        sessions[id] = session
        connection.start(onLine: { [weak self, weak connection] line in
            let message: ControlMessage
            do {
                message = try ControlMessage.decode(line)
            } catch let failure as ControlMessageError {
                try? connection?.send(failure.reply)
                return
            } catch {
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(message, session: id) }
            }
        }, onClose: { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.connectionClosed(id) }
            }
        })
    }

    /// Over the connection limit: answers the helper's first request (its
    /// hello) with an error it shows the model, then closes. Beyond
    /// ``maximumRefusingConnections`` such connections, closes at once.
    private func refuseOverLimit(_ descriptor: Int32) {
        guard refusing.count < Self.maximumRefusingConnections else {
            Darwin.close(descriptor)
            return
        }
        let connection = ControlConnection(fileDescriptor: descriptor, label: "app.focusstudio.control.refused", maximumLineLength: options.maximumLineLength)
        let id = UUID()
        refusing[id] = connection
        let message = "Focus Studio already has \(options.maximumConnections) AI tool sessions connected, its limit. Ask the person to end AI tool sessions they no longer use, then try again."
        connection.start(onLine: { [weak connection] line in
            guard let connection, case let .request(requestID, _, _)? = try? ControlMessage.decode(line) else { return }
            try? connection.send(.error(id: requestID, ControlError(code: ControlChannel.ErrorCode.tooManyConnections, message: message)))
            connection.closeAfterPendingWrites()
        }, onClose: { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = self?.refusing.removeValue(forKey: id) }
            }
        })
    }

    private func connectionClosed(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.cancelCalls()
        session.identity.cancel()
    }

    // MARK: - Messages

    private func handle(_ message: ControlMessage, session id: UUID) {
        guard let session = sessions[id] else { return }
        switch message {
        case let .request(requestID, method, params):
            switch method {
            case ControlChannel.Method.hello:
                hello(requestID, params: params, session: session)
            case ControlChannel.Method.call:
                call(requestID, params: params, session: session)
            default:
                session.reply(.error(id: requestID, ControlError(code: ControlChannel.ErrorCode.methodNotFound, message: "Method not found: \(method)")))
            }
        case let .notification(method, params):
            if method == ControlChannel.Method.cancel, let cancel = try? ControlCancel.decode(params) {
                session.calls[cancel.id]?.cancel()
            }
        case .result, .error:
            // The app sends no requests, so there is nothing to match.
            break
        }
    }

    private func hello(_ id: AIJSONValue, params: AIJSONValue?, session: ControlSession) {
        let hello: ControlHello
        do {
            hello = try ControlHello.decode(params)
        } catch {
            session.reply(.error(id: id, Self.controlError(error)))
            return
        }
        session.hello = hello
        let reply = ControlHelloReply(appVersion: appInfo.version, appPath: appInfo.path, pid: appInfo.processID)
        let readiness = self.readiness
        Task { @MainActor in
            await readiness()
            session.reply(.result(id: id, reply.json))
        }
    }

    private func call(_ id: AIJSONValue, params: AIJSONValue?, session: ControlSession) {
        guard let hello = session.hello else {
            session.reply(.error(id: id, ControlError(code: ControlChannel.ErrorCode.helloRequired, message: "Send hello before call.")))
            return
        }
        guard hello.protocolVersion == ControlChannel.protocolVersion else {
            let message = "Focus Studio at \(appInfo.path) (version \(appInfo.version)) speaks control protocol \(ControlChannel.protocolVersion), but this focus-studio-mcp (version \(hello.helperVersion)) speaks \(hello.protocolVersion). Use the focus-studio-mcp inside the Focus Studio.app that is running."
            session.reply(.error(id: id, ControlError(code: ControlChannel.ErrorCode.protocolMismatch, message: message)))
            return
        }
        let call: ControlCall
        do {
            call = try ControlCall.decode(params)
        } catch {
            session.reply(.error(id: id, Self.controlError(error)))
            return
        }
        guard session.calls[id] == nil else {
            session.reply(.error(id: id, ControlError(code: ControlChannel.ErrorCode.invalidRequest, message: "A call with the id \(id) is already running.")))
            return
        }
        // The call's time counts from here, less what the helper already spent on it.
        let arrivedAt = Date().addingTimeInterval(-call.countedElapsed)
        let sink = ControlProgressSink(connection: session.connection, id: id, isEnabled: call.progressToken != nil)
        let workingDirectory = (call.workingDirectory ?? hello.workingDirectory)
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
        let task = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            let outcome = await self.run(call, hello: hello, session: session, workingDirectory: workingDirectory, arrivedAt: arrivedAt, progress: sink.handler)
            sink.finish {
                do {
                    try session.connection.send(outcome.controlReply(id: id))
                } catch {
                    try? session.connection.send(.error(id: id, ControlError(code: ControlChannel.ErrorCode.internalError, message: "Focus Studio could not encode the result of \(call.tool).")))
                }
            }
            session.calls[id] = nil
        }
        session.calls[id] = task
    }

    private func run(
        _ call: ControlCall,
        hello: ControlHello,
        session: ControlSession,
        workingDirectory: URL?,
        arrivedAt: Date,
        progress: AIToolProgressHandler?
    ) async -> AutomationCallResult {
        await readiness()
        if Task.isCancelled { return .cancelled }
        let identity = await session.identity.value
        let deadline = arrivedAt.addingTimeInterval(bridge.jobs.detachAfter)
        switch await access.authorize(identity: identity, client: hello.client, tool: call.tool, connection: session.access, deadline: deadline, progress: progress) {
        case let .refused(message):
            return .result(.failure(message))
        case let .stillAsking(result):
            return .result(result)
        case .cancelled:
            return .cancelled
        case .allowed:
            break
        }
        if Task.isCancelled { return .cancelled }
        let clientName = hello.client?.displayName ?? identity?.programName ?? "AI tool"
        let entry = activity.begin(clientName: clientName, tool: call.tool)
        defer { activity.end(entry) }
        // Keeps App Nap from slowing a call while the app is in the background.
        let napGuard = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Running \(call.tool) for \(clientName)")
        defer { ProcessInfo.processInfo.endActivity(napGuard) }
        let access = self.access
        let connection = session.access
        return await bridge.call(
            toolName: call.tool,
            arguments: call.arguments.mapValues(\.jsonObject),
            workingDirectory: workingDirectory,
            clientName: clientName,
            programName: identity?.programName,
            arrivedAt: arrivedAt,
            progress: progress,
            stillAllowed: { access.refusalNow(identity: identity, connection: connection, tool: call.tool, client: clientName) }
        )
    }

    private static func controlError(_ error: Error) -> ControlError {
        (error as? ControlError) ?? ControlError(code: ControlChannel.ErrorCode.invalidParams, message: "Invalid params: \(error.localizedDescription)")
    }
}

/// One helper's connection.
@MainActor
private final class ControlSession {
    let id = UUID()
    let connection: ControlConnection
    let peer: ControlPeer
    /// The program that started the helper, resolved once per connection.
    let identity: Task<AutomationClientIdentity?, Never>
    /// This connection's own approval, for a client that is not remembered.
    let access = AutomationConnectionAccess()
    var hello: ControlHello?
    var calls: [AIJSONValue: Task<Void, Never>] = [:]

    init(connection: ControlConnection, peer: ControlPeer, identity: Task<AutomationClientIdentity?, Never>) {
        self.connection = connection
        self.peer = peer
        self.identity = identity
    }

    func reply(_ message: ControlMessage) {
        try? connection.send(message)
    }

    func cancelCalls() {
        calls.values.forEach { $0.cancel() }
    }
}

/// Sends a call's progress to its helper: only when the call asked for it,
/// only increasing finite values, and nothing once the reply is on its way.
private final class ControlProgressSink: @unchecked Sendable {
    private let connection: ControlConnection
    private let id: AIJSONValue
    private let isEnabled: Bool
    private let lock = NSLock()
    private var last = -Double.infinity
    private var finished = false

    init(connection: ControlConnection, id: AIJSONValue, isEnabled: Bool) {
        self.connection = connection
        self.id = id
        self.isEnabled = isEnabled
    }

    var handler: AIToolProgressHandler? {
        guard isEnabled else { return nil }
        return { [self] completed, total, message in report(completed, total, message) }
    }

    private func report(_ completed: Double, _ total: Double?, _ message: String?) {
        lock.withLock {
            guard !finished, completed.isFinite, completed > last else { return }
            last = completed
            let params = ControlProgress(id: id, progress: completed, total: total.flatMap { $0.isFinite ? $0 : nil }, message: message)
            try? connection.send(.notification(method: ControlChannel.Method.progress, params: params.json))
        }
    }

    /// Stops progress and runs `send` (the reply) so no progress follows it.
    func finish(_ send: () -> Void) {
        lock.withLock {
            finished = true
            send()
        }
    }
}

/// The listening socket, owned by one server.
final class ControlListener: @unchecked Sendable {
    enum OpenError: Error, Equatable, LocalizedError {
        /// Another Focus Studio serves this socket.
        case busy
        /// The folder or the path is not safe to use; retrying will not help.
        case unsafe(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .busy: return "Another copy of Focus Studio is serving AI tools."
            case let .unsafe(message), let .failed(message): return message
            }
        }
    }

    let location: ControlSocketLocation
    private let descriptor: Int32
    private let lockDescriptor: Int32
    private let socketDevice: dev_t
    private let socketInode: ino_t
    private let queue = DispatchQueue(label: "app.focusstudio.control.accept")
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var stopped = false

    private init(location: ControlSocketLocation, descriptor: Int32, lockDescriptor: Int32, device: dev_t, inode: ino_t) {
        self.location = location
        self.descriptor = descriptor
        self.lockDescriptor = lockDescriptor
        socketDevice = device
        socketInode = inode
    }

    /// Makes the folder private, takes the instance lock, replaces a stale
    /// socket file, then binds (mode 0600) and listens.
    static func open(_ location: ControlSocketLocation) throws -> ControlListener {
        try secureDirectory(location.directory)
        let lockDescriptor = Darwin.open(location.lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockDescriptor >= 0 else { throw OpenError.failed(systemMessage("Could not open \(location.lockPath)", errno)) }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(lockDescriptor)
            if code == EWOULDBLOCK { throw OpenError.busy }
            throw OpenError.failed(systemMessage("Could not lock \(location.lockPath)", code))
        }
        do {
            try removeStaleSocket(at: location.path)
            let descriptor = try ControlSocket.makeSocket()
            do {
                var address = try ControlSocket.address(for: location.path)
                let bound = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard bound == 0 else {
                    let code = errno
                    if code == EADDRINUSE { throw OpenError.busy }
                    throw OpenError.failed(systemMessage("Could not create \(location.path)", code))
                }
                // The system's largest backlog: on macOS a full backlog
                // refuses connections (ECONNREFUSED), which a helper reads
                // as "Focus Studio is not running".
                guard chmod(location.path, 0o600) == 0, listen(descriptor, SOMAXCONN) == 0 else {
                    let code = errno
                    unlink(location.path)
                    throw OpenError.failed(systemMessage("Could not listen on \(location.path)", code))
                }
                var info = stat()
                guard lstat(location.path, &info) == 0 else {
                    throw OpenError.failed(systemMessage("Could not inspect \(location.path)", errno))
                }
                ControlSocket.setNonBlocking(descriptor)
                return ControlListener(location: location, descriptor: descriptor, lockDescriptor: lockDescriptor, device: info.st_dev, inode: info.st_ino)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        } catch {
            Darwin.close(lockDescriptor)
            throw error
        }
    }

    /// Calls `handler` on the accept queue with each accepted descriptor,
    /// which it then owns.
    func startAccepting(_ handler: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, source == nil else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let listening = descriptor
        source.setEventHandler {
            while true {
                let accepted = Darwin.accept(listening, nil, nil)
                if accepted >= 0 {
                    ControlSocket.prepare(accepted)
                    handler(accepted)
                    continue
                }
                let code = errno
                if code == EINTR || code == ECONNABORTED { continue }
                // Out of descriptors: the connection waits in the backlog and
                // the source fires again; pace that instead of spinning.
                if code == EMFILE || code == ENFILE { usleep(100_000) }
                return
            }
        }
        source.setCancelHandler {
            Darwin.close(listening)
        }
        self.source = source
        source.resume()
    }

    /// Removes the socket file if it is still the one this listener created,
    /// stops accepting and releases the instance lock at once, so another
    /// copy can take over right away.
    func stop() {
        enum Closing { case none, cancel(DispatchSourceRead), close }
        let closing = lock.withLock { () -> Closing in
            guard !stopped else { return .none }
            stopped = true
            return source.map { .cancel($0) } ?? .close
        }
        switch closing {
        case .none:
            return
        case let .cancel(source):
            removeSocketIfOwned()
            // The cancel handler closes the listening descriptor.
            source.cancel()
        case .close:
            removeSocketIfOwned()
            Darwin.close(descriptor)
        }
        Darwin.close(lockDescriptor)
    }

    private func removeSocketIfOwned() {
        var info = stat()
        guard lstat(location.path, &info) == 0, info.st_dev == socketDevice, info.st_ino == socketInode else { return }
        unlink(location.path)
    }

    /// Creates the folder (0700) or checks it: a real folder, not a symlink,
    /// owned by this user; group or other access is removed.
    static func secureDirectory(_ path: String) throws {
        if mkdir(path, 0o700) != 0 {
            let code = errno
            if code == ENOENT {
                let parent = (path as NSString).deletingLastPathComponent
                do {
                    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                } catch {
                    throw OpenError.failed("Could not create \(parent): \(error.localizedDescription)")
                }
                if mkdir(path, 0o700) != 0, errno != EEXIST {
                    throw OpenError.failed(systemMessage("Could not create \(path)", errno))
                }
            } else if code != EEXIST {
                throw OpenError.failed(systemMessage("Could not create \(path)", code))
            }
        }
        let folder = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR {
                throw OpenError.unsafe("\(path) is a symbolic link or not a folder, so Focus Studio does not use it for its control socket.")
            }
            throw OpenError.failed(systemMessage("Could not open \(path)", code))
        }
        defer { Darwin.close(folder) }
        var info = stat()
        guard fstat(folder, &info) == 0 else { throw OpenError.failed(systemMessage("Could not inspect \(path)", errno)) }
        guard info.st_uid == geteuid() else {
            throw OpenError.unsafe("\(path) belongs to another user, so Focus Studio does not use it for its control socket.")
        }
        if info.st_mode & 0o077 != 0, fchmod(folder, 0o700) != 0 {
            throw OpenError.unsafe(systemMessage("\(path) is open to other users and could not be made private", errno))
        }
    }

    /// Nothing at `path`: fine. A socket nobody answers on: removed. A socket
    /// that answers: another server, `busy`. Anything else is left alone.
    static func removeStaleSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return }
            throw OpenError.failed(systemMessage("Could not inspect \(path)", code))
        }
        guard info.st_mode & S_IFMT == S_IFSOCK else {
            throw OpenError.unsafe("\(path) exists and is not a socket, so Focus Studio leaves it alone and does not listen.")
        }
        do {
            let probe = try ControlSocket.connect(to: path)
            Darwin.close(probe)
        } catch let error as ControlSocketError where error.code == ECONNREFUSED {
            guard unlink(path) == 0 || errno == ENOENT else {
                throw OpenError.failed(systemMessage("Could not remove the stale socket \(path)", errno))
            }
            return
        } catch {
            throw OpenError.failed("Could not check \(path): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
        throw OpenError.busy
    }

    private static func systemMessage(_ prefix: String, _ code: Int32) -> String {
        "\(prefix): \(String(cString: strerror(code)))."
    }
}
