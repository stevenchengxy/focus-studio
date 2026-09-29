import Foundation

/// Google's Gemini video API, separate from the text-completion gateway.
/// The REST shape follows https://ai.google.dev/gemini-api/docs/veo.
/// A Google API key is only sent to the configured Gemini host, never saved
/// next to generated media or included in user-visible errors.
struct VeoMediaClient: Sendable {
    static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    static let modelIDs = [
        "veo-3.1-generate-preview",
        "veo-3.1-fast-generate-preview",
        "veo-3.1-lite-generate-preview",
    ]

    struct ModelInfo: Sendable {
        let name: String
        let resolutions: [String]
        let supportsReferenceImages: Bool
        let usdPerSecond720p: Double
        let usdPerSecond1080p: Double
        let usdPerSecond4K: Double?

        func rate(for resolution: String) -> Double? {
            switch resolution {
            case "720p": usdPerSecond720p
            case "1080p": usdPerSecond1080p
            case "4k": usdPerSecond4K
            default: nil
            }
        }
    }

    static func modelInfo(for model: String) -> ModelInfo? {
        switch model {
        case "veo-3.1-generate-preview":
            return .init(name: "Veo 3.1", resolutions: ["720p", "1080p", "4k"],
                         supportsReferenceImages: true, usdPerSecond720p: 0.40,
                         usdPerSecond1080p: 0.40, usdPerSecond4K: 0.60)
        case "veo-3.1-fast-generate-preview":
            return .init(name: "Veo 3.1 Fast", resolutions: ["720p", "1080p", "4k"],
                         supportsReferenceImages: true, usdPerSecond720p: 0.10,
                         usdPerSecond1080p: 0.12, usdPerSecond4K: 0.30)
        case "veo-3.1-lite-generate-preview":
            return .init(name: "Veo 3.1 Lite", resolutions: ["720p", "1080p"],
                         supportsReferenceImages: false, usdPerSecond720p: 0.05,
                         usdPerSecond1080p: 0.08, usdPerSecond4K: nil)
        default:
            return nil
        }
    }

    static func displayName(forModel model: String) -> String {
        modelInfo(for: model)?.name ?? model
    }

    /// Google publishes per-second USD prices, including generated audio.
    static func estimateVideoCostUSD(model: String, resolution: String?, duration: Int) -> Double? {
        guard let rate = modelInfo(for: model)?.rate(for: resolution ?? "720p") else { return nil }
        return (rate * Double(duration) * 100).rounded() / 100
    }

    struct InlineImage: Equatable, Sendable {
        let mimeType: String
        let base64Data: String

        var payload: [String: Any] {
            ["inlineData": ["mimeType": mimeType, "data": base64Data]]
        }
    }

    /// AIToolPaths.mediaURL downscales local images to a data URL; Gemini
    /// expects an Image object, not Ark's data-URL string.
    static func inlineImage(from dataURL: String) throws -> InlineImage {
        guard dataURL.hasPrefix("data:image/"), let comma = dataURL.firstIndex(of: ",") else {
            throw VeoMediaError.invalidRequest("Veo image references must be local image files, not remote URLs.")
        }
        let header = String(dataURL[..<comma])
        let mediaType = String(header.dropFirst(5)).replacingOccurrences(of: ";base64", with: "")
        guard ["image/jpeg", "image/png", "image/webp"].contains(mediaType), header.hasSuffix(";base64") else {
            throw VeoMediaError.invalidRequest("Veo reference image must be a JPEG, PNG, or WebP file.")
        }
        let encoded = String(dataURL[dataURL.index(after: comma)...])
        guard let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= 4 * 1_024 * 1_024 else {
            throw VeoMediaError.invalidRequest("Veo reference image is empty or larger than 4 MB.")
        }
        return InlineImage(mimeType: mediaType, base64Data: encoded)
    }

    struct VideoTaskRequest: Sendable {
        var model: String
        let prompt: String
        var duration: Int
        let ratio: String
        var resolution: String
        var firstFrame: InlineImage?
        var lastFrame: InlineImage?
        var referenceImages: [InlineImage] = []
        var seed: Int?
    }

    static func videoPayload(_ request: VideoTaskRequest) throws -> [String: Any] {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw VeoMediaError.invalidRequest("prompt must not be empty") }
        guard let info = modelInfo(for: request.model) else {
            throw VeoMediaError.invalidRequest("Unknown Veo model ID: \(request.model)")
        }
        guard [4, 6, 8].contains(request.duration) else {
            throw VeoMediaError.invalidRequest("Veo 3.1 duration must be 4, 6, or 8 seconds.")
        }
        guard ["16:9", "9:16"].contains(request.ratio) else {
            throw VeoMediaError.invalidRequest("Veo 3.1 aspect ratio must be 16:9 or 9:16.")
        }
        guard info.resolutions.contains(request.resolution) else {
            throw VeoMediaError.invalidRequest("\(info.name) supports \(info.resolutions.joined(separator: "/")) only.")
        }
        if request.resolution != "720p" && request.duration != 8 {
            throw VeoMediaError.invalidRequest("Veo 1080p/4k generation requires 8 seconds.")
        }
        if request.lastFrame != nil && request.firstFrame == nil {
            throw VeoMediaError.invalidRequest("Veo last_frame requires first_frame.")
        }
        if !request.referenceImages.isEmpty {
            guard info.supportsReferenceImages else {
                throw VeoMediaError.invalidRequest("\(info.name) does not support reference_images.")
            }
            guard request.referenceImages.count <= 3 else {
                throw VeoMediaError.invalidRequest("Veo reference_images accepts at most 3 images.")
            }
            guard request.duration == 8 else {
                throw VeoMediaError.invalidRequest("Veo reference_images requires 8 seconds.")
            }
        }
        var instance: [String: Any] = ["prompt": prompt]
        if let firstFrame = request.firstFrame { instance["image"] = firstFrame.payload }
        if let lastFrame = request.lastFrame { instance["lastFrame"] = lastFrame.payload }
        if !request.referenceImages.isEmpty {
            instance["referenceImages"] = request.referenceImages.map {
                ["image": $0.payload, "referenceType": "asset"] as [String: Any]
            }
        }
        var parameters: [String: Any] = [
            "durationSeconds": String(request.duration),
            "aspectRatio": request.ratio,
            "resolution": request.resolution,
        ]
        if let seed = request.seed { parameters["seed"] = seed }
        return ["instances": [instance], "parameters": parameters]
    }

    let baseURL: URL
    let session: URLSession
    var pollingDelay: TimeInterval = 10
    var pollingTimeout: TimeInterval = 1_800
    private let apiKey: String

    init(apiKey: String, baseURL: URL = defaultBaseURL, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    func createVideoTask(_ task: VideoTaskRequest) async throws -> String {
        let payload = try Self.videoPayload(task)
        let result = try await request(
            "POST", path: "models/\(task.model):predictLongRunning", payload: payload
        )
        guard let name = result["name"] as? String, Self.safeOperationName(name) else {
            throw VeoMediaError.invalidResponse("Google did not return a valid operation name.")
        }
        return name
    }

    struct CompletedVideo: Sendable {
        let operationName: String
        let videoURL: String
    }

    func waitForTask(
        name: String,
        progress: @escaping @Sendable (TimeInterval) -> Void = { _ in }
    ) async throws -> CompletedVideo {
        guard Self.safeOperationName(name) else {
            throw VeoMediaError.invalidRequest("Invalid Veo operation name.")
        }
        let start = Date()
        while true {
            try Task.checkCancellation()
            let result = try await request("GET", path: name, payload: nil)
            let elapsed = Date().timeIntervalSince(start)
            progress(elapsed)
            if result["done"] as? Bool == true {
                if let error = result["error"] as? [String: Any] {
                    let code = (error["code"] as? NSNumber)?.stringValue ?? "unknown"
                    let message = error["message"] as? String ?? "Video generation failed."
                    throw VeoMediaError.taskFailed(code: code, message: redact(message))
                }
                guard let response = result["response"] as? [String: Any],
                      let videoResponse = response["generateVideoResponse"] as? [String: Any],
                      let samples = videoResponse["generatedSamples"] as? [[String: Any]],
                      let video = samples.first?["video"] as? [String: Any],
                      let uri = video["uri"] as? String, !uri.isEmpty else {
                    throw VeoMediaError.invalidResponse("Completed Veo operation has no downloadable video.")
                }
                return CompletedVideo(operationName: name, videoURL: uri)
            }
            guard elapsed < pollingTimeout else {
                throw VeoMediaError.timeout(seconds: pollingTimeout)
            }
            try await Task.sleep(nanoseconds: UInt64(max(0.01, pollingDelay) * 1_000_000_000))
        }
    }

    func download(_ uri: String, to destination: URL) async throws {
        guard let url = URL(string: uri), url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http",
              url.host?.lowercased() == baseURL.host?.lowercased() else {
            throw VeoMediaError.invalidResponse("Veo returned a media URL outside the configured Gemini API host.")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 300
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (temporary, response) = try await session.download(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw VeoMediaError.invalidResponse("Veo download failed with HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        let bytes = try Data(contentsOf: temporary, options: .mappedIfSafe)
        guard bytes.count >= 12, String(data: bytes.subdata(in: 4..<8), encoding: .ascii) == "ftyp" else {
            try? FileManager.default.removeItem(at: temporary)
            throw VeoMediaError.invalidResponse("Veo returned data that is not an MP4 video.")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private static func safeOperationName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 2 && !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            && (name.hasPrefix("operations/") || (name.hasPrefix("models/") && name.contains("/operations/")))
            && name.range(of: #"^[A-Za-z0-9_./:-]+$"#, options: .regularExpression) != nil
    }

    private func request(_ method: String, path: String, payload: [String: Any]?) async throws -> [String: Any] {
        guard !path.hasPrefix("/"), !path.contains("..") else {
            throw VeoMediaError.invalidRequest("Invalid Gemini API path.")
        }
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 120
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let payload { req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw VeoMediaError.invalidResponse("Gemini API returned no HTTP status.")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if !(200..<300).contains(http.statusCode) {
            let error = object?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "HTTP \(http.statusCode)"
            throw VeoMediaError.api(status: http.statusCode, message: redact(message))
        }
        guard let object else {
            throw VeoMediaError.invalidResponse("Gemini API returned non-JSON data.")
        }
        return object
    }

    private func redact(_ message: String) -> String {
        guard !apiKey.isEmpty else { return message }
        return message.replacingOccurrences(of: apiKey, with: "***")
    }
}

enum VeoMediaError: LocalizedError, Equatable {
    case invalidRequest(String)
    case invalidResponse(String)
    case api(status: Int, message: String)
    case taskFailed(code: String, message: String)
    case timeout(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): return message
        case .invalidResponse(let message): return message
        case .api(let status, let message): return "Gemini API HTTP \(status): \(message)"
        case .taskFailed(let code, let message): return "Veo generation failed (\(code)): \(message)"
        case .timeout(let seconds): return "Veo generation did not finish within \(Int(seconds)) seconds."
        }
    }
}
