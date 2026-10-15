import Foundation

/// Speech credentials and models are independent from the assistant's chat model.
public enum SpeechProviderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case minimax
    case openAI
    case openAICompatible

    public var title: String {
        switch self {
        case .minimax: return "MiniMax"
        case .openAI: return "OpenAI"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }
    public var defaultBaseURL: String {
        switch self {
        case .minimax: return "https://api.minimax.io/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .openAICompatible: return ""
        }
    }
    public var defaultModel: String {
        switch self {
        case .minimax: return "speech-2.8-hd"
        case .openAI: return "gpt-4o-mini-tts"
        case .openAICompatible: return ""
        }
    }
    public var defaultVoice: String {
        switch self {
        case .minimax: return "English_expressive_narrator"
        case .openAI: return "coral"
        case .openAICompatible: return ""
        }
    }
}

public struct SpeechGenerationConfiguration: Codable, Equatable, Sendable {
    public var provider: SpeechProviderKind
    public var baseURL: String
    public var model: String
    public var voice: String

    /// Nil uses a provider default. Explicit values, including an invalid blank
    /// value, are never silently replaced with a different model or voice.
    public init(provider: SpeechProviderKind = .minimax, baseURL: String? = nil,
                model: String? = nil, voice: String? = nil) {
        self.provider = provider
        self.baseURL = baseURL ?? provider.defaultBaseURL
        self.model = model ?? provider.defaultModel
        self.voice = voice ?? provider.defaultVoice
    }
}

public struct SpeechGenerationRequest: Sendable {
    public var text: String
    public var configuration: SpeechGenerationConfiguration
    public var speed: Double

    public init(text: String, configuration: SpeechGenerationConfiguration, speed: Double = 1) {
        self.text = text; self.configuration = configuration; self.speed = speed
    }
}

/// Timing is intentionally absent. The editor measures the actual saved audio;
/// providers without alignment must not appear to have word-level timestamps.
public struct SpeechGenerationResult: Sendable {
    public let audioData: Data
    public let fileExtension: String

    public init(audioData: Data, fileExtension: String = "mp3") {
        self.audioData = audioData; self.fileExtension = fileExtension
    }
}

public enum SpeechGenerationError: Error, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case invalidRequest(String)
    case missingAPIKey
    case httpStatus(Int, String)
    case providerFailure(Int, String)
    case invalidResponse(String)
    case responseTooLarge
    case network(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message), let .invalidRequest(message): return message
        case .missingAPIKey: return "Add a narration API key in Settings › AI models."
        case let .httpStatus(code, message): return "Speech provider HTTP \(code)" + (message.isEmpty ? "." : ": \(message)")
        case let .providerFailure(code, message): return "Speech provider error \(code)" + (message.isEmpty ? "." : ": \(message)")
        case let .invalidResponse(message): return "Invalid speech response: \(message)"
        case .responseTooLarge: return "The speech response is too large. Generate shorter narration segments."
        case let .network(message): return "Speech connection failed: \(message)"
        }
    }
}

/// A bounded, non-streaming speech request. No automatic retries: a lost response
/// may already have been billed by a provider. Never retain or log API keys.
public actor SpeechGenerationService {
    private let session: URLSession
    private static let maximumResponseBytes = 32 * 1_024 * 1_024
    private static let maximumAudioBytes = 16 * 1_024 * 1_024

    public init(session: URLSession = .shared) { self.session = session }

    public nonisolated static func validate(configuration: SpeechGenerationConfiguration) throws {
        let parts = URLComponents(string: configuration.baseURL)
        let host = parts?.host?.lowercased() ?? ""
        let scheme = parts?.scheme?.lowercased() ?? ""
        let local = configuration.provider == .openAICompatible
            && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard let parts, parts.url != nil, !host.isEmpty,
              scheme == "https" || (scheme == "http" && local),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw SpeechGenerationError.invalidConfiguration("Use an HTTPS narration base URL without credentials or query parameters. Local compatible servers may use HTTP on loopback.")
        }
        for (label, value) in [("model", configuration.model), ("voice", configuration.voice)] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= 256, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw SpeechGenerationError.invalidConfiguration("Choose a valid narration \(label) in Settings › AI models.")
            }
        }
    }

    public func generate(request input: SpeechGenerationRequest, apiKey: String) async throws -> SpeechGenerationResult {
        try Task.checkCancellation()
        try Self.validate(configuration: input.configuration)
        let config = input.configuration
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty || config.provider == .openAICompatible else { throw SpeechGenerationError.missingAPIKey }
        guard !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SpeechGenerationError.invalidConfiguration("The narration API key contains invalid characters.")
        }
        let limit = config.provider == .minimax ? 9_999 : 4_096
        guard !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.text.count <= limit else {
            throw SpeechGenerationError.invalidRequest("Narration text must contain 1–\(limit) characters per segment.")
        }
        let speeds: ClosedRange<Double> = config.provider == .minimax ? 0.5...2 : 0.25...4
        guard input.speed.isFinite, speeds.contains(input.speed) else {
            throw SpeechGenerationError.invalidRequest("Narration speed must be between \(speeds.lowerBound) and \(speeds.upperBound).")
        }
        let base = URL(string: config.baseURL)!
        let endpoint = base.appendingPathComponent(config.provider == .minimax ? "t2a_v2" : "audio/speech")
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.provider == .minimax ? "application/json" : "audio/mpeg", forHTTPHeaderField: "Accept")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let payload: [String: Any]
        switch config.provider {
        case .minimax:
            payload = ["model": config.model, "text": input.text, "stream": false, "output_format": "hex",
                       "voice_setting": ["voice_id": config.voice, "speed": input.speed, "vol": 1, "pitch": 0],
                       "audio_setting": ["sample_rate": 32_000, "bitrate": 128_000, "format": "mp3", "channel": 1]]
        case .openAI, .openAICompatible:
            payload = ["model": config.model, "input": input.text, "voice": config.voice,
                       "speed": input.speed, "response_format": "mp3"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        do {
            // A redirect never receives the bearer credential, including a
            // same-origin redirect to a different service path.
            let (bytes, response) = try await session.bytes(for: request, delegate: SpeechRedirectRefuser())
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw SpeechGenerationError.invalidResponse("Missing HTTP response.") }
            let succeeded = (200...299).contains(http.statusCode)
            let maximum = succeeded ? Self.maximumResponseBytes : 8_192
            if succeeded, response.expectedContentLength > Int64(maximum) { throw SpeechGenerationError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                if data.count >= maximum {
                    if succeeded { throw SpeechGenerationError.responseTooLarge }
                    break
                }
                data.append(byte)
                if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            guard succeeded else { throw SpeechGenerationError.httpStatus(http.statusCode, Self.failureMessage(data, key: key)) }
            let audio = try Self.audioData(data, provider: config.provider, apiKey: key)
            guard audio.count <= Self.maximumAudioBytes else { throw SpeechGenerationError.responseTooLarge }
            // Catch JSON/HTML error pages and empty responses before creating
            // a misleading .mp3 file. AVFoundation verifies playback on import.
            let header = Array(audio.prefix(3))
            guard header.count == 3,
                  header == [0x49, 0x44, 0x33] || (header[0] == 0xff && header[1] & 0xe0 == 0xe0) else {
                throw SpeechGenerationError.invalidResponse("The provider did not return MP3 audio.")
            }
            return SpeechGenerationResult(audioData: audio)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as SpeechGenerationError {
            throw error
        } catch {
            throw SpeechGenerationError.network(Self.redact(error.localizedDescription, key: key))
        }
    }

    private static func audioData(_ data: Data, provider: SpeechProviderKind, apiKey: String) throws -> Data {
        guard provider == .minimax else { return data }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["base_resp"] as? [String: Any], let code = status["status_code"] as? Int else {
            throw SpeechGenerationError.invalidResponse("MiniMax did not return a result status.")
        }
        guard code == 0 else {
            throw SpeechGenerationError.providerFailure(code, redact(status["status_msg"] as? String ?? "", key: apiKey))
        }
        guard let body = root["data"] as? [String: Any], let hex = body["audio"] as? String,
              !hex.isEmpty, hex.utf8.count.isMultiple(of: 2), hex.utf8.count <= maximumAudioBytes * 2 else {
            throw SpeechGenerationError.invalidResponse("MiniMax did not return hex-encoded audio.")
        }
        let digits = Array(hex.utf8)
        func nibble(_ digit: UInt8) -> UInt8? {
            switch digit {
            case 48...57: return digit - 48
            case 65...70: return digit - 55
            case 97...102: return digit - 87
            default: return nil
            }
        }
        var audio = Data(capacity: digits.count / 2)
        for i in stride(from: 0, to: digits.count, by: 2) {
            if i.isMultiple(of: 16_384) { try Task.checkCancellation() }
            guard let high = nibble(digits[i]), let low = nibble(digits[i + 1]) else {
                throw SpeechGenerationError.invalidResponse("MiniMax returned malformed audio hex.")
            }
            audio.append(high << 4 | low)
        }
        return audio
    }

    private static func failureMessage(_ data: Data, key: String) -> String {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let error = body["error"] as? [String: Any]
        let base = body["base_resp"] as? [String: Any]
        return redact(error?["message"] as? String ?? base?["status_msg"] as? String ?? "", key: key)
    }

    private static func redact(_ message: String, key: String) -> String {
        var clean = key.isEmpty ? message : message.replacingOccurrences(of: key, with: "[redacted]")
        clean = clean.replacingOccurrences(of: "(?i)Bearer\\s+[^\\s\"',;]+", with: "Bearer [redacted]", options: .regularExpression)
        return String(clean.replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression).prefix(400))
    }
}

private final class SpeechRedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
