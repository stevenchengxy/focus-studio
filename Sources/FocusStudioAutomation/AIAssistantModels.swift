import FocusStudioCore
import Foundation

/// One row of the assistant transcript. Tool and status rows are rendered
/// differently from chat bubbles but share the same list so the order in
/// which things happened is preserved.
public struct AIAssistantMessage: Identifiable, Equatable, Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        /// A tool result (text plus generated files) that is also fed back to the model.
        case tool
        /// Transient progress such as "Seedance generating… 40 s".
        case status
        case error
    }

    public var id: UUID
    public var role: Role
    public var text: String
    public var attachments: [URL]
    public var toolName: String?
    public var timestamp: Date

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        attachments: [URL] = [],
        toolName: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.toolName = toolName
        self.timestamp = timestamp
    }
}

/// Providers with hidden server-side context must discard it when the local
/// conversation or selected provider changes. Stateless HTTP providers need no hook.
public protocol AssistantConversationResetting: TextCompletionProviding {
    func resetConversation() async
}

/// Shown before a paid call runs. Prices are budgeting estimates in 人民币;
/// the Volcengine console bill is authoritative.
public struct AIToolCostEstimate: Equatable, Sendable {
    public var yuan: Double
    public var summary: String

    init(yuan: Double, summary: String) {
        self.yuan = yuan
        self.summary = summary
    }
}

public struct AIToolResult: Equatable, Sendable {
    /// Plain text for the user and the model. Keep it short and factual.
    public var text: String
    /// Files the tool produced or wants to show (images, videos, exports).
    public var attachments: [URL]
    /// The same outcome for a program: ids, absolute paths, counts, durations
    /// and sizes. External clients receive it as structured content; the
    /// in-app assistant shows only the text.
    public var data: AIJSONValue?

    public init(text: String, attachments: [URL] = [], data: AIJSONValue? = nil) {
        self.text = text
        self.attachments = attachments
        self.data = data
    }
}

/// Measured progress of a long call: `completed` out of `total` (nil when the
/// total is unknown) with an optional message, e.g. `0.42, 1, "Exporting… 42%"`.
public typealias AIToolProgressHandler = @Sendable (_ completed: Double, _ total: Double?, _ message: String?) -> Void

/// Everything a tool may touch. The integrator builds one for the app; tools
/// never reach into app state any other way, which keeps them testable.
/// The project, the assets folder and the language are resolved on every
/// access so one long-lived session follows whatever the user has open.
public struct AIAssistantContext: Sendable {
    /// Where generated files land right now: the open project's `ai/` folder or
    /// the shared AI Assets folder. Created on first use via ``ensuredAssetsDirectory()``.
    public var assetsDirectory: URL {
        get { assetsDirectoryProvider() }
        set { let fixed = newValue; assetsDirectoryProvider = { fixed } }
    }
    /// "zh-Hans" or "en": the language the model should answer in, and the
    /// language of every text a tool returns (results, progress, errors).
    /// The in-app assistant follows the UI language; an external call is English.
    public var uiLanguage: String {
        get { uiLanguageProvider() }
        set { let fixed = newValue; uiLanguageProvider = { fixed } }
    }
    public var readProject: @MainActor @Sendable () -> RecordingProject?
    /// Applies a change to the open project. Throws, writing nothing, when the
    /// app cannot take the edit (the editor closed, a library operation is
    /// running) or when the change itself throws, so a tool never reports an
    /// edit that did not happen. Tools call it through `AIToolSupport.edit`.
    public var updateProject: @MainActor @Sendable ((inout RecordingProject) throws -> Void) throws -> Void
    /// Read on the main actor when a paid tool runs, so a key added in Settings
    /// after the session was created is picked up.
    var arkAPIKey: @MainActor @Sendable () -> String?
    var arkBaseURL: URL
    /// The projects library root. Exports never write inside it except into
    /// the open project's `ai/` folder. Nil when unknown (unit tests).
    public var projectsDirectory: URL?
    /// The app itself (recording, library, editor). Nil in unit tests that only
    /// exercise project tools; app tools then report that control is unavailable.
    public var app: (any AppControlling)?
    /// The caller's current directory (an MCP client's working directory).
    /// Relative input paths are looked up there first; relative output paths
    /// are written there. Nil or "/" means there is none.
    public var workingDirectory: URL?
    /// The call comes from outside the app (an MCP client). A relative output
    /// path then needs a working directory instead of falling back to the
    /// assets folder, which the caller cannot see.
    public var isExternal = false
    /// The project an external call targets (its `project_id`). When set,
    /// tools refuse to read or edit any other project, and read-only tools
    /// such as get_project look it up without opening it.
    public var projectID: UUID?
    /// Measured progress for long calls (exports), next to the text progress
    /// every tool gets. Nil when nobody listens.
    public var numericProgress: AIToolProgressHandler?
    /// Asks the person using the app whether an external start_recording may
    /// record sound their own recorder settings leave off (the app's prompt;
    /// tests pass their own). Only external calls ask; with none set, such a
    /// call is refused rather than recording sound unasked.
    public var recordingAudioConsent: AIRecordingAudioConsentHandler?

    private var assetsDirectoryProvider: @Sendable () -> URL
    private var uiLanguageProvider: @Sendable () -> String

    init(
        assetsDirectory: URL,
        uiLanguage: String,
        readProject: @escaping @MainActor @Sendable () -> RecordingProject?,
        updateProject: @escaping @MainActor @Sendable ((inout RecordingProject) throws -> Void) throws -> Void,
        arkAPIKey: @escaping @MainActor @Sendable () -> String?,
        arkBaseURL: URL = URL(string: "https://ark.cn-beijing.volces.com/api/v3")!,
        projectsDirectory: URL? = nil,
        app: (any AppControlling)? = nil
    ) {
        self.init(
            assetsDirectoryProvider: { assetsDirectory },
            uiLanguageProvider: { uiLanguage },
            readProject: readProject,
            updateProject: updateProject,
            arkAPIKey: arkAPIKey,
            arkBaseURL: arkBaseURL,
            projectsDirectory: projectsDirectory,
            app: app
        )
    }

    public init(
        assetsDirectoryProvider: @escaping @Sendable () -> URL,
        uiLanguageProvider: @escaping @Sendable () -> String,
        readProject: @escaping @MainActor @Sendable () -> RecordingProject?,
        updateProject: @escaping @MainActor @Sendable ((inout RecordingProject) throws -> Void) throws -> Void,
        arkAPIKey: @escaping @MainActor @Sendable () -> String?,
        arkBaseURL: URL = URL(string: "https://ark.cn-beijing.volces.com/api/v3")!,
        projectsDirectory: URL? = nil,
        app: (any AppControlling)? = nil
    ) {
        self.assetsDirectoryProvider = assetsDirectoryProvider
        self.uiLanguageProvider = uiLanguageProvider
        self.readProject = readProject
        self.updateProject = updateProject
        self.arkAPIKey = arkAPIKey
        self.arkBaseURL = arkBaseURL
        self.projectsDirectory = projectsDirectory
        self.app = app
    }

    var isChinese: Bool { uiLanguage.lowercased().hasPrefix("zh") }

    /// The language tool texts are written in, taken from ``uiLanguage`` on
    /// every call and never from the app's global setting, so an external
    /// call reads English while the app's own alerts stay in the UI language.
    public var resultLanguage: AppLanguage { AppLanguage(localeIdentifier: uiLanguage) }

    /// `L10n.tr` in ``resultLanguage``.
    func tr(_ key: String) -> String { L10n.tr(key, language: resultLanguage) }

    /// `L10n.format` in ``resultLanguage``.
    func format(_ key: String, _ arguments: CVarArg...) -> String {
        L10n.format(key, language: resultLanguage, arguments: arguments)
    }

    /// The working directory when there is a usable one (not nil, not "/").
    var usableWorkingDirectory: URL? {
        guard let workingDirectory, workingDirectory.isFileURL else { return nil }
        let standardized = workingDirectory.standardizedFileURL
        return standardized.path == "/" ? nil : standardized
    }

    /// Sends measured progress when someone listens.
    func reportProgress(_ completed: Double, total: Double?, message: String?) {
        numericProgress?(completed, total, message)
    }

    @discardableResult
    func ensuredAssetsDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        return assetsDirectory
    }

    /// A fresh output path such as `image-20260922-101500.png`, never clobbering an existing file.
    func newAssetURL(prefix: String, fileExtension: String, date: Date = Date()) throws -> URL {
        let directory = try ensuredAssetsDirectory()
        let stamp = Self.timestampFormatter.string(from: date)
        var candidate = directory.appendingPathComponent("\(prefix)-\(stamp)").appendingPathExtension(fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(prefix)-\(stamp)-\(counter)").appendingPathExtension(fileExtension)
            counter += 1
        }
        return candidate
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

/// A capability the assistant can invoke. `parametersSchema` is a JSON-schema
/// style dictionary shown to the model verbatim; `run` validates arguments
/// itself because the model may still send anything.
public protocol AIAssistantTool: Sendable {
    var name: String { get }
    var summary: String { get }
    var parametersSchema: [String: Any] { get }
    /// Non-nil means the call is paid and must be confirmed by the user first.
    func costEstimate(arguments: [String: Any]) -> AIToolCostEstimate?
    func run(
        arguments: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult
}

extension AIAssistantTool {
    public func costEstimate(arguments: [String: Any]) -> AIToolCostEstimate? { nil }
}

/// Argument problems are reported to the model in plain words so it can fix
/// the call instead of giving up.
public enum AIToolError: LocalizedError, Equatable {
    case invalidArgument(String)
    case fileNotFound(String)
    case noProject
    case failed(String)
    /// The context has no app controller (unit tests) so app tools cannot run.
    case appUnavailable
    /// A wait for the app (countdown, stop, export) exceeded its time limit.
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidArgument(message): return message
        case let .fileNotFound(path): return "File not found: \(path)"
        case .noProject: return "No recording is open. Open a project from the library (open_project) or record one first."
        case let .failed(message): return message
        case .appUnavailable: return "App control is not available in this context."
        case let .timedOut(message): return message
        }
    }
}
