// focus-studio-mcp: Focus Studio's MCP server for Claude Code, Codex and
// other MCP clients, which start it as a stdio server. It ships in
// Focus Studio.app/Contents/MacOS. It answers `initialize` and `tools/list`
// from the tool catalog without contacting or launching the app, and hands
// each `tools/call` to Focus Studio over its control socket
// (SocketAppForwarder), opening the app in the background when it is not
// running (unless FOCUS_STUDIO_MCP_NO_LAUNCH=1).

import Darwin
import FocusStudioAutomation
import Foundation

/// Runs before anything else can write: from here on standard output (fd 1)
/// is standard error, and only the transport writes to the original stream.
private func isolateStandardStreams() -> HelperStandardStreams {
    do {
        return try HelperStandardStreams.isolateProtocolOutput()
    } catch {
        FileHandle.standardError.write(Data("focus-studio-mcp: \(error)\n".utf8))
        exit(EX_OSERR)
    }
}

let standardStreams = isolateStandardStreams()
let environment = ProcessInfo.processInfo.environment
let identity = HelperIdentity.resolve()
let settings = HelperSettings(environment: environment)
let forwarder = SocketAppForwarder(
    settings: AppConnectionSettings(environment: environment, identity: identity),
    helperVersion: identity.version,
    helperPath: HelperIdentity.realExecutableURL()?.path,
    launcher: WorkspaceAppLauncher(),
    log: .standardError(level: settings.logLevel)
)
let host = MCPServerHost(
    identity: identity,
    catalog: .v1,
    forwarder: forwarder,
    workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
    settings: settings
)
let status = await host.runStdio(standardStreams)
standardStreams.restore()
exit(status)
