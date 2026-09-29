import FocusStudioCore
import Foundation

extension AIAssistantTests.FakeApp {
    func listGlobalMedia() async throws -> [DemoMediaAsset] { globalMedia }

    func importGlobalMedia(from urls: [URL]) async throws -> [DemoMediaAsset] {
        let added = urls.map { file in
            DemoMediaAsset(title: file.lastPathComponent, filePath: file.path,
                           kind: file.pathExtension.lowercased() == "mp4" ? .video : .image,
                           duration: file.pathExtension.lowercased() == "mp4" ? 4 : 0,
                           width: 320, height: 180)
        }
        globalMedia += added
        return added
    }

    func importGlobalMediaToProject(assetIDs: [UUID], projectID: UUID) async throws -> RecordingProject {
        let files = try assetIDs.map { id -> URL in
            guard let asset = globalMedia.first(where: { $0.id == id }) else {
                throw AIToolError.invalidArgument("Shared asset missing")
            }
            return URL(fileURLWithPath: asset.filePath)
        }
        return try await importEditorMedia(from: files, projectID: projectID)
    }

    func importEditorMedia(from urls: [URL], projectID: UUID) async throws -> RecordingProject {
        guard let source = project(id: projectID) else { throw AIToolError.noProject }
        guard !urls.isEmpty else { throw AIToolError.invalidArgument("No media files supplied.") }
        var working = source
        if !videoEditingCopies.contains(source.id) {
            working.id = UUID()
            working.title += " · Edited"
            videoEditingCopies.insert(working.id)
            projects.append(working)
        }
        for file in urls {
            let kind: DemoMediaAssetKind = file.pathExtension.lowercased() == "mp4" ? .video : .image
            let asset = DemoMediaAsset(title: file.lastPathComponent, filePath: file.path, kind: kind,
                                       duration: kind == .video ? 4 : 0, width: 320, height: 180)
            working.mediaAssets = (working.mediaAssets ?? []) + [asset]
            imported.append(file)
        }
        if let index = projects.firstIndex(where: { $0.id == working.id }) { projects[index] = working }
        openID = working.id
        box.project = working
        return working
    }

    func insertEditorMedia(projectID: UUID, assetID: UUID, atIndex: Int, duration: Double?) async throws -> RecordingProject {
        try await applyVideoEdit(projectID: projectID, operation: .insertMedia(assetID: assetID, atIndex: atIndex, duration: duration))
    }
}

extension AIAssistantTests {
    @MainActor
    static func mediaLibraryTools(root: URL) async throws {
        let source = makeProject(sourceVideoPath: "/original-demo.mov", duration: 6)
        let box = ProjectBox(source)
        let app = FakeApp(box: box)
        app.projects = [source]
        app.openID = source.id
        var context = makeContext(root: root, box: box)
        context.app = app

        let emptyGlobal = try await ListGlobalMediaAssetsTool().run(arguments: [:], context: context, progress: { _ in })
        check(emptyGlobal.data?["count"]?.intValue == 0, "the global catalog is independent of the open project")

        let empty = try await ListMediaAssetsTool().run(arguments: [:], context: context, progress: { _ in })
        check(empty.data?["count"]?.intValue == 0, "a project starts with an empty editor media library")

        let image = root.appendingPathComponent("b-roll.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)
        let globalImported = try await ImportGlobalMediaAssetTool().run(arguments: ["path": image.path], context: context, progress: { _ in })
        guard let globalID = globalImported.data?["imported"]?[0]?["id"]?.stringValue else {
            fatalError("FAIL: global import returns a stable asset ID")
        }
        check(box.project?.mediaAssets == nil && app.globalMedia.count == 1,
              "global import does not edit an open project")
        let sharedList = try await ListGlobalMediaAssetsTool().run(arguments: [:], context: context, progress: { _ in })
        check(sharedList.data?["assets"]?[0]?["id"]?.stringValue == globalID,
              "shared assets can be listed without choosing a project")
        let imported = try await ImportMediaAssetTool().run(arguments: ["path": image.path], context: context, progress: { _ in })
        guard let projectID = imported.data?["project_id"]?.stringValue,
              let assetID = imported.data?["imported"]?[0]?["id"]?.stringValue else {
            fatalError("FAIL: media import returned its working project and asset IDs")
        }
        check(projectID != source.id.uuidString && imported.data?["created_copy"]?.boolValue == true,
              "import creates an editable working copy and preserves the source")
        check(app.projects.first == source && app.imported == [image], "source project is unchanged and only one file was imported")

        let assets = try await ListMediaAssetsTool().run(arguments: ["project_id": projectID], context: context, progress: { _ in })
        check(assets.data?["count"]?.intValue == 1 && assets.data?["assets"]?[0]?["kind"]?.stringValue == "image",
              "the imported still is reusable in the editor media library")

        let inserted = try await InsertMediaAssetTool().run(arguments: [
            "project_id": projectID, "asset_id": assetID, "at_index": 1, "duration": 2.5,
        ], context: context, progress: { _ in })
        check(inserted.data?["clip_count"]?.intValue == 2
              && inserted.data?["clips"]?[1]?["media_asset_id"]?.stringValue == assetID
              && inserted.data?["clips"]?[1]?["duration"]?.doubleValue == 2.5,
              "insert_media_asset places the selected still at the requested index and duration")
        let undone = try await UndoClipEditTool().run(arguments: ["project_id": projectID], context: context, progress: { _ in })
        check(undone.data?["clip_count"]?.intValue == 1 && box.project?.mediaAssets?.count == 1,
              "undo removes the placement while the media stays in the reusable library")

        let priorImports = app.imported.count
        await expectThrows("unsupported media") {
            let text = root.appendingPathComponent("not-media.txt")
            try Data("hello".utf8).write(to: text)
            _ = try await ImportMediaAssetTool().run(arguments: ["project_id": projectID, "path": text.path], context: context, progress: { _ in })
        }
        check(app.imported.count == priorImports, "invalid input never writes the media library")

        let copied = try await AddGlobalMediaToProjectTool().run(arguments: [
            "project_id": projectID, "global_asset_id": globalID,
        ], context: context, progress: { _ in })
        check(copied.data?["project_id"]?.stringValue == projectID
              && copied.data?["imported"]?[0]?["id"]?.stringValue != globalID
              && app.globalMedia.count == 1,
              "an explicit shared-to-project action creates a separate project asset")

        let generated = root.appendingPathComponent("seedance-result.mp4")
        try Data([1, 2, 3]).write(to: generated)
        let clipsBeforeRegistration = try DemoVideoTimeline(project: box.project!).clips.count
        let projectMediaCount = box.project?.mediaAssets?.count
        let registration = await MediaLibraryToolSupport.registerGenerated(generated, context: context)
        check(registration.globalAsset != nil && app.globalMedia.count == 2
              && box.project?.mediaAssets?.count == projectMediaCount,
              "a completed Seedance file is registered globally without touching the open project")
        let clipsAfterRegistration = try DemoVideoTimeline(project: box.project!).clips.count
        check(clipsAfterRegistration == clipsBeforeRegistration,
              "registering AI media leaves the video track unchanged")
        app.openID = source.id
        let afterNavigation = await MediaLibraryToolSupport.registerGenerated(generated, context: context)
        check(afterNavigation.globalAsset != nil && app.globalMedia.count == 3,
              "generation registration remains available after switching projects")
    }
}
