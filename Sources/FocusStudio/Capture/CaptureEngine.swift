import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import FocusStudioCore
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

public enum CaptureVideoCodec: String, CaseIterable, Sendable {
    case h264
    case hevc

    fileprivate var avCodecType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}

public struct CaptureOptions: Sendable, Equatable {
    public var frameRate: Int
    /// Pixels per captured point. `nil` uses the target display's backing scale.
    public var outputScale: Double?
    /// Prevents codec failures on very large Retina displays while preserving aspect ratio.
    public var maximumOutputDimension: Int
    public var codec: CaptureVideoCodec
    public var capturesSystemAudio: Bool
    public var capturesMicrophone: Bool
    public var microphoneDeviceID: String?
    public var excludesCurrentProcessAudio: Bool
    public var audioSampleRate: Int
    public var audioChannelCount: Int
    public var queueDepth: Int
    public var ignoresWindowShadow: Bool

    /// UI-friendly aliases retained for call sites that prefer shorter labels.
    public var systemAudio: Bool {
        get { capturesSystemAudio }
        set { capturesSystemAudio = newValue }
    }

    public var microphone: Bool {
        get { capturesMicrophone }
        set { capturesMicrophone = newValue }
    }

    public init(
        frameRate: Int = 60,
        outputScale: Double? = nil,
        maximumOutputDimension: Int = 4_096,
        codec: CaptureVideoCodec = .h264,
        capturesSystemAudio: Bool = false,
        capturesMicrophone: Bool = false,
        microphoneDeviceID: String? = nil,
        excludesCurrentProcessAudio: Bool = true,
        audioSampleRate: Int = 48_000,
        audioChannelCount: Int = 2,
        queueDepth: Int = 6,
        ignoresWindowShadow: Bool = true
    ) {
        self.frameRate = frameRate
        self.outputScale = outputScale
        self.maximumOutputDimension = maximumOutputDimension
        self.codec = codec
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
        self.queueDepth = queueDepth
        self.ignoresWindowShadow = ignoresWindowShadow
    }
}

public enum RecordingState: Equatable, Sendable {
    case idle
    case preparing
    case recording
    case stopping
    case completed(URL)
    case failed(String)
}

/// Pure startup rules kept separate from ScreenCaptureKit so regressions can be
/// exercised without changing the machine's recording permissions.
public enum CaptureStartupPolicy {
    /// A normal on-screen source produces a complete frame almost immediately.
    /// Allow a few seconds for displays waking from sleep or a busy browser, but
    /// never leave the UI pretending to record a suspended stream indefinitely.
    public static let firstCompleteFrameTimeout: Duration = .seconds(5)

    public static func isRecordableWindow(
        isOnScreen: Bool,
        frame: CaptureRect
    ) -> Bool {
        isOnScreen && frame.width >= 32 && frame.height >= 32
    }

    public static func noCompleteFrameMessage(
        targetName: String,
        targetKind: CaptureTargetKind
    ) -> String {
        switch targetKind {
        case .window:
            return "No video frame arrived from \(targetName). Bring that window onto a visible desktop, restore it if it is minimized, then refresh the source list and try again."
        case .display, .area:
            return "No video frame arrived from \(targetName). Make sure the display is awake and connected, then refresh the source list and try again."
        }
    }
}

/// What happened to a take the user chose to throw away.
public enum RecordingDiscardOutcome: Sendable, Equatable {
    /// Finalized and moved to the Trash, where it can still be recovered.
    case trashed
    /// Finalized but the Trash refused it, so the file was left where it is.
    case kept(URL, String)
    /// Finalizing itself failed; the recording was not thrown away.
    case failed(String)
}

public struct RecordingResult: Sendable {
    public var outputURL: URL
    public var duration: TimeInterval
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var cursorSamples: [CursorSample]
    public var clickEvents: [ClickEvent]
    public var typingActivity: [TypingActivity]
    public var eventDiagnostics: EventMonitorDiagnostics
    public var target: CaptureTargetInfo

    public init(
        outputURL: URL,
        duration: TimeInterval,
        sourceWidth: Int,
        sourceHeight: Int,
        cursorSamples: [CursorSample],
        clickEvents: [ClickEvent],
        target: CaptureTargetInfo,
        typingActivity: [TypingActivity] = [],
        eventDiagnostics: EventMonitorDiagnostics = .init()
    ) {
        self.outputURL = outputURL
        self.duration = duration
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.cursorSamples = cursorSamples
        self.clickEvents = clickEvents
        self.typingActivity = typingActivity
        self.eventDiagnostics = eventDiagnostics
        self.target = target
    }
}

public enum CaptureEngineError: LocalizedError, Sendable {
    case recordingAlreadyInProgress
    case noActiveRecording
    case screenRecordingPermissionDenied(String)
    case missingCaptureEntitlements(String)
    case targetUnavailable(String)
    case invalidTarget(String)
    case invalidOptions(String)
    case outputFileAlreadyExists(URL)
    case unsupportedCodec(String)
    case captureDidNotStart(String)
    case screenshotUnavailable
    case screenshotFailed(String)
    case recordingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .recordingAlreadyInProgress:
            return "A recording is already in progress."
        case .noActiveRecording:
            return "There is no active recording to stop."
        case let .screenRecordingPermissionDenied(details):
            return "Screen Recording access is not active for this copy of Focus Studio. \(details)"
        case let .missingCaptureEntitlements(details):
            return "Focus Studio is missing a required capture entitlement. \(details)"
        case let .targetUnavailable(name):
            return "The capture target “\(name)” is no longer available."
        case let .invalidTarget(reason):
            return "The capture target is invalid: \(reason)"
        case let .invalidOptions(reason):
            return "The capture settings are invalid: \(reason)"
        case let .outputFileAlreadyExists(url):
            return "A file already exists at \(url.path). Choose a new recording filename."
        case let .unsupportedCodec(codec):
            return "The \(codec) codec is not available for ScreenCaptureKit recording output."
        case let .captureDidNotStart(reason):
            return "Recording did not start. \(reason)"
        case .screenshotUnavailable:
            return "A screenshot is only available while a recording is active."
        case let .screenshotFailed(reason):
            return "The screenshot could not be saved: \(reason)"
        case let .recordingFailed(reason):
            return "Recording failed: \(reason)"
        }
    }

    /// True only for failures that can be recovered in Privacy & Security.
    /// This deliberately excludes general ScreenCaptureKit failures so callers
    /// do not hide useful diagnostics behind a misleading permission message.
    public var isScreenRecordingPermissionFailure: Bool {
        if case .screenRecordingPermissionDenied = self { return true }
        return false
    }

    /// Maps ScreenCaptureKit/NSError failures without discarding their domain,
    /// numeric code, failure reason, or underlying error. The access value is an
    /// argument so this logic can be tested deterministically without changing
    /// the machine's TCC database.
    public static func classifyCaptureFailure(
        _ error: Error,
        hasScreenRecordingAccess: Bool
    ) -> CaptureEngineError {
        if let captureError = error as? CaptureEngineError {
            return captureError
        }

        let nsError = error as NSError
        let details = diagnosticDescription(for: nsError)
        if nsError.domain == SCStreamErrorDomain {
            switch nsError.code {
            case SCStreamError.Code.userDeclined.rawValue:
                return .screenRecordingPermissionDenied(details)
            case SCStreamError.Code.missingEntitlements.rawValue:
                return .missingCaptureEntitlements(details)
            default:
                break
            }
        }
        if !hasScreenRecordingAccess {
            return .screenRecordingPermissionDenied(details)
        }
        return .recordingFailed(details)
    }

    public static func diagnosticDescription(for error: NSError) -> String {
        var parts = [error.localizedDescription]
        if let reason = error.localizedFailureReason, !reason.isEmpty,
           reason != error.localizedDescription {
            parts.append(reason)
        }
        if let suggestion = error.localizedRecoverySuggestion, !suggestion.isEmpty {
            parts.append(suggestion)
        }
        parts.append("[\(error.domain) \(error.code)]")
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("Underlying: \(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)]")
        }
        return parts.joined(separator: " ")
    }
}

/// Side-effect policy for the macOS Screen Recording permission APIs.
///
/// `CGPreflightScreenCaptureAccess()` is only a hint: immediately after a TCC
/// change it can lag behind what ScreenCaptureKit can actually use. Normal
/// recording flows should therefore try ScreenCaptureKit directly and handle
/// its result. This policy is reserved for UI that is explicitly checking or
/// requesting access, and guarantees that an existing grant never triggers a
/// second system request.
public enum ScreenRecordingAccessIntent: Sendable {
    case inspectOnly
    case explicitUserRequest
}

public enum ScreenRecordingAccessPolicy {
    public static func resolve(
        intent: ScreenRecordingAccessIntent,
        preflight: () -> Bool,
        request: () -> Bool
    ) -> Bool {
        if preflight() {
            return true
        }
        guard intent == .explicitUserRequest else {
            return false
        }
        return request()
    }
}

/// ScreenCaptureKit-backed capture service for macOS 15 and later.
///
/// The video file never contains the system cursor. Cursor motion and clicks are
/// captured separately by `eventMonitor`, allowing the editor to animate, resize,
/// or hide the cursor and to create click-driven zooms non-destructively.
@MainActor
public final class CaptureEngine: ObservableObject {
    public typealias SampleBufferHandler = @Sendable (CMSampleBuffer, SCStreamOutputType) -> Void

    @Published public private(set) var state: RecordingState = .idle
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var lastError: String?
    @Published public private(set) var eventCaptureWarning: String?
    @Published public private(set) var availableTargets: [CaptureTargetInfo] = []
    @Published public private(set) var isPaused = false
    @Published public private(set) var isChangingPauseState = false

    /// The active recording's intervals on the uptime clock: what has been
    /// recorded so far (paused time left out) and when the current interval
    /// started, nil while paused. A recording's duration limit is measured on it.
    public var recordingIntervals: RecordingPauseClock { pauseClock }

    /// Actual video time zero in the `ProcessInfo.systemUptime` clock. This is
    /// derived from the first complete screen sample's presentation timestamp.
    @Published public private(set) var recordingStartUptime: TimeInterval?

    public let eventMonitor: EventMonitor

    /// Invoked on a dedicated serial capture queue. Set before `startRecording`.
    /// Enabled audio sources are delivered with `.audio` and `.microphone` types.
    public var sampleBufferHandler: SampleBufferHandler?

    public var isRecording: Bool {
        switch state {
        case .preparing, .recording, .stopping:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }

    private var activeStream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var delegateBridge: CaptureDelegateBridge?
    private var recordingCompletion: RecordingCompletion?
    private var sampleQueue: DispatchQueue?
    private var durationTask: Task<Void, Never>?
    private var captureStartedUptime: TimeInterval?
    private var activeOutputURL: URL?
    private var activeTarget: CaptureTargetInfo?
    private var activeOutputSize: (width: Int, height: Int)?
    private var activeContentFilter: SCContentFilter?
    private var activeStreamConfiguration: SCStreamConfiguration?
    private var failureCleanupInProgress = false
    private let transitionGate = RecordingTransitionGate()
    private var pauseClock = RecordingPauseClock()
    private var segmentDirectory: URL?
    private var activeSegmentURL: URL?
    private var recordedSegments: [RecordedMediaSegment] = []
    private var activeOptions: CaptureOptions?
    private var activeSegmentGeneration = UUID()

    public init(eventMonitor: EventMonitor) {
        self.eventMonitor = eventMonitor
    }

    public convenience init() {
        self.init(eventMonitor: EventMonitor())
    }

    /// A read-only check of the permission currently active for this process.
    /// macOS can keep returning `false` after the user toggles access until the
    /// app is relaunched, so the UI should offer relaunch as a recovery action.
    public var hasScreenRecordingAccess: Bool {
        ScreenRecordingAccessPolicy.resolve(
            intent: .inspectOnly,
            preflight: { CGPreflightScreenCaptureAccess() },
            request: { false }
        )
    }

    /// Requests Screen Recording access in response to an explicit user action.
    /// On macOS the grant can require relaunching before ScreenCaptureKit sees it.
    @discardableResult
    public func requestScreenRecordingAccess() -> Bool {
        ScreenRecordingAccessPolicy.resolve(
            intent: .explicitUserRequest,
            preflight: { CGPreflightScreenCaptureAccess() },
            request: { CGRequestScreenCaptureAccess() }
        )
    }

    /// A read-only Input Monitoring check used for cursor and click metadata.
    /// Video recording remains fully functional when this permission is absent.
    public var hasInputMonitoringAccess: Bool {
        CGPreflightListenEventAccess()
    }

    /// Requests Input Monitoring after a user-initiated recording action.
    /// The return value reflects whether macOS has activated the grant now;
    /// callers must still treat cursor/click capture as optional enhancement.
    @discardableResult
    public func requestInputMonitoringAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    deinit {
        durationTask?.cancel()
    }

    /// A background refresh for the picker, which runs while the user is looking
    /// at the source list. Unlike ``refreshAvailableTargets(onScreenWindowsOnly:)``
    /// it never empties the list on a transient failure, never surfaces an error,
    /// keeps a registered area target, and only publishes when something actually
    /// changed, so the grid does not re-render every tick.
    @discardableResult
    public func refreshAvailableTargetsQuietly(
        onScreenWindowsOnly: Bool = true
    ) async -> Bool {
        guard !isRecording else { return false }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: onScreenWindowsOnly
        ) else { return false }
        let shareable = makeTargetInfos(from: content)
        // Area targets are made by this app, not enumerated by the system.
        let areas = availableTargets.filter { $0.kind == .area }
        let updated = shareable + areas
        guard updated != availableTargets else { return true }
        availableTargets = updated
        return true
    }

    /// Requests current display/window inventory. Calling this may cause macOS to
    /// show its Screen Recording permission prompt.
    @discardableResult
    public func refreshAvailableTargets(
        onScreenWindowsOnly: Bool = true
    ) async throws -> [CaptureTargetInfo] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: onScreenWindowsOnly
            )
            let targets = makeTargetInfos(from: content)
            availableTargets = targets
            return targets
        } catch {
            availableTargets = []
            let mappedError = CaptureEngineError.classifyCaptureFailure(
                error,
                hasScreenRecordingAccess: hasScreenRecordingAccess
            )
            let message = mappedError.localizedDescription
            lastError = message
            throw mappedError
        }
    }

    /// Records a display, window, or display-backed area to an MPEG-4 file.
    public func startRecording(
        target: CaptureTargetInfo,
        outputURL: URL,
        options: CaptureOptions = .init()
    ) async throws {
        guard !isRecording, activeStream == nil else {
            throw CaptureEngineError.recordingAlreadyInProgress
        }

        var ownsOutputURL = false
        do {
            try validate(options: options)
            try prepareOutputURL(outputURL)
            ownsOutputURL = true

            state = .preparing
            duration = 0
            lastError = nil
            eventCaptureWarning = nil
            recordingStartUptime = nil
            captureStartedUptime = nil
            pauseClock = .init()
            isPaused = false
            recordedSegments = []
            activeOptions = options
            let directory = outputURL.deletingLastPathComponent()
                .appendingPathComponent(".focusstudio-recording-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            segmentDirectory = directory
            let segmentURL = directory.appendingPathComponent("segment-0.mp4")
            activeSegmentURL = segmentURL

            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let resolvedTarget = try resolve(target: target, in: content)
            let outputSize = CaptureOutputGeometry.pixelSize(
                sourcePointSize: resolvedTarget.sourcePointSize,
                targetScaleFactor: resolvedTarget.targetInfo.scaleFactor,
                outputScale: options.outputScale,
                maximumOutputDimension: options.maximumOutputDimension
            )
            let streamConfiguration = makeStreamConfiguration(
                resolvedTarget: resolvedTarget,
                outputSize: outputSize,
                options: options
            )

            let completion = RecordingCompletion()
            let startupGate = CaptureStartupGate()
            let segmentGeneration = UUID()
            activeSegmentGeneration = segmentGeneration
            let queue = DispatchQueue(
                label: "app.focusstudio.capture.samples",
                qos: .userInteractive
            )
            let bridge = CaptureDelegateBridge(
                sampleHandler: sampleBufferHandler,
                completion: completion,
                onFirstCompleteScreenSample: { uptime in
                    Task {
                        await startupGate.complete(with: .ready(uptime))
                    }
                },
                onFatalError: { [weak self] message in
                    Task {
                        await startupGate.complete(with: .failed(message))
                    }
                    Task { @MainActor [weak self] in
                        guard self?.activeSegmentGeneration == segmentGeneration, self?.state == .recording else { return }
                        await self?.handleFatalCaptureError(message)
                    }
                }
            )

            let stream = SCStream(
                filter: resolvedTarget.filter,
                configuration: streamConfiguration,
                delegate: bridge
            )
            try stream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: queue)
            if options.capturesSystemAudio {
                try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: queue)
            }
            if options.capturesMicrophone {
                try stream.addStreamOutput(bridge, type: .microphone, sampleHandlerQueue: queue)
            }

            let outputConfiguration = SCRecordingOutputConfiguration()
            outputConfiguration.outputURL = segmentURL
            outputConfiguration.outputFileType = .mp4
            let requestedCodec = options.codec.avCodecType
            guard outputConfiguration.availableVideoCodecTypes.contains(requestedCodec) else {
                throw CaptureEngineError.unsupportedCodec(options.codec.rawValue.uppercased())
            }
            outputConfiguration.videoCodecType = requestedCodec

            let output = SCRecordingOutput(
                configuration: outputConfiguration,
                delegate: bridge
            )
            try stream.addRecordingOutput(output)

            activeStream = stream
            recordingOutput = output
            delegateBridge = bridge
            recordingCompletion = completion
            sampleQueue = queue
            activeOutputURL = outputURL
            activeTarget = resolvedTarget.targetInfo
            activeOutputSize = (width: outputSize.width, height: outputSize.height)
            activeContentFilter = resolvedTarget.filter
            activeStreamConfiguration = streamConfiguration

            // Install event taps before capture starts but do not assign time zero.
            // Pre-first-frame events are discarded by EventMonitor.
            do {
                try eventMonitor.prepare(
                    captureRect: resolvedTarget.targetInfo.frame,
                    targetProcessID: resolvedTarget.typingProcessID,
                    targetWindowID: resolvedTarget.typingWindowID
                )
                eventCaptureWarning = eventMonitor.lastError
            } catch {
                // Cursor metadata is an enhancement; permission/setup failure must
                // never prevent a valid ScreenCaptureKit movie from being recorded.
                eventCaptureWarning = error.localizedDescription
            }

            try await stream.startCapture()

            // `startCapture()` and SCRecordingOutput's did-start callback only
            // mean the pipeline was scheduled. A hidden/minimized window can
            // remain suspended forever and never deliver an encodable frame.
            // Do not report recording (or start the timer/event timeline) until
            // the first complete screen sample actually arrives.
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: CaptureStartupPolicy.firstCompleteFrameTimeout)
                    await startupGate.complete(with: .timedOut)
                } catch {
                    // Expected when a complete frame or fatal error wins first.
                }
            }
            let startupOutcome = await startupGate.wait()
            timeoutTask.cancel()

            switch startupOutcome {
            case let .ready(uptime):
                if let failure = await completion.failureMessage { throw CaptureEngineError.recordingFailed(failure) }
                captureStartedUptime = uptime
                pauseClock.anchor(at: uptime)
                anchorRecordingTimeline(at: uptime)
            case let .failed(message):
                throw CaptureEngineError.recordingFailed(message)
            case .timedOut:
                throw CaptureEngineError.captureDidNotStart(
                    CaptureStartupPolicy.noCompleteFrameMessage(
                        targetName: resolvedTarget.targetInfo.title,
                        targetKind: resolvedTarget.targetInfo.kind
                    )
                )
            }

            if state == .preparing {
                state = .recording
            }
            startDurationUpdates()
        } catch {
            eventMonitor.stop()
            durationTask?.cancel()
            durationTask = nil
            if let activeStream, let recordingOutput {
                try? activeStream.removeRecordingOutput(recordingOutput)
            }
            if let activeStream {
                try? await activeStream.stopCapture()
            }
            clearActiveCapture()
            // A startup failure cannot contain a valid first video sample. Do
            // not leave a zero-byte/invalid temporary movie behind.
            if ownsOutputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }

            let mappedError = CaptureEngineError.classifyCaptureFailure(
                error,
                hasScreenRecordingAccess: hasScreenRecordingAccess
            )
            if mappedError.isScreenRecordingPermissionFailure {
                availableTargets = []
            }
            let message = mappedError.localizedDescription
            lastError = message
            state = .failed(message)
            throw mappedError
        }
    }

    /// Stops media writing, not just the UI clock. Capture permissions and source
    /// configuration are retained; no video, audio, or interaction enters a pause.
    public func pauseRecording() async throws {
        await transitionGate.acquire()
        defer { transitionGate.release() }
        guard state == .recording else { throw CaptureEngineError.noActiveRecording }
        guard !isPaused else { return }
        isChangingPauseState = true
        defer { isChangingPauseState = false }
        isPaused = true
        let uptime = ProcessInfo.processInfo.systemUptime
        let requested = pauseClock.pause(at: uptime) ?? 0
        eventMonitor.pause(at: uptime)
        duration = pauseClock.completedDuration
        delegateBridge?.setAcceptsSamples(false)
        do {
            let actual = try await finishActiveSegment(requestedDuration: requested)
            pauseClock.reconcileLastSegment(duration: actual)
            eventMonitor.reconcilePausedDuration(segmentDuration: actual)
            duration = pauseClock.completedDuration
        } catch {
            // A failed writer never becomes part of the joined movie. Previous
            // valid segments remain available to Finish, or the user can retry.
            pauseClock.reconcileLastSegment(duration: 0)
            eventMonitor.reconcilePausedDuration(segmentDuration: 0)
            duration = pauseClock.completedDuration
            lastError = error.localizedDescription
            throw error
        }
    }

    public func resumeRecording() async throws {
        await transitionGate.acquire()
        defer { transitionGate.release() }
        guard state == .recording else { throw CaptureEngineError.noActiveRecording }
        guard isPaused else { return }
        guard let target = activeTarget, let outputSize = activeOutputSize,
              let options = activeOptions, let directory = segmentDirectory else {
            throw CaptureEngineError.noActiveRecording
        }
        isChangingPauseState = true
        defer { isChangingPauseState = false }
        // Resolve the same selected source again; never silently switch windows.
        // If it disappeared, stay safely paused and let Finish save earlier media.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let resolved = try resolve(target: target, in: content)
        let filter = resolved.filter
        let configuration = makeStreamConfiguration(
            resolvedTarget: resolved, outputSize: CapturePixelSize(width: outputSize.width, height: outputSize.height), options: options
        )
        activeContentFilter = filter
        activeStreamConfiguration = configuration
        activeTarget = resolved.targetInfo
        eventMonitor.updatePausedCaptureRect(
            resolved.targetInfo.frame, targetProcessID: resolved.typingProcessID, targetWindowID: resolved.typingWindowID
        )
        let segmentURL = directory.appendingPathComponent("segment-\(UUID().uuidString).mp4")
        let completion = RecordingCompletion()
        let startupGate = CaptureStartupGate()
        let segmentGeneration = UUID()
        activeSegmentGeneration = segmentGeneration
        let queue = DispatchQueue(label: "app.focusstudio.capture.resumed-samples", qos: .userInteractive)
        let bridge = CaptureDelegateBridge(
            sampleHandler: sampleBufferHandler, completion: completion,
            onFirstCompleteScreenSample: { uptime in Task { await startupGate.complete(with: .ready(uptime)) } },
            onFatalError: { [weak self] message in
                Task {
                    await startupGate.complete(with: .failed(message))
                    await completion.complete(.failure(message))
                }
                Task { @MainActor [weak self] in
                    guard let self, self.activeSegmentGeneration == segmentGeneration,
                          !self.isChangingPauseState else { return }
                    await self.handleFatalCaptureError(message)
                }
            }
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: bridge)
        do {
            try stream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: queue)
            if options.capturesSystemAudio { try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: queue) }
            if options.capturesMicrophone { try stream.addStreamOutput(bridge, type: .microphone, sampleHandlerQueue: queue) }
            let outputConfiguration = SCRecordingOutputConfiguration()
            outputConfiguration.outputURL = segmentURL
            outputConfiguration.outputFileType = .mp4
            outputConfiguration.videoCodecType = options.codec.avCodecType
            let output = SCRecordingOutput(configuration: outputConfiguration, delegate: bridge)
            try stream.addRecordingOutput(output)
            activeStream = stream
            recordingOutput = output
            recordingCompletion = completion
            delegateBridge = bridge
            sampleQueue = queue
            activeSegmentURL = segmentURL
            try await stream.startCapture()
            let timeout = Task {
                do {
                    try await Task.sleep(for: CaptureStartupPolicy.firstCompleteFrameTimeout)
                    await startupGate.complete(with: .timedOut)
                } catch {}
            }
            let outcome = await startupGate.wait()
            timeout.cancel()
            switch outcome {
            case let .ready(uptime):
                if let failure = await completion.failureMessage { throw CaptureEngineError.recordingFailed(failure) }
                captureStartedUptime = uptime
                pauseClock.anchor(at: uptime)
                eventMonitor.resume(at: uptime)
                isPaused = false
                lastError = nil
                startDurationUpdates()
            case let .failed(message): throw CaptureEngineError.recordingFailed(message)
            case .timedOut:
                throw CaptureEngineError.captureDidNotStart("The selected source did not produce a frame. Restore its window and retry Resume, or finish the existing recording.")
            }
        } catch {
            bridge.setAcceptsSamples(false)
            if let recordingOutput { try? stream.removeRecordingOutput(recordingOutput) }
            try? await stream.stopCapture()
            activeStream = nil
            recordingOutput = nil
            recordingCompletion = nil
            activeSegmentURL = nil
            // The failed resumed segment was created only for this session.
            try? FileManager.default.removeItem(at: segmentURL)
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Finalizes the MP4 and returns the synchronized cursor/click trace.
    @discardableResult
    public func stopRecording() async throws -> RecordingResult {
        await transitionGate.acquire()
        defer { transitionGate.release() }
        guard
            state == .recording,
            let outputURL = activeOutputURL,
            let target = activeTarget,
            let outputSize = activeOutputSize
        else {
            throw CaptureEngineError.noActiveRecording
        }

        state = .stopping
        let uptime = ProcessInfo.processInfo.systemUptime
        let requested = pauseClock.pause(at: uptime)
        eventMonitor.pause(at: uptime)
        delegateBridge?.setAcceptsSamples(false)
        isPaused = true
        eventMonitor.stop()
        durationTask?.cancel()
        durationTask = nil

        do {
            if let requested {
                let actual = try await finishActiveSegment(requestedDuration: requested)
                pauseClock.reconcileLastSegment(duration: actual)
                eventMonitor.reconcilePausedDuration(segmentDuration: actual)
            }
            duration = try await RecordingSegmentAssembler.assemble(recordedSegments, to: outputURL)
        } catch {
            let message = [error.localizedDescription,
                           segmentDirectory.map { "Recording segments were retained for recovery at: \($0.path)" }]
                .compactMap { $0 }.joined(separator: "\n")
            lastError = message
            state = .failed(message)
            // Preserve session files for recovery after a failed final export.
            clearActiveCapture(removeSegments: false)
            throw CaptureEngineError.recordingFailed(message)
        }
        let trace = eventMonitor.snapshot()
        let result = RecordingResult(
            outputURL: outputURL,
            duration: duration,
            sourceWidth: outputSize.width,
            sourceHeight: outputSize.height,
            cursorSamples: trace.cursorSamples,
            clickEvents: trace.clickEvents,
            target: target,
            typingActivity: trace.typingActivity,
            eventDiagnostics: eventMonitor.diagnostics
        )

        clearActiveCapture()

        state = .completed(outputURL)
        return result
    }

    /// Flushes exactly one writer, including when the screen is currently idle.
    private func finishActiveSegment(requestedDuration: TimeInterval) async throws -> TimeInterval {
        guard let stream = activeStream, let output = recordingOutput,
              let completion = recordingCompletion, let url = activeSegmentURL else {
            throw CaptureEngineError.noActiveRecording
        }
        defer {
            activeStream = nil
            recordingOutput = nil
            recordingCompletion = nil
            activeSegmentURL = nil
        }
        var failure: Error?
        var removed = false
        do { try stream.removeRecordingOutput(output); removed = true } catch { failure = error }
        // Drain the recording output before tearing down its stream. The pause
        // interval is already closed, so callback frames cannot leak into media.
        if removed, case let .failure(message) = await completion.wait(timeout: .seconds(15)) {
            failure = CaptureEngineError.recordingFailed(message)
        }
        do { try await stream.stopCapture() } catch { failure = failure ?? error }
        if let failure { throw failure }
        let actual = try await RecordingSegmentAssembler.playableDuration(at: url, requested: requestedDuration)
        if actual > 0 { recordedSegments.append(.init(url: url, duration: actual)) }
        return actual
    }

    /// Aborts a recording the user never saw: a lost start-up race or a failed
    /// launch. The partial file is deleted outright because there is nothing in
    /// it worth keeping. For a take the user asks to throw away, use
    /// ``discardRecording()``, which moves the file to the Trash instead.
    public func cancelRecording() async {
        guard let result = try? await stopRecording() else { return }
        try? FileManager.default.removeItem(at: result.outputURL)
    }

    /// The user-facing discard. It finalizes through the same `stopRecording()`
    /// as Finish, so a paused-and-resumed take is spliced identically, then
    /// moves the file to the Trash. A mis-click stays recoverable, which matches
    /// the library's policy of never deleting a recording permanently.
    public func discardRecording() async -> RecordingDiscardOutcome {
        let result: RecordingResult
        do {
            result = try await stopRecording()
        } catch {
            return .failed(error.localizedDescription)
        }
        do {
            try FileManager.default.trashItem(at: result.outputURL, resultingItemURL: nil)
            return .trashed
        } catch {
            // Keep the file rather than falling back to a permanent delete: on a
            // volume with no Trash, losing the take silently is the worse bug.
            return .kept(result.outputURL, error.localizedDescription)
        }
    }

    /// Captures the exact source currently being recorded and writes a PNG.
    /// The active content filter is reused so a display screenshot follows the
    /// same app-exclusion and area-crop rules as the movie.
    public func captureScreenshot(to outputURL: URL) async throws {
        guard
            isRecording,
            let filter = activeContentFilter,
            let configuration = activeStreamConfiguration
        else {
            throw CaptureEngineError.screenshotUnavailable
        }

        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let image: CGImage
            do {
                image = try await withCheckedThrowingContinuation { continuation in
                    SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: configuration
                    ) { image, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let image {
                            continuation.resume(returning: image)
                        } else {
                            continuation.resume(
                                throwing: CaptureEngineError.screenshotFailed("ScreenCaptureKit returned no image.")
                            )
                        }
                    }
                }
            } catch {
                // A desktop-independent window can keep recording while it sits
                // in another Space, but SCScreenshotManager may reject a fresh
                // one-shot capture in that state. The stream's latest complete
                // pixel buffer is the same selected source and is a safe fallback.
                guard let pixelBuffer = delegateBridge?.latestScreenPixelBuffer() else {
                    throw error
                }
                let source = CIImage(cvPixelBuffer: pixelBuffer)
                guard let fallback = CIContext().createCGImage(source, from: source.extent) else {
                    throw error
                }
                image = fallback
            }

            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                throw CaptureEngineError.screenshotFailed("Could not create the PNG destination.")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw CaptureEngineError.screenshotFailed("The PNG encoder did not finish.")
            }
        } catch let error as CaptureEngineError {
            throw error
        } catch {
            throw CaptureEngineError.screenshotFailed(error.localizedDescription)
        }
    }

    /// Captures a selected source without starting a recording. Codex Director
    /// uses this to provide the planner with the exact page/window it will later
    /// record instead of asking the model to guess interaction coordinates.
    public func captureScreenshot(
        target: CaptureTargetInfo,
        to outputURL: URL
    ) async throws {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let resolvedTarget = try resolve(target: target, in: content)
            var options = CaptureOptions()
            options.frameRate = 30
            options.capturesSystemAudio = false
            options.capturesMicrophone = false
            let outputSize = CaptureOutputGeometry.pixelSize(
                sourcePointSize: resolvedTarget.sourcePointSize,
                targetScaleFactor: resolvedTarget.targetInfo.scaleFactor,
                outputScale: options.outputScale,
                maximumOutputDimension: options.maximumOutputDimension
            )
            let configuration = makeStreamConfiguration(
                resolvedTarget: resolvedTarget,
                outputSize: outputSize,
                options: options
            )
            let image = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CGImage, Error>) in
                SCScreenshotManager.captureImage(
                    contentFilter: resolvedTarget.filter,
                    configuration: configuration
                ) { image, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(
                            throwing: CaptureEngineError.screenshotFailed(
                                "ScreenCaptureKit returned no image."
                            )
                        )
                    }
                }
            }

            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                throw CaptureEngineError.screenshotFailed("Could not create the PNG destination.")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw CaptureEngineError.screenshotFailed("The PNG encoder did not finish.")
            }
        } catch let error as CaptureEngineError {
            throw error
        } catch {
            throw CaptureEngineError.classifyCaptureFailure(
                error,
                hasScreenRecordingAccess: hasScreenRecordingAccess
            )
        }
    }

    /// Returns a display-backed target for an arbitrary selection rectangle.
    public func makeAreaTarget(
        on display: CaptureTargetInfo,
        frame: CaptureRect,
        title: String = "Selected Area"
    ) throws -> CaptureTargetInfo {
        guard display.kind == .display else {
            throw CaptureEngineError.invalidTarget("Area capture requires a display target.")
        }
        guard let clippedFrame = AreaCaptureGeometry.clippedGlobalFrame(
            frame,
            toDisplay: display.frame
        ) else {
            throw CaptureEngineError.invalidTarget("The selected area is empty or outside its display.")
        }
        return CaptureTargetInfo(
            id: "area-\(display.nativeID)-\(UUID().uuidString)",
            kind: .area,
            nativeID: display.nativeID,
            title: title,
            frame: clippedFrame,
            scaleFactor: display.scaleFactor
        )
    }

    /// Adds a transient picker-created area to the current source inventory.
    /// Only one area is retained because a new drag replaces the previous one.
    /// A subsequent source refresh intentionally clears transient areas.
    public func registerAreaTarget(_ target: CaptureTargetInfo) throws {
        guard target.kind == .area else {
            throw CaptureEngineError.invalidTarget("Only area targets can be registered as a selection.")
        }
        availableTargets.removeAll { $0.kind == .area }
        availableTargets.append(target)
    }

    private func makeTargetInfos(from content: SCShareableContent) -> [CaptureTargetInfo] {
        let screenScales = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (UInt32, Double)? in
                let key = NSDeviceDescriptionKey("NSScreenNumber")
                guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
                return (number.uint32Value, Double(screen.backingScaleFactor))
            }
        )

        let displayTargets = content.displays.enumerated().map { index, display in
            let nativeID = UInt32(display.displayID)
            let screen = NSScreen.screens.first { screen in
                let key = NSDeviceDescriptionKey("NSScreenNumber")
                return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == nativeID
            }
            return CaptureTargetInfo(
                id: "display-\(nativeID)",
                kind: .display,
                nativeID: nativeID,
                title: screen?.localizedName ?? "Display \(index + 1)",
                frame: captureRect(display.frame),
                scaleFactor: screenScales[nativeID] ?? 1
            )
        }

        let windowTargets: [CaptureTargetInfo] = content.windows
            .filter { window in
                window.windowLayer == 0
                    && CaptureStartupPolicy.isRecordableWindow(
                        isOnScreen: window.isOnScreen,
                        frame: captureRect(window.frame)
                    )
                    && (window.title?.isEmpty == false || window.owningApplication != nil)
            }
            .map { window in
                let appName = window.owningApplication?.applicationName
                let title = window.title?.isEmpty == false
                    ? window.title!
                    : (appName ?? "Window \(window.windowID)")
                let display = content.displays.max { lhs, rhs in
                    intersectionArea(lhs.frame, window.frame) < intersectionArea(rhs.frame, window.frame)
                }
                let scale = display.flatMap { screenScales[UInt32($0.displayID)] } ?? 1
                return CaptureTargetInfo(
                    id: "window-\(window.windowID)",
                    kind: .window,
                    nativeID: UInt32(window.windowID),
                    title: title,
                    appName: appName,
                    frame: captureRect(window.frame),
                    scaleFactor: scale
                )
            }
            .sorted { (lhs: CaptureTargetInfo, rhs: CaptureTargetInfo) in
                "\(lhs.appName ?? "")\u{0}\(lhs.title)".localizedStandardCompare(
                    "\(rhs.appName ?? "")\u{0}\(rhs.title)"
                ) == .orderedAscending
            }

        return displayTargets + windowTargets
    }

    private func resolve(
        target: CaptureTargetInfo,
        in content: SCShareableContent
    ) throws -> ResolvedTarget {
        switch target.kind {
        case .display:
            guard let display = content.displays.first(where: { UInt32($0.displayID) == target.nativeID }) else {
                throw CaptureEngineError.targetUnavailable(target.title)
            }
            var currentTarget = target
            currentTarget.frame = captureRect(display.frame)
            return ResolvedTarget(
                filter: displayFilter(display, content: content),
                targetInfo: currentTarget,
                sourcePointSize: display.frame.size,
                sourceRect: nil
            )

        case .window:
            guard let window = content.windows.first(where: { UInt32($0.windowID) == target.nativeID }) else {
                throw CaptureEngineError.targetUnavailable(target.title)
            }
            guard CaptureStartupPolicy.isRecordableWindow(
                isOnScreen: window.isOnScreen,
                frame: captureRect(window.frame)
            ) else {
                throw CaptureEngineError.captureDidNotStart(
                    "The selected window “\(target.title)” is not currently visible. Restore it or move to its desktop, refresh the source list, and select it again."
                )
            }
            var currentTarget = target
            currentTarget.frame = captureRect(window.frame)
            currentTarget.title = window.title ?? target.title
            currentTarget.appName = window.owningApplication?.applicationName ?? target.appName
            return ResolvedTarget(
                filter: SCContentFilter(desktopIndependentWindow: window),
                targetInfo: currentTarget,
                sourcePointSize: window.frame.size,
                sourceRect: nil,
                typingProcessID: window.owningApplication?.processID,
                typingWindowID: UInt32(window.windowID)
            )

        case .area:
            let requestedRect = cgRect(target.frame)
            let display = content.displays.first(where: { UInt32($0.displayID) == target.nativeID })
                ?? content.displays.max { lhs, rhs in
                    intersectionArea(lhs.frame, requestedRect) < intersectionArea(rhs.frame, requestedRect)
                }
            guard let display else {
                throw CaptureEngineError.targetUnavailable(target.title)
            }

            let displayFrame = captureRect(display.frame)
            guard
                let clippedFrame = AreaCaptureGeometry.clippedGlobalFrame(
                    target.frame,
                    toDisplay: displayFrame
                ),
                let localSourceRect = AreaCaptureGeometry.sourceRect(
                    forGlobalFrame: clippedFrame,
                    onDisplay: displayFrame
                )
            else {
                throw CaptureEngineError.invalidTarget("The selected area is outside its display.")
            }
            var currentTarget = target
            currentTarget.nativeID = UInt32(display.displayID)
            currentTarget.frame = clippedFrame
            return ResolvedTarget(
                filter: displayFilter(display, content: content),
                targetInfo: currentTarget,
                sourcePointSize: CGSize(width: clippedFrame.width, height: clippedFrame.height),
                sourceRect: localSourceRect
            )
        }
    }

    /// Keep Focus Studio's recording controls out of display and area captures.
    /// Window captures already contain only the explicitly selected window.
    private func displayFilter(_ display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let ownApplications = content.applications.filter { $0.processID == ownProcessID }
        guard !ownApplications.isEmpty else {
            return SCContentFilter(display: display, excludingWindows: [])
        }
        return SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
    }

    private func validate(options: CaptureOptions) throws {
        guard (1...240).contains(options.frameRate) else {
            throw CaptureEngineError.invalidOptions("Frame rate must be between 1 and 240.")
        }
        if let outputScale = options.outputScale, !(0.1...4).contains(outputScale) {
            throw CaptureEngineError.invalidOptions("Output scale must be between 0.1 and 4.0.")
        }
        guard options.maximumOutputDimension >= 320 else {
            throw CaptureEngineError.invalidOptions("Maximum output dimension must be at least 320 pixels.")
        }
        guard (3...8).contains(options.queueDepth) else {
            throw CaptureEngineError.invalidOptions("Queue depth must be between 3 and 8.")
        }
        guard options.audioSampleRate > 0, (1...8).contains(options.audioChannelCount) else {
            throw CaptureEngineError.invalidOptions("Audio sample rate or channel count is invalid.")
        }
    }

    private func prepareOutputURL(_ outputURL: URL) throws {
        guard outputURL.isFileURL else {
            throw CaptureEngineError.invalidOptions("The output must be a local file URL.")
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            throw CaptureEngineError.outputFileAlreadyExists(outputURL)
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func makeStreamConfiguration(
        resolvedTarget: ResolvedTarget,
        outputSize: CapturePixelSize,
        options: CaptureOptions
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(options.frameRate)
        )
        configuration.queueDepth = options.queueDepth
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.showMouseClicks = false
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.captureMicrophone = options.capturesMicrophone
        configuration.excludesCurrentProcessAudio = options.excludesCurrentProcessAudio
        configuration.sampleRate = options.audioSampleRate
        configuration.channelCount = options.audioChannelCount
        configuration.microphoneCaptureDeviceID = options.microphoneDeviceID
        configuration.ignoreShadowsSingleWindow = options.ignoresWindowShadow
        if let sourceRect = resolvedTarget.sourceRect {
            configuration.sourceRect = sourceRect
        }
        return configuration
    }

    private func anchorRecordingTimeline(at uptime: TimeInterval) {
        guard recordingStartUptime == nil else { return }
        recordingStartUptime = uptime
        eventMonitor.anchor(at: uptime)
        eventCaptureWarning = eventMonitor.lastError
    }

    private func startDurationUpdates() {
        durationTask?.cancel()
        durationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard let self, self.isRecording else { return }
                self.duration = self.pauseClock.elapsed(at: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    private func handleFatalCaptureError(_ message: String) async {
        guard activeStream != nil, !failureCleanupInProgress else { return }
        guard state != .stopping, !isChangingPauseState else { return }
        failureCleanupInProgress = true
        lastError = message
        // Keep the session busy until its asynchronous teardown is complete.
        // Publishing failure earlier allows UI observers to start a new capture
        // that this old session's cleanup would then clear.
        state = .stopping
        eventMonitor.stop()
        durationTask?.cancel()
        durationTask = nil
        if let activeStream {
            try? await activeStream.stopCapture()
        }
        clearActiveCapture(removeSegments: false)
        failureCleanupInProgress = false
        state = .failed(message)
    }

    private func clearActiveCapture(removeSegments: Bool = true) {
        activeSegmentGeneration = UUID()
        if removeSegments, let segmentDirectory {
            // Only this session's UUID directory; never a caller-provided folder.
            try? FileManager.default.removeItem(at: segmentDirectory)
        }
        segmentDirectory = nil
        recordedSegments = []
        activeSegmentURL = nil
        activeOptions = nil
        isPaused = false
        activeStream = nil
        recordingOutput = nil
        delegateBridge = nil
        recordingCompletion = nil
        sampleQueue = nil
        activeOutputURL = nil
        activeTarget = nil
        activeOutputSize = nil
        activeContentFilter = nil
        activeStreamConfiguration = nil
        captureStartedUptime = nil
    }

    private func finiteSeconds(_ time: CMTime) -> TimeInterval {
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite && seconds >= 0 ? seconds : 0
    }
}

private struct ResolvedTarget {
    var filter: SCContentFilter
    var targetInfo: CaptureTargetInfo
    var sourcePointSize: CGSize
    var sourceRect: CGRect?
    var typingProcessID: Int32? = nil
    var typingWindowID: UInt32? = nil
}

private enum RecordingFinishOutcome: Sendable {
    case success
    case failure(String)
}

private enum CaptureStartupOutcome: Sendable {
    case ready(TimeInterval)
    case failed(String)
    case timedOut
}

/// One-shot rendezvous between ScreenCaptureKit's serial callback queue and the
/// main-actor start call. It also stores an early callback so a frame delivered
/// before `wait()` cannot be lost.
private actor CaptureStartupGate {
    private var outcome: CaptureStartupOutcome?
    private var waiters: [CheckedContinuation<CaptureStartupOutcome, Never>] = []

    func wait() async -> CaptureStartupOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func complete(with newOutcome: CaptureStartupOutcome) {
        guard outcome == nil else { return }
        outcome = newOutcome
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume(returning: newOutcome)
        }
    }
}

private actor RecordingCompletion {
    private var outcome: RecordingFinishOutcome?
    private var waiters: [CheckedContinuation<RecordingFinishOutcome, Never>] = []
    var failureMessage: String? {
        if case let .failure(message) = outcome { return message }
        return nil
    }

    func wait() async -> RecordingFinishOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func wait(timeout: Duration) async -> RecordingFinishOutcome {
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
                complete(.failure("The recording segment did not finish writing in time."))
            } catch {}
        }
        let result = await wait()
        timer.cancel()
        return result
    }

    func complete(_ newOutcome: RecordingFinishOutcome) {
        guard outcome == nil else { return }
        outcome = newOutcome
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume(returning: newOutcome)
        }
    }
}

private final class CaptureDelegateBridge: NSObject, SCStreamOutput, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    private let sampleHandler: CaptureEngine.SampleBufferHandler?
    private let completion: RecordingCompletion
    private let onFirstCompleteScreenSample: @Sendable (TimeInterval) -> Void
    private let onFatalError: @Sendable (String) -> Void
    private let firstFrameLock = NSLock()
    private var hasDeliveredFirstFrame = false
    private let latestFrameLock = NSLock()
    private var latestScreenFrame: CVPixelBuffer?
    private var acceptsSamples = true

    init(
        sampleHandler: CaptureEngine.SampleBufferHandler?,
        completion: RecordingCompletion,
        onFirstCompleteScreenSample: @escaping @Sendable (TimeInterval) -> Void,
        onFatalError: @escaping @Sendable (String) -> Void
    ) {
        self.sampleHandler = sampleHandler
        self.completion = completion
        self.onFirstCompleteScreenSample = onFirstCompleteScreenSample
        self.onFatalError = onFatalError
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        latestFrameLock.lock()
        let acceptsSamples = self.acceptsSamples
        latestFrameLock.unlock()
        guard acceptsSamples else { return }
        if type == .screen, isCompleteScreenSample(sampleBuffer) {
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                latestFrameLock.lock()
                latestScreenFrame = pixelBuffer
                latestFrameLock.unlock()
            }
            if markFirstFrameIfNeeded() {
                onFirstCompleteScreenSample(estimatedSystemUptime(for: sampleBuffer))
            }
        }
        sampleHandler?(sampleBuffer, type)
    }

    func latestScreenPixelBuffer() -> CVPixelBuffer? {
        latestFrameLock.lock()
        defer { latestFrameLock.unlock() }
        return latestScreenFrame
    }

    func setAcceptsSamples(_ accepts: Bool) {
        latestFrameLock.lock()
        acceptsSamples = accepts
        latestFrameLock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onFatalError(error.localizedDescription)
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        // This callback can precede the first encodable video frame (notably for
        // off-screen windows). Startup is gated exclusively by a complete screen
        // sample in `didOutputSampleBuffer` above.
    }

    func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: any Error
    ) {
        let message = error.localizedDescription
        Task {
            await completion.complete(.failure(message))
        }
        onFatalError(message)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task {
            await completion.complete(.success)
        }
    }

    private func markFirstFrameIfNeeded() -> Bool {
        firstFrameLock.lock()
        defer { firstFrameLock.unlock() }
        guard !hasDeliveredFirstFrame else { return false }
        hasDeliveredFirstFrame = true
        return true
    }

    private func isCompleteScreenSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            return false
        }
        guard
            let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let attachments = attachmentArray.first,
            let rawStatus = attachments[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else {
            return false
        }
        return status == .complete
    }

    private func estimatedSystemUptime(for sampleBuffer: CMSampleBuffer) -> TimeInterval {
        let presentationSeconds = CMTimeGetSeconds(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
        let hostClockSeconds = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let currentUptime = ProcessInfo.processInfo.systemUptime
        guard presentationSeconds.isFinite, hostClockSeconds.isFinite else {
            return currentUptime
        }
        let hostDelta = presentationSeconds - hostClockSeconds
        // ScreenCaptureKit normally timestamps against the host clock. If a future
        // OS/device supplies a stream-relative PTS instead, use callback uptime as
        // the safe zero rather than manufacturing a wildly offset event timeline.
        guard abs(hostDelta) < 10 else { return currentUptime }
        return currentUptime + hostDelta
    }
}

private func captureRect(_ rect: CGRect) -> CaptureRect {
    CaptureRect(
        x: rect.origin.x,
        y: rect.origin.y,
        width: rect.width,
        height: rect.height
    )
}

private func cgRect(_ rect: CaptureRect) -> CGRect {
    CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
}

private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull else { return 0 }
    return intersection.width * intersection.height
}
