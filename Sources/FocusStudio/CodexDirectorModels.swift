import Foundation

enum CodexCaptureMode: String, Codable, CaseIterable, Sendable {
    case url
    case window
    case screenshot

    var title: String {
        switch self {
        case .url: return "URL"
        case .window: return "Window"
        case .screenshot: return "Screenshot"
        }
    }
}

struct CodexCaptureDirective: Codable, Hashable, Sendable {
    var mode: CodexCaptureMode
    var url: String?
    var windowTitle: String?
    var screenshotPath: String?

    var summary: String {
        switch mode {
        case .url:
            return url.map { "Open \($0)" } ?? "Open a URL"
        case .window:
            return windowTitle.map { "Record window “\($0)”" } ?? "Record a window"
        case .screenshot:
            return screenshotPath.map { "Capture \($0)" } ?? "Capture a screenshot"
        }
    }
}

enum CodexRecordingActionType: String, Codable, CaseIterable, Sendable {
    case wait
    case click
    case scroll
    case navigate
}

/// A deliberately flat action payload. The Codex app-server can constrain this
/// shape with JSON Schema, while the recorder can validate fields based on
/// `type` before it executes anything.
struct CodexRecordingAction: Codable, Hashable, Sendable {
    var type: CodexRecordingActionType
    var seconds: Double?
    var x: Double?
    var y: Double?
    var deltaX: Double?
    var deltaY: Double?
    var url: String?
    var label: String?

    var summary: String {
        switch type {
        case .wait:
            return "Wait \(Self.formatted(seconds ?? 0))s"
        case .click:
            let target = label.map { " “\($0)”" } ?? ""
            if let x, let y {
                return "Click\(target) at \(Self.formatted(x)), \(Self.formatted(y))"
            }
            return "Click\(target)"
        case .scroll:
            return "Scroll by \(Self.formatted(deltaX ?? 0)), \(Self.formatted(deltaY ?? 0))"
        case .navigate:
            return url.map { "Navigate to \($0)" } ?? "Navigate"
        }
    }

    private static func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

struct CodexRecordingPlan: Codable, Hashable, Sendable {
    var title: String
    var summary: String
    var capture: CodexCaptureDirective
    var actions: [CodexRecordingAction]

    /// Empty means the plan is safe to hand to a future runner. The Director
    /// view never executes actions itself.
    var validationIssues: [String] {
        var issues: [String] = []

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("The plan needs a title.")
        }
        if actions.count > 32 {
            issues.append("A recording plan can contain at most 32 actions.")
        }

        let waitBudget = actions.reduce(0.0) { partial, action in
            partial + (action.type == .wait ? max(0, action.seconds ?? 0) : 0)
        }
        if waitBudget > 75 {
            issues.append("The plan's total wait time cannot exceed 75 seconds.")
        }
        if actions.filter({ $0.type == .click }).count > 12 {
            issues.append("A recording plan can contain at most 12 clicks.")
        }
        if actions.filter({ $0.type == .navigate }).count > 4 {
            issues.append("A recording plan can contain at most 4 navigations.")
        }

        switch capture.mode {
        case .url:
            if !Self.isWebURL(capture.url) {
                issues.append("URL capture requires an http or https URL.")
            }
        case .window:
            if capture.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                issues.append("Window capture requires a window title.")
            }
        case .screenshot:
            if actions.contains(where: { $0.type == .navigate }) {
                issues.append("Screenshot plans cannot navigate; click cues become non-interactive zooms.")
            }
        }

        for (index, action) in actions.enumerated() {
            let prefix = "Action \(index + 1)"
            switch action.type {
            case .wait:
                if action.seconds.map({ !$0.isFinite || !(0...30).contains($0) }) != false {
                    issues.append("\(prefix) requires seconds between 0 and 30.")
                }
            case .click:
                let hasCoordinates = action.x.map(Self.isNormalized) == true
                    && action.y.map(Self.isNormalized) == true
                if !hasCoordinates {
                    issues.append("\(prefix) requires normalized x/y coordinates so it can run safely.")
                }
            case .scroll:
                let x = action.deltaX ?? 0
                let y = action.deltaY ?? 0
                if !x.isFinite || !y.isFinite || (x == 0 && y == 0) {
                    issues.append("\(prefix) requires a finite, non-zero scroll delta.")
                } else if abs(x) > 1_200 || abs(y) > 1_200 {
                    issues.append("\(prefix) scroll delta must stay within ±1200 pixels.")
                }
            case .navigate:
                if !Self.isWebURL(action.url) {
                    issues.append("\(prefix) requires an http or https URL.")
                }
            }
        }

        return issues
    }

    private static func isNormalized(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    private static func isWebURL(_ value: String?) -> Bool {
        guard let value,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false
        else { return false }
        return true
    }
}

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
