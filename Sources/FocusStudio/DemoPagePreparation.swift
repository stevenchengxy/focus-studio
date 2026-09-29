import AppKit
import CoreGraphics
import FocusStudioAutomation
import FocusStudioCore
import Foundation
import ImageIO

/// Opening a website is an ordinary visible browser operation. No automation
/// bridge, Apple Events permission, remote debugging port or hidden page is used.
@MainActor
enum DemoPagePreparation {
    struct BrowserApplication: Equatable {
        var url: URL
        var name: String
    }

    struct VisibleWindow: Equatable {
        var id: UInt32
        var frame: CaptureRect
    }

    struct Driver {
        var application: (AIDemoBrowser) -> BrowserApplication?
        var open: (URL, BrowserApplication) async throws -> pid_t
        var frontmostPID: () -> pid_t?
        /// Front-to-back order, already filtered to visible normal windows.
        var windows: (pid_t) -> [VisibleWindow]
        var sources: () async throws -> [CaptureTargetInfo]
        var wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(350)) }
        var rememberWindow: (CaptureTargetInfo) throws -> Void = { _ in }
    }

    static func application(for browser: AIDemoBrowser, locate: (String) -> URL?) -> BrowserApplication? {
        let choices: [(String, String)]
        switch browser {
        case .automatic: choices = [("com.google.Chrome", "Google Chrome"), ("com.apple.Safari", "Safari")]
        case .chrome: choices = [("com.google.Chrome", "Google Chrome")]
        case .safari: choices = [("com.apple.Safari", "Safari")]
        }
        for (id, name) in choices {
            if let url = locate(id) { return BrowserApplication(url: url, name: name) }
        }
        return nil
    }

    /// Selects the foremost window of the exact process returned by open().
    /// An old window whose title happens to match the URL never wins a score.
    static func target(in windows: [VisibleWindow], sources: [CaptureTargetInfo]) -> CaptureTargetInfo? {
        guard let foremost = windows.first else { return nil }
        return sources.first {
            $0.kind == .window && $0.nativeID == foremost.id && $0.frame == foremost.frame
        }
    }

    static func prepare(url: URL, browser: AIDemoBrowser, driver: Driver,
                        checkReady: () throws -> Void) async throws -> AIPreparedDemoPage {
        let url = try AIDemoPageURL.parse(url.absoluteString)
        try checkReady()
        guard let application = driver.application(browser) else {
            throw AIToolError.failed("The requested browser is not installed. Install Chrome or choose Safari.")
        }
        try Task.checkCancellation()
        let pid = try await driver.open(url, application)
        var previous: CaptureTargetInfo?
        // Wait for the new foreground page window and its geometry to settle.
        // A page loading or login screen is still visible content: its real
        // state is inspected by the assistant's first recording observation.
        for _ in 0..<24 {
            try await driver.wait()
            try Task.checkCancellation()
            try checkReady()
            guard driver.frontmostPID() == pid else { previous = nil; continue }
            let before = driver.windows(pid)
            let sources = try await driver.sources()
            try checkReady()
            guard driver.frontmostPID() == pid,
                  let current = target(in: before, sources: sources),
                  driver.windows(pid).first == before.first else { previous = nil; continue }
            if previous == current {
                try driver.rememberWindow(current)
                return AIPreparedDemoPage(url: url, source: AIRecordingSource(target: current), browserName: application.name)
            }
            previous = current
        }
        throw AIToolError.failed("The browser opened, but its visible window could not be confirmed. Bring the requested page to the front, keep its window still, then prepare the page again.")
    }

    static func windows(for pid: pid_t) -> [VisibleWindow] {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else { return [] }
        return entries.compactMap { entry in
            guard (entry[kCGWindowOwnerPID] as? NSNumber)?.int32Value == pid,
                  (entry[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                  ((entry[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let id = (entry[kCGWindowNumber] as? NSNumber)?.uint32Value,
                  let bounds = entry[kCGWindowBounds] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 320, frame.height >= 200 else { return nil }
            return VisibleWindow(id: id, frame: CaptureRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
        }
    }

    static func open(_ url: URL, application: BrowserApplication) async throws -> pid_t {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.open([url], withApplicationAt: application.url, configuration: configuration) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if let app { continuation.resume(returning: app.processIdentifier) }
                else { continuation.resume(throwing: AIToolError.failed("The browser could not open the requested website.")) }
            }
        }
    }
}

extension StudioModel {
    /// Preflight is a read of the selected window before a recording exists.
    /// Its image is never eligible for the live pointer-action observation gate.
    func capturePreparedDemoFrame(sourceID: String, to url: URL) async throws -> AIJSONValue {
        try checkDemoPagePreparationReady()
        guard permissionStatus.screenRecording else {
            throw AIToolError.failed("Enable Screen Recording for Focus Studio in System Settings, then prepare the demo page again.")
        }
        isBusy = true
        defer { isBusy = false }
        let sources = try await refreshListedSources()
        try Task.checkCancellation()
        try checkDemoPagePreparationReady(ownsBusyState: true)
        let target = try Self.preparedDemoTarget(sourceID: sourceID, sources: sources)
        let before = try Self.visiblePreparedDemoFrame(target)
        guard before == target.frame else {
            throw AIToolError.failed("The prepared window changed while observing it. Prepare the page again.")
        }
        try await captureEngine.captureScreenshot(target: target, to: url)
        try Task.checkCancellation()
        try checkDemoPagePreparationReady(ownsBusyState: true)
        guard try Self.visiblePreparedDemoFrame(target) == before,
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil), image.width > 0, image.height > 0 else {
            throw AIToolError.failed("The prepared window changed while observing it. Prepare the page again.")
        }
        return Self.preparedDemoFrameData(sourceID: sourceID, frame: before, width: image.width, height: image.height, url: url)
    }

    static func preparedDemoTarget(sourceID: String, sources: [CaptureTargetInfo]) throws -> CaptureTargetInfo {
        guard let target = sources.first(where: { $0.id == sourceID }), target.kind == .window else {
            throw AIToolError.failed("The prepared window is no longer available. Open the demo page again.")
        }
        return target
    }

    private static func visiblePreparedDemoFrame(_ target: CaptureTargetInfo) throws -> CaptureRect {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]],
              let entry = entries.first(where: { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value == target.nativeID }),
              (entry[kCGWindowLayer] as? NSNumber)?.intValue == 0,
              ((entry[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1) > 0,
              let bounds = entry[kCGWindowBounds] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 0, rect.height > 0 else {
            throw AIToolError.failed("The prepared window is no longer visible. Restore it before starting the demo.")
        }
        return CaptureRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    static func preparedDemoFrameData(sourceID: String, frame: CaptureRect, width: Int, height: Int, url: URL) -> AIJSONValue {
        ["source_id": AIJSONValue(sourceID), "purpose": "preflight", "path": AIJSONValue(url.path),
         "coordinate_space": "normalized_uncropped_source", "width": AIJSONValue(width), "height": AIJSONValue(height),
         "source_frame": ["x": AIJSONValue(frame.x), "y": AIJSONValue(frame.y),
                          "width": AIJSONValue(frame.width), "height": AIJSONValue(frame.height)]]
    }

    /// Called by both the guided launcher and prepare_demo_page. Preparation
    /// leaves the existing editor open and never starts a capture implicitly.
    func prepareDemoPage(url: URL, browser: AIDemoBrowser = .automatic) async throws -> AIPreparedDemoPage {
        try checkDemoPagePreparationReady()
        let permissions = permissionStatus
        guard permissions.screenRecording else {
            throw AIToolError.failed("Enable Screen Recording for Focus Studio in System Settings, then prepare the demo page again.")
        }
        guard permissions.accessibility else {
            throw AIToolError.failed("Enable Accessibility for Focus Studio in System Settings so Codex can operate the demo window.")
        }
        isBusy = true
        defer { isBusy = false }
        let driver = DemoPagePreparation.Driver(
            application: { DemoPagePreparation.application(for: $0, locate: NSWorkspace.shared.urlForApplication(withBundleIdentifier:)) },
            open: DemoPagePreparation.open,
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            windows: DemoPagePreparation.windows,
            sources: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.refreshListedSources()
            },
            rememberWindow: RecordingWindowFocus.rememberFrontmostWindow
        )
        return try await DemoPagePreparation.prepare(url: url, browser: browser, driver: driver) { [weak self] in
            guard let self else { throw CancellationError() }
            try self.checkDemoPagePreparationReady(ownsBusyState: true)
        }
    }

    func checkDemoPagePreparationReady(ownsBusyState: Bool = false) throws {
        guard (ownsBusyState || !isBusy), !isManagingProjects, !isRunningCodexPlan,
              !isSelectingArea, !isWaitingForMicrophoneAccess, !isExportingFromEditor,
              !captureEngine.isRecording, currentRecording?.isLive != true,
              !isFinishingRecording, destination != .countdown, destination != .recording else {
            throw AIToolError.failed("Finish the current recording or operation before opening a demo page.")
        }
    }
}
