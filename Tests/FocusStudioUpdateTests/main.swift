import Foundation

@main
struct FocusStudioUpdateTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    static func fixture(version: String = "1.14.3", channel: String = "preview", requested: String = "preview", minimumOS: String = "15.0") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "platform": "mac", "version": version, "channel": channel, "title": "Focus Studio \(version)",
            "published_at": "2026-10-14T09:30:00Z", "minimum_os": minimumOS,
            "download_url": "https://\(AppUpdateRelease.websiteHost)/api/download/mac?channel=\(requested)&version=\(version)",
            "release_url": "https://github.com/stevenchengxy/focus-studio/releases/tag/v\(version)-preview.1"
        ])
    }

    static func rejects(_ body: () throws -> Void, _ message: String) {
        do { try body(); fatalError(message) } catch {}
    }

    @MainActor
    static func main() async throws {
        let order = ["1.9.9", "1.10.0-alpha", "1.10.0-alpha.2", "1.10.0-alpha.10", "1.10.0-beta", "1.10.0-rc.1", "1.10.0", "1.14.3", "2.0.0"]
        for (a, b) in zip(order, order.dropFirst()) { check(AppSemanticVersion(a)! < AppSemanticVersion(b)!, "semantic precedence \(a), \(b)") }
        check(AppSemanticVersion("1.14.3+65") == AppSemanticVersion("1.14.3+66"), "build metadata cannot reoffer same version")
        for value in ["", "1.14", "1.14.03", "1.14.3-", "1.14.3-01", "1.14.3+", "1.14.3+build..meta", "v1.14.3", "1.14.3 "] {
            check(AppSemanticVersion(value) == nil, "reject invalid SemVer \(value)")
        }
        let release = try AppUpdateRelease.decode(fixture(), expectedChannel: .preview)
        let newer = try release.isNewer(than: "1.14.2")
        let same = try release.isNewer(than: "1.14.3")
        check(newer && !same, "only greater version prompts")
        check(release.supports(.init(majorVersion: 15, minorVersion: 0, patchVersion: 0)), "minimum OS boundary")
        check(!release.supports(.init(majorVersion: 14, minorVersion: 9, patchVersion: 9)), "unsupported OS not offered")
        _ = try AppUpdateRelease.decode(fixture(channel: "stable"), expectedChannel: .preview)
        rejects({ _ = try AppUpdateRelease.decode(fixture(), expectedChannel: .stable) }, "stable cannot receive preview")
        var bad = try JSONSerialization.jsonObject(with: fixture()) as! [String: Any]
        for url in ["https://evil.test/app.dmg", "https://\(AppUpdateRelease.websiteHost).evil.test/api/download/mac?channel=preview&version=1.14.3", "http://\(AppUpdateRelease.websiteHost)/api/download/mac?channel=preview&version=1.14.3", "https://\(AppUpdateRelease.websiteHost)/api/download/mac?channel=preview", "https://\(AppUpdateRelease.websiteHost)/api/download/mac?channel=preview&version=1.14.2", "https://key@\(AppUpdateRelease.websiteHost)/api/download/mac?channel=preview&version=1.14.3"] {
            bad["download_url"] = url
            rejects({ _ = try AppUpdateRelease.decode(JSONSerialization.data(withJSONObject: bad), expectedChannel: .preview) }, "untrusted or unpinned download accepted")
        }
        bad = try JSONSerialization.jsonObject(with: fixture()) as! [String: Any]
        bad["release_url"] = "https://github.com/other/repo/releases/tag/v1.14.3"
        rejects({ _ = try AppUpdateRelease.decode(JSONSerialization.data(withJSONObject: bad), expectedChannel: .preview) }, "foreign release link accepted")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        check(AppUpdateCheckPolicy.shouldCheck(lastAttempt: nil, now: now), "first launch checks")
        check(!AppUpdateCheckPolicy.shouldCheck(lastAttempt: now.addingTimeInterval(-86_399), now: now), "24h throttle")
        check(AppUpdateCheckPolicy.shouldCheck(lastAttempt: now.addingTimeInterval(-86_400), now: now), "24h boundary")
        check(AppUpdateCheckPolicy.shouldCheck(lastAttempt: now.addingTimeInterval(100), now: now), "clock rollback recovers")

        let suite = "FocusStudio.UpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdaterTestURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = AppUpdateService(defaults: defaults, session: session, installedVersion: "1.14.2", defaultChannel: .preview,
                                       operatingSystem: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0), now: { now })
        UpdaterTestURLProtocol.reset(status: 200, body: try fixture())
        async let first: Void = service.checkIfNeeded()
        async let second: Void = service.checkIfNeeded()
        _ = await (first, second)
        check(UpdaterTestURLProtocol.count == 1, "concurrent checks coalesce")
        check(service.status == .available && service.shouldShowNotice, "valid newer update notice")
        await service.checkIfNeeded()
        check(UpdaterTestURLProtocol.count == 1, "automatic check remains throttled")
        service.dismissNotice()
        check(!service.shouldShowNotice, "notice dismissal is nonblocking")
        let restarted = AppUpdateService(defaults: defaults, session: session, installedVersion: "1.14.2", now: { now })
        check(restarted.availableRelease?.version == "1.14.3", "validated cached offer survives relaunch")
        let updated = AppUpdateService(defaults: defaults, session: session, installedVersion: "1.14.3", now: { now })
        check(updated.availableRelease == nil && updated.status == .upToDate, "same version not offered after installing")
        UpdaterTestURLProtocol.reset(status: 404, body: Data(#"{"error":"No installer"}"#.utf8))
        await service.check()
        check(service.status == .noRelease && service.availableRelease == nil, "404 is no release, never up-to-date")
        UpdaterTestURLProtocol.reset(status: 503, body: Data())
        await service.check()
        if case .failed = service.status {} else { fatalError("network failure must remain visible") }
        let failedRestart = AppUpdateService(defaults: defaults, session: session, installedVersion: "1.14.2", now: { now })
        if case .failed = failedRestart.status {} else { fatalError("relaunch must not disguise a failed check as up-to-date") }
        service.automaticallyChecks = false
        UpdaterTestURLProtocol.reset(status: 200, body: try fixture())
        await service.checkIfNeeded()
        check(UpdaterTestURLProtocol.count == 0, "automatic opt-out sends no request")
        print("FocusStudioUpdateTests: PASS (SemVer, pinned URLs, channels, OS, cache, throttle, concurrency, failure states)")
    }
}

final class UpdaterTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseStatus = 200
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var requestCount = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requestCount }
    static func reset(status: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        responseStatus = status; responseBody = body; requestCount = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let status = Self.responseStatus, body = Self.responseBody
        Self.lock.unlock()
        // Keep the first request in flight while a concurrent check is attempted.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) {
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
