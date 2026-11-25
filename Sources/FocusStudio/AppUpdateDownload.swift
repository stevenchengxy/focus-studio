import Foundation

/// A verified image lives in the app's temporary directory while the user
/// finishes working. The installer stages its own copy before relaunch.
final class AppUpdatePackage: Sendable {
    let file: URL
    let build: String
    let verify: @Sendable () async throws -> Void

    init(file: URL, build: String, verify: @escaping @Sendable () async throws -> Void) {
        self.file = file
        self.build = build
        self.verify = verify
    }

    deinit { try? FileManager.default.removeItem(at: file) }
}

enum AppUpdateDownloadEvent: Sendable {
    case progress(Int), verifying
}

enum AppUpdateDownload {
    typealias Observer = @Sendable (AppUpdateDownloadEvent) -> Void

    static func run(release: AppUpdateRelease, report: @escaping Observer) async throws -> AppUpdatePackage {
        let manifest = try await MacUpdateTrust.fetch(for: release)
        try Task.checkCancellation()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusStudio-update-\(UUID().uuidString).dmg")
        let package = AppUpdatePackage(file: destination, build: manifest.build) {
            try await MacUpdateTrust.verify(file: destination, against: manifest)
        }
        let transfer = AppUpdateDiskTransfer(release: release, asset: manifest.assetName,
                                             expectedBytes: manifest.byteCount, destination: destination, report: report)
        try await transfer.download()
        try Task.checkCancellation()
        report(.verifying)
        try await package.verify()
        try Task.checkCancellation()
        return package
    }
}

/// Redirects can resolve to the website's pinned proxy or the release's exact
/// GitHub asset. A signed CDN URL is accepted only from that GitHub response.
struct AppUpdateAssetRoute {
    let release: AppUpdateRelease
    let asset: String

    func permitsRedirect(from source: URL, to url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.fragment == nil, url.port == nil || url.port == 443 else { return false }
        let tag = release.releaseURL.lastPathComponent
        let githubAsset = URL(string: "https://github.com/stevenchengxy/focus-studio/releases/download/")!
            .appendingPathComponent(tag).appendingPathComponent(asset)
        if url.host?.lowercased() == AppUpdateRelease.websiteHost {
            guard source == release.downloadURL, url.path == release.downloadURL.path,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
            let original = URLComponents(url: release.downloadURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let expected = original + [URLQueryItem(name: "release", value: tag), URLQueryItem(name: "asset", value: asset)]
            return items.count == expected.count && Set(items) == Set(expected)
        }
        if url == githubAsset { return source.host?.lowercased() == AppUpdateRelease.websiteHost }
        return source == githubAsset && url.host?.lowercased() == "release-assets.githubusercontent.com"
    }
}

private enum TransferError: LocalizedError {
    case invalidPackage
    var errorDescription: String? { "The update download did not match the release. Try again." }
}

private final class AppUpdateDiskTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let route: AppUpdateAssetRoute
    private let expectedBytes: Int64
    private let destination: URL
    private let report: AppUpdateDownload.Observer

    // All mutable state is accessed on the session's serial delegate queue.
    private var completion: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var fileError: Error?
    private var moved = false
    private var lastPercent = -1

    init(release: AppUpdateRelease, asset: String, expectedBytes: Int64, destination: URL,
         report: @escaping AppUpdateDownload.Observer) {
        route = AppUpdateAssetRoute(release: release, asset: asset)
        self.expectedBytes = expectedBytes
        self.destination = destination
        self.report = report
    }

    func download() async throws {
        guard expectedBytes > 0 else { throw TransferError.invalidPackage }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 45
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    guard !self.cancelled else { continuation.resume(throwing: CancellationError()); return }
                    self.completion = continuation
                    var request = URLRequest(url: self.route.release.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData)
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                    let task = session.downloadTask(with: request)
                    self.task = task
                    task.resume()
                }
            }
        } onCancel: {
            self.queue.addOperation {
                self.cancelled = true
                self.task?.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let source = response.url, let url = request.url, route.permitsRedirect(from: source, to: url) else {
            fileError = TransferError.invalidPackage
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= expectedBytes,
              totalBytesExpectedToWrite <= 0 || totalBytesExpectedToWrite == expectedBytes else {
            fileError = TransferError.invalidPackage
            downloadTask.cancel()
            return
        }
        let percent = Int(100 * Double(totalBytesWritten) / Double(expectedBytes))
        if percent > lastPercent {
            lastPercent = percent
            report(.progress(percent))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !cancelled, fileError == nil else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw TransferError.invalidPackage }
            guard response.statusCode == 200 else { throw AppUpdateError.httpStatus(response.statusCode) }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, Int64(size) == expectedBytes else { throw TransferError.invalidPackage }
            try FileManager.default.moveItem(at: location, to: destination)
            moved = true
        } catch { fileError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { completion = nil; self.task = nil }
        if cancelled { completion?.resume(throwing: CancellationError()) }
        else if let error = fileError ?? error { completion?.resume(throwing: error) }
        else if moved { completion?.resume() }
        else { completion?.resume(throwing: TransferError.invalidPackage) }
    }
}
