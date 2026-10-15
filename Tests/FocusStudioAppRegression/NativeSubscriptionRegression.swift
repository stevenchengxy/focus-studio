import FocusStudioAutomation
import Foundation
import FocusStudioCore

enum NativeSubscriptionRegression {
    @MainActor
    static func run() async throws {
        try await offlineAccess()
        let reservation = ExportReservation(id: UUID().uuidString)
        // Accept the actual API response, including fields not needed here.
        let valid = try JSONSerialization.data(withJSONObject: [
            "exportId": reservation.id, "status": "committed", "mode": "trial", "expiresAt": 1_900_000_000
        ])
        try NativeSubscriptionClient.validateCommitReceipt(valid, reservation: reservation)

        let invalidReceipts: [Data] = [
            Data(), Data("<html>OK</html>".utf8), Data("{}".utf8),
            try JSONSerialization.data(withJSONObject: ["exportId": UUID().uuidString, "status": "committed"]),
            try JSONSerialization.data(withJSONObject: ["exportId": reservation.id, "status": "reserved"]),
            try JSONSerialization.data(withJSONObject: ["exportId": reservation.id, "status": "released"]),
            try JSONSerialization.data(withJSONObject: ["exportId": reservation.id, "status": "expired"]),
            try JSONSerialization.data(withJSONObject: ["exportId": reservation.id, "status": true]),
        ]
        for data in invalidReceipts {
            do {
                try NativeSubscriptionClient.validateCommitReceipt(data, reservation: reservation)
                preconditionFailure("An unconfirmed commit receipt must not authorize output publication")
            } catch let error as SubscriptionServiceError {
                precondition(error.code == "invalid_response")
                precondition(!error.commitOutcomeIsKnown,
                    "Invalid receipts must preserve the completed video and recovery journal, not release or discard them")
            }
        }
        print("NativeSubscriptionRegression: PASS (matching committed receipt; malformed, unrelated and uncommitted receipts remain recoverable)")
    }
    @MainActor
    private static func offlineAccess() async throws {
        precondition(!ProductAccessPolicy.requiresExportAccount && !ProductAccessPolicy.paymentsEnabled)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoExportNetwork.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = NativeSubscriptionClient(origin: URL(string: "https://offline.invalid")!, session: session)
        let key = UUID()
        let receipt = try await client.reserve(projectID: "offline-demo", idempotencyKey: key)
        precondition(receipt.id == key.uuidString)
        try await client.renew(receipt)
        try await client.commit(receipt)
        await client.release(receipt)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("free-export-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("staged.mp4")
        let destination = directory.appendingPathComponent("recovered.mp4")
        let bytes = Data("completed-render-fixture".utf8)
        try bytes.write(to: source)
        let record = try JSONDecoder().decode(ExportRecoveryRecord.self, from: JSONSerialization.data(withJSONObject: [
            "id": key.uuidString, "projectID": "legacy-demo", "temporaryPath": source.path,
            "destinationPath": destination.path, "createdAt": 0
        ]))
        let recovery = directory.appendingPathComponent("recovery")
        try ExportRecoveryStore.save(record, directory: recovery)
        try await ExportRecoveryStore.recover(record, authorizer: client, to: destination, directory: recovery)
        let recovered = try Data(contentsOf: destination)
        precondition(recovered == bytes)
        precondition(ExportRecoveryStore.records(directory: recovery).isEmpty)
        let model = StudioModel(store: ProjectStore(projectsDirectory: directory.appendingPathComponent("projects")))
        let context = model.makeToolContext(assetsDirectory: { directory }, language: { "en" })
        precondition(context.exportAuthorization == nil, "Manual and MCP exports must not create a remote authorization lease")
        print("NativeSubscriptionRegression: PASS (offline unsigned-in reserve/commit/recovery; default manual and MCP exports have no authorizer)")
    }
}

private final class NoExportNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { preconditionFailure("Free local exports must not make a network request") }
    override func stopLoading() {}
}
