import Foundation

public enum EventMonitorRegistrationPolicy {
    /// Registering a global key monitor can itself trigger the Input Monitoring
    /// prompt. Only install it after both existing grants are confirmed.
    public static func allowsGlobalKeyboardMonitor(
        accessibilityTrusted: Bool,
        inputMonitoringTrusted: Bool
    ) -> Bool {
        accessibilityTrusted && inputMonitoringTrusted
    }
}

/// Registration/permission facts and aggregate counts only. No input contents,
/// key codes, application titles, or typed text are included in diagnostics.
public struct EventMonitorDiagnostics: Codable, Equatable, Sendable {
    public var accessibilityTrusted = false
    public var inputMonitoringTrusted = false
    public var globalMouseMonitorRegistered = false
    public var globalKeyboardMonitorRegistered = false
    public var localMouseMonitorRegistered = false
    public var localKeyboardMonitorRegistered = false
    public var globalMouseEvents = 0
    public var globalKeyboardEvents = 0
    public var localMouseEvents = 0
    public var localKeyboardEvents = 0
    public var storedCursorSamples = 0
    public var storedClicks = 0
    public var storedTypingActivity = 0
    public var mouseEventsMissingPosition = 0
    public var mouseEventsBeforeAnchor = 0
    public var mouseEventsBeforeStartTimestamp = 0
    public var mouseEventsOutsideCapture = 0
    public var keyboardEventsBeforeAnchor = 0
    public var keyboardEventsBeforeStartTimestamp = 0
    public var keyboardEventsRejectedByFocusOrThrottle = 0
    public var lastMouseNativeTimeOffset: Double?
    public var lastMouseReceiptTimeOffset: Double?
    public var lastKeyboardNativeTimeOffset: Double?
    public var lastKeyboardReceiptTimeOffset: Double?
    public var axObserverAttachments = 0
    public var axEditableSubscriptions = 0
    public var axFocusNotifications = 0
    public var axValueNotifications = 0
    public var axSelectionNotifications = 0
    public var axFocusActivities = 0
    public var axValueActivities = 0
    public var axSelectionActivities = 0
    public var axActivitiesBeforeAnchor = 0
    public var axActivitiesBeforeStartTimestamp = 0
    public var axActivitiesRejectedByFocusOrThrottle = 0

    public init() {}

    public var hasAnyMonitor: Bool {
        globalMouseMonitorRegistered || globalKeyboardMonitorRegistered
            || localMouseMonitorRegistered || localKeyboardMonitorRegistered
    }

    public var externalMouseMonitorRegistered: Bool { globalMouseMonitorRegistered }
    public var externalTypingMonitorRegistered: Bool {
        EventMonitorRegistrationPolicy.allowsGlobalKeyboardMonitor(
            accessibilityTrusted: accessibilityTrusted,
            inputMonitoringTrusted: inputMonitoringTrusted
        ) && globalKeyboardMonitorRegistered
    }

    public var warning: String? {
        var warnings: [String] = []
        if !externalMouseMonitorRegistered {
            warnings.append("External mouse tracking could not start. Click-to-zoom in other apps is unavailable.")
        } else if !inputMonitoringTrusted {
            warnings.append("Input Monitoring is off. External cursor and click events may be unavailable.")
        }
        if !externalTypingMonitorRegistered {
            if !accessibilityTrusted {
                warnings.append("Accessibility is off. Enable Focus Studio in Privacy & Security > Accessibility for typing focus in other apps.")
            } else if !inputMonitoringTrusted {
                warnings.append("Global keyboard tracking is off. Supported input fields can still keep zoom focused through Accessibility.")
            } else {
                warnings.append("External keyboard activity tracking could not start. Reopen the recorder to retry.")
            }
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: " ") + " Video recording continues normally."
    }
}
