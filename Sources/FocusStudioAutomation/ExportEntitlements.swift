import FocusStudioCore
import Foundation

/// Product access is temporarily free. This never changes third-party AI billing
/// or the separate approval required by paid generation tools.
public enum ProductAccessPolicy {
    public static let requiresExportAccount = false
    public static let paymentsEnabled = false
}

public struct ExportReservation: Sendable, Equatable {
    public let id: String
    public init(id: String) { self.id = id }
}

public protocol ExportAuthorizing: Sendable {
    func reserve(projectID: String, idempotencyKey: UUID) async throws -> ExportReservation
    func renew(_ reservation: ExportReservation) async throws
    func commit(_ reservation: ExportReservation) async throws
    func release(_ reservation: ExportReservation) async
}

/// Only a definite server rejection permits deleting an already rendered file.
/// Connection loss and 5xx replies can hide a successful idempotent commit.
public protocol ExportCommitFailure: Error { var commitOutcomeIsKnown: Bool { get } }

public struct ExportRecoveryRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let projectID: String
    public let temporaryPath: String
    public let destinationPath: String
    public let createdAt: Date
}

public struct ExportRecoveryRequired: LocalizedError, PreservesCompletedExport, Sendable {
    public let exportID: String
    public var errorDescription: String? {
        L10n.tr("Your rendered video is safe. Open Settings → Account → Recover export to finish without using another export.")
    }
}

/// Durable before the server commit, so a crash or lost response cannot consume
/// the free allowance and erase the only completed MP4. Contains no auth token.
public enum ExportRecoveryStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusStudio/ExportRecovery", isDirectory: true)
    }
    private static func url(for record: ExportRecoveryRecord, directory: URL) -> URL {
        directory.appendingPathComponent(record.id).appendingPathExtension("json")
    }
    public static func save(_ record: ExportRecoveryRecord, directory: URL = directory) throws {
        guard UUID(uuidString: record.id) != nil else { throw AIToolError.failed("Invalid export reservation ID.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let path = url(for: record, directory: directory)
        try JSONEncoder().encode(record).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    public static func records(directory: URL = directory) -> [ExportRecoveryRecord] {
        let paths = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return paths.filter { $0.pathExtension == "json" }.compactMap { path in
            guard let data = try? Data(contentsOf: path), data.count < 65_536,
                  let record = try? JSONDecoder().decode(ExportRecoveryRecord.self, from: data),
                  UUID(uuidString: record.id) != nil else { return nil }
            return record
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public static func remove(_ record: ExportRecoveryRecord, directory: URL = directory) {
        try? FileManager.default.removeItem(at: url(for: record, directory: directory))
    }
    public static func recover(_ record: ExportRecoveryRecord, authorizer: any ExportAuthorizing,
                               to destination: URL, directory: URL = directory) async throws {
        let staged = URL(fileURLWithPath: record.temporaryPath)
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw AIToolError.failed(L10n.tr("The saved export file is missing. Your source recording has not changed."))
        }
        guard destination.pathExtension.lowercased() == "mp4" else { throw AIToolError.invalidArgument("Choose an MP4 destination.") }
        try await Task.detached { try await authorizer.commit(ExportReservation(id: record.id)) }.value
        if staged.standardizedFileURL != destination.standardizedFileURL {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        }
        remove(record, directory: directory)
    }
}

private actor ExportLeaseState {
    var record: ExportRecoveryRecord?
    var needsRecovery = false
    func stage(_ value: ExportRecoveryRecord) { record = value }
    func retain() { needsRecovery = true }
    func snapshot() -> (ExportRecoveryRecord?, Bool) { (record, needsRecovery) }
}

public enum EntitledExport {
    public static func run<T: Sendable>(
        authorizer: (any ExportAuthorizing)?, projectID: String, outputURL: URL? = nil,
        recoveryDirectory: URL = ExportRecoveryStore.directory,
        renewalNanoseconds: UInt64 = 300_000_000_000,
        render: (@escaping @Sendable (URL) async throws -> Void) async throws -> T
    ) async throws -> T {
        guard let authorizer else { return try await render({ _ in }) }
        try Task.checkCancellation()
        let reservation = try await authorizer.reserve(projectID: projectID, idempotencyKey: UUID())
        let state = ExportLeaseState()
        let renewal = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: renewalNanoseconds) }
                catch { return }
                // The authoritative commit validates the lease. A temporary
                // network outage during renewal must not discard good footage.
                try? await authorizer.renew(reservation)
            }
        }
        defer { renewal.cancel() }
        do {
            let result = try await render { staged in
                try Task.checkCancellation()
                let record = ExportRecoveryRecord(id: reservation.id, projectID: projectID,
                    temporaryPath: staged.path, destinationPath: (outputURL ?? staged).path, createdAt: Date())
                try ExportRecoveryStore.save(record, directory: recoveryDirectory)
                await state.stage(record)
                do {
                    // Complete the same commit even if cancellation arrives
                    // now; the rendered output already exists and is durable.
                    try await Task.detached { try await authorizer.commit(reservation) }.value
                    await state.retain() // retain on any subsequent file-publication failure
                } catch {
                    if (error as? any ExportCommitFailure)?.commitOutcomeIsKnown == true {
                        ExportRecoveryStore.remove(record, directory: recoveryDirectory)
                        throw error
                    }
                    await state.retain()
                    throw ExportRecoveryRequired(exportID: reservation.id)
                }
            }
            if let record = await state.snapshot().0 { ExportRecoveryStore.remove(record, directory: recoveryDirectory) }
            return result
        } catch {
            let (record, needsRecovery) = await state.snapshot()
            if !needsRecovery {
                if let record { ExportRecoveryStore.remove(record, directory: recoveryDirectory) }
                await Task.detached { await authorizer.release(reservation) }.value
            }
            throw error
        }
    }
}
