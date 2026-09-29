@preconcurrency import AVFoundation
import CoreGraphics
import CryptoKit
import FocusStudioCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum GlobalMediaLibraryRegression {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusStudio-SharedMedia-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        let inspector = ProjectStore(projectsDirectory: projects)
        let shared = root.appendingPathComponent("MediaLibrary", isDirectory: true)
        let catalog = GlobalMediaLibraryStore(directory: shared, inspector: inspector)
        let image = root.appendingPathComponent("source.png")
        try makeImage(image)
        let movie = root.appendingPathComponent("source.mp4")
        _ = try await StillImageVideoBuilder.build(from: image, to: movie,
            duration: 1.5, renderSize: CGSize(width: 64, height: 64))
        let original = try await inspector.createProject(from: movie, title: "Original", cursorSamples: [], clickEvents: [])
        let raw = URL(fileURLWithPath: original.sourceVideoPath)
        let before = SHA256.hash(data: try Data(contentsOf: raw))
        let invalid = root.appendingPathComponent("bad.mp4")
        try Data("not video".utf8).write(to: invalid)
        var rejected = false
        do { _ = try await catalog.importFiles([image, invalid]) }
        catch { rejected = true }
        let afterRejected = try await catalog.assets()
        precondition(rejected && afterRejected.isEmpty,
                     "A bad batch does not publish any shared item")

        let added = try await catalog.importFiles([image, movie])
        precondition(added.count == 2 && added.map(\.kind) == [.image, .video],
                     "Valid image and movie are cataloged together")
        precondition(added.allSatisfy { $0.filePath.hasPrefix(shared.path + "/files/")
            && FileManager.default.fileExists(atPath: $0.filePath) },
            "Shared catalog owns copies independent of import sources")
        let index = try Data(contentsOf: shared.appendingPathComponent("index.json"))
        let persisted = try JSONDecoder().decode([DemoMediaAsset].self, from: index)
        precondition(persisted.allSatisfy { $0.filePath.hasPrefix("files/") },
                     "Shared catalog stores portable relative paths")
        try FileManager.default.removeItem(at: image)
        try FileManager.default.removeItem(at: movie)
        let reopened = GlobalMediaLibraryStore(directory: shared, inspector: inspector)
        let restored = try await reopened.assets()
        precondition(restored.map(\.id) == added.map(\.id)
            && restored.allSatisfy { FileManager.default.fileExists(atPath: $0.filePath) },
            "Shared items survive relaunch after original input files disappear")

        let model = StudioModel(store: inspector)
        await model.reloadProjects()
        await model.reloadGlobalMediaAssets()
        precondition(model.globalMediaAssets.count == 2 && model.projects.count == 1
            && model.projects[0].mediaAssets == nil,
            "Shared items never silently migrate into existing projects")
        let working = try await model.importGlobalMediaToProject(assetIDs: [added[0].id], projectID: original.id)
        guard let privateAsset = working.mediaAssets?.first else {
            preconditionFailure("Shared item must appear in working project")
        }
        precondition(working.id != original.id && privateAsset.id != added[0].id
            && privateAsset.filePath.hasPrefix(projects.appendingPathComponent(working.id.uuidString).path + "/media/")
            && privateAsset.filePath != added[0].filePath,
            "Explicit project import branches the original and owns a distinct media copy")
        try FileManager.default.removeItem(atPath: added[0].filePath)
        let after = SHA256.hash(data: try Data(contentsOf: raw))
        precondition(FileManager.default.fileExists(atPath: privateAsset.filePath)
            && after == before,
            "Project media and original recording survive removal from the shared catalog")
        let projectReloaded = try await inspector.loadProjects().first(where: { $0.id == working.id })
        precondition(projectReloaded?.mediaAssets?.first?.filePath == privateAsset.filePath,
                     "A working project reloads its private media without the shared copy")

        // The home screen shows eight cards by default. A new AI/manual item
        // must be visible immediately even once the shared catalog grows.
        var newestID = added[1].id
        for _ in 0..<7 {
            let newItems = try await model.importGlobalMedia(from: [URL(fileURLWithPath: added[1].filePath)])
            newestID = newItems[0].id
        }
        let featured = GlobalMediaLibrarySection.visibleAssets(model.globalMediaAssets, showAll: false)
        let expanded = GlobalMediaLibrarySection.visibleAssets(model.globalMediaAssets, showAll: true)
        precondition(model.globalMediaAssets.count == 9 && featured.count == 8
            && featured.first?.id == newestID && !featured.contains(where: { $0.id == added[0].id })
            && expanded.count == 9 && expanded.first?.id == newestID,
            "Home media cards show newest additions first, including the ninth item")
        print("GlobalMediaLibraryRegression: PASS (atomic import, durable shared copies, explicit project copy, source isolation, newest home cards visible)")
    }

    private static func makeImage(_ url: URL) throws {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "GlobalMediaLibraryRegression", code: 1)
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "GlobalMediaLibraryRegression", code: 2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "GlobalMediaLibraryRegression", code: 3)
        }
    }
}
