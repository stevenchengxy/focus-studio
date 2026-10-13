import CoreFoundation
import FocusStudioCore
import Foundation

enum VoiceoverToolSupport {
    static func number(_ raw: [String: Any], _ key: String, range: ClosedRange<Double>) throws -> Double? {
        guard let value = raw[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, range.contains(number.doubleValue) else {
            throw AIToolError.invalidArgument("\(key) must be a finite number from \(range.lowerBound) to \(range.upperBound).")
        }
        return number.doubleValue
    }
    static func data(_ clip: VoiceoverClip) -> AIJSONValue {
        ["id": AIJSONValue(clip.id.uuidString), "title": AIJSONValue(clip.title),
         "path": AIJSONValue(clip.filePath), "source_duration": .rounded(clip.sourceDuration),
         "source_in": .rounded(clip.sourceStart), "source_out": .rounded(clip.sourceEnd),
         "timeline_start": .rounded(clip.timelineStart), "timeline_end": .rounded(clip.timelineEnd),
         "volume": .rounded(clip.volume), "fade_in": .rounded(clip.fadeIn), "fade_out": .rounded(clip.fadeOut),
         "enabled": AIJSONValue(clip.isEnabled)]
    }
}

struct EditVoiceoverTool: AIAssistantTool {
    let name = "edit_voiceover"
    let summary = "Import, trim, position, mix or remove a non-looping voiceover clip. action add copies a local audio file into the project and returns a stable id; update/remove require voiceover_id from get_project. Times are seconds. The source file is never altered. Ripple video edits also cut/reorder voiceover; undo_clip_edit restores it. Audio past the video end is not played."
    var parametersSchema: [String: Any] { ["type": "object", "required": ["action"], "properties": [
        "action": ["type": "string", "enum": ["add", "update", "remove"]],
        "voiceover_id": ["type": "string", "description": "Stable id required for update/remove."],
        "path": ["type": "string", "description": "Local audio file required for add; copied into the project."],
        "title": ["type": "string"],
        "source_in": ["type": "number", "minimum": 0],
        "source_out": ["type": "number", "minimum": 0, "description": "Must be after source_in and within source_duration; omitted on add means full source."],
        "timeline_start": ["type": "number", "minimum": 0],
        "volume": ["type": "number", "minimum": 0, "maximum": 2],
        "fade_in": ["type": "number", "minimum": 0, "maximum": 30],
        "fade_out": ["type": "number", "minimum": 0, "maximum": 30],
        "enabled": ["type": "boolean"]
    ]] }
    func run(arguments raw: [String: Any], context: AIAssistantContext,
             progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw), action = try arguments.requiredString("action")
        guard ["add", "update", "remove"].contains(action) else { throw AIToolError.invalidArgument("Unknown voiceover action.") }
        let project = try await AIToolSupport.requireProject(context)
        let id: UUID?
        if action == "add" { id = nil }
        else {
            guard let value = UUID(uuidString: try arguments.requiredString("voiceover_id")) else {
                throw AIToolError.invalidArgument("voiceover_id must be an existing UUID.")
            }; id = value
        }
        var values: [String: Double] = [:]
        for key in ["source_in", "source_out", "timeline_start", "volume", "fade_in", "fade_out"] {
            let maximum = key == "volume" ? 2.0 : (key.hasPrefix("fade_") ? 30 : 86_400)
            values[key] = try VoiceoverToolSupport.number(raw, key, range: 0...maximum)
        }
        let enabled: Bool?
        if let value = raw["enabled"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw AIToolError.invalidArgument("enabled must be a boolean.")
            }; enabled = number.boolValue
        } else { enabled = nil }
        let title = arguments.string("title")
        if raw["title"] != nil, !(raw["title"] is String) || title == nil || title!.count > 120 {
            throw AIToolError.invalidArgument("title must contain 1–120 characters.")
        }
        var imported: VoiceoverClip?
        if action == "add" {
            guard (project.settings.resolvedProductDemoAudio.voiceovers?.count ?? 0) < 64 else {
                throw AIToolError.invalidArgument("A project supports up to 64 voiceover clips.")
            }
            let path = try arguments.requiredString("path")
            guard case let .local(url) = try AIToolPaths.reference(path, context: context),
                  AIToolPaths.kind(of: url) == .audio else { throw AIToolError.invalidArgument("Choose a local audio file.") }
            let app = try AIToolSupport.requireApp(context)
            imported = try await app.importVoiceover(from: url, projectID: project.id)
        }
        let newClip = imported, edits = values
        let result = try await AIToolSupport.edit(context, projectID: project.id) { project -> AIJSONValue in
            var audio = project.settings.resolvedProductDemoAudio, clips = project.settings.resolvedProductDemoAudio.voiceovers ?? []
            if action == "remove" {
                guard let index = clips.firstIndex(where: { $0.id == id }) else { throw AIToolError.invalidArgument("Voiceover clip not found.") }
                clips.remove(at: index)
            } else {
                let index = clips.firstIndex { $0.id == id }
                guard var clip = newClip ?? index.map({ clips[$0] }) else { throw AIToolError.invalidArgument("Voiceover clip not found.") }
                if let title { clip.title = title }
                if let value = edits["source_in"] { clip.sourceStart = value }
                if let value = edits["source_out"] { clip.sourceEnd = value }
                if let value = edits["timeline_start"] { clip.timelineStart = value }
                if let value = edits["volume"] { clip.volume = value }
                if let value = edits["fade_in"] { clip.fadeIn = value }
                if let value = edits["fade_out"] { clip.fadeOut = value }
                if let enabled { clip.isEnabled = enabled }
                _ = try clip.validated()
                if let index { clips[index] = clip }
                else {
                    guard clips.count < 64 else { throw AIToolError.invalidArgument("A project supports up to 64 voiceover clips.") }
                    clips.append(clip)
                }
            }
            audio.voiceovers = clips; project.settings.productDemoAudio = audio
            return ["project_id": AIJSONValue(project.id.uuidString),
                    "voiceovers": .array(clips.map(VoiceoverToolSupport.data))]
        }
        return AIToolResult(text: context.isChinese ? "旁白音轨已更新。" : "Voiceover updated.", data: result)
    }
}

struct SetAudioMixTool: AIAssistantTool {
    let name = "set_audio_mix"
    let summary = "Set the recorded-audio gain, music gain/fades and automatic music ducking during enabled voiceover clips. Omitted fields remain unchanged. duck_music false disables ducking; true defaults to 25% of music volume. These edits use the same mix for preview/export and can be undone."
    var parametersSchema: [String: Any] { ["type": "object", "properties": [
        "source_volume": ["type": "number", "minimum": 0, "maximum": 2],
        "music_volume": ["type": "number", "minimum": 0, "maximum": 1],
        "music_fade_in": ["type": "number", "minimum": 0, "maximum": 30],
        "music_fade_out": ["type": "number", "minimum": 0, "maximum": 30],
        "duck_music": ["type": "boolean"],
        "duck_level": ["type": "number", "minimum": 0, "maximum": 1, "description": "Music multiplier during speech; only used when ducking is enabled."]
    ]] }
    func run(arguments raw: [String: Any], context: AIAssistantContext,
             progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let source = try VoiceoverToolSupport.number(raw, "source_volume", range: 0...2)
        let music = try VoiceoverToolSupport.number(raw, "music_volume", range: 0...1)
        let fadeIn = try VoiceoverToolSupport.number(raw, "music_fade_in", range: 0...30)
        let fadeOut = try VoiceoverToolSupport.number(raw, "music_fade_out", range: 0...30)
        let duck = try VoiceoverToolSupport.number(raw, "duck_level", range: 0...1)
        let enabled: Bool?
        if let value = raw["duck_music"] {
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw AIToolError.invalidArgument("duck_music must be a boolean.") }
            enabled = n.boolValue
        } else { enabled = nil }
        let project = try await AIToolSupport.requireProject(context)
        let data = try await AIToolSupport.edit(context, projectID: project.id) { project -> AIJSONValue in
            var audio = project.settings.resolvedProductDemoAudio
            if let source { audio.sourceAudioVolume = source }
            if let music { audio.backgroundMusicVolume = music }
            if let fadeIn { audio.backgroundMusicFadeIn = fadeIn }
            if let fadeOut { audio.backgroundMusicFadeOut = fadeOut }
            if enabled == false { audio.voiceoverDuckingLevel = nil }
            else if enabled == true || duck != nil { audio.voiceoverDuckingLevel = duck ?? audio.voiceoverDuckingLevel ?? 0.25 }
            project.settings.productDemoAudio = audio
            return AIProjectReport.audioData(project.settings, tracks: [])
        }
        return AIToolResult(text: context.isChinese ? "声音混音已更新。" : "Audio mix updated.", data: data)
    }
}
