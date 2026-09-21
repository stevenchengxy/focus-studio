import Foundation

/// Only non-secret connection preferences belong in the app's preferences.
/// Authentication is delegated to Codex and, for a separate account, macOS Keychain.
struct CodexConnectionPreferences: Codable, Equatable, Sendable {
    enum AccountScope: String, Codable, CaseIterable, Sendable {
        case focusStudio
        case existingCodex

        var title: String {
            switch self {
            case .focusStudio: return "Sign in for Focus Studio"
            case .existingCodex: return "Use existing Codex sign-in"
            }
        }
    }

    var executablePath = ""
    var modelID = ""
    var accountScope: AccountScope = .focusStudio

    static let defaultsKey = "codexDirector.connection.v1"

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data)
        else { return .init() }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    var normalized: Self {
        var value = self
        value.executablePath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        value.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }
}

struct CodexAvailableModel: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let defaultEffort: String?
    let isDefault: Bool
    let supportsImages: Bool

    init?(json: CodexJSONValue) {
        guard let value = json.objectValue,
              let id = value["model"]?.stringValue ?? value["id"]?.stringValue,
              value["hidden"]?.boolValue != true else { return nil }
        self.id = id
        title = value["displayName"]?.stringValue ?? id
        defaultEffort = value["defaultReasoningEffort"]?.stringValue
        isDefault = value["isDefault"]?.boolValue == true
        supportsImages = value["inputModalities"]?.arrayValue.map {
            $0.contains(.string("image"))
        } ?? true
    }
}

/// A semantic version parsed from `codex --version` output such as
/// `codex-cli 0.155.0-alpha.9.2`. Numeric components are compared first; a
/// pre-release suffix ranks below the release with the same numbers, so any
/// 0.155.x still beats 0.42.0.
struct CodexVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int
    var preRelease: String?

    init(major: Int, minor: Int, patch: Int, preRelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.preRelease = preRelease
    }

    /// Extracts the first `major.minor.patch[-pre.release]` found in `output`.
    init?(parsing output: String) {
        guard let match = output.firstMatch(of: #/(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z][0-9A-Za-z.-]*))?/#),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3)
        else { return nil }
        self.init(major: major, minor: minor, patch: patch, preRelease: match.4.map(String.init))
    }

    var numeric: (Int, Int, Int) { (major, minor, patch) }

    var description: String {
        let base = "\(major).\(minor).\(patch)"
        return preRelease.map { "\(base)-\($0)" } ?? base
    }

    static func < (lhs: CodexVersion, rhs: CodexVersion) -> Bool {
        if lhs.numeric != rhs.numeric { return lhs.numeric < rhs.numeric }
        switch (lhs.preRelease, rhs.preRelease) {
        case (nil, _): return false
        case (_?, nil): return true
        case let (left?, right?): return preReleasePrecedes(left, right)
        }
    }

    /// Semantic-versioning precedence: dot-separated identifiers compare
    /// numerically when both are numbers, numbers rank below words, and a
    /// shorter identifier list ranks below a longer one with the same prefix.
    private static func preReleasePrecedes(_ left: String, _ right: String) -> Bool {
        let lefts = left.split(separator: "."), rights = right.split(separator: ".")
        for (l, r) in zip(lefts, rights) {
            switch (Int(l), Int(r)) {
            case let (a?, b?): if a != b { return a < b }
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): if l != r { return l < r }
            }
        }
        return lefts.count < rights.count
    }
}

/// One Codex executable found on this Mac, with the version it reported.
struct CodexInstallation: Identifiable, Hashable, Sendable {
    /// The path as it was discovered. Symlinks are left unresolved so the user
    /// recognises it, but each resolved executable is listed only once.
    let path: String
    /// The first line printed by `codex --version`; empty when the probe failed.
    let versionString: String
    /// `nil` when the executable did not run, timed out, or printed no version.
    /// Such installations rank last and are launched only if nothing else exists.
    let version: CodexVersion?
    /// The newest installation, which automatic detection launches.
    var isRecommended: Bool

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var numericVersion: (Int, Int, Int)? { version?.numeric }
}

enum CodexExecutableDiscovery {
    /// `codex --version` normally answers within a few milliseconds; a shim
    /// that has to start Node takes a few hundred.
    static let versionProbeTimeout: TimeInterval = 3

    /// Environment keys that must never reach a probe or a shared Codex home.
    static let credentialEnvironmentKeys = ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"]

    /// Synchronous resolution. A non-empty `explicitPath` is authoritative and
    /// throws `invalidExecutable` when it cannot be launched. An empty path
    /// falls back to the first candidate on disk without comparing versions;
    /// prefer `resolveExecutable`, which launches the newest installation.
    static func resolve(
        explicitPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let explicit = try resolveExplicit(path: explicitPath, fileManager: fileManager) { return explicit }
        guard let found = candidatePaths(environment: environment, fileManager: fileManager).first else {
            throw CodexDirectorServiceError.executableNotFound
        }
        return URL(fileURLWithPath: found)
    }

    /// The explicit path when one is set, otherwise the newest installation.
    static func resolveExecutable(
        explicitPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        probeTimeout: TimeInterval = versionProbeTimeout
    ) async throws -> URL {
        if let explicit = try resolveExplicit(path: explicitPath, fileManager: fileManager) { return explicit }
        return try await resolveAutomatic(environment: environment, fileManager: fileManager, probeTimeout: probeTimeout)
    }

    /// Probes every candidate and launches the highest version. Candidates that
    /// fail to answer `--version` are chosen only when nothing else exists.
    static func resolveAutomatic(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        searchesStandardLocations: Bool = true,
        probeTimeout: TimeInterval = versionProbeTimeout
    ) async throws -> URL {
        let installations = await installations(
            environment: environment, fileManager: fileManager,
            searchesStandardLocations: searchesStandardLocations, probeTimeout: probeTimeout
        )
        guard let best = installations.first else { throw CodexDirectorServiceError.executableNotFound }
        return best.url
    }

    /// Every executable candidate with its reported version, newest first.
    /// Probes run concurrently and off the main actor; each is bounded by
    /// `probeTimeout` and never sees the caller's API credentials.
    static func installations(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        searchesStandardLocations: Bool = true,
        probeTimeout: TimeInterval = versionProbeTimeout
    ) async -> [CodexInstallation] {
        let paths = candidatePaths(
            environment: environment, fileManager: fileManager, searchesStandardLocations: searchesStandardLocations
        )
        var probed: [(order: Int, installation: CodexInstallation)] = []
        await withTaskGroup(of: (Int, CodexInstallation).self) { group in
            for (order, path) in paths.enumerated() {
                group.addTask {
                    let output = await probeVersion(path: path, environment: environment, timeout: probeTimeout)
                    let firstLine = output?.split(whereSeparator: \.isNewline).first
                    return (order, CodexInstallation(
                        path: path,
                        versionString: firstLine.map { $0.trimmingCharacters(in: .whitespaces) } ?? "",
                        version: output.flatMap(CodexVersion.init(parsing:)),
                        isRecommended: false
                    ))
                }
            }
            for await result in group { probed.append(result) }
        }
        let unknown = CodexVersion(major: 0, minor: 0, patch: 0)
        var ordered = probed.sorted { lhs, rhs in
            let left = lhs.installation.version ?? unknown, right = rhs.installation.version ?? unknown
            return left != right ? left > right : lhs.order < rhs.order
        }.map(\.installation)
        if ordered.first?.version != nil { ordered[0].isRecommended = true }
        return ordered
    }

    /// Executable candidates in search order, de-duplicated by resolved path:
    /// `CODEX_EXECUTABLE`, every PATH entry, then the desktop app bundles and
    /// the usual CLI install locations.
    static func candidatePaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        searchesStandardLocations: Bool = true
    ) -> [String] {
        var candidates: [String] = []
        if let path = environment["CODEX_EXECUTABLE"], !path.isEmpty { candidates.append(path) }
        candidates += (environment["PATH"] ?? "").split(separator: ":")
            .map { String($0) + "/codex" }
        if searchesStandardLocations {
            let home = fileManager.homeDirectoryForCurrentUser
            candidates += [
                "/Applications/Codex.app/Contents/Resources/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
                home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path,
                "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                home.appendingPathComponent(".local/bin/codex").path,
                home.appendingPathComponent(".npm-global/bin/codex").path
            ]
        }
        var seen = Set<String>()
        return candidates.filter { path in
            guard isExecutableFile(path, fileManager: fileManager) else { return false }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            return seen.insert(resolved).inserted
        }
    }

    /// PATH for launching a Codex executable: its own directory first so a
    /// shim can find its runtime, then the usual install locations.
    static func launchPath(for executableURL: URL, environment: [String: String]) -> String {
        ([executableURL.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
    }

    private static func resolveExplicit(path: String, fileManager: FileManager) throws -> URL? {
        let explicitPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !explicitPath.isEmpty else { return nil }
        let expanded = (explicitPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), isExecutableFile(expanded, fileManager: fileManager) else {
            throw CodexDirectorServiceError.invalidExecutable(explicitPath)
        }
        return URL(fileURLWithPath: expanded)
    }

    /// The trimmed stdout of `<path> --version`, or nil when the executable
    /// failed to start, exited with an error, or exceeded `timeout`.
    private static func probeVersion(path: String, environment: [String: String], timeout: TimeInterval) async -> String? {
        var probeEnvironment = environment
        probeEnvironment["PATH"] = launchPath(for: URL(fileURLWithPath: path), environment: environment)
        for key in credentialEnvironmentKeys { probeEnvironment.removeValue(forKey: key) }
        return await withCheckedContinuation { continuation in
            CodexVersionProbe(path: path, environment: probeEnvironment, timeout: timeout)
                .start { continuation.resume(returning: $0) }
        }
    }

    private static func isExecutableFile(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && fileManager.isExecutableFile(atPath: path)
    }
}

/// Runs `codex --version` with a hard deadline. The reader blocks a private
/// dispatch queue rather than a Swift concurrency thread, and the completion
/// fires exactly once even when the executable hangs or leaves a child holding
/// the pipe open.
private final class CodexVersionProbe: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var completion: (@Sendable (String?) -> Void)?

    init(path: String, environment: [String: String], timeout: TimeInterval) {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        self.timeout = timeout
    }

    func start(completion: @escaping @Sendable (String?) -> Void) {
        self.completion = completion
        do {
            try process.run()
        } catch {
            finish(nil)
            return
        }
        DispatchQueue(label: "app.focusstudio.codex.version-probe").async { [self] in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
            finish(succeeded ? String(decoding: data, as: UTF8.self) : nil)
        }
        let timer = DispatchQueue.global(qos: .utility)
        timer.asyncAfter(deadline: .now() + timeout) { [self] in
            guard finish(nil), process.isRunning else { return }
            process.terminate()
            timer.asyncAfter(deadline: .now() + 1) { [self] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    /// Returns true when this call delivered the result, false if one already had.
    @discardableResult
    private func finish(_ result: String?) -> Bool {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        guard let completion else { return false }
        completion(result)
        return true
    }
}
