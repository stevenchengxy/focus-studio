import AVFoundation
import Combine
import FocusStudioAutomation
import Foundation

@MainActor
protocol VoiceoverRecordingEngine: AnyObject {
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    func record(forDuration: TimeInterval) -> Bool
    func stop()
    func updateMeters()
    func averagePower(forChannel: Int) -> Float
}

extension AVAudioRecorder: VoiceoverRecordingEngine {}

/// Explicit UI-owned microphone take. Never registered as an AI tool: a
/// recording starts only from the visible Record voiceover button. Cancelling
/// a permission wait cannot start the microphone after this panel disappears.
@MainActor
final class VoiceoverRecorder: ObservableObject {
    enum Phase: Equatable { case idle, requesting, recording }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var error: String?
    private var engine: (any VoiceoverRecordingEngine)?
    private var url: URL?
    private var generation = UUID()
    private var meterTask: Task<Void, Never>?
    private var completion: ((URL) -> Void)?
    private let factory: (URL) throws -> any VoiceoverRecordingEngine

    init(factory: @escaping (URL) throws -> any VoiceoverRecordingEngine = { url in
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128_000])
        recorder.isMeteringEnabled = true
        return recorder
    }) { self.factory = factory }

    func start(access: MicrophoneAccessController, maximumDuration: Double,
               completed: @escaping (URL) -> Void) async {
        guard phase == .idle else { return }
        error = nil; elapsed = 0; level = 0
        let run = UUID(); generation = run; phase = .requesting
        let permission = await access.ensure(progress: nil, timeout: nil)
        guard generation == run, !Task.isCancelled else { return }
        guard case .authorized = permission else {
            phase = .idle; error = L10n.tr("Allow microphone access in System Settings to record voiceover."); return
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("FocusStudio-Voiceover-\(UUID()).m4a")
        do {
            let recorder = try factory(target)
            guard recorder.record(forDuration: min(600, max(0.1, maximumDuration))) else {
                recorder.stop(); throw RecorderError.failed
            }
            engine = recorder; url = target; completion = completed; phase = .recording
            meterTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self, self.generation == run else { return }
                    self.refreshMeters()
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            phase = .idle; self.error = L10n.tr("The microphone could not start. Check the input device and try again.")
        }
    }

    func refreshMeters() {
        guard phase == .recording, let engine else { return }
        elapsed = engine.currentTime
        engine.updateMeters()
        let power = Double(engine.averagePower(forChannel: 0))
        // A decibel meter, not a cosmetic animation. -60 dB is effectively
        // silent; 0 dB is full scale. Only this compact panel updates at 10 Hz.
        level = power.isFinite ? ((power + 60) / 60).clamped(to: 0...1) : 0
        if !engine.isRecording { finish() }
    }

    func finish() {
        guard phase == .recording, let engine, let url else { return }
        let duration = max(elapsed, engine.currentTime)
        engine.stop()
        let callback = completion
        reset()
        if duration >= 0.05 { callback?(url) }
        else { try? FileManager.default.removeItem(at: url); error = L10n.tr("Record a little longer before saving.") }
    }

    func cancel() {
        let discarded = url
        engine?.stop(); reset()
        if let discarded { try? FileManager.default.removeItem(at: discarded) }
    }
    private func reset() {
        generation = UUID(); meterTask?.cancel(); meterTask = nil
        engine = nil; url = nil; completion = nil; phase = .idle; level = 0
    }
    private enum RecorderError: Error { case failed }
}
