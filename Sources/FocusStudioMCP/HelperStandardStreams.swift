import Darwin

/// The helper's standard streams, arranged so that the MCP protocol stream
/// is the only thing that ever reaches the client's end of standard output.
///
/// ``isolateProtocolOutput()`` runs first in main, before anything can
/// print: it duplicates the original standard output for the transport
/// (close-on-exec, above the standard descriptor numbers) and then points
/// descriptor 1 at standard error. A stray `print`, a library warning or a
/// crash message therefore lands in the client's log instead of corrupting
/// the protocol. It also ignores SIGPIPE, so a client that goes away turns
/// writes into EPIPE errors instead of killing the helper.
struct HelperStandardStreams {
    /// Standard input: the client's messages.
    let input: Int32
    /// The original standard output, for protocol messages only.
    let protocolOutput: Int32
    /// File status flags to put back on exit. The helper's transport leaves
    /// them alone; this only guards the open file descriptions it may share
    /// with its parent (a terminal, when run by hand) against anything that
    /// does change them.
    private let savedFlags: [(descriptor: Int32, flags: Int32)]

    struct SetupError: Error, CustomStringConvertible {
        let operation: String
        let code: Int32

        var description: String { "\(operation) failed: \(String(cString: strerror(code)))" }
    }

    static func isolateProtocolOutput() throws -> HelperStandardStreams {
        signal(SIGPIPE, SIG_IGN)
        // dup and open hand out the lowest free number, so a closed standard
        // descriptor would come back as the protocol stream or a log target.
        // Park /dev/null on any that is closed (in order, so each open lands
        // on the one being checked).
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] where fcntl(descriptor, F_GETFD) == -1 {
            let opened = open("/dev/null", O_RDWR)
            guard opened == descriptor else { throw SetupError(operation: "open /dev/null", code: opened < 0 ? errno : EBADF) }
        }
        let output = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard output > STDERR_FILENO else { throw SetupError(operation: "dup standard output", code: errno) }
        fflush(stdout)
        guard dup2(STDERR_FILENO, STDOUT_FILENO) == STDOUT_FILENO else {
            throw SetupError(operation: "redirect standard output", code: errno)
        }
        // Line-buffer what still writes to standard output (now standard error)
        // so it interleaves sensibly with the logs.
        setvbuf(stdout, nil, _IOLBF, 0)
        let saved = [STDIN_FILENO, output].compactMap { descriptor -> (descriptor: Int32, flags: Int32)? in
            let flags = fcntl(descriptor, F_GETFL)
            return flags < 0 ? nil : (descriptor, flags)
        }
        return HelperStandardStreams(input: STDIN_FILENO, protocolOutput: output, savedFlags: saved)
    }

    /// Puts the descriptors' original file status flags (blocking mode) back.
    func restore() {
        for (descriptor, flags) in savedFlags {
            _ = fcntl(descriptor, F_SETFL, flags)
        }
    }
}
