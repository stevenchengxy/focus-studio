import FocusStudioCore
import Foundation

@MainActor
enum RecordingWindowFocusRegression {
    static func run() async throws {
        let settings = CaptureTargetInfo(id: "window-22", kind: .window, nativeID: 22,
            title: "Settings", appName: "Focus Studio",
            frame: CaptureRect(x: 100, y: 70, width: 900, height: 737))
        var frontWindow = 11
        var activated = 0
        var raised: [Int] = []
        var fallbacks = 0
        let windows = [
            RecordingWindowFocus.OwnedWindow(number: 11, raise: { raised.append(11); frontWindow = 11 }),
            RecordingWindowFocus.OwnedWindow(number: 22, raise: { raised.append(22); frontWindow = 22 })
        ]
        let driver = RecordingWindowFocus.Driver(handoff: { target in
            try RecordingWindowFocus.raiseOwnedWindow(target, ownerPID: 123, currentPID: 123,
                windows: windows, activate: { activated += 1 })
        }, isFrontmost: { Int($0.nativeID) == frontWindow }, wait: {},
        fallback: { _ in fallbacks += 1; throw RecordingWindowFocus.FocusError.activationFailed })
        try await RecordingWindowFocus.prepareForAutomation(settings, driver: driver)
        precondition(raised == [22] && activated == 1 && fallbacks == 0,
            "A recording of Settings must raise the selected auxiliary window, even with the main window first/frontmost")

        func refuses(_ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("Unsafe window identity was accepted") }
            catch { }
        }
        let previousActivations = activated
        let previousRaises = raised
        refuses {
            try RecordingWindowFocus.raiseOwnedWindow(settings, ownerPID: 456, currentPID: 123,
                windows: windows, activate: { activated += 1 })
        }
        refuses {
            try RecordingWindowFocus.raiseOwnedWindow(settings, ownerPID: 123, currentPID: 123,
                windows: [windows[0]], activate: { activated += 1 })
        }
        refuses {
            try RecordingWindowFocus.raiseOwnedWindow(settings, ownerPID: 123, currentPID: 123,
                windows: [windows[1], windows[1]], activate: { activated += 1 })
        }
        var display = settings
        display.kind = .display
        refuses {
            try RecordingWindowFocus.raiseOwnedWindow(display, ownerPID: 123, currentPID: 123,
                windows: windows, activate: { activated += 1 })
        }
        precondition(activated == previousActivations && raised == previousRaises,
            "Wrong process, missing/ambiguous ID and display sources must fail before activation or any window raise")

        // Even a successful raise request cannot authorize recording if some
        // other window stays frontmost. Retain the existing verification gate.
        var unconfirmed = driver
        unconfirmed.isFrontmost = { _ in false }
        var wasRefused = false
        do { try await RecordingWindowFocus.prepareForAutomation(settings, driver: unconfirmed) }
        catch { wasRefused = true }
        precondition(wasRefused && fallbacks == 1,
            "A same-process raise must still pass the exact-window foreground check")
        print("RecordingWindowFocusRegression: PASS (auxiliary window activation, exact identity, no side effects on refusal, foreground verification)")
    }
}

#if FOCUS_WINDOW_FOCUS_STANDALONE
@main
struct RecordingWindowFocusRegressionMain {
    static func main() async throws { try await RecordingWindowFocusRegression.run() }
}
#endif
