// focus-studio-mcp: Focus Studio's MCP server for Claude Code, Codex and
// other MCP clients, which start it as a stdio server. It ships in
// Focus Studio.app/Contents/MacOS. It answers `initialize` and `tools/list`
// from the tool catalog without contacting or launching the app, and hands
// each `tools/call` to an AppForwarding. This build has no channel to the
// app yet, so calls answer that Focus Studio could not be reached.

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
let host = MCPServerHost(
    identity: .resolve(),
    catalog: .v1,
    forwarder: UnreachableAppForwarder(),
    workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
    settings: HelperSettings(environment: ProcessInfo.processInfo.environment)
)
let status = await host.runStdio(standardStreams)
standardStreams.restore()
exit(status)
