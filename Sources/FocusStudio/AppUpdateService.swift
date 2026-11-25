import Combine
import Foundation

/// One update operation survives navigation and closing the Settings window.
@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()
    enum Status: Equatable {
        case idle, checking, upToDate, noRelease, available, requiresNewerOS, failed(String)
    }
    enum Phase: Equatable {
        case idle, downloading(Int?), verifying, ready, installing, restarting
    }
    typealias Download = (AppUpdateRelease, @escaping AppUpdateDownload.Observer) async throws -> AppUpdatePackage
    typealias Handoff = @MainActor () throws -> Void
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var operationError: String?
    private let download: Download
    private var operationID: UUID?
    private var downloadTask: Task<Void, Never>?
    private var package: AppUpdatePackage?

    var isUpdating: Bool { phase != .idle && phase != .ready }
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
            resetTransfer()
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
         now: @escaping () -> Date = Date.init,
         download: @escaping Download = AppUpdateDownload.run) {
        self.download = download
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
        guard !isChecking, !isUpdating else { return }
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
                resetTransfer()
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
        if availableRelease != release { resetTransfer() }
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

    @discardableResult
    func startDownload() -> Task<Void, Never>? {
        guard !isChecking, phase == .idle, let release = availableRelease,
              release.supports(operatingSystem),
              (try? release.validate(expectedChannel: channel)) != nil,
              (try? release.isNewer(than: installedVersion)) == true else { return nil }
        let id = UUID()
        operationID = id
        operationError = nil
        phase = .downloading(nil)
        let report: AppUpdateDownload.Observer = { [weak self] event in
            Task { @MainActor in
                guard let self, self.operationID == id, case let .downloading(current) = self.phase else { return }
                switch event {
                case let .progress(percent):
                    self.phase = .downloading(max(current ?? 0, min(100, percent)))
                case .verifying: self.phase = .verifying
                }
            }
        }
        let task = Task {
            defer { if operationID == id { downloadTask = nil } }
            guard operationID == id, !Task.isCancelled else { return }
            do {
                let candidate = try await download(release, report)
                guard operationID == id, !Task.isCancelled else { return }
                package = candidate
                phase = .ready
            } catch {
                guard operationID == id else { return }
                phase = .idle
                operationError = error.localizedDescription
            }
        }
        downloadTask = task
        return task
    }

    func cancelDownload() {
        switch phase {
        case .downloading, .verifying: resetTransfer()
        default: break
        }
    }

    /// Recheck both the cached bytes and active work immediately before staging
    /// and handoff. If work started during staging, keep the download for later.
    func install(isBusyNow: @escaping @MainActor () -> Bool,
                 prepare: (AppUpdatePackage, AppUpdateRelease) async throws -> Handoff,
                 flushEdits: @MainActor () async -> Void, restart: @MainActor () -> Void) async {
        guard !isChecking, phase == .ready, let package, let release = availableRelease, let id = operationID else { return }
        let busyMessage = "Return to the library and finish active tasks to install the update."
        guard !isBusyNow() else { operationError = busyMessage; return }
        operationError = nil
        phase = .installing
        do {
            try await package.verify()
        } catch {
            guard operationID == id else { return }
            resetTransfer()
            operationError = error.localizedDescription
            return
        }
        do {
            guard operationID == id else { return }
            let beginHandoff = try await prepare(package, release)
            await flushEdits()
            guard operationID == id else { return }
            guard !isBusyNow() else {
                phase = .ready
                operationError = busyMessage
                return
            }
            try beginHandoff()
            phase = .restarting
            self.package = nil
            restart()
        } catch {
            guard operationID == id else { return }
            phase = .ready
            operationError = error.localizedDescription
        }
    }

    func resetTransfer() {
        operationID = nil
        downloadTask?.cancel()
        downloadTask = nil
        package = nil
        operationError = nil
        phase = .idle
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
