import AppKit
import FocusStudioAutomation
import Foundation

/// Opens Focus Studio.app when a tool call finds it not running.
protocol AppLaunching: Sendable {
    /// Asks the system to open the app at `appURL` in the background and
    /// returns once it has (or has found it already running). Throws when
    /// the system refuses. `environment` applies only to a new instance.
    func launch(appAt appURL: URL, environment: [String: String]) async throws
    /// Whether the app at `appURL` is running now, for messages.
    func isRunning(appAt appURL: URL) -> Bool
    /// The bundle URLs of the Focus Studio copies running now other than
    /// `appURL` (same bundle identifier, another location).
    func otherRunningCopies(than appURL: URL) -> [URL]
}

/// Opens the app through LaunchServices (`NSWorkspace`), by its bundle URL:
/// without activating it (the person's keyboard focus stays where it is),
/// without adding it to Recent Items, reusing the instance of that copy when
/// it runs. The app is never spawned as a child of the helper, so it keeps
/// its own identity for macOS privacy permissions (screen recording) instead
/// of inheriting the terminal's.
///
/// Several copies of Focus Studio share one bundle identifier (a build in
/// dist/, one in /Applications) and one library. The helper opens its own
/// copy only when no other copy runs (``SocketAppForwarder`` checks
/// ``otherRunningCopies(than:)`` first), and LaunchServices may still hand
/// back a copy that started meanwhile (running-application substitution
/// stays on), so two copies never edit the same library at once.
struct WorkspaceAppLauncher: AppLaunching {
    func launch(appAt appURL: URL, environment: [String: String]) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        if !environment.isEmpty { configuration.environment = environment }
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    func isRunning(appAt appURL: URL) -> Bool {
        let target = Self.canonicalPath(appURL)
        return runningCopies().contains { Self.canonicalPath($0) == target }
    }

    func otherRunningCopies(than appURL: URL) -> [URL] {
        let target = Self.canonicalPath(appURL)
        return runningCopies().filter { Self.canonicalPath($0) != target }
    }

    private func runningCopies() -> [URL] {
        NSRunningApplication.runningApplications(withBundleIdentifier: HelperIdentity.appBundleIdentifier).compactMap(\.bundleURL)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// How the helper reaches the app, read from the environment the client
/// starts it with.
struct AppConnectionSettings: Sendable {
    /// `FOCUS_STUDIO_MCP_NO_LAUNCH=1`: never open the app; a call made while
    /// it is not running says so (tests, and people who want to open it themselves).
    static let noLaunchVariable = "FOCUS_STUDIO_MCP_NO_LAUNCH"
    /// `FOCUS_STUDIO_APP_PATH`: the Focus Studio.app to open, instead of the
    /// one the helper ships in (a development build of the helper runs from
    /// .build, outside any app).
    static let appPathVariable = "FOCUS_STUDIO_APP_PATH"
    /// Development builds only: the variables passed on to an app the helper
    /// opens, so a QA run with its own socket reaches the app it started.
    /// Release builds pass nothing: what the app does is not for an MCP
    /// client's configuration to change.
    static let forwardedTestVariables = [ControlChannel.socketPathVariable]

    #if DEBUG
    static let isDevelopmentBuild = true
    #else
    static let isDevelopmentBuild = false
    #endif

    enum Launch: Equatable, Sendable {
        /// Opens this app when nothing listens on the socket.
        case app(URL)
        /// `FOCUS_STUDIO_MCP_NO_LAUNCH=1`.
        case disabled
        /// There is no app to open; the reason is for the model.
        case unavailable(String)
    }

    /// Where the app listens, or why there is no usable path.
    var socket: Result<ControlSocketLocation, ControlChannelError>
    var launch: Launch
    /// Set in an app the helper opens (only when a new instance starts).
    var launchEnvironment: [String: String]
    /// After asking the system to open the app, how long to keep trying to
    /// connect (every ``pollInterval``).
    var launchTimeout: TimeInterval = 30
    var pollInterval: TimeInterval = 0.25
    /// How long the app gets to answer `hello`: it does once its library has loaded.
    var helloTimeout: TimeInterval = 30
    /// How often a call waiting for the app to start or load reports progress
    /// (when its request carried a progress token).
    var heartbeatInterval: TimeInterval = 1
    /// After asking the app to cancel a call, how long to wait for its answer.
    var cancelReplyTimeout: TimeInterval = 5
    /// Whether "Allow AI tools to control Focus Studio" is on, checked before
    /// opening the app (an app that is off would only refuse the call). The
    /// helper reads the app's preferences (``readAutomationEnabled()``);
    /// tests set their own.
    var isAutomationEnabled: @Sendable () -> Bool = { true }

    init(socket: Result<ControlSocketLocation, ControlChannelError>, launch: Launch, launchEnvironment: [String: String] = [:]) {
        self.socket = socket
        self.launch = launch
        self.launchEnvironment = launchEnvironment
    }

    init(environment: [String: String], identity: HelperIdentity, includeTestVariables: Bool = isDevelopmentBuild) {
        let socket: Result<ControlSocketLocation, ControlChannelError>
        do {
            socket = .success(try ControlChannel.socketLocation(environment: environment))
        } catch let error as ControlChannelError {
            socket = .failure(error)
        } catch {
            socket = .failure(.socketPathTooLong(error.localizedDescription))
        }
        self.init(
            socket: socket,
            launch: Self.launch(environment: environment, identity: identity),
            launchEnvironment: includeTestVariables ? environment.filter { Self.forwardedTestVariables.contains($0.key) } : [:]
        )
        isAutomationEnabled = { Self.readAutomationEnabled() }
    }

    /// The app's switch, read (never written) from its preferences; a
    /// missing value means on, as in the app. Read at each launch decision,
    /// so turning it back on takes effect without restarting the helper.
    static func readAutomationEnabled() -> Bool {
        let value = CFPreferencesCopyAppValue(AutomationSwitch.preferenceKey as CFString, HelperIdentity.appBundleIdentifier as CFString)
        return (value as? Bool) ?? true
    }

    static func isSet(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return ["1", "true", "yes"].contains(value)
    }

    /// The app to open: `FOCUS_STUDIO_APP_PATH` when set (it must be a Focus
    /// Studio.app), else the app the helper ships in.
    static func launch(environment: [String: String], identity: HelperIdentity) -> Launch {
        if isSet(environment[noLaunchVariable]) { return .disabled }
        if let path = environment[appPathVariable], !path.isEmpty {
            guard path.hasPrefix("/") else {
                return .unavailable("\(appPathVariable) must be an absolute path to Focus Studio.app, not \(path).")
            }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard url.pathExtension == "app", let bundle = Bundle(url: url), bundle.bundleIdentifier == HelperIdentity.appBundleIdentifier else {
                return .unavailable("\(appPathVariable) is set to \(path), which is not a Focus Studio.app.")
            }
            return .app(url)
        }
        if let app = identity.appURL { return .app(app) }
        return .unavailable("This focus-studio-mcp does not run from inside Focus Studio.app, so it does not know which Focus Studio to open (set \(appPathVariable) to open one).")
    }
}
