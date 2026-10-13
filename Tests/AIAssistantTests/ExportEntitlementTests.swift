import FocusStudioCore
import Foundation

private enum EntitlementTestFailure: Error, ExportCommitFailure {
    case denied, render, commit
    var commitOutcomeIsKnown: Bool { true }
}
private actor TestExportAuthorizer: ExportAuthorizing {
    let deniesReservation: Bool
    let deniesCommit: Bool
    private(set) var reservations = 0
    private(set) var commits = 0
    private(set) var releases = 0
    init(deniesReservation: Bool = false, deniesCommit: Bool = false) {
        self.deniesReservation = deniesReservation; self.deniesCommit = deniesCommit
    }
    func reserve(projectID: String, idempotencyKey: UUID) async throws -> ExportReservation {
        reservations += 1
        if deniesReservation { throw EntitlementTestFailure.denied }
        return ExportReservation(id: idempotencyKey.uuidString)
    }
    func renew(_ reservation: ExportReservation) async throws { }
    func commit(_ reservation: ExportReservation) async throws {
        commits += 1
        if deniesCommit { throw EntitlementTestFailure.commit }
    }
    func release(_ reservation: ExportReservation) async { releases += 1 }
    func counts() -> [Int] { [reservations, commits, releases] }
}

private actor UncertainExportAuthorizer: ExportAuthorizing {
    private(set) var reservations = 0
    private(set) var commits = 0
    private(set) var releases = 0
    func reserve(projectID: String, idempotencyKey: UUID) async throws -> ExportReservation {
        reservations += 1; return ExportReservation(id: idempotencyKey.uuidString)
    }
    func renew(_ reservation: ExportReservation) async throws { }
    func commit(_ reservation: ExportReservation) async throws {
        commits += 1
        // The server committed, but its first response disappeared in transit.
        // Its idempotent retry confirms the same receipt.
        if commits == 1 { throw URLError(.networkConnectionLost) }
    }
    func release(_ reservation: ExportReservation) async { releases += 1 }
    func counts() -> [Int] { [reservations, commits, releases] }
}

extension AIAssistantTests {
    @MainActor static func exportEntitlements(root: URL) async throws {
        let denied = TestExportAuthorizer(deniesReservation: true)
        await expectThrows("quota denial stops before rendering") {
            _ = try await EntitledExport.run(authorizer: denied, projectID: "fixture") { _ -> Bool in
                check(false, "denied export must not begin rendering"); return false
            }
        }
        let deniedCounts = await denied.counts()
        check(deniedCounts == [1, 0, 0], "quota denial neither commits nor creates a release")

        for cancelled in [false, true] {
            let failed = TestExportAuthorizer()
            await expectThrows("failed/cancelled render releases its allowance") {
                _ = try await EntitledExport.run(authorizer: failed, projectID: "fixture") { _ -> Bool in
                    if cancelled { throw CancellationError() }
                    throw EntitlementTestFailure.render
                }
            }
            let counts = await failed.counts()
            check(counts == [1, 0, 1], "render failure or cancellation never consumes the free export")
        }

        let source = root.appendingPathComponent("entitlement-source.mp4")
        try await SolidClipWriter.write(to: source, width: 320, height: 180, duration: 0.5, color: (0.2, 0.4, 0.7), audio: false)
        let project = makeProject(sourceVideoPath: source.path, duration: 0.5)
        let box = ProjectBox(project)
        var context = makeContext(root: root, box: box)
        let destination = root.appendingPathComponent("entitled-export.mp4")
        let existing = Data("keep existing output on authorization failure".utf8)
        try existing.write(to: destination)
        let rejectedCommit = TestExportAuthorizer(deniesCommit: true)
        context.exportAuthorization = rejectedCommit
        await expectThrows("commit rejection never publishes a rendered MP4") {
            _ = try await ExportProjectTool().run(arguments: ["path": destination.path, "overwrite": true], context: context, progress: { _ in })
        }
        let afterRejection = try Data(contentsOf: destination)
        check(afterRejection == existing, "rejected authorization preserves an existing destination")
        let rejectedCounts = await rejectedCommit.counts()
        check(rejectedCounts == [1, 1, 1], "a complete render checks commit and releases a rejected lease")

        let success = TestExportAuthorizer()
        context.exportAuthorization = success
        _ = try await ExportProjectTool().run(arguments: ["path": destination.path, "overwrite": true], context: context, progress: { _ in })
        let successCounts = await success.counts()
        let afterSuccess = try Data(contentsOf: destination)
        check(successCounts == [1, 1, 0] && afterSuccess != existing,
              "successful tool export commits exactly once and publishes its MP4")

        let uncertain = UncertainExportAuthorizer()
        context.exportAuthorization = uncertain
        let uncertainDestination = root.appendingPathComponent("recover-without-new-quota.mp4")
        await expectThrows("lost commit response retains a recoverable complete render") {
            _ = try await ExportProjectTool().run(arguments: ["path": uncertainDestination.path], context: context, progress: { _ in })
        }
        let pending = ExportRecoveryStore.records().filter { $0.projectID == project.id.uuidString }
        check(pending.count == 1 && !FileManager.default.fileExists(atPath: uncertainDestination.path),
              "uncertain export journals its receipt and never publishes an unconfirmed file")
        let staged = URL(fileURLWithPath: pending[0].temporaryPath)
        check(FileManager.default.fileExists(atPath: staged.path), "renderer keeps the completed MP4 after an uncertain commit")
        let uncertainCounts = await uncertain.counts()
        check(uncertainCounts == [1, 1, 0], "uncertain commits are not released or charged through a second reservation")
        try await ExportRecoveryStore.recover(pending[0], authorizer: uncertain, to: uncertainDestination)
        let recoveredCounts = await uncertain.counts()
        check(recoveredCounts == [1, 2, 0] && FileManager.default.fileExists(atPath: uncertainDestination.path)
              && !FileManager.default.fileExists(atPath: staged.path),
              "recovery confirms the same receipt and publishes without reserving another free export")
        check(!ExportRecoveryStore.records().contains { $0.id == pending[0].id }, "successful recovery clears its durable journal")

        let assemblyDestination = root.appendingPathComponent("entitled-assembly.mp4")
        let assemblyGate = TestExportAuthorizer(deniesReservation: true)
        context.exportAuthorization = assemblyGate
        await expectThrows("assembly follows the same quota gate") {
            _ = try await AssembleVideoTool().run(arguments: ["clips": [source.path], "path": assemblyDestination.path], context: context, progress: { _ in })
        }
        check(!FileManager.default.fileExists(atPath: assemblyDestination.path), "assembly cannot bypass denied export allowance")
    }
}
