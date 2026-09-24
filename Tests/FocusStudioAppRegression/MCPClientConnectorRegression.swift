import FocusStudioAutomation
import Foundation

/// Settings › AI tools › Connect against fake `claude` and `codex`
/// executables and fake login shells in a temporary folder; the real CLIs,
/// shells and their configuration are never run or touched. Covers finding
/// the CLIs (login shell PATH, a broken install skipped, a shell that hangs),
/// registering with exact argument arrays (a path with a space stays one
/// argument), no-op when already connected, update by remove + add when
/// another copy is registered, CLI failures and timeouts with their error
/// text, a missing CLI, the copyable commands, the environment the CLIs get,
/// parsing the real CLIs' output, and the helper path warnings.
@MainActor
enum MCPClientConnectorRegression {
    static func run() async throws {
        let fixture = try FakeCLIFixture()
        defer { fixture.cleanup() }
        try await locating(fixture)
        try await connecting(fixture)
        try await failures(fixture)
        try parsing()
        try commandsAndWarnings(fixture)
        print("MCPClientConnectorRegression: PASS (login-shell PATH lookup with noisy startup output, broken install skipped, hanging shell timed out, missing CLIs, exact add/remove/get argument arrays, already connected is a no-op, another copy updated by remove + add, CLI errors and timeouts reported, Focus Studio test variables kept from CLIs, claude/codex output parsing, copyable shell-quoted commands, translocated/disk image/missing helper warnings)")
    }

    private static func locating(_ fixture: FakeCLIFixture) async throws {
        let found = await fixture.search().locate()
        try expect(found.executables[.claudeCode] == fixture.claude, "claude comes from the login shell's command -v: \(found.executables)")
        try expect(found.executables[.codex] == fixture.codex, "The broken codex first on PATH is skipped for the working one: \(found.executables)")
        try expect(found.shellPath.contains("/fake/node/bin") && found.shellPath.contains("/usr/bin"), "The login shell's PATH is read past its startup noise: \(found.shellPath)")
        let shellArguments = fixture.log("shell")
        try expect(shellArguments.first == ["-l", "-c", MCPCLISearch.loginShellScript], "The login shell gets -l -c and the fixed script: \(shellArguments)")

        let started = Date()
        let hanging = await fixture.search(shell: fixture.hangingShell, shellTimeout: 0.5).locate()
        try expect(Date().timeIntervalSince(started) < 4, "A hanging login shell is given up on: \(Date().timeIntervalSince(started)) s")
        try expect(hanging.executables[.claudeCode] == nil && hanging.executables[.codex] == fixture.codex && hanging.shellPath.isEmpty, "Without the shell, only PATH finds a CLI: \(hanging.executables)")

        let none = await fixture.search(shell: nil, path: "/usr/bin:/bin").locate()
        try expect(none.executables.isEmpty, "Nothing found: \(none.executables)")
        let missing = MCPClientConnector(helperPath: fixture.helperPath, search: fixture.search(shell: nil, path: "/usr/bin:/bin"))
        await missing.refresh()
        try expect(missing.status(for: .claudeCode).state == .cliNotFound && missing.status(for: .codex).state == .cliNotFound, "Missing CLIs are reported")
        await missing.connect(.codex)
        try expect(missing.status(for: .codex).state == .cliNotFound, "Connect without a CLI reports it missing")
    }

    private static func connecting(_ fixture: FakeCLIFixture) async throws {
        fixture.reset()
        let connector = MCPClientConnector(helperPath: fixture.helperPath, search: fixture.search(), commandTimeout: 5)
        await connector.refresh()
        try expect(connector.status(for: .claudeCode) == MCPClientStatus(cliPath: fixture.claude, state: .notConnected), "claude: not connected: \(connector.status(for: .claudeCode))")
        try expect(connector.status(for: .codex) == MCPClientStatus(cliPath: fixture.codex, state: .notConnected), "codex: not connected: \(connector.status(for: .codex))")

        await connector.connect(.claudeCode)
        let claude = connector.status(for: .claudeCode)
        try expect(claude.state == .connected(MCPClientRegistration(command: fixture.helperPath, arguments: [], scope: "user")), "claude connected: \(claude)")
        try expect(claude.note == "Connected. Start a new Claude Code session to use Focus Studio.", "with a note")
        let claudeCalls = fixture.log("claude").filter { $0.first != "--version" }
        try expect(claudeCalls == [["mcp", "get", "focus-studio"], ["mcp", "get", "focus-studio"], ["mcp", "add", "--scope", "user", "focus-studio", "--", fixture.helperPath], ["mcp", "get", "focus-studio"]],
                   "claude's argument arrays, the path with its space as one argument: \(claudeCalls)")
        try expect(!fixture.leaked, "Focus Studio's own test variables never reach the CLI")
        let path = (try? String(contentsOfFile: fixture.directory + "/claude.path", encoding: .utf8)) ?? ""
        try expect(path.hasPrefix(fixture.claudeDirectory + ":") && path.contains("/fake/node/bin"), "The CLI's PATH starts with its own folder and includes the login shell's: \(path)")

        fixture.clearLog("claude")
        await connector.connect(.claudeCode)
        try expect(fixture.log("claude") == [["mcp", "get", "focus-studio"]] && connector.status(for: .claudeCode).state == .connected(MCPClientRegistration(command: fixture.helperPath, arguments: [], scope: "user")),
                   "Already connected: nothing changes: \(fixture.log("claude"))")

        // Another copy registered: shown, then replaced by remove + add.
        let old = "/Volumes/Old/Focus Studio.app/Contents/MacOS/focus-studio-mcp"
        try old.write(toFile: fixture.directory + "/claude.state", atomically: true, encoding: .utf8)
        await connector.refresh()
        try expect(connector.status(for: .claudeCode).state == .connectedElsewhere(MCPClientRegistration(command: old, arguments: [], scope: "user")), "Another copy: \(connector.status(for: .claudeCode))")
        fixture.clearLog("claude")
        await connector.connect(.claudeCode)
        try expect(fixture.log("claude") == [["mcp", "get", "focus-studio"], ["mcp", "remove", "--scope", "user", "focus-studio"], ["mcp", "add", "--scope", "user", "focus-studio", "--", fixture.helperPath], ["mcp", "get", "focus-studio"]],
                   "Update removes then adds: \(fixture.log("claude"))")
        try expect(connector.status(for: .claudeCode).state == .connected(MCPClientRegistration(command: fixture.helperPath, arguments: [], scope: "user")), "and ends connected")

        fixture.clearLog("codex")
        await connector.connect(.codex)
        try expect(connector.status(for: .codex).state == .connected(MCPClientRegistration(command: fixture.helperPath, arguments: [], scope: nil)), "codex connected: \(connector.status(for: .codex))")
        try expect(fixture.log("codex") == [["mcp", "get", "focus-studio", "--json"], ["mcp", "add", "focus-studio", "--", fixture.helperPath], ["mcp", "get", "focus-studio", "--json"]],
                   "codex's argument arrays: \(fixture.log("codex"))")
        try old.write(toFile: fixture.directory + "/codex.state", atomically: true, encoding: .utf8)
        fixture.clearLog("codex")
        await connector.connect(.codex)
        try expect(fixture.log("codex") == [["mcp", "get", "focus-studio", "--json"], ["mcp", "remove", "focus-studio"], ["mcp", "add", "focus-studio", "--", fixture.helperPath], ["mcp", "get", "focus-studio", "--json"]],
                   "codex update: \(fixture.log("codex"))")
    }

    private static func failures(_ fixture: FakeCLIFixture) async throws {
        fixture.reset()
        let connector = MCPClientConnector(helperPath: fixture.helperPath, search: fixture.search(), commandTimeout: 0.5)
        await connector.refresh()
        fixture.touch("claude.fail")
        await connector.connect(.claudeCode)
        try expect(connector.status(for: .claudeCode).state == .failed("claude: simulated failure"), "A failing CLI shows its stderr: \(connector.status(for: .claudeCode))")
        fixture.remove("claude.fail")
        fixture.touch("claude.addfail")
        await connector.connect(.claudeCode)
        try expect(connector.status(for: .claudeCode).state == .failed("claude: could not write the configuration"), "A failed add shows its stderr: \(connector.status(for: .claudeCode))")
        fixture.remove("claude.addfail")
        fixture.touch("codex.hang")
        let started = Date()
        await connector.connect(.codex)
        try expect(connector.status(for: .codex).state == .failed("The command did not finish in time.") && Date().timeIntervalSince(started) < 4,
                   "A CLI that hangs is stopped: \(connector.status(for: .codex)), \(Date().timeIntervalSince(started)) s")
        fixture.remove("codex.hang")

        let run = await CLIRunner.run("/nonexistent/claude", arguments: [], environment: [:], currentDirectory: nil, timeout: 1)
        try expect(run.launchError != nil && !run.succeeded && run.failureText.contains("/nonexistent/claude"), "A missing executable: \(run.failureText)")
        let echo = await CLIRunner.run("/bin/sh", arguments: ["-c", "printf out; printf err >&2; exit 3", "ignored"], environment: [:], currentDirectory: "/", timeout: 5)
        try expect(echo.exitStatus == 3 && echo.standardOutput == "out" && echo.standardError == "err" && echo.failureText == "err", "Both outputs and the exit status: \(echo)")
    }

    private static func parsing() throws {
        // What claude 2.1 and codex-cli 0.155 print (captured in a scratch HOME).
        let claude = """
        focus-studio:
          Scope: User config (available in all your projects)
          Status: ✘ Failed to connect
          Type: stdio
          Command: /Applications/Focus Studio.app/Contents/MacOS/focus-studio-mcp
          Args:
          Environment:

        To remove this server, run: claude mcp remove focus-studio -s user
        """
        try expect(MCPClientConnector.parseRegistration(.claudeCode, output: claude) == MCPClientRegistration(command: "/Applications/Focus Studio.app/Contents/MacOS/focus-studio-mcp", arguments: [], scope: "user"), "claude mcp get")
        let local = claude.replacingOccurrences(of: "User config (available in all your projects)", with: "Local config (private to you in this project)")
            .replacingOccurrences(of: "  Args:\n", with: "  Args: --verbose\n")
        try expect(MCPClientConnector.parseRegistration(.claudeCode, output: local) == MCPClientRegistration(command: "/Applications/Focus Studio.app/Contents/MacOS/focus-studio-mcp", arguments: ["--verbose"], scope: "local"), "claude local scope with arguments")
        let codex = """
        {
          "name": "focus-studio",
          "enabled": true,
          "disabled_reason": null,
          "transport": {
            "type": "stdio",
            "command": "/Applications/Focus Studio.app/Contents/MacOS/focus-studio-mcp",
            "args": [],
            "env": null,
            "env_vars": [],
            "cwd": null
          },
          "enabled_tools": null
        }
        """
        try expect(MCPClientConnector.parseRegistration(.codex, output: codex) == MCPClientRegistration(command: "/Applications/Focus Studio.app/Contents/MacOS/focus-studio-mcp", arguments: [], scope: nil), "codex mcp get --json")
        let codexText = "focus-studio\n  enabled: true\n  transport: stdio\n  command: /opt/fs/focus-studio-mcp\n  args: -\n  cwd: -\n"
        try expect(MCPClientConnector.parseRegistration(.codex, output: codexText) == MCPClientRegistration(command: "/opt/fs/focus-studio-mcp", arguments: [], scope: nil), "codex text output")
        try expect(MCPClientConnector.parseRegistration(.claudeCode, output: "nothing useful") == nil, "Unreadable output")
        let parsed = MCPCLISearch.parseLoginShellOutput("Welcome!\n__FOCUS_STUDIO_CLAUDE__\n/opt/claude\n__FOCUS_STUDIO_CODEX__\ncodex: not found\n__FOCUS_STUDIO_PATH__\n/usr/bin:/bin\n/fish/style\nrelative\n")
        try expect(parsed.0 == [.claudeCode: "/opt/claude"] && parsed.1 == ["/usr/bin", "/bin", "/fish/style"], "Login shell output: \(parsed)")
        try expect(MCPClientConnector.sameFile("/tmp/x", "/private/tmp/x"), "Symlinked folders compare equal")
    }

    private static func commandsAndWarnings(_ fixture: FakeCLIFixture) throws {
        let path = "/Applications/Focus Studio.app/Contents/MacOS/focus-studio-mcp"
        try expect(MCPClientKind.claudeCode.commandLine(helperPath: path) == "claude mcp add --scope user focus-studio -- '/Applications/Focus Studio.app/Contents/MacOS/focus-studio-mcp'", "claude command: \(MCPClientKind.claudeCode.commandLine(helperPath: path))")
        try expect(MCPClientKind.codex.commandLine(helperPath: path) == "codex mcp add focus-studio -- '/Applications/Focus Studio.app/Contents/MacOS/focus-studio-mcp'", "codex command")
        try expect(ShellQuoting.quote("it's") == #"'it'\''s'"# && ShellQuoting.quote("/plain/path") == "/plain/path" && ShellQuoting.quote("") == "''", "Shell quoting")
        let search = fixture.search(shell: nil)
        try expect(MCPClientConnector(helperPath: "/private/var/folders/x/AppTranslocation/ABC/d/Focus Studio.app/Contents/MacOS/focus-studio-mcp", search: search).helperWarning?.contains("temporary location") == true, "Translocated")
        try expect(MCPClientConnector(helperPath: "/Volumes/Focus Studio/Focus Studio.app/Contents/MacOS/focus-studio-mcp", search: search).helperWarning?.contains("disk image") == true, "Disk image")
        try expect(MCPClientConnector(helperPath: "/nonexistent/focus-studio-mcp", search: search).helperWarning?.contains("not found") == true, "Missing helper")
        try expect(MCPClientConnector(helperPath: fixture.helperPath, search: search).helperWarning == nil, "An installed helper")
        try expect(MCPClientConnector.bundledHelperPath().hasSuffix("/focus-studio-mcp"), "The helper next to the app's executable: \(MCPClientConnector.bundledHelperPath())")
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw ServerFailure(message) }
    }
}

/// Fake CLIs and login shells in a temporary folder. Each fake logs its
/// arguments (one line per run, arguments separated by U+001F) and keeps
/// its registration in a state file; marker files make it fail or hang.
final class FakeCLIFixture {
    let directory: String
    let claudeDirectory: String
    let codexDirectory: String
    let brokenDirectory: String
    let claude: String
    let codex: String
    let shell: String
    let hangingShell: String
    /// A helper path with a space, which must stay one argument.
    let helperPath: String

    init() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("fs-cli-\(UUID().uuidString.prefix(8))", isDirectory: true).path
        directory = root
        claudeDirectory = root + "/claude-bin"
        codexDirectory = root + "/codex-bin"
        brokenDirectory = root + "/broken-bin"
        claude = claudeDirectory + "/claude"
        codex = codexDirectory + "/codex"
        shell = root + "/login-shell"
        hangingShell = root + "/hanging-shell"
        helperPath = root + "/Focus Studio.app/Contents/MacOS/focus-studio-mcp"
        for folder in [claudeDirectory, codexDirectory, brokenDirectory, (helperPath as NSString).deletingLastPathComponent] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        let log = #"{ for a in "$@"; do printf '%s\037' "$a"; done; printf '\n'; } >> "$state_dir/"#
        try write(claude, """
        #!/bin/sh
        state_dir='\(root)'
        \(log)claude.log"
        [ -n "$FOCUS_STUDIO_TEST_LEAK" ] && echo leaked >> "$state_dir/leak.log"
        printf '%s' "$PATH" > "$state_dir/claude.path"
        [ -f "$state_dir/claude.hang" ] && sleep 30
        state="$state_dir/claude.state"
        case "$1" in
        --version) echo "2.1.0 (Claude Code)"; exit 0;;
        mcp) ;;
        *) echo "unexpected: $*" >&2; exit 64;;
        esac
        [ -f "$state_dir/claude.fail" ] && { echo "claude: simulated failure" >&2; exit 3; }
        case "$2" in
        get)
          [ "$3" = "focus-studio" ] && [ $# -eq 3 ] || { echo "bad get: $*" >&2; exit 64; }
          if [ -f "$state" ]; then
            printf 'focus-studio:\\n  Scope: User config (available in all your projects)\\n  Status: ✓ Connected\\n  Type: stdio\\n  Command: %s\\n  Args:\\n  Environment:\\n\\nTo remove this server, run: claude mcp remove focus-studio -s user\\n' "$(cat "$state")"
            exit 0
          fi
          echo 'No MCP server named "focus-studio". Run `claude mcp add` to add one.'
          exit 1;;
        add)
          [ "$3" = "--scope" ] && [ "$4" = "user" ] && [ "$5" = "focus-studio" ] && [ "$6" = "--" ] && [ $# -eq 7 ] || { echo "bad add: $*" >&2; exit 64; }
          [ -f "$state_dir/claude.addfail" ] && { echo "claude: could not write the configuration" >&2; exit 1; }
          [ -f "$state" ] && { echo "MCP server focus-studio already exists in user config" >&2; exit 1; }
          printf '%s' "$7" > "$state"
          echo "Added stdio MCP server focus-studio with command: $7  to user config"
          exit 0;;
        remove)
          [ "$3" = "--scope" ] && [ "$4" = "user" ] && [ "$5" = "focus-studio" ] && [ $# -eq 5 ] || { echo "bad remove: $*" >&2; exit 64; }
          [ -f "$state" ] || { echo 'No MCP server named "focus-studio" in user scope' >&2; exit 1; }
          rm "$state"
          echo "Removed MCP server focus-studio from user config"
          exit 0;;
        esac
        echo "unexpected: $*" >&2
        exit 64
        """)
        try write(codex, """
        #!/bin/sh
        state_dir='\(root)'
        \(log)codex.log"
        [ -f "$state_dir/codex.hang" ] && [ "$1" != "--version" ] && sleep 30
        state="$state_dir/codex.state"
        case "$1" in
        --version) echo "codex-cli 0.155.0"; exit 0;;
        mcp) ;;
        *) exit 64;;
        esac
        case "$2" in
        get)
          [ "$3" = "focus-studio" ] && [ "$4" = "--json" ] && [ $# -eq 4 ] || exit 64
          if [ -f "$state" ]; then
            printf '{\\n  "name": "focus-studio",\\n  "enabled": true,\\n  "transport": {\\n    "type": "stdio",\\n    "command": "%s",\\n    "args": [],\\n    "env": null\\n  }\\n}\\n' "$(cat "$state")"
            exit 0
          fi
          echo "Error: No MCP server named 'focus-studio' found." >&2
          exit 1;;
        add)
          [ "$3" = "focus-studio" ] && [ "$4" = "--" ] && [ $# -eq 5 ] || exit 64
          printf '%s' "$5" > "$state"
          echo "Added global MCP server 'focus-studio'."
          exit 0;;
        remove)
          [ "$3" = "focus-studio" ] && [ $# -eq 3 ] || exit 64
          rm -f "$state"
          echo "Removed global MCP server 'focus-studio'."
          exit 0;;
        esac
        exit 64
        """)
        // A Node shim whose package is gone, like a stale npm install.
        try write(brokenDirectory + "/codex", """
        #!/bin/sh
        echo "Error: spawn .../vendor/codex ENOENT" >&2
        exit 1
        """)
        try write(shell, """
        #!/bin/sh
        state_dir='\(root)'
        \(log)shell.log"
        echo "Last login: Mon Sep 21 on ttys000"
        echo "__FOCUS_STUDIO_CLAUDE__"
        echo "\(claude)"
        echo "__FOCUS_STUDIO_CODEX__"
        echo "__FOCUS_STUDIO_PATH__"
        echo "/usr/bin:/bin:/fake/node/bin"
        """)
        try write(hangingShell, """
        #!/bin/sh
        sleep 30
        """)
        try write(helperPath, "#!/bin/sh\nexit 0\n")
    }

    /// PATH has the broken codex first, then the working one; claude is only
    /// found through the fake login shell.
    func search(shellTimeout: TimeInterval = 5, path: String? = nil) -> MCPCLISearch {
        search(shell: shell, shellTimeout: shellTimeout, path: path)
    }

    /// The same with another login shell, or none.
    func search(shell: String?, shellTimeout: TimeInterval = 5, path: String? = nil) -> MCPCLISearch {
        let environment = [
            "PATH": path ?? "\(brokenDirectory):\(codexDirectory):/usr/bin:/bin",
            "HOME": directory,
            "FOCUS_STUDIO_TEST_LEAK": "1",
        ]
        var search = MCPCLISearch(environment: environment, homeDirectory: directory, loginShell: shell)
        search.loginShellTimeout = shellTimeout
        search.searchesStandardLocations = false
        return search
    }

    func log(_ name: String) -> [[String]] {
        let text = (try? String(contentsOfFile: directory + "/\(name).log", encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            line.split(separator: "\u{1F}", omittingEmptySubsequences: false).dropLast().map(String.init)
        }
    }

    var leaked: Bool { FileManager.default.fileExists(atPath: directory + "/leak.log") }

    func clearLog(_ name: String) { remove("\(name).log") }

    func touch(_ name: String) { FileManager.default.createFile(atPath: directory + "/" + name, contents: Data()) }

    func remove(_ name: String) { try? FileManager.default.removeItem(atPath: directory + "/" + name) }

    /// Forgets registrations, logs and markers.
    func reset() {
        for name in ["claude.state", "codex.state", "claude.log", "codex.log", "shell.log", "claude.fail", "claude.addfail", "codex.hang", "leak.log"] { remove(name) }
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: directory) }

    private func write(_ path: String, _ script: String) throws {
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
    }
}
