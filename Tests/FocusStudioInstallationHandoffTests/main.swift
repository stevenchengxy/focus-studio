import Foundation

/// Pure process doubles: no NSWorkspace, NSRunningApplication, real bundles,
/// or user processes are opened, quit, copied, or changed by this suite.
@MainActor
private final class FakeInstance {
    let processID: Int32
    let url: URL?
    var terminated = false
    var terminationRequests = 0
    var onTermination: (() -> Bool)?

    init(_ processID: Int32, _ url: URL?) {
        self.processID = processID
        self.url = url
    }

    var instance: AppInstallationHandoff.Instance {
        .init(processID: processID, url: url, requestTermination: { [self] in
            terminationRequests += 1
            if let onTermination { return onTermination() }
            terminated = true
            return true
        }, hasTerminated: { [self] in terminated })
    }
}

@main
private enum InstallationHandoffTests {
    private static let canonical = URL(fileURLWithPath: "/Applications/Focus Studio.app")
    private static let download = URL(fileURLWithPath: "/Downloads/Focus Studio.app")
    private static let quitFailure = "An open Focus Studio could not quit. Finish your work and quit it, then try again."
    private static let newInstanceFailure = "Another Focus Studio opened during installation. Quit it and try again."

    @MainActor
    static func main() async throws {
        var passed = 0
        func check(_ name: String, _ body: @MainActor () async throws -> Void) async throws {
            try await body()
            passed += 1
            print("PASS: \(name)")
        }

        let launchCases: [(String, URL, Int, Bool)] = [
            ("downloaded app requires setup", download, 0, true),
            ("App Translocation requires setup", URL(fileURLWithPath: "/private/var/folders/fixture/AppTranslocation/id/d/Focus Studio.app"), 0, true),
            ("user Applications copy requires canonical setup", URL(fileURLWithPath: "/Users/fixture/Applications/Focus Studio.app"), 0, true),
            ("canonical app starts without conflicts", canonical, 0, false),
            ("canonical directory hint does not matter", URL(fileURLWithPath: canonical.path, isDirectory: true), 0, false),
            ("canonical duplicate requires setup", canonical, 1, true),
            ("canonical path is standardized", URL(fileURLWithPath: "/Applications/Other/../Focus Studio.app"), 0, false),
            ("raw swift binary starts", URL(fileURLWithPath: "/build/debug/FocusStudio"), 0, false),
            ("raw swift binary bypasses app conflict gate", URL(fileURLWithPath: "/build/debug/FocusStudio"), 2, false)
        ]
        for (name, bundle, count, expected) in launchCases {
            try await check(name) {
                expect(AppInstallationLaunchPolicy.requiresSetup(bundleURL: bundle, destination: canonical,
                    otherInstanceCount: count) == expected, name)
            }
        }

        try await check("no other instance succeeds") {
            try await handoff([]).quitOtherCopies()
        }
        try await check("current PID is never asked to quit") {
            let current = FakeInstance(100, download)
            current.onTermination = { preconditionFailure("The current process must never be terminated") }
            try await handoff([current]).quitOtherCopies()
            expect(current.terminationRequests == 0 && !current.terminated)
        }
        try await check("all other instances quit normally") {
            let current = FakeInstance(100, download)
            let old = FakeInstance(101, canonical)
            let renamed = FakeInstance(102, URL(fileURLWithPath: "/Applications/Focus Studio Old.app"))
            try await handoff([current, old, renamed]).quitOtherCopies()
            expect(old.terminated && renamed.terminated)
            expect(old.terminationRequests == 1 && renamed.terminationRequests == 1)
            expect(current.terminationRequests == 0)
        }
        try await check("asynchronous normal quit is awaited") {
            let old = FakeInstance(101, canonical)
            old.onTermination = {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(5))
                    old.terminated = true
                }
                return true
            }
            try await handoff([old]).quitOtherCopies()
            expect(old.terminated && old.terminationRequests == 1)
        }
        try await check("refusal blocks installation") {
            let old = FakeInstance(101, canonical)
            old.onTermination = { false }
            try await expectFailure(quitFailure) { try await handoff([old]).quitOtherCopies() }
            expect(!old.terminated && old.terminationRequests == 1)
        }
        try await check("accepted quit that never completes times out") {
            let old = FakeInstance(101, canonical)
            old.onTermination = { true }
            let pending = AppInstallationHandoff(currentProcessID: 100, runningInstances: { [old.instance] },
                timeout: .milliseconds(15), pollInterval: .milliseconds(1))
            try await expectFailure(quitFailure) { try await pending.quitOtherCopies() }
            expect(!old.terminated && old.terminationRequests == 1)
        }
        try await check("already terminated instance is ignored") {
            let old = FakeInstance(101, canonical)
            old.terminated = true
            try await handoff([old]).quitOtherCopies()
            expect(old.terminationRequests == 0)
        }
        try await check("termination race may report false after exiting") {
            let old = FakeInstance(101, canonical)
            old.onTermination = { old.terminated = true; return false }
            try await handoff([old]).quitOtherCopies()
            expect(old.terminated && old.terminationRequests == 1)
        }
        try await check("keeping canonical leaves it running and quits other copies") {
            let current = FakeInstance(100, download)
            let kept = FakeInstance(101, URL(fileURLWithPath: "/Applications/Other/../Focus Studio.app"))
            let old = FakeInstance(102, URL(fileURLWithPath: "/Users/fixture/Applications/Focus Studio.app"))
            try await handoff([current, kept, old]).quitOtherCopies(keeping: canonical)
            expect(!kept.terminated && kept.terminationRequests == 0)
            expect(old.terminated && old.terminationRequests == 1)
            expect(current.terminationRequests == 0)
        }
        try await check("unknown bundle URL does not evade termination") {
            let unknown = FakeInstance(101, nil)
            try await handoff([unknown]).quitOtherCopies(keeping: canonical)
            expect(unknown.terminated && unknown.terminationRequests == 1)
        }
        try await check("new instance during quit blocks installation") {
            let old = FakeInstance(101, canonical)
            let newcomer = FakeInstance(102, download)
            var running = [old]
            old.onTermination = {
                old.terminated = true
                running.append(newcomer)
                return true
            }
            let pending = AppInstallationHandoff(currentProcessID: 100, runningInstances: { running.map(\.instance) })
            try await expectFailure(newInstanceFailure) { try await pending.quitOtherCopies() }
            expect(old.terminated)
            expect(!newcomer.terminated && newcomer.terminationRequests == 0,
                "A newly launched process must block, not be quit without another inventory")
        }
        try await check("new instance while awaiting old exit also blocks") {
            let old = FakeInstance(101, canonical)
            let newcomer = FakeInstance(102, download)
            var running = [old]
            old.onTermination = {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(5))
                    running.append(newcomer)
                    old.terminated = true
                }
                return true
            }
            let pending = AppInstallationHandoff(currentProcessID: 100, runningInstances: { running.map(\.instance) },
                timeout: .seconds(1), pollInterval: .milliseconds(1))
            try await expectFailure(newInstanceFailure) { try await pending.quitOtherCopies() }
            expect(old.terminated && newcomer.terminationRequests == 0)
        }
        try await check("cancellation interrupts waiting without further termination requests") {
            let old = FakeInstance(101, canonical)
            old.onTermination = { true }
            let pending = handoff([old])
            let task = Task { try await pending.quitOtherCopies() }
            while old.terminationRequests == 0 { await Task.yield() }
            task.cancel()
            do {
                try await task.value
                preconditionFailure("Cancelled handoff unexpectedly succeeded")
            } catch is CancellationError {}
            expect(old.terminationRequests == 1 && !old.terminated)
        }
        print("Installation handoff regression tests passed: \(passed)")
    }

    @MainActor
    private static func handoff(_ instances: [FakeInstance]) -> AppInstallationHandoff {
        .init(currentProcessID: 100, runningInstances: { instances.map(\.instance) },
            timeout: .seconds(1), pollInterval: .milliseconds(1))
    }

    private static func expect(_ condition: Bool, _ message: String = "Unexpected installation handoff state") {
        precondition(condition, message)
    }

    @MainActor
    private static func expectFailure(_ key: String, _ body: @MainActor () async throws -> Void) async throws {
        do {
            try await body()
            preconditionFailure("Operation unexpectedly succeeded: \(key)")
        } catch let error as AppInstallationError {
            expect(error.key == key, "Expected \(key), got \(error.key)")
        }
    }
}
