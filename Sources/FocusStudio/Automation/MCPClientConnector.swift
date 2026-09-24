import Darwin
import FocusStudioAutomation
import Foundation

/// An MCP client Focus Studio registers itself with through the client's
/// official CLI (`claude mcp add`, `codex mcp add`), never by editing the
/// client's configuration files.
enum MCPClientKind: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var executableName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    /// Registers the helper: for Claude Code in the user scope (every project).
    func addArguments(helperPath: String) -> [String] {
        switch self {
        case .claudeCode: return ["mcp", "add", "--scope", "user", MCPClientConnector.serverName, "--", helperPath]
        case .codex: return ["mcp", "add", MCPClientConnector.serverName, "--", helperPath]
        }
    }

    /// `scope` is the Claude Code scope the existing entry is in.
    func removeArguments(scope: String?) -> [String] {
        switch self {
        case .claudeCode: return ["mcp", "remove", "--scope", scope ?? "user", MCPClientConnector.serverName]
        case .codex: return ["mcp", "remove", MCPClientConnector.serverName]
        }
    }

    var getArguments: [String] {
        switch self {
        case .claudeCode: return ["mcp", "get", MCPClientConnector.serverName]
        case .codex: return ["mcp", "get", MCPClientConnector.serverName, "--json"]
        }
    }

    /// The command a person can paste into Terminal, the path quoted.
    func commandLine(helperPath: String) -> String {
        ([executableName] + addArguments(helperPath: helperPath)).map(ShellQuoting.quote).joined(separator: " ")
    }

    /// Where the CLI is usually installed, after PATH.
    func standardLocations(home: String) -> [String] {
        let name = executableName
        var paths = [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
            "\(home)/.volta/bin/\(name)",
        ]
        if self == .claudeCode { paths.insert("\(home)/.claude/local/claude", at: 1) }
        // Node version managers: newest version first.
        let nvm = "\(home)/.nvm/versions/node"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        paths += versions.map { "\(nvm)/\($0)/bin/\(name)" }
        if self == .codex {
            for applications in ["/Applications", "\(home)/Applications"] {
                paths += ["\(applications)/Codex.app/Contents/Resources/codex", "\(applications)/ChatGPT.app/Contents/Resources/codex"]
            }
        }
        return paths
    }
}

enum ShellQuoting {
    /// POSIX shell quoting: bare when safe, else single quotes.
    static func quote(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy({ safe.contains($0) }) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// How Focus Studio is registered with a client.
struct MCPClientRegistration: Equatable, Sendable {
    var command: String
    var arguments: [String]
    /// Claude Code: "user", "local" or "project".
    var scope: String?
}

enum MCPClientConnectionState: Equatable, Sendable {
    case unknown
    case checking
    case cliNotFound
    case notConnected
    /// Registered with this app's helper.
    case connected(MCPClientRegistration)
    /// Registered as focus-studio, but with another command (an older copy).
    case connectedElsewhere(MCPClientRegistration)
    /// The CLI ran and failed; its error output.
    case failed(String)
}

struct MCPClientStatus: Equatable, Sendable {
    var cliPath: String?
    var state: MCPClientConnectionState = .unknown
    /// What the last connect did, for the person.
    var note: String?
}

/// What running a CLI came to.
struct CLIRunResult: Equatable, Sendable {
    var exitStatus: Int32
    var standardOutput: String
    var standardError: String
    var timedOut = false
    var launchError: String?

    var succeeded: Bool { launchError == nil && !timedOut && exitStatus == 0 }

    /// The error text to show: stderr, else stdout, else what happened.
    var failureText: String {
        if let launchError { return launchError }
        if timedOut { return "The command did not finish in time." }
        let error = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !error.isEmpty { return error }
        let output = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "The command failed with exit status \(exitStatus)." : output
    }
}

/// Runs a command with an argument array (never through a shell string),
/// standard input from /dev/null, both outputs captured, and a hard
/// deadline after which it is terminated, then killed.
enum CLIRunner {
    static let outputLimit = 1_024 * 1_024

    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String?,
        timeout: TimeInterval
    ) async -> CLIRunResult {
        await withCheckedContinuation { continuation in
            CLIRun(executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory, timeout: timeout)
                .start { continuation.resume(returning: $0) }
        }
    }
}

private final class CLIRun: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let error = Pipe()
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var outputData = Data()
    private var errorData = Data()
    private var openStreams = 2
    private var exited = false
    private var timedOut = false
    private var completion: (@Sendable (CLIRunResult) -> Void)?

    init(executable: String, arguments: [String], environment: [String: String], currentDirectory: String?, timeout: TimeInterval) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        self.timeout = max(0.1, timeout)
    }

    func start(completion: @escaping @Sendable (CLIRunResult) -> Void) {
        self.completion = completion
        for (pipe, isOutput) in [(output, true), (error, false)] {
            pipe.fileHandleForReading.readabilityHandler = { [self] handle in
                let data = handle.availableData
                lock.withLock {
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        openStreams -= 1
                    } else if isOutput {
                        if outputData.count < CLIRunner.outputLimit { outputData.append(data) }
                    } else if errorData.count < CLIRunner.outputLimit {
                        errorData.append(data)
                    }
                }
                finishIfDone()
            }
        }
        process.terminationHandler = { [self] _ in
            lock.withLock { exited = true }
            finishIfDone()
            // A child of the command may keep the pipes open; do not wait for it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in finish() }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            self.error.fileHandleForReading.readabilityHandler = nil
            deliver(CLIRunResult(exitStatus: -1, standardOutput: "", standardError: "", launchError: "Could not run \(process.executableURL?.path ?? "the command"): \(error.localizedDescription)"))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            let running = lock.withLock { () -> Bool in
                guard self.completion != nil, !exited else { return false }
                timedOut = true
                return true
            }
            guard running else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                finish()
            }
        }
    }

    private func finishIfDone() {
        let done = lock.withLock { exited && openStreams <= 0 }
        if done { finish() }
    }

    private func finish() {
        let result = lock.withLock { () -> CLIRunResult? in
            guard completion != nil else { return nil }
            let status = exited ? process.terminationStatus : -1
            return CLIRunResult(
                exitStatus: status,
                standardOutput: String(decoding: outputData, as: UTF8.self),
                standardError: String(decoding: errorData, as: UTF8.self),
                timedOut: timedOut
            )
        }
        guard let result else { return }
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        deliver(result)
    }

    private func deliver(_ result: CLIRunResult) {
        let completion = lock.withLock { () -> (@Sendable (CLIRunResult) -> Void)? in
            defer { self.completion = nil }
            return self.completion
        }
        completion?(result)
    }
}

/// Where the CLIs are: the GUI app's own PATH is minimal (/usr/bin:/bin…),
/// so the user's login shell is asked (`$SHELL -l -c 'command -v …'`, with
/// a timeout) and the usual install folders are searched. The first
/// candidate that answers `--version` wins, so a broken install (a Node shim
/// whose package is gone) is skipped.
struct MCPCLISearch: Sendable {
    /// Plain commands that sh, bash, zsh and fish all run.
    static let loginShellScript = "echo __FOCUS_STUDIO_CLAUDE__; command -v claude; echo __FOCUS_STUDIO_CODEX__; command -v codex; echo __FOCUS_STUDIO_PATH__; printf '%s\\n' $PATH"

    var environment: [String: String]
    var homeDirectory: String
    /// The user's login shell; nil skips asking it.
    var loginShell: String?
    var loginShellTimeout: TimeInterval = 5
    var versionTimeout: TimeInterval = 5
    var searchesStandardLocations = true

    static func current() -> MCPCLISearch {
        let environment = ProcessInfo.processInfo.environment
        var shell = environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        if shell == nil, let record = getpwuid(getuid()), let path = record.pointee.pw_shell {
            shell = String(cString: path)
        }
        return MCPCLISearch(environment: environment, homeDirectory: ControlChannel.userHomeDirectory(), loginShell: shell)
    }

    struct Result: Equatable, Sendable {
        var executables: [MCPClientKind: String] = [:]
        /// The login shell's PATH, for running the CLIs (a Node shim needs `node`).
        var shellPath: [String] = []
    }

    func locate() async -> Result {
        var result = Result()
        var shellFinds: [MCPClientKind: String] = [:]
        if let loginShell, FileManager.default.isExecutableFile(atPath: loginShell) {
            let probe = await CLIRunner.run(
                loginShell, arguments: ["-l", "-c", Self.loginShellScript],
                environment: shellEnvironment, currentDirectory: homeDirectory, timeout: loginShellTimeout
            )
            if !probe.timedOut, probe.launchError == nil {
                (shellFinds, result.shellPath) = Self.parseLoginShellOutput(probe.standardOutput)
            }
        }
        for kind in MCPClientKind.allCases {
            var candidates: [String] = []
            if let found = shellFinds[kind] { candidates.append(found) }
            let appPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            candidates += (appPath + result.shellPath).map { ($0 as NSString).appendingPathComponent(kind.executableName) }
            if searchesStandardLocations { candidates += kind.standardLocations(home: homeDirectory) }
            var seen = Set<String>()
            for candidate in candidates where candidate.hasPrefix("/") && seen.insert(candidate).inserted {
                guard Self.isExecutableFile(candidate) else { continue }
                let version = await CLIRunner.run(
                    candidate, arguments: ["--version"],
                    environment: commandEnvironment(for: candidate, shellPath: result.shellPath),
                    currentDirectory: homeDirectory, timeout: versionTimeout
                )
                if version.succeeded {
                    result.executables[kind] = candidate
                    break
                }
            }
        }
        return result
    }

    /// The environment for running a CLI: this app's, minus Focus Studio's
    /// own test and QA variables, with a PATH that finds the CLI's runtime.
    func commandEnvironment(for executable: String, shellPath: [String]) -> [String: String] {
        var result = environment.filter { !$0.key.hasPrefix("FOCUS_STUDIO_") }
        let own = (executable as NSString).deletingLastPathComponent
        let appPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let path = ([own] + shellPath + appPath + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        result["PATH"] = path.joined(separator: ":")
        result["HOME"] = result["HOME"] ?? homeDirectory
        return result
    }

    private var shellEnvironment: [String: String] {
        var result: [String: String] = ["HOME": homeDirectory, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"] {
            if let value = environment[key] { result[key] = value }
        }
        result["TERM"] = "dumb"
        return result
    }

    /// Reads the marker-delimited answer; anything the shell's startup files
    /// print around it is ignored.
    static func parseLoginShellOutput(_ output: String) -> ([MCPClientKind: String], [String]) {
        var section: String?
        var found: [MCPClientKind: String] = [:]
        var path: [String] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            switch line {
            case "__FOCUS_STUDIO_CLAUDE__", "__FOCUS_STUDIO_CODEX__", "__FOCUS_STUDIO_PATH__":
                section = line
                continue
            default:
                break
            }
            guard let section, !line.isEmpty else { continue }
            switch section {
            case "__FOCUS_STUDIO_CLAUDE__" where line.hasPrefix("/") && found[.claudeCode] == nil:
                found[.claudeCode] = line
            case "__FOCUS_STUDIO_CODEX__" where line.hasPrefix("/") && found[.codex] == nil:
                found[.codex] = line
            case "__FOCUS_STUDIO_PATH__":
                path += line.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
            default:
                break
            }
        }
        return (found, path)
    }

    static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}

/// Settings › AI tools › Connect: finds the Claude Code and Codex CLIs,
/// shows whether Focus Studio is registered with each, and registers this
/// app's helper with one click (replacing a registration that points at
/// another copy: remove, then add).
@MainActor
final class MCPClientConnector: ObservableObject {
    nonisolated static let serverName = "focus-studio"

    @Published private(set) var statuses: [MCPClientKind: MCPClientStatus] = [:]
    @Published private(set) var isLocating = false

    let helperPath: String
    let search: MCPCLISearch
    let commandTimeout: TimeInterval
    private var located: MCPCLISearch.Result?

    init(helperPath: String, search: MCPCLISearch, commandTimeout: TimeInterval = 30) {
        self.helperPath = helperPath
        self.search = search
        self.commandTimeout = commandTimeout
    }

    /// Contents/MacOS/focus-studio-mcp next to this app's executable (in a
    /// development build, the helper next to the app's binary).
    static func bundledHelperPath(bundle: Bundle = .main) -> String {
        let folder = bundle.executableURL?.deletingLastPathComponent() ?? bundle.bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        return folder.appendingPathComponent("focus-studio-mcp").standardizedFileURL.path
    }

    /// Why registering this copy's helper would not last, if it would not.
    var helperWarning: String? {
        if helperPath.contains("/AppTranslocation/") {
            return "macOS is running Focus Studio from a temporary location. Move Focus Studio to the Applications folder and open it from there before connecting."
        }
        if helperPath.hasPrefix("/Volumes/") {
            return "Focus Studio is running from a disk image. Copy it to the Applications folder and open it from there before connecting."
        }
        if !MCPCLISearch.isExecutableFile(helperPath) {
            return "focus-studio-mcp was not found in this copy of Focus Studio."
        }
        return nil
    }

    func status(for kind: MCPClientKind) -> MCPClientStatus {
        statuses[kind] ?? MCPClientStatus()
    }

    func commandLine(for kind: MCPClientKind) -> String {
        kind.commandLine(helperPath: helperPath)
    }

    /// Finds the CLIs again and asks each for its registration.
    func refresh() async {
        guard !isLocating else { return }
        isLocating = true
        for kind in MCPClientKind.allCases { statuses[kind, default: MCPClientStatus()].state = .checking }
        let found = await search.locate()
        located = found
        isLocating = false
        await withTaskGroup(of: Void.self) { group in
            for kind in MCPClientKind.allCases {
                group.addTask { @MainActor in await self.updateStatus(kind) }
            }
        }
    }

    /// Registers this app's helper with `kind`, replacing another command.
    func connect(_ kind: MCPClientKind) async {
        if located == nil { await refresh() }
        guard let executable = located?.executables[kind] else {
            statuses[kind] = MCPClientStatus(cliPath: nil, state: .cliNotFound)
            return
        }
        statuses[kind, default: MCPClientStatus()].state = .checking
        statuses[kind]?.note = nil
        let current = await registration(kind, executable: executable)
        switch current {
        case .connected:
            statuses[kind] = MCPClientStatus(cliPath: executable, state: current)
            return
        case let .connectedElsewhere(existing):
            let removed = await run(executable, kind.removeArguments(scope: existing.scope))
            guard removed.succeeded else {
                statuses[kind] = MCPClientStatus(cliPath: executable, state: .failed(removed.failureText))
                return
            }
        case .notConnected:
            break
        case .failed, .cliNotFound, .unknown, .checking:
            statuses[kind] = MCPClientStatus(cliPath: executable, state: current)
            return
        }
        let added = await run(executable, kind.addArguments(helperPath: helperPath))
        guard added.succeeded else {
            statuses[kind] = MCPClientStatus(cliPath: executable, state: .failed(added.failureText))
            return
        }
        let after = await registration(kind, executable: executable)
        var status = MCPClientStatus(cliPath: executable, state: after)
        if case .connected = after {
            status.note = kind == .claudeCode
                ? "Connected. Start a new Claude Code session to use Focus Studio."
                : "Connected. Start a new Codex session to use Focus Studio."
        } else if case .notConnected = after {
            status.state = .failed("\(kind.executableName) reported success, but Focus Studio is not in its list.")
        }
        statuses[kind] = status
    }

    private func updateStatus(_ kind: MCPClientKind) async {
        guard let executable = located?.executables[kind] else {
            statuses[kind] = MCPClientStatus(cliPath: nil, state: .cliNotFound)
            return
        }
        let note = statuses[kind]?.note
        statuses[kind] = MCPClientStatus(cliPath: executable, state: await registration(kind, executable: executable), note: note)
    }

    private func run(_ executable: String, _ arguments: [String]) async -> CLIRunResult {
        await CLIRunner.run(
            executable, arguments: arguments,
            environment: search.commandEnvironment(for: executable, shellPath: located?.shellPath ?? []),
            currentDirectory: search.homeDirectory, timeout: commandTimeout
        )
    }

    private func registration(_ kind: MCPClientKind, executable: String) async -> MCPClientConnectionState {
        let result = await run(executable, kind.getArguments)
        if !result.succeeded {
            let text = result.standardOutput + "\n" + result.standardError
            if !result.timedOut, result.launchError == nil, text.range(of: "No MCP server", options: .caseInsensitive) != nil {
                return .notConnected
            }
            return .failed(result.failureText)
        }
        guard let registration = Self.parseRegistration(kind, output: result.standardOutput) else {
            return .failed("Could not read what \(kind.executableName) mcp get printed.")
        }
        return Self.sameFile(registration.command, helperPath) && registration.arguments.isEmpty
            ? .connected(registration) : .connectedElsewhere(registration)
    }

    /// Reads `claude mcp get` text or `codex mcp get --json`.
    static func parseRegistration(_ kind: MCPClientKind, output: String) -> MCPClientRegistration? {
        if kind == .codex,
           let data = output.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let json = AIJSONValue(jsonObject: object),
           let command = json["transport"]?["command"]?.stringValue {
            let arguments = json["transport"]?["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return MCPClientRegistration(command: command, arguments: arguments, scope: nil)
        }
        var command: String?
        var arguments: [String] = []
        var scope: String?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            func value(_ label: String) -> String? {
                guard line.lowercased().hasPrefix(label.lowercased() + ":") else { return nil }
                return line.dropFirst(label.count + 1).trimmingCharacters(in: .whitespaces)
            }
            if let text = value("Command") { command = text }
            if let text = value("Args"), !text.isEmpty, text != "-" { arguments = text.split(separator: " ").map(String.init) }
            if let text = value("Scope") {
                let lower = text.lowercased()
                scope = lower.hasPrefix("user") ? "user" : lower.hasPrefix("local") ? "local" : lower.hasPrefix("project") ? "project" : nil
            }
        }
        guard let command, !command.isEmpty else { return nil }
        return MCPClientRegistration(command: command, arguments: arguments, scope: scope)
    }

    static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || canonicalPath(lhs) == canonicalPath(rhs)
    }

    /// `path` with symlinks resolved as far as it exists (a registered copy
    /// may have been deleted), e.g. /tmp/x → /private/tmp/x.
    static func canonicalPath(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while existing.path != "/" {
            if let resolved = realpath(existing.path, nil) {
                defer { free(resolved) }
                return missing.reversed().reduce(URL(fileURLWithPath: String(cString: resolved))) { $0.appendingPathComponent($1) }.path
            }
            missing.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        return path
    }
}
