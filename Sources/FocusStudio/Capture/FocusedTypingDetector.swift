import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import FocusStudioCore

/// Reads focus identity, roles, and rectangles only. In particular, never asks
/// for AXValue, selected text, or the contents of a secure/editable element.
@MainActor
final class FocusedTypingDetector {
    private var lastProbeUptime = -Double.infinity
    private var cachedContext = TypingFocusContext(processID: nil)
    private(set) var focusedEditableElement: AXUIElement?

    func reset() {
        lastProbeUptime = -.infinity
        cachedContext = TypingFocusContext(processID: nil)
        focusedEditableElement = nil
    }

    func context(uptime: TimeInterval, force: Bool = false) -> TypingFocusContext {
        guard let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return TypingFocusContext(processID: nil)
        }
        if !force, cachedContext.processID == processID, uptime - lastProbeUptime < 0.099 {
            return cachedContext
        }
        lastProbeUptime = uptime
        focusedEditableElement = nil
        let windows = visibleWindows(for: processID)
        let windowID = windows.first?.id
        var context = TypingFocusContext(processID: processID, windowID: windowID)
        guard AXIsProcessTrusted() else { cachedContext = context; return context }
        let app = AXUIElementCreateApplication(processID)
        // A target app stalled on a busy web page must not stall recording.
        AXUIElementSetMessagingTimeout(app, 0.02)
        let probeStart = ProcessInfo.processInfo.systemUptime
        guard let focused = elementAttribute(kAXFocusedUIElementAttribute as CFString, of: app) else {
            cachedContext = context
            return context
        }
        if let focusedWindow = elementAttribute(kAXWindowAttribute as CFString, of: focused)
            ?? elementAttribute(kAXFocusedWindowAttribute as CFString, of: app),
           let focusedBounds = bounds(of: focusedWindow) {
            // Public AX has no portable window-number attribute. Match its
            // focused-window geometry to the Window Server's ordered window IDs.
            // When no match exists, reject window-capture activity conservatively.
            context.windowID = windows.first(where: { sameBounds($0.bounds, focusedBounds) })?.id
        }
        var current: AXUIElement? = focused
        var foundSemanticRole = false
        var foundEditable = false
        var focusedRole: String?
        for _ in 0..<5 {
            guard ProcessInfo.processInfo.systemUptime - probeStart < 0.08 else { break }
            guard let element = current else { break }
            let role = attribute(kAXRoleAttribute as CFString, of: element) as? String
            if focusedRole == nil { focusedRole = role }
            let subrole = attribute(kAXSubroleAttribute as CFString, of: element) as? String
            let editable = (attribute("AXIsEditable" as CFString, of: element) as? Bool) ?? false
            foundSemanticRole = foundSemanticRole || role != nil
            let editableAncestor = elementAttribute("AXEditableAncestor" as CFString, of: element)
            let isEditable = CursorKindSemantics.classify(
                role: role, subrole: subrole, isEditable: editable,
                hasEditableAncestor: editableAncestor != nil
            ) == .iBeam
            foundEditable = foundEditable || isEditable
            if isEditable, let bounds = bounds(of: editableAncestor ?? element) {
                context.semantics = .editable(bounds)
                focusedEditableElement = editableAncestor ?? element
                cachedContext = context
                return context
            }
            current = elementAttribute(kAXParentAttribute as CFString, of: element)
        }
        // Browsers may report a web area without exposing DOM focus. Treat it as
        // unavailable so the same-app last-click fallback remains useful.
        let ambiguousRoles = ["AXWebArea", "AXGroup", "AXWindow", "AXScrollArea"]
        if !foundEditable, foundSemanticRole, let focusedRole, !ambiguousRoles.contains(focusedRole) {
            context.semantics = .notEditable
        }
        cachedContext = context
        return context
    }

    private func visibleWindows(for processID: Int32) -> [(id: UInt32, bounds: CaptureRect)] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        // Window-server order is front to back. Matching the first normal window
        // also rejects typing into another window belonging to the same app.
        return windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let dictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
            return (id, CaptureRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
        }
    }

    private func sameBounds(_ lhs: CaptureRect, _ rhs: CaptureRect) -> Bool {
        abs(lhs.x - rhs.x) < 2 && abs(lhs.y - rhs.y) < 2
            && abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
    }

    private func bounds(of element: AXUIElement) -> CaptureRect? {
        guard let positionValue = attribute(kAXPositionAttribute as CFString, of: element),
              let sizeValue = attribute(kAXSizeAttribute as CFString, of: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CaptureRect(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    private func elementAttribute(_ name: CFString, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func attribute(_ name: CFString, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
}
