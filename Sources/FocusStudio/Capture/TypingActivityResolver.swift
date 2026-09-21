import CoreGraphics
import Foundation
import FocusStudioCore

/// Geometry and identity only. No text, characters, key codes, or AX values.
public struct TypingFocusContext: Sendable {
    public enum Semantics: Sendable {
        case editable(CaptureRect)
        case notEditable
        case unavailable
    }

    public var processID: Int32?
    public var windowID: UInt32?
    public var semantics: Semantics

    public init(processID: Int32?, windowID: UInt32? = nil, semantics: Semantics = .unavailable) {
        self.processID = processID
        self.windowID = windowID
        self.semantics = semantics
    }
}

/// Keeps typing tied to the focused field/last click, never the current pointer.
public struct TypingActivityResolver: Sendable {
    private struct ClickAnchor: Sendable {
        var point: CGPoint
        var processID: Int32
        var windowID: UInt32?
    }

    private let captureRect: CaptureRect
    private let targetProcessID: Int32?
    private let targetWindowID: UInt32?
    private let excludedProcessID: Int32?
    private var lastClick: ClickAnchor?
    private var lastStoredUptime = -Double.infinity

    public init(
        captureRect: CaptureRect, targetProcessID: Int32? = nil,
        targetWindowID: UInt32? = nil, excludedProcessID: Int32? = nil
    ) {
        self.captureRect = captureRect
        self.targetProcessID = targetProcessID
        self.targetWindowID = targetWindowID
        self.excludedProcessID = excludedProcessID
    }

    public mutating func noteClick(x: Double, y: Double, context: TypingFocusContext) {
        guard let processID = context.processID,
              identityMatches(context), contains(CGPoint(x: x, y: y), in: captureRect) else {
            // Clicking away invalidates the fallback even when the pointer later
            // returns to the recorded region without clicking into a field.
            lastClick = nil
            return
        }
        lastClick = ClickAnchor(point: CGPoint(x: x, y: y), processID: processID, windowID: context.windowID)
    }

    public mutating func activity(
        uptime: TimeInterval,
        startUptime: TimeInterval,
        context: TypingFocusContext
    ) -> TypingActivity? {
        guard uptime.isFinite, startUptime.isFinite, uptime >= startUptime,
              uptime - lastStoredUptime >= 0.099,
              identityMatches(context), let processID = context.processID else { return nil }
        let anchor = lastClick.flatMap { click -> ClickAnchor? in
            guard click.processID == processID,
                  click.windowID == nil || context.windowID == nil || click.windowID == context.windowID else { return nil }
            return click
        }
        let point: CGPoint
        switch context.semantics {
        case let .editable(bounds):
            if let anchor, contains(anchor.point, in: bounds) {
                point = anchor.point
            } else {
                let intersection = rectangle(bounds).intersection(rectangle(captureRect))
                guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
                point = CGPoint(x: intersection.midX, y: intersection.midY)
            }
        case .notEditable:
            return nil
        case .unavailable:
            guard let anchor else { return nil }
            point = anchor.point
        }
        guard contains(point, in: captureRect), captureRect.width > 0, captureRect.height > 0 else { return nil }
        lastStoredUptime = uptime
        return TypingActivity(
            time: uptime - startUptime,
            x: min(1, max(0, (point.x - captureRect.x) / captureRect.width)),
            y: min(1, max(0, (point.y - captureRect.y) / captureRect.height))
        )
    }

    private func identityMatches(_ context: TypingFocusContext) -> Bool {
        guard context.processID != nil else { return false }
        if let excludedProcessID, context.processID == excludedProcessID { return false }
        if let targetProcessID, context.processID != targetProcessID { return false }
        if let targetWindowID, context.windowID != targetWindowID { return false }
        return true
    }

    private func rectangle(_ rect: CaptureRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private func contains(_ point: CGPoint, in rect: CaptureRect) -> Bool {
        point.x.isFinite && point.y.isFinite && rect.width > 0 && rect.height > 0
            && point.x >= rect.x && point.x <= rect.x + rect.width
            && point.y >= rect.y && point.y <= rect.y + rect.height
    }
}
