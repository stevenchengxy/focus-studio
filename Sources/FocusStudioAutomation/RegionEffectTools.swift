import CoreFoundation
import FocusStudioCore
import Foundation

/// The UI and model both author the same fixed source rectangle. Output times
/// are mapped inside the atomic write so a simultaneous clip edit cannot attach
/// the highlight to the wrong source frame.
enum RegionEffectToolSupport {
    static let coordinateSpace = "uncropped_source_top_left_normalized"
    static var properties: [String: Any] { [
        "project_id": DemoEditingSupport.projectProperty,
        "clip_id": TimelineToolSupport.clipProperty,
        "start": ["type": "number", "minimum": 0, "description": "Start in output-timeline seconds, 0 or higher and inside clip_id. Use get_timeline to locate the clip."],
        "end": ["type": "number", "minimum": 0, "description": "End in output-timeline seconds, 0 or higher and inside the same clip; at least 0.1 seconds after start."],
        "x": ["type": "number", "minimum": 0, "maximum": 0.99, "description": "Rectangle left, from 0 to 0.99 in the uncropped source frame, not styled output. Inspect capture_frame with source_frame=true first."],
        "y": ["type": "number", "minimum": 0, "maximum": 0.99, "description": "Rectangle top, from 0 to 0.99 in the uncropped source frame."],
        "width": ["type": "number", "minimum": 0.01, "maximum": 1, "description": "Source-normalized width, from 0.01 to 1; x + width must be at most 1."],
        "height": ["type": "number", "minimum": 0.01, "maximum": 1, "description": "Source-normalized height, from 0.01 to 1; y + height must be at most 1."],
        "preset": ["type": "string", "enum": RegionEffectPreset.allCases.map(\.rawValue), "description": "spotlight (clear detail), lift (floating card), tilt (2D entry, settles level), perspective (3D tilted plane), magnify (circular lens centered inside selection), outline (draw-on border). Default spotlight."],
        "background": ["type": "string", "enum": RegionEffectBackground.allCases.map(\.rawValue), "description": "dim, blur or none; default dim. This is emphasis, not privacy redaction."],
        "scale": ["type": "number", "minimum": 1, "maximum": 3, "default": 1.35, "description": "Card magnification, from 1 to 3; default 1.35 for a new effect. Omission preserves an existing effect's value."],
        "intensity": ["type": "number", "minimum": 0, "maximum": 1, "default": 0.55, "description": "Background emphasis strength, from 0 to 1; default 0.55 for a new effect. Omission preserves an existing effect's value."],
        "ease_in": ["type": "number", "minimum": 0, "maximum": 5, "default": 0.35, "description": "Entrance duration from 0 to 5 seconds; default 0.35 for a new effect. Omission preserves an existing value. Short spans proportionally shorten entrance and exit."],
        "ease_out": ["type": "number", "minimum": 0, "maximum": 5, "default": 0.35, "description": "Return duration from 0 to 5 seconds; default 0.35 for a new effect. Omission preserves an existing value."],
        "perspective_degrees": ["type": "number", "minimum": -35, "maximum": 35, "default": 18, "description": "Perspective card yaw, from -35 to 35 degrees; default 18. The card smoothly tilts in, holds and restores. Omission preserves existing angle."],
        "outline_width": ["type": "number", "minimum": 1, "maximum": 12, "default": 3, "description": "Magnifier/outline rim width, 1 to 12 pixels at 1080 source height; default 3. Scales with output framing. Omission preserves existing width."],
        "enabled": ["type": "boolean", "default": true, "description": "Whether the effect is enabled; default true for a new effect. Omission preserves an existing effect's state."],
    ] }

    static let numericKeys = ["start", "end", "x", "y", "width", "height", "scale", "intensity", "ease_in", "ease_out", "perspective_degrees", "outline_width"]

    static func validateKeys(_ raw: [String: Any], schema: [String: Any]) throws {
        let known = Set((schema["properties"] as? [String: Any] ?? [:]).keys)
        let unknown = raw.keys.filter { !known.contains($0) && !(raw[$0] is NSNull) }.sorted()
        guard unknown.isEmpty else {
            throw AIToolError.invalidArgument("Unknown region effect arguments: \(unknown.joined(separator: ", ")).")
        }
    }

    static func numericValues(_ args: AIToolArguments) throws -> [String: Double] {
        var values: [String: Double] = [:]
        for key in numericKeys where args.has(key) {
            guard let number = args.raw[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                throw AIToolError.invalidArgument("\(key) must be a finite JSON number.")
            }
            values[key] = number.doubleValue
        }
        return values
    }

    static func enabled(_ args: AIToolArguments) throws -> Bool? {
        guard args.has("enabled") else { return nil }
        guard let number = args.raw["enabled"] as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw AIToolError.invalidArgument("enabled must be a JSON boolean.")
        }
        return number.boolValue
    }

    static func choice<T: RawRepresentable>(_ key: String, args: AIToolArguments, type: T.Type) throws -> T? where T.RawValue == String {
        guard args.has(key) else { return nil }
        guard let value = args.raw[key] as? String, let choice = T(rawValue: value) else {
            throw AIToolError.invalidArgument("Unsupported \(key). Read the tool's allowed values.")
        }
        return choice
    }

    static func effectID(_ args: AIToolArguments) throws -> UUID {
        guard let value = args.raw["effect_id"] as? String, let id = UUID(uuidString: value) else {
            throw AIToolError.invalidArgument("effect_id must be a UUID from get_project.region_effects.")
        }
        return id
    }

    static func apply(_ values: [String: Double], to effect: inout RegionEffect,
                      in project: RecordingProject) throws {
        if values["start"] != nil || values["end"] != nil {
            let timeline = try DemoVideoTimeline(project: project)
            guard let placement = timeline.placements.first(where: { $0.clip.id == effect.clipID }) else {
                throw AIToolError.invalidArgument("The selected clip no longer exists. Read get_timeline again.")
            }
            let start = values["start"] ?? (placement.start + effect.sourceStart - placement.clip.sourceStart)
            let end = values["end"] ?? (placement.start + effect.sourceEnd - placement.clip.sourceStart)
            guard start >= placement.start, end <= placement.end + 0.000_001,
                  end - start >= 0.1 - 0.000_001 else {
                throw AIToolError.invalidArgument("start/end must span at least 0.1 seconds inside clip_id's visible output range. For a trimmed-away effect, supply both times.")
            }
            effect.sourceStart = placement.clip.sourceStart + start - placement.start
            effect.sourceEnd = placement.clip.sourceStart + end - placement.start
        }
        effect.rect.x = values["x"] ?? effect.rect.x
        effect.rect.y = values["y"] ?? effect.rect.y
        effect.rect.width = values["width"] ?? effect.rect.width
        effect.rect.height = values["height"] ?? effect.rect.height
        effect.scale = values["scale"] ?? effect.scale
        effect.intensity = values["intensity"] ?? effect.intensity
        effect.easeIn = values["ease_in"] ?? effect.easeIn
        effect.easeOut = values["ease_out"] ?? effect.easeOut
        effect.perspectiveDegrees = values["perspective_degrees"] ?? effect.perspectiveDegrees
        effect.outlineWidth = values["outline_width"] ?? effect.outlineWidth
    }

    static func validate(_ effect: RegionEffect, in project: RecordingProject) throws {
        do { try RegionEffectValidator.validate(effect, in: project, excludingID: effect.id) }
        catch { throw AIToolError.invalidArgument(error.localizedDescription) }
    }

    static func data(_ effect: RegionEffect, placement: RegionEffectPlacement?) -> AIJSONValue {
        ["id": AIJSONValue(effect.id.uuidString), "clip_id": AIJSONValue(effect.clipID.uuidString),
         "source_start": .rounded(effect.sourceStart), "source_end": .rounded(effect.sourceEnd),
         "start": placement.map { .rounded($0.start) } ?? .null,
         "end": placement.map { .rounded($0.end) } ?? .null,
         "visible_on_timeline": AIJSONValue(placement != nil),
         "coordinate_space": AIJSONValue(coordinateSpace),
         "rect": ["x": .rounded(effect.rect.x, places: 6), "y": .rounded(effect.rect.y, places: 6),
                  "width": .rounded(effect.rect.width, places: 6), "height": .rounded(effect.rect.height, places: 6)],
         "preset": AIJSONValue(effect.preset.rawValue), "background": AIJSONValue(effect.background.rawValue),
         "scale": .rounded(effect.scale), "intensity": .rounded(effect.intensity),
         "ease_in": .rounded(effect.easeIn), "ease_out": .rounded(effect.easeOut),
         "perspective_degrees": .rounded(effect.resolvedPerspectiveDegrees),
         "outline_width": .rounded(effect.resolvedOutlineWidth),
         "enabled": AIJSONValue(effect.isEnabled), "tracking": "fixed_rectangle"]
    }

    static func result(_ project: RecordingProject, effect: RegionEffect, verb: String, context: AIAssistantContext) throws -> AIToolResult {
        let placement = try RegionEffectTimeline(project: project).placements.first { $0.effect.id == effect.id }
        let data: AIJSONValue = ["project_id": AIJSONValue(project.id.uuidString),
                                 "effect_id": AIJSONValue(effect.id.uuidString),
                                 "region_effect": self.data(effect, placement: placement),
                                 "region_effect_count": AIJSONValue(project.regionEffects?.count ?? 0)]
        let message = context.isChinese ? "已\(verb == "Added" ? "添加" : "更新")局部强调。选区固定在源画面上；请预览入场、停留和回位。" : "\(verb) local highlight. Its source rectangle is fixed; preview entrance, hold and return."
        return AIToolResult(text: message + "\n" + String(decoding: try data.jsonData(), as: UTF8.self), data: data)
    }
}

public struct AddRegionEffectTool: AIAssistantTool {
    public let name = "add_region_effect"
    public let summary = "Emphasize a fixed source region with spotlight, lift, tilt, perspective, magnify or outline, preserving real UI pixels. Inspect a source_frame first, then give clip_id, output start/end and source-normalized x/y/width/height. No object tracking; enabled effects cannot overlap."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["clip_id", "start", "end", "x", "y", "width", "height"],
         "properties": RegionEffectToolSupport.properties]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        try RegionEffectToolSupport.validateKeys(raw, schema: parametersSchema)
        let args = AIToolArguments(raw)
        let clipID = try TimelineToolSupport.clipID(args)
        let values = try RegionEffectToolSupport.numericValues(args)
        for key in ["start", "end", "x", "y", "width", "height"] where values[key] == nil {
            throw AIToolError.invalidArgument("Missing required argument \(key).")
        }
        let preset = try RegionEffectToolSupport.choice("preset", args: args, type: RegionEffectPreset.self) ?? .spotlight
        let background = try RegionEffectToolSupport.choice("background", args: args, type: RegionEffectBackground.self) ?? .dim
        let enabled = try RegionEffectToolSupport.enabled(args) ?? true
        let source = try await DemoEditingSupport.project(raw, context: context)
        let updated = try await AIToolSupport.edit(context, projectID: source.id) { project -> (RecordingProject, RegionEffect) in
            var effect = RegionEffect(clipID: clipID, sourceStart: 0, sourceEnd: 1,
                                      rect: .init(x: 0, y: 0, width: 1, height: 1),
                                      preset: preset, background: background, isEnabled: enabled)
            try RegionEffectToolSupport.apply(values, to: &effect, in: project)
            try RegionEffectToolSupport.validate(effect, in: project)
            project.regionEffects = (project.regionEffects ?? []) + [effect]
            return (project, effect)
        }
        return try RegionEffectToolSupport.result(updated.0, effect: updated.1, verb: "Added", context: context)
    }
}

public struct UpdateRegionEffectTool: AIAssistantTool {
    public let name = "update_region_effect"
    public let summary = "Adjust one local highlight by stable effect_id. Omitted fields stay unchanged, including clip binding; output start/end must remain in that clip. The selection does not track scrolling."
    public init() {}
    public var parametersSchema: [String: Any] {
        var properties = RegionEffectToolSupport.properties
        properties.removeValue(forKey: "clip_id")
        properties["effect_id"] = ["type": "string", "description": "Stable UUID from get_project.region_effects."]
        return ["type": "object", "required": ["effect_id"], "properties": properties]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        try RegionEffectToolSupport.validateKeys(raw, schema: parametersSchema)
        let args = AIToolArguments(raw), id = try RegionEffectToolSupport.effectID(args)
        let values = try RegionEffectToolSupport.numericValues(args)
        let preset = try RegionEffectToolSupport.choice("preset", args: args, type: RegionEffectPreset.self)
        let background = try RegionEffectToolSupport.choice("background", args: args, type: RegionEffectBackground.self)
        let enabled = try RegionEffectToolSupport.enabled(args)
        guard !values.isEmpty || preset != nil || background != nil || enabled != nil else {
            throw AIToolError.invalidArgument("Supply at least one region effect property to update.")
        }
        let source = try await DemoEditingSupport.project(raw, context: context)
        let updated = try await AIToolSupport.edit(context, projectID: source.id) { project -> (RecordingProject, RegionEffect) in
            guard let index = project.regionEffects?.firstIndex(where: { $0.id == id }), var effect = project.regionEffects?[index] else {
                throw AIToolError.invalidArgument("This highlight no longer exists. Read get_project again.")
            }
            try RegionEffectToolSupport.apply(values, to: &effect, in: project)
            if let preset { effect.preset = preset }; if let background { effect.background = background }
            if let enabled { effect.isEnabled = enabled }
            try RegionEffectToolSupport.validate(effect, in: project)
            project.regionEffects?[index] = effect
            return (project, effect)
        }
        return try RegionEffectToolSupport.result(updated.0, effect: updated.1, verb: "Updated", context: context)
    }
}

public struct DeleteRegionEffectTool: AIAssistantTool {
    public let name = "delete_region_effect"
    public let summary = "Remove one local highlight by stable effect_id, including a trimmed-away highlight. This does not delete source media or clips."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["effect_id"], "properties": [
            "project_id": DemoEditingSupport.projectProperty,
            "effect_id": ["type": "string", "description": "Stable UUID from get_project.region_effects."],
        ]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        try RegionEffectToolSupport.validateKeys(raw, schema: parametersSchema)
        let id = try RegionEffectToolSupport.effectID(AIToolArguments(raw))
        let source = try await DemoEditingSupport.project(raw, context: context)
        let count = try await AIToolSupport.edit(context, projectID: source.id) { project -> Int in
            guard project.regionEffects?.contains(where: { $0.id == id }) == true else {
                throw AIToolError.invalidArgument("This highlight no longer exists. Read get_project again.")
            }
            project.regionEffects?.removeAll { $0.id == id }
            return project.regionEffects?.count ?? 0
        }
        let data: AIJSONValue = ["project_id": AIJSONValue(source.id.uuidString), "effect_id": AIJSONValue(id.uuidString), "region_effect_count": AIJSONValue(count)]
        return AIToolResult(text: context.isChinese ? "已删除局部强调。" : "Removed the local highlight.", data: data)
    }
}
