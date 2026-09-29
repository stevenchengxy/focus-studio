import FocusStudioAutomation
import FocusStudioCore
import Foundation
import CoreGraphics

@main
struct CodexPlanRunnerTests {
    @MainActor
    static func main() async throws {
        final class Clock {
            var time = 0.0
            var paused = false
            var completed = false
            var gates = 0
            func ready() async throws {
                gates += 1
                while paused { try await Task.sleep(for: .milliseconds(10)) }
                try Task.checkCancellation()
            }
        }

        let clock = Clock()
        let waiter = Task { @MainActor in
            try await CodexPlanRunner.waitForDuration(0.2, waitUntilReady: { try await clock.ready() }, activeClock: { clock.time })
            clock.completed = true
        }
        try await Task.sleep(for: .milliseconds(300))
        precondition(!clock.completed, "Wall-clock time must not consume an active-recording wait")
        clock.time = 0.1
        try await Task.sleep(for: .milliseconds(70))
        precondition(!clock.completed, "Only elapsed capture time counts")
        clock.paused = true
        clock.time = 0.3
        try await Task.sleep(for: .milliseconds(100))
        precondition(!clock.completed, "A paused gate must prevent the wait from finishing even if the clock advances")
        clock.paused = false
        try await waiter.value
        precondition(clock.completed && clock.gates > 2)

        let cancelled = Clock()
        cancelled.paused = true
        let cancellation = Task { @MainActor in
            try await CodexPlanRunner.waitForDuration(10, waitUntilReady: { try await cancelled.ready() }, activeClock: { cancelled.time })
        }
        try await Task.sleep(for: .milliseconds(30))
        cancellation.cancel()
        do { try await cancellation.value; preconditionFailure("Pause must remain cancellable") }
        catch is CancellationError { }

        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            do {
                try await CodexPlanRunner.waitForDuration(1, activeClock: { invalid })
                preconditionFailure("Invalid clocks must fail closed")
            } catch CodexPlanRunner.RunnerError.invalidActiveClock { }
        }
        let decreasing = Clock()
        decreasing.time = 1
        let backwards = Task { @MainActor in
            try await CodexPlanRunner.waitForDuration(2, activeClock: { decreasing.time })
        }
        try await Task.sleep(for: .milliseconds(30))
        decreasing.time = 0.5
        do { try await backwards.value; preconditionFailure("A resetting capture clock must fail closed") }
        catch CodexPlanRunner.RunnerError.invalidActiveClock { }

        // The model's adapter reconciles the media writer's final partial frame
        // without letting that tiny downward correction reset the runner clock.
        let reconciled = Clock()
        reconciled.time = 10
        var lastReported = 0.0
        let reconciledWait = Task { @MainActor in
            try await CodexPlanRunner.waitForDuration(0.2, activeClock: {
                lastReported = max(lastReported, reconciled.time)
                return lastReported
            })
            reconciled.completed = true
        }
        try await Task.sleep(for: .milliseconds(30))
        reconciled.time = 10.1
        try await Task.sleep(for: .milliseconds(60))
        reconciled.time = 10.08
        try await Task.sleep(for: .milliseconds(60))
        precondition(!reconciled.completed, "A partial-frame reconciliation must not complete a wait early")
        reconciled.time = 10.25
        try await reconciledWait.value

        let target = CaptureTargetInfo(id: "fixture", kind: .display, nativeID: 0, title: "Fixture", frame: CaptureRect(x: 0, y: 0, width: 100, height: 100))
        let finish = Clock()
        var readinessCalls = 0
        let runner = Task { @MainActor in
            try await CodexPlanRunner.run(actions: [], in: target, waitUntilReady: {
                readinessCalls += 1
                try await finish.ready()
            }, activeClock: { finish.time }, onPlannedClick: { _, _ in preconditionFailure("Pure waits must never send clicks") })
            finish.completed = true
        }
        finish.paused = true
        try await Task.sleep(for: .milliseconds(50))
        precondition(!finish.completed && readinessCalls > 0, "Even an empty/final plan must not finish while paused")
        finish.paused = false
        try await runner.value
        try await testDispatchedInteractions()
        print("CodexPlanRunnerTests: PASS (active-time waits, pause gates, cancellation, input tracing, crop mapping, movement, validation; no desktop input)")
    }

    @MainActor
    static func testDispatchedInteractions() async throws {
        final class Recorder {
            var time = 0.0
            var permissionChecks = 0
            var posted: [(String, CGPoint)] = []
            var events: [CodexPlanRunner.Interaction] = []
            var paused = false
            var failMove = false
            var obscured = false
            var windowMoved = false
            func clock() -> TimeInterval { time += 1.0 / 120; return time }
            func ready() async throws {
                while paused { try await Task.sleep(for: .milliseconds(5)) }
                try Task.checkCancellation()
            }
        }
        let recorder = Recorder()
        let frame = CaptureRect(x: 200, y: 80, width: 1000, height: 800)
        let target = CaptureTargetInfo(id: "fixture-window", kind: .window, nativeID: 999, title: "Fixture", frame: frame)
        let crop = SourceCropInsets(top: 0.2, leading: 0.1, bottom: 0.05, trailing: 0.1)
        let driver = CodexPlanRunner.InputDriver(
            hasAccessibilityPermission: { recorder.permissionChecks += 1; return true },
            prepareWindow: { _, _, _, gate in try await gate?(); return frame },
            resolveWindow: { _, _, _ in
                if recorder.obscured { throw CodexPlanRunner.RunnerError.targetWindowObscured }
                var current = frame
                if recorder.windowMoved { current.x += 20 }
                return current
            },
            move: { point in
                if recorder.failMove { throw CodexPlanRunner.RunnerError.eventCreationFailed }
                recorder.posted.append(("move", point))
            },
            down: { recorder.posted.append(("down", $0)) },
            up: { recorder.posted.append(("up", $0)) },
            scroll: { point, _, _ in recorder.posted.append(("scroll", point)) }
        )
        var plannedClicks: [CGPoint] = []
        try await CodexPlanRunner.run(
            actions: [
                .init(type: .move, seconds: 0.08, x: 0.25, y: 0.75),
                .init(type: .click, seconds: 0.08, x: 0.8, y: 0.4),
                .init(type: .scroll, seconds: 0.08, x: 0.7, y: 0.6, deltaY: 200)
            ],
            in: target, cropInsets: crop, activeClock: { recorder.clock() },
            onInteraction: { recorder.events.append($0) }, inputDriver: driver,
            onPlannedClick: { plannedClicks.append(CGPoint(x: $0, y: $1)) }
        )
        precondition(recorder.permissionChecks == 1)
        let clicks = recorder.events.filter { $0.kind == .click }
        let scrolls = recorder.events.filter { $0.kind == .scroll }
        let moves = recorder.events.filter { $0.kind == .move }
        precondition(clicks.count == 1 && scrolls.count == 1 && moves.count > 9,
                     "Actual movement, click and scroll must all reach the same trace")
        precondition(recorder.posted.filter { $0.0 == "move" }.count == moves.count,
                     "Every recorded move must correspond to a dispatched move")
        precondition(zip(recorder.events, recorder.events.dropFirst()).allSatisfy { pair in pair.0.time < pair.1.time },
                     "The precise recorder clock timestamps each delivered sample")
        let expectedClick = crop.sourcePoint(x: 0.8, y: 0.4)
        precondition(abs(clicks[0].x - expectedClick.x) < 1e-12 && abs(clicks[0].y - expectedClick.y) < 1e-12)
        precondition(plannedClicks == [expectedClick], "Legacy and new callbacks share uncropped source coordinates")
        let deliveredClick = recorder.posted.first { $0.0 == "down" }!.1
        precondition(abs(deliveredClick.x - (frame.x + expectedClick.x * frame.width)) < 1e-9)
        precondition(abs(deliveredClick.y - (frame.y + expectedClick.y * frame.height)) < 1e-9,
                     "Crop and Retina-independent logical-window mapping are each applied once")
        let clickIndex = recorder.events.firstIndex { $0.kind == .click }!
        precondition(recorder.events[clickIndex - 1].x == clicks[0].x && recorder.events[clickIndex - 1].y == clicks[0].y,
                     "The cursor reaches the click anchor before posting the click")
        let first = recorder.events[0]
        let center = crop.sourcePoint(x: 0.5, y: 0.5)
        precondition(first.x == center.x && first.y == center.y,
                     "A new execution starts at its own anchor, not the unrelated physical pointer")
        precondition(recorder.posted.contains { $0.0 == "up" }, "Mouse down must be released")

        // Separate MCP calls retain the previous execution position. No center
        // teleport or physical-mouse resampling is introduced between actions.
        let prior = CGPoint(x: scrolls[0].x, y: scrolls[0].y)
        recorder.events = []
        try await CodexPlanRunner.run(
            actions: [.init(type: .move, seconds: 0.08, x: 0.1, y: 0.2)],
            in: target, cropInsets: crop, activeClock: { recorder.clock() },
            initialCursorPosition: prior,
            onInteraction: { recorder.events.append($0) }, inputDriver: driver
        )
        let resumed = recorder.events[0]
        precondition(hypot(resumed.x - prior.x, resumed.y - prior.y) < 0.02,
                     "Independent actions continue smoothly from the prior trace anchor")

        // Reject bad coordinates and broad targets before requesting access.
        let permissionChecks = recorder.permissionChecks
        let eventCount = recorder.posted.count
        for invalid in [Double.nan, Double.infinity, -0.1, 1.1] {
            do {
                try await CodexPlanRunner.run(actions: [.init(type: .click, x: invalid, y: 0.5)], in: target, inputDriver: driver)
                preconditionFailure("Invalid coordinates must fail closed")
            } catch CodexPlanRunner.RunnerError.invalidClick { }
        }
        do {
            var display = target
            display.kind = .display
            try await CodexPlanRunner.run(actions: [.init(type: .click, x: 0.5, y: 0.5)], in: display, inputDriver: driver)
            preconditionFailure("Input cannot escape a selected recording window")
        } catch CodexPlanRunner.RunnerError.windowCaptureRequired { }
        precondition(permissionChecks == recorder.permissionChecks && eventCount == recorder.posted.count)

        // Failed native delivery and newly covered windows cannot create fake
        // trace events or planned zoom clicks.
        recorder.events = []
        recorder.failMove = true
        do {
            try await CodexPlanRunner.run(actions: [.init(type: .click, x: 0.5, y: 0.5)], in: target,
                activeClock: { recorder.clock() }, onInteraction: { recorder.events.append($0) }, inputDriver: driver)
            preconditionFailure("Native delivery failure must abort")
        } catch CodexPlanRunner.RunnerError.eventCreationFailed { }
        precondition(recorder.events.isEmpty)
        recorder.failMove = false
        recorder.obscured = true
        do {
            try await CodexPlanRunner.run(actions: [.init(type: .click, x: 0.5, y: 0.5)], in: target,
                activeClock: { recorder.clock() }, onInteraction: { recorder.events.append($0) }, inputDriver: driver)
            preconditionFailure("Covered windows must abort before input")
        } catch CodexPlanRunner.RunnerError.targetWindowObscured { }
        precondition(recorder.events.isEmpty)
        recorder.obscured = false
        recorder.windowMoved = true
        do {
            try await CodexPlanRunner.run(actions: [.init(type: .click, x: 0.5, y: 0.5)], in: target,
                activeClock: { recorder.clock() }, onInteraction: { recorder.events.append($0) }, inputDriver: driver)
            preconditionFailure("Moving or resizing a window after action preparation must abort")
        } catch CodexPlanRunner.RunnerError.targetWindowChanged { }
        precondition(recorder.events.isEmpty)
        recorder.windowMoved = false

        // A recording pause freezes both native motion and the execution trace.
        recorder.events = []
        recorder.paused = true
        let pausedMotion = Task { @MainActor in
            try await CodexPlanRunner.run(actions: [.init(type: .move, seconds: 0.08, x: 0.2, y: 0.8)], in: target,
                waitUntilReady: { try await recorder.ready() }, activeClock: { recorder.clock() },
                onInteraction: { recorder.events.append($0) }, inputDriver: driver)
        }
        try await Task.sleep(for: .milliseconds(40))
        precondition(recorder.events.isEmpty)
        recorder.paused = false
        try await pausedMotion.value
        precondition(recorder.events.count > 2)

        recorder.events = []
        var didPauseDuringMotion = false
        let interruptedMotion = Task { @MainActor in
            try await CodexPlanRunner.run(actions: [.init(type: .move, seconds: 0.15, x: 0.8, y: 0.2)], in: target,
                waitUntilReady: { try await recorder.ready() }, activeClock: { recorder.clock() },
                onInteraction: { event in
                    recorder.events.append(event)
                    if recorder.events.count == 2 && !didPauseDuringMotion {
                        didPauseDuringMotion = true
                        recorder.paused = true
                    }
                }, inputDriver: driver)
        }
        while !didPauseDuringMotion { try await Task.sleep(for: .milliseconds(5)) }
        let pausedSampleCount = recorder.events.count
        try await Task.sleep(for: .milliseconds(40))
        precondition(recorder.events.count == pausedSampleCount, "A pause in the middle of travel must stop native dispatch")
        recorder.paused = false
        try await interruptedMotion.value

        recorder.events = []
        recorder.posted = []
        let cancelClick = Task { @MainActor in
            try await CodexPlanRunner.run(actions: [.init(type: .click, seconds: 0.08, x: 0.4, y: 0.7)], in: target,
                activeClock: { recorder.clock() }, onInteraction: { recorder.events.append($0) }, inputDriver: driver)
        }
        while !recorder.posted.contains(where: { $0.0 == "down" }) { try await Task.sleep(for: .milliseconds(2)) }
        cancelClick.cancel()
        do { try await cancelClick.value; preconditionFailure("Click cancellation must propagate") }
        catch is CancellationError { }
        precondition(recorder.posted.filter { $0.0 == "down" }.count == 1
                     && recorder.posted.filter { $0.0 == "up" }.count == 1,
                     "Cancellation between mouse down/up must always release the button")

        recorder.events = []
        var navigated: [URL] = []
        var navigationDriver = driver
        navigationDriver.navigate = { url, _ in navigated.append(url) }
        try await CodexPlanRunner.run(actions: [.init(type: .navigate, url: "https://example.com/new"), .init(type: .move, seconds: 0.08, x: 0.1, y: 0.2)],
            in: target, cropInsets: crop, activeClock: { recorder.clock() }, initialCursorPosition: CGPoint(x: 0.9, y: 0.9),
            onInteraction: { recorder.events.append($0) }, inputDriver: navigationDriver)
        precondition(navigated.count == 1 && recorder.events.first?.kind == .discontinuity,
                     "Successful navigation cuts the old page's cursor trace")
        precondition(recorder.events[1].kind == .move && recorder.events[1].x == center.x && recorder.events[1].y == center.y,
                     "The first move on a new page starts from a new execution anchor")
        recorder.events = []
        navigationDriver.navigate = { url, _ in throw CodexPlanRunner.RunnerError.couldNotOpenURL(url) }
        do {
            try await CodexPlanRunner.run(actions: [.init(type: .navigate, url: "https://example.com/new")], in: target,
                activeClock: { recorder.clock() }, onInteraction: { recorder.events.append($0) }, inputDriver: navigationDriver)
            preconditionFailure("Failed navigation must report its failure")
        } catch CodexPlanRunner.RunnerError.couldNotOpenURL { }
        precondition(recorder.events.isEmpty, "No navigation cut is invented when the navigation failed")

        let point = CGPoint(x: 50, y: 50)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let recordedWindow = CodexPlanRunner.InputWindow(id: 1, layer: 0, frame: bounds)
        let floatingControls = CodexPlanRunner.InputWindow(id: 2, layer: 3, frame: bounds)
        precondition(CodexPlanRunner.firstInputWindow(at: point, in: [floatingControls, recordedWindow]) == 2,
                     "Floating recording controls must block clicks to the underlying recorded window")
        let higherOverlay = CodexPlanRunner.InputWindow(id: 3, layer: 1000, frame: bounds, alpha: 0.001)
        precondition(CodexPlanRunner.firstInputWindow(at: point, in: [higherOverlay, recordedWindow]) == 3,
                     "Even a faint elevated window can intercept input")
        let foreignOverlay = CodexPlanRunner.InputWindow(id: 6, layer: 1000, frame: bounds, ownerPID: 888)
        let blocker = CodexPlanRunner.firstInputWindowDetails(at: point, in: [foreignOverlay, recordedWindow])
        let diagnostic = CodexPlanRunner.obstructionDiagnostic(targetID: 1, targetPID: 777, point: point,
            blocker: blocker, axStatus: 0, axPID: 777, axWindowFrame: bounds)
        precondition(blocker?.id == 6 && diagnostic.contains("blocker_pid=888") && diagnostic.contains("blocker_layer=1000")
                     && diagnostic.contains("ax_pid=777") && diagnostic.contains("point=50.0,50.0"),
                     "Diagnostics identify the actual covering process even when AX reports the target underneath")
        let sameProcessOverlay = CodexPlanRunner.InputWindow(id: 7, layer: 0, frame: bounds, ownerPID: 777)
        precondition(CodexPlanRunner.firstInputWindowDetails(at: point, in: [sameProcessOverlay, recordedWindow])?.id == 7,
                     "A same-PID window with identical bounds is still a different input target")
        let codexCursor = CodexPlanRunner.InputWindow(id: 9, layer: 8, frame: bounds, ownerPID: 999)
        var hitChecks = 0
        func resolve(_ windows: [CodexPlanRunner.InputWindow], signed: Bool, exactHit: Bool) -> UInt32? {
            CodexPlanRunner.resolvedInputWindow(at: point, in: windows, targetID: recordedWindow.id,
                isVerifiedCursorProcess: { $0 == 999 && signed },
                hitsExactTargetWindow: { hitChecks += 1; return exactHit })?.id
        }
        precondition(resolve([codexCursor, recordedWindow], signed: true, exactHit: true) == recordedWindow.id && hitChecks == 1,
                     "Verified signed Codex cursor passes only with an AX hit on the exact prepared recording window")
        precondition(resolve([codexCursor, recordedWindow], signed: false, exactHit: true) == codexCursor.id && hitChecks == 1,
                     "An unsigned or unknown lookalike cursor cannot use AX to bypass CG coverage")
        precondition(resolve([codexCursor, recordedWindow], signed: true, exactHit: false) == codexCursor.id,
                     "Missing AX, foreign AX, and same-PID different AX windows all fail closed")
        precondition(resolve([codexCursor, foreignOverlay, recordedWindow], signed: true, exactHit: true) == foreignOverlay.id,
                     "A known cursor does not hide an unknown overlay or system dialog beneath it")
        precondition(resolve([codexCursor, sameProcessOverlay, recordedWindow], signed: true, exactHit: true) == sameProcessOverlay.id,
                     "A same-process covering window still blocks underneath a verified cursor")
        var helperPanel = codexCursor
        helperPanel.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        precondition(resolve([helperPanel, recordedWindow], signed: true, exactHit: true) == helperPanel.id,
                     "Even a signed Codex helper's larger control panel is not a cursor overlay")
        helperPanel = codexCursor
        helperPanel.layer = 3
        precondition(resolve([helperPanel, recordedWindow], signed: true, exactHit: true) == helperPanel.id,
                     "Only the observed cursor layer can use the narrow exception")
        precondition(resolve([codexCursor], signed: true, exactHit: true) == codexCursor.id,
                     "A virtual cursor cannot invent a missing CG recording window")
        let nativeCursor = CodexPlanRunner.InputWindow(id: 10, layer: Int(CGWindowLevelForKey(.cursorWindow)),
            frame: CGRect(x: 30, y: 30, width: 28, height: 40), ownerPID: 172)
        func resolveNative(_ windows: [CodexPlanRunner.InputWindow], signed: Bool, exactHit: Bool) -> UInt32? {
            CodexPlanRunner.resolvedInputWindow(at: point, in: windows, targetID: recordedWindow.id,
                isVerifiedCursorProcess: { $0 == 999 },
                isVerifiedSystemCursorProcess: { $0 == 172 && signed },
                hitsExactTargetWindow: { exactHit })?.id
        }
        precondition(resolveNative([nativeCursor, recordedWindow], signed: true, exactHit: true) == recordedWindow.id,
                     "The Apple-signed WindowServer cursor plane passes through only to the exact AX recording window")
        precondition(resolveNative([nativeCursor, recordedWindow], signed: false, exactHit: true) == nativeCursor.id,
                     "A cursor-level window owned by unknown running code is still a blocker")
        precondition(resolveNative([nativeCursor, recordedWindow], signed: true, exactHit: false) == nativeCursor.id,
                     "Even the system cursor plane cannot bypass a missing or different AX target")
        precondition(resolveNative([nativeCursor, codexCursor, recordedWindow], signed: true, exactHit: true) == recordedWindow.id,
                     "The native and Codex virtual cursor planes can coexist above the same validated target")
        precondition(resolveNative([nativeCursor, foreignOverlay, recordedWindow], signed: true, exactHit: true) == foreignOverlay.id,
                     "System dialogs and unknown overlays below the native cursor still block input")
        var windowServerSurface = nativeCursor
        windowServerSurface.layer = 8
        precondition(resolveNative([windowServerSurface, recordedWindow], signed: true, exactHit: true) == windowServerSurface.id,
                     "WindowServer-owned non-cursor layers are not implicitly interactive pass-through surfaces")
        windowServerSurface = nativeCursor
        windowServerSurface.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        precondition(resolveNative([windowServerSurface, recordedWindow], signed: true, exactHit: true) == windowServerSurface.id,
                     "A full-window WindowServer surface is not classified as a cursor")
        let passThrough = CodexPlanRunner.InputWindow(id: 4, layer: 5, frame: bounds, ignoresMouseEvents: true)
        let hidden = CodexPlanRunner.InputWindow(id: 5, layer: 10, frame: bounds, alpha: 0)
        precondition(CodexPlanRunner.firstInputWindow(at: point, in: [passThrough, hidden, recordedWindow]) == 1,
                     "Known noninteractive or invisible overlays do not block the target")
        precondition(CodexPlanRunner.firstInputWindow(at: CGPoint(x: 150, y: 50), in: [recordedWindow]) == nil,
                     "Input outside every visible window is never guessed")

        let displays = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: -1440, y: 100, width: 1280, height: 900)]
        precondition(CodexPlanRunner.pointIsOnDisplay(CGPoint(x: 400, y: 300), displayFrames: displays))
        precondition(CodexPlanRunner.pointIsOnDisplay(CGPoint(x: -1000, y: 300), displayFrames: displays),
                     "Negative desktop coordinates on a secondary display are valid")
        precondition(!CodexPlanRunner.pointIsOnDisplay(CGPoint(x: -80, y: 300), displayFrames: displays),
                     "A gap between displays is not an input surface")
        let partiallyOffscreen = CodexPlanRunner.InputWindow(id: 8, layer: 0, frame: CGRect(x: -100, y: 50, width: 600, height: 400))
        let invisiblePoint = CGPoint(x: -50, y: 100)
        precondition(CodexPlanRunner.firstInputWindow(at: invisiblePoint, in: [partiallyOffscreen]) == 8
                     && !CodexPlanRunner.pointIsOnDisplay(invisiblePoint, displayFrames: displays),
                     "Being inside a partially visible window does not make an offscreen point dispatchable")
        precondition(!CodexPlanRunner.pointIsOnDisplay(CGPoint(x: Double.nan, y: 10), displayFrames: displays)
                     && !CodexPlanRunner.pointIsOnDisplay(CGPoint(x: 10, y: 10), displayFrames: []))
        var movedFrame = frame
        movedFrame.x += 200
        precondition(CodexPlanRunner.windowSizeMatches(movedFrame, captured: frame),
                     "Window movement retains the normalized input mapping after a fresh observation")
        movedFrame.width += 1
        precondition(!CodexPlanRunner.windowSizeMatches(movedFrame, captured: frame),
                     "A resized window cannot reuse a fixed recording frame's coordinate mapping")

        recorder.posted = []
        recorder.events = []
        var discardStarted = false
        do {
            try await CodexPlanRunner.run(actions: [.init(type: .click, seconds: 0.15, x: 0.4, y: 0.7)], in: target,
                waitUntilReady: { if discardStarted { throw CancellationError() } }, activeClock: { recorder.clock() },
                onInteraction: { event in
                    recorder.events.append(event)
                    if recorder.events.count == 2 { discardStarted = true }
                }, inputDriver: driver)
            preconditionFailure("Discard must interrupt an in-flight approach")
        } catch is CancellationError { }
        precondition(recorder.events.count == 2 && !recorder.posted.contains { $0.0 == "down" || $0.0 == "scroll" },
                     "The readiness gate is checked again before further movement or a final click")

        let plan = CodexRecordingPlan(title: "Move", summary: "Smooth approach", capture: .init(mode: .window, windowTitle: "Fixture"),
                                      actions: [.init(type: .move, seconds: 0.2, x: 0.4, y: 0.7)])
        precondition(plan.validationIssues.isEmpty)
        var invalidPlan = plan
        invalidPlan.actions[0].seconds = .nan
        precondition(!invalidPlan.validationIssues.isEmpty)
        invalidPlan.actions = [.init(type: .scroll, x: 0.2, deltaY: 100)]
        precondition(!invalidPlan.validationIssues.isEmpty, "Half-specified scroll coordinates cannot run")
        let a = CGPoint(x: 0.1, y: 0.2), b = CGPoint(x: 0.9, y: 0.8)
        precondition(CodexPlanRunner.interpolatedPosition(from: a, to: b, progress: 0) == a)
        precondition(CodexPlanRunner.interpolatedPosition(from: a, to: b, progress: 1) == b)
    }

}
