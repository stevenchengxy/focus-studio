import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import FocusStudioCore

/// Collects mouse movement and click metadata while a recording is in progress.
///
/// ScreenCaptureKit and `CGEvent.location` both use the Quartz global display
/// coordinate space, so the captured points can be normalized directly against
/// a `CaptureTargetInfo.frame`. Samples outside that frame are intentionally
/// ignored: clicks in another app should not create a zoom in the recording.
@MainActor
public final class EventMonitor: ObservableObject {
    public enum MonitorError: LocalizedError, Sendable {
        case invalidCaptureRect
        case unableToInstallGlobalMonitor

        public var errorDescription: String? {
            switch self {
            case .invalidCaptureRect:
                return "The capture rectangle must have a positive width and height."
            case .unableToInstallGlobalMonitor:
                return "macOS could not install the global mouse event monitor."
            }
        }
    }

    @Published public private(set) var isMonitoring = false

    /// A non-fatal input-monitoring warning. Screen recording can continue when set.
    @Published public private(set) var lastError: String?

    /// Cursor positions in the capture's normalized 0...1 coordinate space.
    public private(set) var cursorSamples: [CursorSample] = []

    /// Mouse-down events in the capture's normalized 0...1 coordinate space.
    public private(set) var clickEvents: [ClickEvent] = []

    /// Activity locations/times only; typed content and key codes are never stored.
    public private(set) var typingActivity: [TypingActivity] = []

    /// The monotonic timestamp used as zero for all emitted event times.
    public private(set) var monotonicStartTimestamp: TimeInterval?

    /// Limits high-frequency mouse-move traffic. Defaults to 120 samples/second.
    public var minimumSampleInterval: TimeInterval = 1.0 / 120.0

    /// Called on the main actor after a cursor sample is stored.
    public var onCursorSample: ((CursorSample) -> Void)?

    /// Called on the main actor after a click event is stored.
    public var onClick: ((ClickEvent) -> Void)?

    private var captureRect: CaptureRect?
    private let monitorTokens = EventMonitorTokens()
    private let cursorKindDetector = CursorKindDetector()
    private let focusedTypingDetector = FocusedTypingDetector()
    private var typingResolver: TypingActivityResolver?
    private var lastCursorSampleTime: TimeInterval = -.infinity
    private var lastCursorKind: CursorKind = .arrow
    private var monitorGeneration = UUID()
    private var eventDiagnostics = EventMonitorDiagnostics()
    private var accessibilityTypingMonitor: AccessibilityTypingMonitor?

    public var diagnostics: EventMonitorDiagnostics {
        var value = eventDiagnostics
        value.storedCursorSamples = cursorSamples.count
        value.storedClicks = clickEvents.count
        value.storedTypingActivity = typingActivity.count
        return value
    }

    private static let mouseEventMask: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
    ]

    public init() {}

    /// Starts a fresh event trace.
    ///
    /// - Parameters:
    ///   - captureRect: The target frame in Quartz global display coordinates.
    ///   - timestamp: A `ProcessInfo.systemUptime` value shared with the capture
    ///     engine. Supplying the same value keeps cursor and video timelines aligned.
    public func start(
        captureRect: CaptureRect,
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) throws {
        try prepare(captureRect: captureRect)
        anchor(at: timestamp)
    }

    /// Installs event monitors but deliberately leaves the trace unanchored.
    /// Events received before `anchor(at:)` are discarded. CaptureEngine uses this
    /// two-phase API to set time zero from the first complete ScreenCaptureKit frame.
    public func prepare(
        captureRect: CaptureRect,
        targetProcessID: Int32? = nil,
        targetWindowID: UInt32? = nil
    ) throws {
        guard captureRect.width > 0, captureRect.height > 0 else {
            throw MonitorError.invalidCaptureRect
        }

        stop()
        reset()

        self.captureRect = captureRect
        lastCursorSampleTime = -.infinity
        lastCursorKind = .arrow
        cursorKindDetector.reset()
        focusedTypingDetector.reset()
        typingResolver = TypingActivityResolver(
            captureRect: captureRect, targetProcessID: targetProcessID, targetWindowID: targetWindowID,
            excludedProcessID: targetWindowID == nil ? ProcessInfo.processInfo.processIdentifier : nil
        )
        lastError = nil

        let generation = monitorGeneration
        eventDiagnostics.accessibilityTrusted = AXIsProcessTrusted()
        eventDiagnostics.inputMonitoringTrusted = CGPreflightListenEventAccess()

        // Keep registration independent: key monitoring needs Accessibility,
        // while mouse monitoring must not inherit that key-event requirement.
        monitorTokens.globalMouse = NSEvent.addGlobalMonitorForEvents(matching: Self.mouseEventMask) { [weak self] event in
            let payload = MouseEventPayload(event: event)
            let nativeUptime = event.timestamp
            Task { @MainActor [weak self] in
                guard let self, self.monitorGeneration == generation, self.isMonitoring else { return }
                self.eventDiagnostics.globalMouseEvents += 1
                self.observeMouse(payload, nativeUptime: nativeUptime)
            }
        }
        if EventMonitorRegistrationPolicy.allowsGlobalKeyboardMonitor(
            accessibilityTrusted: eventDiagnostics.accessibilityTrusted,
            inputMonitoringTrusted: eventDiagnostics.inputMonitoringTrusted
        ) {
            monitorTokens.globalKeyboard = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let uptime = event.timestamp
                Task { @MainActor [weak self] in
                    guard let self, self.monitorGeneration == generation, self.isMonitoring else { return }
                    self.eventDiagnostics.globalKeyboardEvents += 1
                    self.consumeTyping(at: uptime)
                }
            }
        }

        // A global monitor does not receive events delivered to this application.
        // The local monitor fills that gap without consuming or changing the event.
        monitorTokens.localMouse = NSEvent.addLocalMonitorForEvents(matching: Self.mouseEventMask) { [weak self] event in
            let payload = MouseEventPayload(event: event)
            let nativeUptime = event.timestamp
            Task { @MainActor [weak self] in
                guard let self, self.monitorGeneration == generation, self.isMonitoring else { return }
                self.eventDiagnostics.localMouseEvents += 1
                self.observeMouse(payload, nativeUptime: nativeUptime)
            }
            return event
        }
        monitorTokens.localKeyboard = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let uptime = event.timestamp
            Task { @MainActor [weak self] in
                guard let self, self.monitorGeneration == generation, self.isMonitoring else { return }
                self.eventDiagnostics.localKeyboardEvents += 1
                self.consumeTyping(at: uptime)
            }
            return event
        }

        eventDiagnostics.globalMouseMonitorRegistered = monitorTokens.globalMouse != nil
        eventDiagnostics.globalKeyboardMonitorRegistered = monitorTokens.globalKeyboard != nil
        eventDiagnostics.localMouseMonitorRegistered = monitorTokens.localMouse != nil
        eventDiagnostics.localKeyboardMonitorRegistered = monitorTokens.localKeyboard != nil

        guard eventDiagnostics.hasAnyMonitor else {
            stop()
            throw MonitorError.unableToInstallGlobalMonitor
        }

        isMonitoring = true

        accessibilityTypingMonitor = AccessibilityTypingMonitor(
            detector: focusedTypingDetector,
            targetProcessID: targetProcessID,
            excludesCurrentProcess: targetWindowID == nil,
            onSignal: { [weak self] signal in
                guard let self, self.monitorGeneration == generation, self.isMonitoring else { return }
                switch signal {
                case .observerAttached: self.eventDiagnostics.axObserverAttachments += 1
                case .editableSubscribed: self.eventDiagnostics.axEditableSubscriptions += 1
                case .focusNotification: self.eventDiagnostics.axFocusNotifications += 1
                case .valueNotification: self.eventDiagnostics.axValueNotifications += 1
                case .selectionNotification: self.eventDiagnostics.axSelectionNotifications += 1
                case .focusActivity: self.eventDiagnostics.axFocusActivities += 1
                case .valueActivity: self.eventDiagnostics.axValueActivities += 1
                case .selectionActivity: self.eventDiagnostics.axSelectionActivities += 1
                }
            },
            onActivity: { [weak self] uptime, context in
                guard let self, self.monitorGeneration == generation else { return }
                self.consumeTyping(at: uptime, context: context, isAccessibilityActivity: true)
            }
        )
        accessibilityTypingMonitor?.start()

        lastError = eventDiagnostics.warning
    }

    /// Sets the trace's actual zero point in the monotonic system-uptime clock.
    /// Calling this more than once is harmless; the first anchor always wins.
    public func anchor(at timestamp: TimeInterval) {
        guard isMonitoring, monotonicStartTimestamp == nil else { return }
        monotonicStartTimestamp = timestamp

        // Seed the trace so renderers have a cursor position at time zero even if
        // the user does not move the mouse immediately after recording begins.
        if let location = CGEvent(source: nil)?.location {
            consume(
                MouseEventPayload(
                    uptime: timestamp,
                    x: location.x,
                    y: location.y,
                    kind: .movement,
                    button: nil
                ),
                forceCursorSample: true
            )
        }
    }

    /// Stops monitoring while retaining all samples for project creation.
    public func stop() {
        isMonitoring = false
        monitorGeneration = UUID()
        monitorTokens.removeAll()
        accessibilityTypingMonitor?.stop()
        accessibilityTypingMonitor = nil
    }

    /// Clears the current trace. Monitoring is not stopped by this method.
    public func reset() {
        cursorSamples.removeAll(keepingCapacity: true)
        clickEvents.removeAll(keepingCapacity: true)
        typingActivity.removeAll(keepingCapacity: true)
        monotonicStartTimestamp = nil
        captureRect = nil
        lastCursorSampleTime = -.infinity
        lastCursorKind = .arrow
        cursorKindDetector.reset()
        focusedTypingDetector.reset()
        typingResolver = nil
        eventDiagnostics = .init()
        lastError = nil
    }

    /// Returns stable value copies suitable for creating a `RecordingProject`.
    public func snapshot() -> (cursorSamples: [CursorSample], clickEvents: [ClickEvent], typingActivity: [TypingActivity]) {
        (cursorSamples, clickEvents, typingActivity)
    }

    #if DEBUG
    /// Feeds the same normalization/storage path as the NSEvent monitors without
    /// posting a system-wide click. Used only by the deterministic E2E executable.
    public func injectEventForTesting(
        uptime: TimeInterval,
        x: Double,
        y: Double,
        button: MouseButton? = nil,
        cursorKind: CursorKind? = nil
    ) {
        consume(
            MouseEventPayload(
                uptime: uptime,
                x: x,
                y: y,
                kind: button == nil ? .movement : .mouseDown,
                button: button,
                cursorKind: cursorKind
            )
        )
    }

    public func injectTypingAnchorForTesting(x: Double, y: Double, context: TypingFocusContext) {
        typingResolver?.noteClick(x: x, y: y, context: context)
    }

    public func injectTypingActivityForTesting(uptime: TimeInterval, context: TypingFocusContext) {
        consumeTyping(at: uptime, context: context)
    }

    public func injectAccessibilityActivityForTesting(uptime: TimeInterval, context: TypingFocusContext) {
        consumeTyping(at: uptime, context: context, isAccessibilityActivity: true)
    }
    #endif

    private func consumeTyping(
        at uptime: TimeInterval,
        context: TypingFocusContext? = nil,
        isAccessibilityActivity: Bool = false
    ) {
        guard isMonitoring else { return }
        guard let start = monotonicStartTimestamp else {
            if isAccessibilityActivity { eventDiagnostics.axActivitiesBeforeAnchor += 1 }
            else { eventDiagnostics.keyboardEventsBeforeAnchor += 1 }
            return
        }
        if !isAccessibilityActivity {
            eventDiagnostics.lastKeyboardNativeTimeOffset = uptime - start
            eventDiagnostics.lastKeyboardReceiptTimeOffset = ProcessInfo.processInfo.systemUptime - start
        }
        guard uptime >= start else {
            if isAccessibilityActivity { eventDiagnostics.axActivitiesBeforeStartTimestamp += 1 }
            else { eventDiagnostics.keyboardEventsBeforeStartTimestamp += 1 }
            return
        }
        let focus = context ?? focusedTypingDetector.context(uptime: uptime)
        if let activity = typingResolver?.activity(uptime: uptime, startUptime: start, context: focus) {
            typingActivity.append(activity)
        } else {
            if isAccessibilityActivity { eventDiagnostics.axActivitiesRejectedByFocusOrThrottle += 1 }
            else { eventDiagnostics.keyboardEventsRejectedByFocusOrThrottle += 1 }
        }
    }

    private func observeMouse(_ payload: MouseEventPayload?, nativeUptime: TimeInterval) {
        if let start = monotonicStartTimestamp {
            eventDiagnostics.lastMouseNativeTimeOffset = nativeUptime - start
            eventDiagnostics.lastMouseReceiptTimeOffset = ProcessInfo.processInfo.systemUptime - start
        }
        guard let payload else {
            eventDiagnostics.mouseEventsMissingPosition += 1
            return
        }
        consume(payload)
    }

    private func consume(_ payload: MouseEventPayload, forceCursorSample: Bool = false) {
        guard isMonitoring || forceCursorSample, let captureRect else { return }
        guard let start = monotonicStartTimestamp else {
            eventDiagnostics.mouseEventsBeforeAnchor += 1
            return
        }
        guard payload.uptime >= start else {
            eventDiagnostics.mouseEventsBeforeStartTimestamp += 1
            return
        }

        if payload.kind == .mouseDown {
            typingResolver?.noteClick(
                x: payload.x, y: payload.y,
                context: focusedTypingDetector.context(uptime: payload.uptime, force: true)
            )
        }
        guard let point = normalizedPoint(x: payload.x, y: payload.y, in: captureRect) else {
            eventDiagnostics.mouseEventsOutsideCapture += 1
            return
        }

        let relativeTime = max(0, payload.uptime - start)
        guard payload.uptime >= start else { return }
        let cursorKind = payload.cursorKind ?? cursorKindDetector.kind(
            at: CGPoint(x: payload.x, y: payload.y),
            uptime: payload.uptime
        )
        let shouldStoreCursor = forceCursorSample
            || payload.kind == .mouseDown
            || cursorKind != lastCursorKind
            || relativeTime - lastCursorSampleTime >= max(0, minimumSampleInterval)

        if shouldStoreCursor {
            let sample = CursorSample(
                time: relativeTime,
                x: point.x,
                y: point.y,
                cursorKind: cursorKind
            )
            cursorSamples.append(sample)
            lastCursorSampleTime = relativeTime
            lastCursorKind = cursorKind
            onCursorSample?(sample)
        }

        if payload.kind == .mouseDown, let button = payload.button {
            let click = ClickEvent(
                time: relativeTime,
                x: point.x,
                y: point.y,
                button: button
            )
            clickEvents.append(click)
            onClick?(click)
        }
    }

    private func normalizedPoint(
        x: Double,
        y: Double,
        in rect: CaptureRect
    ) -> (x: Double, y: Double)? {
        let localX = (x - rect.x) / rect.width
        let localY = (y - rect.y) / rect.height

        // Allow a very small tolerance for points delivered exactly on a display edge.
        let tolerance = 0.000_001
        guard
            localX >= -tolerance,
            localX <= 1 + tolerance,
            localY >= -tolerance,
            localY <= 1 + tolerance
        else { return nil }

        return (
            min(max(localX, 0), 1),
            min(max(localY, 0), 1)
        )
    }
}

/// NSEvent represents monitor tokens as `Any`. Keeping them in a deliberately
/// unchecked wrapper lets Swift 6 tear them down from `deinit`; all mutation is
/// still performed by EventMonitor on the main actor.
private final class EventMonitorTokens: @unchecked Sendable {
    var globalMouse: Any?
    var globalKeyboard: Any?
    var localMouse: Any?
    var localKeyboard: Any?

    func removeAll() {
        for token in [globalMouse, globalKeyboard, localMouse, localKeyboard] {
            if let token { NSEvent.removeMonitor(token) }
        }
        globalMouse = nil
        globalKeyboard = nil
        localMouse = nil
        localKeyboard = nil
    }

    deinit { removeAll() }
}

private struct MouseEventPayload: Sendable {
    enum Kind: Sendable {
        case movement
        case mouseDown
    }

    var uptime: TimeInterval
    var x: Double
    var y: Double
    var kind: Kind
    var button: MouseButton?
    var cursorKind: CursorKind?

    init(
        uptime: TimeInterval,
        x: Double,
        y: Double,
        kind: Kind,
        button: MouseButton?,
        cursorKind: CursorKind? = nil
    ) {
        self.uptime = uptime
        self.x = x
        self.y = y
        self.kind = kind
        self.button = button
        self.cursorKind = cursorKind
    }

    init?(event: NSEvent) {
        guard let location = event.cgEvent?.location ?? CGEvent(source: nil)?.location else {
            return nil
        }

        uptime = ProcessInfo.processInfo.systemUptime
        x = location.x
        y = location.y
        cursorKind = nil

        switch event.type {
        case .leftMouseDown:
            kind = .mouseDown
            button = .left
        case .rightMouseDown:
            kind = .mouseDown
            button = .right
        case .otherMouseDown:
            kind = .mouseDown
            button = .other
        default:
            kind = .movement
            button = nil
        }
    }
}
