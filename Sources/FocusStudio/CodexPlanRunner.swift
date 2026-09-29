import AppKit
import ApplicationServices
import CoreGraphics
import FocusStudioAutomation
import FocusStudioCore
import Foundation
import Security

/// Executes the intentionally small, reviewed action vocabulary produced by
/// Codex Director. It cannot type text, submit forms, invoke shell commands, or
/// interact with anything outside the selected recording window.
enum CodexPlanRunner {
    enum RunnerError: LocalizedError {
        case accessibilityPermissionRequired
        case couldNotOpenURL(URL)
        case invalidClick
        case eventCreationFailed
        case targetWindowUnavailable
        case targetWindowObscured
        case invalidActiveClock
        case windowCaptureRequired
        case invalidMovementDuration
        case invalidScroll
        case targetWindowChanged
        case targetPointOffscreen
        case targetWindowResized

        var errorDescription: String? {
            switch self {
            case .accessibilityPermissionRequired:
                return "Codex Director needs Accessibility access to perform reviewed clicks and scrolling. Enable Focus Studio in System Settings → Privacy & Security → Accessibility, then run the plan again."
            case let .couldNotOpenURL(url):
                return "Focus Studio could not open \(url.absoluteString)."
            case .invalidClick:
                return "An input action requires finite normalized coordinates between 0 and 1."
            case .eventCreationFailed:
                return "macOS could not create an automation input event."
            case .targetWindowUnavailable:
                return "The selected recording window moved off screen or closed, so Focus Studio stopped before sending another input."
            case .targetWindowObscured:
                return "The selected recording window is covered at the planned interaction point. Bring that window to the front, review the plan, and run it again."
            case .invalidActiveClock:
                return "The recording clock became invalid. Focus Studio stopped the plan before sending another input."
            case .windowCaptureRequired:
                return "Automated input requires a selected recording window. Display and area captures cannot receive automated input."
            case .invalidMovementDuration:
                return "Movement duration must be between 0.08 and 3 seconds."
            case .invalidScroll:
                return "Scrolling requires finite deltas within ±1200 pixels and a non-zero distance."
            case .targetWindowChanged:
                return "The recording window moved or resized during the action. Observe its new position before continuing."
            case .targetPointOffscreen:
                return "The interaction point is outside every connected display. Move the recording window fully on screen and observe it again."
            case .targetWindowResized:
                return "The recording window was resized. Start a new recording before sending more actions."
            }
        }
    }

    static func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw RunnerError.couldNotOpenURL(url)
        }
    }

    /// Only dispatched input is reported. The recording owner assigns a global
    /// sequence and session identity before storing these source-space samples.
    struct Interaction: Sendable {
        enum Kind: String, Sendable { case move, click, scroll, discontinuity }
        var kind: Kind
        var time: TimeInterval
        var x: Double
        var y: Double
    }

    /// A test seam for exercising input scheduling, cancellation and recording
    /// callbacks without posting events to the user's desktop.
    struct InputDriver {
        var hasAccessibilityPermission: @MainActor () -> Bool
        var prepareWindow: @MainActor (CaptureTargetInfo, Double, Double, (@MainActor () async throws -> Void)?) async throws -> CaptureRect
        var resolveWindow: @MainActor (CaptureTargetInfo, Double, Double) throws -> CaptureRect
        var move: @MainActor (CGPoint) throws -> Void
        var down: @MainActor (CGPoint) throws -> Void
        var up: @MainActor (CGPoint) -> Void
        var scroll: @MainActor (CGPoint, Double, Double) throws -> Void
        var navigate: @MainActor (URL, URL?) async throws -> Void = { url, application in
            try await open(url, with: application)
        }

        static var live: InputDriver {
            InputDriver(
                hasAccessibilityPermission: { requestAccessibilityIfNeeded() },
                prepareWindow: { target, x, y, gate in
                    try await verifiedWindowFrame(for: target, sourceX: x, sourceY: y, waitUntilReady: gate)
                },
                resolveWindow: { target, x, y in
                    try currentWindowFrame(for: target, sourceX: x, sourceY: y)
                },
                move: { point in
                    try postMouseEvent(.mouseMoved, at: point)
                },
                down: { point in
                    try postMouseEvent(.leftMouseDown, at: point)
                },
                up: { point in
                    // Releasing a button must also happen during cancellation.
                    try? postMouseEvent(.leftMouseUp, at: point)
                },
                scroll: { point, horizontal, vertical in
                    guard let event = CGEvent(
                        scrollWheelEvent2Source: nil,
                        units: .pixel,
                        wheelCount: 2,
                        wheel1: Int32((-vertical).rounded()),
                        wheel2: Int32((-horizontal).rounded()),
                        wheel3: 0
                    ) else { throw RunnerError.eventCreationFailed }
                    event.location = point
                    event.post(tap: .cghidEventTap)
                }
            )
        }
    }

    @MainActor
    static func run(
        actions: [CodexRecordingAction],
        in target: CaptureTargetInfo,
        cropInsets: SourceCropInsets? = nil,
        browserApplicationURL: URL? = nil,
        waitUntilReady: (@MainActor () async throws -> Void)? = nil,
        activeClock: (@MainActor () -> TimeInterval)? = nil,
        initialCursorPosition: CGPoint? = nil,
        onInteraction: (@MainActor (Interaction) -> Void)? = nil,
        inputDriver: InputDriver? = nil,
        onPlannedClick: @escaping @MainActor (Double, Double) -> Void = { _, _ in }
    ) async throws {
        let needsInputAutomation = actions.contains { action in
            action.type == .move || action.type == .click || action.type == .scroll
        }
        // Validate before either prompting for access or delivering any input.
        if needsInputAutomation && target.kind != .window {
            throw RunnerError.windowCaptureRequired
        }
        for action in actions { try validate(action) }
        if let point = initialCursorPosition, !isNormalized(point.x) || !isNormalized(point.y) {
            throw RunnerError.invalidClick
        }
        let driver = inputDriver ?? .live
        if needsInputAutomation && !driver.hasAccessibilityPermission() {
            throw RunnerError.accessibilityPermissionRequired
        }
        let crop = cropInsets ?? SourceCropInsets()
        // Execution traces never infer their start from an unrelated physical
        // mouse. The first actual dispatch places the pointer at this anchor.
        var cursorPosition = initialCursorPosition ?? crop.sourcePoint(x: 0.5, y: 0.5)
        var hasDispatchedPosition = initialCursorPosition != nil
        let clock = activeClock ?? { ProcessInfo.processInfo.systemUptime }
        var previousTime = -Double.infinity
        func eventTime() throws -> TimeInterval {
            let now = clock()
            guard now.isFinite, now >= 0, now >= previousTime else { throw RunnerError.invalidActiveClock }
            previousTime = now
            return now
        }
        func report(_ kind: Interaction.Kind, at position: CGPoint, time: TimeInterval) {
            onInteraction?(Interaction(kind: kind, time: time, x: position.x, y: position.y))
        }

        for action in actions {
            try Task.checkCancellation()
            try await waitUntilReady?()
            try Task.checkCancellation()
            switch action.type {
            case .wait:
                try await waitForDuration(action.seconds ?? 0, waitUntilReady: waitUntilReady, activeClock: activeClock)

            case .navigate:
                guard let value = action.url, let url = URL(string: value) else { continue }
                _ = try eventTime()
                try await driver.navigate(url, browserApplicationURL)
                report(.discontinuity, at: cursorPosition, time: try eventTime())
                // The old page's last pointer cannot imply a motion path on a
                // new page. The next dispatched move establishes a fresh anchor.
                cursorPosition = crop.sourcePoint(x: 0.5, y: 0.5)
                hasDispatchedPosition = false

            case .move, .click, .scroll:
                let sourcePoint = crop.sourcePoint(x: action.x ?? 0.5, y: action.y ?? 0.5)
                let actionFrame = try await driver.prepareWindow(target, sourcePoint.x, sourcePoint.y, waitUntilReady)
                func dispatchFrame(at point: CGPoint) throws -> CaptureRect {
                    let current = try driver.resolveWindow(target, point.x, point.y)
                    guard current == actionFrame else { throw RunnerError.targetWindowChanged }
                    return current
                }
                // The active clock is checked immediately before a dispatch, so
                // an invalid recorder clock cannot send an untraceable action.
                let started = try eventTime()
                let duration = action.seconds ?? movementDuration(from: cursorPosition, to: sourcePoint)
                let from = cursorPosition
                if !hasDispatchedPosition {
                    let frame = try dispatchFrame(at: from)
                    try driver.move(globalPoint(x: from.x, y: from.y, in: frame))
                    report(.move, at: from, time: try eventTime())
                    hasDispatchedPosition = true
                }
                // Sample the actual motion at approximately 60 Hz. Progress is
                // measured by media time, so paused recording cannot silently
                // consume an approach animation or click its final target.
                while true {
                    try Task.checkCancellation()
                    try await waitUntilReady?()
                    try Task.checkCancellation()
                    let now = try eventTime()
                    let progress = min(1, max(0, (now - started) / duration))
                    let point = interpolatedPosition(from: from, to: sourcePoint, progress: progress)
                    let frame = try dispatchFrame(at: point)
                    try driver.move(globalPoint(x: point.x, y: point.y, in: frame))
                    cursorPosition = point
                    report(.move, at: point, time: try eventTime())
                    if progress >= 1 { break }
                    try await Task.sleep(for: .milliseconds(16))
                }
                if action.type == .click {
                    try await waitUntilReady?()
                    try Task.checkCancellation()
                    _ = try eventTime()
                    let frame = try dispatchFrame(at: sourcePoint)
                    let point = globalPoint(x: sourcePoint.x, y: sourcePoint.y, in: frame)
                    try driver.down(point)
                    // Always release a pressed button, including cancellation
                    // or pausing during the small down/up interval.
                    defer { driver.up(point) }
                    report(.click, at: sourcePoint, time: try eventTime())
                    onPlannedClick(sourcePoint.x, sourcePoint.y)
                    try await Task.sleep(for: .milliseconds(45))
                } else if action.type == .scroll {
                    try await waitUntilReady?()
                    try Task.checkCancellation()
                    _ = try eventTime()
                    let frame = try dispatchFrame(at: sourcePoint)
                    let point = globalPoint(x: sourcePoint.x, y: sourcePoint.y, in: frame)
                    try driver.scroll(point, action.deltaX ?? 0, action.deltaY ?? 0)
                    report(.scroll, at: sourcePoint, time: try eventTime())
                }
            }
        }
        // The caller typically stops capture as soon as run returns. Do not
        // finish the recording while its last action is paused or transitioning.
        try await waitUntilReady?()
        try Task.checkCancellation()
    }

    static func movementDuration(from: CGPoint, to: CGPoint) -> TimeInterval {
        // Short control adjustments stay brisk; cross-window travel stays legible.
        (0.18 + hypot(to.x - from.x, to.y - from.y) * 0.55).clamped(to: 0.18...0.85)
    }

    static func interpolatedPosition(from: CGPoint, to: CGPoint, progress: Double) -> CGPoint {
        let p = progress.clamped(to: 0...1)
        if p <= 0 { return from }
        if p >= 1 { return to }
        let eased = p * p * p * (10 + p * (-15 + 6 * p))
        return CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
    }

    private static func validate(_ action: CodexRecordingAction) throws {
        switch action.type {
        case .click, .move:
            guard let x = action.x, let y = action.y, isNormalized(x), isNormalized(y) else {
                throw RunnerError.invalidClick
            }
            if let seconds = action.seconds, !seconds.isFinite || !(0.08...3).contains(seconds) {
                throw RunnerError.invalidMovementDuration
            }
        case .scroll:
            if action.x != nil || action.y != nil {
                guard let x = action.x, let y = action.y, isNormalized(x), isNormalized(y) else {
                    throw RunnerError.invalidClick
                }
            }
            let x = action.deltaX ?? 0, y = action.deltaY ?? 0
            guard x.isFinite, y.isFinite, abs(x) <= 1_200, abs(y) <= 1_200, x != 0 || y != 0 else {
                throw RunnerError.invalidScroll
            }
            if let seconds = action.seconds, !seconds.isFinite || !(0.08...3).contains(seconds) {
                throw RunnerError.invalidMovementDuration
            }
        case .wait:
            guard let seconds = action.seconds, seconds.isFinite, (0...30).contains(seconds) else {
                throw RunnerError.invalidActiveClock
            }
        case .navigate:
            guard let value = action.url, let url = URLComponents(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false else { throw RunnerError.invalidClick }
        }
    }

    private static func isNormalized(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    private static func postMouseEvent(_ type: CGEventType, at point: CGPoint) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            throw RunnerError.eventCreationFailed
        }
        event.post(tap: .cghidEventTap)
    }

    /// Tests can supply a deterministic clock. Production supplies capture
    /// duration, which freezes during pause; wall time is the compatible default.
    @MainActor
    static func waitForDuration(
        _ seconds: TimeInterval,
        waitUntilReady: (@MainActor () async throws -> Void)? = nil,
        activeClock: (@MainActor () -> TimeInterval)? = nil
    ) async throws {
        try Task.checkCancellation()
        try await waitUntilReady?()
        let clock = activeClock ?? { ProcessInfo.processInfo.systemUptime }
        let started = clock()
        guard seconds.isFinite, started.isFinite, started >= 0 else { throw RunnerError.invalidActiveClock }
        var previous = started
        while true {
            try Task.checkCancellation()
            try await waitUntilReady?()
            try Task.checkCancellation()
            let now = clock()
            guard now.isFinite, now >= previous else { throw RunnerError.invalidActiveClock }
            if now - started >= max(0, seconds) { return }
            previous = now
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func open(_ url: URL, with applicationURL: URL?) async throws {
        guard let applicationURL else {
            try open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    /// Re-resolves the ScreenCaptureKit window by its stable CGWindowID before
    /// every input. It also refuses to send an event when another layer-0 window
    /// or floating panel is in front at the intended point.
    @MainActor
    private static func verifiedWindowFrame(
        for target: CaptureTargetInfo,
        sourceX: Double,
        sourceY: Double,
        waitUntilReady: (@MainActor () async throws -> Void)?
    ) async throws -> CaptureRect {
        guard target.kind == .window else { throw RunnerError.windowCaptureRequired }
        try await waitUntilReady?()
        try Task.checkCancellation()
        try await RecordingWindowFocus.prepareForAutomation(target, waitUntilReady: waitUntilReady)
        try await waitUntilReady?()
        try Task.checkCancellation()
        return try currentWindowFrame(for: target, sourceX: sourceX, sourceY: sourceY)
    }

    @MainActor
    private static func currentWindowFrame(for target: CaptureTargetInfo, sourceX: Double, sourceY: Double) throws -> CaptureRect {
        guard target.kind == .window else { throw RunnerError.windowCaptureRequired }
        // Re-resolve on every dispatched point. The target may move, close or
        // become covered during a pause or while the cursor is approaching it.
        let snapshot = try windowSnapshot(for: target.nativeID)
        guard windowSizeMatches(snapshot.frame, captured: target.frame) else { throw RunnerError.targetWindowResized }
        let point = globalPoint(x: sourceX, y: sourceY, in: snapshot.frame)
        guard pointIsOnDisplay(point, displayFrames: activeDisplayFrames()) else {
            throw RunnerError.targetPointOffscreen
        }
        let topmost = topmostInputWindow(at: point, target: target, snapshot: snapshot)
        guard topmost?.id == target.nativeID else {
            logObstruction(targetID: target.nativeID, targetPID: snapshot.ownerPID, point: point, blocker: topmost)
            throw RunnerError.targetWindowObscured
        }
        return snapshot.frame
    }

    static func windowSizeMatches(_ current: CaptureRect, captured: CaptureRect) -> Bool {
        current.width.isFinite && current.height.isFinite && captured.width.isFinite && captured.height.isFinite
            && current.width > 0 && current.height > 0 && captured.width > 0 && captured.height > 0
            && abs(current.width - captured.width) <= 0.5 && abs(current.height - captured.height) <= 0.5
    }

    static func pointIsOnDisplay(_ point: CGPoint, displayFrames: [CGRect]) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        return displayFrames.contains { $0.width > 0 && $0.height > 0 && $0.contains(point) }
    }

    private static func activeDisplayFrames() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private struct WindowSnapshot {
        var frame: CaptureRect
        var ownerPID: pid_t
    }

    private static func windowSnapshot(for windowID: UInt32) throws -> WindowSnapshot {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            throw RunnerError.targetWindowUnavailable
        }
        guard let entry = entries.first(where: {
            ($0[kCGWindowNumber] as? NSNumber)?.uint32Value == windowID
        }), let bounds = entry[kCGWindowBounds],
              let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
              rect.width > 0, rect.height > 0,
              let pid = (entry[kCGWindowOwnerPID] as? NSNumber)?.int32Value
        else { throw RunnerError.targetWindowUnavailable }

        return WindowSnapshot(
            frame: CaptureRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: rect.width,
                height: rect.height
            ),
            ownerPID: pid_t(pid)
        )
    }

    struct InputWindow {
        var id: UInt32
        var layer: Int
        var frame: CGRect
        var alpha: Double = 1
        var ignoresMouseEvents: Bool = false
        var ownerPID: pid_t = -1
    }

    /// CGWindowList is front-to-back. Elevated windows count too: otherwise a
    /// click on the recorder's floating Pause/Discard panel would be reported
    /// as a click on the browser underneath it. Only a known pass-through
    /// window may be skipped; unknown foreign overlays are treated cautiously.
    static func firstInputWindow(at point: CGPoint, in frontToBack: [InputWindow]) -> UInt32? {
        firstInputWindowDetails(at: point, in: frontToBack)?.id
    }

    static func firstInputWindowDetails(at point: CGPoint, in frontToBack: [InputWindow]) -> InputWindow? {
        frontToBack.first {
            $0.layer >= 0 && $0.alpha.isFinite && $0.alpha > 0
                && !$0.ignoresMouseEvents && $0.frame.contains(point)
        }
    }

    /// Codex's small layer-8 cursor and WindowServer's native cursor plane are
    /// rendered over input. Each requires its exact running code identity and
    /// an AX hit on the exact prepared recording window before passing through.
    /// Unknown overlays remain blockers even if AX sees the browser below them.
    static func resolvedInputWindow(at point: CGPoint, in frontToBack: [InputWindow], targetID: UInt32,
                                    isVerifiedCursorProcess: (pid_t) -> Bool,
                                    isVerifiedSystemCursorProcess: (pid_t) -> Bool = { _ in false },
                                    hitsExactTargetWindow: () -> Bool) -> InputWindow? {
        var firstCursor: InputWindow?
        for window in frontToBack where window.layer >= 0 && window.alpha.isFinite && window.alpha > 0
            && !window.ignoresMouseEvents && window.frame.contains(point) {
            if window.id == targetID {
                return firstCursor == nil || hitsExactTargetWindow() ? window : firstCursor
            }
            let codexCursor = isCursorOverlayShape(window) && isVerifiedCursorProcess(window.ownerPID)
            let systemCursor = isSystemCursorOverlayShape(window) && isVerifiedSystemCursorProcess(window.ownerPID)
            guard codexCursor || systemCursor else { return window }
            if firstCursor == nil { firstCursor = window }
        }
        return firstCursor
    }

    static func isCursorOverlayShape(_ window: InputWindow) -> Bool {
        window.layer == 8 && window.frame.width.isFinite && window.frame.height.isFinite
            && window.frame.width > 0 && window.frame.height > 0
            && window.frame.width <= 160 && window.frame.height <= 160
            && abs(window.frame.width - window.frame.height) <= 2
    }

    static func isSystemCursorOverlayShape(_ window: InputWindow) -> Bool {
        window.layer == Int(CGWindowLevelForKey(.cursorWindow))
            && window.frame.width.isFinite && window.frame.height.isFinite
            && window.frame.width > 0 && window.frame.height > 0
            && window.frame.width <= 128 && window.frame.height <= 128
    }

    @MainActor
    private static func isVerifiedCodexCursorProcess(_ processID: pid_t) -> Bool {
        guard processID > 0,
              let application = NSRunningApplication(processIdentifier: processID), !application.isTerminated,
              application.bundleIdentifier == "com.openai.sky.CUAService",
              application.executableURL?.lastPathComponent == "SkyComputerUseService" else { return false }
        let identity = "anchor apple generic and identifier \"com.openai.sky.CUAService\" and certificate leaf[subject.OU] = \"2DC432GLL2\""
        return runningCodeMatches(processID, identity: identity)
    }

    private static func isVerifiedWindowServerProcess(_ processID: pid_t) -> Bool {
        // WindowServer is not a GUI application and has no Team ID. Validate
        // its running code against Apple's OS signing anchor and exact ID;
        // neither a process name, fixed PID, nor cursor-level window suffices.
        runningCodeMatches(processID, identity: "anchor apple and identifier \"com.apple.WindowServer\"")
    }

    private static func runningCodeMatches(_ processID: pid_t, identity: String) -> Bool {
        guard processID > 0 else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(identity as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        var code: SecCode?
        return SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: processID] as CFDictionary, [], &code) == errSecSuccess
            && code.map { SecCodeCheckValidity($0, [], requirement) == errSecSuccess } == true
    }

    @MainActor
    private static func hitMatchesTarget(at point: CGPoint, target: CaptureTargetInfo, snapshot: WindowSnapshot) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return false }
        var hitPID: pid_t = -1
        guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == snapshot.ownerPID else { return false }
        AXUIElementSetMessagingTimeout(hit, 0.15)
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &rawWindow) == .success,
              let rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return false }
        let window = unsafeBitCast(rawWindow, to: AXUIElement.self)
        return RecordingWindowFocus.hitMatchesPreparedWindow(window, target: target, ownerPID: snapshot.ownerPID, currentFrame: snapshot.frame)
    }

    @MainActor
    private static func topmostInputWindow(at point: CGPoint, target: CaptureTargetInfo, snapshot: WindowSnapshot) -> InputWindow? {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }
        let ownWindows = NSApplication.shared.windows
        let windows: [InputWindow] = entries.compactMap { entry in
            guard let id = (entry[kCGWindowNumber] as? NSNumber)?.uint32Value,
                  let layer = (entry[kCGWindowLayer] as? NSNumber)?.intValue,
                  let bounds = entry[kCGWindowBounds] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            let ownWindow = (entry[kCGWindowOwnerPID] as? NSNumber)?.int32Value == getpid()
                ? ownWindows.first { $0.windowNumber == Int(id) } : nil
            return InputWindow(id: id, layer: layer, frame: rect,
                               alpha: (entry[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1,
                               ignoresMouseEvents: ownWindow?.ignoresMouseEvents ?? false,
                               ownerPID: (entry[kCGWindowOwnerPID] as? NSNumber)?.int32Value ?? -1)
        }
        return resolvedInputWindow(at: point, in: windows, targetID: target.nativeID,
                                   isVerifiedCursorProcess: isVerifiedCodexCursorProcess,
                                   isVerifiedSystemCursorProcess: isVerifiedWindowServerProcess,
                                   hitsExactTargetWindow: { hitMatchesTarget(at: point, target: target, snapshot: snapshot) })
    }

    /// Facts only: no title, URL, accessibility label or field value is read.
    /// This intentionally does not let an AX result override an unknown
    /// covering window, or equate two windows merely because their PIDs match.
    @MainActor
    private static func logObstruction(targetID: UInt32, targetPID: pid_t, point: CGPoint, blocker: InputWindow?) {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var hit: AXUIElement?
        let hitStatus = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        var hitPID: pid_t = -1
        var windowFrame: CGRect?
        if hitStatus == .success, let hit {
            _ = AXUIElementGetPid(hit, &hitPID)
            var rawWindow: CFTypeRef?
            if AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &rawWindow) == .success,
               let rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID() {
                let window = unsafeBitCast(rawWindow, to: AXUIElement.self)
                var position: CFTypeRef?, size: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                   AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
                   let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                    var origin = CGPoint.zero, dimensions = CGSize.zero
                    if AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin),
                       AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) {
                        windowFrame = CGRect(origin: origin, size: dimensions)
                    }
                }
            }
        }
        let line = "\(Date().ISO8601Format()) " + obstructionDiagnostic(targetID: targetID, targetPID: targetPID,
            point: point, blocker: blocker, axStatus: hitStatus.rawValue, axPID: hitPID, axWindowFrame: windowFrame) + "\n"
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let folder = support.appendingPathComponent("FocusStudio/diagnostics", isDirectory: true)
        let file = folder.appendingPathComponent("window-input.log")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous = (try? Data(contentsOf: file)) ?? Data()
        var data = previous.count <= 64_000 ? previous : Data()
        data.append(contentsOf: line.utf8)
        try? data.write(to: file, options: .atomic)
    }

    static func obstructionDiagnostic(targetID: UInt32, targetPID: pid_t, point: CGPoint, blocker: InputWindow?,
                                      axStatus: Int32, axPID: pid_t, axWindowFrame: CGRect?) -> String {
        func bounds(_ frame: CGRect?) -> String {
            frame.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? "missing"
        }
        return "target_id=\(targetID) target_pid=\(targetPID) point=\(point.x),\(point.y) blocker_id=\(blocker?.id ?? 0) blocker_pid=\(blocker?.ownerPID ?? -1) blocker_layer=\(blocker?.layer ?? -1) blocker_bounds=\(bounds(blocker?.frame)) blocker_alpha=\(blocker?.alpha ?? -1) ax_status=\(axStatus) ax_pid=\(axPID) ax_window_bounds=\(bounds(axWindowFrame))"
    }

    private static func globalPoint(x: Double, y: Double, in frame: CaptureRect) -> CGPoint {
        CGPoint(
            x: frame.x + frame.width * x,
            y: frame.y + frame.height * y
        )
    }

    private static func requestAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
