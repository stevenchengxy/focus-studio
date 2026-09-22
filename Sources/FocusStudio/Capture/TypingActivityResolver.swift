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
    private struct EditableAnchor: Sendable {
        var point: CGPoint
        var bounds: CaptureRect
        var processID: Int32
        var windowID: UInt32?
    }

    private let captureRect: CaptureRect
    private let targetProcessID: Int32?
    private let targetWindowID: UInt32?
    private let excludedProcessID: Int32?
    private var lastClick: ClickAnchor?
    private var editableAnchor: EditableAnchor?
    private var lastStoredPoint: CGPoint?
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
            editableAnchor = nil
            return
        }
        if let editableAnchor, !contains(CGPoint(x: x, y: y), in: editableAnchor.bounds) {
            self.editableAnchor = nil
        }
        lastClick = ClickAnchor(point: CGPoint(x: x, y: y), processID: processID, windowID: context.windowID)
    }

    public mutating func activity(
        uptime: TimeInterval,
        startUptime: TimeInterval,
        context: TypingFocusContext
    ) -> TypingActivity? {
        guard uptime.isFinite, startUptime.isFinite, uptime >= startUptime, valid(captureRect) else { return nil }
        guard identityMatches(context), let processID = context.processID else {
            lastClick = nil
            editableAnchor = nil
            return nil
        }
        let anchor = lastClick.flatMap { click -> ClickAnchor? in
            guard click.processID == processID,
                  click.windowID == nil || context.windowID == nil || click.windowID == context.windowID else { return nil }
            return click
        }
        let point: CGPoint
        switch context.semantics {
        case let .editable(bounds):
            guard valid(bounds) else { return nil }
            if let previous = editableAnchor,
               previous.processID == processID, previous.windowID == context.windowID,
               sameEditableRegion(previous.bounds, bounds),
               contains(previous.point, in: bounds), contains(previous.point, in: captureRect) {
                // Auto-growing chat boxes must not pull the camera after every
                // line. Keep a visible point in the same input until focus really
                // moves to a different field, even without an initial click.
                point = previous.point
            } else if let anchor, contains(anchor.point, in: bounds) {
                point = anchor.point
            } else {
                let intersection = rectangle(bounds).intersection(rectangle(captureRect))
                guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
                point = CGPoint(x: intersection.midX, y: intersection.midY)
            }
            editableAnchor = EditableAnchor(point: point, bounds: bounds, processID: processID, windowID: context.windowID)
        case .notEditable:
            lastClick = nil
            editableAnchor = nil
            return nil
        case .unavailable:
            guard let anchor else { return nil }
            point = anchor.point
        }
        guard contains(point, in: captureRect), captureRect.width > 0, captureRect.height > 0 else { return nil }
        let changedFocus = lastStoredPoint.map { hypot(point.x - $0.x, point.y - $0.y) > 1 } ?? false
        // Do not drop the only keystroke in a newly focused field merely because
        // it arrived inside the previous field's 100 ms repeat throttle.
        guard uptime - lastStoredUptime >= 0.099 || changedFocus else { return nil }
        lastStoredUptime = uptime
        lastStoredPoint = point
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
        point.x.isFinite && point.y.isFinite && valid(rect)
            && point.x >= rect.x && point.x <= rect.x + rect.width
            && point.y >= rect.y && point.y <= rect.y + rect.height
    }

    private func valid(_ rect: CaptureRect) -> Bool {
        rect.x.isFinite && rect.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private func sameEditableRegion(_ previous: CaptureRect, _ current: CaptureRect) -> Bool {
        guard valid(previous), valid(current) else { return false }
        let old = rectangle(previous)
        let new = rectangle(current)
        let overlap = old.intersection(new)
        guard !overlap.isNull else { return false }
        let shared = overlap.width * overlap.height / min(old.width * old.height, new.width * new.height)
        // Both top-growing and bottom-anchored message inputs are supported.
        return shared >= 0.7 && abs(old.minX - new.minX) <= 3
            && (abs(old.minY - new.minY) <= 3 || abs(old.maxY - new.maxY) <= 3)
    }
}
