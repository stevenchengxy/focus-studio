import Foundation
import FocusStudioCore
import FocusStudioCapture

func typingActivityCaptureFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }
    expect(!EventMonitorRegistrationPolicy.allowsGlobalKeyboardMonitor(
        accessibilityTrusted: true, inputMonitoringTrusted: false),
        "Accessibility alone must not trigger a global key registration and its Input Monitoring prompt")
    expect(!EventMonitorRegistrationPolicy.allowsGlobalKeyboardMonitor(
        accessibilityTrusted: false, inputMonitoringTrusted: true),
        "Input Monitoring alone must not install an Accessibility-gated global keyboard monitor")
    expect(!EventMonitorRegistrationPolicy.allowsGlobalKeyboardMonitor(
        accessibilityTrusted: false, inputMonitoringTrusted: false),
        "an unconfigured app must not register global keyboard monitoring")
    expect(EventMonitorRegistrationPolicy.allowsGlobalKeyboardMonitor(
        accessibilityTrusted: true, inputMonitoringTrusted: true),
        "global keyboard registration is allowed only after both grants already exist")
    var localOnly = EventMonitorDiagnostics()
    localOnly.localMouseMonitorRegistered = true
    localOnly.localKeyboardMonitorRegistered = true
    expect(localOnly.hasAnyMonitor && !localOnly.externalMouseMonitorRegistered,
           "local-only monitoring must never be reported as external mouse tracking")
    expect(localOnly.warning?.contains("Click-to-zoom") == true,
           "missing global mouse registration needs an explicit nonblocking warning")
    var independentMouse = localOnly
    independentMouse.globalMouseMonitorRegistered = true
    expect(independentMouse.externalMouseMonitorRegistered && !independentMouse.externalTypingMonitorRegistered,
           "mouse registration must stay independent of inaccessible global keyboard monitoring")
    expect(independentMouse.warning?.contains("Accessibility") == true
           && independentMouse.warning?.contains("Click-to-zoom") == false,
           "keyboard authorization failures must not incorrectly mark registered mouse tracking as unavailable")
    var authorized = independentMouse
    authorized.accessibilityTrusted = true
    authorized.globalKeyboardMonitorRegistered = true
    expect(authorized.warning?.contains("Input Monitoring") == true,
           "registered event monitors must still report ungranted Input Monitoring without claiming events were observed")
    expect(authorized.warning?.contains("through Accessibility") == true
           && !authorized.externalTypingMonitorRegistered,
           "with Input Monitoring off the app must describe AX field-change fallback without claiming global key access")
    authorized.inputMonitoringTrusted = true
    expect(authorized.externalTypingMonitorRegistered && authorized.warning == nil,
           "authorized independent mouse and keyboard registrations should be usable without extra prompts")
    expect(authorized.globalMouseEvents == 0 && authorized.globalKeyboardEvents == 0,
           "registered monitors must not fabricate evidence of observed input")
    let captured = CaptureRect(x: 100, y: 200, width: 400, height: 200)
    let field = CaptureRect(x: 200, y: 225, width: 180, height: 80)
    let focused = TypingFocusContext(processID: 42, windowID: 7, semantics: .editable(field))
    var resolver = TypingActivityResolver(captureRect: captured, targetProcessID: 42, targetWindowID: 7)
    resolver.noteClick(x: 260, y: 240, context: focused)
    let initial = resolver.activity(uptime: 100.2, startUptime: 100, context: focused)
    expect(initial.map { abs($0.time - 0.2) < 0.0001 && $0.x == 0.4 && $0.y == 0.2 } ?? false,
           "typing must use video-relative time and the normalized input-click anchor")
    expect(resolver.activity(uptime: 100.24, startUptime: 100, context: focused) == nil,
           "key repeat activity must be throttled to ten samples per second")
    let repeated = resolver.activity(uptime: 100.7, startUptime: 100, context: focused)
    expect(repeated?.x == initial?.x && repeated?.y == initial?.y,
           "typing must hold the focused input location independently of pointer movement")
    expect(resolver.activity(uptime: 101, startUptime: 100,
           context: .init(processID: 43, windowID: 7, semantics: .editable(field))) == nil,
           "typing in another application must not affect a captured window")
    expect(resolver.activity(uptime: 101, startUptime: 100,
           context: .init(processID: 42, windowID: 8, semantics: .editable(field))) == nil,
           "typing into another window in the same app must not extend zoom")
    expect(resolver.activity(uptime: 101, startUptime: 100,
           context: .init(processID: 42, semantics: .editable(field))) == nil,
           "a window capture must reject unverified focused-window identity")
    expect(resolver.activity(uptime: 101, startUptime: 100,
           context: .init(processID: 42, windowID: 7, semantics: .notEditable)) == nil,
           "a known non-editable focused element must not count as typing")
    expect(resolver.activity(uptime: 99, startUptime: 100, context: focused) == nil,
           "keyboard activity before the first video frame must be discarded")

    let unavailable = TypingFocusContext(processID: 42, windowID: 7)
    expect(resolver.activity(uptime: 101.2, startUptime: 100, context: unavailable)?.x == 0.4,
           "missing app accessibility semantics should reuse a same-app/window clicked anchor")
    resolver.noteClick(x: 800, y: 240, context: unavailable)
    expect(resolver.activity(uptime: 101.5, startUptime: 100, context: unavailable) == nil,
           "clicking outside the capture must invalidate fallback typing focus")
    var noClick = TypingActivityResolver(captureRect: captured)
    expect(noClick.activity(uptime: 101, startUptime: 100, context: unavailable) == nil,
           "unknown focus without an in-target click must not guess a typing position")

    var area = TypingActivityResolver(captureRect: CaptureRect(x: -100, y: -50, width: 200, height: 100))
    let partlyVisible = area.activity(uptime: 101, startUptime: 100, context: .init(
        processID: 42, windowID: 7,
        semantics: .editable(CaptureRect(x: 80, y: -10, width: 100, height: 40))
    ))
    expect(partlyVisible?.x == 0.95 && partlyVisible?.y == 0.6,
           "partially visible input bounds must clip correctly in negative-coordinate area recordings")
    expect(area.activity(uptime: 102, startUptime: 100, context: .init(
        processID: 42, windowID: 7,
        semantics: .editable(CaptureRect(x: 300, y: 300, width: 100, height: 40)))) == nil,
           "focused fields outside the selected area must not produce typing activity")
    var display = TypingActivityResolver(captureRect: captured, excludedProcessID: 42)
    expect(display.activity(uptime: 101, startUptime: 100, context: focused) == nil,
           "the recorder's own excluded overlay must not create typing activity")

    if let initial, let encoded = try? JSONEncoder().encode(initial),
       let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
        expect(Set(object.keys) == Set(["time", "x", "y"]),
               "persisted typing metadata must contain only activity time and position")
    } else {
        failures.append("typing metadata privacy shape could not be verified")
    }
    return failures
}

@MainActor
func accessibilityActivityTraceFailures() -> [String] {
    #if DEBUG
    var failures: [String] = []
    let monitor = EventMonitor()
    let context = TypingFocusContext(processID: 42, windowID: 7,
        semantics: .editable(CaptureRect(x: 150, y: 225, width: 100, height: 50)))
    do {
        try monitor.prepare(captureRect: .init(x: 100, y: 200, width: 400, height: 200),
                            targetProcessID: 42, targetWindowID: 7)
        monitor.injectAccessibilityActivityForTesting(uptime: 999, context: context)
        if monitor.diagnostics.axActivitiesBeforeAnchor != 1 || !monitor.typingActivity.isEmpty {
            failures.append("AX activity before the first video frame must be counted and discarded")
        }
        monitor.anchor(at: 1_000)
        monitor.injectAccessibilityActivityForTesting(uptime: 1_000.2, context: context)
        monitor.injectAccessibilityActivityForTesting(uptime: 1_000.21, context: context)
        monitor.injectAccessibilityActivityForTesting(uptime: 1_000.5, context: context)
        if monitor.snapshot().typingActivity.count != 2 {
            failures.append("AX edit notifications must feed the same throttled, anchored typing trace")
        }
        monitor.injectAccessibilityActivityForTesting(uptime: 1_001, context: .init(
            processID: 42, windowID: 8,
            semantics: .editable(CaptureRect(x: 150, y: 225, width: 100, height: 50))))
        if monitor.typingActivity.count != 2 || monitor.diagnostics.axActivitiesRejectedByFocusOrThrottle != 2 {
            failures.append("AX activity from other windows and duplicate notifications must be rejected")
        }
        monitor.stop()
        monitor.injectAccessibilityActivityForTesting(uptime: 1_002, context: context)
        if monitor.typingActivity.count != 2 {
            failures.append("stopped AX observers must not append project metadata")
        }
    } catch {
        failures.append("AX activity trace test setup failed: \(error.localizedDescription)")
    }
    monitor.stop()
    return failures
    #else
    return []
    #endif
}
