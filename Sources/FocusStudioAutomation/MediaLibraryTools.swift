import FocusStudioCore
import Foundation

/// Project media is self-contained; the shared catalog is a separate source
/// from which a user can explicitly copy items into a project.
enum MediaLibraryToolSupport {
    static func data(_ asset: DemoMediaAsset) -> AIJSONValue {
        [
            "id": AIJSONValue(asset.id.uuidString),
            "title": AIJSONValue(asset.title),
            "path": AIJSONValue(asset.filePath),
            "kind": AIJSONValue(asset.kind.rawValue),
            "duration": .rounded(asset.duration),
            "width": AIJSONValue(asset.width),
            "height": AIJSONValue(asset.height),
        ]
    }

    static func data(_ project: RecordingProject) -> AIJSONValue {
        let assets = project.mediaAssets ?? []
        return [
            "project_id": AIJSONValue(project.id.uuidString),
            "count": AIJSONValue(assets.count),
            "assets": .array(assets.map(data)),
        ]
    }

    struct Registration {
        var globalAsset: DemoMediaAsset?
        var issue: String?
    }

    /// A generated video still exists on disk if registering it fails. Do
    /// not throw after the paid Ark task succeeded: an automatic retry would
    /// otherwise charge for and create a second video.
    static func registerGenerated(
        _ file: URL,
        context: AIAssistantContext
    ) async -> Registration {
        guard let app = context.app else {
            return Registration(issue: context.isChinese
                ? "生成文件已保存，但应用未连接；请稍后手动将其导入通用素材库。"
                : "The generated file was saved, but the app is unavailable. Import it to the shared library later.")
        }
        do {
            let assets = try await AIToolSupport.appAction(context) {
                try await app.importGlobalMedia(from: [file])
            }
            return Registration(globalAsset: assets.first)
        } catch {
            return Registration(issue: context.isChinese
                ? "生成文件已保存，但加入通用素材库失败：\(error.localizedDescription)。可稍后手动导入该文件。"
                : "The generated file was saved, but adding it to the shared library failed: \(error.localizedDescription). You can import the file later.")
        }
    }
}

public struct ListGlobalMediaAssetsTool: AIAssistantTool {
    public let name = "list_global_media_assets"
    public let summary = "List videos and images in the shared media library, independent of any project. Use an asset ID with add_global_media_to_project to copy one into the current demo."
    public init() {}
    public var parametersSchema: [String: Any] { ["type": "object", "properties": [:]] }
    public func run(arguments: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let app = try AIToolSupport.requireApp(context)
        let assets = try await app.listGlobalMedia()
        let payload: AIJSONValue = ["count": AIJSONValue(assets.count), "assets": .array(assets.map(MediaLibraryToolSupport.data))]
        return AIToolResult(text: (context.isChinese ? "通用素材库共有 \(assets.count) 个素材。" : "The shared media library has \(assets.count) assets.")
            + "\n" + String(decoding: try payload.jsonData(), as: UTF8.self), data: payload)
    }
}

public struct ImportGlobalMediaAssetTool: AIAssistantTool {
    public let name = "import_global_media_asset"
    public let summary = "Copy one local image or video into the shared media library. It does not change any project or place media on a timeline."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["path"], "properties": [
            "path": ["type": "string", "description": "Absolute local image/video path, or a path relative to the caller's working directory."],
        ]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let file = try AIToolPaths.existingLocalFile(AIToolArguments(raw).requiredString("path"), context: context)
        guard let kind = AIToolPaths.kind(of: file), kind == .image || kind == .video else {
            throw AIToolError.invalidArgument("path must name a supported video or image file.")
        }
        let app = try AIToolSupport.requireApp(context)
        progress(context.isChinese ? "正在导入通用素材…" : "Importing shared media…")
        let assets = try await AIToolSupport.appAction(context) { try await app.importGlobalMedia(from: [file]) }
        let payload: AIJSONValue = ["imported": .array(assets.map(MediaLibraryToolSupport.data))]
        return AIToolResult(text: (context.isChinese ? "已加入通用素材库。" : "Added to the shared media library.")
            + "\n" + String(decoding: try payload.jsonData(), as: UTF8.self), data: payload)
    }
}

public struct AddGlobalMediaToProjectTool: AIAssistantTool {
    public let name = "add_global_media_to_project"
    public let summary = "Copy one shared library item into the current project's private media library. This does not insert it on the timeline; use insert_media_asset afterwards. The first edit may create a working copy."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["global_asset_id"], "properties": [
            "project_id": DemoEditingSupport.projectProperty,
            "global_asset_id": ["type": "string", "description": "Stable UUID from list_global_media_assets."],
        ]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let project = try await DemoEditingSupport.project(raw, context: context)
        guard let id = AIToolArguments(raw).string("global_asset_id").flatMap(UUID.init(uuidString:)) else {
            throw AIToolError.invalidArgument("global_asset_id must be a UUID from list_global_media_assets.")
        }
        let app = try AIToolSupport.requireApp(context)
        guard try await app.listGlobalMedia().contains(where: { $0.id == id }) else {
            throw AIToolError.invalidArgument("global_asset_id was not found in the shared media library.")
        }
        let previous = Set((project.mediaAssets ?? []).map(\.id))
        progress(context.isChinese ? "正在复制到当前项目…" : "Copying into this project…")
        let updated = try await AIToolSupport.appAction(context) {
            try await app.importGlobalMediaToProject(assetIDs: [id], projectID: project.id)
        }
        let added = (updated.mediaAssets ?? []).filter { !previous.contains($0.id) }
        let payload: AIJSONValue = [
            "source_project_id": AIJSONValue(project.id.uuidString),
            "project_id": AIJSONValue(updated.id.uuidString),
            "created_copy": AIJSONValue(updated.id != project.id),
            "imported": .array(added.map(MediaLibraryToolSupport.data)),
            "media_library": MediaLibraryToolSupport.data(updated),
        ]
        return AIToolResult(text: (context.isChinese ? "素材已复制到项目库，可继续加入时间轴。" : "Copied to the project library; it can now be added to the timeline.")
            + "\n" + String(decoding: try payload.jsonData(), as: UTF8.self), data: payload)
    }
}

public struct ListMediaAssetsTool: AIAssistantTool {
    public let name = "list_media_assets"
    public let summary = "List reusable videos and images in this project's editor media library, with stable asset IDs and durations. Read this before inserting an asset. No edit is made."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "properties": ["project_id": DemoEditingSupport.projectProperty]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let project = try await DemoEditingSupport.project(raw, context: context)
        let payload = MediaLibraryToolSupport.data(project)
        let count = project.mediaAssets?.count ?? 0
        let text = context.isChinese ? "素材库中有 \(count) 个视频或图片。" : "The media library has \(count) video or image assets."
        return AIToolResult(text: text + "\n" + String(decoding: try payload.jsonData(), as: UTF8.self), data: payload)
    }
}

public struct ImportMediaAssetTool: AIAssistantTool {
    public let name = "import_media_asset"
    public let summary = "Copy one local video or image into the open project's reusable editor media library. This does not place it on the timeline. The first media edit may create a working copy; use the returned project ID afterwards."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["path"], "properties": [
            "project_id": DemoEditingSupport.projectProperty,
            "path": ["type": "string", "description": "Absolute local path, a file name from list_assets, or a path relative to the caller's working directory. PNG/JPEG/HEIC/WebP or MP4/MOV/M4V."],
        ]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let project = try await DemoEditingSupport.project(raw, context: context)
        let path = try AIToolArguments(raw).requiredString("path")
        let file = try AIToolPaths.existingLocalFile(path, context: context)
        guard let kind = AIToolPaths.kind(of: file), kind == .image || kind == .video else {
            throw AIToolError.invalidArgument("path must name a supported video or image file.")
        }
        let app = try AIToolSupport.requireApp(context)
        let previousIDs = Set((project.mediaAssets ?? []).map(\.id))
        progress(context.isChinese ? "正在导入素材…" : "Importing media…")
        let updated = try await AIToolSupport.appAction(context) {
            try await app.importEditorMedia(from: [file], projectID: project.id)
        }
        let imported = (updated.mediaAssets ?? []).filter { !previousIDs.contains($0.id) }
        let data: AIJSONValue = [
            "source_project_id": AIJSONValue(project.id.uuidString),
            "project_id": AIJSONValue(updated.id.uuidString),
            "created_copy": AIJSONValue(updated.id != project.id),
            "imported": .array(imported.map(MediaLibraryToolSupport.data)),
            "media_library": MediaLibraryToolSupport.data(updated),
        ]
        let intro = context.isChinese
            ? "已将 \(file.lastPathComponent) 加入素材库。可拖入时间轴，或调用 insert_media_asset。"
            : "Added \(file.lastPathComponent) to the media library. Drag it onto the timeline or call insert_media_asset."
        return AIToolResult(text: intro + " Project \(updated.id.uuidString).\n" + String(decoding: try data.jsonData(), as: UTF8.self), data: data)
    }
}

public struct InsertMediaAssetTool: AIAssistantTool {
    public let name = "insert_media_asset"
    public let summary = "Insert one imported video or image from the project media library at a zero-based clip index. Image duration defaults to 3 seconds. Returns the complete updated timeline; the edit can be undone."
    public init() {}
    public var parametersSchema: [String: Any] {
        ["type": "object", "required": ["asset_id", "at_index"], "properties": [
            "project_id": DemoEditingSupport.projectProperty,
            "asset_id": ["type": "string", "description": "Stable asset UUID from list_media_assets."],
            "at_index": ["type": "integer", "minimum": 0, "description": "Zero-based insertion position in get_timeline (0 inserts before the first clip)."],
            "duration": ["type": "number", "minimum": 0.1, "description": "Optional visible duration in seconds, at least 0.1. Omit for the full video or a 3-second image."],
        ]]
    }
    public func run(arguments raw: [String: Any], context: AIAssistantContext, progress: @escaping @Sendable (String) -> Void) async throws -> AIToolResult {
        let project = try await DemoEditingSupport.project(raw, context: context)
        let args = AIToolArguments(raw)
        guard let assetID = args.string("asset_id").flatMap(UUID.init(uuidString:)),
              (project.mediaAssets ?? []).contains(where: { $0.id == assetID }) else {
            throw AIToolError.invalidArgument("asset_id must identify an asset from list_media_assets.")
        }
        guard let value = args.double("at_index"), value >= 0, value.rounded() == value,
              let index = Int(exactly: value) else {
            throw AIToolError.invalidArgument("at_index must be a non-negative integer.")
        }
        let count = try DemoVideoTimeline(project: project).clips.count
        guard index <= count else { throw AIToolError.invalidArgument("at_index must be between 0 and \(count).") }
        let duration: Double?
        if args.has("duration") {
            guard let seconds = args.double("duration"), seconds >= 0.1 else {
                throw AIToolError.invalidArgument("duration must be at least 0.1 seconds.")
            }
            duration = seconds
        } else { duration = nil }
        let app = try AIToolSupport.requireApp(context)
        progress(context.isChinese ? "正在将素材加入视频滑轨…" : "Adding media to the video track…")
        let updated = try await AIToolSupport.appAction(context) {
            try await app.insertEditorMedia(projectID: project.id, assetID: assetID, atIndex: index, duration: duration)
        }
        let timeline = try TimelineToolSupport.timelineData(updated)
        let data = AIToolSupport.merged(timeline, [
            "source_project_id": AIJSONValue(project.id.uuidString),
            "created_copy": AIJSONValue(updated.id != project.id),
            "asset_id": AIJSONValue(assetID.uuidString),
        ])
        let message = context.isChinese ? "素材已加入视频滑轨，可撤销或继续剪辑。" : "The media asset is on the video track and can be undone or edited."
        return AIToolResult(text: message + " Project \(updated.id.uuidString).\n" + String(decoding: try data.jsonData(), as: UTF8.self), data: data)
    }
}
