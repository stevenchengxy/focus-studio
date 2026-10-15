import Foundation
import Network

/// Exercises the community protocol without a live account, network, or Keychain.
/// The gates intentionally ignore task cancellation to model late I/O completions.
enum NativeCommunityConnectionRegression {
    private static let origin = URL(string: "https://community-fixture.invalid")!
    private static let instant = Date(timeIntervalSince1970: 1_900_000_000)
    private static let secretA = String(repeating: "a", count: 64)
    private static let secretB = String(repeating: "b", count: 64)
    private static let tokenA = "fs_" + secretA
    private static let codeA = "AAAAAA-AAAAAA"
    private static let codeB = "BBBBBB-BBBBBB"

    static func run() async throws {
        try await completeProtocolAndRestart()
        try await malformedPairingAndExchange()
        try await responseBoundaries()
        try await strictSuccessStatuses()
        try await realTransportRefusesRedirects()
        try await restartBeforeIdentity()
        try await failedConfirmationAndRecovery()
        try await credentialFailurePolicy()
        try await persistedScopeAndExpiry()
        try await malformedSavedPairingCanReconnect()
        try await cancelLateStartAndExchange()
        try await cancelLateIdentityAndConfirmation()
        try await cancelDuringVaultWrite()
        try await disconnectDuringRestore()
        precondition(CommunityKeychainVault.service == "studio.focus.community")
        precondition(CommunityKeychainVault.account == "community-connection-v1")
        print("NativeCommunityConnectionRegression: PASS (purpose and URL validation; credential scope; real URLSession redirect refusal; explicit confirmation; pending and token restart; malformed receipts; 401/503 recovery; lost activation response; stale I/O and serialized vault cancellation; disconnect; persisted origin and expiry)")
    }

    private static func completeProtocolAndRestart() async throws {
        let vault = CommunityFixtureVault()
        let transport = CommunityFixtureTransport([start()])
        let first = client(transport, vault)
        let pairing = try await first.startPairing()
        precondition(pairing.userCode == codeA && pairing.interval == 5)
        let pending = await first.snapshot()
        precondition(pending.pairing == pairing && !pending.hasCredential && !pending.clientConfirmed)

        // A process restart restores the same live grant without starting a new one.
        let resumedTransport = CommunityFixtureTransport([
            .init("token", status: 202, body: json(["status": "authorization_pending"])),
            exchange(), identity(),
            .init("activate", token: tokenA, body: json(["confirmed": true])),
        ])
        let resumed = client(resumedTransport, vault)
        let restored = try await resumed.restore()
        precondition(restored == pending)
        let callsBeforePolling = await resumedTransport.requests()
        precondition(callsBeforePolling.isEmpty, "Restoring a pending grant must not activate or restart pairing")
        let waiting = try await resumed.pollPairing(pairing)
        precondition(waiting == nil)
        let approved = try await resumed.pollPairing(pairing)
        precondition(approved?.identity?.id == "fixture-owner-a")
        precondition(approved?.hasCredential == true && approved?.clientConfirmed == false)
        precondition(approved?.pairing == nil)
        let beforeConsent = await resumedTransport.requests()
        precondition(!beforeConsent.contains { $0.url?.path == "/api/device/activate" },
                     "Browser approval and identity restoration must not bypass explicit native confirmation")
        let confirmed = try await resumed.confirmClient()
        precondition(confirmed.clientConfirmed && confirmed.identity?.id == "fixture-owner-a")

        let restartedTransport = CommunityFixtureTransport([identity(confirmed: true),
            .init("revoke", token: tokenA, body: json(["revoked": true]))])
        let restarted = client(restartedTransport, vault)
        let current = try await restarted.restore()
        precondition(current == confirmed)
        try await restarted.disconnect()
        let disconnected = await restarted.snapshot()
        let remaining = await vault.read()
        precondition(disconnected == .disconnected && remaining == nil)
        try await restartedTransport.assertFinished()
        try await resumedTransport.assertFinished()
        try await transport.assertFinished()
    }

    private static func malformedPairingAndExchange() async throws {
        var invalidStarts: [[String: Any]] = []
        for (key, value) in [("purpose", "account"), ("purpose", "COMMUNITY"),
                             ("deviceCode", "short"), ("deviceCode", String(repeating: "A", count: 64)),
                             ("userCode", "aaaaaa-aaaaaa"), ("userCode", "AAAAAA-AAAAA-")] {
            var body = startBody(); body[key] = value; invalidStarts.append(body)
        }
        for (key, value) in [("expiresIn", 0), ("expiresIn", 601), ("interval", 0), ("interval", 31)] {
            var body = startBody(); body[key] = value; invalidStarts.append(body)
        }
        for missing in ["purpose", "deviceCode", "userCode", "verificationUriComplete", "expiresIn", "interval"] {
            var body = startBody(); body.removeValue(forKey: missing); invalidStarts.append(body)
        }
        let invalidLinks = [
            "http://community-fixture.invalid/account?code=\(codeA)&purpose=community",
            "https://other.invalid/account?code=\(codeA)&purpose=community",
            "https://community-fixture.invalid.attacker.invalid/account?code=\(codeA)&purpose=community",
            "https://community-fixture.invalid:444/account?code=\(codeA)&purpose=community",
            "https://user:password@community-fixture.invalid/account?code=\(codeA)&purpose=community",
            "https://community-fixture.invalid/other?code=\(codeA)&purpose=community",
            "https://community-fixture.invalid/account?code=\(codeB)&purpose=community",
            "https://community-fixture.invalid/account?code=\(codeA)&purpose=account",
            "https://community-fixture.invalid/account?code=\(codeA)&purpose=community&code=\(codeB)",
            "https://community-fixture.invalid/account?code=\(codeA)&purpose=community&next=https://other.invalid",
            "https://community-fixture.invalid/account?code=\(codeA)&purpose=community#fragment",
        ]
        for link in invalidLinks {
            var body = startBody(); body["verificationUriComplete"] = link; invalidStarts.append(body)
        }
        for body in invalidStarts {
            let vault = CommunityFixtureVault()
            let transport = CommunityFixtureTransport([.init("start", body: json(body))])
            let value = client(transport, vault)
            try await expect("invalid_response") { _ = try await value.startPairing() }
            let stored = await vault.read()
            precondition(stored == nil, "Malformed pairing must not leave reusable credentials")
        }

        var invalidTokens: [[String: Any]] = []
        for (key, value) in [("purpose", "account"), ("tokenType", "Basic"),
                             ("accessToken", "fs_short"), ("accessToken", "fs_" + String(repeating: "A", count: 64))] {
            var body = tokenBody(); body[key] = value; invalidTokens.append(body)
        }
        for expiry in [0, -1, 30 * 86400 + 1] {
            var body = tokenBody(); body["expiresIn"] = expiry; invalidTokens.append(body)
        }
        for missing in ["purpose", "tokenType", "accessToken", "expiresIn"] {
            var body = tokenBody(); body.removeValue(forKey: missing); invalidTokens.append(body)
        }
        for body in invalidTokens {
            let transport = CommunityFixtureTransport([start(), .init("token", body: json(body))])
            let value = client(transport, CommunityFixtureVault())
            let pairing = try await value.startPairing()
            try await expect("invalid_response") { _ = try await value.pollPairing(pairing) }
            let snapshot = await value.snapshot()
            precondition(!snapshot.hasCredential && snapshot.pairing == pairing)
        }
        for body in [json([:]), json(["status": "approved"]), Data("<html>pending</html>".utf8)] {
            let transport = CommunityFixtureTransport([start(), .init("token", status: 202, body: body)])
            let value = client(transport, CommunityFixtureVault())
            let pairing = try await value.startPairing()
            try await expect("invalid_response") { _ = try await value.pollPairing(pairing) }
        }
    }

    private static func responseBoundaries() async throws {
        for status in [301, 302, 303, 307, 308] {
            let transport = CommunityFixtureTransport([.init("start", status: status, body: json(startBody()))])
            let value = client(transport, CommunityFixtureVault())
            try await expect("invalid_response") { _ = try await value.startPairing() }
        }
        for responseURL in ["https://other.invalid/api/device/start", "https://community-fixture.invalid/api/account",
                            "http://community-fixture.invalid/api/device/start"] {
            let transport = CommunityFixtureTransport([.init("start", body: json(startBody()), responseURL: URL(string: responseURL)!)])
            let value = client(transport, CommunityFixtureVault())
            try await expect("invalid_response") { _ = try await value.startPairing() }
        }
        for body in [Data(), Data("<html>OK</html>".utf8), Data(repeating: 32, count: 65_537)] {
            let transport = CommunityFixtureTransport([.init("start", body: body)])
            let value = client(transport, CommunityFixtureVault())
            try await expect("invalid_response") { _ = try await value.startPairing() }
        }
        // Checking a final response URL also protects injected transports that follow redirects.
        let transport = CommunityFixtureTransport([start(), exchange(),
            .init("community", method: "GET", token: tokenA, body: json(identityBody()),
                  responseURL: URL(string: "https://other.invalid/api/device/community")!)])
        let value = client(transport, CommunityFixtureVault())
        let pairing = try await value.startPairing()
        try await expect("invalid_response") { _ = try await value.pollPairing(pairing) }
        let snapshot = await value.snapshot()
        precondition(snapshot.identity == nil && !snapshot.clientConfirmed)

        var badIdentities: [[String: Any]] = []
        for purpose in ["account", "COMMUNITY", ""] {
            var body = identityBody(); body["purpose"] = purpose; badIdentities.append(body)
        }
        for expiry in [instant.timeIntervalSince1970, instant.addingTimeInterval(32 * 86400).timeIntervalSince1970] {
            var body = identityBody(); body["expiresAt"] = expiry; badIdentities.append(body)
        }
        for identity in [["id": "", "email": "fixture@example.invalid"], ["id": "fixture-owner-a", "email": ""]] {
            var body = identityBody(); body["account"] = identity; badIdentities.append(body)
        }
        for body in badIdentities {
            let transport = CommunityFixtureTransport([start(), exchange(), .init("community", method: "GET", token: tokenA, body: json(body))])
            let value = client(transport, CommunityFixtureVault())
            let pairing = try await value.startPairing()
            try await expect("invalid_response") { _ = try await value.pollPairing(pairing) }
            let snapshot = await value.snapshot()
            precondition(snapshot.identity == nil && !snapshot.clientConfirmed)
        }
    }

    private static func restartBeforeIdentity() async throws {
        let vault = CommunityFixtureVault()
        let transport = CommunityFixtureTransport([start(), exchange(), failure("community", 503)])
        let value = client(transport, vault)
        let pairing = try await value.startPairing()
        try await expect("service_unavailable") { _ = try await value.pollPairing(pairing) }
        let pending = await value.snapshot()
        precondition(pending.hasCredential && pending.identity == nil && !pending.clientConfirmed)
        try await expect("connection_expired") { _ = try await value.confirmClient() }
        try await transport.assertFinished()

        let restartTransport = CommunityFixtureTransport([identity()])
        let restart = client(restartTransport, vault)
        let restored = try await restart.restore()
        precondition(restored.hasCredential && restored.identity?.id == "fixture-owner-a" && !restored.clientConfirmed)
        try await restartTransport.assertFinished()
    }

    private static func strictSuccessStatuses() async throws {
        for status in [201, 202, 204, 206] {
            let transport = CommunityFixtureTransport([.init("start", status: status, body: json(startBody()))])
            let value = client(transport, CommunityFixtureVault())
            try await expect("invalid_response") { _ = try await value.startPairing() }
            for endpoint in ["community", "activate", "revoke"] {
                let (connected, scripted, vault) = try await connected()
                let body = endpoint == "community" ? identityBody() : (endpoint == "activate" ? ["confirmed": true] : ["revoked": true])
                await scripted.append(.init(endpoint, method: endpoint == "community" ? "GET" : "POST",
                                            token: tokenA, status: status, body: json(body)))
                try await expect(endpoint == "revoke" ? "remote_revoke_failed" : "invalid_response") {
                    switch endpoint {
                    case "community": _ = try await connected.restore()
                    case "activate": _ = try await connected.confirmClient()
                    default: try await connected.disconnect()
                    }
                }
                let snapshot = await connected.snapshot()
                precondition(!snapshot.clientConfirmed)
                if endpoint == "revoke" {
                    let remaining = await vault.read()
                    precondition(remaining == nil && snapshot == .disconnected)
                }
            }
        }
    }

    private static func realTransportRefusesRedirects() async throws {
        // Exercise the production URLSession delegate against a loopback HTTP
        // fixture. The client still requires HTTPS; no external service is used.
        for status in [301, 302, 303, 307, 308] {
            let server = try CommunityRedirectFixture(status: status)
            defer { server.stop() }
            let port = try await server.start()
            let transport = CommunityURLSessionTransport()
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/exchange")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.httpBody = json(["deviceCode": secretA])
            request.setValue("Bearer \(tokenA)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await transport.send(request)
            precondition(response.statusCode == status && response.url == request.url,
                         "The production transport must return the original redirect response")
            let paths = server.paths()
            precondition(paths == ["/exchange"], "No redirect may forward a bearer token or deviceCode, even to another path on the same origin")
        }
    }

    private static func failedConfirmationAndRecovery() async throws {
        for receipt in [json(["confirmed": false]), json([:]), json(["confirmed": "true"]), Data(), Data("OK".utf8)] {
            let (value, transport, _) = try await connected()
            await transport.append(.init("activate", token: tokenA, body: receipt))
            try await expect("invalid_response") { _ = try await value.confirmClient() }
            let snapshot = await value.snapshot()
            precondition(snapshot.hasCredential && !snapshot.clientConfirmed)
        }
        let (value, transport, vault) = try await connected()
        await transport.append(.init("activate", token: tokenA, error: .networkConnectionLost))
        do { _ = try await value.confirmClient(); preconditionFailure("A lost response cannot confirm locally") }
        catch let error as URLError { precondition(error.code == .networkConnectionLost) }
        let unknown = await value.snapshot()
        precondition(unknown.hasCredential && !unknown.clientConfirmed)
        let restartTransport = CommunityFixtureTransport([identity(confirmed: true)])
        let restart = client(restartTransport, vault)
        let recovered = try await restart.restore()
        precondition(recovered.clientConfirmed, "Authoritative identity recovers an activation whose reply was lost")
        let requests = await restartTransport.requests()
        precondition(requests.count == 1 && requests[0].url?.path == "/api/device/community")
    }

    private static func credentialFailurePolicy() async throws {
        for endpoint in ["community", "activate"] {
            for status in [401, 503] {
                let (value, transport, vault) = try await connected()
                await transport.append(failure(endpoint, status))
                try await expect(status == 401 ? "connection_expired" : "service_unavailable") {
                    if endpoint == "community" { _ = try await value.restore() }
                    else { _ = try await value.confirmClient() }
                }
                let snapshot = await value.snapshot()
                let stored = await vault.read()
                precondition(snapshot.hasCredential == (status == 503))
                precondition((stored != nil) == (status == 503))
                precondition(!snapshot.clientConfirmed)
            }
        }
        for code in ["code_expired", "device_revoked"] {
            let vault = CommunityFixtureVault()
            let transport = CommunityFixtureTransport([start(), .init("token", status: 410, body: json(["error": ["code": code]]))])
            let value = client(transport, vault)
            let pairing = try await value.startPairing()
            try await expect(code) { _ = try await value.pollPairing(pairing) }
            let snapshot = await value.snapshot()
            let stored = await vault.read()
            precondition(snapshot == .disconnected && stored == nil)
        }
        let (value, transport, vault) = try await connected()
        await transport.append(failure("revoke", 503))
        try await expect("remote_revoke_failed") { try await value.disconnect() }
        let snapshot = await value.snapshot()
        let stored = await vault.read()
        precondition(snapshot == .disconnected && stored == nil, "Failed remote revoke must still remove local access")

        let (expired, expiredTransport, expiredVault) = try await connected()
        await expiredTransport.append(failure("revoke", 401))
        try await expired.disconnect()
        let expiredSnapshot = await expired.snapshot()
        let expiredStored = await expiredVault.read()
        precondition(expiredSnapshot == .disconnected && expiredStored == nil, "An already invalid token is successfully disconnected")

        let (unrevoked, unrevokedTransport, unrevokedVault) = try await connected()
        await unrevokedTransport.append(.init("revoke", token: tokenA, body: json(["revoked": false])))
        try await expect("remote_revoke_failed") { try await unrevoked.disconnect() }
        let unrevokedStored = await unrevokedVault.read()
        precondition(unrevokedStored == nil)
    }

    private static func persistedScopeAndExpiry() async throws {
        let (_, _, vault) = try await connected()
        guard let saved = await vault.read() else { preconditionFailure("Missing fixture token") }
        for replacement in ["https://other.invalid", "https://community-fixture.invalid:444"] {
            let transport = CommunityFixtureTransport([])
            let scopedVault = CommunityFixtureVault(saved)
            let value = NativeCommunityConnectionClient(origin: URL(string: replacement)!, transport: transport, vault: scopedVault, isInstalledClient: { true }, now: { instant })
            try await expect("invalid_response") { _ = try await value.restore() }
            try await transport.assertFinished()
        }
        for (key, replacement) in [("purpose", "account" as Any), ("version", 2 as Any)] {
            var body = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
            body[key] = replacement
            let scopedVault = CommunityFixtureVault(json(body))
            let transport = CommunityFixtureTransport([])
            let value = client(transport, scopedVault)
            try await expect("invalid_response") { _ = try await value.restore() }
            try await transport.assertFinished()
        }
        for stored in [Data(), Data("not JSON".utf8)] {
            let transport = CommunityFixtureTransport([])
            let value = client(transport, CommunityFixtureVault(stored))
            try await expect("invalid_response") { _ = try await value.restore() }
            try await transport.assertFinished()
        }
        let expiredTransport = CommunityFixtureTransport([])
        let expired = NativeCommunityConnectionClient(origin: origin, transport: expiredTransport, vault: vault, isInstalledClient: { true },
                                                       now: { instant.addingTimeInterval(30 * 86400 + 1) })
        try await expect("connection_expired") { _ = try await expired.restore() }
        let deleted = await vault.read()
        precondition(deleted == nil)
        try await expiredTransport.assertFinished()

        let pendingVault = CommunityFixtureVault()
        let original = client(CommunityFixtureTransport([start()]), pendingVault)
        _ = try await original.startPairing()
        let transport = CommunityFixtureTransport([])
        let oldPairing = NativeCommunityConnectionClient(origin: origin, transport: transport, vault: pendingVault, isInstalledClient: { true },
                                                         now: { instant.addingTimeInterval(601) })
        try await expect("connection_expired") { _ = try await oldPairing.restore() }
        let pendingDeleted = await pendingVault.read()
        precondition(pendingDeleted == nil)

        // A valid token cannot silently become another browser user's identity.
        let (value, identityTransport, _) = try await connected()
        var foreignIdentity = identityBody(); foreignIdentity["account"] = ["id": "fixture-owner-b", "email": "b@example.invalid"]
        await identityTransport.append(.init("community", method: "GET", token: tokenA, body: json(foreignIdentity)))
        try await expect("invalid_response") { _ = try await value.restore() }
        let snapshot = await value.snapshot()
        precondition(snapshot.identity?.id == "fixture-owner-a")

        let confirmationVault = CommunityFixtureVault(saved)
        let confirmationTransport = CommunityFixtureTransport([])
        let expiredConfirmation = NativeCommunityConnectionClient(origin: origin, transport: confirmationTransport,
            vault: confirmationVault, isInstalledClient: { true }, now: { instant.addingTimeInterval(30 * 86400 + 1) })
        try await expect("connection_expired") { _ = try await expiredConfirmation.confirmClient() }
        let confirmationDeleted = await confirmationVault.read()
        precondition(confirmationDeleted == nil)
        try await confirmationTransport.assertFinished()
    }

    private static func malformedSavedPairingCanReconnect() async throws {
        let vault = CommunityFixtureVault()
        let original = client(CommunityFixtureTransport([start()]), vault)
        _ = try await original.startPairing()
        guard let saved = await vault.read() else { preconditionFailure("Missing saved grant") }
        for (key, replacement) in [("interval", 0 as Any), ("interval", 31 as Any),
                                   ("expiresAt", "invalid-date" as Any), ("deviceCode", "not-a-secret" as Any),
                                   ("verificationURL", "https://other.invalid/account" as Any)] {
            var record = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
            var pairing = record["pairing"] as! [String: Any]
            pairing[key] = replacement; record["pairing"] = pairing
            let damagedVault = CommunityFixtureVault(json(record))
            let transport = CommunityFixtureTransport([])
            let value = client(transport, damagedVault)
            try await expect("invalid_response") { _ = try await value.restore() }
            let remaining = await damagedVault.read()
            precondition(remaining == nil, "An incompatible community record must not permanently block reconnect")
            try await transport.assertFinished()
            await transport.append(start(second: true))
            let newPairing = try await value.startPairing()
            precondition(newPairing.userCode == codeB)
        }
    }

    private static func cancelLateStartAndExchange() async throws {
        for phase in ["start", "token"] {
            let gate = CommunityFixtureGate()
            let vault = CommunityFixtureVault()
            let transport = CommunityFixtureTransport(phase == "start" ? [start(gate: gate), start(second: true)] :
                [start(), exchange(gate: gate), start(second: true)])
            let value = client(transport, vault)
            let stale: Task<Void, Error>
            if phase == "start" {
                stale = Task { _ = try await value.startPairing() }
            } else {
                let pairing = try await value.startPairing()
                stale = Task { _ = try await value.pollPairing(pairing) }
            }
            try await waitUntil { await gate.isWaiting() }
            try await value.cancelPairing()
            let replacement = try await value.startPairing()
            await gate.open()
            try await expectCancelled(stale)
            let snapshot = await value.snapshot()
            precondition(snapshot.pairing == replacement && replacement.userCode == codeB && !snapshot.hasCredential)
            let restart = client(CommunityFixtureTransport([]), vault)
            let persisted = try await restart.restore()
            precondition(persisted == snapshot)
        }
    }

    private static func cancelLateIdentityAndConfirmation() async throws {
        for phase in ["community", "activate"] {
            let gate = CommunityFixtureGate()
            let vault = CommunityFixtureVault()
            let transport = CommunityFixtureTransport([start(), exchange(), identity(gate: phase == "community" ? gate : nil)])
            let value = client(transport, vault)
            let pairing = try await value.startPairing()
            let stale: Task<Void, Error>
            if phase == "community" {
                stale = Task { _ = try await value.pollPairing(pairing) }
            } else {
                _ = try await value.pollPairing(pairing)
                await transport.append(.init("activate", token: tokenA, body: json(["confirmed": true]), gate: gate))
                stale = Task { _ = try await value.confirmClient() }
            }
            try await waitUntil { await gate.isWaiting() }
            try await value.cancelPairing()
            await transport.append(start(second: true))
            let replacement = try await value.startPairing()
            await gate.open()
            try await expectCancelled(stale)
            let snapshot = await value.snapshot()
            precondition(snapshot.pairing == replacement && !snapshot.hasCredential && !snapshot.clientConfirmed)
            let restart = client(CommunityFixtureTransport([]), vault)
            let persisted = try await restart.restore()
            precondition(persisted == snapshot)
        }
    }

    private static func cancelDuringVaultWrite() async throws {
        // The token exchange returns, but its Keychain write has not completed.
        // Cancellation's delete and B's write must be serialized behind A's write.
        let gate = CommunityFixtureGate()
        let deleteGate = CommunityFixtureGate()
        let vault = CommunityFixtureVault()
        let transport = CommunityFixtureTransport([start(), exchange(), start(second: true)])
        let value = client(transport, vault)
        let pairing = try await value.startPairing()
        await vault.holdNextWrite(gate)
        let stale = Task { _ = try await value.pollPairing(pairing) }
        try await waitUntil { await gate.isWaiting() }
        await vault.holdNextDelete(deleteGate)
        stale.cancel()
        let cancelled = Task { try await value.cancelPairing() }
        await gate.open()
        try await waitUntil { await deleteGate.isWaiting() }
        // B now begins while the already-enqueued cancellation delete is blocked.
        let replacementTask = Task { try await value.startPairing() }
        try await waitUntil { await transport.requests().count == 3 }
        await deleteGate.open()
        try await expectCancelled(stale)
        do { try await cancelled.value } catch is CancellationError { /* B superseded the delete's caller. */ }
        let replacement = try await replacementTask.value
        let snapshot = await value.snapshot()
        precondition(snapshot.pairing == replacement && replacement.userCode == codeB && !snapshot.hasCredential)
        let restart = client(CommunityFixtureTransport([]), vault)
        let persisted = try await restart.restore()
        precondition(persisted == snapshot, "A delayed write must never resurrect A after cancel and reconnect B")
        let history = await vault.history()
        precondition(history.count == 4 && history[2] == nil, "The vault must write A, delete A, then write B in order")
    }

    private static func disconnectDuringRestore() async throws {
        let (value, transport, vault) = try await connected()
        let gate = CommunityFixtureGate()
        await transport.append(identity(confirmed: true, gate: gate))
        await transport.append(.init("revoke", token: tokenA, body: json(["revoked": true])))
        let stale = Task { _ = try await value.restore() }
        try await waitUntil { await gate.isWaiting() }
        try await value.disconnect()
        await gate.open()
        try await expectCancelled(stale)
        let snapshot = await value.snapshot()
        let stored = await vault.read()
        precondition(snapshot == .disconnected && stored == nil)
    }

    private static func client(_ transport: CommunityFixtureTransport, _ vault: CommunityFixtureVault) -> NativeCommunityConnectionClient {
        NativeCommunityConnectionClient(origin: origin, transport: transport, vault: vault, isInstalledClient: { true }, now: { instant })
    }
    private static func connected() async throws -> (NativeCommunityConnectionClient, CommunityFixtureTransport, CommunityFixtureVault) {
        let vault = CommunityFixtureVault()
        let transport = CommunityFixtureTransport([start(), exchange(), identity()])
        let value = client(transport, vault)
        let pairing = try await value.startPairing()
        let snapshot = try await value.pollPairing(pairing)
        precondition(snapshot?.hasCredential == true && snapshot?.identity != nil && snapshot?.clientConfirmed == false)
        return (value, transport, vault)
    }
    private static func startBody(second: Bool = false) -> [String: Any] {
        let code = second ? codeB : codeA
        return ["deviceCode": second ? secretB : secretA, "userCode": code,
                "verificationUriComplete": "\(origin.absoluteString)/account?code=\(code)&purpose=community",
                "expiresIn": 600, "interval": 5, "purpose": "community"]
    }
    private static func tokenBody() -> [String: Any] {
        ["accessToken": tokenA, "tokenType": "Bearer", "expiresIn": 30 * 86400, "purpose": "community"]
    }
    private static func identityBody(confirmed: Bool = false) -> [String: Any] {
        ["purpose": "community", "account": ["id": "fixture-owner-a", "email": "fixture@example.invalid", "displayName": "Fixture Creator"],
         "clientConfirmed": confirmed, "expiresAt": instant.addingTimeInterval(30 * 86400).timeIntervalSince1970]
    }
    private static func json(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private static func start(second: Bool = false, gate: CommunityFixtureGate? = nil) -> CommunityFixtureReply {
        .init("start", body: json(startBody(second: second)), gate: gate)
    }
    private static func exchange(gate: CommunityFixtureGate? = nil) -> CommunityFixtureReply {
        .init("token", body: json(tokenBody()), gate: gate)
    }
    private static func identity(confirmed: Bool = false, gate: CommunityFixtureGate? = nil) -> CommunityFixtureReply {
        .init("community", method: "GET", token: tokenA, body: json(identityBody(confirmed: confirmed)), gate: gate)
    }
    private static func failure(_ endpoint: String, _ status: Int) -> CommunityFixtureReply {
        .init(endpoint, method: endpoint == "community" ? "GET" : "POST", token: tokenA, status: status,
              body: json(["error": ["code": status == 401 ? "community_device_required" : "service_error"]]))
    }
    private static func expect(_ code: String, action: () async throws -> Void) async throws {
        do { try await action(); preconditionFailure("Expected community error \(code)") }
        catch let failure as CommunityConnectionError { precondition(failure.code == code, "Expected \(code), got \(failure.code)") }
    }
    private static func expectCancelled(_ task: Task<Void, Error>) async throws {
        do { try await task.value; preconditionFailure("Superseded work must throw CancellationError") }
        catch is CancellationError { }
    }
    private static func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await predicate()) {
            precondition(Date() < deadline, "Timed out waiting for fixture I/O")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private actor CommunityFixtureGate {
    private var entered = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func isWaiting() -> Bool { entered }
    func open() {
        opened = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private struct CommunityFixtureReply: Sendable {
    let endpoint: String
    let method: String
    let token: String?
    let status: Int
    let body: Data
    let responseURL: URL?
    let gate: CommunityFixtureGate?
    let error: URLError.Code?
    init(_ endpoint: String, method: String = "POST", token: String? = nil, status: Int = 200,
         body: Data = Data(), responseURL: URL? = nil, gate: CommunityFixtureGate? = nil, error: URLError.Code? = nil) {
        self.endpoint = endpoint; self.method = method; self.token = token; self.status = status
        self.body = body; self.responseURL = responseURL; self.gate = gate; self.error = error
    }
}

private actor CommunityFixtureTransport: CommunityConnectionTransport {
    private var replies: [CommunityFixtureReply]
    private var sent: [URLRequest] = []
    init(_ replies: [CommunityFixtureReply]) { self.replies = replies }
    func append(_ reply: CommunityFixtureReply) { replies.append(reply) }
    func requests() -> [URLRequest] { sent }
    func assertFinished() throws { precondition(replies.isEmpty, "Some expected protocol requests were not sent") }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        precondition(!replies.isEmpty, "Unexpected community network request: \(request.url?.path ?? "missing")")
        let reply = replies.removeFirst()
        precondition(request.url?.path == "/api/device/\(reply.endpoint)")
        precondition(request.httpMethod == reply.method)
        precondition(request.value(forHTTPHeaderField: "Authorization") == reply.token.map { "Bearer \($0)" },
                     "Community bearer must be absent on grant endpoints and scoped to community identity/activation/revoke")
        precondition(request.value(forHTTPHeaderField: "Cookie") == nil && !request.httpShouldHandleCookies)
        precondition(request.cachePolicy == .reloadIgnoringLocalCacheData)
        precondition(request.value(forHTTPHeaderField: "Accept") == "application/json")
        if reply.endpoint == "start" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            precondition(body == ["purpose": "community"])
        } else if reply.endpoint == "token" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            precondition(body.keys.sorted() == ["deviceCode"] && body["deviceCode"]?.count == 64)
        } else if reply.endpoint == "community" {
            precondition(request.httpBody == nil)
        } else {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            precondition(body.isEmpty, "The bearer, never a supplied owner ID, selects activation/revocation identity")
        }
        sent.append(request)
        if let gate = reply.gate { await gate.wait() }
        if let error = reply.error { throw URLError(error) }
        let response = HTTPURLResponse(url: reply.responseURL ?? request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (reply.body, response)
    }
}

private actor CommunityFixtureVault: CommunityCredentialVault {
    private var value: Data?
    private var writes: [Data?] = []
    private var writeGate: CommunityFixtureGate?
    private var deleteGate: CommunityFixtureGate?
    init(_ value: Data? = nil) { self.value = value }
    func read() -> Data? { value }
    func holdNextWrite(_ gate: CommunityFixtureGate) { writeGate = gate }
    func holdNextDelete(_ gate: CommunityFixtureGate) { deleteGate = gate }
    func history() -> [Data?] { writes }
    func write(_ data: Data) async {
        let gate = writeGate; writeGate = nil
        if let gate { await gate.wait() }
        value = data; writes.append(data)
    }
    func delete() async {
        let gate = deleteGate; deleteGate = nil
        if let gate { await gate.wait() }
        value = nil; writes.append(nil)
    }
}

/// A local HTTP fixture proves URLSession itself refuses redirects before a
/// second request can carry credentials. No TLS exception is added to the client.
private final class CommunityRedirectFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "studio.focus.tests.community-redirect")
    private let status: Int
    private let lock = NSLock()
    private var receivedPaths: [String] = []

    init(status: Int) throws {
        self.status = status
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
    func paths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return receivedPaths
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] bytes, _, complete, error in
            var request = accumulated
            if let bytes { request.append(bytes) }
            guard request.count <= 65_536 else { connection.cancel(); return }
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete || error != nil { connection.cancel() }
                else { receive(connection, accumulated: request) }
                return
            }
            let path = text.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "missing"
            lock.lock(); receivedPaths.append(path); lock.unlock()
            let reply: String
            if path == "/exchange" {
                reply = "HTTP/1.1 \(status) Redirect\r\nLocation: http://127.0.0.1:\(listener.port!.rawValue)/credential-leak\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            } else {
                reply = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
