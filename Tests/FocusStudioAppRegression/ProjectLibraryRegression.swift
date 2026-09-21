import FocusStudioCore
import Foundation

/// All project assets and the recoverable fake Trash live in one newly-created
/// temporary directory. These tests never call the user's real Trash or store.
@MainActor
enum ProjectLibraryRegression {
    static func run() async throws {
        try selectionIsIndependentAndStable()
        try await renamePreservesProject()
        try await renamePreservesLegacyMetadataPaths()
        try await batchDeleteKeepsUnselectedProject()
        try await partialTrashFailureRemainsRecoverable()
        try await pendingSavesCannotResurrectDeletedProjects()
        try await managementOperationsAreSerialized()
        try await storeRejectsMissingAndRedirectedTargets()
        print("ProjectLibraryRegression: PASS (multi-selection/Shift range/pruning, rename/trim/Unicode/duplicate titles, persistence, 2-of-3 delete, partial recoverable Trash failure, pending-save and stale-binding protection, concurrent-operation guards, missing/symlink/ID validation)")
    }

    private static func renamePreservesLegacyMetadataPaths() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanup() }
        let nested = try await fixture.createProject(title: "Nested source")
        let mediaDirectory = fixture.directory(nested.id).appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let nestedSource = mediaDirectory.appendingPathComponent("raw.mp4")
        try FileManager.default.moveItem(at: fixture.asset(nested.id, "raw.mp4"), to: nestedSource)
        var nestedMetadata = try fixture.metadataObject(nested.id)
        nestedMetadata["sourceVideoPath"] = "media/raw.mp4"
        nestedMetadata["futureCompatibilityProbe"] = ["version": 3, "keep": true]
        try JSONSerialization.data(withJSONObject: nestedMetadata, options: [.sortedKeys])
            .write(to: fixture.asset(nested.id, "project.json"))
        await fixture.model.reloadProjects()
        try expect(await fixture.model.renameProject(id: nested.id, to: "Nested renamed"), "A legacy nested source should remain renameable")
        nestedMetadata["title"] = "Nested renamed"
        let renamedNestedMetadata = try fixture.metadataObject(nested.id)
        try expect(NSDictionary(dictionary: nestedMetadata).isEqual(to: renamedNestedMetadata), "Rename must preserve nested paths and unknown metadata fields verbatim")
        try expect(try await fixture.loaded(nested.id).sourceVideoPath == nestedSource.path, "Nested video must still resolve after rename")
        try expect(FileManager.default.fileExists(atPath: nestedSource.path), "Rename must not move a legacy nested video")

        let absolute = try await fixture.createProject(title: "External source")
        let externalSource = fixture.root.appendingPathComponent("external-source.mp4")
        let original = Data("External source fixture bytes".utf8)
        try original.write(to: externalSource)
        var absoluteMetadata = try fixture.metadataObject(absolute.id)
        absoluteMetadata["sourceVideoPath"] = externalSource.path
        try JSONSerialization.data(withJSONObject: absoluteMetadata, options: [.sortedKeys])
            .write(to: fixture.asset(absolute.id, "project.json"))
        await fixture.model.reloadProjects()
        try expect(await fixture.model.renameProject(id: absolute.id, to: "Absolute renamed"), "An absolute legacy source should remain renameable")
        absoluteMetadata["title"] = "Absolute renamed"
        try expect(NSDictionary(dictionary: absoluteMetadata).isEqual(to: try fixture.metadataObject(absolute.id)), "Rename must not convert an absolute legacy source path to a basename")
        try expect(try Data(contentsOf: externalSource) == original, "Rename must not alter an external media source")
    }

    private static func selectionIsIndependentAndStable() throws {
        let ids = (0..<4).map { _ in UUID() }
        var selection = ProjectLibrarySelection()
        try expect(!selection.isSelecting && selection.ids.isEmpty && selection.anchorID == nil, "Library must open without accidental selection")
        selection.toggle(UUID(), in: ids)
        try expect(!selection.isSelecting && selection.ids.isEmpty, "Unknown cards must not enter selection mode")
        selection.begin()
        try expect(selection.isSelecting && selection.ids.isEmpty, "Select should enter selection mode without selecting every project")
        selection.toggle(ids[0], in: ids)
        try expect(selection.ids == [ids[0]] && selection.anchorID == ids[0], "First click should select only its project and anchor the range")
        selection.toggle(ids[2], in: ids)
        try expect(selection.ids == [ids[0], ids[2]], "Multiple card clicks should accumulate independently")
        selection.toggle(ids[3], in: ids, extendingRange: true)
        try expect(selection.ids == [ids[0], ids[2], ids[3]], "Shift selection should use the latest non-range anchor")
        selection.toggle(ids[1], in: ids, extendingRange: true)
        try expect(selection.ids == Set(ids), "Reverse Shift range should add all cards between target and anchor")
        let snapshot = selection
        selection.toggle(UUID(), in: ids, extendingRange: true)
        try expect(selection == snapshot, "An unknown Shift target must not change selected IDs or anchor")
        selection.remove([ids[2]])
        try expect(selection.ids == [ids[0], ids[1], ids[3]] && selection.anchorID == nil, "Delete must prune successful IDs and clear a removed anchor")
        selection.retainExisting([ids[1], ids[3]])
        try expect(selection.ids == [ids[1], ids[3]], "Reload must prune recordings no longer present")
        selection.deselectAll()
        try expect(selection.isSelecting && selection.ids.isEmpty && selection.anchorID == nil, "Deselect all should stay in selection mode")
        selection.selectAll(ids)
        try expect(selection.ids == Set(ids) && selection.anchorID == ids[0], "Select all should include exactly the visible recordings")
        selection.toggle(ids[1], in: ids)
        try expect(!selection.ids.contains(ids[1]) && selection.ids.count == 3, "Selected cards should toggle off independently")
        selection.finish()
        try expect(!selection.isSelecting && selection.ids.isEmpty && selection.anchorID == nil, "Done should reset mode, selection, and range anchor")
    }

    private static func renamePreservesProject() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanup() }
        let first = try await fixture.createProject(title: "Original product demo")
        let second = try await fixture.createProject(title: "Another demo")
        await fixture.model.reloadProjects()
        let original = try await fixture.loaded(first.id)
        let originalMetadata = try fixture.metadata(first.id)
        let originalRaw = try Data(contentsOf: fixture.asset(first.id, "raw.mp4"))
        let originalMusic = try Data(contentsOf: fixture.asset(first.id, "music.wav"))
        let originalBackground = try Data(contentsOf: fixture.asset(first.id, "background.png"))

        for invalid in ["", "  \n\t  ", String(repeating: "x", count: 121)] {
            let accepted = await fixture.model.renameProject(id: first.id, to: invalid)
            try expect(!accepted, "Empty, whitespace-only, or overlong names must not be saved")
            try expect(!fixture.model.isManagingProjects, "Validation failure must release management state")
            try expect(try fixture.metadata(first.id) == originalMetadata, "Invalid rename must not write metadata")
        }

        let title = "产品演示 🎬 — Café"
        try expect(await fixture.model.renameProject(id: first.id, to: " \n\t\(title)  \n"), "Unicode rename should succeed")
        var expected = original
        expected.title = title
        let renamed = try await fixture.loaded(first.id)
        try expect(renamed == expected, "Rename must change only title, preserving IDs, zooms, events, settings, paths, and creation date")
        try expect(fixture.model.projects.first(where: { $0.id == first.id })?.title == title, "Library card title should update immediately")
        try expect(try Data(contentsOf: fixture.asset(first.id, "raw.mp4")) == originalRaw, "Rename must not alter media bytes")
        try expect(try Data(contentsOf: fixture.asset(first.id, "music.wav")) == originalMusic, "Rename must not alter music bytes")
        try expect(try Data(contentsOf: fixture.asset(first.id, "background.png")) == originalBackground, "Rename must not alter background bytes")
        let metadata = try fixture.metadataObject(first.id)
        try expect(metadata["sourceVideoPath"] as? String == "raw.mp4", "Rename must keep portable relative media paths")

        try expect(await fixture.model.renameProject(id: second.id, to: title), "Duplicate display titles must be allowed")
        await fixture.model.reloadProjects()
        try expect(fixture.model.projects.filter { $0.title == title }.count == 2, "Same-title recordings must remain separate projects")
        try expect(Set(fixture.model.projects.map(\.id)) == [first.id, second.id], "Rename must never merge or replace project UUIDs")
        try expect(await fixture.model.renameProject(id: first.id, to: "Final title"), "A second rename should succeed")
        try expect(try await fixture.loaded(first.id).title == "Final title", "The latest successful rename must persist")
        try expect(fixture.trash.attemptedIDs.isEmpty, "Renaming must never invoke Trash")
    }

    private static func batchDeleteKeepsUnselectedProject() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanup() }
        let projects = try await fixture.createThreeProjects()
        let untouchedMetadata = try fixture.metadata(projects[2].id)
        let untouchedRaw = try Data(contentsOf: fixture.asset(projects[2].id, "raw.mp4"))
        let externalSource = fixture.root.appendingPathComponent("original-import-outside-projects.mp4")
        let externalBytes = Data("original import must never be trashed".utf8)
        try externalBytes.write(to: externalSource)
        // A caller's source path must not broaden the UUID-scoped delete target.
        if let index = fixture.model.projects.firstIndex(where: { $0.id == projects[0].id }) {
            fixture.model.projects[index].sourceVideoPath = externalSource.path
        }

        let selection: Set<UUID> = [projects[0].id, projects[1].id]
        let deleted = await fixture.model.deleteProjects(ids: selection)
        try expect(deleted == selection, "Batch delete should report exactly the two selected successful UUIDs")
        try expect(Set(fixture.model.projects.map(\.id)) == [projects[2].id], "The third unselected card must remain")
        try expect(Set(fixture.trash.attemptedIDs) == selection, "Only selected project directories may reach Trash")
        for project in projects.prefix(2) {
            try expect(!FileManager.default.fileExists(atPath: fixture.directory(project.id).path), "Trashed project must leave the library directory")
            try expect(FileManager.default.fileExists(atPath: fixture.trashedDirectory(project.id).appendingPathComponent("raw.mp4").path), "Deleted project media must remain recoverable in fake Trash")
        }
        try expect(try fixture.metadata(projects[2].id) == untouchedMetadata, "Unselected metadata must be byte-identical")
        try expect(try Data(contentsOf: fixture.asset(projects[2].id, "raw.mp4")) == untouchedRaw, "Unselected media must be untouched")
        try expect(try Data(contentsOf: externalSource) == externalBytes, "Deleting a project must never delete the original external import")
        await fixture.model.reloadProjects()
        try expect(Set(fixture.model.projects.map(\.id)) == [projects[2].id], "Successful batch deletion must survive reload")
        try expect(await fixture.model.deleteProjects(ids: []).isEmpty, "Empty selections are a no-op")
        try expect(!fixture.model.isManagingProjects, "Completed batch delete must release management state")
    }

    private static func partialTrashFailureRemainsRecoverable() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanup() }
        let projects = try await fixture.createThreeProjects()
        let blocked = projects[1]
        fixture.trash.failures = [blocked.id]
        let preservedMetadata = try fixture.metadata(blocked.id)
        let preservedRaw = try Data(contentsOf: fixture.asset(blocked.id, "raw.mp4"))

        let deleted = await fixture.model.deleteProjects(ids: [projects[0].id, blocked.id])
        try expect(deleted == [projects[0].id], "A partial failure must return only the successfully trashed UUID")
        try expect(Set(fixture.model.projects.map(\.id)) == [blocked.id, projects[2].id], "Failed and unselected cards must remain visible")
        try expect(fixture.model.isShowingError && !fixture.model.errorMessage.isEmpty, "Trash failures must be reported, not silently presented as success")
        try expect(!fixture.model.isManagingProjects, "Partial failure must release the management guard")
        try expect(try fixture.metadata(blocked.id) == preservedMetadata, "A failed Trash operation must preserve original metadata")
        try expect(try Data(contentsOf: fixture.asset(blocked.id, "raw.mp4")) == preservedRaw, "No permanent-delete fallback is allowed after Trash failure")
        try expect(!FileManager.default.fileExists(atPath: fixture.trashedDirectory(blocked.id).path), "Failed item must not appear in Trash")
        try expect(FileManager.default.fileExists(atPath: fixture.trashedDirectory(projects[0].id).appendingPathComponent("project.json").path), "Successful item must be recoverable despite another failure")

        fixture.trash.failures = []
        try expect(await fixture.model.deleteProjects(ids: [blocked.id]) == [blocked.id], "A failed item should be retryable")
        try expect(Set(fixture.model.projects.map(\.id)) == [projects[2].id], "Retry should not affect the untouched card")
    }

    private static func pendingSavesCannotResurrectDeletedProjects() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanup() }
        let project = try await fixture.createProject(title: "Pending autosave")
        await fixture.model.reloadProjects()
        fixture.model.open(project)
        let staleBinding = fixture.model.editorBinding(for: project)
        for index in 0..<30 {
            var edit = staleBinding.wrappedValue
            edit.title = "Pending edit \(index)"
            edit.settings.padding = Double(30 + index)
            staleBinding.wrappedValue = edit
        }
        fixture.model.closeEditor()
        let successful = await fixture.model.deleteProjects(ids: [project.id])
        try expect(successful == [project.id], "Delete must flush queued editor saves and then trash the project")
        var lateEdit = project
        lateEdit.title = "Must not reappear"
        staleBinding.wrappedValue = lateEdit
        await fixture.model.flushProjectEdits()
        await fixture.model.reloadProjects()
        try expect(fixture.model.projects.isEmpty && fixture.model.activeProject == nil, "Late editor binding writes must not resurrect a deleted project")
        try expect(!FileManager.default.fileExists(atPath: fixture.directory(project.id).path), "Pending save tasks must not recreate a trashed UUID directory")
        let recovered = try fixture.decodeMetadata(at: fixture.trashedDirectory(project.id).appendingPathComponent("project.json"))
        try expect(recovered.title == "Pending edit 29" && recovered.settings.padding == 59, "Recoverable Trash must include the latest completed edits")
    }

    private static func managementOperationsAreSerialized() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanup() }
        let projects = try await fixture.createThreeProjects()
        let gate = fixture.trash.blockNextOperation()
        defer { gate.release() }
        let deleting = Task { await fixture.model.deleteProjects(ids: [projects[0].id]) }
        try await waitUntil("Trash operation did not reach the test gate") { gate.hasEntered }
        try expect(fixture.model.isManagingProjects, "Delete must hold a guard across awaited store work")
        try expect(!((await fixture.model.renameProject(id: projects[1].id, to: "Rejected concurrent rename"))), "Rename must not race an in-flight deletion")
        try expect(await fixture.model.deleteProjects(ids: [projects[2].id]).isEmpty, "A second delete must not race the first")
        try expect(fixture.model.projects.first(where: { $0.id == projects[1].id })?.title == projects[1].title, "Rejected concurrent rename must not optimistically mutate a card")
        fixture.model.open(projects[1])
        try expect(fixture.model.destination == .library && fixture.model.activeProject == nil, "Opening an editor during management must not introduce late autosaves")
        gate.release()
        try expect(await deleting.value == [projects[0].id], "First deletion should complete when the gate releases")
        try expect(!fixture.model.isManagingProjects, "Guard must release after completion")

        // Occupy only the store actor, then start rename. Its awaited read/save
        // must hold the model guard just like deletion did above.
        let renameGate = fixture.trash.blockNextOperation()
        defer { renameGate.release() }
        let storeBlocker = Task { try await fixture.store.deleteProject(id: projects[2].id) }
        try await waitUntil("Store blocker did not reach the test gate") { renameGate.hasEntered }
        let renaming = Task { await fixture.model.renameProject(id: projects[1].id, to: "Serialized final title") }
        try await waitUntil("Rename did not hold the management guard") { fixture.model.isManagingProjects }
        try expect(await fixture.model.deleteProjects(ids: [projects[1].id]).isEmpty, "Delete must not race an in-flight rename")
        try expect(!((await fixture.model.renameProject(id: projects[1].id, to: "Rejected second rename"))), "Two concurrent renames must not reorder title saves")
        renameGate.release()
        try await storeBlocker.value
        try expect(await renaming.value, "First rename should finish after pending store work")
        try expect(!fixture.model.isManagingProjects, "Rename must release guard")
        try expect(try await fixture.loaded(projects[1].id).title == "Serialized final title", "Rejected concurrent rename must not overwrite the successful one")
    }

    private static func storeRejectsMissingAndRedirectedTargets() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanup() }
        let missing = UUID()
        var missingDeleteRejected = false
        do { try await fixture.store.deleteProject(id: missing) } catch { missingDeleteRejected = true }
        try expect(missingDeleteRejected, "Deleting a missing UUID must report projectNotFound, not create a directory")
        var missingRenameRejected = false
        do { _ = try await fixture.store.renameProject(id: missing, to: "Missing") } catch { missingRenameRejected = true }
        try expect(missingRenameRejected && !FileManager.default.fileExists(atPath: fixture.directory(missing).path), "Missing rename must not create an empty project")
        try expect(fixture.trash.attemptedIDs.isEmpty, "Missing project operations must not reach Trash")

        let ordinary = try await fixture.createProject(title: "Non-trailing-slash root")
        let nonTrailingRoot = URL(fileURLWithPath: fixture.projectsDirectory.path, isDirectory: false)
        let alternateTrash = fixture.trash
        let alternateStore = ProjectStore(projectsDirectory: nonTrailingRoot, trashOperation: { try alternateTrash.moveToTrash($0) })
        let ordinaryRename = try await alternateStore.renameProject(id: ordinary.id, to: "Validated ordinary root")
        try expect(ordinaryRename.title == "Validated ordinary root", "An ordinary file URL without a trailing slash must not be mistaken for an unsafe root")

        let redirected = UUID()
        let outside = fixture.root.appendingPathComponent("outside-target", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep.txt")
        try Data("private external target".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: fixture.directory(redirected), withDestinationURL: outside)
        var rejectedRedirect = false
        do { try await fixture.store.deleteProject(id: redirected) } catch { rejectedRedirect = true }
        try expect(rejectedRedirect && FileManager.default.fileExists(atPath: sentinel.path), "Symlinked UUID directories must never trash external targets")
        try expect(fixture.trash.attemptedIDs.isEmpty, "Symlinked paths must be rejected before invoking the trash adapter")

        let mismatch = try await fixture.createProject(title: "Mismatched metadata")
        var metadata = try fixture.metadataObject(mismatch.id)
        metadata["id"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: fixture.asset(mismatch.id, "project.json"))
        var rejectedMismatch = false
        do { try await fixture.store.deleteProject(id: mismatch.id) } catch { rejectedMismatch = true }
        try expect(rejectedMismatch && FileManager.default.fileExists(atPath: fixture.directory(mismatch.id).path), "Metadata-ID mismatch must not delete an unrelated project")
        try expect(fixture.trash.attemptedIDs.isEmpty, "Invalid project identity must not reach Trash")
    }

    private static func waitUntil(_ message: String, predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() {
            if ContinuousClock.now >= deadline { throw LibraryRegressionFailure(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw LibraryRegressionFailure(message) }
    }
}

private struct LibraryRegressionFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
private final class LibraryFixture {
    let root: URL
    let projectsDirectory: URL
    let trashDirectory: URL
    let trash: FakeProjectTrash
    let store: ProjectStore
    let model: StudioModel

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FocusStudio-Library-Test-\(UUID().uuidString)", isDirectory: true)
        projectsDirectory = root.appendingPathComponent("Projects", isDirectory: true)
        trashDirectory = root.appendingPathComponent("RecoverableTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let adapter = FakeProjectTrash(projectsDirectory: projectsDirectory, trashDirectory: trashDirectory)
        trash = adapter
        store = ProjectStore(projectsDirectory: projectsDirectory, trashOperation: { try adapter.moveToTrash($0) })
        model = StudioModel(store: store, interactionTrackingAccess: { true }, inputMonitoringAccess: { true })
    }

    func createProject(title: String) async throws -> RecordingProject {
        var project = RecordingProject(
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            sourceVideoPath: "raw.mp4",
            duration: 12,
            sourceWidth: 1280,
            sourceHeight: 720,
            cursorSamples: [CursorSample(time: 1, x: 0.4, y: 0.6, cursorKind: .iBeam)],
            clickEvents: [ClickEvent(time: 1, x: 0.4, y: 0.6, button: .left)],
            typingActivity: [TypingActivity(time: 1.2, x: 0.4, y: 0.6)],
            zoomSegments: [ZoomSegment(start: 0.7, end: 4.2, targetX: 0.4, targetY: 0.6, scale: 1.8, kind: .manual)]
        )
        let directory = try await store.projectDirectory(for: project.id)
        for filename in ["raw.mp4", "music.wav", "background.png"] {
            try Data("Isolated metadata fixture \(project.id) \(filename)".utf8)
                .write(to: directory.appendingPathComponent(filename))
        }
        project.sourceVideoPath = directory.appendingPathComponent("raw.mp4").path
        project.settings.productDemoAudio = ProductDemoAudioSettings(backgroundMusicPath: directory.appendingPathComponent("music.wav").path)
        project.settings.backgroundImagePath = directory.appendingPathComponent("background.png").path
        project.settings.backgroundBlur = 18
        try await store.save(project)
        return project
    }

    func createThreeProjects() async throws -> [RecordingProject] {
        var projects: [RecordingProject] = []
        for index in 1...3 { projects.append(try await createProject(title: "Demo \(index)")) }
        await model.reloadProjects()
        return projects
    }

    func loaded(_ id: UUID) async throws -> RecordingProject {
        guard let project = try await store.loadProjects().first(where: { $0.id == id }) else {
            throw LibraryRegressionFailure("Expected persisted project \(id)")
        }
        return project
    }

    func directory(_ id: UUID) -> URL { projectsDirectory.appendingPathComponent(id.uuidString, isDirectory: true) }
    func trashedDirectory(_ id: UUID) -> URL { trashDirectory.appendingPathComponent(id.uuidString, isDirectory: true) }
    func asset(_ id: UUID, _ filename: String) -> URL { directory(id).appendingPathComponent(filename) }
    func metadata(_ id: UUID) throws -> Data { try Data(contentsOf: asset(id, "project.json")) }
    func metadataObject(_ id: UUID) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: metadata(id)) as? [String: Any] else {
            throw LibraryRegressionFailure("Invalid fixture JSON")
        }
        return object
    }
    func decodeMetadata(at url: URL) throws -> RecordingProject {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingProject.self, from: Data(contentsOf: url))
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class FakeProjectTrash: @unchecked Sendable {
    private let lock = NSLock()
    private let projectsDirectory: URL
    private let trashDirectory: URL
    private var failedIDs: Set<UUID> = []
    private var attempted: [UUID] = []
    private var nextGate: TrashOperationGate?

    init(projectsDirectory: URL, trashDirectory: URL) {
        self.projectsDirectory = projectsDirectory
        self.trashDirectory = trashDirectory
    }

    var failures: Set<UUID> {
        get { lock.withLock { failedIDs } }
        set { lock.withLock { failedIDs = newValue } }
    }
    var attemptedIDs: [UUID] { lock.withLock { attempted } }
    func blockNextOperation() -> TrashOperationGate {
        let gate = TrashOperationGate()
        lock.withLock { nextGate = gate }
        return gate
    }

    func moveToTrash(_ source: URL) throws {
        guard source.deletingLastPathComponent().standardizedFileURL == projectsDirectory.standardizedFileURL,
              let id = UUID(uuidString: source.lastPathComponent) else {
            throw LibraryRegressionFailure("Unsafe fake Trash target outside isolated UUID directory: \(source)")
        }
        let (fails, gate) = lock.withLock { () -> (Bool, TrashOperationGate?) in
            attempted.append(id)
            let gate = nextGate
            nextGate = nil
            return (failedIDs.contains(id), gate)
        }
        if let gate { try gate.enterAndWait() }
        if fails { throw LibraryRegressionFailure("Injected recoverable Trash failure for \(id)") }
        try FileManager.default.moveItem(at: source, to: trashDirectory.appendingPathComponent(id.uuidString, isDirectory: true))
    }
}

private final class TrashOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var released = false
    var hasEntered: Bool { lock.withLock { entered } }

    func enterAndWait() throws {
        lock.withLock { entered = true }
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw LibraryRegressionFailure("Timed out waiting for isolated Trash test gate")
        }
    }

    func release() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !released else { return false }
            released = true
            return true
        }
        if shouldSignal { semaphore.signal() }
    }
}
