import FocusStudioCore
import Foundation

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
        print("CodexPlanRunnerTests: PASS (active-time waits, pause gates, cancellation, final gate, invalid clocks; no desktop input)")
    }
}
