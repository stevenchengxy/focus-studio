import AppKit
import ApplicationServices
import FocusStudioCore

/// Hand off the desktop before the countdown, without hiding its floating bar.
/// Uses the selected window's owner, never an app guessed from its display name.
@MainActor
enum RecordingWindowFocus {
    enum FocusError: LocalizedError {
        case unavailable, ambiguous, activationFailed
        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "The selected recording window is unavailable. Open the demo page again before recording."
            case .ambiguous:
                return "The recording window cannot be identified uniquely. Bring the intended browser window to the front and prepare the demo page again."
            case .activationFailed:
                return "The selected recording window could not come to the front. Bring that exact window forward and retry; no automated input was sent."
            }
        }
    }

    struct Driver {
        var handoff: (CaptureTargetInfo) throws -> Void
        var isFrontmost: (CaptureTargetInfo) -> Bool
        var wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) }
        var fallback: (CaptureTargetInfo) async throws -> Void = { _ in throw FocusError.activationFailed }
        var diagnostic: (String, CaptureTargetInfo) -> Void = { _, _ in }
    }

    private struct CachedWindow {
        var ownerPID: pid_t
        var element: AXUIElement
    }
    private struct WindowState: Equatable {
        var ownerPID: pid_t
        var frame: CaptureRect
    }
    private struct ResolvedWindow {
        var owner: NSRunningApplication
        var element: AXUIElement
    }
    private static var preparedWindows: [UInt32: CachedWindow] = [:]

    static func prepare(_ target: CaptureTargetInfo) {
        guard let app = NSApp, app.activationPolicy() == .regular else { return }
        if target.kind == .window {
            // Manual recordings retain best-effort focus; automated recordings
            // additionally use the throwing, verified handoff below.
            do { try beginHandoff(target) }
            catch {
                // Preserve the manual recorder's best-effort app handoff when
                // Accessibility is unavailable. Automation verifies separately.
                guard let state = state(of: target.nativeID), state.ownerPID != ProcessInfo.processInfo.processIdentifier,
                      let owner = NSRunningApplication(processIdentifier: state.ownerPID) else { return }
                app.yieldActivation(to: owner)
                app.hide(nil)
                owner.activate(options: [])
            }
        } else {
            app.hide(nil)
        }
    }

    static func prepareForAutomation(_ target: CaptureTargetInfo,
                                     waitUntilReady: (@MainActor () async throws -> Void)? = nil,
                                     driver: Driver? = nil) async throws {
        guard target.kind == .window else { throw FocusError.unavailable }
        let driver = driver ?? Driver(handoff: beginHandoff, isFrontmost: isExactWindowFrontmost,
                                      fallback: workspaceHandoff, diagnostic: diagnostic)
        try Task.checkCancellation()
        try await waitUntilReady?()
        var standardHandoffRequested = true
        do { try driver.handoff(target) }
        catch FocusError.activationFailed {
            standardHandoffRequested = false
            driver.diagnostic("standard_handoff_rejected", target)
        }
        if standardHandoffRequested {
            for _ in 0..<20 {
                try Task.checkCancellation()
                try await waitUntilReady?()
                if driver.isFrontmost(target) { return }
                try await driver.wait()
            }
        }
        driver.diagnostic("standard_handoff_timeout", target)
        try Task.checkCancellation()
        try await waitUntilReady?()
        try await driver.fallback(target)
        for _ in 0..<40 {
            try Task.checkCancellation()
            try await waitUntilReady?()
            if driver.isFrontmost(target) { driver.diagnostic("workspace_handoff_confirmed", target); return }
            try await driver.wait()
        }
        driver.diagnostic("workspace_handoff_timeout", target)
        throw FocusError.activationFailed
    }

    /// Bind an AX reference to a Window Server ID only while that exact window
    /// is frontmost. Equal titles and equal rectangles cannot create a binding.
    static func rememberFrontmostWindow(_ target: CaptureTargetInfo) throws {
        guard target.kind == .window, AXIsProcessTrusted(),
              let before = state(of: target.nativeID),
              sameBounds(before.frame, target.frame), isExactWindowFrontmost(target) else { throw FocusError.unavailable }
        let application = AXUIElementCreateApplication(before.ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let window = element(kAXFocusedWindowAttribute, of: application),
              let frame = bounds(of: window), sameBounds(frame, before.frame),
              state(of: target.nativeID) == before, isExactWindowFrontmost(target) else { throw FocusError.ambiguous }
        // Only the most recent prepared window needs retention. Replacing it
        // also prevents stale accessibility references accumulating forever.
        preparedWindows = [target.nativeID: CachedWindow(ownerPID: before.ownerPID, element: window)]
    }

    /// AX hit-testing alone cannot distinguish two same-process windows by
    /// rectangle. Compare the actual AX object bound while this exact CG window
    /// was foreground, and recheck its live geometry and owner before input.
    static func hitMatchesPreparedWindow(_ window: AXUIElement, target: CaptureTargetInfo,
                                         ownerPID: pid_t, currentFrame: CaptureRect) -> Bool {
        var liveTarget = target
        liveTarget.frame = currentFrame
        guard isExactWindowFrontmost(liveTarget) else { return false }
        if preparedWindows[target.nativeID] == nil {
            do { try rememberFrontmostWindow(liveTarget) } catch { return false }
        }
        guard let cached = preparedWindows[target.nativeID], cached.ownerPID == ownerPID,
              CFEqual(cached.element, window), let hitFrame = bounds(of: window),
              sameBounds(hitFrame, currentFrame),
              let current = state(of: target.nativeID), current.ownerPID == ownerPID,
              sameBounds(current.frame, currentFrame) else { return false }
        return true
    }

    private static func beginHandoff(_ target: CaptureTargetInfo) throws {
        guard target.kind == .window, let state = state(of: target.nativeID),
              let owner = NSRunningApplication(processIdentifier: state.ownerPID) else { throw FocusError.unavailable }
        // Recording Focus Studio itself must leave its window visible.
        if state.ownerPID == ProcessInfo.processInfo.processIdentifier { return }
        guard AXIsProcessTrusted() else { throw FocusError.unavailable }
        if isExactWindowFrontmost(target) {
            var liveTarget = target
            liveTarget.frame = state.frame
            try rememberFrontmostWindow(liveTarget)
            // orderFrontRegardless can leave our non-active editor above the
            // active browser. Owning the menu bar does not mean the browser is
            // unobscured: hide ordinary recorder windows on this branch too.
            if let app = NSApp, app.activationPolicy() == .regular { app.hide(nil) }
            guard let selected = preparedWindows[target.nativeID] else { throw FocusError.unavailable }
            let raised = AXUIElementPerformAction(selected.element, kAXRaiseAction as CFString)
            diagnostic("already_front_hide_and_raise=\(raised.rawValue)", target)
            guard raised == .success else { throw FocusError.activationFailed }
            return
        }
        let selected = try resolveWindow(target, state: state)
        // Modern AppKit activation is cooperative. Yield while Focus Studio
        // is still active, before hiding its ordinary windows.
        diagnostic("standard_handoff_begin", target)
        if let app = NSApp {
            app.yieldActivation(to: owner)
            if app.activationPolicy() == .regular { app.hide(nil) }
        }
        let firstRaise = AXUIElementPerformAction(selected.element, kAXRaiseAction as CFString)
        guard firstRaise == .success else { diagnostic("first_raise=\(firstRaise.rawValue)", target); throw FocusError.activationFailed }
        let activated = owner.activate(from: .current, options: [])
        // App activation may select its previous main window; repeat the exact
        // AX raise, then verify the CG ID asynchronously before any input.
        let secondRaise = AXUIElementPerformAction(selected.element, kAXRaiseAction as CFString)
        diagnostic("first_raise=\(firstRaise.rawValue),activate_allowed=\(activated),second_raise=\(secondRaise.rawValue)", target)
        guard secondRaise == .success else { throw FocusError.activationFailed }
    }

    private static func resolveWindow(_ target: CaptureTargetInfo, state: WindowState) throws -> ResolvedWindow {
        guard let owner = NSRunningApplication(processIdentifier: state.ownerPID), AXIsProcessTrusted() else { throw FocusError.unavailable }
        let application = AXUIElementCreateApplication(state.ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let windows = attribute(kAXWindowsAttribute, of: application) as? [AXUIElement] else { throw FocusError.unavailable }
        let selected: AXUIElement
        if let cached = preparedWindows[target.nativeID], cached.ownerPID == state.ownerPID,
           windows.contains(where: { CFEqual($0, cached.element) }),
           let rect = bounds(of: cached.element), sameBounds(rect, state.frame) {
            selected = cached.element
        } else {
            preparedWindows.removeValue(forKey: target.nativeID)
            let candidates = windows.compactMap { window -> (AXUIElement, CaptureRect, String)? in
                guard let rect = bounds(of: window) else { return nil }
                return (window, rect, attribute(kAXTitleAttribute, of: window) as? String ?? "")
            }
            var liveTarget = target
            liveTarget.frame = state.frame
            guard let index = matchingWindow(target: liveTarget, candidates: candidates.map { ($0.1, $0.2) }) else { throw FocusError.ambiguous }
            selected = candidates[index].0
        }
        return ResolvedWindow(owner: owner, element: selected)
    }

    /// LaunchServices can activate an already-running browser even when the
    /// initiating automation click did not make Focus Studio the active app.
    /// Reuse its process, open no URL, and retain the exact AX window reference.
    private static func workspaceHandoff(_ target: CaptureTargetInfo) async throws {
        guard let before = state(of: target.nativeID) else { throw FocusError.unavailable }
        let selected = try resolveWindow(target, state: before)
        guard let applicationURL = selected.owner.bundleURL else { throw FocusError.unavailable }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        diagnostic("workspace_handoff_begin", target)
        let activated: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if let app { continuation.resume(returning: app) }
                else { continuation.resume(throwing: FocusError.activationFailed) }
            }
        }
        try Task.checkCancellation()
        guard activated.processIdentifier == before.ownerPID, state(of: target.nativeID)?.ownerPID == before.ownerPID,
              let current = state(of: target.nativeID), let frame = bounds(of: selected.element), sameBounds(frame, current.frame) else {
            diagnostic("workspace_handoff_identity_changed", target)
            throw FocusError.unavailable
        }
        let raised = AXUIElementPerformAction(selected.element, kAXRaiseAction as CFString)
        diagnostic("workspace_raise=\(raised.rawValue),returned_pid=\(activated.processIdentifier)", target)
        guard raised == .success else { throw FocusError.activationFailed }
    }

    private static func state(of id: UInt32) -> WindowState? {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]],
              let entry = entries.first(where: { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value == id }),
              let pid = (entry[kCGWindowOwnerPID] as? NSNumber)?.int32Value,
              let values = entry[kCGWindowBounds] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: values as CFDictionary), frame.width > 0, frame.height > 0 else { return nil }
        return WindowState(ownerPID: pid, frame: CaptureRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
    }

    private static func isExactWindowFrontmost(_ target: CaptureTargetInfo) -> Bool {
        guard let state = state(of: target.nativeID),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == state.ownerPID,
              let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]],
              let first = entries.first(where: { isMainWindow($0, ownerPID: state.ownerPID, targetFrame: state.frame) }) else { return false }
        return (first[kCGWindowNumber] as? NSNumber)?.uint32Value == target.nativeID
    }

    static func isMainWindow(_ entry: [CFString: Any], ownerPID: pid_t, targetFrame: CaptureRect) -> Bool {
        guard (entry[kCGWindowOwnerPID] as? NSNumber)?.int32Value == ownerPID,
              (entry[kCGWindowLayer] as? NSNumber)?.intValue == 0,
              ((entry[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1) > 0,
              let values = entry[kCGWindowBounds] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: values as CFDictionary) else { return false }
        // Match browser preparation's main-window threshold. Tiny helper
        // windows do not identify the active document. Pointer dispatch still
        // checks every covering window at the intended interaction point.
        return rect.width >= min(320, targetFrame.width) && rect.height >= min(200, targetFrame.height)
    }

    private static func diagnostic(_ phase: String, _ target: CaptureTargetInfo) {
        let targetState = state(of: target.nativeID)
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let front = entries.first { ($0[kCGWindowOwnerPID] as? NSNumber)?.int32Value == frontPID && ($0[kCGWindowLayer] as? NSNumber)?.intValue == 0 }
        let frontID = (front?[kCGWindowNumber] as? NSNumber)?.uint32Value ?? 0
        let frontFrame = (front?[kCGWindowBounds] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        let frame = frontFrame.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? "missing"
        let line = "\(Date().ISO8601Format()) \(phase) target_id=\(target.nativeID) target_pid=\(targetState?.ownerPID ?? -1) studio_active=\(NSApp?.isActive ?? false) studio_hidden=\(NSApp?.isHidden ?? false) front_pid=\(frontPID) front_cg_id=\(frontID) front_bounds=\(frame)\n"
        // Bounded, app-owned diagnostics contain no titles, URLs or field text.
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let folder = support.appendingPathComponent("FocusStudio/diagnostics", isDirectory: true)
        let path = folder.appendingPathComponent("window-focus.log")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous = (try? Data(contentsOf: path)) ?? Data()
        var data = previous.count <= 64_000 ? previous : Data()
        data.append(contentsOf: line.utf8)
        try? data.write(to: path, options: .atomic)
    }

    private static func sameBounds(_ a: CaptureRect, _ b: CaptureRect) -> Bool {
        abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// Public Accessibility has no portable window-number property. Match the
    /// selected Window Server rectangle; a title breaks ties, never a guess.
    static func matchingWindow(target: CaptureTargetInfo, candidates: [(CaptureRect, String)]) -> Int? {
        let matches = candidates.indices.filter {
            let rect = candidates[$0].0
            return abs(rect.x - target.frame.x) < 2 && abs(rect.y - target.frame.y) < 2
                && abs(rect.width - target.frame.width) < 2 && abs(rect.height - target.frame.height) < 2
        }
        if matches.count == 1 { return matches[0] }
        let titled = matches.filter { candidates[$0].1 == target.title }
        return titled.count == 1 ? titled[0] : nil
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ name: String, of parent: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: parent), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func bounds(of window: AXUIElement) -> CaptureRect? {
        guard let position = attribute(kAXPositionAttribute, of: window),
              let size = attribute(kAXSizeAttribute, of: window),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CaptureRect(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
    }
}
