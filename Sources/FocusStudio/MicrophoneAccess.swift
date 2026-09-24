import AVFoundation
import FocusStudioAutomation
import Foundation

/// Whether macOS lets Focus Studio use the microphone
/// (`AVCaptureDevice.authorizationStatus(for: .audio)`).
enum MicrophoneAuthorization: Equatable, Sendable {
    /// macOS has never asked the person.
    case notDetermined
    case authorized
    /// The person turned it off (System Settings › Privacy & Security ›
    /// Microphone, or Don't Allow when macOS asked).
    case denied
    /// Screen Time or a device management profile keeps it off.
    case restricted

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        // A status macOS adds later: not usable until it says authorized.
        @unknown default: self = .denied
        }
    }
}

/// Settles macOS's microphone permission before a recording that captures
/// the microphone counts down.
///
/// ScreenCaptureKit asks macOS for the microphone only when the capture
/// starts. The first time, macOS's dialog therefore came up after the
/// countdown, while the recording already ran: a recording with a duration
/// ran out while the person answered, and the start of the sound may be
/// missing (found in the 1.12.0 live check); the dialog could also end up in
/// the video. Asking here, before the countdown, avoids this.
///
/// ``ensure(progress:timeout:)`` asks macOS only when the person has never
/// answered; everyone asking while macOS's dialog is up waits for its one
/// answer. The status probe and the request are injected, so tests fake
/// every state without a real dialog.
@MainActor
final class MicrophoneAccessController {
    typealias StatusProbe = @MainActor () -> MicrophoneAuthorization
    /// Shows macOS's dialog and returns whether the person allowed it.
    typealias AccessRequest = @Sendable () async -> Bool

    /// How long an AI tool's start_recording waits for the person to answer
    /// macOS's dialog, as long as the sound prompt waits.
    nonisolated static let defaultTimeout: TimeInterval = 60
    nonisolated static let defaultHeartbeatInterval: TimeInterval = 5
    /// Heartbeat progress while macOS's dialog is up: tiny increasing values
    /// from this base, above the sound prompt's (which comes first in the
    /// same call), since a call's progress must keep increasing.
    nonisolated static let heartbeatBase = 0.02
    nonisolated static let heartbeatStep = 0.0001
    nonisolated static let waitingMessage = "Waiting for the person to answer macOS's microphone access prompt for Focus Studio…"

    /// The wait an AI tool's call uses (``defaultTimeout`` in the app).
    let timeout: TimeInterval
    let heartbeatInterval: TimeInterval
    private let probe: StatusProbe
    private let requestAccess: AccessRequest
    /// macOS's dialog while it is up.
    private var request: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Bool?, Never>] = [:]
    /// How many times macOS was asked (tests).
    private(set) var requestCount = 0

    init(
        timeout: TimeInterval = defaultTimeout,
        heartbeatInterval: TimeInterval = defaultHeartbeatInterval,
        status: @escaping StatusProbe = { MicrophoneAuthorization(AVCaptureDevice.authorizationStatus(for: .audio)) },
        request: @escaping AccessRequest = { await AVCaptureDevice.requestAccess(for: .audio) }
    ) {
        self.timeout = max(0, timeout)
        self.heartbeatInterval = max(0.01, heartbeatInterval)
        probe = status
        requestAccess = request
    }

    /// What macOS says now, without asking.
    var authorization: MicrophoneAuthorization { probe() }

    /// Whether macOS's dialog is up (this controller asked and has no answer yet).
    var isAsking: Bool { request != nil }

    /// Callers waiting for macOS's answer now.
    var waitingCount: Int { waiters.count }

    /// Whether Focus Studio may use the microphone. When the person has never
    /// answered, asks macOS (its dialog) and waits for the answer, at most
    /// `timeout` seconds (nil: until it comes), sending heartbeat `progress`
    /// meanwhile. macOS's dialog cannot be closed: when the wait ends first,
    /// a later answer is only remembered by macOS. A cancelled caller stops
    /// waiting at once and gets `.timedOut` with no time; it checks for
    /// cancellation itself.
    func ensure(progress: AIToolProgressHandler?, timeout: TimeInterval?) async -> AIMicrophoneAccess {
        switch probe() {
        case .authorized: return .authorized(askedNow: false)
        case .denied: return .denied(askedNow: false)
        case .restricted: return .restricted
        case .notDetermined: break
        }
        let beats = HeartbeatCount()
        let heartbeat = progress.map { progress in
            Task { @MainActor [interval = heartbeatInterval] in
                while !Task.isCancelled {
                    progress(Self.heartbeatBase + Double(beats.next()) * Self.heartbeatStep, nil, Self.waitingMessage)
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
        }
        let granted = await answer(within: timeout)
        heartbeat?.cancel()
        // The wait is over: a last report without a message, so a job's
        // running status no longer says it waits for the person.
        progress?(Self.heartbeatBase + Double(beats.next()) * Self.heartbeatStep, nil, nil)
        if Task.isCancelled { return .timedOut(0) }
        guard let granted else { return .timedOut(timeout ?? 0) }
        if granted { return .authorized(askedNow: true) }
        return probe() == .restricted ? .restricted : .denied(askedNow: true)
    }

    /// macOS's answer, or nil when `timeout` passes (never, for nil) or the
    /// caller is cancelled first. Asks macOS unless its dialog is already up.
    private func answer(within timeout: TimeInterval?) async -> Bool? {
        if request == nil {
            requestCount += 1
            let ask = requestAccess
            request = Task { @MainActor [weak self] in
                let granted = await ask()
                self?.answered(granted)
            }
        }
        let token = UUID()
        let timer = timeout.map { seconds in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, seconds)))
                guard !Task.isCancelled else { return }
                self?.resume(token, with: nil)
            }
        }
        defer { timer?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiters[token] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(token, with: nil) }
        }
    }

    private func answered(_ granted: Bool) {
        request = nil
        let pending = waiters
        waiters = [:]
        for waiter in pending.values { waiter.resume(returning: granted) }
    }

    private func resume(_ token: UUID, with value: Bool?) {
        waiters.removeValue(forKey: token)?.resume(returning: value)
    }
}

/// The heartbeats of one wait, counted on the main actor.
@MainActor
private final class HeartbeatCount {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
