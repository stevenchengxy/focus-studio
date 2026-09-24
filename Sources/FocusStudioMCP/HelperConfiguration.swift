import Darwin
import Foundation

/// How the helper introduces itself in `initialize`.
struct HelperIdentity: Equatable, Sendable {
    static let serverName = "focus-studio"
    static let serverTitle = "Focus Studio"
    /// The bundle identifier of Focus Studio.app, whose version the helper reports.
    static let appBundleIdentifier = "com.local.focusstudio"
    /// Reported when the helper does not run from Focus Studio.app, such as
    /// a `swift build` product under .build.
    static let developmentVersion = "0.0.0-dev"

    let name: String
    let title: String
    let version: String
    /// The Focus Studio.app this helper ships in, when it runs from its
    /// Contents/MacOS; nil otherwise.
    let appURL: URL?

    /// The helper's identity from where its executable really is: when that
    /// is Focus Studio.app/Contents/MacOS, it reports the app's
    /// CFBundleShortVersionString and the app's location, also when started
    /// through a symlink (a PATH shortcut, a Homebrew cask `binary`), which
    /// `Bundle.main` does not follow. Otherwise it goes by `Bundle.main`,
    /// and reports ``developmentVersion`` outside the app.
    static func resolve() -> HelperIdentity {
        if let executable = realExecutableURL(), let app = enclosingAppURL(of: executable), let bundle = Bundle(url: app) {
            let identity = resolve(bundle: bundle, appURL: app)
            if identity.appURL != nil { return identity }
        }
        return resolve(bundle: .main)
    }

    /// For an executable in Focus Studio.app/Contents/MacOS, `Bundle.main`
    /// is the app bundle (Foundation finds the main bundle from the
    /// executable's location, whatever its file name), so the helper reports
    /// the app's CFBundleShortVersionString. Anywhere else it reports
    /// ``developmentVersion``. `appURL` overrides the bundle's own URL
    /// (Foundation shortens /private/tmp to /tmp, for example).
    static func resolve(bundle: Bundle, appURL: URL? = nil) -> HelperIdentity {
        let isApp = bundle.bundleURL.pathExtension == "app" && bundle.bundleIdentifier == appBundleIdentifier
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if isApp, let version, !version.isEmpty {
            return HelperIdentity(name: serverName, title: serverTitle, version: version, appURL: appURL ?? bundle.bundleURL)
        }
        return HelperIdentity(name: serverName, title: serverTitle, version: developmentVersion, appURL: nil)
    }

    /// This process's executable with every symlink resolved
    /// (_NSGetExecutablePath, then realpath).
    static func realExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&path, &size) == 0, let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// X.app for an executable at X.app/Contents/MacOS/<name>; nil otherwise.
    static func enclosingAppURL(of executable: URL) -> URL? {
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension == "app" else { return nil }
        return app
    }
}

/// Severity of a helper log line; the same levels as swift-log, which the
/// SDK adapter writes them through (to standard error).
enum HelperLogLevel: Int, Comparable, CaseIterable, Sendable {
    case trace, debug, info, notice, warning, error, critical

    static func < (lhs: HelperLogLevel, rhs: HelperLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    init?(name: String) {
        guard let level = Self.allCases.first(where: { "\($0)" == name.lowercased() }) else { return nil }
        self = level
    }
}

/// Where the helper's own log lines go. Standard error only: standard output
/// carries the protocol.
struct HelperLog: Sendable {
    let level: HelperLogLevel
    let emit: @Sendable (HelperLogLevel, String) -> Void

    /// Drops everything; for tests.
    static let silent = HelperLog(level: .critical) { _, _ in }

    func log(_ level: HelperLogLevel, _ message: @autoclosure () -> String) {
        guard level >= self.level else { return }
        emit(level, message())
    }

    func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    func warning(_ message: @autoclosure () -> String) { log(.warning, message()) }
    func error(_ message: @autoclosure () -> String) { log(.error, message()) }
}

/// Settings read from the environment the client starts the helper with.
struct HelperSettings: Sendable {
    /// `FOCUS_STUDIO_MCP_LOG_LEVEL`: trace, debug, info, notice, warning
    /// (the default), error or critical.
    static let logLevelVariable = "FOCUS_STUDIO_MCP_LOG_LEVEL"
    static let defaultLogLevel = HelperLogLevel.warning

    var logLevel: HelperLogLevel
    /// After standard input closes, how long the calls already read get to
    /// finish on their own, so a script that pipes requests and closes stdin
    /// still gets real answers.
    var settleTime: TimeInterval
    /// Then, how long the calls still running get to answer once cancelled,
    /// and again how long the answers get to be written, before the helper
    /// exits. At most settleTime + 2 × cancelTime in all.
    var cancelTime: TimeInterval

    init(logLevel: HelperLogLevel = defaultLogLevel, settleTime: TimeInterval = 2, cancelTime: TimeInterval = 1) {
        self.logLevel = logLevel
        self.settleTime = settleTime
        self.cancelTime = cancelTime
    }

    init(environment: [String: String]) {
        self.init(logLevel: environment[Self.logLevelVariable].flatMap(HelperLogLevel.init(name:)) ?? Self.defaultLogLevel)
    }
}
