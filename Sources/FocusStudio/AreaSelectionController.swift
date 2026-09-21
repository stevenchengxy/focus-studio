import AppKit
import FocusStudioCapture
import FocusStudioCore

enum AreaSelectionError: LocalizedError {
    case selectionAlreadyActive
    case displayUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .selectionAlreadyActive:
            return L10n.tr("Another area selection is already in progress.")
        case let .displayUnavailable(name):
            return L10n.format("The display “%@” is no longer available.", name)
        }
    }
}

/// Full-display overlay used by the recording picker to create an `.area`
/// capture target. The controller intentionally returns a target rather than a
/// presentation-only rectangle so callers cannot accidentally skip the AppKit
/// to Quartz coordinate conversion.
@MainActor
final class AreaSelectionController {
    static let shared = AreaSelectionController()

    private var overlayWindow: NSWindow?
    private var continuation: CheckedContinuation<CaptureTargetInfo?, Error>?
    private var displayTarget: CaptureTargetInfo?

    private init() {}

    func selectArea(
        on display: CaptureTargetInfo,
        using captureEngine: CaptureEngine
    ) async throws -> CaptureTargetInfo? {
        guard continuation == nil else { throw AreaSelectionError.selectionAlreadyActive }
        guard display.kind == .display else {
            throw CaptureEngineError.invalidTarget("Area selection requires a display target.")
        }
        guard let screen = Self.screen(for: display.nativeID) else {
            throw AreaSelectionError.displayUnavailable(display.title)
        }

        displayTarget = display
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let view = AreaSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onCancel = { [weak self] in self?.finish(with: nil) }
            view.onConfirm = { [weak self] localRect in
                self?.finish(localSelection: localRect, using: captureEngine)
            }

            let window = AreaSelectionWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.title = L10n.tr("Select Recording Area")
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.contentView = view
            self.overlayWindow = window
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
    }

    private func finish(localSelection: CGRect, using captureEngine: CaptureEngine) {
        guard let displayTarget else {
            finish(throwing: AreaSelectionError.displayUnavailable(L10n.tr("Selected display")))
            return
        }
        let local = CaptureRect(
            x: localSelection.minX,
            y: localSelection.minY,
            width: localSelection.width,
            height: localSelection.height
        )
        guard let global = AreaCaptureGeometry.globalFrame(
            forLocalSelection: local,
            onDisplay: displayTarget.frame
        ) else {
            return
        }
        do {
            let dimensions = "\(Int(global.width.rounded())) × \(Int(global.height.rounded()))"
            let target = try captureEngine.makeAreaTarget(
                on: displayTarget,
                frame: global,
                title: L10n.format("Selected Area (%@)", dimensions)
            )
            try captureEngine.registerAreaTarget(target)
            finish(with: target)
        } catch {
            finish(throwing: error)
        }
    }

    private func finish(with target: CaptureTargetInfo?) {
        let current = continuation
        cleanup()
        current?.resume(returning: target)
    }

    private func finish(throwing error: Error) {
        let current = continuation
        cleanup()
        current?.resume(throwing: error)
    }

    private func cleanup() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        continuation = nil
        displayTarget = nil
    }

    private static func screen(for displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }
    }
}

/// Borderless windows do not become key by default. The area overlay must be
/// key so Escape/Return are delivered to `AreaSelectionView` instead of the
/// recording picker behind it. It deliberately remains a non-main utility
/// window so closing it restores the editor/recorder window naturally.
private final class AreaSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class AreaSelectionView: NSView {
    var onCancel: (() -> Void)?
    var onConfirm: ((CGRect) -> Void)?

    private var dragStart: CGPoint?
    private var selection: CGRect?
    private let minimumDimension: CGFloat = 48

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("focusstudio.area-selector")
        setAccessibilityLabel(L10n.tr("Recording area selector"))
        setAccessibilityHelp(
            L10n.tr("Drag to select an area. Press Return to use it or Escape to cancel.")
        )
        updateAccessibilityValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.58).setFill()
        bounds.fill()

        if let selection {
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSGraphicsContext.current?.restoreGraphicsState()

            let outline = NSBezierPath(roundedRect: selection, xRadius: 7, yRadius: 7)
            outline.lineWidth = 2
            NSColor.systemBlue.setStroke()
            outline.stroke()

            let label = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.72),
            ]
            let labelSize = label.size(withAttributes: attributes)
            let labelOrigin = CGPoint(
                x: selection.midX - labelSize.width / 2,
                y: max(10, selection.minY - labelSize.height - 14)
            )
            label.draw(at: labelOrigin, withAttributes: attributes)
        }

        let instruction = L10n.tr(selection == nil
            ? "Drag to select the clean recording area  •  Esc to cancel"
            : "Drag again to adjust  •  Return or double-click to use this area  •  Esc to cancel")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = instruction.size(withAttributes: attributes)
        instruction.draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 54),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2, let selection, selection.contains(point) {
            dragStart = nil
            onConfirm?(selection)
            return
        }

        // Keep the current rectangle until an actual drag begins. Clearing it
        // here makes the first click of a double-click destroy the selection,
        // so the advertised double-click confirmation can never succeed.
        dragStart = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        selection = CGRect(
            x: min(dragStart.x, current.x),
            y: min(dragStart.y, current.y),
            width: abs(current.x - dragStart.x),
            height: abs(current.y - dragStart.y)
        ).intersection(bounds)
        updateAccessibilityValue()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard let selection else { return }
        if selection.width < minimumDimension || selection.height < minimumDimension {
            self.selection = nil
            updateAccessibilityValue()
            needsDisplay = true
        } else if event.clickCount >= 2 {
            onConfirm?(selection)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            onCancel?()
        case 36, 76: // Return / keypad Enter
            if let selection { onConfirm?(selection) }
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformCancel() -> Bool {
        onCancel?()
        return true
    }

    override func accessibilityPerformConfirm() -> Bool {
        guard let selection else { return false }
        onConfirm?(selection)
        return true
    }

    private func updateAccessibilityValue() {
        guard let selection else {
            setAccessibilityValue(L10n.tr("No area selected"))
            return
        }
        setAccessibilityValue(
            L10n.format("Selected area, %lld by %lld", Int(selection.width.rounded()), Int(selection.height.rounded()))
        )
    }
}
