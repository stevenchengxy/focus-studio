import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Volcengine Ark (火山方舟) media generation: Seedream images and Seedance
/// video tasks. A port of `skills/_shared/ark_client.py`, which was verified
/// against the live API; request and response shapes are kept identical.
///
/// The API key never appears in errors, logs or saved files.
struct ArkMediaClient: Sendable {
    static let defaultBaseURL = URL(string: "https://ark.cn-beijing.volces.com/api/v3")!
    static let userAgent = "focus-studio/1.0 (assistant)"

    static let defaultVideoModel = "doubao-seedance-2-0-mini-260615"
    static let defaultImageModel = "doubao-seedream-4-5-251128"

    static let videoRatios = ["16:9", "9:16", "1:1", "4:3", "3:4", "21:9", "adaptive"]
    static let videoResolutions = ["480p", "720p", "1080p"]
    static let imageRoles = ["first_frame", "last_frame", "reference_image"]
    static let videoRoles = ["reference_video"]
    static let audioRoles = ["reference_audio"]

    let baseURL: URL
    let session: URLSession
    var timeout: TimeInterval = 120
    var retries = 2
    /// Polling starts at `pollingInitialDelay` and grows by 1.5× up to `pollingMaximumDelay`.
    var pollingInitialDelay: TimeInterval = 5
    var pollingMaximumDelay: TimeInterval = 20
    var pollingTimeout: TimeInterval = 1_800

    private let apiKey: String

    init(apiKey: String, baseURL: URL = ArkMediaClient.defaultBaseURL, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Model catalogue and pricing

    struct VideoModelInfo: Sendable {
        let family: String
        let resolutions: [String]
        let durations: ClosedRange<Int>
        let supportsAudio: Bool
        /// 人民币 per 1,000 output tokens; estimates for budgeting only.
        let yuanPerKiloToken: Double
        let tier: String
    }

    struct ImageModelInfo: Sendable {
        let yuanPerImage: Double
        /// Minimum output pixel count the model accepts.
        let minimumPixels: Int
        let tier: String
    }

    /// Verified with GET /models on 2026-09-21. Keys omit the date suffix so
    /// newer builds of the same model still match.
    static let videoModels: [String: VideoModelInfo] = [
        "doubao-seedance-2-5": VideoModelInfo(family: "Seedance 2.5", resolutions: ["480p", "720p", "1080p"], durations: 4...15, supportsAudio: true, yuanPerKiloToken: 0.046, tier: "flagship"),
        "doubao-seedance-2-0-mini": VideoModelInfo(family: "Seedance 2.0 mini", resolutions: ["480p", "720p"], durations: 4...15, supportsAudio: true, yuanPerKiloToken: 0.023, tier: "budget"),
        "doubao-seedance-2-0-fast": VideoModelInfo(family: "Seedance 2.0 fast", resolutions: ["480p", "720p", "1080p"], durations: 4...15, supportsAudio: true, yuanPerKiloToken: 0.035, tier: "fast"),
        "doubao-seedance-2-0": VideoModelInfo(family: "Seedance 2.0", resolutions: ["480p", "720p", "1080p"], durations: 4...15, supportsAudio: true, yuanPerKiloToken: 0.046, tier: "quality"),
        "doubao-seedance-1-0-pro-fast": VideoModelInfo(family: "Seedance 1.0 pro fast", resolutions: ["480p", "720p", "1080p"], durations: 2...12, supportsAudio: false, yuanPerKiloToken: 0.010, tier: "legacy-fast"),
        "doubao-seedance-1-0-pro": VideoModelInfo(family: "Seedance 1.0 pro", resolutions: ["480p", "720p", "1080p"], durations: 2...12, supportsAudio: false, yuanPerKiloToken: 0.015, tier: "legacy"),
    ]

    static let imageModels: [String: ImageModelInfo] = [
        "doubao-seedream-5-0-pro": ImageModelInfo(yuanPerImage: 0.35, minimumPixels: 3_686_400, tier: "flagship"),
        "doubao-seedream-5-0": ImageModelInfo(yuanPerImage: 0.30, minimumPixels: 3_686_400, tier: "quality"),
        "doubao-seedream-4-5": ImageModelInfo(yuanPerImage: 0.25, minimumPixels: 3_686_400, tier: "default"),
        "doubao-seedream-4-0": ImageModelInfo(yuanPerImage: 0.20, minimumPixels: 921_600, tier: "budget"),
    ]

    static func videoModelInfo(for model: String) -> VideoModelInfo? {
        longestPrefixMatch(model, in: videoModels)
    }

    static func imageModelInfo(for model: String) -> ImageModelInfo? {
        longestPrefixMatch(model, in: imageModels)
    }

    private static func longestPrefixMatch<Value>(_ model: String, in table: [String: Value]) -> Value? {
        let normalized = model.lowercased()
        var best: (key: String, value: Value)?
        for (key, value) in table where normalized == key || normalized.hasPrefix(key + "-") {
            if best == nil || key.count > best!.key.count { best = (key, value) }
        }
        return best?.value
    }

    /// Human-readable model name for cost summaries ("Seedance 2.0 mini").
    static func displayName(forModel model: String) -> String {
        if let info = videoModelInfo(for: model) { return info.family }
        if imageModelInfo(for: model) != nil {
            let parts = model.lowercased().split(separator: "-")
            if parts.count >= 4, parts[1] == "seedream" {
                return "Seedream \(parts[2]).\(parts[3])" + (parts.count > 4 && parts[4] == "pro" ? " pro" : "")
            }
        }
        return model
    }

    /// Output pixel size used for token estimates. Widths mirror the Python table for 16:9.
    static func outputPixelSize(resolution: String, ratio: String) -> (width: Int, height: Int) {
        let short: Int
        switch resolution.lowercased() {
        case "480p": short = 480
        case "1080p": short = 1080
        case "4k": short = 2160
        default: short = 720
        }
        let normalizedRatio = ratio == "adaptive" ? "16:9" : ratio
        let parts = normalizedRatio.split(separator: ":").compactMap { Double($0) }
        let value = parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : 16.0 / 9.0
        if normalizedRatio == "16:9" || normalizedRatio == "9:16" {
            let long: Int
            switch short {
            case 480: long = 864
            case 1080: long = 1_920
            case 2160: long = 3_840
            default: long = 1_280
            }
            return value >= 1 ? (long, short) : (short, long)
        }
        if value >= 1 { return (Int((Double(short) * value).rounded()), short) }
        return (short, Int((Double(short) / value).rounded()))
    }

    /// Ark bills video by tokens ≈ width × height × fps × seconds / 1024.
    static func estimateVideoTokens(width: Int, height: Int, fps: Int = 24, duration: Double) -> Int {
        Int((Double(width) * Double(height) * Double(fps) * duration / 1_024).rounded())
    }

    struct VideoCostEstimate: Equatable, Sendable {
        let model: String
        let resolution: String
        let ratio: String
        let duration: Double
        let tokens: Int
        let yuanPerKiloToken: Double?
        /// Nil when the model is unknown.
        let yuan: Double?
        let multiplier: Double
    }

    /// Reference video/audio and generated audio cost about 1.7× the plain rate.
    static func estimateVideoCost(
        model: String,
        resolution: String?,
        ratio: String,
        duration: Double,
        usesAudioOrReferenceMedia: Bool
    ) -> VideoCostEstimate {
        let effectiveResolution = resolution ?? "720p"
        let size = outputPixelSize(resolution: effectiveResolution, ratio: ratio)
        let multiplier = usesAudioOrReferenceMedia ? 1.7 : 1.0
        let tokens = Int((Double(estimateVideoTokens(width: size.width, height: size.height, duration: duration)) * multiplier).rounded())
        let rate = videoModelInfo(for: model)?.yuanPerKiloToken
        let yuan = rate.map { (Double(tokens) / 1_000 * $0 * 1_000).rounded() / 1_000 }
        return VideoCostEstimate(
            model: model, resolution: effectiveResolution, ratio: ratio, duration: duration,
            tokens: tokens, yuanPerKiloToken: rate, yuan: yuan, multiplier: multiplier
        )
    }

    static func estimateImageCost(model: String, count: Int = 1) -> Double? {
        guard let info = imageModelInfo(for: model) else { return nil }
        return info.yuanPerImage * Double(max(1, count))
    }

    /// Best-effort cost from a real `usage` block.
    static func cost(forModel model: String, usage: ArkUsage?) -> Double? {
        guard let usage else { return nil }
        if let info = videoModelInfo(for: model), let tokens = usage.completionTokens ?? usage.totalTokens {
            return (Double(tokens) / 1_000 * info.yuanPerKiloToken * 1_000).rounded() / 1_000
        }
        if let info = imageModelInfo(for: model) {
            return info.yuanPerImage * Double(max(1, usage.generatedImages ?? 1))
        }
        return nil
    }

    /// Default Seedream sizes per aspect ratio. All satisfy the 4.5/5.0
    /// minimum of 3,686,400 pixels (2560×1440) and the 4.0 minimum.
    static func defaultImageSize(ratio: String) -> String {
        switch ratio {
        case "9:16": return "1440x2560"
        case "1:1": return "2048x2048"
        case "4:3": return "2304x1728"
        case "3:4": return "1728x2304"
        default: return "2560x1440"
        }
    }

    // MARK: - Payloads

    struct MediaReference: Equatable, Sendable {
        let url: String
        let role: String
    }

    struct VideoTaskRequest: Equatable, Sendable {
        var model: String
        var prompt: String
        var images: [MediaReference] = []
        var videos: [MediaReference] = []
        var audios: [MediaReference] = []
        var resolution: String?
        var ratio: String?
        var duration: Int?
        var generateAudio: Bool?
        var watermark: Bool? = false
        var seed: Int?
        var cameraFixed: Bool?

        init(model: String, prompt: String) {
            self.model = model
            self.prompt = prompt
        }
    }

    /// Body for `POST /contents/generations/tasks`. Content order is preserved
    /// (text, images, videos, audios): the prompt refers to 图片1/视频1/音频1 in that order.
    static func videoPayload(_ request: VideoTaskRequest) throws -> [String: Any] {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ArkMediaError.invalidRequest("prompt must not be empty") }
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for image in request.images {
            guard imageRoles.contains(image.role) else {
                throw ArkMediaError.invalidRequest("unknown image role \(image.role); expected one of \(imageRoles.joined(separator: ", "))")
            }
            content.append(["type": "image_url", "image_url": ["url": image.url], "role": image.role])
        }
        for video in request.videos {
            guard videoRoles.contains(video.role) else {
                throw ArkMediaError.invalidRequest("unknown video role \(video.role); expected reference_video")
            }
            content.append(["type": "video_url", "video_url": ["url": video.url], "role": video.role])
        }
        for audio in request.audios {
            guard audioRoles.contains(audio.role) else {
                throw ArkMediaError.invalidRequest("unknown audio role \(audio.role); expected reference_audio")
            }
            content.append(["type": "audio_url", "audio_url": ["url": audio.url], "role": audio.role])
        }
        var payload: [String: Any] = ["model": request.model, "content": content]
        if let resolution = request.resolution { payload["resolution"] = resolution }
        if let ratio = request.ratio { payload["ratio"] = ratio }
        if let duration = request.duration { payload["duration"] = duration }
        if let generateAudio = request.generateAudio { payload["generate_audio"] = generateAudio }
        if let watermark = request.watermark { payload["watermark"] = watermark }
        if let seed = request.seed { payload["seed"] = seed }
        if let cameraFixed = request.cameraFixed { payload["camera_fixed"] = cameraFixed }
        return payload
    }

    /// Body for `POST /images/generations` (Seedream 4.x / 5.x).
    static func imagePayload(
        model: String,
        prompt: String,
        size: String,
        referenceImages: [String] = [],
        watermark: Bool = false,
        responseFormat: String = "url",
        seed: Int? = nil
    ) throws -> [String: Any] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ArkMediaError.invalidRequest("prompt must not be empty") }
        var payload: [String: Any] = [
            "model": model,
            "prompt": trimmed,
            "size": size,
            "response_format": responseFormat,
            "watermark": watermark,
            "sequential_image_generation": "disabled",
        ]
        if referenceImages.count == 1 {
            payload["image"] = referenceImages[0]
        } else if referenceImages.count > 1 {
            payload["image"] = referenceImages
        }
        if let seed { payload["seed"] = seed }
        return payload
    }

    // MARK: - Images

    struct ImageGenerationResult: Equatable, Sendable {
        let url: String?
        let base64JSON: String?
        let size: String?
        let usage: ArkUsage?
    }

    func generateImage(
        model: String,
        prompt: String,
        size: String = "2560x1440",
        referenceImages: [String] = [],
        watermark: Bool = false,
        responseFormat: String = "url",
        seed: Int? = nil
    ) async throws -> ImageGenerationResult {
        let payload = try Self.imagePayload(
            model: model, prompt: prompt, size: size, referenceImages: referenceImages,
            watermark: watermark, responseFormat: responseFormat, seed: seed
        )
        let response = try await request("POST", path: "images/generations", payload: payload, timeout: max(timeout, 300), retryOn5xx: false)
        if let error = response["error"] as? [String: Any] {
            throw ArkMediaError.api(status: 200, code: string(error["code"]) ?? "", message: redact(string(error["message"]) ?? ""))
        }
        guard let items = response["data"] as? [[String: Any]], let first = items.first else {
            throw ArkMediaError.invalidResponse("image response has no data: \(Self.excerpt(response))")
        }
        let usage = ArkUsage(response["usage"] as? [String: Any])
        return ImageGenerationResult(
            url: string(first["url"]),
            base64JSON: string(first["b64_json"]),
            size: string(first["size"]),
            usage: usage
        )
    }

    /// Writes the generated image to `destination` (from its URL or inline base64).
    func saveImage(_ result: ImageGenerationResult, to destination: URL) async throws {
        if let url = result.url {
            try await download(url, to: destination)
        } else if let base64 = result.base64JSON, let data = Data(base64Encoded: base64) {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } else {
            throw ArkMediaError.invalidResponse("image item has neither url nor b64_json")
        }
    }

    // MARK: - Video tasks

    func createVideoTask(payload: [String: Any]) async throws -> String {
        let response = try await request("POST", path: "contents/generations/tasks", payload: payload, retryOn5xx: false)
        guard let id = string(response["id"]), !id.isEmpty else {
            throw ArkMediaError.invalidResponse("unexpected create response: \(Self.excerpt(response))")
        }
        return id
    }

    func createVideoTask(_ request: VideoTaskRequest) async throws -> String {
        try await createVideoTask(payload: try Self.videoPayload(request))
    }

    func getTask(id: String) async throws -> ArkTask {
        let response = try await request("GET", path: "contents/generations/tasks/\(Self.pathEncoded(id))", payload: nil)
        return ArkTask(response, fallbackID: id)
    }

    @discardableResult
    func cancelTask(id: String) async throws -> ArkTask {
        let response = try await request("DELETE", path: "contents/generations/tasks/\(Self.pathEncoded(id))", payload: nil)
        return ArkTask(response, fallbackID: id)
    }

    /// Polls until the task succeeds (returned) or fails (thrown). Cancelling
    /// the surrounding task also asks Ark to cancel the generation.
    func waitForTask(
        id: String,
        progress: @escaping @Sendable (ArkTask, TimeInterval) -> Void = { _, _ in }
    ) async throws -> ArkTask {
        let start = Date()
        var delay = pollingInitialDelay
        while true {
            let task: ArkTask
            do {
                task = try await getTask(id: id)
            } catch is CancellationError {
                await cancelQuietly(id: id)
                throw CancellationError()
            }
            let elapsed = Date().timeIntervalSince(start)
            progress(task, elapsed)
            switch task.status {
            case "succeeded":
                return task
            case "failed", "cancelled", "canceled", "expired":
                throw ArkMediaError.taskFailed(id: id, status: task.status, code: task.errorCode ?? "", message: redact(task.errorMessage ?? ""))
            default:
                break
            }
            if elapsed > pollingTimeout {
                throw ArkMediaError.timeout(id: id, status: task.status, seconds: pollingTimeout)
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            } catch {
                await cancelQuietly(id: id)
                throw CancellationError()
            }
            delay = min(pollingMaximumDelay, delay * 1.5)
        }
    }

    /// Best-effort DELETE from a fresh task, so it still goes out after the
    /// polling task itself was cancelled.
    private func cancelQuietly(id: String) async {
        let client = self
        _ = await Task { try? await client.cancelTask(id: id) }.value
    }

    // MARK: - Downloads

    /// Streams a (temporary, signed) result URL to `destination`. Data URLs are decoded inline.
    func download(_ urlString: String, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if urlString.hasPrefix("data:") {
            guard let comma = urlString.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(urlString[urlString.index(after: comma)...]))
            else { throw ArkMediaError.invalidResponse("malformed data URL") }
            try data.write(to: destination, options: .atomic)
            return
        }
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw ArkMediaError.invalidResponse("result URL is not http(s): \(urlString.prefix(80))")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw ArkMediaError.api(status: http.statusCode, code: "download_failed", message: "download returned HTTP \(http.statusCode)")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        }
    }

    // MARK: - Local files as data URLs

    /// Encodes a local image as `data:image/jpeg;base64,…`, downscaled to
    /// `maxSide` pixels and kept under `maxBytes` (Ark rejects very large inline images).
    static func imageDataURL(for fileURL: URL, maxSide: Int = 2_048, maxBytes: Int = 4 * 1_024 * 1_024) throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw ArkMediaError.fileNotFound(fileURL.path) }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ArkMediaError.unreadableImage(fileURL.path)
        }
        var side = maxSide
        var quality = 0.92
        while true {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ArkMediaError.unreadableImage(fileURL.path)
            }
            let data = try jpegData(image, quality: quality)
            if data.count * 4 / 3 <= maxBytes || (quality <= 0.4 && side <= 512) {
                return "data:image/jpeg;base64," + data.base64EncodedString()
            }
            if quality > 0.4 {
                quality -= 0.1
            } else {
                side = max(512, side * 3 / 4)
                quality = 0.8
            }
        }
    }

    /// Small local videos and audio files can be inlined the same way.
    static func fileDataURL(for fileURL: URL, mimeType: String, maxBytes: Int) throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw ArkMediaError.fileNotFound(fileURL.path) }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= maxBytes else {
            throw ArkMediaError.invalidRequest("\(fileURL.lastPathComponent) is \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)); files over \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)) must be given as an http(s) URL")
        }
        return "data:\(mimeType);base64," + data.base64EncodedString()
    }

    static func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ArkMediaError.invalidRequest("could not create a JPEG encoder")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ArkMediaError.invalidRequest("JPEG encoding failed") }
        return data as Data
    }

    /// Writes any readable image as PNG (Ark usually returns JPEG).
    static func writePNG(from sourceURL: URL, to destination: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ArkMediaError.unreadableImage(sourceURL.path) }
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ArkMediaError.invalidRequest("could not create a PNG encoder")
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw ArkMediaError.invalidRequest("PNG encoding failed") }
        return (image.width, image.height)
    }

    static func imagePixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    // MARK: - HTTP

    private func request(
        _ method: String,
        path: String,
        payload: [String: Any]?,
        timeout requestTimeout: TimeInterval? = nil,
        retryOn5xx: Bool = true
    ) async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent(path)
        var body: Data?
        if let payload {
            body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        }
        var attempt = 0
        while true {
            attempt += 1
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = requestTimeout ?? timeout
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = body

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                if attempt <= retries {
                    try await Task.sleep(nanoseconds: UInt64(min(30, pow(2, Double(attempt))) * 1_000_000_000))
                    continue
                }
                throw ArkMediaError.network(redact(error.localizedDescription))
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                if data.isEmpty { return [:] }
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ArkMediaError.invalidResponse("non-JSON reply (\(data.count) bytes)")
                }
                return object
            }
            let (code, message) = Self.parseError(data)
            let transient = status == 429 || (retryOn5xx && (500..<600).contains(status))
            if transient && attempt <= retries {
                try await Task.sleep(nanoseconds: UInt64(min(30, pow(2, Double(attempt))) * 1_000_000_000))
                continue
            }
            var hint = ""
            if code == "ModelNotOpen" {
                hint = " This model is not activated for the account: open the Ark console (开通管理 / 模型广场) and activate it. Nothing was billed."
            } else if code.hasPrefix("InvalidEndpointOrModel") {
                hint = " Unknown model id for this account or region."
            } else if status == 401 {
                hint = " The API key was rejected: check the Volcengine Ark key in Settings."
            }
            throw ArkMediaError.api(status: status, code: code.isEmpty ? "http_error" : code, message: redact(message) + hint)
        }
    }

    private static func parseError(_ data: Data) -> (code: String, message: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("", String(decoding: data.prefix(500), as: UTF8.self))
        }
        let error = object["error"] as? [String: Any] ?? object
        let code = (error["code"] as? String) ?? ""
        let message = (error["message"] as? String) ?? String(decoding: data.prefix(500), as: UTF8.self)
        return (code, String(message.prefix(2_000)))
    }

    private static func pathEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func excerpt(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(String(decoding: data, as: UTF8.self).prefix(400))
    }

    private func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// Masks the API key and anything that looks like a bearer token.
    func redact(_ text: String) -> String {
        Self.redact(text, apiKey: apiKey)
    }

    static func redact(_ text: String, apiKey: String) -> String {
        var result = text
        if !apiKey.isEmpty { result = result.replacingOccurrences(of: apiKey, with: "***") }
        if let expression = try? NSRegularExpression(pattern: "(?i)(bearer\\s+)[A-Za-z0-9._\\-]{8,}") {
            result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1***")
        }
        return result
    }
}

/// Token accounting returned next to every generated asset.
struct ArkUsage: Equatable, Sendable {
    var completionTokens: Int?
    var totalTokens: Int?
    var generatedImages: Int?

    init(completionTokens: Int? = nil, totalTokens: Int? = nil, generatedImages: Int? = nil) {
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.generatedImages = generatedImages
    }

    init?(_ object: [String: Any]?) {
        guard let object else { return nil }
        completionTokens = (object["completion_tokens"] as? NSNumber)?.intValue
        totalTokens = (object["total_tokens"] as? NSNumber)?.intValue
        generatedImages = (object["generated_images"] as? NSNumber)?.intValue ?? (object["output_images"] as? NSNumber)?.intValue
    }
}

/// One `GET /contents/generations/tasks/{id}` reply.
struct ArkTask: Equatable, Sendable {
    var id: String
    var status: String
    var videoURL: String?
    var lastFrameURL: String?
    var errorCode: String?
    var errorMessage: String?
    var usage: ArkUsage?

    init(id: String, status: String, videoURL: String? = nil, lastFrameURL: String? = nil,
         errorCode: String? = nil, errorMessage: String? = nil, usage: ArkUsage? = nil) {
        self.id = id
        self.status = status
        self.videoURL = videoURL
        self.lastFrameURL = lastFrameURL
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.usage = usage
    }

    init(_ object: [String: Any], fallbackID: String) {
        id = (object["id"] as? String) ?? fallbackID
        status = ((object["status"] as? String) ?? "unknown").lowercased()
        let content = object["content"] as? [String: Any]
        videoURL = content?["video_url"] as? String
        lastFrameURL = content?["last_frame_url"] as? String
        let error = object["error"] as? [String: Any]
        errorCode = error?["code"] as? String
        errorMessage = error?["message"] as? String
        usage = ArkUsage(object["usage"] as? [String: Any])
    }
}

/// Every message is safe to show: the API key never appears in one.
enum ArkMediaError: LocalizedError, Equatable {
    case invalidRequest(String)
    case api(status: Int, code: String, message: String)
    case taskFailed(id: String, status: String, code: String, message: String)
    case timeout(id: String, status: String, seconds: TimeInterval)
    case network(String)
    case invalidResponse(String)
    case fileNotFound(String)
    case unreadableImage(String)

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(message):
            return message
        case let .api(status, code, message):
            return "Ark HTTP \(status) \(code): \(message)"
        case let .taskFailed(id, status, code, message):
            return "Ark task \(id) \(status): \(code) \(message)".trimmingCharacters(in: .whitespaces)
        case let .timeout(id, status, seconds):
            return "Ark task \(id) is still \(status) after \(Int(seconds)) s."
        case let .network(message):
            return "Network error talking to Ark: \(message)"
        case let .invalidResponse(message):
            return "Unexpected Ark reply: \(message)"
        case let .fileNotFound(path):
            return "File not found: \(path)"
        case let .unreadableImage(path):
            return "Not a readable image: \(path)"
        }
    }
}
