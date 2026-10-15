import Foundation

/// Keep this policy independent of AppKit so launch/quit races can be tested
/// without opening or terminating any of the user's applications.
enum AppInstallationLaunchPolicy {
    static func requiresSetup(bundleURL: URL, destination: URL, otherInstanceCount: Int) -> Bool {
        bundleURL.pathExtension == "app"
            && (bundleURL.standardizedFileURL.path != destination.standardizedFileURL.path || otherInstanceCount > 0)
    }
}

@MainActor
struct AppInstallationHandoff {
    struct Instance {
        let processID: Int32
        let url: URL?
        let requestTermination: () -> Bool
        let hasTerminated: () -> Bool
    }

    let currentProcessID: Int32
    let runningInstances: () -> [Instance]
    var timeout: Duration = .seconds(10)
    var pollInterval: Duration = .milliseconds(100)

    /// Normal Quit only. A refusal, timeout, or newly launched copy prevents
    /// installation; never force-kill a recorder or replace a live bundle.
    func quitOtherCopies(keeping destination: URL? = nil) async throws {
        func others() -> [Instance] {
            runningInstances().filter {
                $0.processID != currentProcessID && !$0.hasTerminated()
                    && (destination == nil || $0.url?.standardizedFileURL != destination?.standardizedFileURL)
            }
        }
        let copies = others()
        for app in copies {
            guard app.requestTermination() || app.hasTerminated() else {
                throw AppInstallationError(key: "An open Focus Studio could not quit. Finish your work and quit it, then try again.")
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while copies.contains(where: { !$0.hasTerminated() }) {
            guard clock.now < deadline else {
                throw AppInstallationError(key: "An open Focus Studio could not quit. Finish your work and quit it, then try again.")
            }
            try await Task.sleep(for: pollInterval)
        }
        guard others().isEmpty else {
            throw AppInstallationError(key: "Another Focus Studio opened during installation. Quit it and try again.")
        }
    }
}
