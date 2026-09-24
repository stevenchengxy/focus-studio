import Darwin
import Dispatch
import Foundation

/// A failed socket operation on the control channel.
public enum ControlSocketError: Error, Equatable, LocalizedError, Sendable {
    case pathTooLong(String)
    /// A system call failed with `code` (an errno value).
    case system(operation: String, code: Int32)

    public var code: Int32? {
        if case let .system(_, code) = self { return code }
        return nil
    }

    /// Nothing is listening: no socket file (ENOENT) or a stale one whose
    /// app has quit (ECONNREFUSED). The helper launches the app then.
    public var meansNoListener: Bool {
        code == ENOENT || code == ECONNREFUSED
    }

    public var errorDescription: String? {
        switch self {
        case let .pathTooLong(path):
            return ControlChannelError.socketPathTooLong(path).errorDescription
        case let .system(operation, code):
            return "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

/// POSIX helpers for the control channel's Unix domain sockets.
public enum ControlSocket {
    /// A `sockaddr_un` for `path`; throws when the path does not fit.
    public static func address(for path: String) throws -> sockaddr_un {
        guard ControlChannel.fits(path) else { throw ControlSocketError.pathTooLong(path) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    /// A new stream socket, close-on-exec and without SIGPIPE.
    public static func makeSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlSocketError.system(operation: "socket", code: errno) }
        prepare(descriptor)
        return descriptor
    }

    /// Marks a descriptor close-on-exec (no child process inherits it) and
    /// turns SIGPIPE into EPIPE for writes to a closed peer.
    public static func prepare(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0, flags & O_NONBLOCK == 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    /// Connects to the socket at `path` and returns the descriptor
    /// (blocking, close-on-exec, no SIGPIPE). See
    /// ``ControlSocketError/meansNoListener`` for "the app is not running".
    public static func connect(to path: String) throws -> Int32 {
        var address = try address(for: path)
        while true {
            let descriptor = try makeSocket()
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { return descriptor }
            let code = errno
            Darwin.close(descriptor)
            // An interrupted connect goes on in the background; start over
            // on a fresh socket rather than track it.
            if code == EINTR { continue }
            throw ControlSocketError.system(operation: "connect", code: code)
        }
    }

    /// The peer's effective user and group (`getpeereid`).
    public static func peerCredentials(of descriptor: Int32) -> (uid: uid_t, gid: gid_t)? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0 else { return nil }
        return (uid, gid)
    }

    /// The peer's process id (`LOCAL_PEERPID`), as it was when it connected.
    public static func peerProcessID(of descriptor: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }
}

/// One control-channel connection over a connected socket: reads lines on
/// its own serial queue (a GCD read source; no thread blocks while idle) and
/// writes whole lines in order on another, so any thread may send.
///
/// Closing, for any reason, happens once: the read source is cancelled, the
/// close handler runs on the read queue, and the descriptor is closed after
/// the writes already started. A closed connection drops what it is sent.
public final class ControlConnection: @unchecked Sendable {
    public enum CloseReason: Equatable, Sendable {
        /// The peer closed its end.
        case endOfStream
        /// A line exceeded the limit.
        case lineTooLong
        case readFailed(Int32)
        case writeFailed(Int32)
        /// The peer stopped reading for longer than the write timeout.
        case writeTimedOut
        /// ``close()`` or ``closeAfterPendingWrites()``.
        case closedLocally
    }

    private enum State { case idle, starting, open, closing, closed }

    public let fileDescriptor: Int32
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let writeTimeout: TimeInterval
    private let lock = NSLock()
    private var state = State.idle
    private var closeReason: CloseReason?
    private var readSource: DispatchSourceRead?
    private var lineHandler: (@Sendable (Data) -> Void)?
    private var closeHandler: (@Sendable (CloseReason) -> Void)?
    /// Read queue only.
    private var framer: LineFramer
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
    /// Write queue only: the descriptor has been closed.
    private var descriptorClosed = false

    /// Takes ownership of `fileDescriptor`, which it makes non-blocking.
    public init(
        fileDescriptor: Int32,
        label: String = "app.focusstudio.control",
        maximumLineLength: Int = ControlChannel.maximumLineLength,
        writeTimeout: TimeInterval = 30
    ) {
        self.fileDescriptor = fileDescriptor
        readQueue = DispatchQueue(label: "\(label).read")
        writeQueue = DispatchQueue(label: "\(label).write")
        framer = LineFramer(maximumLineLength: maximumLineLength)
        self.writeTimeout = max(0.1, writeTimeout)
        ControlSocket.prepare(fileDescriptor)
        ControlSocket.setNonBlocking(fileDescriptor)
    }

    deinit {
        // Never started or never closed: release the descriptor.
        if state == .idle || state == .open { Darwin.close(fileDescriptor) }
    }

    /// Starts reading. `onLine` gets each line (without its line feed) in
    /// order on the read queue; `onClose` runs once, on the read queue, when
    /// the connection closes for any reason. Call once.
    public func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (CloseReason) -> Void) {
        let begins = lock.withLock { () -> Bool in
            guard state == .idle else { return false }
            state = .starting
            lineHandler = onLine
            closeHandler = onClose
            return true
        }
        guard begins else { return }
        // Created only now: a dispatch source must never be released
        // without having been resumed.
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: readQueue)
        source.setEventHandler { [self] in readAvailable() }
        source.setCancelHandler { [self] in
            let (reason, handler) = lock.withLock { () -> (CloseReason, (@Sendable (CloseReason) -> Void)?) in
                let handler = closeHandler
                closeHandler = nil
                lineHandler = nil
                readSource = nil
                return (closeReason ?? .closedLocally, handler)
            }
            handler?(reason)
            writeQueue.async { [self] in
                descriptorClosed = true
                Darwin.close(fileDescriptor)
                lock.withLock { state = .closed }
            }
        }
        let closedWhileStarting = lock.withLock { () -> Bool in
            readSource = source
            guard state == .starting else { return true }
            state = .open
            return false
        }
        source.resume()
        if closedWhileStarting {
            _ = shutdown(fileDescriptor, SHUT_RDWR)
            source.cancel()
        }
    }

    public var isOpen: Bool { lock.withLock { state == .open } }

    /// Why the connection closed; nil while open.
    public var closedBecause: CloseReason? { lock.withLock { state == .open || state == .idle || state == .starting ? nil : closeReason } }

    /// Queues `line` (one message, without a line feed) for writing.
    public func send(line: Data) {
        guard isOpen else { return }
        var bytes = line
        bytes.append(0x0A)
        writeQueue.async { [self] in
            guard !descriptorClosed, isOpen else { return }
            write(bytes)
        }
    }

    /// Queues `message` for writing. Throws only when it cannot be encoded
    /// (a non-finite number built by hand).
    public func send(_ message: ControlMessage) throws {
        send(line: try message.encoded())
    }

    /// Closes now; queued writes that have not started are dropped.
    public func close() {
        finish(.closedLocally)
    }

    /// Closes once everything queued so far has been written.
    public func closeAfterPendingWrites() {
        writeQueue.async { [self] in finish(.closedLocally) }
    }

    // MARK: - Reading

    private func readAvailable() {
        while true {
            let count = readBuffer.withUnsafeMutableBytes { Darwin.read(fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let lines: [Data]
                do {
                    lines = try framer.append(readBuffer[0..<count])
                } catch {
                    finish(.lineTooLong)
                    return
                }
                let handler = lock.withLock { state == .open ? lineHandler : nil }
                guard let handler else { return }
                for line in lines {
                    guard isOpen else { return }
                    handler(line)
                }
                if count < readBuffer.count { return }
            } else if count == 0 {
                // A last line without a line feed is a truncated message:
                // the peer is gone and could not read an answer anyway.
                _ = framer.finish()
                finish(.endOfStream)
                return
            } else {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { return }
                finish(.readFailed(code))
                return
            }
        }
    }

    // MARK: - Writing

    /// Write queue only.
    private func write(_ bytes: Data) {
        let deadline = Date().addingTimeInterval(writeTimeout)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(fileDescriptor, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            let code = errno
            if written < 0, code == EINTR { continue }
            if written < 0, code == EAGAIN || code == EWOULDBLOCK {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    finish(.writeTimedOut)
                    return
                }
                var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, Int32(min(remaining, 1) * 1_000))
                guard isOpen else { return }
                continue
            }
            finish(.writeFailed(written < 0 ? code : EPIPE))
            return
        }
    }

    // MARK: - Closing

    private func finish(_ reason: CloseReason) {
        enum Step { case none, closeDescriptor, cancel(DispatchSourceRead) }
        let step = lock.withLock { () -> Step in
            switch state {
            case .idle:
                // Never started: nothing reads, so close right away.
                state = .closed
                closeReason = reason
                return .closeDescriptor
            case .starting:
                // start() sees this and cancels its new source.
                state = .closing
                closeReason = reason
                return .none
            case .open:
                state = .closing
                closeReason = reason
                return readSource.map { .cancel($0) } ?? .none
            case .closing, .closed:
                return .none
            }
        }
        switch step {
        case .none:
            break
        case .closeDescriptor:
            writeQueue.async { [self] in
                descriptorClosed = true
                Darwin.close(fileDescriptor)
            }
        case let .cancel(source):
            // Wakes a write blocked in poll and tells the peer at once; the
            // descriptor itself closes after the read source is gone.
            _ = shutdown(fileDescriptor, SHUT_RDWR)
            source.cancel()
        }
    }
}
