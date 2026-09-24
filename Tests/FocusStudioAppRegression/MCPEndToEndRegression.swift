import CoreGraphics
import Darwin
import FocusStudioAutomation
import FocusStudioCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The whole MCP chain end to end, with nothing faked between the client and
/// the library: Tests/MCPTests/mcp_e2e.py is the MCP client, it starts the
/// real focus-studio-mcp binary over stdio, and the helper reaches this
/// process's real ControlServer, which runs each call through the approval
/// check and AutomationBridge against a StudioModel. Everything lives in a
/// temporary folder: the library, its Trash (the store's trash operation),
/// the socket (FOCUS_STUDIO_CONTROL_SOCKET), the preferences holding the
/// approval, and the client's working directory with the fixture video and
/// the export. The approver allows the client and records the request; the
/// client's identity is resolved for real (the helper's parent: python3,
/// keyed by the script it runs, mcp_e2e.py).
///
/// scripts/test-app-regression.sh passes the helper, the driver and the tool
/// list in FOCUS_STUDIO_TEST_MCP_HELPER, FOCUS_STUDIO_TEST_MCP_E2E and
/// FOCUS_STUDIO_TEST_MCP_TOOLS.
@MainActor
enum MCPEndToEndRegression {
    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let helper = environment["FOCUS_STUDIO_TEST_MCP_HELPER"], let driver = environment["FOCUS_STUDIO_TEST_MCP_E2E"],
              let tools = environment["FOCUS_STUDIO_TEST_MCP_TOOLS"] else {
            throw ServerFailure("MCPEndToEndRegression needs FOCUS_STUDIO_TEST_MCP_HELPER, FOCUS_STUDIO_TEST_MCP_E2E and FOCUS_STUDIO_TEST_MCP_TOOLS; scripts/test-app-regression.sh sets them.")
        }
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw ServerFailure("No focus-studio-mcp at \(helper); run swift build first.") }

        let fixture = try await EndToEndFixture()
        defer { fixture.cleanup() }
        var windowRequests = 0
        fixture.bridge.presentWindow = { windowRequests += 1 }
        let server = fixture.makeServer()
        server.start()
        defer { server.stop() }
        try ControlServerRegression.expect(server.state == .listening(fixture.socketPath), "The server listens on the test socket: \(server.state)")

        let started = Date()
        let run = try await PythonRun.run(
            arguments: [driver, helper, "--socket", fixture.socketPath, "--cwd", fixture.cwd.path, "--fixture", tools],
            timeout: 240
        )
        guard run.status == 0, let line = run.output.split(separator: "\n").first(where: { $0.hasPrefix("mcp_e2e.py: PASS project ") }) else {
            throw ServerFailure("mcp_e2e.py failed (exit \(run.status)):\n\(run.output)\n\(run.errors)")
        }
        let projectID = String(line.dropFirst("mcp_e2e.py: PASS project ".count).prefix(36))

        // What the app did: the project went through the library and into the Trash.
        await fixture.model.flushProjectEdits()
        try ControlServerRegression.expect(fixture.model.projects.isEmpty && !FileManager.default.fileExists(atPath: fixture.projects.appendingPathComponent(projectID).path),
                                           "The library is empty again: \(fixture.model.projects.map(\.title))")
        let trashed = fixture.trash.appendingPathComponent(projectID)
        try ControlServerRegression.expect(FileManager.default.fileExists(atPath: trashed.appendingPathComponent("project.json").path), "The project folder went to the (test) Trash: \(trashed.path)")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(RecordingProject.self, from: Data(contentsOf: trashed.appendingPathComponent("project.json")))
        try ControlServerRegression.expect(saved.title == "E2E renamed" && saved.zoomSegments.count == 1 && saved.settings.padding == 24 && saved.settings.cornerRadius == 12 && saved.settings.frameRate == 24,
                                           "Its last saved state has the rename, the zoom and the settings: \(saved.title), \(saved.zoomSegments.count) zooms, padding \(saved.settings.padding), \(saved.settings.frameRate) fps")
        let export = fixture.cwd.appendingPathComponent("out/e2e.mp4")
        try ControlServerRegression.expect(((try? FileManager.default.attributesOfItem(atPath: export.path)[.size] as? Int) ?? 0) > 1_000, "The export is in the client's folder")
        try ControlServerRegression.expect(FileManager.default.fileExists(atPath: fixture.cwd.appendingPathComponent("clip.mp4").path), "The imported video is copied, not moved")

        // Approval: asked once, for the client as it introduced itself and the program behind the helper.
        try ControlServerRegression.expect(fixture.approvals.count == 1 && fixture.approvals[0].clientName == "Claude Code" && fixture.approvals[0].toolName == "get_status"
                                           && fixture.approvals[0].clientVersion == "2.1.0-e2e",
                                           "One approval request, for Claude Code's first call: \(fixture.approvals)")
        let program = fixture.approvals[0].identity
        // python3 is a generic host: the approval is keyed by the script it runs, so it does not cover every python program.
        guard let resolvedDriver = realpath(driver, nil) else { throw ServerFailure("realpath \(driver)") }
        let driverPath = String(cString: resolvedDriver)
        free(resolvedDriver)
        try ControlServerRegression.expect(program.programPath.lowercased().contains("python") && program.key.hasPrefix(program.teamIdentifier == nil ? "path:" : "codesign:")
                                           && program.isGenericHost && program.scriptPath == driverPath && program.key.hasSuffix("|script:\(driverPath)") && program.isRememberable,
                                           "The program behind the helper is the client that started it (python3 running mcp_e2e.py), keyed by that script: \(program)")
        try ControlServerRegression.expect(fixture.store.approvedClients.map(\.identity.key) == [program.key], "The approval is remembered")
        try ControlServerRegression.expect(windowRequests >= 5, "Navigating calls put the window on screen: \(windowRequests)")
        try await ControlServerRegression.waitUntil("the helper's connection to close") { server.connectionCount == 0 }
        try ControlServerRegression.expect(fixture.activity.running.isEmpty && server.runningCallCount == 0, "Nothing is left running")
        print("MCPEndToEndRegression: PASS (\(line.dropFirst("mcp_e2e.py: PASS ".count)); app side: library empty, project in the test Trash with its rename, zoom and settings, export in the client's folder, one approval for Claude Code keyed to \(program.programName), \(windowRequests) window requests, connection closed; \(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
    }
}

/// A temporary library, Trash, socket, preferences and client folder.
@MainActor
private final class EndToEndFixture {
    let root: URL
    let projects: URL
    let trash: URL
    let cwd: URL
    let socketPath: String
    let model: StudioModel
    let bridge: AutomationBridge
    let suiteName: String
    let defaults: UserDefaults
    let store: AutomationAccessStore
    let access: AutomationAccessController
    let activity = AutomationActivity()
    private(set) var approvals: [AutomationApprovalRequest] = []

    init() async throws {
        let fileManager = FileManager.default
        // Short: a socket path must fit in 103 bytes.
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("fse-\(UUID().uuidString.prefix(8))", isDirectory: true)
        projects = root.appendingPathComponent("Projects", isDirectory: true)
        trash = root.appendingPathComponent("Trash", isDirectory: true)
        cwd = root.appendingPathComponent("client", isDirectory: true)
        socketPath = root.appendingPathComponent("Control/control.sock").path
        for folder in [projects, trash, cwd] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let trash = self.trash
        let store = ProjectStore(projectsDirectory: projects, trashOperation: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
        model = StudioModel(store: store, interactionTrackingAccess: { true }, inputMonitoringAccess: { true }, screenCaptureAccess: { true })
        bridge = AutomationBridge(model: model)
        let image = root.appendingPathComponent("frame.png")
        try Self.writeImage(to: image)
        _ = try await StillImageVideoBuilder.build(from: image, to: cwd.appendingPathComponent("clip.mp4"), duration: 2, renderSize: CGSize(width: 320, height: 180))
        // A preferences file inside the temporary folder (a suite named by an
        // absolute path), so nothing lands in ~/Library/Preferences.
        let preferences = root.appendingPathComponent("Preferences", isDirectory: true)
        try fileManager.createDirectory(at: preferences, withIntermediateDirectories: true)
        suiteName = preferences.appendingPathComponent("app.focusstudio.mcp-e2e").path
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw ServerFailure("No test preferences") }
        self.defaults = defaults
        self.store = AutomationAccessStore(defaults: defaults)
        var recorder: ((AutomationApprovalRequest) -> Void)?
        access = AutomationAccessController(store: self.store) { request in
            recorder?(request)
            return true
        }
        recorder = { [unowned self] request in approvals.append(request) }
    }

    /// The server as the app builds it, on the test socket: the real peer
    /// check and client identity, the test's approver.
    func makeServer() -> ControlServer {
        let model = self.model
        return ControlServer(
            location: ControlSocketLocation(path: socketPath, source: .environment),
            bridge: bridge,
            access: access,
            activity: activity,
            appInfo: ControlAppInfo(version: "1.5.0-e2e", path: root.appendingPathComponent("Focus Studio E2E.app").path, processID: getpid()),
            readiness: { await model.bootstrap() }
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private static func writeImage(to url: URL) throws {
        guard let context = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ServerFailure("Could not create a bitmap context")
        }
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 120, height: 80))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ServerFailure("Could not encode the fixture image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ServerFailure("Could not write the fixture image") }
    }
}

/// Runs python3 with arguments without blocking the main actor, which keeps
/// serving the control socket meanwhile.
enum PythonRun {
    struct Outcome {
        let status: Int32
        let output: String
        let errors: String
    }

    static func run(arguments: [String], timeout: TimeInterval) async throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3"] + arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let outputData = PipeReader(output.fileHandleForReading)
        let errorData = PipeReader(errors.fileHandleForReading)
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
        return Outcome(status: status, output: outputData.text(), errors: errorData.text())
    }
}

/// Drains a pipe in the background, so a chatty child never blocks on it.
private final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global().async { [self] in
            let all = handle.readDataToEndOfFile()
            lock.withLock { data = all }
            done.signal()
        }
    }

    func text() -> String {
        _ = done.wait(timeout: .now() + 10)
        return lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
