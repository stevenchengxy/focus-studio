import AppKit
import ApplicationServices
import CoreFoundation
import Foundation

/// Observes changes to a focused editable accessibility object without reading
/// its value, selected text, selection range, or any keyboard event contents.
@MainActor
final class AccessibilityTypingMonitor {
    enum Signal {
        case observerAttached
        case editableSubscribed
        case focusNotification
        case valueNotification
        case selectionNotification
        case focusActivity
        case valueActivity
        case selectionActivity
    }

    private let detector: FocusedTypingDetector
    private let targetProcessID: Int32?
    private let excludesCurrentProcess: Bool
    private let onSignal: (Signal) -> Void
    private let onActivity: (TimeInterval, TypingFocusContext) -> Void
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var focusedElement: AXUIElement?
    private var processID: Int32?
    private var activationToken: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var isRunning = false
    private var generation = UUID()

    init(
        detector: FocusedTypingDetector,
        targetProcessID: Int32?,
        excludesCurrentProcess: Bool,
        onSignal: @escaping (Signal) -> Void,
        onActivity: @escaping (TimeInterval, TypingFocusContext) -> Void
    ) {
        self.detector = detector
        self.targetProcessID = targetProcessID
        self.excludesCurrentProcess = excludesCurrentProcess
        self.onSignal = onSignal
        self.onActivity = onActivity
    }

    func start() {
        stop()
        guard AXIsProcessTrusted() else { return }
        isRunning = true
        let generation = generation
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.refreshFocus()
            }
        }
        // Some web apps omit focus-change notifications. Reconcile identity,
        // but never use continued focus as evidence that typing is occurring.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.refreshFocus()
            }
        }
        if let refreshTimer { RunLoop.main.add(refreshTimer, forMode: .common) }
        refreshFocus()
    }

    func stop() {
        isRunning = false
        generation = UUID()
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
        detachObserver()
    }

    deinit {
        refreshTimer?.invalidate()
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    private func refreshFocus() {
        guard isRunning, AXIsProcessTrusted(),
              let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              targetProcessID == nil || targetProcessID == frontmost,
              !excludesCurrentProcess || frontmost != ProcessInfo.processInfo.processIdentifier else {
            detachObserver()
            return
        }
        if processID != frontmost || observer == nil {
            detachObserver()
            guard attachObserver(to: frontmost) else { return }
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        let context = detector.context(uptime: uptime, force: true)
        guard case .editable = context.semantics, let editable = detector.focusedEditableElement else {
            updateFocusedElement(nil)
            return
        }
        if updateFocusedElement(editable) {
            onSignal(.focusActivity)
            onActivity(uptime, context)
        }
    }

    private func attachObserver(to processID: Int32) -> Bool {
        var created: AXObserver?
        let result = AXObserverCreate(processID, { _, element, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<AccessibilityTypingMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // This source is attached exclusively to the main run loop below.
            MainActor.assumeIsolated {
                monitor.receive(element: element, notification: notification as String)
            }
        }, &created)
        guard result == .success, let created else { return false }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.02)
        self.processID = processID
        self.application = app
        self.observer = created
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(created, app, kAXFocusedUIElementChangedNotification as CFString, refcon)
        _ = AXObserverAddNotification(created, app, kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        onSignal(.observerAttached)
        return true
    }

    @discardableResult
    private func updateFocusedElement(_ next: AXUIElement?) -> Bool {
        if let focusedElement, let next, CFEqual(focusedElement, next) { return false }
        if focusedElement == nil && next == nil { return false }
        if let observer, let focusedElement {
            _ = AXObserverRemoveNotification(observer, focusedElement, kAXValueChangedNotification as CFString)
            _ = AXObserverRemoveNotification(observer, focusedElement, kAXSelectedTextChangedNotification as CFString)
        }
        focusedElement = next
        guard let observer, let next else { return false }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let valueResult = AXObserverAddNotification(observer, next, kAXValueChangedNotification as CFString, refcon)
        let selectionResult = AXObserverAddNotification(observer, next, kAXSelectedTextChangedNotification as CFString, refcon)
        if valueResult == .success || selectionResult == .success { onSignal(.editableSubscribed) }
        return true
    }

    private func receive(element: AXUIElement, notification: String) {
        guard isRunning else { return }
        switch notification {
        case kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification:
            onSignal(.focusNotification)
            refreshFocus()
        case kAXValueChangedNotification, kAXSelectedTextChangedNotification:
            let isValue = notification == kAXValueChangedNotification
            onSignal(isValue ? .valueNotification : .selectionNotification)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
                  let focusedElement, CFEqual(focusedElement, element) else { return }
            let uptime = ProcessInfo.processInfo.systemUptime
            let context = detector.context(uptime: uptime, force: true)
            guard case .editable = context.semantics,
                  let actualFocus = detector.focusedEditableElement, CFEqual(actualFocus, focusedElement) else {
                refreshFocus()
                return
            }
            onSignal(isValue ? .valueActivity : .selectionActivity)
            onActivity(uptime, context)
        default:
            break
        }
    }

    private func detachObserver() {
        updateFocusedElement(nil)
        if let observer {
            if let application {
                _ = AXObserverRemoveNotification(observer, application, kAXFocusedUIElementChangedNotification as CFString)
                _ = AXObserverRemoveNotification(observer, application, kAXFocusedWindowChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        application = nil
        focusedElement = nil
        processID = nil
    }
}
