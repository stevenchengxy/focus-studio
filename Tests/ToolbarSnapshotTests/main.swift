import AppKit
import CoreGraphics
import FocusStudioCore
import Foundation
import ImageIO
import SwiftUI

/// Renders the real toolbar view in this test process only. It never asks for
/// screens, creates live capture controls, opens user media, or starts recording.
@main
struct ToolbarSnapshotTests {
    @MainActor
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
            ?? ".artifacts/qa-1.6.0-b11", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusStudio-ToolbarSnapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        // Volatile overrides affect this process only. Do not call the shared
        // localization language setter, which persists user preferences.
        let previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(previousArguments.merging([
            "focusStudio.language": "en",
            "AppleLanguages": ["en"],
        ]) { _, new in new }, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)

        let model = StudioModel(store: ProjectStore(projectsDirectory: fixtureRoot),
                                interactionTrackingAccess: { true }, inputMonitoringAccess: { true })
        let target = CaptureTargetInfo(id: "toolbar-fixture-area", kind: .area, nativeID: 424242,
            title: "Demo workspace · Selected region",
            frame: CaptureRect(x: 10, y: 10, width: 1280, height: 720))
        try model.captureEngine.registerAreaTarget(target)
        model.destination = .recorder
        model.selectToolbarTarget(target)
        precondition(!model.captureEngine.isRecording && model.selectedTarget?.id == target.id)
        precondition(model.recordingSourceKind == .area && model.selectedAreaTarget == nil,
                     "The idle console fixture must reach area mode through selectedTarget, not selectedAreaTarget")

        var reports: [[String: Any]] = []
        for width in [760, 640] {
            let view = FloatingRecordingControls(model: model)
                .preferredColorScheme(.dark)
                .frame(width: CGFloat(width), height: 116)
            // ImageRenderer substitutes yellow placeholders for native Menu
            // controls. A never-ordered AppKit host renders those real controls
            // without showing a window or reading the user's screen.
            let image = try renderOffscreen(view, width: width, height: 116)
            precondition(image.width == width && image.height == 116, "Toolbar image must use its real logical layout dimensions")
            let variedPixels = countDistinctColors(image)
            precondition(variedPixels > 100, "The snapshot must contain rendered controls, not an empty or flat background")
            let name = width == 760 ? "toolbar-ready.png" : "toolbar-ready-640.png"
            let url = output.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw SnapshotError.renderFailed
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw SnapshotError.renderFailed }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            precondition(size > 1_000, "Snapshot PNG must not be empty")
            reports.append(["path": url.path, "width": image.width, "height": image.height,
                            "distinctColors": variedPixels, "bytes": size])
        }
        // Window mode, so the idle row's other branch (source chip, no area
        // controls) is covered too. Restored immediately afterwards.
        do {
            let restoreKind = model.recordingSourceKind
            model.recordingSourceKind = .window
            defer { model.recordingSourceKind = restoreKind }
            let view = FloatingRecordingControls(model: model)
                .preferredColorScheme(.dark)
                .frame(width: 760, height: 116)
            let image = try renderOffscreen(view, width: 760, height: 116)
            precondition(image.width == 760 && image.height == 116,
                         "Window-mode toolbar must use its real logical layout dimensions")
            let variedPixels = countDistinctColors(image)
            precondition(variedPixels > 100,
                         "The window-mode snapshot must contain rendered controls")
            let url = output.appendingPathComponent("toolbar-ready-window.png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw SnapshotError.renderFailed
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw SnapshotError.renderFailed }
            reports.append(["path": url.path, "width": image.width, "height": image.height,
                            "distinctColors": variedPixels,
                            "bytes": try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0])
        }

        // The recording bar, rendered through the same view with its layout
        // forced. No capture is started; only geometry and controls are checked.
        for (width, height) in [(324, 46)] {
            let view = FloatingRecordingControls(model: model, layoutOverride: .compact)
                .preferredColorScheme(.dark)
                .frame(width: CGFloat(width), height: CGFloat(height))
            let image = try renderOffscreen(view, width: width, height: height)
            precondition(image.width == width && image.height == height,
                         "Compact bar must use its real logical layout dimensions")
            let variedPixels = countDistinctColors(image)
            precondition(variedPixels > 30,
                         "The compact snapshot must contain rendered controls, not a flat background")
            let url = output.appendingPathComponent("toolbar-recording-compact.png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw SnapshotError.renderFailed
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw SnapshotError.renderFailed }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            precondition(size > 500, "Compact snapshot PNG must not be empty")
            reports.append(["path": url.path, "width": image.width, "height": image.height,
                            "distinctColors": variedPixels, "bytes": size])
        }
        // An AI tool's recording: its countdown names the tool and the sound,
        // and its recording bar shows the recorded time left beside the clock.
        // The capture is scripted through the model's seams; nothing records.
        do {
            let live = StudioModel(
                store: ProjectStore(projectsDirectory: fixtureRoot.appendingPathComponent("LiveFixture", isDirectory: true)),
                interactionTrackingAccess: { true }, inputMonitoringAccess: { true },
                startCapture: { _, _, _, _ in ProcessInfo.processInfo.systemUptime },
                recordingClock: RecordingClock(now: { ProcessInfo.processInfo.systemUptime }, sleep: { _ in await Task.yield() })
            )
            live.automationRequester = { "Claude Code" }
            let display = CaptureTargetInfo(id: "toolbar-fixture-display", kind: .display, nativeID: 424243,
                title: "Built-in Retina Display", frame: CaptureRect(x: 0, y: 0, width: 1440, height: 900))
            var settings = live.recorderSettings
            settings.microphone = true
            settings.systemAudio = true
            precondition(live.beginRecordingCountdown(target: display, settings: settings, duration: 60) != nil,
                         "The scripted countdown must start")
            precondition(live.currentRecording?.requester == "Claude Code" && live.destination == .countdown)
            precondition(RecordingPanelLayout.compact(for: live.currentRecording) == .compactDetailed
                         && RecordingPanelLayout.compact(for: nil) == .compact && RecordingPanelLayout.compactDetailed.preferredSize == NSSize(width: 392, height: 46),
                         "A recording with a duration or sound gets the wider bar, chosen at its countdown")
            var shots: [(name: String, layout: RecordingPanelLayout, width: Int, height: Int)] = [
                ("toolbar-countdown-ai-compact.png", .compactDetailed, 392, 46),
                ("toolbar-countdown-ai-expanded.png", .expanded, 760, 116),
            ]
            for shot in shots {
                reports.append(try snapshot(FloatingRecordingControls(model: live, layoutOverride: shot.layout),
                                            width: shot.width, height: shot.height, minimumColors: 30, to: output.appendingPathComponent(shot.name)))
            }
            let deadline = Date().addingTimeInterval(10)
            while live.destination != .recording {
                precondition(Date() < deadline, "The scripted recording did not start")
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(live.currentRecording?.isLive == true && live.currentRecording?.duration == 60)
            shots = [
                ("toolbar-recording-ai-compact.png", .compactDetailed, 392, 46),
                ("toolbar-recording-ai-expanded.png", .expanded, 760, 116),
            ]
            for shot in shots {
                reports.append(try snapshot(FloatingRecordingControls(model: live, layoutOverride: shot.layout),
                                            width: shot.width, height: shot.height, minimumColors: 30, to: output.appendingPathComponent(shot.name)))
            }
            await live.cancelRecording()
        }
        // The cursor inspector, so the style gallery is checked the same way the
        // toolbar is: rendered from the real view, never from a description of it.
        var inspectorProject = RecordingProject(
            title: "Cursor gallery fixture",
            sourceVideoPath: fixtureRoot.appendingPathComponent("fixture.mp4").path,
            duration: 6,
            sourceWidth: 1440,
            sourceHeight: 900,
            clickEvents: [ClickEvent(time: 1, x: 0.5, y: 0.5, button: .left)]
        )
        inspectorProject.settings.cursorAppearance = .accent
        for (name, width, height) in [("inspector-cursor.png", 330, 720)] {
            let binding = Binding<RecordingProject>(
                get: { inspectorProject },
                set: { inspectorProject = $0 }
            )
            let view = EditorInspectorView(
                project: binding,
                selectedZoomID: .constant(nil),
                selectedChapterID: .constant(nil),
                tool: .cursor
            )
            .environmentObject(model)
            .preferredColorScheme(.dark)
            .frame(width: CGFloat(width), height: CGFloat(height))
            let image = try renderOffscreen(view, width: width, height: height)
            let variedPixels = countDistinctColors(image)
            precondition(variedPixels > 80,
                         "The cursor inspector snapshot must contain the rendered style gallery")
            let url = output.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw SnapshotError.renderFailed
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw SnapshotError.renderFailed }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            precondition(size > 1_000, "Cursor inspector PNG must not be empty")
            reports.append(["path": url.path, "width": image.width, "height": image.height,
                            "distinctColors": variedPixels, "bytes": size])
        }
        // The design inspector in image-background mode, which is where the
        // bundled background set and the macOS wallpapers are offered.
        do {
            var designProject = inspectorProject
            designProject.settings.backgroundStyle = .image
            let binding = Binding<RecordingProject>(
                get: { designProject },
                set: { designProject = $0 }
            )
            let view = EditorInspectorView(
                project: binding,
                selectedZoomID: .constant(nil),
                selectedChapterID: .constant(nil),
                tool: .design
            )
            .environmentObject(model)
            .preferredColorScheme(.dark)
            .frame(width: 330, height: 900)
            let image = try renderOffscreen(view, width: 330, height: 900)
            let variedPixels = countDistinctColors(image)
            precondition(variedPixels > 80, "The design inspector snapshot must contain rendered controls")
            let url = output.appendingPathComponent("inspector-background.png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw SnapshotError.renderFailed
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw SnapshotError.renderFailed }
            reports.append(["path": url.path, "width": image.width, "height": image.height,
                            "distinctColors": variedPixels,
                            "bytes": try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0])
        }

        // The area overlay's own controls, which are AppKit rather than SwiftUI.
        do {
            let bounds = NSRect(x: 0, y: 0, width: 900, height: 560)
            let overlay = AreaSelectionView(frame: bounds)
            overlay.previewSelection(CGRect(x: 180, y: 150, width: 540, height: 280))
            let host = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.appearance = NSAppearance(named: .darkAqua)
            host.contentView = overlay
            defer { host.close() }
            overlay.layoutSubtreeIfNeeded()
            overlay.displayIfNeeded()
            precondition(!host.isVisible, "Overlay fixture window must never be shown")
            guard let rep = overlay.bitmapImageRepForCachingDisplay(in: bounds) else {
                throw SnapshotError.renderFailed
            }
            overlay.cacheDisplay(in: bounds, to: rep)
            guard let image = rep.cgImage else { throw SnapshotError.renderFailed }
            let variedPixels = countDistinctColors(image)
            precondition(variedPixels > 20, "The area overlay snapshot must contain its controls")
            let url = output.appendingPathComponent("area-overlay.png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw SnapshotError.renderFailed
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw SnapshotError.renderFailed }
            reports.append(["path": url.path, "width": image.width, "height": image.height,
                            "distinctColors": variedPixels,
                            "bytes": try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0])
        }
        let report: [String: Any] = ["status": "PASS", "fixtureOnly": true,
                                    "renderedViews": ["FloatingRecordingControls", "EditorInspectorView", "AreaSelectionView"], "screenshots": reports]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("toolbar-snapshots.json"), options: .atomic)
        precondition(!model.captureEngine.isRecording && model.destination == .recorder)
        print("ToolbarSnapshotTests: PASS (real SwiftUI ready toolbar at 760×116 and 640×116, the 324×46 recording bar, window mode, an AI tool's countdown and recording (named tool, sound, recorded time left) compact and expanded, the cursor and background inspectors and the area overlay; isolated fixture, no live app, panels or screen capture)")
    }

    enum SnapshotError: Error { case renderFailed }

    /// Renders `view` at its real size, checks it is not flat and writes the PNG.
    @MainActor
    private static func snapshot<V: View>(_ view: V, width: Int, height: Int, minimumColors: Int, to url: URL) throws -> [String: Any] {
        let image = try renderOffscreen(view.preferredColorScheme(.dark).frame(width: CGFloat(width), height: CGFloat(height)), width: width, height: height)
        precondition(image.width == width && image.height == height, "\(url.lastPathComponent) must use its real logical layout dimensions")
        let variedPixels = countDistinctColors(image)
        precondition(variedPixels > minimumColors, "\(url.lastPathComponent) must contain rendered controls, not a flat background")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw SnapshotError.renderFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SnapshotError.renderFailed }
        return ["path": url.path, "width": image.width, "height": image.height, "distinctColors": variedPixels,
                "bytes": try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0]
    }

    @MainActor
    private static func renderOffscreen<V: View>(_ view: V, width: Int, height: Int) throws -> CGImage {
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let host = NSHostingView(rootView: view)
        host.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        precondition(!window.isVisible, "Snapshot fixture window must never be shown")
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32) else {
            throw SnapshotError.renderFailed
        }
        host.cacheDisplay(in: bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw SnapshotError.renderFailed }
        return image
    }

    private static func countDistinctColors(_ image: CGImage) -> Int {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var colors = Set<UInt32>()
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] > 0 {
            colors.insert(UInt32(pixels[offset]) << 16 | UInt32(pixels[offset + 1]) << 8 | UInt32(pixels[offset + 2]))
        }
        return colors.count
    }
}
