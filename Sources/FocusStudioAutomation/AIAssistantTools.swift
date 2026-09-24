import AppKit
@preconcurrency import AVFoundation
import FocusStudioCore
import Foundation
import UniformTypeIdentifiers

/// The tools the assistant may call, in the order they are described to the model.
public enum AIAssistantToolCatalog {
    public static var standard: [any AIAssistantTool] {
        [
            // Pacing for multi-step flows ("record for 8 seconds").
            WaitTool(),
            // Recording and library (the app itself).
            ListRecordingSourcesTool(),
            StartRecordingTool(),
            StopRecordingTool(),
            ListProjectsTool(),
            OpenProjectTool(),
            CloseEditorTool(),
            // Editing the open project.
            AddZoomTool(),
            RemoveZoomTool(),
            SetZoomStyleTool(),
            UpdateSettingsTool(),
            SetChaptersTool(),
            SetBackgroundImageTool(),
            SetBackgroundMusicTool(),
            SetSoundEffectsTool(),
            // Generated media and output.
            GenerateImageTool(),
            GenerateVideoTool(),
            CaptureFrameTool(),
            ListAssetsTool(),
            ExportProjectTool(),
            ExportDemoTool(),
            AssembleVideoTool(),
            RevealInFinderTool(),
        ]
    }
}

// MARK: - Argument access

/// Tolerant, typed access to whatever JSON the model sent.
struct AIToolArguments {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    func string(_ key: String) -> String? {
        guard let value = raw[key] else { return nil }
        let text: String
        if let string = value as? String {
            text = string
        } else if let number = value as? NSNumber {
            text = number.stringValue
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else { throw AIToolError.invalidArgument("Missing required argument \"\(key)\".") }
        return value
    }

    func double(_ key: String) -> Double? {
        if let number = raw[key] as? NSNumber { return number.doubleValue.isFinite ? number.doubleValue : nil }
        if let text = string(key) {
            var cleaned = text.lowercased()
            for suffix in ["fps", "px", "s", "sec", "×", "x"] where cleaned.hasSuffix(suffix) { cleaned.removeLast(suffix.count) }
            if let value = Double(cleaned.trimmingCharacters(in: .whitespaces)), value.isFinite { return value }
        }
        return nil
    }

    func int(_ key: String) -> Int? {
        guard let value = double(key) else { return nil }
        // Out-of-range numbers (1e19) would trap in Int(_:); treat them as unparsable.
        return Int(exactly: value.rounded())
    }

    func bool(_ key: String) -> Bool? {
        if let value = raw[key] as? Bool { return value }
        if let number = raw[key] as? NSNumber { return number.intValue != 0 }
        switch string(key)?.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    func stringList(_ key: String) -> [String] {
        if let list = raw[key] as? [Any] {
            return list.compactMap { item -> String? in
                let text = (item as? String) ?? (item as? NSNumber)?.stringValue
                let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        if let single = string(key) { return [single] }
        return []
    }

    func dictionaryList(_ key: String) -> [[String: Any]] {
        (raw[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// Case-insensitive choice among `options`; a clear error names them.
    func choice(_ key: String, in options: [String], default defaultValue: String?) throws -> String? {
        guard let value = string(key) else { return defaultValue }
        if let match = options.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { return match }
        throw AIToolError.invalidArgument("\"\(key)\" must be one of \(options.joined(separator: ", ")) (got \"\(value)\").")
    }

    func has(_ key: String) -> Bool { raw[key] != nil && !(raw[key] is NSNull) }
}

// MARK: - Paths

public enum AIToolPaths {
    enum Reference: Equatable {
        case remote(String)
        case local(URL)
    }

    public enum MediaKind {
        case image
        case video
        case audio
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "tiff", "tif", "gif", "bmp"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "aiff", "aif", "caf", "flac"]

    /// http(s)/data URLs stay remote; everything else is a local path
    /// (absolute, `~`, `file://`, or a name inside the assets directory).
    static func reference(_ raw: String, context: AIAssistantContext) -> Reference {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") || lowercased.hasPrefix("data:") {
            return .remote(trimmed)
        }
        if lowercased.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL {
            return .local(url.standardizedFileURL)
        }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        if expanded.hasPrefix("/") { return .local(URL(fileURLWithPath: expanded).standardizedFileURL) }
        return .local(context.assetsDirectory.appendingPathComponent(trimmed).standardizedFileURL)
    }

    static func existingLocalFile(_ raw: String, context: AIAssistantContext) throws -> URL {
        guard case let .local(url) = reference(raw, context: context) else {
            throw AIToolError.invalidArgument("\"\(raw)\" must be a local file path.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AIToolError.fileNotFound(raw)
        }
        return url
    }

    /// Something Ark accepts inside `content`: an http(s) URL or an inline data URL.
    static func mediaURL(_ raw: String, kind: MediaKind, context: AIAssistantContext) throws -> String {
        switch reference(raw, context: context) {
        case let .remote(url):
            return url
        case let .local(url):
            guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError.fileNotFound(raw) }
            switch kind {
            case .image:
                return try ArkMediaClient.imageDataURL(for: url)
            case .video:
                return try ArkMediaClient.fileDataURL(for: url, mimeType: mimeType(for: url) ?? "video/mp4", maxBytes: 30 * 1_024 * 1_024)
            case .audio:
                return try ArkMediaClient.fileDataURL(for: url, mimeType: mimeType(for: url) ?? "audio/mpeg", maxBytes: 15 * 1_024 * 1_024)
            }
        }
    }

    /// The absolute path with symlinks resolved as far as it exists (`/var` →
    /// `/private/var`) and the Data volume's firmlinks folded back
    /// (`/System/Volumes/Data/Users` → `/Users`), so two spellings of one
    /// location compare equal.
    static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing
        if let real = realpath(existing.path, nil) {
            let path = String(cString: real)
            free(real)
            // realpath keeps the firmlinked spelling; the canonical path key
            // folds it but leaves a final symlink (`/tmp`) alone, so both run.
            let folded = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
            resolved = URL(fileURLWithPath: folded ?? path)
        }
        for component in missing { resolved.appendPathComponent(component) }
        // Not standardized again: that drops `/private` only where the path
        // exists, so an existing folder and a new file inside it would disagree.
        return resolved.path
    }

    /// Whether `path` is `folder` or lies inside it. Both are canonical paths;
    /// the comparison ignores case like the default APFS volume does.
    static func path(_ path: String, isInside folder: String) -> Bool {
        let path = path.lowercased()
        let folder = folder.lowercased()
        return path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    static func mimeType(for url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType
    }

    public static func kind(of url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        return nil
    }
}

// MARK: - Shared helpers

public enum AIToolSupport {
    static func requireArkClient(_ context: AIAssistantContext) async throws -> ArkMediaClient {
        let stored = await MainActor.run { context.arkAPIKey() }
        guard let key = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw AIToolError.failed(L10n.tr("Add a Volcengine Ark API key in Settings to generate media."))
        }
        return ArkMediaClient(apiKey: key, baseURL: context.arkBaseURL)
    }

    static func requireProject(_ context: AIAssistantContext) async throws -> RecordingProject {
        guard let project = await MainActor.run(body: { context.readProject() }) else { throw AIToolError.noProject }
        return project
    }

    /// Applies `change` to the open project in one main-actor step and returns
    /// what it computed from the project as written. The change works on the
    /// project as it is now, not on the snapshot the tool read, so parallel
    /// calls and the user's own edits to other keys survive. Throws, changing
    /// nothing, when the app drops the write, when `change` throws, or when a
    /// different project was opened since the tool read `projectID`.
    public static func edit<Value: Sendable>(
        _ context: AIAssistantContext,
        projectID: UUID,
        _ change: @escaping @Sendable (inout RecordingProject) throws -> Value
    ) async throws -> Value {
        try await MainActor.run {
            var result: Value?
            try context.updateProject { project in
                guard project.id == projectID else {
                    throw AIToolError.failed("Another project was opened before the change was applied; nothing was changed. Check which project is open and try again.")
                }
                result = try change(&project)
            }
            // The app must either apply the change or throw; never report an edit it skipped.
            guard let result else { throw AIToolError.failed("The app did not apply the change; nothing was changed.") }
            return result
        }
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func yuan(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func bytes(_ url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func mediaDuration(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 else { return nil }
        return duration.seconds
    }

    static func videoSize(_ url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    static func writeSidecar(_ record: [String: Any], nextTo url: URL) {
        var payload = record
        payload["created_at"] = ISO8601DateFormatter().string(from: Date())
        payload["output"] = url.path
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url.appendingPathExtension("json"), options: .atomic)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AIToolError.failed("Could not create a PNG encoder.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AIToolError.failed("PNG encoding failed.") }
    }

    static func hexColor(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + value
    }
}

// MARK: - generate_image

struct GenerateImageTool: AIAssistantTool {
    let name = "generate_image"
    let summary = "Generate a still image with Seedream (Volcengine Ark): a background for the recording, a title card, or any other asset. Saves a PNG in the assets folder. Apply a background afterwards with set_background_image."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["prompt"],
            "properties": [
                "prompt": ["type": "string", "description": "Visual description: subject, style, colours, lighting, mood. Never ask for words or UI text in the image."],
                "purpose": ["type": "string", "enum": ["background", "title_card", "asset"], "default": "asset"],
                "ratio": ["type": "string", "enum": ["16:9", "9:16", "1:1", "4:3", "3:4"], "default": "16:9"],
                "model": ["type": "string", "description": "Seedream model id. Default \(ArkMediaClient.defaultImageModel)."],
                "reference_images": ["type": "array", "items": ["type": "string"], "description": "Up to 3 local paths or http(s) URLs whose style or composition should guide the result."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let prompt = try arguments.requiredString("prompt")
        let purpose = try arguments.choice("purpose", in: ["background", "title_card", "asset"], default: "asset") ?? "asset"
        let ratio = try arguments.choice("ratio", in: ["16:9", "9:16", "1:1", "4:3", "3:4"], default: "16:9") ?? "16:9"
        let model = arguments.string("model") ?? ArkMediaClient.defaultImageModel
        let references = arguments.stringList("reference_images")
        guard references.count <= 3 else { throw AIToolError.invalidArgument("reference_images accepts at most 3 images.") }
        let client = try await AIToolSupport.requireArkClient(context)
        let referenceURLs = try references.map { try AIToolPaths.mediaURL($0, kind: .image, context: context) }
        let size = ArkMediaClient.defaultImageSize(ratio: ratio)

        progress(L10n.tr("Requesting image from Seedream…"))
        let result = try await client.generateImage(model: model, prompt: prompt, size: size, referenceImages: referenceURLs)
        let output = try context.newAssetURL(prefix: "image", fileExtension: "png")
        let download = output.deletingPathExtension().appendingPathExtension("download")
        progress(L10n.tr("Downloading…"))
        try await client.saveImage(result, to: download)
        let pixelSize = try ArkMediaClient.writePNG(from: download, to: output)
        try? FileManager.default.removeItem(at: download)

        let estimate = ArkMediaClient.cost(forModel: model, usage: result.usage) ?? ArkMediaClient.estimateImageCost(model: model)
        AIToolSupport.writeSidecar([
            "kind": "image", "model": model, "prompt": prompt, "purpose": purpose, "size": size,
            "reference_images": references, "estimated_yuan": estimate ?? 0,
            "usage": ["generated_images": result.usage?.generatedImages ?? 1, "total_tokens": result.usage?.totalTokens ?? 0],
        ], nextTo: output)

        var lines = [L10n.format("Image saved: %@ (%lld × %lld)", output.lastPathComponent, pixelSize.width, pixelSize.height)]
        if let estimate { lines.append(L10n.format("Estimated cost ≈ ¥%@", AIToolSupport.yuan(estimate))) }
        lines.append(output.path)
        return AIToolResult(text: lines.joined(separator: "\n"), attachments: [output])
    }
}

// MARK: - generate_video

struct GenerateVideoTool: AIAssistantTool {
    let name = "generate_video"
    let summary = "Generate a short video clip with Seedance (Volcengine Ark), e.g. an intro or outro for the demo. Optional first/last frame images, reference images, a reference video (camera/composition) and reference audio (rhythm). Paid: the user confirms a cost estimate first. Prefer the mini model and 4–6 s while iterating."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["prompt"],
            "properties": [
                "prompt": ["type": "string", "description": "Motion, subject, camera and mood. Refer to attached media as 图片1/视频1/音频1. No on-screen text."],
                "model": ["type": "string", "description": "Seedance model id. Default \(ArkMediaClient.defaultVideoModel) (cheapest, 480p/720p)."],
                "duration": ["type": "integer", "minimum": 4, "maximum": 15, "default": 5],
                "ratio": ["type": "string", "enum": ArkMediaClient.videoRatios, "default": "16:9"],
                "resolution": ["type": "string", "enum": ArkMediaClient.videoResolutions, "description": "Omit to let the model pick."],
                "generate_audio": ["type": "boolean", "default": false],
                "first_frame": ["type": "string", "description": "Local path or URL of the first frame image."],
                "last_frame": ["type": "string", "description": "Local path or URL of the last frame image."],
                "reference_images": ["type": "array", "items": ["type": "string"], "description": "Up to 4 style/subject reference images."],
                "reference_video": ["type": "string", "description": "http(s) URL or small local clip whose camera and composition to follow (Seedance 2.x)."],
                "reference_audio": ["type": "string", "description": "http(s) URL or small local audio file whose rhythm to follow (Seedance 2.x)."],
                "seed": ["type": "integer"],
            ],
        ]
    }

    private struct Plan {
        var model: String
        var duration: Int
        var ratio: String
        var resolution: String?
        var generateAudio: Bool
        var usesReferenceMedia: Bool
    }

    private func plan(_ arguments: AIToolArguments, strict: Bool) throws -> Plan {
        let model = arguments.string("model") ?? ArkMediaClient.defaultVideoModel
        let info = ArkMediaClient.videoModelInfo(for: model)
        let allowedDurations = info?.durations ?? 2...15
        var duration = arguments.int("duration") ?? 5
        if strict {
            guard allowedDurations.contains(duration) else {
                throw AIToolError.invalidArgument("duration must be \(allowedDurations.lowerBound)–\(allowedDurations.upperBound) seconds for \(model).")
            }
        } else {
            duration = duration.clamped(to: allowedDurations)
        }
        let ratio = try arguments.choice("ratio", in: ArkMediaClient.videoRatios, default: "16:9") ?? "16:9"
        let resolution = try arguments.choice("resolution", in: ArkMediaClient.videoResolutions, default: nil)
        if strict, let resolution, let info, !info.resolutions.contains(resolution) {
            throw AIToolError.invalidArgument("\(model) supports \(info.resolutions.joined(separator: "/")) only.")
        }
        let generateAudio = arguments.bool("generate_audio") ?? false
        let usesReferenceMedia = arguments.has("reference_video") || arguments.has("reference_audio")
        return Plan(model: model, duration: duration, ratio: ratio, resolution: resolution,
                    generateAudio: generateAudio, usesReferenceMedia: usesReferenceMedia)
    }

    func costEstimate(arguments raw: [String: Any]) -> AIToolCostEstimate? {
        let arguments = AIToolArguments(raw)
        let plan = (try? plan(arguments, strict: false)) ?? Plan(model: ArkMediaClient.defaultVideoModel, duration: 5, ratio: "16:9", resolution: nil, generateAudio: false, usesReferenceMedia: false)
        let estimate = ArkMediaClient.estimateVideoCost(
            model: plan.model, resolution: plan.resolution, ratio: plan.ratio,
            duration: Double(plan.duration), usesAudioOrReferenceMedia: plan.generateAudio || plan.usesReferenceMedia
        )
        var parts = [
            ArkMediaClient.displayName(forModel: plan.model),
            L10n.format("%@s", String(plan.duration)),
            plan.resolution ?? L10n.tr("auto resolution"),
            plan.ratio,
        ]
        if plan.generateAudio || plan.usesReferenceMedia { parts.append(L10n.tr("with audio")) }
        if estimate.yuan == nil { parts.append(L10n.tr("unknown price")) }
        return AIToolCostEstimate(yuan: estimate.yuan ?? 0, summary: parts.joined(separator: " · "))
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let prompt = try arguments.requiredString("prompt")
        let plan = try plan(arguments, strict: true)
        let referenceImages = arguments.stringList("reference_images")
        guard referenceImages.count <= 4 else { throw AIToolError.invalidArgument("reference_images accepts at most 4 images.") }
        let client = try await AIToolSupport.requireArkClient(context)

        var request = ArkMediaClient.VideoTaskRequest(model: plan.model, prompt: prompt)
        if let firstFrame = arguments.string("first_frame") {
            request.images.append(.init(url: try AIToolPaths.mediaURL(firstFrame, kind: .image, context: context), role: "first_frame"))
        }
        if let lastFrame = arguments.string("last_frame") {
            request.images.append(.init(url: try AIToolPaths.mediaURL(lastFrame, kind: .image, context: context), role: "last_frame"))
        }
        for reference in referenceImages {
            request.images.append(.init(url: try AIToolPaths.mediaURL(reference, kind: .image, context: context), role: "reference_image"))
        }
        if let video = arguments.string("reference_video") {
            request.videos.append(.init(url: try AIToolPaths.mediaURL(video, kind: .video, context: context), role: "reference_video"))
        }
        if let audio = arguments.string("reference_audio") {
            request.audios.append(.init(url: try AIToolPaths.mediaURL(audio, kind: .audio, context: context), role: "reference_audio"))
        }
        request.resolution = plan.resolution
        request.ratio = plan.ratio
        request.duration = plan.duration
        request.generateAudio = plan.generateAudio
        request.watermark = false
        request.seed = arguments.int("seed")

        progress(L10n.tr("Submitting Seedance task…"))
        let taskID = try await client.createVideoTask(request)
        let family = ArkMediaClient.displayName(forModel: plan.model)
        let task = try await client.waitForTask(id: taskID) { _, elapsed in
            progress(L10n.format("%@ generating… %lld s", family, Int(elapsed.rounded())))
        }
        guard let videoURL = task.videoURL else {
            throw AIToolError.failed("Ark task \(taskID) succeeded without a video URL.")
        }
        progress(L10n.tr("Downloading…"))
        let output = try context.newAssetURL(prefix: "video", fileExtension: "mp4")
        try await client.download(videoURL, to: output)
        if let lastFrame = task.lastFrameURL {
            let frameURL = output.deletingPathExtension().appendingPathExtension("last-frame.jpg")
            try? await client.download(lastFrame, to: frameURL)
        }

        let duration = await AIToolSupport.mediaDuration(output)
        let actualCost = ArkMediaClient.cost(forModel: plan.model, usage: task.usage)
        let estimate = actualCost ?? ArkMediaClient.estimateVideoCost(
            model: plan.model, resolution: plan.resolution, ratio: plan.ratio,
            duration: Double(plan.duration), usesAudioOrReferenceMedia: plan.generateAudio || plan.usesReferenceMedia
        ).yuan
        AIToolSupport.writeSidecar([
            "kind": "video", "model": plan.model, "prompt": prompt, "task_id": taskID,
            "duration": plan.duration, "ratio": plan.ratio, "resolution": plan.resolution ?? "auto",
            "generate_audio": plan.generateAudio, "estimated_yuan": estimate ?? 0,
            "usage": ["completion_tokens": task.usage?.completionTokens ?? 0, "total_tokens": task.usage?.totalTokens ?? 0],
        ], nextTo: output)

        var lines = [L10n.format("Video saved: %@ (%@ s, %@)", output.lastPathComponent,
                                 AIToolSupport.seconds(duration ?? Double(plan.duration)), AIToolSupport.bytes(output))]
        if let estimate { lines.append(L10n.format("Estimated cost ≈ ¥%@", AIToolSupport.yuan(estimate))) }
        lines.append(output.path)
        return AIToolResult(text: lines.joined(separator: "\n"), attachments: [output])
    }
}

// MARK: - capture_frame

struct CaptureFrameTool: AIAssistantTool {
    let name = "capture_frame"
    let summary = "Render one styled frame of the current recording (background, padding, zoom, captions) as a PNG, e.g. to use as a first/last frame or reference image for generate_video."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["time"],
            "properties": [
                "time": ["type": "number", "description": "Seconds into the recording."],
                "width": ["type": "integer", "minimum": 640, "maximum": 3840, "default": 1920],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        guard let time = arguments.double("time") else { throw AIToolError.invalidArgument("Missing required argument \"time\" (seconds).") }
        var project = try await AIToolSupport.requireProject(context)
        guard project.duration.isFinite, project.duration > 0 else { throw AIToolError.failed("The recording has no duration.") }
        let clampedTime = time.clamped(to: 0...max(0, project.duration - 0.05))
        project.settings.exportWidth = (arguments.int("width") ?? 1_920).clamped(to: 640...3_840)

        progress(L10n.tr("Rendering frame…"))
        let prepared = try await ProjectVideoRenderer.prepare(project: project)
        let generator = AVAssetImageGenerator(asset: prepared.asset)
        generator.videoComposition = prepared.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let (image, _) = try await generator.image(at: CMTime(seconds: clampedTime, preferredTimescale: 600))
        let output = try context.newAssetURL(prefix: "frame", fileExtension: "png")
        try AIToolSupport.writePNG(image, to: output)
        let text = L10n.format("Frame captured at %@ s: %@ (%lld × %lld)", AIToolSupport.seconds(clampedTime), output.lastPathComponent, image.width, image.height)
        return AIToolResult(text: text + "\n" + output.path, attachments: [output])
    }
}

// MARK: - set_background_image

struct SetBackgroundImageTool: AIAssistantTool {
    let name = "set_background_image"
    let summary = "Use an image file (generated or imported) as the recording's background."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["path"],
            "properties": [
                "path": ["type": "string", "description": "Local image path or a file name from the assets folder."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let url = try AIToolPaths.existingLocalFile(try arguments.requiredString("path"), context: context)
        guard ArkMediaClient.imagePixelSize(at: url) != nil else { throw AIToolError.invalidArgument("\(url.lastPathComponent) is not a readable image.") }
        let project = try await AIToolSupport.requireProject(context)
        let path = url.path
        try await AIToolSupport.edit(context, projectID: project.id) { project in
            project.settings.backgroundStyle = .image
            project.settings.backgroundImagePath = path
        }
        return AIToolResult(text: L10n.format("Background image set: %@", url.lastPathComponent), attachments: [url])
    }
}

// MARK: - update_settings

struct UpdateSettingsTool: AIAssistantTool {
    let name = "update_settings"
    let summary = "Change how the recording looks and exports: background (style, preset, colours, image, blur, brightness), padding, corner radius, shadow, screen animation, zoom scale, aspect ratio, motion blur, caption style, the product description, and the export width and frame rate. Only the given keys change."

    static let backgroundPresetNames = BackgroundPreset.allCases.map(\.rawValue)
    static let aspectRatioNames = CanvasAspectRatio.allCases.map(\.rawValue) + ["auto", "16:9", "9:16", "1:1", "4:3", "3:4"]
    /// The choices the editor's Export inspector offers.
    static let exportWidths = [1_280, 1_920, 2_560, 3_840]
    static let exportFrameRates = [24, 30, 60]

    static let ranges: [String: ClosedRange<Double>] = [
        "padding": 0...160,
        "cornerRadius": 0...52,
        "shadow": 0...0.8,
        "zoomScale": 1.1...3,
        "motionBlur": 0...0.3,
        "backgroundBlur": 0...60,
        "backgroundBrightness": -0.5...0.35,
        "captionScale": CaptionStyle.scaleRange,
    ]

    static let allowedKeys = [
        "backgroundStyle", "backgroundPreset", "backgroundColor", "secondaryBackgroundColor", "backgroundImagePath",
        "backgroundBlur", "backgroundBrightness", "padding", "cornerRadius", "shadow", "screenAnimation", "zoomScale",
        "aspectRatio", "motionBlur", "captionPosition", "captionScale", "showsChapterNumber", "productDescription",
        "exportWidth", "frameRate",
    ]

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "backgroundStyle": ["type": "string", "enum": BackgroundStyle.allCases.map(\.rawValue)],
                "backgroundPreset": ["type": "string", "enum": Self.backgroundPresetNames, "description": "Curated gradient; sets both colours."],
                "backgroundColor": ["type": "string", "description": "Hex like #6D5DFB"],
                "secondaryBackgroundColor": ["type": "string", "description": "Hex; second gradient stop"],
                "backgroundImagePath": ["type": "string"],
                "backgroundBlur": ["type": "number", "minimum": 0, "maximum": 60],
                "backgroundBrightness": ["type": "number", "minimum": -0.5, "maximum": 0.35],
                "padding": ["type": "number", "minimum": 0, "maximum": 160, "description": "Pixels around the screen"],
                "cornerRadius": ["type": "number", "minimum": 0, "maximum": 52],
                "shadow": ["type": "number", "minimum": 0, "maximum": 0.8],
                "screenAnimation": ["type": "string", "enum": ScreenAnimationStyle.allCases.map(\.rawValue)],
                "zoomScale": ["type": "number", "minimum": 1.1, "maximum": 3],
                "aspectRatio": ["type": "string", "enum": CanvasAspectRatio.allCases.map(\.rawValue), "description": "wide = 16:9, vertical = 9:16, square, classic = 4:3, tall = 3:4"],
                "motionBlur": ["type": "number", "minimum": 0, "maximum": 0.3],
                "captionPosition": ["type": "string", "enum": CaptionPosition.allCases.map(\.rawValue)],
                "captionScale": ["type": "number", "minimum": 0.7, "maximum": 1.6],
                "showsChapterNumber": ["type": "boolean"],
                "productDescription": ["type": "string", "description": "What the demo shows, in the user's words."],
                "exportWidth": ["type": "integer", "enum": Self.exportWidths, "description": "Width of the exported video in pixels; the height follows the aspect ratio."],
                "frameRate": ["type": "integer", "enum": Self.exportFrameRates, "description": "Frames per second of the exported video."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let update = try Self.prepare(arguments: raw, context: context)
        let project = try await AIToolSupport.requireProject(context)
        try await AIToolSupport.edit(context, projectID: project.id) { try update.apply(&$0.settings) }
        return AIToolResult(text: L10n.format("Updated %@", update.changes.joined(separator: ", ")))
    }

    /// A validated call: one "key = value" note per change, and the change
    /// itself, which sets only the requested keys on whatever the project
    /// holds when it is written.
    struct SettingsUpdate: Sendable {
        var changes: [String]
        var apply: @Sendable (inout ProjectSettings) throws -> Void
    }

    /// Validates every argument before anything is written, so a bad call
    /// changes nothing. Shared with set_zoom_style for the keys both tools accept.
    static func prepare(arguments raw: [String: Any], context: AIAssistantContext) throws -> SettingsUpdate {
        let arguments = AIToolArguments(raw)
        let requested = raw.keys.filter { !(raw[$0] is NSNull) }
        let unknown = requested.filter { !Self.allowedKeys.contains($0) }
        guard unknown.isEmpty else {
            throw AIToolError.invalidArgument("Unknown settings \(unknown.sorted().joined(separator: ", ")). Allowed: \(Self.allowedKeys.joined(separator: ", ")).")
        }
        guard !requested.isEmpty else { throw AIToolError.invalidArgument("No settings given.") }

        var changes: [String] = []
        // Applied in order to the settings as they are at write time.
        var steps: [@Sendable (inout ProjectSettings) throws -> Void] = []
        func clamp(_ key: String, _ value: Double) -> Double {
            let range = Self.ranges[key] ?? (-Double.infinity...Double.infinity)
            let clamped = value.clamped(to: range)
            if clamped != value { changes.append("\(key) = \(Self.number(clamped)) (clamped)") } else { changes.append("\(key) = \(Self.number(clamped))") }
            return clamped
        }
        func number(_ key: String) throws -> Double? {
            guard arguments.has(key) else { return nil }
            guard let value = arguments.double(key) else { throw AIToolError.invalidArgument("\"\(key)\" must be a number.") }
            return value
        }
        func option(_ key: String, in allowed: [Int]) throws -> Int? {
            guard arguments.has(key) else { return nil }
            // Matched as numbers: converting a huge value to Int first would trap.
            guard let value = arguments.double(key), let match = allowed.first(where: { Double($0) == value }) else {
                let given = arguments.string(key) ?? raw[key].map { String(describing: $0) } ?? ""
                throw AIToolError.invalidArgument("\"\(key)\" must be one of \(allowed.map(String.init).joined(separator: ", ")) (got \"\(given)\").")
            }
            return match
        }
        let setsStyle = arguments.has("backgroundStyle")
        let setsImagePath = arguments.has("backgroundImagePath")

        if let preset = try arguments.choice("backgroundPreset", in: Self.backgroundPresetNames, default: nil),
           let value = BackgroundPreset(rawValue: preset) {
            steps.append { settings in
                settings.backgroundStyle = .gradient
                settings.backgroundColor = value.primaryHex
                settings.secondaryBackgroundColor = value.secondaryHex
            }
            changes.append("backgroundPreset = \(value.title)")
        }
        if let style = try arguments.choice("backgroundStyle", in: BackgroundStyle.allCases.map(\.rawValue), default: nil),
           let value = BackgroundStyle(rawValue: style) {
            steps.append { settings in
                if value == .image, (settings.backgroundImagePath ?? "").isEmpty, !setsImagePath {
                    throw AIToolError.invalidArgument("backgroundStyle image needs backgroundImagePath (or call set_background_image).")
                }
                settings.backgroundStyle = value
            }
            changes.append("backgroundStyle = \(value.rawValue)")
        }
        for key in ["backgroundColor", "secondaryBackgroundColor"] where arguments.has(key) {
            guard let hex = AIToolSupport.hexColor(arguments.string(key) ?? "") else {
                throw AIToolError.invalidArgument("\"\(key)\" must be a hex colour like #6D5DFB.")
            }
            let isPrimary = key == "backgroundColor"
            steps.append { settings in
                if isPrimary { settings.backgroundColor = hex } else { settings.secondaryBackgroundColor = hex }
                if settings.backgroundStyle == .image, !setsStyle { settings.backgroundStyle = .gradient }
            }
            changes.append("\(key) = \(hex)")
        }
        if let path = arguments.string("backgroundImagePath") {
            let url = try AIToolPaths.existingLocalFile(path, context: context)
            guard ArkMediaClient.imagePixelSize(at: url) != nil else { throw AIToolError.invalidArgument("\(url.lastPathComponent) is not a readable image.") }
            let imagePath = url.path
            steps.append { settings in
                settings.backgroundImagePath = imagePath
                if !setsStyle { settings.backgroundStyle = .image }
            }
            changes.append("backgroundImagePath = \(url.lastPathComponent)")
        }
        if let value = try number("backgroundBlur") {
            let blur = clamp("backgroundBlur", value)
            steps.append { $0.backgroundBlur = blur }
        }
        if let value = try number("backgroundBrightness") {
            let brightness = clamp("backgroundBrightness", value)
            steps.append { $0.backgroundBrightness = brightness }
        }
        if let value = try number("padding") {
            let padding = clamp("padding", value)
            steps.append { $0.padding = padding }
        }
        if let value = try number("cornerRadius") {
            let radius = clamp("cornerRadius", value)
            steps.append { $0.cornerRadius = radius }
        }
        if let value = try number("shadow") {
            let shadow = clamp("shadow", value)
            steps.append { $0.shadow = shadow }
        }
        if let value = try number("zoomScale") {
            let scale = clamp("zoomScale", value)
            steps.append { $0.zoomScale = scale }
        }
        if let value = try number("motionBlur") {
            let blur = clamp("motionBlur", value)
            steps.append { $0.motionBlur = blur }
        }
        if let animation = try arguments.choice("screenAnimation", in: ScreenAnimationStyle.allCases.map(\.rawValue), default: nil),
           let value = ScreenAnimationStyle(rawValue: animation) {
            steps.append { $0.screenAnimation = value }
            changes.append("screenAnimation = \(value.rawValue)")
        }
        if let ratio = try arguments.choice("aspectRatio", in: Self.aspectRatioNames, default: nil) {
            let value: CanvasAspectRatio
            switch ratio.lowercased() {
            case "auto": value = .automatic
            case "16:9": value = .wide
            case "9:16": value = .vertical
            case "1:1": value = .square
            case "4:3": value = .classic
            case "3:4": value = .tall
            default: value = CanvasAspectRatio(rawValue: ratio.lowercased()) ?? .wide
            }
            steps.append { $0.aspectRatio = value }
            changes.append("aspectRatio = \(value.rawValue) (\(value.title))")
        }
        var captionPosition: CaptionPosition?
        var captionScale: Double?
        var showsChapterNumber: Bool?
        if let position = try arguments.choice("captionPosition", in: CaptionPosition.allCases.map(\.rawValue), default: nil),
           let value = CaptionPosition(rawValue: position) {
            captionPosition = value
            changes.append("captionPosition = \(value.rawValue)")
        }
        if let value = try number("captionScale") {
            captionScale = clamp("captionScale", value)
        }
        if arguments.has("showsChapterNumber") {
            guard let value = arguments.bool("showsChapterNumber") else { throw AIToolError.invalidArgument("\"showsChapterNumber\" must be true or false.") }
            showsChapterNumber = value
            changes.append("showsChapterNumber = \(value)")
        }
        if captionPosition != nil || captionScale != nil || showsChapterNumber != nil {
            let (position, scale, showsNumber) = (captionPosition, captionScale, showsChapterNumber)
            steps.append { settings in
                var caption = settings.resolvedCaptionStyle
                if let position { caption.position = position }
                if let scale { caption.scale = scale }
                if let showsNumber { caption.showsChapterNumber = showsNumber }
                settings.captionStyle = caption.sanitized
            }
        }
        if arguments.has("productDescription") {
            let description = (arguments.string("productDescription") ?? "").prefix(600)
            let stored = description.isEmpty ? nil : String(description)
            steps.append { $0.productDescription = stored }
            changes.append("productDescription = \(description.isEmpty ? "(cleared)" : "\"\(description.prefix(60))\(description.count > 60 ? "…" : "")\"")")
        }
        if let width = try option("exportWidth", in: Self.exportWidths) {
            steps.append { $0.exportWidth = width }
            changes.append("exportWidth = \(width)")
        }
        if let rate = try option("frameRate", in: Self.exportFrameRates) {
            steps.append { $0.frameRate = rate }
            changes.append("frameRate = \(rate)")
        }

        let ordered = steps
        return SettingsUpdate(changes: changes) { settings in
            for step in ordered { try step(&settings) }
        }
    }

    static func number(_ value: Double) -> String {
        if value == value.rounded(), let whole = Int(exactly: value) { return String(whole) }
        return String(format: "%.2f", value)
    }
}

// MARK: - set_chapters

struct SetChaptersTool: AIAssistantTool {
    let name = "set_chapters"
    let summary = "Replace (or append to) the demo's chapters: time ranges with a short title and an on-video caption. Times are seconds within the recording; each chapter needs at least 0.5 s and a title or caption."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["chapters"],
            "properties": [
                "chapters": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "required": ["start", "end"],
                        "properties": [
                            "start": ["type": "number"],
                            "end": ["type": "number"],
                            "title": ["type": "string", "description": "At most 4 words"],
                            "caption": ["type": "string", "description": "One line, at most 60 characters, benefit-oriented"],
                        ],
                    ],
                ],
                "append": ["type": "boolean", "default": false, "description": "Keep existing chapters and add these."],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let entries = arguments.dictionaryList("chapters")
        guard !entries.isEmpty else { throw AIToolError.invalidArgument("\"chapters\" must be a non-empty array of {start, end, title, caption}.") }
        let project = try await AIToolSupport.requireProject(context)
        let candidates = entries.compactMap { entry -> DemoChapter? in
            let fields = AIToolArguments(entry)
            guard let start = fields.double("start"), let end = fields.double("end") else { return nil }
            return DemoChapter(
                start: start, end: end,
                title: fields.string("title") ?? fields.string("name") ?? "",
                caption: fields.string("caption") ?? fields.string("text") ?? ""
            )
        }
        let append = arguments.bool("append") ?? false
        // Appending merges with the chapters the project has when it is written,
        // so a parallel call's chapters are kept.
        let (chapters, kept) = try await AIToolSupport.edit(context, projectID: project.id) { current -> ([DemoChapter], Int) in
            let existing = append ? (current.chapters ?? []) : []
            let chapters = ChapterMath.sanitized(existing + candidates, duration: current.duration)
            guard !chapters.isEmpty else {
                throw AIToolError.invalidArgument("No valid chapters: each needs start < end inside 0–\(AIToolSupport.seconds(current.duration)) s, at least \(ChapterMath.minimumDuration) s long, with a title or caption.")
            }
            current.chapters = chapters
            return (chapters, existing.count)
        }
        var lines = [L10n.format("Set %lld chapters", chapters.count)]
        for (index, chapter) in chapters.enumerated() {
            let text = chapter.caption.isEmpty ? chapter.title : "\(chapter.title) — \(chapter.caption)"
            lines.append("\(index + 1). \(AIToolSupport.seconds(chapter.start))–\(AIToolSupport.seconds(chapter.end)) s  \(text)")
        }
        if candidates.count != chapters.count - kept {
            lines.append("(\(candidates.count - (chapters.count - kept)) invalid chapters were dropped)")
        }
        return AIToolResult(text: lines.joined(separator: "\n"))
    }
}

// MARK: - list_assets

struct ListAssetsTool: AIAssistantTool {
    let name = "list_assets"
    let summary = "List the images, videos and audio files in the assets folder (generated, captured, exported or imported), newest first."

    var parametersSchema: [String: Any] {
        ["type": "object", "properties": [String: Any]()]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let directory = context.assetsDirectory
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        let media = contents
            .filter { AIToolPaths.kind(of: $0) != nil }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        guard !media.isEmpty else {
            return AIToolResult(text: L10n.tr("No assets yet") + "\n" + directory.path)
        }
        var lines = [L10n.format("%lld assets", media.count), directory.path]
        for url in media {
            var details = [AIToolSupport.bytes(url)]
            switch AIToolPaths.kind(of: url) {
            case .image:
                if let size = ArkMediaClient.imagePixelSize(at: url) { details.insert("\(size.width) × \(size.height)", at: 0) }
            case .video:
                if let duration = await AIToolSupport.mediaDuration(url) { details.insert(L10n.format("%@s", AIToolSupport.seconds(duration)), at: 0) }
                if let size = await AIToolSupport.videoSize(url) { details.insert("\(Int(size.width)) × \(Int(size.height))", at: 0) }
            case .audio:
                if let duration = await AIToolSupport.mediaDuration(url) { details.insert(L10n.format("%@s", AIToolSupport.seconds(duration)), at: 0) }
            case nil:
                break
            }
            lines.append("\(url.lastPathComponent) · \(details.joined(separator: " · "))")
        }
        return AIToolResult(text: lines.joined(separator: "\n"), attachments: Array(media.prefix(8)))
    }
}

// MARK: - export_demo

/// Older prompts and transcripts call the export `export_demo`; it is the same
/// tool as `export_project` (same arguments and output location).
struct ExportDemoTool: AIAssistantTool {
    private let tool = ExportProjectTool(
        name: "export_demo",
        summary: "Alias of export_project: render the open project to an MP4 (default export-<timestamp>.mp4 in the assets folder)."
    )

    var name: String { tool.name }
    var summary: String { tool.summary }
    var parametersSchema: [String: Any] { tool.parametersSchema }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        try await tool.run(arguments: raw, context: context, progress: progress)
    }
}

// MARK: - assemble_video

struct AssembleVideoTool: AIAssistantTool {
    let name = "assemble_video"
    let summary = "Join clips in order (for example intro + exported demo + outro) into one 1080p MP4, with a cut or a 0.5 s crossfade. Each clip is scaled and letterboxed to fit; audio is kept."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["clips"],
            "properties": [
                "clips": ["type": "array", "items": ["type": "string"], "minItems": 1, "description": "Local video paths or asset file names, in playback order."],
                "transition": ["type": "string", "enum": ["cut", "crossfade"], "default": "cut"],
                "output": ["type": "string", "enum": ["1080p", "720p"], "default": "1080p"],
            ],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        let clipReferences = arguments.stringList("clips")
        guard !clipReferences.isEmpty else { throw AIToolError.invalidArgument("\"clips\" must list at least one video file.") }
        let clips = try clipReferences.map { try AIToolPaths.existingLocalFile($0, context: context) }
        let transition = VideoAssembler.Transition(rawValue: try arguments.choice("transition", in: ["cut", "crossfade"], default: "cut") ?? "cut") ?? .cut
        let output = try arguments.choice("output", in: ["1080p", "720p"], default: "1080p") ?? "1080p"
        let renderSize = output == "720p" ? CGSize(width: 1_280, height: 720) : CGSize(width: 1_920, height: 1_080)
        let destination = try context.newAssetURL(prefix: "assembled", fileExtension: "mp4")
        progress(L10n.format("Assembling %lld clips…", clips.count))
        let result = try await VideoAssembler.assemble(clips: clips, transition: transition, renderSize: renderSize, to: destination)
        let text = L10n.format("Assembled %@ from %lld clips (%@ s, %lld × %lld)", destination.lastPathComponent, clips.count,
                               AIToolSupport.seconds(result.duration), Int(result.renderSize.width), Int(result.renderSize.height))
        return AIToolResult(text: text + "\n" + destination.path, attachments: [destination])
    }
}

/// Sequential clip assembly on two alternating video (and audio) tracks so a
/// crossfade can overlap neighbours. Every clip is aspect-fitted into the
/// render size with a layer transform; nothing is re-rendered through Core Image.
enum VideoAssembler {
    enum Transition: String, Sendable {
        case cut
        case crossfade
    }

    struct Result: Sendable {
        let url: URL
        let duration: Double
        let renderSize: CGSize
        let clipCount: Int
    }

    static let crossfadeDuration = 0.5

    private struct LoadedClip {
        let url: URL
        let asset: AVURLAsset
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
        let duration: CMTime
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
    }

    private struct Placement {
        let clipIndex: Int
        let trackIndex: Int
        let start: CMTime
        let end: CMTime
    }

    static func assemble(
        clips: [URL],
        transition: Transition,
        renderSize: CGSize,
        frameRate: Int = 30,
        to outputURL: URL
    ) async throws -> Result {
        guard !clips.isEmpty else { throw AIToolError.invalidArgument("clips must contain at least one file.") }
        guard outputURL.pathExtension.lowercased() == "mp4" else { throw AIToolError.invalidArgument("The output must be an .mp4 file.") }

        var loaded: [LoadedClip] = []
        for url in clips {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration.seconds.isFinite, duration.seconds > 0 else { throw AIToolError.failed("\(url.lastPathComponent) has no duration.") }
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw AIToolError.failed("\(url.lastPathComponent) has no video track.")
            }
            let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
            let (naturalSize, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
            loaded.append(LoadedClip(url: url, asset: asset, videoTrack: videoTrack, audioTrack: audioTrack,
                                     duration: duration, naturalSize: naturalSize, preferredTransform: transform))
        }

        let shortest = loaded.map(\.duration.seconds).min() ?? 0
        let overlapSeconds = transition == .crossfade && loaded.count > 1 ? min(crossfadeDuration, shortest / 2) : 0
        let overlap = CMTime(seconds: overlapSeconds, preferredTimescale: 600)

        let composition = AVMutableComposition()
        guard let videoA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let videoB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw AIToolError.failed("Could not create composition video tracks.") }
        let videoTracks = [videoA, videoB]
        let needsAudio = loaded.contains { $0.audioTrack != nil }
        var audioTracks: [AVMutableCompositionTrack] = []
        if needsAudio {
            for _ in 0..<2 {
                guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw AIToolError.failed("Could not create composition audio tracks.")
                }
                audioTracks.append(track)
            }
        }

        var placements: [Placement] = []
        var cursor = CMTime.zero
        for (index, clip) in loaded.enumerated() {
            let trackIndex = index % 2
            let range = CMTimeRange(start: .zero, duration: clip.duration)
            do {
                try videoTracks[trackIndex].insertTimeRange(range, of: clip.videoTrack, at: cursor)
            } catch {
                throw AIToolError.failed("Could not add \(clip.url.lastPathComponent): \(error.localizedDescription)")
            }
            if let audio = clip.audioTrack, !audioTracks.isEmpty {
                try? audioTracks[trackIndex].insertTimeRange(range, of: audio, at: cursor)
            }
            let end = CMTimeAdd(cursor, clip.duration)
            placements.append(Placement(clipIndex: index, trackIndex: trackIndex, start: cursor, end: end))
            cursor = index < loaded.count - 1 ? CMTimeSubtract(end, overlap) : end
        }
        let totalDuration = placements.last?.end ?? .zero

        // One instruction per span between clip boundaries; the later-starting
        // clip is the top layer and fades in over its predecessor.
        var boundaries = Set(placements.flatMap { [$0.start, $0.end] }).sorted(by: <)
        boundaries = boundaries.filter { $0 >= .zero && $0 <= totalDuration }
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for (t0, t1) in zip(boundaries, boundaries.dropFirst()) where t1 > t0 {
            let active = placements
                .filter { $0.start <= t0 && $0.end >= t1 }
                .sorted { $0.start > $1.start }
            guard !active.isEmpty else { continue }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: t0, end: t1)
            var layers: [AVMutableVideoCompositionLayerInstruction] = []
            for (position, placement) in active.enumerated() {
                let clip = loaded[placement.clipIndex]
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTracks[placement.trackIndex])
                layer.setTransform(fitTransform(for: clip, in: renderSize), at: t0)
                if position == 0, active.count > 1 {
                    layer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: instruction.timeRange)
                } else {
                    layer.setOpacity(1, at: t0)
                }
                layers.append(layer)
            }
            instruction.layerInstructions = layers
            instructions.append(instruction)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
        videoComposition.instructions = instructions

        var audioMix: AVMutableAudioMix?
        if needsAudio, overlapSeconds > 0 {
            let mix = AVMutableAudioMix()
            var parameters = audioTracks.map { AVMutableAudioMixInputParameters(track: $0) }
            for (index, placement) in placements.enumerated() {
                let input = parameters[placement.trackIndex]
                if index > 0 {
                    input.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: placement.start, duration: overlap))
                }
                if index < placements.count - 1 {
                    input.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: CMTimeSubtract(placement.end, overlap), duration: overlap))
                }
                parameters[placement.trackIndex] = input
            }
            mix.inputParameters = parameters
            audioMix = mix
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw AIToolError.failed("AVFoundation could not create an export session.")
        }
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        session.shouldOptimizeForNetworkUse = true
        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).partial.mp4")
        do {
            try await session.export(to: temporaryURL, as: .mp4)
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw AIToolError.failed("Video assembly failed: \(error.localizedDescription)")
        }
        return Result(url: outputURL, duration: totalDuration.seconds, renderSize: renderSize, clipCount: loaded.count)
    }

    /// Aspect-fits the clip (after its preferred orientation) into the render size, centred.
    private static func fitTransform(for clip: LoadedClip, in renderSize: CGSize) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: clip.naturalSize).applying(clip.preferredTransform)
        let width = max(1, abs(oriented.width))
        let height = max(1, abs(oriented.height))
        let scale = min(renderSize.width / width, renderSize.height / height)
        let offset = CGPoint(x: (renderSize.width - width * scale) / 2, y: (renderSize.height - height * scale) / 2)
        return clip.preferredTransform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: offset.x, y: offset.y))
    }
}

// MARK: - reveal_in_finder

struct RevealInFinderTool: AIAssistantTool {
    let name = "reveal_in_finder"
    let summary = "Show a generated or exported file in the Finder."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "required": ["path"],
            "properties": ["path": ["type": "string"]],
        ]
    }

    func run(
        arguments raw: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let url = try AIToolPaths.existingLocalFile(try AIToolArguments(raw).requiredString("path"), context: context)
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        return AIToolResult(text: L10n.format("Revealed %@ in Finder", url.lastPathComponent))
    }
}

// MARK: - Wait

/// Lets multi-step flows pause, for example between start_recording and
/// stop_recording, or while a page settles. Cancellable; capped at two minutes.
struct WaitTool: AIAssistantTool {
    let name = "wait"
    let summary = "Pause for a number of seconds (1-120) before the next step, e.g. to let a recording run for the requested time or a page load. Reports progress every 5 seconds."

    var parametersSchema: [String: Any] {
        ["type": "object",
         "properties": ["seconds": ["type": "number", "description": "Seconds to wait, 1-120"]],
         "required": ["seconds"]]
    }

    func run(
        arguments: [String: Any],
        context: AIAssistantContext,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let seconds: Double
        switch arguments["seconds"] {
        case let value as Double: seconds = value
        case let value as Int: seconds = Double(value)
        case let value as String: seconds = Double(value.trimmingCharacters(in: .whitespaces)) ?? .nan
        default: seconds = .nan
        }
        guard seconds.isFinite, seconds >= 1, seconds <= 120 else {
            throw AIToolError.invalidArgument("seconds must be a number between 1 and 120")
        }
        let start = Date()
        while true {
            try Task.checkCancellation()
            let remaining = seconds - Date().timeIntervalSince(start)
            guard remaining > 0 else { break }
            try await Task.sleep(nanoseconds: UInt64(min(5, remaining) * 1_000_000_000))
            let left = seconds - Date().timeIntervalSince(start)
            if left > 0.5 { progress(L10n.format("Waiting… %lld s left", Int(left.rounded(.up)))) }
        }
        return AIToolResult(text: "Waited \(Int(seconds.rounded())) s.")
    }
}
