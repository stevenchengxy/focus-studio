import AppKit
import ApplicationServices
import CoreGraphics
import FocusStudioCore
import Foundation

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

        var errorDescription: String? {
            switch self {
            case .accessibilityPermissionRequired:
                return "Codex Director needs Accessibility access to perform reviewed clicks and scrolling. Enable Focus Studio in System Settings → Privacy & Security → Accessibility, then run the plan again."
            case let .couldNotOpenURL(url):
                return "Focus Studio could not open \(url.absoluteString)."
            case .invalidClick:
                return "A click action is missing normalized coordinates."
            case .eventCreationFailed:
                return "macOS could not create an automation input event."
            case .targetWindowUnavailable:
                return "The selected recording window moved off screen or closed, so Focus Studio stopped before sending another input."
            case .targetWindowObscured:
                return "The selected recording window is covered at the planned interaction point. Bring that window to the front, review the plan, and run it again."
            }
        }
    }

    static func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw RunnerError.couldNotOpenURL(url)
        }
    }

    static func run(
        actions: [CodexRecordingAction],
        in target: CaptureTargetInfo,
        cropInsets: SourceCropInsets? = nil,
        browserApplicationURL: URL? = nil,
        onPlannedClick: @escaping @MainActor (Double, Double) -> Void
    ) async throws {
        let needsInputAutomation = actions.contains { action in
            action.type == .click || action.type == .scroll
        }
        if needsInputAutomation && !requestAccessibilityIfNeeded() {
            throw RunnerError.accessibilityPermissionRequired
        }

        for action in actions {
            try Task.checkCancellation()
            switch action.type {
            case .wait:
                let seconds = (action.seconds ?? 0).clamped(to: 0...30)
                if seconds > 0 {
                    try await Task.sleep(for: .seconds(seconds))
                }

            case .navigate:
                guard let value = action.url,
                      let url = URL(string: value),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                else { continue }
                try await open(url, with: browserApplicationURL)

            case .click:
                guard let x = action.x, let y = action.y,
                      (0...1).contains(x), (0...1).contains(y)
                else { throw RunnerError.invalidClick }
                let sourcePoint = (cropInsets ?? SourceCropInsets()).sourcePoint(x: x, y: y)
                let frame = try await verifiedWindowFrame(
                    for: target,
                    sourceX: sourcePoint.x,
                    sourceY: sourcePoint.y
                )
                let point = globalPoint(x: sourcePoint.x, y: sourcePoint.y, in: frame)
                guard let down = CGEvent(
                    mouseEventSource: nil,
                    mouseType: .leftMouseDown,
                    mouseCursorPosition: point,
                    mouseButton: .left
                ), let up = CGEvent(
                    mouseEventSource: nil,
                    mouseType: .leftMouseUp,
                    mouseCursorPosition: point,
                    mouseButton: .left
                ) else { throw RunnerError.eventCreationFailed }
                down.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(45))
                up.post(tap: .cghidEventTap)
                await onPlannedClick(sourcePoint.x, sourcePoint.y)

            case .scroll:
                let vertical = (action.deltaY ?? 0).clamped(to: -1_200...1_200)
                let horizontal = (action.deltaX ?? 0).clamped(to: -1_200...1_200)
                let sourcePoint = (cropInsets ?? SourceCropInsets()).sourcePoint(x: 0.5, y: 0.5)
                let frame = try await verifiedWindowFrame(
                    for: target,
                    sourceX: sourcePoint.x,
                    sourceY: sourcePoint.y
                )
                guard let event = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .pixel,
                    wheelCount: 2,
                    wheel1: Int32((-vertical).rounded()),
                    wheel2: Int32((-horizontal).rounded()),
                    wheel3: 0
                ) else { throw RunnerError.eventCreationFailed }
                event.location = globalPoint(x: sourcePoint.x, y: sourcePoint.y, in: frame)
                event.post(tap: .cghidEventTap)
            }
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
    /// is in front at the intended point.
    private static func verifiedWindowFrame(
        for target: CaptureTargetInfo,
        sourceX: Double,
        sourceY: Double
    ) async throws -> CaptureRect {
        guard target.kind == .window else { return target.frame }
        let before = try windowSnapshot(for: target.nativeID)
        if let application = NSRunningApplication(processIdentifier: before.ownerPID) {
            application.activate(options: [])
            try await Task.sleep(for: .milliseconds(180))
        }

        let snapshot = try windowSnapshot(for: target.nativeID)
        let point = globalPoint(x: sourceX, y: sourceY, in: snapshot.frame)
        guard topmostLayerZeroWindow(at: point) == target.nativeID else {
            throw RunnerError.targetWindowObscured
        }
        return snapshot.frame
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

    private static func topmostLayerZeroWindow(at point: CGPoint) -> UInt32? {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }

        for entry in entries {
            guard (entry[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                  let bounds = entry[kCGWindowBounds],
                  let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
                  rect.contains(point),
                  (entry[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1 > 0.01
            else { continue }
            return (entry[kCGWindowNumber] as? NSNumber)?.uint32Value
        }
        return nil
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
