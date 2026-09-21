import ApplicationServices
import CoreGraphics
import FocusStudioCore
import Foundation

/// Pure accessibility semantics shared by live detection and deterministic tests.
public enum CursorKindSemantics {
    public static func classify(
        role: String?,
        subrole: String?,
        isEditable: Bool,
        hasEditableAncestor: Bool
    ) -> CursorKind {
        if role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || subrole == (kAXSearchFieldSubrole as String)
            || subrole == (kAXSecureTextFieldSubrole as String)
            || isEditable
            || hasEditableAncestor {
            return .iBeam
        }
        return .arrow
    }
}

/// Detects whether the pointer is over an editable accessibility element.
///
/// Accessibility lookup is intentionally best-effort and never prompts. When
/// access is unavailable, or an application does not expose useful semantics,
/// recording continues with an arrow cursor. Probes are throttled so a 120 Hz
/// mouse stream cannot saturate the main thread or the target application's AX
/// server.
@MainActor
final class CursorKindDetector {
    private let systemWideElement = AXUIElementCreateSystemWide()
    private let accessibilityTrustedOverride: Bool?
    private var lastProbeUptime = -Double.infinity
    private var cachedKind: CursorKind = .arrow

    let minimumProbeInterval: TimeInterval = 1.0 / 15.0

    init(accessibilityTrusted: Bool? = nil) {
        self.accessibilityTrustedOverride = accessibilityTrusted
    }

    func reset() {
        lastProbeUptime = -.infinity
        cachedKind = .arrow
    }

    func kind(at point: CGPoint, uptime: TimeInterval) -> CursorKind {
        guard uptime - lastProbeUptime >= minimumProbeInterval else {
            return cachedKind
        }
        lastProbeUptime = uptime
        // Permission may be enabled while the app remains open. Recheck it at
        // probe frequency without requesting access or reopening Settings.
        guard accessibilityTrustedOverride ?? AXIsProcessTrusted() else {
            cachedKind = .arrow
            return cachedKind
        }

        var hitElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &hitElement
        )
        guard result == .success, let hitElement else {
            cachedKind = .arrow
            return cachedKind
        }

        cachedKind = semanticKind(startingAt: hitElement)
        return cachedKind
    }

    private func semanticKind(startingAt element: AXUIElement) -> CursorKind {
        var current: AXUIElement? = element
        // Web content sometimes reports a static-text leaf underneath the mouse
        // and places editability on an ancestor. A small bounded walk handles
        // Chrome/Safari contenteditable without traversing an entire AX tree.
        for _ in 0..<5 {
            guard let element = current else { break }
            let role = stringAttribute(kAXRoleAttribute as CFString, of: element)
            let subrole = stringAttribute(kAXSubroleAttribute as CFString, of: element)
            let editable = boolAttribute("AXIsEditable" as CFString, of: element)
            let editableAncestor = elementAttribute("AXEditableAncestor" as CFString, of: element) != nil
            let kind = CursorKindSemantics.classify(
                role: role,
                subrole: subrole,
                isEditable: editable,
                hasEditableAncestor: editableAncestor
            )
            if kind == .iBeam { return kind }
            current = elementAttribute(kAXParentAttribute as CFString, of: element)
        }
        return .arrow
    }

    private func stringAttribute(_ name: CFString, of element: AXUIElement) -> String? {
        attribute(name, of: element) as? String
    }

    private func boolAttribute(_ name: CFString, of element: AXUIElement) -> Bool {
        (attribute(name, of: element) as? Bool) ?? false
    }

    private func elementAttribute(_ name: CFString, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func attribute(_ name: CFString, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value
    }
}
