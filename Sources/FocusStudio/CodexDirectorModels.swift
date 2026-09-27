import FocusStudioAutomation
import Foundation

struct CodexDirectorMessage: Identifiable, Hashable, Sendable {
    enum Role: String, Hashable, Sendable {
        case user
        case assistant
        case status
    }

    let id: UUID
    let role: Role
    let text: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

enum CodexDirectorConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case needsSignIn
    case signingIn
    case ready
    case generating
    case failed(String)

    var title: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .needsSignIn: return "Sign in required"
        case .signingIn: return "Waiting for sign-in…"
        case .ready: return "Ready"
        case .generating: return "Planning…"
        case .failed: return "Needs attention"
        }
    }

    var isBusy: Bool {
        self == .connecting || self == .signingIn || self == .generating
    }
}

/// A small JSON value type keeps the app-server transport strongly typed while
/// remaining forward-compatible with fields added by future CLI releases.
enum CodexJSONValue: Codable, Equatable, Sendable {
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CodexJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CodexJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: CodexJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [CodexJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case let .number(value) = self, value.isFinite else { return nil }
        return Int(exactly: value)
    }
}

extension CodexRecordingPlan {
    /// JSON Schema passed as `turn/start.outputSchema`. Nullable fields are all
    /// required so the constrained-output contract stays deterministic.
    static let appServerOutputSchema: CodexJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "title": .object(["type": .string("string")]),
            "summary": .object(["type": .string("string")]),
            "capture": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array(CodexCaptureMode.allCases.map { .string($0.rawValue) })
                    ]),
                    "url": Self.nullableStringSchema,
                    "windowTitle": Self.nullableStringSchema,
                    "screenshotPath": Self.nullableStringSchema
                ]),
                "required": .array(["mode", "url", "windowTitle", "screenshotPath"].map(CodexJSONValue.string))
            ]),
            "actions": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "type": .object([
                            "type": .string("string"),
                            "enum": .array(CodexRecordingActionType.allCases.map { .string($0.rawValue) })
                        ]),
                        "seconds": Self.nullableNumberSchema,
                        "x": Self.nullableNumberSchema,
                        "y": Self.nullableNumberSchema,
                        "deltaX": Self.nullableNumberSchema,
                        "deltaY": Self.nullableNumberSchema,
                        "url": Self.nullableStringSchema,
                        "label": Self.nullableStringSchema
                    ]),
                    "required": .array([
                        "type", "seconds", "x", "y", "deltaX", "deltaY", "url", "label"
                    ].map(CodexJSONValue.string))
                ])
            ])
        ]),
        "required": .array(["title", "summary", "capture", "actions"].map(CodexJSONValue.string))
    ])

    private static let nullableStringSchema: CodexJSONValue = .object([
        "type": .array([.string("string"), .string("null")])
    ])

    private static let nullableNumberSchema: CodexJSONValue = .object([
        "type": .array([.string("number"), .string("null")])
    ])
}
