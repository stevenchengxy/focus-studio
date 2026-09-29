@preconcurrency import AVFoundation
import FocusStudioCore
import Foundation

/// Prepares a factual, bounded reference for a text-directed AI variation of
/// one timeline clip. No project clip is replaced and no paid API is called.
struct PrepareClipAIReferenceTool: AIAssistantTool {
    let name = "prepare_clip_ai_reference"
    let summary = "Prepare one existing video-track clip for an AI variation: render its first/last appearance and a short silent reference MP4. The user can describe the desired change, then generate_video can use these paths. This does not edit or replace the original clip."

    var parametersSchema: [String: Any] {
        ["type": "object", "required": ["clip_id"], "properties": [
            "project_id": TimelineToolSupport.projectProperty,
            "clip_id": TimelineToolSupport.clipProperty,
            "reference_seconds": ["type": "number", "minimum": 0.1, "maximum": 8, "description": "Length of the silent visual reference, up to 8 seconds. Default: the shorter of the clip and 8 seconds."],
        ]]
    }

    func run(arguments raw: [String: Any], context: AIAssistantContext,
             progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let project = try await DemoEditingSupport.project(raw, context: context)
        let args = AIToolArguments(raw)
        let clipID = try TimelineToolSupport.clipID(args)
        let timeline = try DemoVideoTimeline(project: project)
        guard let placement = timeline.placements.first(where: { $0.clip.id == clipID }) else {
            throw AIToolError.invalidArgument("clip_id is not in the current timeline; refresh get_timeline.")
        }
        let requested = args.double("reference_seconds") ?? min(placement.duration, 8)
        guard requested >= 0.1, requested <= 8 else {
            throw AIToolError.invalidArgument("reference_seconds must be 0.1–8 seconds.")
        }
        let referenceDuration = min(requested, placement.duration)
        var previewProject = project
        previewProject.settings.exportWidth = 960
        progress(context.isChinese ? "正在从选定片段提取参考画面…" : "Preparing reference frames from the selected clip…")
        let prepared = try await ProjectVideoRenderer.prepare(project: previewProject)
        let generator = AVAssetImageGenerator(asset: prepared.asset)
        generator.videoComposition = prepared.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.04, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.04, preferredTimescale: 600)

        let firstTime = min(placement.end - 0.01, placement.start + 0.04)
        let lastTime = max(placement.start + 0.01, placement.end - 0.04)
        let firstFrame = try context.newAssetURL(prefix: "clip-first", fileExtension: "png")
        let lastFrame = try context.newAssetURL(prefix: "clip-last", fileExtension: "png")
        do {
            let (firstImage, _) = try await generator.image(at: CMTime(seconds: firstTime, preferredTimescale: 600))
            try AIToolSupport.writePNG(firstImage, to: firstFrame)
            let (lastImage, _) = try await generator.image(at: CMTime(seconds: lastTime, preferredTimescale: 600))
            try AIToolSupport.writePNG(lastImage, to: lastFrame)
        } catch {
            try? FileManager.default.removeItem(at: firstFrame)
            try? FileManager.default.removeItem(at: lastFrame)
            throw error
        }

        // Copy only the rendered video track; audio from a recorded product
        // session must not be sent to a media model as an incidental reference.
        let referenceVideo = try context.newAssetURL(prefix: "clip-reference", fileExtension: "mp4")
        var usableVideo: URL?
        if let sourceTrack = try await prepared.asset.loadTracks(withMediaType: .video).first {
            let silent = AVMutableComposition()
            if let videoTrack = silent.addMutableTrack(withMediaType: .video, preferredTrackID: sourceTrack.trackID) {
                let fullRange = CMTimeRange(start: .zero, duration: CMTime(seconds: prepared.duration, preferredTimescale: 600))
                try videoTrack.insertTimeRange(fullRange, of: sourceTrack, at: .zero)
                if let session = AVAssetExportSession(asset: silent, presetName: AVAssetExportPresetMediumQuality) {
                    session.videoComposition = prepared.videoComposition
                    session.timeRange = CMTimeRange(
                        start: CMTime(seconds: placement.start, preferredTimescale: 600),
                        duration: CMTime(seconds: referenceDuration, preferredTimescale: 600))
                    session.shouldOptimizeForNetworkUse = true
                    do {
                        progress(context.isChinese ? "正在渲染无声片段参考…" : "Rendering a silent clip reference…")
                        try await ProjectVideoRenderer.runExportSession(session, to: referenceVideo, as: .mp4, progress: nil)
                        // Local Ark reference media is inlined as a data URL.
                        // Keep comfortably below the tool's 30 MiB cap.
                        if AIToolSupport.fileSize(referenceVideo) <= 25 * 1_024 * 1_024 {
                            usableVideo = referenceVideo
                        } else {
                            try? FileManager.default.removeItem(at: referenceVideo)
                        }
                    } catch is CancellationError {
                        try? FileManager.default.removeItem(at: referenceVideo)
                        throw CancellationError()
                    } catch {
                        // The two stills remain usable for image-to-video.
                        try? FileManager.default.removeItem(at: referenceVideo)
                    }
                }
            }
        }

        var attachments = [firstFrame, lastFrame]
        if let usableVideo { attachments.append(usableVideo) }
        let data: AIJSONValue = [
            "project_id": AIJSONValue(project.id.uuidString),
            "clip_id": AIJSONValue(clipID.uuidString),
            "timeline_start": .rounded(placement.start),
            "timeline_end": .rounded(placement.end),
            "clip_duration": .rounded(placement.duration),
            "reference_duration": .rounded(referenceDuration),
            "first_frame": AIJSONValue(firstFrame),
            "last_frame": AIJSONValue(lastFrame),
            "reference_video": usableVideo.map(AIJSONValue.init) ?? .null,
            "reference_has_audio": AIJSONValue(false),
        ]
        let intro = context.isChinese
            ? "已提取片段的首尾画面和\(usableVideo == nil ? "（视频参考不可用）" : "无声视频参考")。原片段未修改。请先预览，再描述要改变的视觉效果；真实界面文字请保留原录屏。"
            : "Prepared first/last frames and \(usableVideo == nil ? "no usable video reference" : "a silent video reference"). The original clip is unchanged. Preview the frames, then describe the visual change; keep the real recording for accurate UI text."
        return AIToolResult(text: intro + "\n" + String(decoding: try data.jsonData(), as: UTF8.self), attachments: attachments, data: data)
    }
}
