import CryptoKit
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

    static func verifySignedPackage(_ release: AppUpdateRelease) async throws {
        let contents = Data(repeating: 0x42, count: 1024)
        let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        let key = Curve25519.Signing.PrivateKey()
        let name = "Focus-Studio-1.14.3-universal-local.dmg"
        let payload = ["Focus Studio macOS update v1", "v1.14.3-preview.1", "1.14.3", "70", "preview", name, "1024", digest, ""].joined(separator: "\n")
        let signed: [String: Any] = [
            "tag": "v1.14.3-preview.1", "version": "1.14.3", "build": "70", "channel": "preview", "assetName": name,
            "byteCount": 1024, "sha256": digest, "signature": try key.signature(for: Data(payload.utf8)).base64EncodedString()
        ]
        func authenticate(_ value: [String: Any]) throws -> MacUpdateManifest {
            try MacUpdateTrust.authenticate(JSONSerialization.data(withJSONObject: value), release: release, publicKey: key.publicKey.rawRepresentation)
        }
        let manifest = try authenticate(signed)
        for changed: [String: Any] in [["tag": "v1.14.3"], ["version": "1.14.4"], ["build": "71"], ["channel": "stable"],
                                       ["assetName": "../" + name], ["byteCount": 1025], ["sha256": String(repeating: "a", count: 64)], ["signature": "invalid"]] {
            rejects({ _ = try authenticate(signed.merging(changed) { _, new in new }) }, "accepted changed manifest field")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try contents.write(to: file)
        try await MacUpdateTrust.verify(file: file, against: manifest)
        for changed in [Data(contents.dropLast()), contents + Data([0]), Data(repeating: 0, count: 1024)] {
            try changed.write(to: file)
            do { try await MacUpdateTrust.verify(file: file, against: manifest); fatalError("accepted damaged installer") }
            catch MacUpdateTrust.Failure.integrity { }
        }
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
        try await verifySignedPackage(release)
        let asset = "Focus-Studio-1.14.3-universal-local.dmg"
        let route = AppUpdateAssetRoute(release: release, asset: asset)
        let pinned = URL(string: release.downloadURL.absoluteString + "&release=v1.14.3-preview.1&asset=" + asset)!
        let github = URL(string: "https://github.com/stevenchengxy/focus-studio/releases/download/v1.14.3-preview.1/" + asset)!
        let cdn = URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/123/456?signature=abc")!
        check(route.permitsRedirect(from: release.downloadURL, to: pinned), "website download resolves to exact release")
        check(route.permitsRedirect(from: pinned, to: github) && route.permitsRedirect(from: github, to: cdn), "signed repository asset chain")
        check(!route.permitsRedirect(from: pinned, to: cdn), "no direct unsigned CDN redirects")
        for bad in [pinned.absoluteString + "&asset=" + asset, pinned.absoluteString.replacingOccurrences(of: "release=v1.14.3", with: "release=v1.14.2"),
                    github.absoluteString.replacingOccurrences(of: "stevenchengxy", with: "someone"), "https://example.com/", "file:///tmp/update.dmg"] {
            check(!route.permitsRedirect(from: release.downloadURL, to: URL(string: bad)!), "reject ambiguous and foreign asset redirect")
        }
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
        try await exerciseDownload(defaults: defaults, session: session)
        print("FocusStudioUpdateTests: PASS (feed, asset identity, download cancellation/retry, stale progress, busy handoff, re-verification and restart)")
    }

    @MainActor
    static func exerciseDownload(defaults: UserDefaults, session: URLSession) async throws {
        let driver = ControlledDownload()
        let test = AppUpdateService(defaults: defaults, session: session, installedVersion: "1.14.2",
                                    download: { _, report in try await driver.run(report) })
        await test.check()
        guard let early = test.startDownload() else { fatalError("valid release can download") }
        test.cancelDownload()
        await early.value
        check(test.phase == .idle && driver.reports.isEmpty, "instant cancellation makes no transfer")

        guard let first = test.startDownload() else { fatalError("retry after cancelling") }
        await driver.waitForStart(1)
        check(test.startDownload() == nil, "a second click does not start another transfer")
        driver.reports[0](.progress(28))
        let progressDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while test.phase != .downloading(28) && ContinuousClock.now < progressDeadline { await Task.yield() }
        check(test.phase == .downloading(28), "byte progress reaches Settings")
        test.cancelDownload()
        guard let second = test.startDownload() else { fatalError("retry while old delegate unwinds") }
        await driver.waitForStart(2)
        driver.reports[0](.verifying)
        let stale = try driver.finish(index: 0)
        await first.value
        check(test.phase == .downloading(nil), "cancelled verification never replaces new progress")
        check(!FileManager.default.fileExists(atPath: stale.path), "discard late image")
        driver.fail(index: 1)
        await second.value
        check(test.phase == .idle && test.operationError != nil, "failure can retry")

        guard let third = test.startDownload() else { fatalError("retry a failed transfer") }
        await driver.waitForStart(3)
        let file = try driver.finish(index: 2)
        await third.value
        check(test.phase == .ready && test.operationError == nil, "download stays ready without installing")
        var prepared = 0
        var quits = 0
        var busy = true
        func refuseHandoff(_: AppUpdatePackage, _: AppUpdateRelease) async throws -> AppUpdateService.Handoff {
            prepared += 1
            return { fatalError("unexpected handoff") }
        }
        await test.install(isBusyNow: { busy }, prepare: refuseHandoff, flushEdits: {}, restart: { quits += 1 })
        check(prepared == 0 && quits == 0, "a busy recording prevents staging")
        busy = false
        await test.install(isBusyNow: { busy }, prepare: refuseHandoff,
                           flushEdits: { busy = true }, restart: { quits += 1 })
        check(prepared == 1 && quits == 0 && test.phase == .ready, "starting work during prepare retains package and never exits")
        try Data("corrupt".utf8).write(to: file)
        await test.install(isBusyNow: { false }, prepare: refuseHandoff, flushEdits: {}, restart: { quits += 1 })
        check(prepared == 1 && quits == 0 && test.phase == .idle && test.operationError != nil,
              "a changed cached file is rejected before staging; a fresh download is offered")
        check(!FileManager.default.fileExists(atPath: file.path), "invalid cached file is removed")

        guard let fourth = test.startDownload() else { fatalError("download a clean copy") }
        await driver.waitForStart(4)
        let good = try driver.finish(index: 3)
        await fourth.value
        var sequence: [String] = []
        await test.install(isBusyNow: { false }, prepare: { pack, release in
            check(pack.file == good && pack.build == "71" && release.version == "1.14.3", "prepared expected version, build and file")
            sequence.append("prepare")
            return { sequence.append("handoff") }
        }, flushEdits: { sequence.append("save") }, restart: { sequence.append("restart") })
        check(sequence == ["prepare", "save", "handoff", "restart"] && test.phase == .restarting, "save and hand off before terminating")
        check(!FileManager.default.fileExists(atPath: good.path), "image cleaned after handoff")
    }
}

@MainActor
private final class ControlledDownload {
    var reports: [AppUpdateDownload.Observer] = []
    var pending: [CheckedContinuation<AppUpdatePackage, Error>?] = []

    func run(_ report: @escaping AppUpdateDownload.Observer) async throws -> AppUpdatePackage {
        reports.append(report)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func waitForStart(_ count: Int) async {
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while pending.count < count && ContinuousClock.now < until { await Task.yield() }
        precondition(pending.count == count, "timed out awaiting fixture download")
    }

    func finish(index: Int) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("FocusStudio-update-test-\(UUID()).dmg")
        let bytes = Data("signed".utf8)
        try bytes.write(to: file)
        pending[index]!.resume(returning: AppUpdatePackage(file: file, build: "71") {
            guard try Data(contentsOf: file) == bytes else { throw AppUpdateError.invalidRelease }
        })
        pending[index] = nil
        return file
    }

    func fail(index: Int) {
        pending[index]!.resume(throwing: URLError(.networkConnectionLost))
        pending[index] = nil
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
