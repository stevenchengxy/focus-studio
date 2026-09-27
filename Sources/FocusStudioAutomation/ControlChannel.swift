import Darwin
import Foundation

/// The control channel between focus-studio-mcp (the stdio MCP server an AI
/// client starts) and Focus Studio.app, which runs every tool.
///
/// **Transport.** A Unix domain stream socket, by default at
/// `~/Library/Application Support/FocusStudio/Control/control.sock`
/// (``socketLocation(environment:homeDirectory:temporaryDirectory:)``). The
/// app owns it: the directory is 0700 and never a symlink, the socket 0600,
/// and the app accepts only peers of its own user (`getpeereid`). There is no
/// network listener.
///
/// **Framing.** JSON-RPC 2.0 messages, one per line: UTF-8 JSON without raw
/// newlines, each followed by a line feed (0x0A). A trailing CR is dropped and
/// blank lines are skipped (``LineFramer``). A line longer than
/// ``maximumLineLength`` closes the connection.
///
/// **Messages** (protocol ``protocolVersion``; request ids are the helper's own
/// integers):
/// - `hello` request, helper → app: ``ControlHello``. The app answers with
///   ``ControlHelloReply`` once its library has loaded, so a reply means it is
///   ready. The app answers with its own protocol number even when it differs;
///   the helper decides what to tell its client, and the app then refuses
///   calls on that connection with ``ErrorCode/protocolMismatch``.
/// - `call` request, helper → app: ``ControlCall``, sent after hello, with
///   the seconds the helper already spent on it (`elapsed`, optional). The
///   result is an MCP `CallToolResult` (`{content, structuredContent?,
///   isError}`); an unknown tool is error ``ErrorCode/invalidParams`` with
///   `data.tool`; a call the helper cancelled is error ``ErrorCode/cancelled``.
///   Refusals (AI tools turned off in Settings, a client the person has not
///   approved) are `isError` results the model can read, and so is a call
///   whose time ran out while the approval prompt waited for the person, or
///   while it waited for its turn behind another call (`structuredContent.status`
///   "waiting_for_approval" or "waiting_for_turn": it did not run; call it
///   again). A new result shape, not a protocol change.
///   ``AutomationCallResult/init(controlReply:tool:)`` maps a reply back.
/// - `progress` notification, app → helper: ``ControlProgress``, only for a
///   call that carried `progress_token`; values always increase, and none
///   follows the call's reply.
/// - `cancel` notification, helper → app: ``ControlCancel``. The app cancels
///   the call and still replies (``ErrorCode/cancelled``, or the result if it
///   had already finished).
///
/// Closing the connection cancels that connection's running calls.
public enum ControlChannel {
    /// The internal protocol between the helper and the app, independent of
    /// the MCP protocol version the helper negotiates with its client. An
    /// optional field the other end may ignore (`call`'s `elapsed`) keeps
    /// the number; anything an older peer would misread changes it on both ends.
    public static let protocolVersion = 1
    /// Overrides the socket path, for tests and QA runs.
    public static let socketPathVariable = "FOCUS_STUDIO_CONTROL_SOCKET"
    public static let socketFileName = "control.sock"
    /// A longer line closes the connection. Generous: results carry an
    /// inline JPEG of at most 1 MiB of base64.
    public static let maximumLineLength = 16 * 1024 * 1024
    /// `sockaddr_un.sun_path` holds 104 bytes on macOS, the terminating NUL included.
    public static let maximumSocketPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    public enum Method {
        public static let hello = "hello"
        public static let call = "call"
        public static let progress = "progress"
        public static let cancel = "cancel"
    }

    /// JSON-RPC error codes on the control channel.
    public enum ErrorCode {
        public static let parseError = -32700
        public static let invalidRequest = -32600
        public static let methodNotFound = -32601
        /// Malformed params, or `call` for a tool the app does not offer (`data.tool` names it).
        public static let invalidParams = -32602
        public static let internalError = -32603
        /// A `call` before `hello`.
        public static let helloRequired = -32002
        /// The helper's `hello` named another protocol version.
        public static let protocolMismatch = -32003
        /// The app already serves as many connections as it accepts; the
        /// helper's first request gets this, then the connection closes.
        public static let tooManyConnections = -32004
        /// The helper cancelled the call.
        public static let cancelled = -32800
    }

    // MARK: - Socket location

    /// Where the app listens and the helper connects:
    /// 1. `$FOCUS_STUDIO_CONTROL_SOCKET`, an absolute path, when set;
    /// 2. otherwise `<home>/Library/Application Support/FocusStudio/Control/control.sock`,
    ///    with the home folder of the user's account record (not `$HOME`, which
    ///    a client may start the helper with changed);
    /// 3. otherwise, when that path does not fit `sun_path`, `control.sock` in
    ///    `FocusStudio-Control` in the user's private temporary folder
    ///    (`confstr(_CS_DARWIN_USER_TEMP_DIR)`).
    /// Throws when the override is relative or too long, or nothing fits.
    public static func socketLocation(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String? = nil,
        temporaryDirectory: String? = nil
    ) throws -> ControlSocketLocation {
        if let override = environment[socketPathVariable], !override.isEmpty {
            guard override.hasPrefix("/") else { throw ControlChannelError.relativeSocketPath(override) }
            guard fits(override) else { throw ControlChannelError.socketPathTooLong(override) }
            return ControlSocketLocation(path: override, source: .environment)
        }
        let home = homeDirectory ?? userHomeDirectory()
        let standard = (home as NSString).appendingPathComponent("Library/Application Support/FocusStudio/Control/\(socketFileName)")
        if fits(standard) { return ControlSocketLocation(path: standard, source: .applicationSupport) }
        if let temporary = temporaryDirectory ?? userTemporaryDirectory() {
            let short = (temporary as NSString).appendingPathComponent("FocusStudio-Control/\(socketFileName)")
            if short.hasPrefix("/"), fits(short) { return ControlSocketLocation(path: short, source: .temporaryDirectory) }
        }
        throw ControlChannelError.socketPathTooLong(standard)
    }

    static func fits(_ path: String) -> Bool {
        path.utf8.count <= maximumSocketPathLength && !path.utf8.contains(0)
    }

    /// The home folder in the user's account record.
    public static func userHomeDirectory() -> String {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4_096)
        if getpwuid_r(getuid(), &record, &buffer, buffer.count, &result) == 0, result != nil, let directory = record.pw_dir {
            let path = String(cString: directory)
            if path.hasPrefix("/") { return path }
        }
        return NSHomeDirectory()
    }

    /// The user's private temporary folder (`/var/folders/…/T`), mode 0700.
    public static func userTemporaryDirectory() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else { return nil }
        let path = String(cString: buffer)
        return path.hasPrefix("/") ? path : nil
    }
}

/// The switch in Focus Studio › Settings › AI tools, shared by the app
/// (which refuses calls while it is off) and focus-studio-mcp (which then
/// does not open the app just to be refused).
public enum AutomationSwitch {
    /// The key in the app's preferences (com.local.focusstudio); a missing
    /// value means on.
    public static let preferenceKey = "automation.allowAITools"

    /// The `isError` text for a call refused because the switch is off.
    public static func disabledMessage(tool: String) -> String {
        "Focus Studio is set not to accept AI tools, so \(tool) did not run and nothing was changed. If the person wants you to use Focus Studio, ask them to turn on “Allow AI tools to control Focus Studio” in Focus Studio › Settings › AI tools, then try again."
    }
}

/// Where the control socket is and why.
public struct ControlSocketLocation: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// `$FOCUS_STUDIO_CONTROL_SOCKET`.
        case environment
        /// `~/Library/Application Support/FocusStudio/Control`.
        case applicationSupport
        /// The short fallback in the user's temporary folder.
        case temporaryDirectory
    }

    public let path: String
    public let source: Source

    public init(path: String, source: Source) {
        self.path = path
        self.source = source
    }

    /// The folder that holds the socket; the app keeps it private (0700).
    public var directory: String { (path as NSString).deletingLastPathComponent }
    /// The lock file only the serving app instance holds (`flock`).
    public var lockPath: String { path + ".lock" }
}

public enum ControlChannelError: Error, LocalizedError, Equatable {
    case relativeSocketPath(String)
    case socketPathTooLong(String)

    public var errorDescription: String? {
        switch self {
        case let .relativeSocketPath(path):
            return "\(ControlChannel.socketPathVariable) must be an absolute path, not \(path)."
        case let .socketPathTooLong(path):
            return "The control socket path is longer than the \(ControlChannel.maximumSocketPathLength) bytes a Unix socket allows: \(path)"
        }
    }
}

// MARK: - JSON-RPC messages

/// A JSON-RPC error object.
public struct ControlError: Error, Equatable, Sendable, LocalizedError {
    public var code: Int
    public var message: String
    public var data: AIJSONValue?

    public init(code: Int, message: String, data: AIJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var json: AIJSONValue {
        var fields: [String: AIJSONValue] = ["code": AIJSONValue(code), "message": AIJSONValue(message)]
        if let data { fields["data"] = data }
        return .object(fields)
    }

    public var errorDescription: String? { message }
}

/// A line that is not a valid message, with the reply it deserves: the
/// error, and the request id when one could be read.
public struct ControlMessageError: Error, Equatable, Sendable {
    public var error: ControlError
    public var id: AIJSONValue?

    public init(_ error: ControlError, id: AIJSONValue? = nil) {
        self.error = error
        self.id = id
    }

    /// The error response to send back.
    public var reply: ControlMessage { .error(id: id, error) }
}

/// One JSON-RPC 2.0 message on the control channel.
public enum ControlMessage: Equatable, Sendable {
    case request(id: AIJSONValue, method: String, params: AIJSONValue?)
    case notification(method: String, params: AIJSONValue?)
    case result(id: AIJSONValue, AIJSONValue)
    /// An error response; `id` is nil when the request's id could not be read.
    case error(id: AIJSONValue?, ControlError)

    /// Reads one line (without its line feed). Throws a
    /// ``ControlMessageError`` carrying the reply for invalid JSON (-32700)
    /// or a JSON value that is not a message (-32600).
    public static func decode(_ line: Data) throws -> ControlMessage {
        guard let object = try? JSONSerialization.jsonObject(with: line, options: []),
              let json = AIJSONValue(jsonObject: object) else {
            throw ControlMessageError(ControlError(code: ControlChannel.ErrorCode.parseError, message: "Parse error: not a JSON object."))
        }
        return try decode(json)
    }

    public static func decode(_ json: AIJSONValue) throws -> ControlMessage {
        guard let fields = json.objectValue else {
            throw ControlMessageError(ControlError(code: ControlChannel.ErrorCode.invalidRequest, message: "Invalid request: a message is a JSON object."))
        }
        // AIJSONValue is ExpressibleByNilLiteral, so JSON null is dropped explicitly.
        let id = nonNull(fields["id"])
        if let validID = id, validID.stringValue == nil, validID.doubleValue == nil {
            throw ControlMessageError(ControlError(code: ControlChannel.ErrorCode.invalidRequest, message: "Invalid request: the id must be a number or a string."))
        }
        let params = nonNull(fields["params"])
        if let method = fields["method"] {
            guard let name = method.stringValue, !name.isEmpty else {
                throw ControlMessageError(ControlError(code: ControlChannel.ErrorCode.invalidRequest, message: "Invalid request: method must be a string."), id: id)
            }
            if let params, params.objectValue == nil, params.arrayValue == nil {
                throw ControlMessageError(ControlError(code: ControlChannel.ErrorCode.invalidRequest, message: "Invalid request: params must be an object."), id: id)
            }
            if let id { return .request(id: id, method: name, params: params) }
            return .notification(method: name, params: params)
        }
        if let error = fields["error"] {
            guard let code = error["code"]?.intValue else {
                throw ControlMessageError(ControlError(code: ControlChannel.ErrorCode.invalidRequest, message: "Invalid response: error.code must be an integer."), id: id)
            }
            return .error(id: id, ControlError(code: code, message: error["message"]?.stringValue ?? "", data: error["data"]))
        }
        if let result = fields["result"], let id {
            return .result(id: id, result)
        }
        throw ControlMessageError(ControlError(code: ControlChannel.ErrorCode.invalidRequest, message: "Invalid request: neither a request, a notification nor a response."), id: id)
    }

    private static func nonNull(_ value: AIJSONValue?) -> AIJSONValue? {
        guard let value, !value.isNull else { return Optional<AIJSONValue>.none }
        return value
    }

    public var json: AIJSONValue {
        switch self {
        case let .request(id, method, params):
            var fields: [String: AIJSONValue] = ["jsonrpc": "2.0", "id": id, "method": AIJSONValue(method)]
            if let params { fields["params"] = params }
            return .object(fields)
        case let .notification(method, params):
            var fields: [String: AIJSONValue] = ["jsonrpc": "2.0", "method": AIJSONValue(method)]
            if let params { fields["params"] = params }
            return .object(fields)
        case let .result(id, result):
            return ["jsonrpc": "2.0", "id": id, "result": result]
        case let .error(id, error):
            return ["jsonrpc": "2.0", "id": id ?? .null, "error": error.json]
        }
    }

    /// The message as one line of UTF-8 JSON, without the line feed. JSON
    /// escapes line feeds inside strings, so the line has none.
    public func encoded() throws -> Data {
        try json.jsonData()
    }

    public var id: AIJSONValue? {
        switch self {
        case let .request(id, _, _), let .result(id, _): return id
        case let .error(id, _): return id
        case .notification: return nil
        }
    }
}

// MARK: - Parameters

/// A parameter object of a control-channel message.
public protocol ControlParameters: Codable, Equatable, Sendable {}

extension ControlParameters {
    /// Decodes `params`; throws ``ControlError`` -32602 naming what is wrong.
    public static func decode(_ params: AIJSONValue?) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: (params ?? [:]).jsonData())
        } catch let DecodingError.keyNotFound(key, _) {
            throw ControlError(code: ControlChannel.ErrorCode.invalidParams, message: "Invalid params: missing \"\(key.stringValue)\".")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw ControlError(code: ControlChannel.ErrorCode.invalidParams, message: "Invalid params: \"\(path)\" has the wrong type.")
        } catch {
            throw ControlError(code: ControlChannel.ErrorCode.invalidParams, message: "Invalid params: \(error.localizedDescription)")
        }
    }

    /// The parameters as a JSON object.
    public var json: AIJSONValue {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let value = AIJSONValue(jsonObject: object) else { return [:] }
        return value
    }
}

/// The MCP client at the other end of the helper, as it introduced itself
/// (`clientInfo` in MCP `initialize`). Self-reported: for display only.
public struct ControlClientInfo: ControlParameters {
    public var name: String
    public var version: String
    public var title: String?

    public init(name: String, version: String, title: String? = nil) {
        self.name = name
        self.version = version
        self.title = title
    }

    /// A name for people: the title when given, else a known client's
    /// product name ("claude-code" → "Claude Code"), else the name itself.
    public var displayName: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "claude-code", "claude code", "claude-ai", "claude": return "Claude Code"
        case "codex", "codex-mcp-client", "codex_mcp_client", "codex-cli": return "Codex"
        default: return trimmed.isEmpty ? "AI tool" : trimmed
        }
    }
}

/// `hello` params.
public struct ControlHello: ControlParameters {
    public var protocolVersion: Int
    public var helperVersion: String
    public var client: ControlClientInfo?
    /// The helper's working directory: the client's, for relative paths.
    public var workingDirectory: String?

    public init(protocolVersion: Int = ControlChannel.protocolVersion, helperVersion: String, client: ControlClientInfo?, workingDirectory: String?) {
        self.protocolVersion = protocolVersion
        self.helperVersion = helperVersion
        self.client = client
        self.workingDirectory = workingDirectory
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case helperVersion = "helper_version"
        case client
        case workingDirectory = "working_directory"
    }
}

/// The app's `hello` result.
public struct ControlHelloReply: ControlParameters {
    public var protocolVersion: Int
    public var appVersion: String
    /// The Focus Studio.app that answered.
    public var appPath: String
    public var pid: Int32

    public init(protocolVersion: Int = ControlChannel.protocolVersion, appVersion: String, appPath: String, pid: Int32) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.appPath = appPath
        self.pid = pid
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case appVersion = "app_version"
        case appPath = "app_path"
        case pid
    }
}

/// `call` params: one MCP `tools/call`.
public struct ControlCall: ControlParameters {
    public var tool: String
    /// The arguments exactly as the client sent them, `project_id` included.
    public var arguments: [String: AIJSONValue]
    /// Overrides hello's working directory for this call.
    public var workingDirectory: String?
    /// Present when the client asked for progress; the app then sends
    /// `progress` notifications for this call. Opaque to the app.
    public var progressToken: AIJSONValue?
    /// Seconds the helper had already spent on the call when it sent it
    /// (opening the app, connecting, waiting for hello), measured from the
    /// client's `tools/call`. The app counts them toward the time after which
    /// a call answers with a job (``AutomationJobs``), so the first call of a
    /// session answers within the client's tool timeout as well.
    ///
    /// Optional, so protocol 1 is unchanged: an app that predates it ignores
    /// the key (decoding skips unknown keys) and counts from the call's
    /// arrival, and the app counts a call without it (an older helper) the
    /// same way. The app uses it clamped to `0...` ``maximumElapsed``.
    public var elapsed: Double?

    /// More than any helper waits before sending a call.
    public static let maximumElapsed: TimeInterval = 600

    public init(tool: String, arguments: [String: AIJSONValue] = [:], workingDirectory: String? = nil, progressToken: AIJSONValue? = nil, elapsed: Double? = nil) {
        self.tool = tool
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.progressToken = progressToken
        self.elapsed = elapsed
    }

    enum CodingKeys: String, CodingKey {
        case tool
        case arguments
        case workingDirectory = "working_directory"
        case progressToken = "progress_token"
        case elapsed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tool = try container.decode(String.self, forKey: .tool)
        arguments = try container.decodeIfPresent([String: AIJSONValue].self, forKey: .arguments) ?? [:]
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        progressToken = try container.decodeIfPresent(AIJSONValue.self, forKey: .progressToken)
        elapsed = try container.decodeIfPresent(Double.self, forKey: .elapsed)
    }

    /// ``elapsed`` as the app counts it: finite, from 0 to ``maximumElapsed``.
    public var countedElapsed: TimeInterval {
        guard let elapsed, elapsed.isFinite else { return 0 }
        return min(Self.maximumElapsed, max(0, elapsed))
    }
}

/// `progress` params: measured progress of the call whose request id is `id`.
public struct ControlProgress: ControlParameters {
    public var id: AIJSONValue
    public var progress: Double
    public var total: Double?
    public var message: String?

    public init(id: AIJSONValue, progress: Double, total: Double? = nil, message: String? = nil) {
        self.id = id
        self.progress = progress
        self.total = total
        self.message = message
    }
}

/// `cancel` params: the request id of the call to cancel.
public struct ControlCancel: ControlParameters {
    public var id: AIJSONValue

    public init(id: AIJSONValue) { self.id = id }
}

// MARK: - Call results

extension AutomationCallResult {
    /// The app's reply to the `call` request `id`.
    public func controlReply(id: AIJSONValue) -> ControlMessage {
        switch self {
        case let .result(result):
            return .result(id: id, result.json)
        case let .unknownTool(name):
            return .error(id: id, ControlError(code: ControlChannel.ErrorCode.invalidParams, message: "Unknown tool: \(name)", data: ["tool": AIJSONValue(name)]))
        case .cancelled:
            return .error(id: id, ControlError(code: ControlChannel.ErrorCode.cancelled, message: "The call was cancelled."))
        }
    }

    /// What the helper makes of the app's reply to a call of `tool`: the
    /// MCP result, an unknown tool, a cancelled call, or for any other error
    /// an `isError` result naming it.
    public init(controlReply: ControlMessage, tool: String) {
        switch controlReply {
        case let .result(_, value):
            if let result = MCPToolCallResult(json: value) {
                self = .result(result)
            } else {
                self = .result(.failure("Focus Studio answered \(tool) with a result focus-studio-mcp could not read, so it is not known whether the call changed anything. Check with get_status or get_project."))
            }
        case let .error(_, error) where error.code == ControlChannel.ErrorCode.cancelled:
            self = .cancelled
        case let .error(_, error) where error.code == ControlChannel.ErrorCode.invalidParams && error.data?["tool"]?.stringValue != nil:
            self = .unknownTool(error.data?["tool"]?.stringValue ?? tool)
        case let .error(_, error):
            self = .result(.failure("Focus Studio could not run \(tool): \(error.message)"))
        case .request, .notification:
            self = .result(.failure("Focus Studio answered \(tool) with a message that is not a reply."))
        }
    }
}

extension MCPToolCallResult {
    /// Reads an MCP `CallToolResult` (``json``): text and image blocks,
    /// structured content and `isError`. Nil for anything else.
    public init?(json: AIJSONValue) {
        guard let blocks = json["content"]?.arrayValue else { return nil }
        var content: [MCPContent] = []
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                guard let text = block["text"]?.stringValue else { return nil }
                content.append(.text(text))
            case "image":
                guard let encoded = block["data"]?.stringValue, let data = Data(base64Encoded: encoded),
                      let mimeType = block["mimeType"]?.stringValue else { return nil }
                content.append(.image(data: data, mimeType: mimeType))
            default:
                return nil
            }
        }
        var structured = json["structuredContent"]
        if structured?.isNull == true { structured = nil }
        if let structured, structured.objectValue == nil { return nil }
        if let isError = json["isError"], isError.boolValue == nil, !isError.isNull { return nil }
        self.init(content: content, structuredContent: structured, isError: json["isError"]?.boolValue ?? false)
    }
}
