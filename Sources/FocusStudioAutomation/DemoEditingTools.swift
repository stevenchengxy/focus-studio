@preconcurrency import AVFoundation
import Foundation
import FocusStudioCore

enum DemoEditingSupport {
    static func project(_ raw: [String: Any], context: AIAssistantContext) async throws -> RecordingProject {
        let args = AIToolArguments(raw)
        let requested: UUID?
        if args.has("project_id") {
            guard let id = args.string("project_id").flatMap(UUID.init(uuidString:)) else { throw AIToolError.invalidArgument("project_id must be a project UUID.") }
            if let pinned = context.projectID, pinned != id { throw AIToolError.invalidArgument("project_id does not match this call's project.") }
            requested = id
        } else { requested = context.projectID }
        if let requested {
            guard let project = await MainActor.run(body: { context.app?.project(id: requested) ?? context.readProject().flatMap { $0.id == requested ? $0 : nil } }) else { throw AIToolError.noProject }
            return project
        }
        return try await AIToolSupport.requireProject(context)
    }
    static func rangeData(_ ranges: [DemoKeepRange]) -> AIJSONValue {
        .array(ranges.map { ["start": AIJSONValue($0.start), "end": AIJSONValue($0.end)] })
    }
    static let projectProperty: [String: Any] = ["type": "string", "description": "Project UUID; defaults to the open project."]
}

public struct AnalyzeDemoPacingTool: AIAssistantTool {
    public let name = "analyze_demo_pacing"
    public let summary = "Suggest source-time keep ranges from complete recorded input, without changing the project. Input silence is not proof of visual inactivity; inspect loading/results/reading before cutting. Source audio and enabled chapters are protected."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "properties": [
            "project_id": DemoEditingSupport.projectProperty,
            "pre_roll": ["type": "number", "minimum": 0.1, "maximum": 10, "description": "Seconds kept before every input, from 0.1 to 10; default 0.8."],
            "post_roll": ["type": "number", "minimum": 0.1, "maximum": 15, "description": "Seconds kept after every input and at both ends, from 0.1 to 15; default 1.8."],
            "minimum_gap": ["type": "number", "minimum": 0.5, "maximum": 60, "description": "Only propose removing input-free gaps at least this long after context, from 0.5 to 60 seconds; default 3."],
        ]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let project = try await DemoEditingSupport.project(raw, context: context)
        let args = AIToolArguments(raw)
        func number(_ key: String, fallback: Double) throws -> Double {
            guard args.has(key) else { return fallback }
            guard let value = args.double(key) else { throw AIToolError.invalidArgument("\(key) must be a finite number.") }
            return value
        }
        let url = URL(fileURLWithPath: project.sourceVideoPath)
        // Failed media inspection must never be treated as silent audio.
        let audioTracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        let audioPresent = !audioTracks.isEmpty
        let proposal = try DemoPacingAnalyzer.analyze(project, hasSourceAudio: audioPresent,
            preRoll: number("pre_roll", fallback: 0.8), postRoll: number("post_roll", fallback: 1.8), minimumGap: number("minimum_gap", fallback: 3))
        let data: AIJSONValue = [
            "project_id": AIJSONValue(project.id.uuidString), "source_audio_present": AIJSONValue(audioPresent),
            "original_duration": AIJSONValue(project.duration), "edited_duration": AIJSONValue(proposal.edit.duration),
            "removed_seconds": AIJSONValue(project.duration - proposal.edit.duration),
            "keep_ranges": DemoEditingSupport.rangeData(proposal.edit.ranges),
            "removed_ranges": DemoEditingSupport.rangeData(proposal.edit.removedRanges),
            "input_evidence_count": AIJSONValue(proposal.evidenceCount),
            "warnings": .array(proposal.warnings.map { AIJSONValue($0) }),
        ]
        let text = "Pacing proposal: \(AIToolSupport.seconds(project.duration)) → \(AIToolSupport.seconds(proposal.edit.duration)) seconds, \(proposal.edit.ranges.count) retained sections. The project is unchanged. " + proposal.warnings.joined(separator: " ") + "\n" + String(decoding: try data.jsonData(), as: UTF8.self)
        return AIToolResult(text: text, data: data)
    }
}

public struct CreateDemoCutTool: AIAssistantTool {
    public let name = "create_demo_cut"
    public let summary = "Create a new editable project from reviewed source-time keep_ranges. Preserve the original; cut video/audio and remap cursor, clicks, zooms and chapters together. Subsequent edits must use the returned new project ID and timeline."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["keep_ranges"], "properties": [
            "project_id": DemoEditingSupport.projectProperty,
            "title": ["type": "string", "description": "New project title; defaults to the original plus Edited."],
            "keep_ranges": ["type": "array", "description": "1–128 source-time intervals, ordered, non-overlapping, each at least 0.1 seconds. Removed intervals are omitted from the derived movie.", "items": ["type": "object", "required": ["start", "end"], "properties": ["start": ["type": "number"], "end": ["type": "number"]]]],
        ]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let project = try await DemoEditingSupport.project(raw, context: context)
        guard let rows = raw["keep_ranges"] as? [[String: Any]] else { throw AIToolError.invalidArgument("keep_ranges must be an array of start/end objects.") }
        let ranges = try rows.map { row -> DemoKeepRange in
            let args = AIToolArguments(row)
            guard let start = args.double("start"), let end = args.double("end") else { throw AIToolError.invalidArgument("Every keep range needs finite start/end seconds.") }
            return DemoKeepRange(start: start, end: end)
        }
        let edit = try DemoTimelineEdit(keepRanges: ranges, sourceDuration: project.duration)
        guard let app = context.app else { throw AIToolError.appUnavailable }
        let title = try AIToolSupport.optionalTitle(AIToolArguments(raw))
        progress("Creating the edited copy…")
        let result = try await AIToolSupport.appAction(context) { try await app.createDemoCut(projectID: project.id, keepRanges: edit.ranges, title: title) }
        var offset = 0.0
        let timingMap: [AIJSONValue] = edit.ranges.map { range in
            defer { offset += range.duration }
            return ["source_start": AIJSONValue(range.start), "source_end": AIJSONValue(range.end), "output_start": AIJSONValue(offset), "output_end": AIJSONValue(offset + range.duration)]
        }
        let data: AIJSONValue = [
            "timing_map": .array(timingMap),
            "source_project_id": AIJSONValue(project.id.uuidString), "project_id": AIJSONValue(result.id.uuidString),
            "original_duration": AIJSONValue(project.duration), "edited_duration": AIJSONValue(result.duration),
            "removed_seconds": AIJSONValue(project.duration - result.duration),
            "keep_ranges": DemoEditingSupport.rangeData(edit.ranges), "cut_count": AIJSONValue(max(0, edit.ranges.count - 1)),
            "zoom_count": AIJSONValue(result.zoomSegments.count), "click_count": AIJSONValue(result.resolvedClickEvents.count),
        ]
        return AIToolResult(text: "Created edited project \(result.id.uuidString): \(AIToolSupport.seconds(project.duration)) → \(AIToolSupport.seconds(result.duration)) seconds. Original project \(project.id.uuidString) is unchanged. Use the new project and timeline for previews, zoom adjustment and export.\n" + String(decoding: try data.jsonData(), as: UTF8.self), data: data)
    }
}

public struct UpdateZoomTool: AIAssistantTool {
    public let name = "update_zoom"
    public let summary = "Adjust one zoom's timing, target, scale, easing or enabled state by stable zoom_id; preserve all other zooms. The zoom becomes manual, retaining automatic-event provenance so regeneration cannot replace it."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["zoom_id"], "properties": [
            "project_id": DemoEditingSupport.projectProperty, "zoom_id": ["type": "string"],
            "start": ["type": "number"], "end": ["type": "number"],
            "x": ["type": "number", "minimum": 0, "maximum": 1, "description": "Horizontal focus, from 0 (left) to 1 (right)."],
            "y": ["type": "number", "minimum": 0, "maximum": 1, "description": "Vertical focus, from 0 (top) to 1 (bottom)."],
            "scale": ["type": "number", "minimum": 1.1, "maximum": 3, "description": "Magnification, from 1.1 to 3."],
            "ease_in": ["type": "number", "minimum": 0, "maximum": 5, "description": "Seconds to zoom in, from 0 to 5; omitted preserves the existing value."],
            "ease_out": ["type": "number", "minimum": 0, "maximum": 5, "description": "Seconds to zoom out, from 0 to 5; omitted preserves the existing value."],
            "enabled": ["type": "boolean"],
        ]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let args = AIToolArguments(raw)
        guard let id = args.string("zoom_id").flatMap(UUID.init(uuidString:)) else { throw AIToolError.invalidArgument("zoom_id must identify one zoom from get_project.") }
        let project = try await DemoEditingSupport.project(raw, context: context)
        let numeric = ["start", "end", "x", "y", "scale", "ease_in", "ease_out"]
        var values: [String: Double] = [:]
        for key in numeric where args.has(key) {
            guard let value = args.double(key) else { throw AIToolError.invalidArgument("\(key) must be a finite number.") }
            values[key] = value
        }
        let enabled: Bool?
        if args.has("enabled") {
            guard let value = args.bool("enabled") else { throw AIToolError.invalidArgument("enabled must be boolean.") }
            enabled = value
        } else { enabled = nil }
        guard !values.isEmpty || enabled != nil else { throw AIToolError.invalidArgument("Supply at least one zoom property to update.") }
        let edits = values
        let updated = try await AIToolSupport.edit(context, projectID: project.id) { current -> (zoom: ZoomSegment, index: Int) in
            guard let index = current.zoomSegments.firstIndex(where: { $0.id == id }) else { throw AIToolError.invalidArgument("This zoom is no longer in the project. Read get_project again.") }
            var segment = current.zoomSegments[index]
            if segment.kind == .automatic, segment.automaticSource == nil {
                segment.automaticSource = ZoomAutomaticSource(start: segment.start, targetX: segment.targetX, targetY: segment.targetY, originalEnd: segment.end)
            }
            segment.start = edits["start"] ?? segment.start; segment.end = edits["end"] ?? segment.end
            segment.targetX = edits["x"] ?? segment.targetX; segment.targetY = edits["y"] ?? segment.targetY
            segment.scale = edits["scale"] ?? segment.scale
            if let value = edits["ease_in"] { segment.zoomEaseIn = value }
            if let value = edits["ease_out"] { segment.zoomEaseOut = value }
            if let enabled { segment.isEnabled = enabled }
            guard segment.start >= 0, segment.end <= current.duration, segment.end - segment.start >= 0.2,
                  (0...1).contains(segment.targetX), (0...1).contains(segment.targetY), (1.1...3).contains(segment.scale),
                  (0...5).contains(segment.zoomEaseIn ?? 0), (0...5).contains(segment.zoomEaseOut ?? 0) else {
                throw AIToolError.invalidArgument("Zoom times must be within the project, at least 0.2 seconds apart; target 0–1, scale 1.1–3 and easing 0–5 seconds.")
            }
            segment.kind = .manual
            current.zoomSegments[index] = segment
            let number = AIToolSupport.orderedZooms(current).first { $0.segment.id == id }?.index ?? 1
            return (segment, number)
        }
        let zoom = updated.zoom
        let data: AIJSONValue = ["project_id": AIJSONValue(project.id.uuidString), "zoom_id": AIJSONValue(id.uuidString), "zoom": AIProjectReport.zoomData(index: updated.index, segment: zoom)]
        return AIToolResult(text: "Updated zoom \(id.uuidString): \(AIToolSupport.zoomLine(zoom)). Other zooms are unchanged.\n" + String(decoding: try data.jsonData(), as: UTF8.self), data: data)
    }
}
