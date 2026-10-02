import FocusStudioCore
import Foundation

/// The project's output-frame grid, shared by read-only positioning and
/// opt-in exact-frame image capture. Time values are seconds, not source
/// movie frame numbers (which may use a different cadence).
enum TimelineFrameGrid {
    static func count(duration: Double, rate: Int) -> Int? {
        let scaled = duration * Double(rate)
        guard duration.isFinite, duration > 0, scaled.isFinite,
              scaled < Double(Int.max) / 2 else { return nil }
        return max(1, Int(ceil(scaled - 0.000_000_01)))
    }

    static func index(at seconds: Double, rate: Int, count: Int) -> Int {
        // A time produced by time(index:rate:) can multiply back to just
        // below its integer frame due to binary floating-point rounding.
        min(count - 1, max(0, Int(floor(seconds * Double(rate) + 0.000_000_1))))
    }

    static func time(index: Int, rate: Int) -> Double { Double(index) / Double(rate) }
}

/// The video track is a list of source ranges with stable clip IDs. The same
/// operations back the editor and the assistant, so a tool cannot invent an
/// edit that the visible timeline cannot reproduce.
enum TimelineToolSupport {
    static let projectProperty = DemoEditingSupport.projectProperty
    static let clipProperty: [String: Any] = ["type": "string", "description": "Stable clip UUID from get_timeline. Read the current project again after a split or deletion."]

    static func clipID(_ arguments: AIToolArguments) throws -> UUID {
        guard let id = arguments.string("clip_id").flatMap(UUID.init(uuidString:)) else {
            throw AIToolError.invalidArgument("clip_id must be a clip UUID from get_timeline.")
        }
        return id
    }

    static func number(_ key: String, arguments: AIToolArguments) throws -> Double {
        guard let value = arguments.double(key) else {
            throw AIToolError.invalidArgument("\(key) must be a finite number.")
        }
        return value
    }

    static func timelineData(_ project: RecordingProject) throws -> AIJSONValue {
        let timeline = try DemoVideoTimeline(project: project)
        let transitions = Dictionary(uniqueKeysWithValues: timeline.transitions.map { ($0.fromClipID, $0) })
        let clips: [AIJSONValue] = timeline.placements.enumerated().map { index, placement in
            let clip = placement.clip
            let transition = transitions[clip.id]
            return [
                "id": AIJSONValue(clip.id.uuidString),
                "index": AIJSONValue(index),
                "timeline_start": .rounded(placement.start),
                "timeline_end": .rounded(placement.end),
                "source_start": .rounded(clip.sourceStart),
                "source_end": .rounded(clip.sourceEnd),
                "source_min": .rounded(timeline.sourceBounds(for: clip).lowerBound),
                "source_max": .rounded(timeline.sourceBounds(for: clip).upperBound),
                "duration": .rounded(placement.duration),
                "source_audio_volume": .rounded(clip.sourceAudioVolume),
                "media_asset_id": clip.mediaAssetID.map { AIJSONValue($0.uuidString) } ?? .null,
                "transition_after": transition.map { value -> AIJSONValue in
                    ["preset": AIJSONValue(value.preset.rawValue),
                     "duration": .rounded(value.duration),
                     "outgoing_duration": .rounded(value.resolvedOutgoingDuration),
                     "incoming_duration": .rounded(value.resolvedIncomingDuration),
                     "outgoing_curve": AIJSONValue(value.resolvedOutgoingCurve.rawValue),
                     "incoming_curve": AIJSONValue(value.resolvedIncomingCurve.rawValue)]
                } ?? .null,
            ]
        }
        return [
            "project_id": AIJSONValue(project.id.uuidString),
            "title": AIJSONValue(project.title),
            "duration": .rounded(timeline.duration),
            "source_duration": .rounded(timeline.sourceDuration),
            "clip_count": AIJSONValue(clips.count),
            "clips": .array(clips),
            "transition_presets": .array((["cut", "fadeToBlack", "flash"] as [String]).map { AIJSONValue($0) }),
            "has_explicit_clip_track": AIJSONValue(project.videoClips != nil),
        ]
    }

    static func edit(
        _ raw: [String: Any], context: AIAssistantContext, operation: DemoVideoEditOperation,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> AIToolResult {
        let source = try await DemoEditingSupport.project(raw, context: context)
        let app = try AIToolSupport.requireApp(context)
        progress(context.isChinese ? "正在编辑视频片段…" : "Editing video clips…")
        let updated = try await AIToolSupport.appAction(context) {
            try await app.applyVideoEdit(projectID: source.id, operation: operation)
        }
        let copy = updated.id != source.id
        let data = AIToolSupport.merged(try timelineData(updated), [
            "source_project_id": AIJSONValue(source.id.uuidString),
            "created_copy": AIJSONValue(copy),
        ])
        let message = context.isChinese
            ? (copy ? "已创建可编辑副本并完成片段编辑。原片已保留。" : "已更新视频时间线。")
            : (copy ? "Created an editable copy and applied the clip edit. The original is preserved." : "Updated the video timeline.")
        return AIToolResult(text: message + " Project \(updated.id.uuidString).\n" + String(decoding: try data.jsonData(), as: UTF8.self), data: data)
    }
}

public struct GetTimelineTool: AIAssistantTool {
    public let name = "get_timeline"
    public let summary = "Read every video clip's stable ID, source range, output timeline range, source-audio volume and outgoing transition. No edit is made."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "properties": ["project_id": TimelineToolSupport.projectProperty]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let project = try await DemoEditingSupport.project(raw, context: context)
        let data = try TimelineToolSupport.timelineData(project)
        let text = context.isChinese
            ? "已读取 \(data["clip_count"]?.intValue ?? 0) 个片段，时长 \(AIToolSupport.seconds(project.duration)) 秒。"
            : "Read \(data["clip_count"]?.intValue ?? 0) clips, \(AIToolSupport.seconds(project.duration)) seconds."
        return AIToolResult(text: text + "\n" + String(decoding: try data.jsonData(), as: UTF8.self), data: data)
    }
}

/// Resolve a human or model's approximate position onto the project's output
/// frame grid. This deliberately does not seek the editor: inspection is a
/// preview, while moving the white playhead is an explicit UI action.
public struct ResolveTimelineFrameTool: AIAssistantTool {
    public let name = "resolve_timeline_frame"
    public let summary = "Find the exact output frame at a time or zero-based frame index, with its clip ID and source time. Read-only: it does not move the editor playhead or edit the video."
    public init() {}

    public var parametersSchema: [String: Any] {
        ["type": "object", "properties": [
            "project_id": TimelineToolSupport.projectProperty,
            "at_seconds": ["type": "number", "minimum": 0,
                           "description": "Approximate output-timeline seconds from 0 to project duration. Supply this or frame_index, not both. The project duration selects the last visible frame."],
            "frame_index": ["type": "integer", "minimum": 0,
                            "description": "Exact zero-based output frame index, 0 or higher. Supply this or at_seconds, not both."],
        ]]
    }

    public func run(arguments raw: [String: Any], context: AIAssistantContext,
                    progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let arguments = AIToolArguments(raw)
        guard arguments.has("at_seconds") != arguments.has("frame_index") else {
            throw AIToolError.invalidArgument("Supply exactly one of at_seconds or frame_index.")
        }
        let project = try await DemoEditingSupport.project(raw, context: context)
        let timeline = try DemoVideoTimeline(project: project)
        let rate = project.settings.frameRate.clamped(to: 1...120)
        guard let frameCount = TimelineFrameGrid.count(duration: timeline.duration, rate: rate) else {
            throw AIToolError.failed("The video timeline has no valid output frames.")
        }

        let index: Int
        if arguments.has("at_seconds") {
            guard let seconds = arguments.double("at_seconds"),
                  seconds >= 0, seconds <= timeline.duration else {
                throw AIToolError.invalidArgument("at_seconds must be between 0 and the output timeline duration.")
            }
            index = TimelineFrameGrid.index(at: seconds, rate: rate, count: frameCount)
        } else {
            guard let number = arguments.double("frame_index"),
                  number >= 0, number.rounded() == number,
                  let requested = Int(exactly: number), requested < frameCount else {
                throw AIToolError.invalidArgument("frame_index must be an integer from 0 to \(frameCount - 1).")
            }
            index = requested
        }

        let time = TimelineFrameGrid.time(index: index, rate: rate)
        guard let clipIndex = timeline.placements.firstIndex(where: { time >= $0.start && time < $0.end }) else {
            throw AIToolError.failed("No clip contains output frame \(index). Refresh get_timeline.")
        }
        let placement = timeline.placements[clipIndex]
        let sourceTime = placement.clip.sourceStart + time - placement.start
        // The clip editor requires at least 0.1 seconds on both sides.
        let canSplit = time > placement.start + 0.1 && time < placement.end - 0.1
        let data: AIJSONValue = [
            "project_id": AIJSONValue(project.id.uuidString),
            "frame_rate": AIJSONValue(rate),
            "frame_count": AIJSONValue(frameCount),
            "frame_index": AIJSONValue(index),
            "time_seconds": AIJSONValue(time),
            "next_frame_time_seconds": AIJSONValue(min(timeline.duration, TimelineFrameGrid.time(index: index + 1, rate: rate))),
            "clip_id": AIJSONValue(placement.clip.id.uuidString),
            "clip_index": AIJSONValue(clipIndex),
            "clip_timeline_start": AIJSONValue(placement.start),
            "clip_timeline_end": AIJSONValue(placement.end),
            "source_time_seconds": AIJSONValue(sourceTime),
            "media_asset_id": placement.clip.mediaAssetID.map { AIJSONValue($0.uuidString) } ?? .null,
            "can_split_here": AIJSONValue(canSplit),
        ]
        let message = context.isChinese
            ? "第 \(index) 帧位于 \(AIToolSupport.seconds(time)) 秒，片段 \(clipIndex + 1)。仅定位预览，未移动播放针。"
            : "Frame \(index) is at \(AIToolSupport.seconds(time)) s in clip \(clipIndex + 1). This read-only lookup did not move the playhead."
        return AIToolResult(text: message + "\n" + String(decoding: try data.jsonData(), as: UTF8.self), data: data)
    }
}

public struct SplitClipTool: AIAssistantTool {
    public let name = "split_clip"
    public let summary = "Split one clip at an absolute output-timeline time. The returned timeline has stable IDs for the resulting clips; first edit creates a separate working copy."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["clip_id", "at"], "properties": [
            "project_id": TimelineToolSupport.projectProperty,
            "clip_id": TimelineToolSupport.clipProperty,
            "at": ["type": "number", "description": "Absolute playhead time in seconds on the current output timeline, strictly inside this clip."],
        ]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let args = AIToolArguments(raw)
        let operation = DemoVideoEditOperation.split(clipID: try TimelineToolSupport.clipID(args), at: try TimelineToolSupport.number("at", arguments: args))
        return try await TimelineToolSupport.edit(raw, context: context, operation: operation, progress: progress)
    }
}

public struct TrimClipTool: AIAssistantTool {
    public let name = "trim_clip"
    public let summary = "Set or restore a clip's in/out points in source-video seconds. It retains the same clip ID and retimes later clips; get_timeline shows the full source_min/source_max bounds."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["clip_id", "source_start", "source_end"], "properties": [
            "project_id": TimelineToolSupport.projectProperty,
            "clip_id": TimelineToolSupport.clipProperty,
            "source_start": ["type": "number", "description": "New in point in seconds of this clip's source; may extend an earlier trim as far as source_min."],
            "source_end": ["type": "number", "description": "New out point in seconds of this clip's source; must be after source_start and may extend an earlier trim as far as source_max."],
        ]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let args = AIToolArguments(raw)
        let operation = DemoVideoEditOperation.trim(clipID: try TimelineToolSupport.clipID(args), sourceStart: try TimelineToolSupport.number("source_start", arguments: args), sourceEnd: try TimelineToolSupport.number("source_end", arguments: args))
        return try await TimelineToolSupport.edit(raw, context: context, operation: operation, progress: progress)
    }
}

public struct DeleteClipTool: AIAssistantTool {
    public let name = "delete_clip"
    public let summary = "Remove one clip from the editable timeline by stable ID. It does not delete the source recording or library project."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["clip_id"], "properties": [
            "project_id": TimelineToolSupport.projectProperty,
            "clip_id": TimelineToolSupport.clipProperty,
        ]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let operation = DemoVideoEditOperation.delete(clipID: try TimelineToolSupport.clipID(AIToolArguments(raw)))
        return try await TimelineToolSupport.edit(raw, context: context, operation: operation, progress: progress)
    }
}

public struct MoveClipTool: AIAssistantTool {
    public let name = "move_clip"
    public let summary = "Move a clip to a zero-based position in the video track. IDs remain stable, and the output timeline is recalculated."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["clip_id", "to_index"], "properties": [
            "project_id": TimelineToolSupport.projectProperty,
            "clip_id": TimelineToolSupport.clipProperty,
            "to_index": ["type": "integer", "minimum": 0, "description": "Destination index in the current video track, starting at 0."],
        ]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let args = AIToolArguments(raw)
        guard let rawIndex = args.double("to_index"), rawIndex >= 0, rawIndex.rounded() == rawIndex,
              let index = Int(exactly: rawIndex) else {
            throw AIToolError.invalidArgument("to_index must be a non-negative integer.")
        }
        return try await TimelineToolSupport.edit(raw, context: context, operation: .move(clipID: try TimelineToolSupport.clipID(args), toIndex: index), progress: progress)
    }
}

public struct SetTransitionTool: AIAssistantTool {
    public let name = "set_transition"
    public let summary = "Set the transition after one clip. Optionally shape the outgoing and incoming sides separately with durations and visual curves."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["clip_id", "preset", "duration"], "properties": [
            "project_id": TimelineToolSupport.projectProperty,
            "clip_id": TimelineToolSupport.clipProperty,
            "preset": ["type": "string", "enum": ["cut", "fadeToBlack", "flash"], "description": "Visual transition after this clip; the final clip cannot have an outgoing transition."],
            "duration": ["type": "number", "minimum": 0, "maximum": 2, "description": "Seconds. Use 0 for cut, or 0.1–2 for fadeToBlack/flash."],
            "outgoing_duration": ["type": "number", "minimum": 0, "maximum": 2, "description": "Optional 0–2 seconds fading the outgoing clip before the join. Supply with incoming_duration; their sum must equal duration."],
            "incoming_duration": ["type": "number", "minimum": 0, "maximum": 2, "description": "Optional 0–2 seconds revealing the incoming clip after the join. Supply with outgoing_duration; their sum must equal duration."],
            "outgoing_curve": ["type": "string", "enum": ["linear", "smooth", "easeIn", "easeOut"], "description": "Optional visual curve before the join; requires both side durations. Default linear."],
            "incoming_curve": ["type": "string", "enum": ["linear", "smooth", "easeIn", "easeOut"], "description": "Optional visual curve after the join; requires both side durations. Default linear."],
        ]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let args = AIToolArguments(raw)
        guard let preset = args.string("preset").flatMap(DemoTransitionPreset.init(rawValue:)) else {
            throw AIToolError.invalidArgument("preset must be cut, fadeToBlack or flash.")
        }
        let duration = try TimelineToolSupport.number("duration", arguments: args)
        guard (preset == .cut && duration == 0) || (preset != .cut && (0.1...2).contains(duration)) else {
            throw AIToolError.invalidArgument("Use duration 0 for cut, or 0.1–2 seconds for fadeToBlack/flash.")
        }
        let clipID = try TimelineToolSupport.clipID(args)
        let hasSideParameters = ["outgoing_duration", "incoming_duration", "outgoing_curve", "incoming_curve"].contains { raw[$0] != nil }
        if hasSideParameters {
            guard preset != .cut,
                  let outgoing = args.double("outgoing_duration"),
                  let incoming = args.double("incoming_duration"),
                  outgoing >= 0, incoming >= 0,
                  abs(outgoing + incoming - duration) < 0.000_001 else {
                throw AIToolError.invalidArgument("Supply both non-negative side durations; their sum must equal the effect duration.")
            }
            let outgoingCurve = args.string("outgoing_curve").flatMap(DemoTransitionCurve.init(rawValue:)) ?? .linear
            let incomingCurve = args.string("incoming_curve").flatMap(DemoTransitionCurve.init(rawValue:)) ?? .linear
            if raw["outgoing_curve"] != nil && args.string("outgoing_curve").flatMap(DemoTransitionCurve.init(rawValue:)) == nil
                || raw["incoming_curve"] != nil && args.string("incoming_curve").flatMap(DemoTransitionCurve.init(rawValue:)) == nil {
                throw AIToolError.invalidArgument("Transition curves must be linear, smooth, easeIn or easeOut.")
            }
            return try await TimelineToolSupport.edit(raw, context: context,
                operation: .setTransitionParameters(fromClipID: clipID, preset: preset,
                                                    outgoingDuration: outgoing, incomingDuration: incoming,
                                                    outgoingCurve: outgoingCurve, incomingCurve: incomingCurve), progress: progress)
        }
        return try await TimelineToolSupport.edit(raw, context: context,
            operation: .setTransition(fromClipID: clipID, preset: preset, duration: duration), progress: progress)
    }
}

public struct SetClipAudioTool: AIAssistantTool {
    public let name = "set_clip_audio"
    public let summary = "Set one clip's source-audio volume from 0 (mute) to 2 (200%). Preview and export use this mix. Background music is controlled separately."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["clip_id", "volume"], "properties": [
            "project_id": TimelineToolSupport.projectProperty,
            "clip_id": TimelineToolSupport.clipProperty,
            "volume": ["type": "number", "minimum": 0, "maximum": 2, "description": "Source-audio gain on this clip: 0 mutes; 1 is original level; 2 is 200%."],
        ]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let args = AIToolArguments(raw)
        return try await TimelineToolSupport.edit(raw, context: context, operation: .setClipAudio(clipID: try TimelineToolSupport.clipID(args), volume: try TimelineToolSupport.number("volume", arguments: args)), progress: progress)
    }
}

public struct SetImageDurationTool: AIAssistantTool {
    public let name = "set_image_duration"
    public let summary = "Lengthen or shorten an imported still-image clip by stable clip ID. Its source image stays reusable in the media library, and the edit can be undone."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["clip_id", "duration"], "properties": [
            "project_id": TimelineToolSupport.projectProperty,
            "clip_id": TimelineToolSupport.clipProperty,
            "duration": ["type": "number", "minimum": 0.1, "description": "Visible duration of this still in seconds, at least 0.1."],
        ]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let args = AIToolArguments(raw)
        let clipID = try TimelineToolSupport.clipID(args)
        let seconds = try TimelineToolSupport.number("duration", arguments: args)
        guard seconds >= 0.1 else { throw AIToolError.invalidArgument("duration must be at least 0.1 seconds.") }
        return try await TimelineToolSupport.edit(raw, context: context,
            operation: .setImageDuration(clipID: clipID, duration: seconds), progress: progress)
    }
}

public struct UndoClipEditTool: AIAssistantTool {
    public let name = "undo_clip_edit"
    public let summary = "Undo the most recent editor change on the open working project, including clip, zoom and other project settings. Retains its project ID and source media. Can be called repeatedly until its finite history is empty."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "properties": ["project_id": TimelineToolSupport.projectProperty]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let project = try await DemoEditingSupport.project(raw, context: context)
        let app = try AIToolSupport.requireApp(context)
        progress(context.isChinese ? "正在撤销上一步视频剪辑…" : "Undoing the last video edit…")
        let updated = try await AIToolSupport.appAction(context) {
            try await app.undoVideoEdit(projectID: project.id)
        }
        let data = try TimelineToolSupport.timelineData(updated)
        let message = context.isChinese ? "已撤销上一步视频剪辑。" : "Undid the last video edit."
        return AIToolResult(text: message + " Project \(updated.id.uuidString).\n" + String(decoding: try data.jsonData(), as: UTF8.self), data: data)
    }
}

public struct RedoClipEditTool: AIAssistantTool {
    public let name = "redo_clip_edit"
    public let summary = "Reapply the latest undone editor change on the open working project. A new edit clears the redo history. Returns the current timeline."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "properties": ["project_id": TimelineToolSupport.projectProperty]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let project = try await DemoEditingSupport.project(raw, context: context)
        let app = try AIToolSupport.requireApp(context)
        progress(context.isChinese ? "正在重做视频剪辑…" : "Redoing the video edit…")
        let updated = try await AIToolSupport.appAction(context) {
            try await app.redoVideoEdit(projectID: project.id)
        }
        let data = try TimelineToolSupport.timelineData(updated)
        let message = context.isChinese ? "已重做上一步视频剪辑。" : "Redid the last video edit."
        return AIToolResult(text: message + " Project \(updated.id.uuidString).\n" + String(decoding: try data.jsonData(), as: UTF8.self), data: data)
    }
}
