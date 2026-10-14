@preconcurrency import AVFoundation
import CoreFoundation
import FocusStudioCore
import Foundation

/// Configuration inspection never makes a provider request and never returns a secret.
public struct ListSpeechModelsTool: AIAssistantTool {
    public let name = "list_speech_models"
    public let summary = "Inspect configured speech provider, model, voice and key presence offline. Configure in Settings before generate_voiceover; never pass API keys to tools."
    public init() {}
    public var parametersSchema: [String: Any] { ["type": "object", "properties": [:]] }

    public func run(arguments: [String: Any], context: AIAssistantContext,
                    progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        guard let resolve = context.speechConfiguration else {
            return AIToolResult(text: "Speech generation is not configured. Open Settings → AI models → AI narration.",
                                data: ["configured": false, "key_configured": false])
        }
        let configuration = try await resolve()
        let hasKey: Bool
        if let keyResolver = context.speechAPIKey {
            hasKey = (try? await keyResolver(configuration.provider))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        } else { hasKey = false }
        let keyOptional = configuration.provider == .openAICompatible
        let guidance = hasKey ? "An API key is configured; synthesis needs approval in Focus Studio."
            : (keyOptional ? "No key is configured; compatible endpoints may allow keyless access. Synthesis needs approval in Focus Studio."
               : "Add this provider's API key in Settings → AI models → AI narration.")
        return AIToolResult(text: "Speech: \(configuration.provider.title) · \(configuration.model) · \(configuration.voice). " + guidance, data: [
                "configured": true, "key_configured": AIJSONValue(hasKey),
                "key_required": AIJSONValue(!keyOptional),
                "provider": AIJSONValue(configuration.provider.rawValue),
                "model": AIJSONValue(configuration.model), "voice": AIJSONValue(configuration.voice),
                "available_providers": .array([SpeechProviderKind.minimax, .openAI, .openAICompatible].map {
                    ["id": AIJSONValue($0.rawValue), "title": AIJSONValue($0.title)]
                }),
                "subtitle_timing": "Measured duration of each generated segment; not word alignment.",
                "requires_app_approval": true,
            ])
    }
}

/// Narration is synthesized in a staging directory, validated against the current
/// picture, then imported by the app and committed with its captions in one edit.
/// Runtime approval is inside this shared tool, so external MCP cannot bypass it.
public struct GenerateVoiceoverTool: AIAssistantTool {
    public let name = "generate_voiceover"
    public let summary = "Generate narration after picture edits. Uses configured provider and exact model/voice. App approval of provider, model, voice and script precedes network access. Measured segment durations set captions; existing content is preserved. Overlap, overflow and caption fit are validated. Never automatically retry a provider request."
    public init() {}
    public var parametersSchema: [String: Any] { ["type": "object", "required": ["segments"], "properties": [
        "project_id": DemoEditingSupport.projectProperty,
        "segments": ["type": "array", "minItems": 1, "maxItems": 24, "description": "1–24 short sentences; at most 4,000 characters total.", "items": [
            "type": "object", "required": ["text", "start_time"], "properties": [
                "text": ["type": "string", "description": "1–240 characters for speech/caption; split sentences that exceed the caption safe area."],
                "start_time": ["type": "number", "minimum": 0, "description": "Output start in seconds, before the video ends."],
            ]]],
        "provider": ["type": "string", "enum": [SpeechProviderKind.minimax, .openAI, .openAICompatible].map(\.rawValue), "description": "Must match Settings; omit to use selection."],
        "model": ["type": "string", "description": "Exact model ID. Omit to use the configured model."],
        "voice": ["type": "string", "description": "Exact voice ID. Omit to use the configured voice."],
        "speed": ["type": "number", "minimum": 0.5, "maximum": 2, "default": 1, "description": "Speech speed from 0.5 to 2 times normal; default 1."],
        "add_captions": ["type": "boolean", "default": true, "description": "Append matching captions; preserve existing chapters."],
    ]] }

    public func run(arguments raw: [String: Any], context: AIAssistantContext,
                    progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let segments = try SpeechToolSupport.segments(raw)
        let speed = try VoiceoverToolSupport.number(raw, "speed", range: 0.5...2) ?? 1
        let captions = try SpeechToolSupport.boolean(raw, "add_captions") ?? true
        guard let resolve = context.speechConfiguration, let keyResolver = context.speechAPIKey else {
            throw AIToolError.failed("Configure a speech provider, model, voice and API key in Focus Studio Settings → AI models → AI narration.")
        }
        var configuration = try await resolve()
        if let provider = try SpeechToolSupport.optionalString(raw, "provider"), provider != configuration.provider.rawValue {
            throw AIToolError.invalidArgument("Requested provider differs from Settings. Select that speech provider in Focus Studio first; no request was sent.")
        }
        if let model = try SpeechToolSupport.optionalString(raw, "model") { configuration.model = model }
        if let voice = try SpeechToolSupport.optionalString(raw, "voice") { configuration.voice = voice }
        try SpeechGenerationService.validate(configuration: configuration)
        let key = try await keyResolver(configuration.provider)
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || configuration.provider == .openAICompatible else {
            throw AIToolError.failed("The selected speech provider has no API key. Add it in Focus Studio Settings.")
        }
        let project = try await DemoEditingSupport.project(raw, context: context)
        let app = try AIToolSupport.requireApp(context)
        try SpeechToolSupport.validateStarts(segments, project: project, captions: captions)
        guard let confirm = context.confirmSpeechGeneration else {
            throw AIToolError.failed("Speech generation needs the approval dialog in Focus Studio. No request was sent.")
        }
        let summary = SpeechToolSupport.approval(configuration, segments: segments, speed: speed, captions: captions, chinese: context.isChinese)
        guard await confirm(summary) else {
            throw AIToolFailure("Speech generation was declined or cancelled. No request was sent.",
                                data: ["status": "declined", "requests_sent": 0, "retry": false])
        }
        try Task.checkCancellation()
        guard try await AIToolSupport.requireProject(context) == project else {
            throw AIToolError.failed("The project changed while speech approval was open. Nothing was generated; review the new timeline first.")
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("focus-speech-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let service = SpeechGenerationService()
        var staged: [SpeechToolSupport.Staged] = []
        var imported: [VoiceoverClip] = []
        var requestsSent = 0
        do {
            for (index, segment) in segments.enumerated() {
                try Task.checkCancellation()
                progress(context.isChinese ? "正在生成旁白 \(index + 1)/\(segments.count)…" : "Generating narration \(index + 1)/\(segments.count)…")
                let request = SpeechGenerationRequest(text: segment.text, configuration: configuration, speed: speed)
                requestsSent += 1
                let result: SpeechGenerationResult
                if let generate = context.speechGenerate { result = try await generate(request, key) }
                else { result = try await service.generate(request: request, apiKey: key) }
                try Task.checkCancellation()
                guard ["mp3", "wav", "m4a", "aac", "aiff"].contains(result.fileExtension.lowercased()), !result.audioData.isEmpty else {
                    throw AIToolError.failed("The speech provider returned no supported audio.")
                }
                let url = staging.appendingPathComponent("sentence-\(index + 1)").appendingPathExtension(result.fileExtension.lowercased())
                try result.audioData.write(to: url, options: .atomic)
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw AIToolError.failed("The speech provider returned an unreadable audio file.")
                }
                let duration = try await track.load(.timeRange).duration.seconds
                guard duration.isFinite, duration >= (captions ? ChapterMath.minimumDuration : 0.02) else {
                    throw AIToolError.failed("Generated speech is too short for a usable narration/caption segment.")
                }
                staged.append(.init(segment: segment, url: url, duration: duration))
                try SpeechToolSupport.validateIntervals(staged, project: project, captions: captions)
                if index + 1 < segments.count, segment.start + duration > segments[index + 1].start + 0.000_001 {
                    throw AIToolError.invalidArgument("Generated speech would overlap the next sentence. Shorten its script or increase spacing before generating the remaining segments.")
                }
            }
            guard try await AIToolSupport.requireProject(context) == project else {
                throw AIToolError.failed("The project changed during synthesis. Narration was not inserted; inspect the timeline before generating again.")
            }
            for item in staged {
                try Task.checkCancellation()
                var clip = try await app.importVoiceover(from: item.url, projectID: project.id)
                imported.append(clip)
                guard abs(clip.sourceDuration - item.duration) < 0.05 else {
                    throw AIToolError.failed("Imported speech duration differs from the validated generation; nothing was inserted.")
                }
                clip.title = String(item.segment.text.prefix(80))
                clip.timelineStart = item.segment.start
                clip.sourceStart = 0; clip.sourceEnd = clip.sourceDuration
                imported[imported.count - 1] = try clip.validated()
            }
            try Task.checkCancellation()
            let finalClips = imported, finalStaged = staged, finalConfiguration = configuration
            let receipt = try await AIToolSupport.edit(context, projectID: project.id) { current -> AIJSONValue in
                try Task.checkCancellation()
                guard current == project else {
                    throw AIToolError.failed("The project changed before insertion. Narration and captions were not changed.")
                }
                var audio = current.settings.resolvedProductDemoAudio
                audio.voiceovers = (audio.voiceovers ?? []) + finalClips
                current.settings.productDemoAudio = audio
                let newChapters = captions ? finalStaged.map { item in
                    DemoChapter(start: item.segment.start, end: item.end, title: "", caption: item.segment.text)
                } : []
                if captions { current.chapters = (current.chapters ?? []) + newChapters }
                return ["project_id": AIJSONValue(current.id.uuidString),
                        "provider": AIJSONValue(finalConfiguration.provider.rawValue),
                        "model": AIJSONValue(finalConfiguration.model), "voice": AIJSONValue(finalConfiguration.voice),
                        "voiceovers": .array(finalClips.map(VoiceoverToolSupport.data)),
                        "captions": .array(newChapters.map { ["id": AIJSONValue($0.id.uuidString), "start": .rounded($0.start), "end": .rounded($0.end), "text": AIJSONValue($0.caption)] }),
                        "subtitle_timing": "measured_segment_duration", "word_aligned": false,
                        "billing": "Provider usage applies; exact price is reported by the provider."]
            }
            return AIToolResult(text: context.isChinese ? "已添加 \(imported.count) 段 AI 旁白\(captions ? "及同步句子字幕" : "")。" : "Added \(imported.count) AI narration segments\(captions ? " with matching sentence captions" : "").", data: receipt)
        } catch {
            await app.discardImportedVoiceovers(imported, projectID: project.id)
            if error is CancellationError || Task.isCancelled {
                let usage = requestsSent > 0
                    ? " Provider requests may have incurred usage; do not automatically retry."
                    : " No provider request was sent and no generation usage was incurred."
                throw AIToolFailure("Narration generation was cancelled. No narration or captions were inserted." + usage,
                                    data: ["status": "cancelled", "requests_sent": AIJSONValue(requestsSent),
                                           "project_modified_by_tool": false, "retry": false])
            }
            throw AIToolFailure(error.localizedDescription + (requestsSent > 0 ? " No narration/captions were inserted. Provider requests may have incurred usage; do not automatically retry." : ""),
                                data: ["status": "generation_failed", "requests_sent": AIJSONValue(requestsSent), "project_modified_by_tool": false, "retry": false])
        }
    }
}

enum SpeechToolSupport {
    struct Segment: Sendable { let text: String; let start: Double }
    struct Staged: Sendable {
        let segment: Segment; let url: URL; let duration: Double
        var end: Double { segment.start + duration }
    }

    static func optionalString(_ raw: [String: Any], _ key: String) throws -> String? {
        guard let value = raw[key] else { return nil }
        guard let text = value as? String else { throw AIToolError.invalidArgument("\(key) must be a string.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200, !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw AIToolError.invalidArgument("\(key) must be a nonempty single-line identifier of at most 200 characters.")
        }
        return trimmed
    }

    static func boolean(_ raw: [String: Any], _ key: String) throws -> Bool? {
        guard let value = raw[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw AIToolError.invalidArgument("\(key) must be a boolean.")
        }
        return number.boolValue
    }

    static func segments(_ raw: [String: Any]) throws -> [Segment] {
        guard let entries = raw["segments"] as? [[String: Any]], (1...24).contains(entries.count) else {
            throw AIToolError.invalidArgument("segments must contain 1–24 short sentences with text and start_time.")
        }
        let result = try entries.map { entry -> Segment in
            guard let rawText = entry["text"] as? String else { throw AIToolError.invalidArgument("Every segment needs text.") }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...240).contains(text.count), let start = try VoiceoverToolSupport.number(entry, "start_time", range: 0...86_400) else {
                throw AIToolError.invalidArgument("Every segment needs 1–240 text characters and a finite start_time.")
            }
            return Segment(text: text, start: start)
        }.sorted { $0.start < $1.start }
        guard result.reduce(0, { $0 + $1.text.count }) <= 4_000,
              zip(result, result.dropFirst()).allSatisfy({ $0.start < $1.start }) else {
            throw AIToolError.invalidArgument("Narration is limited to 4,000 characters, with distinct segment start times.")
        }
        return result
    }

    static func validateStarts(_ segments: [Segment], project: RecordingProject, captions: Bool) throws {
        guard (project.settings.resolvedProductDemoAudio.voiceovers?.count ?? 0) + segments.count <= 64 else {
            throw AIToolError.invalidArgument("A project supports up to 64 voiceover clips.")
        }
        guard segments.allSatisfy({ $0.start < project.duration }) else {
            throw AIToolError.invalidArgument("Every narration segment must start before the video ends.")
        }
        if captions {
            let canvas = ProjectVideoRenderer.geometry(for: project).outputSize
            let style = project.settings.resolvedCaptionStyle
            // Existing captions may sort before or between these segments. Use
            // the largest possible chapter number for the same safe-area budget.
            let number = style.showsChapterNumber ? (project.chapters?.count ?? 0) + segments.count : nil
            for (index, segment) in segments.enumerated() {
                guard CaptionRenderer.canRenderFullText(text: segment.text, number: number, canvasSize: canvas, style: style) else {
                    throw AIToolError.invalidArgument("Caption segment \(index + 1) does not fit the video's safe area at the current text size. Split this sentence into shorter segments before generating narration; no request was sent.")
                }
            }
        }
        let minimal = segments.map { Staged(segment: $0, url: URL(fileURLWithPath: "/"), duration: captions ? ChapterMath.minimumDuration : 0.02) }
        try validateIntervals(minimal, project: project, captions: captions)
    }

    static func validateIntervals(_ items: [Staged], project: RecordingProject, captions: Bool) throws {
        for (index, item) in items.enumerated() {
            guard item.end <= project.duration + 0.000_001 else {
                throw AIToolError.invalidArgument("Narration segment \(index + 1) ends at \(AIToolSupport.seconds(item.end)) s, beyond the video's \(AIToolSupport.seconds(project.duration)) s. Shorten its script or leave more picture time; audio was not truncated.")
            }
            if index > 0, items[index - 1].end > item.segment.start + 0.000_001 {
                throw AIToolError.invalidArgument("Generated narration segments overlap. Shorten a sentence or increase their spacing.")
            }
            let overlaps: (Double, Double) -> Bool = { start, end in item.segment.start < end - 0.000_001 && item.end > start + 0.000_001 }
            if (project.settings.resolvedProductDemoAudio.voiceovers ?? []).contains(where: { $0.isEnabled && overlaps($0.timelineStart, $0.timelineEnd) }) {
                throw AIToolError.invalidArgument("Generated narration overlaps an existing voiceover. Existing speech was preserved; choose an empty interval.")
            }
            if captions, (project.chapters ?? []).contains(where: { $0.isEnabled && overlaps($0.start, $0.end) }) {
                throw AIToolError.invalidArgument("Generated captions overlap existing chapters. Existing captions were preserved; choose an empty interval or add_captions false.")
            }
        }
    }

    static func approval(_ configuration: SpeechGenerationConfiguration, segments: [Segment], speed: Double, captions: Bool, chinese: Bool) -> String {
        let characters = segments.reduce(0) { $0 + $1.text.count }
        let heading = chinese ? "生成付费 AI 旁白" : "Generate paid AI narration"
        let warning = chinese ? "文稿将发送给此语音服务。按提供商用量计费，确切价格未知；不会自动重试。" : "The script is sent to this speech service. Provider usage is billed; exact price is unknown. No automatic retries."
        let lines = segments.map { "\(AIToolSupport.seconds($0.start)) s — \($0.text)" }.joined(separator: "\n")
        return "\(heading)\n\(configuration.provider.title) · \(configuration.model) · \(configuration.voice)\n\(configuration.baseURL)\n\(characters) characters · \(segments.count) segments · \(speed)×\n\(captions ? (chinese ? "添加句子字幕" : "Add sentence captions") : (chinese ? "不添加字幕" : "No captions"))\n\(warning)\n\n\(lines)"
    }
}
