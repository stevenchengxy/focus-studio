import Foundation

enum NativeCommunityRegression {
    @MainActor
    static func run() async throws {
        let vault = CommunityMemoryVault()
        let server = CommunityFixtureServer()
        let client = NativeCommunityClient(vault: vault, isInstalledClient: { true }, transport: { try await server.send($0) })
        let pairing = try await client.startPairing()
        communityExpect(pairing.purpose == "community")
        communityExpect(try await client.pollPairing(pairing))
        communityExpect(await server.activationCount == 0, "Exchanging a token must not claim that the client is confirmed")
        communityExpect(await vault.read() == CommunityFixtureServer.token)
        try await client.confirm()
        communityExpect(await server.activationCount == 1)
        communityExpect(await server.paths == ["/api/device/start", "/api/device/token", "/api/device/activate"],
                     "Community tokens must never be used for billing or /api/account")

        for receipt in ["{}", "{\"confirmed\":false}", "{\"confirmed\":1}", "not-json"] {
            await server.setActivation(200, body: receipt)
            await rejects(code: "invalid_response") { try await client.confirm() }
        }
        await server.setActivation(403, body: "{\"error\":{\"code\":\"community_device_required\"}}")
        await rejects(code: "community_device_required") { try await client.confirm() }
        let reconnectStore = NativeCommunityConnectionStore(client: client)
        await reconnectStore.refresh()
        communityExpect(reconnectStore.state == .reconnectRequired, "Legacy tokens must ask for a new community pairing")
        await server.setActivation(401, body: "{\"error\":{\"code\":\"device_expired\"}}")
        await rejects(code: "device_expired") { try await client.confirm() }
        communityExpect(await vault.read() == nil, "An expired community credential must be cleared")

        let offlineVault = CommunityMemoryVault(CommunityFixtureServer.token)
        let offline = NativeCommunityClient(vault: offlineVault, isInstalledClient: { true }, transport: { _ in throw URLError(.notConnectedToInternet) })
        do { try await offline.confirm(); preconditionFailure("An offline confirmation cannot succeed") } catch {}
        communityExpect(await offlineVault.read() == CommunityFixtureServer.token, "A network error must preserve the token for retry")
        let outside = NativeCommunityClient(vault: offlineVault, isInstalledClient: { false }, transport: { _ in
            preconditionFailure("An app outside canonical Applications must never send confirmation requests")
        })
        await rejects(code: "installation_required") { try await outside.confirm() }
        await rejects(code: "installation_required") { _ = try await outside.startPairing() }

        let wrongPurposeServer = CommunityFixtureServer()
        await wrongPurposeServer.setPurpose("account")
        let wrongPurposeVault = CommunityMemoryVault()
        let wrongPurpose = NativeCommunityClient(vault: wrongPurposeVault, isInstalledClient: { true }, transport: { try await wrongPurposeServer.send($0) })
        await rejects(code: "invalid_response") { _ = try await wrongPurpose.startPairing() }
        await wrongPurposeServer.setPurpose("community")
        let newPairing = try await wrongPurpose.startPairing()
        await wrongPurposeServer.setPurpose("account")
        await rejects(code: "invalid_response") { _ = try await wrongPurpose.pollPairing(newPairing) }
        communityExpect(await wrongPurposeVault.read() == nil)

        let raceVault = CommunityMemoryVault()
        let raceServer = CommunityFixtureServer()
        await raceServer.holdTokenResponse()
        let raceClient = NativeCommunityClient(vault: raceVault, isInstalledClient: { true }, transport: { try await raceServer.send($0) })
        let racePairing = try await raceClient.startPairing()
        let exchange = Task { try await raceClient.pollPairing(racePairing) }
        while await raceServer.tokenRequests == 0 { await Task.yield() }
        await raceClient.cancelPendingConnection()
        await raceServer.releaseTokenResponse()
        do { _ = try await exchange.value; preconditionFailure("A cancelled exchange must not restore login") }
        catch is CancellationError {}
        communityExpect(await raceVault.read() == nil)

        // A delayed confirmation must not restore success after disconnect.
        let confirmVault = CommunityMemoryVault(CommunityFixtureServer.token)
        let confirmServer = CommunityFixtureServer()
        await confirmServer.holdActivationResponse()
        let confirmClient = NativeCommunityClient(vault: confirmVault, isInstalledClient: { true }, transport: { try await confirmServer.send($0) })
        let confirmation = Task { try await confirmClient.confirm() }
        while await confirmServer.activationCount == 0 { await Task.yield() }
        try await confirmClient.disconnect()
        await confirmServer.releaseActivationResponse()
        do { try await confirmation.value; preconditionFailure("A disconnected client cannot become confirmed from a late response") }
        catch is CancellationError {}
        communityExpect(await confirmVault.read() == nil)

        await server.setActivation(200, body: "{\"confirmed\":true}")
        await vault.write(CommunityFixtureServer.token)
        let confirmedStore = NativeCommunityConnectionStore(client: client)
        await confirmedStore.refresh()
        communityExpect(confirmedStore.state == .confirmed)
        print("NativeCommunityRegression: PASS (purpose-scoped pairing, separate confirmation receipt, canonical gate, no account/billing calls, legacy reconnect, malformed receipts, expiry/offline handling, cancellation/disconnect races; fake transport and memory vault only)")
    }

    private static func rejects(code: String, _ operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("Expected community error \(code)") }
        catch let error as NativeCommunityError { communityExpect(error.code == code, "Unexpected community error: \(error.code)") }
        catch { preconditionFailure("Unexpected error: \(error)") }
    }
}

private actor CommunityMemoryVault: NativeCommunityTokenStoring {
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func read() -> String? { value }
    func write(_ token: String) { value = token }
    func delete() { value = nil }
    func delete(ifMatching token: String) { if value == token { value = nil } }
}

private actor CommunityFixtureServer {
    static let token = "fs_" + String(repeating: "b", count: 64)
    private(set) var paths: [String] = []
    private(set) var activationCount = 0
    private(set) var tokenRequests = 0
    private var purpose = "community"
    private var activationStatus = 200
    private var activationBody = "{\"confirmed\":true}"
    private var tokenHeld = false
    private var activationHeld = false
    private var tokenWaiter: CheckedContinuation<Void, Never>?
    private var activationWaiter: CheckedContinuation<Void, Never>?
    func setPurpose(_ value: String) { purpose = value }
    func setActivation(_ status: Int, body: String) { activationStatus = status; activationBody = body }
    func holdTokenResponse() { tokenHeld = true }
    func holdActivationResponse() { activationHeld = true }
    func releaseTokenResponse() { tokenHeld = false; tokenWaiter?.resume(); tokenWaiter = nil }
    func releaseActivationResponse() { activationHeld = false; activationWaiter?.resume(); activationWaiter = nil }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        paths.append(path)
        communityExpect(request.httpMethod == "POST")
        let input = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        var status = 200
        let data: Data
        switch path {
        case "/api/device/start":
            communityExpect(input == ["purpose": "community"])
            communityExpect(request.value(forHTTPHeaderField: "Authorization") == nil)
            data = try JSONSerialization.data(withJSONObject: ["deviceCode": String(repeating: "a", count: 64), "userCode": "ABC123-DEF456",
                "verificationUriComplete": "https://focus-studio.stevenchengxy19.chatgpt.site/account?code=ABC123-DEF456&purpose=\(purpose)",
                "expiresIn": 600, "interval": 5, "purpose": purpose])
        case "/api/device/token":
            tokenRequests += 1
            communityExpect(input == ["deviceCode": String(repeating: "a", count: 64)])
            if tokenHeld { await withCheckedContinuation { tokenWaiter = $0 } }
            data = try JSONSerialization.data(withJSONObject: ["accessToken": Self.token, "purpose": purpose])
        case "/api/device/activate":
            activationCount += 1
            communityExpect(input.isEmpty)
            communityExpect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
            if activationHeld { await withCheckedContinuation { activationWaiter = $0 } }
            status = activationStatus
            data = Data(activationBody.utf8)
        case "/api/device/revoke":
            communityExpect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
            data = Data("{}".utf8)
        default: preconditionFailure("Unexpected request: \(path)")
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                      headerFields: ["Content-Type": "application/json"])!)
    }
}

private func communityExpect(_ value: Bool, _ message: String = "") { precondition(value, message) }
