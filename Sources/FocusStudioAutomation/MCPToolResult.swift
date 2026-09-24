import Foundation

/// One content block of an MCP tool result.
public enum MCPContent: Equatable, Sendable {
    case text(String)
    /// Encoded image bytes (sent as base64) and their MIME type.
    case image(data: Data, mimeType: String)

    /// The block as MCP writes it: `{"type": "text", "text": …}` or
    /// `{"type": "image", "data": <base64>, "mimeType": …}`.
    public var json: AIJSONValue {
        switch self {
        case let .text(text):
            return ["type": "text", "text": AIJSONValue(text)]
        case let .image(data, mimeType):
            return ["type": "image", "data": AIJSONValue(data.base64EncodedString()), "mimeType": AIJSONValue(mimeType)]
        }
    }
}

/// An MCP `CallToolResult`: content blocks for the model, the tool's
/// structured data, and whether the call failed. A failure is a result, not
/// a protocol error, so the model reads why and can correct its call.
public struct MCPToolCallResult: Equatable, Sendable {
    /// The longest side and the base64 size of an inline image: what Claude
    /// reads without downscaling, and small enough for any client.
    public static let maximumImageSide = 1_568
    public static let maximumImageBytes = 1_024 * 1_024

    public var content: [MCPContent]
    /// Always an object, as MCP requires.
    public var structuredContent: AIJSONValue?
    public var isError: Bool

    public init(content: [MCPContent], structuredContent: AIJSONValue? = nil, isError: Bool = false) {
        self.content = content
        if let structuredContent, structuredContent.objectValue == nil {
            self.structuredContent = ["value": structuredContent]
        } else {
            self.structuredContent = structuredContent
        }
        self.isError = isError
    }

    /// A tool's result: its text, the image it wrote as an inline JPEG when
    /// `includesImage` (the first image attachment; left out if it cannot be
    /// read, the text still names the file), and its data as structured content.
    public init(_ result: AIToolResult, includesImage: Bool = false) {
        var content: [MCPContent] = [.text(result.text)]
        if includesImage,
           let image = result.attachments.first(where: { AIToolPaths.kind(of: $0) == .image }),
           let jpeg = try? ArkMediaClient.jpegThumbnail(for: image, maxSide: Self.maximumImageSide, maxEncodedBytes: Self.maximumImageBytes, quality: 0.85) {
            content.append(.image(data: jpeg, mimeType: "image/jpeg"))
        }
        self.init(content: content, structuredContent: result.data)
    }

    /// A failed call: the error's text, written for the model to act on.
    public static func failure(_ error: Error) -> MCPToolCallResult {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return failure(message)
    }

    public static func failure(_ message: String) -> MCPToolCallResult {
        MCPToolCallResult(content: [.text(message)], isError: true)
    }

    /// The text blocks joined, for logs and tests.
    public var text: String {
        content.compactMap { if case let .text(text) = $0 { return text } else { return nil } }.joined(separator: "\n")
    }

    /// The result as MCP writes it: `{"content": […], "structuredContent": {…}, "isError": …}`.
    public var json: AIJSONValue {
        var fields: [String: AIJSONValue] = ["content": .array(content.map(\.json)), "isError": AIJSONValue(isError)]
        if let structuredContent { fields["structuredContent"] = structuredContent }
        return .object(fields)
    }
}

/// What an automation call came to, for the transport to answer with.
public enum AutomationCallResult: Equatable, Sendable {
    /// The tool ran, successfully or not (``MCPToolCallResult/isError``), or
    /// is still running as a job (``AutomationJobs``).
    case result(MCPToolCallResult)
    /// No exposed tool has this name: a protocol error (JSON-RPC -32602
    /// Invalid params), not a tool result.
    case unknownTool(String)
    /// The caller cancelled the call; MCP sends no response.
    case cancelled
}
