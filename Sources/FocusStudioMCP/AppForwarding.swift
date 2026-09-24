import FocusStudioAutomation
import Foundation

/// The MCP client at the other end of stdio, as it introduced itself in
/// `initialize` (`clientInfo`). Self-reported, so for display and logs only.
struct MCPClientIdentity: Equatable, Sendable {
    var name: String
    var version: String
    var title: String?
}

/// Lists the client's MCP roots as file URLs when asked; nil when the
/// client does not answer in time. Only offered for clients that declared
/// the `roots` capability.
typealias MCPRootsProvider = @Sendable () async -> [URL]?

/// One `tools/call` on its way to Focus Studio, with everything the app
/// needs to run it for this client. The tool is always one of the catalog's
/// (the helper answers unknown and withheld names itself).
struct ForwardedToolCall: Sendable {
    /// Numbers the calls of this helper process, for logs.
    let sequence: Int
    let tool: MCPToolSpec
    /// The arguments exactly as the client sent them, `project_id` included.
    let arguments: [String: AIJSONValue]
    /// What relative paths resolve against: the helper's working directory,
    /// which is the directory the client started it in.
    let workingDirectory: URL
    let client: MCPClientIdentity?
    /// The protocol version negotiated in `initialize`; nil before it.
    let protocolVersion: String?
    /// Takes measured progress from any thread; the helper forwards it as
    /// `notifications/progress`, dropping values that do not increase and
    /// anything reported after the call returned. Nil when the request
    /// carried no `_meta.progressToken`.
    let progress: AIToolProgressHandler?
    /// The client's roots; nil when it did not declare the roots capability.
    let roots: MCPRootsProvider?

    var toolName: String { tool.name }
}

/// Carries a tool call to the Focus Studio app and brings back what the app's
/// automation layer answered (`AutomationBridge.call` returns the same type).
///
/// Cancellation is Swift task cancellation. The task running ``forward(_:)``
/// is cancelled when the client sends `notifications/cancelled` for the
/// request, and when the helper shuts down: standard input closed and the
/// call did not finish within the settle time (``HelperSettings``).
/// `forward` should then stop promptly (asking the app to cancel the call)
/// and return `.cancelled`, or the result it already has. The helper decides
/// what the client sees: nothing for a request the client cancelled, an
/// `isError` result for the others.
protocol AppForwarding: Sendable {
    func forward(_ call: ForwardedToolCall) async -> AutomationCallResult

    /// The helper is about to exit; running calls were cancelled and had a
    /// moment to return. Close connections here.
    func shutdown() async
}

/// Answers every call with an error saying Focus Studio could not be
/// reached: what ``SocketAppForwarder`` answers when the app is not running
/// and the helper may not open it (`FOCUS_STUDIO_MCP_NO_LAUNCH=1`).
struct UnreachableAppForwarder: AppForwarding {
    static func message(for toolName: String) -> String {
        "Focus Studio could not be reached, so \(toolName) did not run and nothing was changed. Focus Studio is not running, and this focus-studio-mcp was started with \(AppConnectionSettings.noLaunchVariable)=1, so it does not open it. Ask the person to open Focus Studio, then try again."
    }

    func forward(_ call: ForwardedToolCall) async -> AutomationCallResult {
        .result(.failure(Self.message(for: call.toolName)))
    }

    func shutdown() async {}
}
