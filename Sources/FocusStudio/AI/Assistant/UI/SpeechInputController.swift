import Accelerate
import AppKit
import AVFoundation
import Foundation
import Speech
import SwiftUI

/// Voice input for the composer: the microphone is captured with
/// AVAudioEngine and streamed into SFSpeechRecognizer. Partial transcripts,
/// an RMS level for the avatar and meter, and permission problems are
/// published for the panel. Recording stops on request, after a pause once
/// something was heard, or when nothing is heard for a while.
@MainActor
final class SpeechInputController: ObservableObject {
    enum Issue: Equatable {
        case speechDenied
        case speechRestricted
        case microphoneDenied
        case noMicrophone
        case unavailable

        var message: LocalizedStringKey {
            switch self {
            case .speechDenied: return "Speech recognition is turned off for Focus Studio."
            case .speechRestricted: return "Speech recognition is not available on this Mac."
            case .microphoneDenied: return "Microphone access is turned off for Focus Studio."
            case .noMicrophone: return "No microphone was found."
            case .unavailable: return "Speech recognition is unavailable right now."
            }
        }

        /// System Settings → Privacy & Security pane that fixes the problem.
        var settingsURL: URL? {
            switch self {
            case .speechDenied:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            case .microphoneDenied:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .speechRestricted, .noMicrophone, .unavailable:
                return nil
            }
        }
    }

    static let silenceTimeout: TimeInterval = 1.5
    static let emptyTimeout: TimeInterval = 8
    static let maximumDuration: TimeInterval = 60
    /// Levels above this count as voice activity and postpone the silence stop.
    static let activityThreshold = 0.22

    @Published private(set) var isRecording = false
    /// True while permissions are being requested and the engine starts.
    @Published private(set) var isPreparing = false
    /// The live partial transcript; updated until the final result arrives.
    @Published private(set) var transcript = ""
    /// 0…1 microphone level, smoothed over ~40 ms windows.
    @Published private(set) var audioLevel: Double = 0
    /// Set when recording cannot start; the panel shows it until dismissed.
    @Published var issue: Issue?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var watchdog: Timer?
    private var finalizeTask: Task<Void, Never>?
    private var startedAt = Date()
    private var lastActivity = Date()
    private var stopRequested = false
    private var awaitingFinal = false
    /// Incremented per session so late callbacks from a previous one are ignored.
    private var generation = 0

    var isActive: Bool { isRecording || isPreparing }

    /// Recognition locale for the UI language ("zh-Hans" → zh-CN, else en-US).
    static func localeIdentifier(for language: String) -> String {
        language.lowercased().hasPrefix("zh") ? "zh-CN" : "en-US"
    }

    static var currentLocale: Locale {
        Locale(identifier: localeIdentifier(for: AppLocalization.shared.language.localeIdentifier))
    }

    deinit {
        watchdog?.invalidate()
    }

    // MARK: - Control

    func toggle() {
        if isRecording {
            stop()
        } else if !isPreparing {
            start()
        }
    }

    func start() {
        guard !isRecording, !isPreparing else { return }
        isPreparing = true
        issue = nil
        Task { [weak self] in
            guard let self else { return }
            let authorized = await self.ensureAuthorization()
            guard self.isPreparing else { return }
            if authorized { self.beginCapture() }
            self.isPreparing = false
        }
    }

    /// Ends capture and waits briefly for the recognizer's final transcript.
    func stop() {
        if isPreparing {
            isPreparing = false
            return
        }
        guard isRecording else { return }
        stopRequested = true
        stopCapture()
        awaitingFinal = true
        finalizeTask?.cancel()
        finalizeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    /// Ends capture and discards anything still in flight.
    func cancel() {
        generation += 1
        isPreparing = false
        stopCapture()
        awaitingFinal = false
        finalizeTask?.cancel()
        finalizeTask = nil
        task?.cancel()
        releaseSession()
    }

    // MARK: - Authorization

    private func ensureAuthorization() async -> Bool {
        var speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        switch speechStatus {
        case .authorized:
            break
        case .denied:
            issue = .speechDenied
            return false
        case .restricted, .notDetermined:
            issue = .speechRestricted
            return false
        @unknown default:
            issue = .speechRestricted
            return false
        }

        var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneStatus == .notDetermined {
            microphoneStatus = await AVCaptureDevice.requestAccess(for: .audio) ? .authorized : .denied
        }
        guard microphoneStatus == .authorized else {
            issue = .microphoneDenied
            return false
        }
        return true
    }

    // MARK: - Capture

    private func beginCapture() {
        guard let recognizer = SFSpeechRecognizer(locale: Self.currentLocale), recognizer.isAvailable else {
            issue = .unavailable
            return
        }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            issue = .noMicrophone
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        generation += 1
        let generation = self.generation
        let meter = AudioLevelMeter()
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            guard let level = meter.measure(buffer) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(level: level, generation: generation) }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            issue = .noMicrophone
            return
        }

        self.engine = engine
        self.request = request
        self.recognizer = recognizer
        transcript = ""
        audioLevel = 0
        stopRequested = false
        awaitingFinal = false
        startedAt = Date()
        lastActivity = startedAt
        isRecording = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor [weak self] in
                self?.handle(text: text, isFinal: isFinal, failed: error != nil, generation: generation)
            }
        }
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSilence() }
        }
    }

    private func receive(level: Double, generation: Int) {
        guard generation == self.generation, isRecording else { return }
        audioLevel = level
        if level > Self.activityThreshold { lastActivity = Date() }
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool, generation: Int) {
        guard generation == self.generation else { return }
        if let text, !text.isEmpty, text != transcript {
            transcript = text
            lastActivity = Date()
        }
        if isFinal {
            finish()
        } else if failed {
            // Errors after endAudio() (for example "no speech detected") are a
            // normal end; a failure mid-recording is reported if nothing was heard.
            if isRecording {
                stopCapture()
                if transcript.isEmpty, !stopRequested { issue = .unavailable }
            }
            finish()
        }
    }

    private func checkSilence() {
        guard isRecording else { return }
        let now = Date()
        if now.timeIntervalSince(startedAt) > Self.maximumDuration {
            stop()
            return
        }
        let idle = now.timeIntervalSince(lastActivity)
        if transcript.isEmpty ? idle > Self.emptyTimeout : idle > Self.silenceTimeout {
            stop()
        }
    }

    private func stopCapture() {
        watchdog?.invalidate()
        watchdog = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        request?.endAudio()
        isRecording = false
        audioLevel = 0
    }

    private func finish() {
        guard awaitingFinal || isRecording else { return }
        if isRecording { stopCapture() }
        awaitingFinal = false
        finalizeTask?.cancel()
        finalizeTask = nil
        task?.cancel()
        releaseSession()
    }

    private func releaseSession() {
        task = nil
        request = nil
        engine = nil
        recognizer = nil
    }
}

/// RMS level of the microphone, reported once per ~40 ms window as 0…1.
/// Runs on the audio tap thread; every call comes from that single thread.
final class AudioLevelMeter: @unchecked Sendable {
    private var peak: Float = 0
    private var accumulated: AVAudioFrameCount = 0
    private let window: AVAudioFrameCount = 2048

    func measure(_ buffer: AVAudioPCMBuffer) -> Double? {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))
        peak = max(peak, rms)
        accumulated += buffer.frameLength
        guard accumulated >= window else { return nil }
        let decibels = 20 * log10(max(Double(peak), 1e-7))
        peak = 0
        accumulated = 0
        let normalized = (decibels + 50) / 46
        return pow(min(max(normalized, 0), 1), 0.85)
    }
}
