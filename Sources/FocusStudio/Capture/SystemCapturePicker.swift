import AppKit
import FocusStudioCore
import ScreenCaptureKit

public enum SystemCaptureStopPolicy {
    public static func isUserStop(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userStopped.rawValue
    }
}

/// The exact filter approved in the system picker. Never reconstruct it by
/// enumerating the desktop: picker approval need not grant that wider access.
@MainActor
public final class SystemCaptureSelection {
    let filter: SCContentFilter
    public let target: CaptureTargetInfo
    let processID: Int32?

    @available(macOS 15.2, *)
    init(filter: SCContentFilter) throws {
        self.filter = filter
        let frame: CGRect
        let kind: CaptureTargetKind
        let nativeID: UInt32
        let title: String
        let appName: String?
        switch filter.style {
        case .window:
            guard filter.includedWindows.count == 1, let window = filter.includedWindows.first else {
                throw CaptureEngineError.invalidTarget("Select one window or one display to record.")
            }
            frame = window.frame
            kind = .window
            nativeID = window.windowID
            appName = window.owningApplication?.applicationName
            title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? appName ?? "Window"
            processID = window.owningApplication?.processID
        case .display:
            guard filter.includedDisplays.count == 1, let display = filter.includedDisplays.first else {
                throw CaptureEngineError.invalidTarget("Select one window or one display to record.")
            }
            frame = display.frame
            kind = .display
            nativeID = display.displayID
            appName = nil
            title = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == nativeID
            }?.localizedName ?? "Display"
            processID = nil
        default:
            throw CaptureEngineError.invalidTarget("Select one window or one display to record.")
        }
        guard frame.width > 1, frame.height > 1, filter.pointPixelScale > 0 else {
            throw CaptureEngineError.invalidTarget("The selected source is unavailable. Choose it again.")
        }
        target = CaptureTargetInfo(
            id: "\(kind.rawValue)-\(nativeID)", kind: kind, nativeID: nativeID,
            title: title, appName: appName,
            frame: CaptureRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
            scaleFactor: Double(filter.pointPixelScale)
        )
    }

    /// Refresh only this window's bounds; never enumerate other sources. The
    /// user may move it between choosing it, the countdown, and resuming.
    func currentTarget() throws -> CaptureTargetInfo {
        var result = target
        if target.kind == .window {
            guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, target.nativeID) as? [[String: Any]],
                  let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.nativeID }),
                  processID == nil || (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  (row[kCGWindowIsOnscreen as String] as? Bool) == true,
                  frame.width > 1, frame.height > 1 else {
                throw CaptureEngineError.targetUnavailable(target.title)
            }
            result.frame = CaptureRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        } else {
            guard CGDisplayIsActive(target.nativeID) != 0 else {
                throw CaptureEngineError.targetUnavailable(target.title)
            }
            let frame = CGDisplayBounds(target.nativeID)
            result.frame = CaptureRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        }
        return result
    }
}

/// One presentation/recording owns one observer. Retiring this object rejects
/// late callbacks; an existing stream can never change source mid-recording.
@MainActor
public final class SystemCapturePicker: NSObject, SCContentSharingPickerObserver {
    public static var isSupported: Bool {
        if #available(macOS 15.2, *) { return true }
        return false
    }

    private let completion: @MainActor (Result<SystemCaptureSelection?, Error>) -> Void
    private var awaitingSelection = false
    private var registered = false

    public init(completion: @escaping @MainActor (Result<SystemCaptureSelection?, Error>) -> Void) {
        self.completion = completion
        super.init()
    }

    public func present() {
        guard Self.isSupported, !registered else { return }
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
        registered = true
        awaitingSelection = true
        picker.isActive = true
        picker.present()
    }

    public func invalidate() {
        awaitingSelection = false
        guard registered else { return }
        registered = false
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
    }

    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self, self.awaitingSelection, stream == nil else { return }
            self.invalidate()
            self.completion(.success(nil))
        }
    }

    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self, self.awaitingSelection, stream == nil else { return }
            self.awaitingSelection = false
            do {
                guard #available(macOS 15.2, *) else { return }
                self.completion(.success(try SystemCaptureSelection(filter: filter)))
            } catch {
                self.invalidate()
                self.completion(.failure(error))
            }
        }
    }

    nonisolated public func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.awaitingSelection else { return }
            self.invalidate()
            self.completion(.failure(error))
        }
    }
}
