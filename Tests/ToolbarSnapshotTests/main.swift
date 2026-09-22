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
    static func main() throws {
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
        let report: [String: Any] = ["status": "PASS", "fixtureOnly": true,
                                    "renderedView": "FloatingRecordingControls", "screenshots": reports]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("toolbar-snapshots.json"), options: .atomic)
        precondition(!model.captureEngine.isRecording && model.destination == .recorder)
        print("ToolbarSnapshotTests: PASS (real SwiftUI ready toolbar at 760×116 and 640×116; isolated fixture, no live app or screen capture)")
    }

    enum SnapshotError: Error { case renderFailed }

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
