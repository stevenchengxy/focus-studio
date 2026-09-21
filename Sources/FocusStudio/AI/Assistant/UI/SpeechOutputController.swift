import AVFoundation
import Foundation

/// Optional spoken replies through AVSpeechSynthesizer. Off by default and
/// persisted in UserDefaults; the avatar follows `isSpeaking` and pulses on
/// every spoken word through `activityLevel`.
@MainActor
final class SpeechOutputController: NSObject, ObservableObject {
    static let defaultsKey = "assistant.voiceReplies"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.defaultsKey) }
    }
    @Published private(set) var isSpeaking = false
    /// 0…1: peaks at each word boundary and decays, a stand-in for an audio level.
    @Published private(set) var activityLevel: Double = 0

    private let synthesizer = AVSpeechSynthesizer()
    private var decayTask: Task<Void, Never>?

    override init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        super.init()
        synthesizer.delegate = self
    }

    /// Voice for the UI language ("zh-Hans" → zh-CN, else en-US).
    static func languageCode(for language: String) -> String {
        language.lowercased().hasPrefix("zh") ? "zh-CN" : "en-US"
    }

    func speak(_ text: String) {
        let spoken = Self.spokenText(text)
        guard !spoken.isEmpty else { return }
        stop()
        let language = Self.languageCode(for: AppLocalization.shared.language.localeIdentifier)
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = Self.voice(for: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        utterance.pitchMultiplier = 1.05
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
    }

    func stop() {
        decayTask?.cancel()
        decayTask = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        activityLevel = 0
    }

    /// The best installed voice for the language: premium, then enhanced, then default.
    static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let matching = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.caseInsensitiveCompare(language) == .orderedSame
        }
        let ranked = matching.sorted { $0.quality.rawValue > $1.quality.rawValue }
        return ranked.first ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Replies read badly when they contain file paths or Markdown marks:
    /// keep file names only and drop emphasis characters.
    static func spokenText(_ text: String) -> String {
        var output = text
        if let paths = try? NSRegularExpression(pattern: "(?<=^|\\s)(?:~|/)[^\\s\"'`)]*/([^\\s\"'`)/]+)") {
            output = paths.stringByReplacingMatches(
                in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "$1"
            )
        }
        output = output.replacingOccurrences(of: "[*_`#]+", with: "", options: .regularExpression)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pulse() {
        activityLevel = 1
        decayTask?.cancel()
        decayTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            self?.activityLevel = 0.2
        }
    }
}

extension SpeechOutputController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.activityLevel = 0
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.activityLevel = 0
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.pulse() }
    }
}
