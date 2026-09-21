import AppKit
import CoreImage
import CoreMedia
import FocusStudioCore
import ScreenCaptureKit

/// Live, low-resolution previews of recordable sources for the picker.
///
/// Every visible display/window card is refreshed with a one-shot
/// `SCScreenshotManager` capture about once per second (a 320-px capture costs
/// roughly 40 ms), and the selected card is driven by a small `SCStream` at
/// 12 fps so it moves in real time. Images live only in memory and are
/// released the moment the picker disappears; nothing is written to disk.
@MainActor
public final class SourcePreviewProvider: ObservableObject {
    @Published public private(set) var images: [String: CGImage] = [:]
    @Published public private(set) var liveTargetID: String?

    public var thumbnailWidth: Double = 360
    public var refreshInterval: Duration = .seconds(1)

    private var visibleTargets: [CaptureTargetInfo] = []
    private var refreshTask: Task<Void, Never>?
    private var cachedContent: SCShareableContent?
    private var cachedContentDate = Date.distantPast
    private var liveStream: SCStream?
    private var liveOutput: LivePreviewOutput?
    private var liveGeneration = 0

    public init() {}

    public var isRunning: Bool { refreshTask != nil }

    /// Starts periodic refreshes for `targets` and a live stream for `liveTargetID`.
    public func start(targets: [CaptureTargetInfo], liveTargetID: String?) {
        update(targets: targets)
        setLiveTarget(liveTargetID)
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshVisibleTargets()
                try? await Task.sleep(for: self.refreshInterval)
            }
        }
    }

    /// Replaces the set of cards currently on screen. Images of cards that
    /// disappeared are dropped immediately.
    public func update(targets: [CaptureTargetInfo]) {
        visibleTargets = targets.filter { $0.kind != .area }
        let ids = Set(visibleTargets.map(\.id))
        for key in images.keys where !ids.contains(key) && key != liveTargetID {
            images[key] = nil
        }
    }

    public func setLiveTarget(_ id: String?) {
        guard id != liveTargetID else { return }
        stopLiveStream()
        liveTargetID = id
        guard id != nil else { return }
        liveGeneration += 1
        let generation = liveGeneration
        Task { [weak self] in await self?.startLiveStream(generation: generation) }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        stopLiveStream()
        liveTargetID = nil
        images = [:]
        cachedContent = nil
    }

    // MARK: - Periodic thumbnails

    private func refreshVisibleTargets() async {
        let targets = visibleTargets.filter { $0.id != liveTargetID }
        guard !targets.isEmpty, let content = await shareableContent() else { return }
        for target in targets {
            guard !Task.isCancelled, refreshTask != nil else { return }
            guard let filter = contentFilter(for: target, in: content) else {
                images[target.id] = nil
                continue
            }
            let configuration = thumbnailConfiguration(for: target, width: thumbnailWidth)
            if let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) {
                guard refreshTask != nil else { return }
                images[target.id] = image
            }
        }
    }

    private func shareableContent() async -> SCShareableContent? {
        if let cachedContent, Date().timeIntervalSince(cachedContentDate) < 4 {
            return cachedContent
        }
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedContent = content
        cachedContentDate = Date()
        return content
    }

    private func contentFilter(for target: CaptureTargetInfo, in content: SCShareableContent) -> SCContentFilter? {
        switch target.kind {
        case .display, .area:
            guard let display = content.displays.first(where: { UInt32($0.displayID) == target.nativeID }) else {
                return nil
            }
            // Match the recording engine: Focus Studio's own windows are never
            // part of a display capture, so the preview shows what will be recorded.
            let ownProcessID = ProcessInfo.processInfo.processIdentifier
            let ownApplications = content.applications.filter { $0.processID == ownProcessID }
            return SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        case .window:
            guard let window = content.windows.first(where: { UInt32($0.windowID) == target.nativeID }) else {
                return nil
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    private func thumbnailConfiguration(for target: CaptureTargetInfo, width: Double) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = width / max(1, target.frame.width)
        configuration.width = max(16, Int((target.frame.width * scale).rounded()))
        configuration.height = max(16, Int((target.frame.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.captureResolution = .nominal
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return configuration
    }

    // MARK: - Live stream for the selected card

    private func startLiveStream(generation: Int) async {
        guard generation == liveGeneration, let id = liveTargetID,
              let target = visibleTargets.first(where: { $0.id == id }),
              let content = await shareableContent(),
              generation == liveGeneration,
              let filter = contentFilter(for: target, in: content)
        else { return }
        let configuration = thumbnailConfiguration(for: target, width: thumbnailWidth * 1.5)
        configuration.showsCursor = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 12)
        configuration.queueDepth = 3
        let output = LivePreviewOutput { [weak self] image in
            Task { @MainActor [weak self] in
                guard let self, self.liveTargetID == id, self.liveGeneration == generation else { return }
                self.images[id] = image
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "com.local.focusstudio.source-preview", qos: .userInitiated)
            )
            try await stream.startCapture()
        } catch {
            // The periodic thumbnail keeps serving this card if a stream cannot start.
            return
        }
        guard generation == liveGeneration, liveTargetID == id else {
            try? await stream.stopCapture()
            return
        }
        liveStream = stream
        liveOutput = output
    }

    private func stopLiveStream() {
        liveGeneration += 1
        if let stream = liveStream {
            Task { try? await stream.stopCapture() }
        }
        liveStream = nil
        liveOutput = nil
    }
}

private final class LivePreviewOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let handler: @Sendable (CGImage) -> Void
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(handler: @escaping @Sendable (CGImage) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        handler(cgImage)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {}
}
