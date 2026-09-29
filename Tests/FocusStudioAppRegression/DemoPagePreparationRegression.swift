import FocusStudioAutomation
import FocusStudioCore
import Foundation
import CoreGraphics

@MainActor
enum DemoPagePreparationRegression {
    static func run() async throws {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        precondition(DemoPagePreparation.application(for: .automatic, locate: { $0 == "com.google.Chrome" ? chrome : safari })?.url == chrome)
        precondition(DemoPagePreparation.application(for: .automatic, locate: { $0 == "com.apple.Safari" ? safari : nil })?.url == safari)
        precondition(DemoPagePreparation.application(for: .chrome, locate: { $0 == "com.apple.Safari" ? safari : nil }) == nil,
                     "An explicitly requested browser cannot silently become another browser")
        let frame = CaptureRect(x: 100, y: 70, width: 1200, height: 800)
        let old = CaptureTargetInfo(id: "window-11", kind: .window, nativeID: 11, title: "Finlyze older tab", appName: "Google Chrome", frame: frame)
        let new = CaptureTargetInfo(id: "window-22", kind: .window, nativeID: 22, title: "New requested page", appName: "Google Chrome", frame: frame)
        let newWindow = DemoPagePreparation.VisibleWindow(id: 22, frame: frame)
        let oldWindow = DemoPagePreparation.VisibleWindow(id: 11, frame: frame)
        precondition(DemoPagePreparation.target(in: [newWindow, oldWindow], sources: [old, new]) == new,
                     "Choose exact front window, never a title-matching old browser window")
        precondition(DemoPagePreparation.target(in: [newWindow, oldWindow], sources: [old]) == nil,
                     "A source refresh must contain the foreground window; no fallback to another window")
        var moved = new
        moved.frame.x += 5
        precondition(DemoPagePreparation.target(in: [newWindow], sources: [moved]) == nil,
                     "A window moving across inventory snapshots must settle first")
        let preparedTarget = try StudioModel.preparedDemoTarget(sourceID: new.id, sources: [old, new])
        precondition(preparedTarget == new,
                     "Preflight observes the exact prepared source, not a matching title")
        try await refuses { _ = try StudioModel.preparedDemoTarget(sourceID: "closed-window", sources: [old, new]) }
        var display = new
        display.kind = .display
        try await refuses { _ = try StudioModel.preparedDemoTarget(sourceID: display.id, sources: [display]) }
        let preflight = StudioModel.preparedDemoFrameData(sourceID: new.id, frame: frame, width: 2400, height: 1600,
                                                         url: URL(fileURLWithPath: "/tmp/preflight.png"))
        precondition(preflight["source_id"]?.stringValue == new.id && preflight["purpose"] == "preflight"
                     && preflight["recording_id"] == nil && preflight["observation_id"] == nil,
                     "A preflight image is not a live input token and cannot authorize any pointer action")

        var opened = 0, refreshes = 0, waits = 0
        var remembered: [UInt32] = []
        var driver = DemoPagePreparation.Driver(
            application: { _ in .init(url: chrome, name: "Google Chrome") },
            open: { url, _ in precondition(url.absoluteString == "https://finlyze.ai/dashboard"); opened += 1; return 123 },
            frontmostPID: { 123 }, windows: { _ in [newWindow, oldWindow] },
            sources: { refreshes += 1; return [old, new] }, wait: { waits += 1 },
            rememberWindow: { remembered.append($0.nativeID) }
        )
        let url = URL(string: "https://finlyze.ai/dashboard")!
        let result = try await DemoPagePreparation.prepare(url: url, browser: .automatic, driver: driver, checkReady: {})
        precondition(result.source.id == new.id && opened == 1 && refreshes == 2 && waits == 2,
                     "Opening happens once and two stable observations identify the prepared source")
        precondition(remembered == [new.nativeID], "Only the exact, settled foreground window receives an AX identity binding")
        precondition(result.options.interactionMode == "codex" && result.options.automaticZooms == true
                     && result.options.systemAudio == false && result.options.microphone == false,
                     "Prepared demos default to traced interactions and silent capture")
        var refusingBinding = driver
        refusingBinding.rememberWindow = { _ in throw RecordingWindowFocus.FocusError.ambiguous }
        try await refuses { _ = try await DemoPagePreparation.prepare(url: url, browser: .automatic, driver: refusingBinding, checkReady: {}) }

        var focusWaits = 0, handoffs = 0
        let focusDriver = RecordingWindowFocus.Driver(handoff: { target in
            precondition(target.nativeID == new.nativeID)
            handoffs += 1
        }, isFrontmost: { _ in focusWaits >= 2 }, wait: { focusWaits += 1 })
        try await RecordingWindowFocus.prepareForAutomation(new, driver: focusDriver)
        precondition(handoffs == 1 && focusWaits == 2, "Recording waits until the exact selected window actually becomes frontmost")
        var failedFocus = focusDriver
        failedFocus.isFrontmost = { _ in false }
        focusWaits = 0
        try await refuses { try await RecordingWindowFocus.prepareForAutomation(new, driver: failedFocus) }
        precondition(focusWaits == 20, "A successful app activation request alone cannot authorize recording the wrong window")
        var fallbackCalls = 0
        var fallbackFocus = focusDriver
        fallbackFocus.isFrontmost = { _ in fallbackCalls == 1 && focusWaits >= 23 }
        fallbackFocus.fallback = { target in precondition(target.nativeID == new.nativeID); fallbackCalls += 1 }
        focusWaits = 0
        try await RecordingWindowFocus.prepareForAutomation(new, driver: fallbackFocus)
        precondition(fallbackCalls == 1 && focusWaits == 23, "LaunchServices fallback must still await confirmation of the exact selected window")
        var refusedRaise = fallbackFocus
        refusedRaise.handoff = { _ in throw RecordingWindowFocus.FocusError.activationFailed }
        refusedRaise.isFrontmost = { _ in fallbackCalls == 1 && focusWaits >= 2 }
        fallbackCalls = 0; focusWaits = 0
        try await RecordingWindowFocus.prepareForAutomation(new, driver: refusedRaise)
        precondition(fallbackCalls == 1 && focusWaits == 2, "A refused AX raise may recover only after LaunchServices and exact-window confirmation")
        fallbackCalls = 0; focusWaits = 0
        try await refuses {
            try await RecordingWindowFocus.prepareForAutomation(new,
                waitUntilReady: { if focusWaits >= 20 { throw CancellationError() } }, driver: fallbackFocus)
        }
        precondition(fallbackCalls == 0, "A recording cancelled during activation cannot start a late fallback")
        func windowEntry(_ width: Double, _ height: Double) -> [CFString: Any] {
            [kCGWindowOwnerPID: NSNumber(value: 123), kCGWindowLayer: NSNumber(value: 0), kCGWindowAlpha: NSNumber(value: 1),
             kCGWindowBounds: ["X": 0, "Y": 0, "Width": width, "Height": height]]
        }
        precondition(!RecordingWindowFocus.isMainWindow(windowEntry(1, 1), ownerPID: 123, targetFrame: frame)
                     && RecordingWindowFocus.isMainWindow(windowEntry(1200, 800), ownerPID: 123, targetFrame: frame),
                     "Tiny browser helper windows cannot masquerade as the selected document window")
        var ambiguousFocus = focusDriver
        ambiguousFocus.handoff = { _ in throw RecordingWindowFocus.FocusError.ambiguous }
        focusWaits = 0
        try await refuses { try await RecordingWindowFocus.prepareForAutomation(new, driver: ambiguousFocus) }
        precondition(focusWaits == 0, "Ambiguous windows are rejected before activation or waiting")
        let before = opened
        try await refuses { _ = try await DemoPagePreparation.prepare(url: url, browser: .automatic, driver: driver) { throw CancellationError() } }
        precondition(opened == before, "A busy or cancelled preparation must not open a page")
        driver.application = { _ in nil }
        try await refuses { _ = try await DemoPagePreparation.prepare(url: url, browser: .chrome, driver: driver, checkReady: {}) }
        precondition(opened == before, "A missing app is refused before launch")
        driver.application = { _ in .init(url: chrome, name: "Google Chrome") }
        driver.frontmostPID = { 456 }
        refreshes = 0
        try await refuses { _ = try await DemoPagePreparation.prepare(url: url, browser: .chrome, driver: driver, checkReady: {}) }
        precondition(refreshes == 0, "Another app in front cannot yield a supposedly prepared browser window")
        driver.frontmostPID = { 123 }
        waits = 0
        driver.windows = { _ in waits.isMultiple(of: 2) ? [newWindow] : [oldWindow] }
        try await refuses { _ = try await DemoPagePreparation.prepare(url: url, browser: .chrome, driver: driver, checkReady: {}) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DemoPreparation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudioModel(store: ProjectStore(projectsDirectory: root), interactionTrackingAccess: { true }, screenCaptureAccess: { true })
        try model.checkDemoPagePreparationReady()
        model.isBusy = true
        try await refuses { _ = try await model.prepareDemoPage(url: url) }
        try await refuses { _ = try await model.capturePreparedDemoFrame(sourceID: new.id, to: root.appendingPathComponent("busy.png")) }
        model.isBusy = false
        model.destination = .countdown
        try await refuses { _ = try await model.prepareDemoPage(url: url) }
        model.destination = .recording
        try await refuses { _ = try await model.prepareDemoPage(url: url) }
        try await refuses { _ = try await model.capturePreparedDemoFrame(sourceID: new.id, to: root.appendingPathComponent("live.png")) }
        let noScreen = StudioModel(store: ProjectStore(projectsDirectory: root), interactionTrackingAccess: { true }, screenCaptureAccess: { false })
        try await refuses { _ = try await noScreen.prepareDemoPage(url: url) }
        try await refuses { _ = try await noScreen.capturePreparedDemoFrame(sourceID: new.id, to: root.appendingPathComponent("denied.png")) }
        let noInput = StudioModel(store: ProjectStore(projectsDirectory: root), interactionTrackingAccess: { false }, screenCaptureAccess: { true })
        try await refuses { _ = try await noInput.prepareDemoPage(url: url) }
        print("DemoPagePreparationRegression: PASS (visible browser selection, exact stable window, busy and missing permission guards, no capture during preparation)")
    }

    private static func refuses(_ body: () async throws -> Void) async throws {
        var refused = false
        do { try await body() } catch { refused = true }
        precondition(refused, "Preparation must refuse this case without using the desktop")
    }
}
