import FocusStudioCore
import Foundation

/// One row of the assistant transcript. Tool and status rows are rendered
/// differently from chat bubbles but share the same list so the order in
/// which things happened is preserved.
struct AIAssistantMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
        /// A tool result (text plus generated files) that is also fed back to the model.
        case tool
        /// Transient progress such as "Seedance generating… 40 s".
        case status
        case error
    }

    var id: UUID
    var role: Role
    var text: String
    var attachments: [URL]
    var toolName: String?
    var timestamp: Date

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
protocol AssistantConversationResetting: TextCompletionProviding {
    func resetConversation() async
}

/// Shown before a paid call runs. Prices are budgeting estimates in 人民币;
/// the Volcengine console bill is authoritative.
struct AIToolCostEstimate: Equatable, Sendable {
    var yuan: Double
    var summary: String

    init(yuan: Double, summary: String) {
        self.yuan = yuan
        self.summary = summary
    }
}

struct AIToolResult: Equatable, Sendable {
    /// Plain text for the user and the model. Keep it short and factual.
    var text: String
    /// Files the tool produced or wants to show (images, videos, exports).
    var attachments: [URL]

    init(text: String, attachments: [URL] = []) {
        self.text = text
        self.attachments = attachments
    }
}

/// Everything a tool may touch. The integrator builds one for the app; tools
/// never reach into app state any other way, which keeps them testable.
/// The project, the assets folder and the language are resolved on every
/// access so one long-lived session follows whatever the user has open.
struct AIAssistantContext: Sendable {
    /// Where generated files land right now: the open project's `ai/` folder or
    /// the shared AI Assets folder. Created on first use via ``ensuredAssetsDirectory()``.
    var assetsDirectory: URL {
        get { assetsDirectoryProvider() }
        set { let fixed = newValue; assetsDirectoryProvider = { fixed } }
    }
    /// "zh-Hans" or "en": the language the model should answer in.
    var uiLanguage: String {
        get { uiLanguageProvider() }
        set { let fixed = newValue; uiLanguageProvider = { fixed } }
    }
    var readProject: @MainActor @Sendable () -> RecordingProject?
    var updateProject: @MainActor @Sendable ((inout RecordingProject) -> Void) -> Void
    /// Read on the main actor when a paid tool runs, so a key added in Settings
    /// after the session was created is picked up.
    var arkAPIKey: @MainActor @Sendable () -> String?
    var arkBaseURL: URL
    /// The app itself (recording, library, editor). Nil in unit tests that only
    /// exercise project tools; app tools then report that control is unavailable.
    var app: (any AppControlling)?

    private var assetsDirectoryProvider: @Sendable () -> URL
    private var uiLanguageProvider: @Sendable () -> String

    init(
        assetsDirectory: URL,
        uiLanguage: String,
        readProject: @escaping @MainActor @Sendable () -> RecordingProject?,
        updateProject: @escaping @MainActor @Sendable ((inout RecordingProject) -> Void) -> Void,
        arkAPIKey: @escaping @MainActor @Sendable () -> String?,
        arkBaseURL: URL = URL(string: "https://ark.cn-beijing.volces.com/api/v3")!,
        app: (any AppControlling)? = nil
    ) {
        self.init(
            assetsDirectoryProvider: { assetsDirectory },
            uiLanguageProvider: { uiLanguage },
            readProject: readProject,
            updateProject: updateProject,
            arkAPIKey: arkAPIKey,
            arkBaseURL: arkBaseURL,
            app: app
        )
    }

    init(
        assetsDirectoryProvider: @escaping @Sendable () -> URL,
        uiLanguageProvider: @escaping @Sendable () -> String,
        readProject: @escaping @MainActor @Sendable () -> RecordingProject?,
        updateProject: @escaping @MainActor @Sendable ((inout RecordingProject) -> Void) -> Void,
        arkAPIKey: @escaping @MainActor @Sendable () -> String?,
        arkBaseURL: URL = URL(string: "https://ark.cn-beijing.volces.com/api/v3")!,
        app: (any AppControlling)? = nil
    ) {
        self.assetsDirectoryProvider = assetsDirectoryProvider
        self.uiLanguageProvider = uiLanguageProvider
        self.readProject = readProject
        self.updateProject = updateProject
        self.arkAPIKey = arkAPIKey
        self.arkBaseURL = arkBaseURL
        self.app = app
    }

    var isChinese: Bool { uiLanguage.lowercased().hasPrefix("zh") }

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
protocol AIAssistantTool: Sendable {
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
    func costEstimate(arguments: [String: Any]) -> AIToolCostEstimate? { nil }
}

/// Argument problems are reported to the model in plain words so it can fix
/// the call instead of giving up.
enum AIToolError: LocalizedError, Equatable {
    case invalidArgument(String)
    case fileNotFound(String)
    case noProject
    case failed(String)
    /// The context has no app controller (unit tests) so app tools cannot run.
    case appUnavailable
    /// A wait for the app (countdown, stop, export) exceeded its time limit.
    case timedOut(String)

    var errorDescription: String? {
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
