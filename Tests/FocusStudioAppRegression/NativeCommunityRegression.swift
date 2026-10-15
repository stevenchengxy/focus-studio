import Foundation

/// Compatibility checks; protocol and transport checks are in the other suite.
/// Both suites use memory vaults and never open the real Keychain.
enum NativeCommunityRegression {
    private static let origin = URL(string: "https://community-migration.invalid")!
    private static let now = Date(timeIntervalSince1970: 1_900_000_000)
    private static let tokenA = "fs_" + String(repeating: "a", count: 64)
    private static let tokenB = "fs_" + String(repeating: "b", count: 64)

    static func run() async throws {
        try await installedGatePrecedesCredentialsAndNetwork()
        try await migrateLegacyWithoutActivation()
        try await preserveLegacyOnFailure()
        try await rejectedLegacyIsCleared()
        try await existingRecordWins()
        try await interruptedMigrationAndConditionalCleanup()
        try await cancelledMigrationCannotWriteBack()
        try await disconnectPreventsLegacyResurrection()
        try await localCleanupFailureRemainsRetryable()
        try await failedInitialMutationDoesNotPoisonReload()
        precondition(CommunityLegacyKeychainVault.service == CommunityKeychainVault.service)
        precondition(CommunityLegacyKeychainVault.account == "community-device-token")
        precondition(CommunityLegacyKeychainVault.account != CommunityKeychainVault.account)
        print("NativeCommunityRegression: PASS (installation gate; validated legacy migration without activation; write-before-delete; offline/503/invalid-response/write-failure retention; 401/403 scope cleanup; existing-record priority; interrupted migration; conditional deletion; cancellation; no legacy resurrection after disconnect)")
    }

    private static func installedGatePrecedesCredentialsAndNetwork() async throws {
        for operation in ["restore", "start", "poll", "confirm"] {
            let fixture = MigrationFixture(legacy: tokenA)
            let client = makeClient(fixture, installed: false)
            try await rejects("installation_required") {
                switch operation {
                case "restore": _ = try await client.restore()
                case "start": _ = try await client.startPairing()
                case "poll": _ = try await client.pollPairing(pairing())
                default: _ = try await client.confirmClient()
                }
            }
            let events = await fixture.audit.events()
            precondition(events.isEmpty, "Installation must be checked before credentials or requests")
        }
        // A fixture origin must never discover the production legacy Keychain.
        let fixture = MigrationFixture()
        let client = NativeCommunityConnectionClient(origin: origin, transport: fixture.transport,
            vault: fixture.current, isInstalledClient: { true }, now: { now })
        let snapshot = try await client.restore()
        precondition(snapshot == .disconnected)
        let requests = await fixture.transport.requests()
        precondition(requests.isEmpty)

        // Local cleanup remains available outside the installed app.
        let cleanup = MigrationFixture(current: savedToken(tokenA), legacy: tokenA)
        try await makeClient(cleanup, installed: false).cancelPairing()
        let current = await cleanup.current.value()
        let legacy = await cleanup.legacy.value()
        precondition(current == nil && legacy == nil)
    }

    private static func migrateLegacyWithoutActivation() async throws {
        for confirmed in [false, true] {
            let fixture = MigrationFixture(legacy: tokenA, replies: [.identity(token: tokenA, confirmed: confirmed)])
            let restored = try await makeClient(fixture).restore()
            precondition(restored.hasCredential && restored.identity?.id == "migration-owner-a")
            precondition(restored.clientConfirmed == confirmed && restored.pairing == nil)
            let legacy = await fixture.legacy.value()
            let stored = await fixture.current.value()
            precondition(legacy == nil)
            let record = try decode(stored)
            precondition(record["purpose"] as? String == "community" && record["origin"] as? String == origin.absoluteString)
            let token = record["token"] as! [String: Any]
            precondition(token["accessToken"] as? String == tokenA)
            let expiry = Date(timeIntervalSinceReferenceDate: token["expiresAt"] as! Double)
            precondition(expiry == now.addingTimeInterval(3600), "Migration must use server expiry")
            let events = await fixture.audit.events()
            precondition(events.firstIndex(of: "current.write")! < events.firstIndex(of: "legacy.delete")!,
                         "New JSON must be durable before deleting the raw token")
            let requests = await fixture.transport.requests()
            precondition(requests.map { $0.url!.path } == ["/api/device/community"],
                         "Migration must only inspect identity, never silently activate")
        }
    }

    private static func preserveLegacyOnFailure() async throws {
        var wrongPurpose = identityBody(); wrongPurpose["purpose"] = "account"
        var wrongIdentity = identityBody(); wrongIdentity["account"] = ["id": "", "email": "a@example.invalid"]
        var expired = identityBody(); expired["expiresAt"] = now.timeIntervalSince1970
        let failures: [MigrationReply] = [
            .init(error: .notConnectedToInternet),
            .init(status: 503, body: json(["error": ["code": "service_error"]])),
            .init(status: 403, body: json(["error": ["code": "origin_rejected"]])),
            .init(body: json(wrongPurpose)), .init(body: json(wrongIdentity)),
            .init(body: json(expired)), .init(body: Data("not JSON".utf8)),
        ]
        for failure in failures {
            let fixture = MigrationFixture(legacy: tokenA, replies: [failure])
            let client = makeClient(fixture)
            do { _ = try await client.restore(); preconditionFailure("An unverified migration must fail") }
            catch is URLError { }
            catch let error as CommunityConnectionError {
                precondition(["invalid_response", "service_unavailable"].contains(error.code))
            }
            let legacy = await fixture.legacy.value()
            let current = await fixture.current.value()
            let deletes = await fixture.legacy.deleteAttempts()
            precondition(legacy == tokenA && current == nil && deletes.isEmpty)
            await fixture.transport.append(.identity(token: tokenA))
            let retry = try await client.restore()
            precondition(retry.identity?.id == "migration-owner-a" && !retry.clientConfirmed)
        }
        let fixture = MigrationFixture(legacy: tokenA, replies: [.identity(token: tokenA)])
        await fixture.current.setWriteFailure(true)
        let client = makeClient(fixture)
        try await rejects("credential_storage") { _ = try await client.restore() }
        let legacy = await fixture.legacy.value()
        let current = await fixture.current.value()
        let deletes = await fixture.legacy.deleteAttempts()
        precondition(legacy == tokenA && current == nil && deletes.isEmpty, "Failed new-item writes must preserve legacy credentials")
        await fixture.current.setWriteFailure(false)
        await fixture.transport.append(.identity(token: tokenA))
        _ = try await client.restore()
        let migrated = await fixture.current.value()
        let cleaned = await fixture.legacy.value()
        precondition(migrated != nil && cleaned == nil)
    }

    private static func rejectedLegacyIsCleared() async throws {
        for (status, code) in [(401, "community_device_required"), (403, "community_device_required"), (403, "community_sign_in_required")] {
            let fixture = MigrationFixture(legacy: tokenA, replies: [.init(status: status, body: json(["error": ["code": code]]))])
            let client = makeClient(fixture)
            try await rejects("connection_expired") { _ = try await client.restore() }
            let current = await fixture.current.value()
            let legacy = await fixture.legacy.value()
            precondition(current == nil && legacy == nil)
            let restored = try await makeClient(fixture).restore()
            precondition(restored == .disconnected)
            let requests = await fixture.transport.requests()
            precondition(requests.count == 1)
        }
    }

    private static func existingRecordWins() async throws {
        let pending = MigrationFixture(current: savedPairing(), legacy: tokenA)
        let restored = try await makeClient(pending).restore()
        precondition(restored.pairing == pairing() && !restored.hasCredential)
        let pendingRequests = await pending.transport.requests()
        precondition(pendingRequests.isEmpty, "A saved grant must not be displaced by a legacy login")

        let existing = MigrationFixture(current: savedToken(tokenB), legacy: tokenA, replies: [.identity(token: tokenB, second: true)])
        let snapshot = try await makeClient(existing).restore()
        precondition(snapshot.identity?.id == "migration-owner-b")
        let old = await existing.legacy.value()
        let deletes = await existing.legacy.deleteAttempts()
        precondition(old == tokenA && !deletes.contains(tokenA), "Refreshing a new identity must not delete another legacy token")
        let requests = await existing.transport.requests()
        precondition(requests.count == 1 && requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(tokenB)")
    }

    private static func interruptedMigrationAndConditionalCleanup() async throws {
        let both = MigrationFixture(current: savedToken(tokenA), legacy: tokenA, replies: [.identity(token: tokenA)])
        _ = try await makeClient(both).restore()
        let old = await both.legacy.value()
        let stored = await both.current.value()
        precondition(old == nil && stored != nil, "A restart must finish matching legacy cleanup")

        // Model another process replacing the legacy item after it was read.
        let replaced = MigrationFixture(legacy: tokenA, replies: [.identity(token: tokenA)])
        await replaced.legacy.replaceAtNextDelete(with: tokenB)
        _ = try await makeClient(replaced).restore()
        let replacement = await replaced.legacy.value()
        let migrated = try decode(await replaced.current.value())["token"] as! [String: Any]
        precondition(replacement == tokenB && migrated["accessToken"] as? String == tokenA,
                     "Conditional deletion must preserve a replacement credential")

        let interrupted = MigrationFixture(legacy: tokenA, replies: [.identity(token: tokenA)])
        await interrupted.legacy.setDeleteFailure(true)
        do { _ = try await makeClient(interrupted).restore() }
        catch let error as CommunityConnectionError { precondition(error.code == "credential_storage") }
        let durable = await interrupted.current.value()
        let retryable = await interrupted.legacy.value()
        precondition(durable != nil && retryable == tokenA)
        await interrupted.legacy.setDeleteFailure(false)
        await interrupted.transport.append(.identity(token: tokenA))
        _ = try await makeClient(interrupted).restore()
        let cleaned = await interrupted.legacy.value()
        precondition(cleaned == nil)
    }

    private static func cancelledMigrationCannotWriteBack() async throws {
        for explicitCancel in [false, true] {
            let gate = MigrationGate()
            let fixture = MigrationFixture(legacy: tokenA, replies: [.identity(token: tokenA, gate: gate)])
            let client = makeClient(fixture)
            let restoring = Task { _ = try await client.restore() }
            try await waitUntil { await gate.isWaiting() }
            if explicitCancel { try await client.cancelPairing() }
            else { restoring.cancel() }
            await gate.open()
            do { try await restoring.value; preconditionFailure("A late response must not revive cancelled migration") }
            catch is CancellationError { }
            let current = await fixture.current.value()
            let legacy = await fixture.legacy.value()
            precondition(current == nil)
            precondition(legacy == (explicitCancel ? nil : tokenA),
                         "Only an explicit cancel/disconnect may remove an unverified legacy token")
            if explicitCancel {
                let restored = try await makeClient(fixture).restore()
                precondition(restored == .disconnected)
            }
        }
    }

    private static func disconnectPreventsLegacyResurrection() async throws {
        for legacyToken in [tokenA, tokenB] {
            let fixture = MigrationFixture(current: savedToken(tokenA), legacy: legacyToken,
                replies: [.init(endpoint: "revoke", body: json(["revoked": true]))])
            try await makeClient(fixture).disconnect()
            let current = await fixture.current.value()
            let legacy = await fixture.legacy.value()
            precondition(current == nil && legacy == nil)
            let restored = try await makeClient(fixture).restore()
            precondition(restored == .disconnected, "A restart must not resurrect the legacy account")
            let requests = await fixture.transport.requests()
            precondition(requests.map { $0.url!.path } == ["/api/device/revoke"], "Disconnect must not migrate or activate")
        }
    }

    private static func localCleanupFailureRemainsRetryable() async throws {
        let fixture = MigrationFixture(current: savedToken(tokenA), legacy: tokenA)
        await fixture.legacy.setDeleteFailure(true)
        let client = makeClient(fixture)
        try await rejects("credential_storage") { try await client.disconnect() }
        let old = await fixture.legacy.value()
        let current = await fixture.current.value()
        precondition(old == tokenA && current != nil, "Failure deleting legacy must retain the new item for retry")
        let noRequests = await fixture.transport.requests()
        precondition(noRequests.isEmpty)
        await fixture.legacy.setDeleteFailure(false)
        await fixture.transport.append(.init(endpoint: "revoke", body: json(["revoked": true])))
        try await client.disconnect()
        let legacy = await fixture.legacy.value()
        let cleaned = await fixture.current.value()
        precondition(legacy == nil && cleaned == nil)
    }

    private static func failedInitialMutationDoesNotPoisonReload() async throws {
        let fixture = MigrationFixture(current: Data("damaged JSON".utf8), legacy: tokenA)
        await fixture.current.setDeleteFailure(true)
        let client = makeClient(fixture)
        try await rejects("credential_storage") { _ = try await client.restore() }
        await fixture.current.setDeleteFailure(false)
        try await rejects("invalid_response") { _ = try await client.restore() }
        let current = await fixture.current.value()
        let legacy = await fixture.legacy.value()
        precondition(current == nil && legacy == tokenA, "Retry must clean the broken new record without deleting the valid legacy token")
        await fixture.transport.append(.identity(token: tokenA))
        let restored = try await client.restore()
        precondition(restored.identity?.id == "migration-owner-a" && !restored.clientConfirmed,
                     "A completed storage failure must not permanently poison later loads")
    }

    private static func makeClient(_ fixture: MigrationFixture, installed: Bool = true) -> NativeCommunityConnectionClient {
        NativeCommunityConnectionClient(origin: origin, transport: fixture.transport, vault: fixture.current,
            legacyVault: fixture.legacy, isInstalledClient: { installed }, now: { now })
    }
    private static func pairing() -> CommunityConnectionPairing {
        .init(deviceCode: String(repeating: "c", count: 64), userCode: "CCCCCC-CCCCCC",
              verificationURL: URL(string: "\(origin)/account?code=CCCCCC-CCCCCC&purpose=community")!,
              expiresAt: now.addingTimeInterval(600), interval: 5)
    }
    private static func savedPairing() -> Data {
        try! JSONEncoder().encode(MigrationSavedRecord(version: 1, origin: origin.absoluteString, purpose: "community", pairing: pairing()))
    }
    private static func savedToken(_ value: String) -> Data {
        let token = MigrationSavedRecord.Token(accessToken: value, expiresAt: now.addingTimeInterval(3600),
            identity: .init(id: value == tokenA ? "migration-owner-a" : "migration-owner-b",
                            email: value == tokenA ? "a@example.invalid" : "b@example.invalid", displayName: nil), clientConfirmed: false)
        return try! JSONEncoder().encode(MigrationSavedRecord(version: 1, origin: origin.absoluteString, purpose: "community", token: token))
    }
    private static func identityBody() -> [String: Any] {
        ["purpose": "community", "account": ["id": "migration-owner-a", "email": "a@example.invalid"],
         "clientConfirmed": false, "expiresAt": now.addingTimeInterval(3600).timeIntervalSince1970]
    }
    private static func decode(_ data: Data?) throws -> [String: Any] {
        guard let data else { preconditionFailure("Expected a durable community record") }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    private static func json(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private static func rejects(_ code: String, _ action: () async throws -> Void) async throws {
        do { try await action(); preconditionFailure("Expected community error \(code)") }
        catch let error as CommunityConnectionError { precondition(error.code == code, "Expected \(code), got \(error.code)") }
    }
    private static func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            precondition(Date() < deadline, "Migration fixture timed out")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private struct MigrationSavedRecord: Encodable {
    struct Token: Encodable {
        let accessToken: String
        let expiresAt: Date
        let identity: CommunityConnectionIdentity?
        let clientConfirmed: Bool
    }
    let version: Int
    let origin: String
    let purpose: String
    var pairing: CommunityConnectionPairing?
    var token: Token?
}
private struct MigrationFixture {
    let audit: MigrationAudit
    let current: MigrationCurrentVault
    let legacy: MigrationLegacyVault
    let transport: MigrationTransport
    init(current: Data? = nil, legacy: String? = nil, replies: [MigrationReply] = []) {
        let audit = MigrationAudit(); self.audit = audit
        self.current = MigrationCurrentVault(current, audit: audit)
        self.legacy = MigrationLegacyVault(legacy, audit: audit)
        transport = MigrationTransport(replies, audit: audit)
    }
}
private actor MigrationAudit {
    private var recorded: [String] = []
    func record(_ event: String) { recorded.append(event) }
    func events() -> [String] { recorded }
}
private actor MigrationCurrentVault: CommunityCredentialVault {
    private var data: Data?
    private var writeFails = false
    private var deleteFails = false
    private let audit: MigrationAudit
    init(_ data: Data?, audit: MigrationAudit) { self.data = data; self.audit = audit }
    func value() -> Data? { data }
    func setWriteFailure(_ fails: Bool) { writeFails = fails }
    func setDeleteFailure(_ fails: Bool) { deleteFails = fails }
    func read() async -> Data? { await audit.record("current.read"); return data }
    func write(_ value: Data) async throws {
        if writeFails { throw CommunityConnectionError(code: "credential_storage", message: "Fixture write failed") }
        data = value; await audit.record("current.write")
    }
    func delete() async throws {
        if deleteFails { throw CommunityConnectionError(code: "credential_storage", message: "Fixture delete failed") }
        data = nil; await audit.record("current.delete")
    }
}
private actor MigrationLegacyVault: CommunityLegacyCredentialVault {
    private var token: String?
    private var deletionTokens: [String] = []
    private var replacement: String?
    private var deleteFails = false
    private let audit: MigrationAudit
    init(_ token: String?, audit: MigrationAudit) { self.token = token; self.audit = audit }
    func value() -> String? { token }
    func deleteAttempts() -> [String] { deletionTokens }
    func replaceAtNextDelete(with value: String) { replacement = value }
    func setDeleteFailure(_ fails: Bool) { deleteFails = fails }
    func read() async -> String? { await audit.record("legacy.read"); return token }
    func delete(ifMatching value: String) async throws {
        deletionTokens.append(value)
        if deleteFails { throw CommunityConnectionError(code: "credential_storage", message: "Fixture delete failed") }
        if let replacement { token = replacement; self.replacement = nil }
        if token == value { token = nil }
        await audit.record("legacy.delete")
    }
}
private actor MigrationGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func isWaiting() -> Bool { entered }
    func open() { continuation?.resume(); continuation = nil }
}
private struct MigrationReply: Sendable {
    var endpoint = "community"
    var token = "fs_" + String(repeating: "a", count: 64)
    var status = 200
    var body = Data()
    var error: URLError.Code?
    var gate: MigrationGate?
    static func identity(token: String, confirmed: Bool = false, second: Bool = false, gate: MigrationGate? = nil) -> Self {
        let body: [String: Any] = ["purpose": "community", "account": ["id": second ? "migration-owner-b" : "migration-owner-a", "email": second ? "b@example.invalid" : "a@example.invalid"],
                                  "clientConfirmed": confirmed, "expiresAt": 1_900_003_600]
        return .init(token: token, body: try! JSONSerialization.data(withJSONObject: body), gate: gate)
    }
}
private actor MigrationTransport: CommunityConnectionTransport {
    private var replies: [MigrationReply]
    private var sent: [URLRequest] = []
    private let audit: MigrationAudit
    init(_ replies: [MigrationReply], audit: MigrationAudit) { self.replies = replies; self.audit = audit }
    func append(_ reply: MigrationReply) { replies.append(reply) }
    func requests() -> [URLRequest] { sent }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        precondition(!replies.isEmpty, "Migration made an unexpected request: \(request.url!.path)")
        let reply = replies.removeFirst()
        precondition(request.url!.path == "/api/device/\(reply.endpoint)")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(reply.token)")
        precondition(request.httpMethod == (reply.endpoint == "community" ? "GET" : "POST"))
        precondition(request.value(forHTTPHeaderField: "Cookie") == nil && !request.httpShouldHandleCookies)
        sent.append(request); await audit.record("request.\(reply.endpoint)")
        if let gate = reply.gate { await gate.wait() }
        if let error = reply.error { throw URLError(error) }
        return (reply.body, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                          headerFields: ["Content-Type": "application/json"])!)
    }
}
