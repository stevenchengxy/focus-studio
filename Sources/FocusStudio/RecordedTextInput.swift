import AppKit
import ApplicationServices
import FocusStudioAutomation
import FocusStudioCore

/// Keyboard input for an observed, already-focused page field only. It never
/// reads a field's value, changes the clipboard, or sends a submit key.
@MainActor
enum RecordedTextInput {
    struct Focus {
        var processID: pid_t
        var windowID: UInt32
        var windowFrame: CGRect
        var fieldFrame: CGRect
        var webFrame: CGRect?
        var browserID: String
        var editable: Bool
        var secure: Bool
        /// Native identity uses AX equality; a fixture supplies an opaque ID.
        var element: AXUIElement?
        var fixtureID = ""

        func isSameField(as other: Focus, allowFieldLayoutChange: Bool = false) -> Bool {
            guard processID == other.processID, windowID == other.windowID,
                  windowFrame == other.windowFrame,
                  allowFieldLayoutChange || fieldFrame == other.fieldFrame else { return false }
            if let element, let otherElement = other.element { return CFEqual(element, otherElement) }
            return element == nil && other.element == nil && fixtureID == other.fixtureID
        }
    }

    struct Driver {
        var focus: () throws -> Focus
        var post: ([UniChar], pid_t) throws -> Void
        var wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(35)) }
    }

    struct Observation {
        var focus: Focus?
        var failure: InputError?

        /// Both sides of the screenshot must identify the same field. Keep
        /// the first actionable failure instead of silently discarding it.
        func paired(with after: Observation) -> Observation {
            guard let focus else { return self }
            guard let afterFocus = after.focus else { return after }
            guard focus.isSameField(as: afterFocus) else { return Observation(failure: .changedFocus) }
            return self
        }
    }

    enum InputError: LocalizedError {
        case unsupportedField, rejected(String), changedFocus, unavailableEvent
        private static let fieldGuidance = "Click a visible, non-password text field inside the recorded Chrome or Safari page, then capture a fresh frame before typing. Browser address bars are not supported."
        var diagnosticCode: String {
            switch self {
            case .unsupportedField: return "field_not_observed"
            case let .rejected(reason): return reason
            case .changedFocus: return "focused_field_changed"
            case .unavailableEvent: return "keyboard_event_unavailable"
            }
        }
        var errorDescription: String? {
            switch self {
            case .unsupportedField:
                return Self.fieldGuidance
            case let .rejected(reason):
                // Codes describe only AX/geometry checks, never field contents.
                return "\(Self.fieldGuidance) [\(reason)]"
            case .changedFocus:
                return "The focused field or recorded window changed. Text entry stopped; observe the field before continuing."
            case .unavailableEvent:
                return "macOS could not create a text input event. No more text was sent."
            }
        }
    }

    static func validate(_ focus: Focus, targetID: UInt32, frame: CGRect) throws {
        guard focus.windowID == targetID else { throw InputError.rejected("different_window") }
        guard focus.windowFrame == frame else { throw InputError.rejected("window_geometry_changed") }
        guard ["com.google.Chrome", "com.apple.Safari"].contains(focus.browserID) else { throw InputError.rejected("unsupported_browser") }
        guard focus.editable else { throw InputError.rejected("field_not_editable") }
        guard !focus.secure else { throw InputError.rejected("protected_field") }
        guard let web = focus.webFrame else { throw InputError.rejected("page_ancestor_missing") }
        guard focus.fieldFrame.width > 0, focus.fieldFrame.height > 0 else { throw InputError.rejected("empty_field_bounds") }
        guard frame.contains(focus.fieldFrame) else { throw InputError.rejected("field_outside_window") }
        guard web.contains(focus.fieldFrame) else { throw InputError.rejected("field_outside_page") }
    }

    static func run(text: String, targetID: UInt32, frame: CGRect,
                    observedFocus: Focus,
                    waitUntilReady: () async throws -> Void,
                    onCharacters: (Int) -> Void,
                    onActivity: ((CGPoint) -> Void)? = nil,
                    driver: Driver? = nil) async throws {
        try AIRecordingText.validate(text)
        let driver = driver ?? Driver(focus: { try currentFocus(targetID: targetID) }, post: postUnicode)
        try Task.checkCancellation()
        try await waitUntilReady()
        try validate(observedFocus, targetID: targetID, frame: frame)
        let initial = try driver.focus()
        try validate(initial, targetID: targetID, frame: frame)
        guard observedFocus.isSameField(as: initial) else { throw InputError.changedFocus }
        // Preserve complete Unicode graphemes, including Chinese and emoji.
        let characters = Array(text)
        for offset in stride(from: 0, to: characters.count, by: 4) {
            try Task.checkCancellation()
            try await waitUntilReady()
            let current = try driver.focus()
            try validate(current, targetID: targetID, frame: frame)
            // A textarea can grow as a line wraps. Keep its exact AX identity
            // and validate the new bounds stay inside the same page/window.
            guard initial.isSameField(as: current, allowFieldLayoutChange: true) else { throw InputError.changedFocus }
            let chunk = String(characters[offset..<min(offset + 4, characters.count)])
            try driver.post(Array(chunk.utf16), current.processID)
            // Only a successfully dispatched chunk creates timing evidence.
            // The editable-field point is independent of the visible cursor;
            // neither text, key codes nor a pointer movement is reported.
            onActivity?(CGPoint(x: (current.fieldFrame.midX - frame.minX) / frame.width,
                                y: (current.fieldFrame.midY - frame.minY) / frame.height))
            onCharacters(chunk.count)
            if offset + 4 < characters.count { try await driver.wait() }
        }
    }

    private static func postUnicode(_ units: [UniChar], to processID: pid_t) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw InputError.unavailableEvent
        }
        for event in [down, up] {
            event.flags = []
            units.withUnsafeBufferPointer { pointer in
                if let base = pointer.baseAddress { event.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: base) }
            }
        }
        // Target the verified browser process, never whichever app becomes
        // foreground between the focus check and event dispatch.
        down.postToPid(processID)
        up.postToPid(processID)
    }

    /// Read-only identity snapshot taken alongside a live recording frame.
    static func observe(targetID: UInt32, frame: CGRect) throws -> Focus {
        let focus = try currentFocus(targetID: targetID)
        try validate(focus, targetID: targetID, frame: frame)
        return focus
    }

    static func observation(targetID: UInt32, frame: CGRect) -> Observation {
        do { return Observation(focus: try observe(targetID: targetID, frame: frame)) }
        catch let error as InputError { return Observation(failure: error) }
        catch { return Observation(failure: .rejected("accessibility_observation_failed")) }
    }

    private static func currentFocus(targetID: UInt32) throws -> Focus {
        guard AXIsProcessTrusted() else { throw InputError.rejected("accessibility_unavailable") }
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]],
              let target = entries.first(where: { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value == targetID }),
              let pid = (target[kCGWindowOwnerPID] as? NSNumber)?.int32Value else { throw InputError.rejected("target_window_unavailable") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw InputError.rejected("browser_not_frontmost") }
        guard let browserID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              ["com.google.Chrome", "com.apple.Safari"].contains(browserID) else { throw InputError.rejected("unsupported_browser") }
        guard
              let values = target[kCGWindowBounds] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: values as CFDictionary) else { throw InputError.rejected("window_bounds_unavailable") }
        // Geometry alone cannot distinguish two overlapping browser windows.
        // Window Server order must also identify the approved window as front.
        let targetFrame = CaptureRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        let front = entries.first {
            RecordingWindowFocus.isMainWindow($0, ownerPID: pid, targetFrame: targetFrame)
        }
        guard (front?[kCGWindowNumber] as? NSNumber)?.uint32Value == targetID else { throw InputError.rejected("different_front_window") }
        let app = AXUIElementCreateApplication(pid)
        // Chrome may need to construct its accessibility tree after a page
        // transition. A 25 ms request budget routinely rejected valid fields.
        AXUIElementSetMessagingTimeout(app, 0.15)
        if browserID == "com.google.Chrome" {
            // Ask Chrome to expose page accessibility nodes. This does not
            // request or change any macOS permission and never reads text.
            _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        guard let focused = element(kAXFocusedUIElementAttribute, of: app) else { throw InputError.rejected("focused_element_unavailable") }
        guard let window = element(kAXWindowAttribute, of: focused) ?? element(kAXFocusedWindowAttribute, of: app) else { throw InputError.rejected("focused_window_unavailable") }
        guard let focusedWindowFrame = bounds(window) else { throw InputError.rejected("focused_window_bounds_unavailable") }
        guard sameBounds(frame, focusedWindowFrame) else { throw InputError.rejected("focused_window_bounds_mismatch") }
        guard let field = bounds(focused) else { throw InputError.rejected("focused_field_bounds_unavailable") }
        let role = attribute(kAXRoleAttribute, of: focused) as? String
        var settable: DarwinBoolean = false
        let writableStatus = AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        let writableValue = writableStatus == .success && settable.boolValue
        let isEditable = attribute("AXIsEditable", of: focused) as? Bool
        guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(role ?? "") else { throw InputError.rejected("focused_role_not_text") }
        guard isEditable == true || writableValue else {
            let editableStatus = isEditable.map { $0 ? "true" : "false" } ?? "missing"
            throw InputError.rejected("field_not_editable:ax_value_status=\(writableStatus.rawValue),settable=\(settable.boolValue),editable=\(editableStatus)")
        }
        guard attribute(kAXEnabledAttribute, of: focused) as? Bool != false else { throw InputError.rejected("field_disabled") }
        var secure = false
        var web: CGRect?
        var node: AXUIElement? = focused
        let deadline = ProcessInfo.processInfo.systemUptime + 1.0
        for _ in 0..<32 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw InputError.rejected("page_ancestor_timeout") }
            guard let current = node else { break }
            let role = attribute(kAXRoleAttribute, of: current) as? String
            let subrole = attribute(kAXSubroleAttribute, of: current) as? String
            secure = secure || subrole == "AXSecureTextField" || role == "AXSecureTextField"
                || attribute("AXProtectedContent", of: current) as? Bool == true
            if role == "AXWebArea" {
                guard let bounds = bounds(current) else { throw InputError.rejected("page_bounds_unavailable") }
                web = bounds; break
            }
            node = element(kAXParentAttribute, of: current)
        }
        return Focus(processID: pid, windowID: targetID, windowFrame: frame, fieldFrame: field, webFrame: web,
                     browserID: browserID, editable: true, secure: secure, element: focused)
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func element(_ name: String, of parent: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: parent), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private static func bounds(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(kAXPositionAttribute, of: element), let size = attribute(kAXSizeAttribute, of: element),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    private static func sameBounds(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }
}
