import Combine
import Foundation

/// Checks public release metadata only. Downloads are an explicit browser action
/// in the UI; this service never writes the application, projects, or credentials.
@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()
    enum Status: Equatable {
        case idle, checking, upToDate, noRelease, available, requiresNewerOS, failed(String)
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var availableRelease: AppUpdateRelease?
    @Published private(set) var lastCheckedAt: Date?
    @Published var automaticallyChecks: Bool {
        didSet { defaults.set(automaticallyChecks, forKey: Self.autoKey) }
    }
    @Published var channel: AppUpdateChannel {
        didSet {
            guard oldValue != channel else { return }
            defaults.set(channel.rawValue, forKey: Self.channelKey)
            dismissedVersion = nil
            restoreCachedState()
        }
    }
    @Published private(set) var dismissedVersion: String?
    let installedVersion: String
    let operatingSystem: OperatingSystemVersion
    private let defaults: UserDefaults
    private let session: URLSession
    private let now: () -> Date
    @Published private(set) var isChecking = false
    private static let autoKey = "updates.automaticallyChecks"
    private static let channelKey = "updates.channel"

    var shouldShowNotice: Bool {
        guard let release = availableRelease else { return false }
        return release.version != dismissedVersion && release.supports(operatingSystem)
    }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared,
         installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
         defaultChannel: AppUpdateChannel = AppUpdateChannel(rawValue: Bundle.main.object(forInfoDictionaryKey: "FocusStudioUpdateChannel") as? String ?? "") ?? .preview,
         operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.session = session; self.installedVersion = installedVersion
        self.operatingSystem = operatingSystem; self.now = now
        automaticallyChecks = defaults.object(forKey: Self.autoKey) as? Bool ?? true
        channel = AppUpdateChannel(rawValue: defaults.string(forKey: Self.channelKey) ?? "") ?? defaultChannel
        restoreCachedState()
    }

    func dismissNotice() { dismissedVersion = availableRelease?.version }

    func checkIfNeeded() async {
        guard automaticallyChecks else { return }
        await check(force: false)
    }

    func check(force: Bool = true) async {
        guard !isChecking else { return }
        let selectedChannel = channel
        let time = now()
        guard force || AppUpdateCheckPolicy.shouldCheck(lastAttempt: lastCheckedAt, now: time) else { return }
        isChecking = true
        status = .checking
        lastCheckedAt = time
        defaults.set(time, forKey: attemptKey(selectedChannel))
        defaults.set("checking", forKey: outcomeKey(selectedChannel))
        defer { isChecking = false }
        do {
            guard AppSemanticVersion(installedVersion) != nil else { throw AppUpdateError.invalidInstalledVersion }
            var request = URLRequest(url: AppUpdateRelease.feedURL(channel: selectedChannel))
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request, delegate: AppUpdateRedirectRefuser())
            guard channel == selectedChannel else { return }
            guard let http = response as? HTTPURLResponse else { throw AppUpdateError.invalidRelease }
            if http.statusCode == 404 {
                availableRelease = nil
                defaults.removeObject(forKey: cacheKey(selectedChannel))
                status = .noRelease
                defaults.set("noRelease", forKey: outcomeKey(selectedChannel))
                return
            }
            guard http.statusCode == 200 else { throw AppUpdateError.httpStatus(http.statusCode) }
            let release = try AppUpdateRelease.decode(data, expectedChannel: selectedChannel)
            defaults.set(data, forKey: cacheKey(selectedChannel))
            defaults.set("success", forKey: outcomeKey(selectedChannel))
            apply(release)
        } catch {
            guard channel == selectedChannel else { return }
            let error = error as? AppUpdateError ?? .network
            status = .failed(error.localizedDescription)
            defaults.set("failed", forKey: outcomeKey(selectedChannel))
        }
    }

    private func apply(_ release: AppUpdateRelease) {
        do {
            guard try release.isNewer(than: installedVersion) else {
                availableRelease = nil
                status = .upToDate
                return
            }
            availableRelease = release
            status = release.supports(operatingSystem) ? .available : .requiresNewerOS
        } catch {
            availableRelease = nil
            status = .failed(AppUpdateError.invalidInstalledVersion.localizedDescription)
        }
    }

    private func restoreCachedState() {
        lastCheckedAt = defaults.object(forKey: attemptKey(channel)) as? Date
        availableRelease = nil
        status = .idle
        if let data = defaults.data(forKey: cacheKey(channel)), let release = try? AppUpdateRelease.decode(data, expectedChannel: channel) {
            apply(release)
        }
        switch defaults.string(forKey: outcomeKey(channel)) {
        case "checking", "failed": status = .failed("The last update check did not complete. Please try again.")
        case "noRelease": status = .noRelease
        default: break
        }
    }

    private func outcomeKey(_ channel: AppUpdateChannel) -> String { "updates.outcome.\(channel.rawValue)" }
    private func attemptKey(_ channel: AppUpdateChannel) -> String { "updates.lastAttempt.\(channel.rawValue)" }
    private func cacheKey(_ channel: AppUpdateChannel) -> String { "updates.release.v1.\(channel.rawValue)" }
}

private final class AppUpdateRedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
