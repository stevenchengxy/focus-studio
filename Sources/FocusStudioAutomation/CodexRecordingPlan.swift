import Foundation

// Recording-plan drafts: what the assistant (and Demo Director) proposes and
// the recorder runs only after the person clicks Run. They live beside the
// assistant session, which drafts, persists and validates them; the app's
// Codex transport (CodexDirectorModels.swift) adds the app-server output schema.

public enum CodexCaptureMode: String, Codable, CaseIterable, Sendable {
    case url
    case window
    case screenshot

    public var title: String {
        switch self {
        case .url: return "URL"
        case .window: return "Window"
        case .screenshot: return "Screenshot"
        }
    }
}

public struct CodexCaptureDirective: Codable, Hashable, Sendable {
    public var mode: CodexCaptureMode
    public var url: String?
    public var windowTitle: String?
    public var screenshotPath: String?

    public init(mode: CodexCaptureMode, url: String? = nil, windowTitle: String? = nil, screenshotPath: String? = nil) {
        self.mode = mode
        self.url = url
        self.windowTitle = windowTitle
        self.screenshotPath = screenshotPath
    }

    public var summary: String {
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

public enum CodexRecordingActionType: String, Codable, CaseIterable, Sendable {
    case wait
    case click
    case scroll
    case navigate
}

/// A deliberately flat action payload. The Codex app-server can constrain this
/// shape with JSON Schema, while the recorder can validate fields based on
/// `type` before it executes anything.
public struct CodexRecordingAction: Codable, Hashable, Sendable {
    public var type: CodexRecordingActionType
    public var seconds: Double?
    public var x: Double?
    public var y: Double?
    public var deltaX: Double?
    public var deltaY: Double?
    public var url: String?
    public var label: String?

    public init(
        type: CodexRecordingActionType,
        seconds: Double? = nil,
        x: Double? = nil,
        y: Double? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        url: String? = nil,
        label: String? = nil
    ) {
        self.type = type
        self.seconds = seconds
        self.x = x
        self.y = y
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.url = url
        self.label = label
    }

    public var summary: String {
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

public struct CodexRecordingPlan: Codable, Hashable, Sendable {
    public var title: String
    public var summary: String
    public var capture: CodexCaptureDirective
    public var actions: [CodexRecordingAction]

    public init(title: String, summary: String, capture: CodexCaptureDirective, actions: [CodexRecordingAction]) {
        self.title = title
        self.summary = summary
        self.capture = capture
        self.actions = actions
    }

    /// Empty means the plan is safe to hand to a future runner. The Director
    /// view never executes actions itself.
    public var validationIssues: [String] {
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
