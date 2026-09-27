import Darwin
import FocusStudioAutomation
import Foundation
import Security

/// Which program is asking Focus Studio to run tools: the process that
/// started focus-studio-mcp (Claude Code, Codex, …), found from the helper's
/// process id on the control socket (`LOCAL_PEERPID`) and its parent.
///
/// An approval is remembered by ``key``: the code-signing identity (Team ID
/// and signing identifier) when the program is validly signed with a Team
/// ID, which stays the same across updates, otherwise its executable path.
/// An ad-hoc signature is never used, since anyone can make one with any
/// identifier. The MCP client's self-reported name is shown next to it but
/// never trusted.
///
/// A generic host (``isGenericHost``: a shell, a script interpreter such as
/// node or python, a launcher such as env or sudo) runs many programs, so
/// its own identity says little about which program is asking: every nvm
/// node shares one Developer ID, and every Terminal session is /bin/zsh.
/// For such a host the key also names the script it runs (``scriptPath``,
/// from its arguments), and without a script (an interactive shell,
/// `zsh -c …`, `python -m …`) nothing is remembered: an approval lasts only
/// for that connection (``isRememberable``).
///
/// Process ids can be reused, so this identifies the program as it was when
/// the helper connected; it guards against mistakes and surprises, not
/// against other software of the same user (see the issue's security notes).
struct AutomationClientIdentity: Codable, Hashable, Sendable {
    var key: String
    /// A short name for people: the app bundle's name, or the executable's;
    /// for a generic host running a script, the script's (or its package's)
    /// name with the host's, e.g. "mcp_e2e.py (Python)".
    var programName: String
    var programPath: String
    var teamIdentifier: String?
    var signingIdentifier: String?
    /// The signing certificate's name, e.g. "Developer ID Application: Anthropic PBC (Q6L2SF6YDW)".
    var signerName: String?
    /// For a generic host: the script it runs (a real path to a regular
    /// file), which the approval is tied to.
    var scriptPath: String?

    init(programPath: String, teamIdentifier: String? = nil, signingIdentifier: String? = nil, signerName: String? = nil, scriptPath: String? = nil) {
        self.programPath = programPath
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.signerName = signerName
        self.scriptPath = scriptPath
        let host = Self.programName(forPath: programPath)
        var key: String
        if let teamIdentifier, let signingIdentifier {
            key = "codesign:\(teamIdentifier)/\(signingIdentifier)"
        } else {
            key = "path:\(programPath)"
        }
        if let scriptPath {
            key += "|script:\(scriptPath)"
            programName = "\(Self.scriptName(forPath: scriptPath)) (\(host))"
        } else {
            programName = host
        }
        self.key = key
    }

    /// The organisation in a Developer ID signer name ("Anthropic PBC"), or the name itself.
    var signerDisplayName: String? {
        guard var name = signerName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        for prefix in ["Developer ID Application: ", "Apple Development: ", "Apple Distribution: "] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        return name
    }

    /// The executable's own name ("zsh", "node", "Python").
    var hostName: String { Self.programName(forPath: programPath) }

    /// A shell, a script interpreter or a launcher: it runs other programs,
    /// so approving it as such would approve all of them.
    var isGenericHost: Bool {
        Self.isGenericHost(programPath: programPath, signingIdentifier: signingIdentifier)
    }

    /// Whether an approval may be remembered: a specific program, or a
    /// generic host running a script that is not itself a generic launcher
    /// (npx, yarn…). Otherwise it holds for one connection only.
    var isRememberable: Bool {
        guard isGenericHost else { return true }
        guard let scriptPath else { return false }
        return !Self.isGenericName(Self.scriptName(forPath: scriptPath))
            && !Self.isGenericName(((scriptPath as NSString).lastPathComponent as NSString).deletingPathExtension)
    }

    /// The program that started the helper whose process id is `helperPID`,
    /// or nil when there is none to trust: the helper has already exited, or
    /// it was orphaned (its parent is launchd).
    static func resolve(helperPID: pid_t) -> AutomationClientIdentity? {
        guard let parent = parentProcessID(of: helperPID), parent > 1 else { return nil }
        return program(processID: parent)
    }

    /// The program running as `processID`, with its signing identity when
    /// it is validly signed with a Team ID, and for a generic host the
    /// script it runs.
    static func program(processID: pid_t) -> AutomationClientIdentity? {
        guard let path = executablePath(of: processID) else { return nil }
        let signing = signingIdentity(of: processID)
        let script = isGenericHost(programPath: path, signingIdentifier: signing?.identifier) ? scriptPath(of: processID) : nil
        return AutomationClientIdentity(programPath: path, teamIdentifier: signing?.team, signingIdentifier: signing?.identifier, signerName: signing?.signer, scriptPath: script)
    }

    static func parentProcessID(of processID: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func executablePath(of processID: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return path.hasPrefix("/") ? path : nil
    }

    /// Team ID, signing identifier and signer of a running process whose
    /// signature is valid now; nil when it is unsigned, ad-hoc signed,
    /// has no Team ID or fails validation.
    static func signingIdentity(of processID: pid_t) -> (team: String, identifier: String, signer: String?)? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: processID] as CFDictionary, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
              let identifier = info[kSecCodeInfoIdentifier as String] as? String, !identifier.isEmpty else { return nil }
        var signer: String?
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first {
            signer = SecCertificateCopySubjectSummary(leaf) as String?
        }
        return (team, identifier, signer)
    }

    /// "ChatGPT" for …/ChatGPT.app/Contents/Resources/codex, "Python" for
    /// Xcode.app/…/Python.app/Contents/MacOS/Python (the innermost app),
    /// "claude" for …/claude/versions/2.1.3 (a versioned install), else the
    /// file name.
    static func programName(forPath path: String) -> String {
        let components = (path as NSString).pathComponents
        if let app = components.last(where: { $0.hasSuffix(".app") && $0.count > 4 }) {
            return String(app.dropLast(4))
        }
        let name = components.last ?? path
        if let first = name.first, first.isNumber, components.count >= 3, components[components.count - 2] == "versions" {
            return components[components.count - 3]
        }
        return name
    }

    /// The package a script belongs to ("@anthropic-ai/claude-code" for
    /// …/node_modules/@anthropic-ai/claude-code/cli.js), else its file name.
    static func scriptName(forPath path: String) -> String {
        let components = (path as NSString).pathComponents
        if let modules = components.lastIndex(of: "node_modules"), modules + 1 < components.count - 1 {
            let package = components[modules + 1]
            if package.hasPrefix("@"), modules + 2 < components.count - 1 {
                return "\(package)/\(components[modules + 2])"
            }
            return package
        }
        return components.last ?? path
    }

    // MARK: - Generic hosts

    /// Shells, interpreters and launchers, by executable name without
    /// version digits ("python3.13" is "python").
    static let genericHostNames: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh",
        "env", "login", "sudo", "su", "doas", "nohup", "xargs", "script", "tmux", "screen", "time", "timeout", "nice", "caffeinate", "arch",
        "node", "nodejs", "bun", "deno", "python", "pythonw", "ruby", "perl", "php", "lua", "osascript",
        "npm", "npx", "pnpm", "pnpx", "yarn", "corepack", "tsx", "ts-node", "uv", "uvx", "pipx",
    ]

    static func isGenericHost(programPath: String, signingIdentifier: String?) -> Bool {
        if isGenericName((programPath as NSString).lastPathComponent) { return true }
        // "com.apple.zsh", "com.apple.python3": a copy under another name.
        if let identifier = signingIdentifier, let last = identifier.split(separator: ".").last, isGenericName(String(last)) { return true }
        return false
    }

    /// "Python3.13" → "python", "perl5.34" → "perl", "@scope/npm" → "npm".
    static func isGenericName(_ name: String) -> Bool {
        var normalized = ((name as NSString).lastPathComponent).lowercased()
        while let last = normalized.last, last.isNumber || last == "." { normalized.removeLast() }
        if normalized.hasPrefix("python") { normalized = "python" }
        return genericHostNames.contains(normalized)
    }

    /// The script a generic host runs: the first argument that is not an
    /// option, resolved against the process's current folder, as a real path
    /// to a regular file; nil for inline code, a module, standard input or an
    /// interactive session.
    static func scriptPath(of processID: pid_t) -> String? {
        guard let arguments = arguments(of: processID), let argument = scriptArgument(in: arguments) else { return nil }
        let candidate: String
        if argument.hasPrefix("/") {
            candidate = argument
        } else {
            guard let directory = currentDirectory(of: processID) else { return nil }
            candidate = (directory as NSString).appendingPathComponent(argument)
        }
        guard let resolved = realpath(candidate, nil) else { return nil }
        defer { free(resolved) }
        let path = String(cString: resolved)
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return path
    }

    /// Options that run code given on the command line or read the program
    /// from standard input (shells' -c and -s, node's -e and -p, python's -c
    /// and -m, perl's -E…), or start an interactive session: no script.
    private static let inlineOptionLetters: Set<Character> = ["c", "e", "E", "m", "p", "s", "i"]
    private static let inlineLongOptions: Set<String> = ["--eval", "--print", "--command", "--interactive"]
    /// Options whose value is the next argument (node -r, python -W/-X, ruby -I…).
    private static let valueOptionLetters: Set<Character> = ["r", "I", "W", "X", "C", "o", "O"]
    private static let valueLongOptions: Set<String> = ["--require", "--import", "--loader", "--experimental-loader", "--conditions", "--title", "--env-file", "--inspect-port"]

    /// The script argument in a generic host's arguments (`arguments[0]` is
    /// the program), or nil when it runs none.
    static func scriptArgument(in arguments: [String]) -> String? {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return index + 1 < arguments.count ? arguments[index + 1] : nil }
            if argument == "-" { return nil }
            if argument.hasPrefix("--") {
                let name = String(argument.split(separator: "=", maxSplits: 1).first ?? Substring(argument))
                if inlineLongOptions.contains(name) { return nil }
                index += valueLongOptions.contains(name) && !argument.contains("=") ? 2 : 1
                continue
            }
            if argument.hasPrefix("-") || argument.hasPrefix("+") {
                let letters = argument.dropFirst()
                if letters.contains(where: { inlineOptionLetters.contains($0) }) { return nil }
                index += letters.count == 1 && letters.last.map { valueOptionLetters.contains($0) } == true ? 2 : 1
                continue
            }
            return argument
        }
        return nil
    }

    /// A process's arguments (`KERN_PROCARGS2`: argc, the executable path,
    /// padding, then the arguments), for processes of this user.
    static func arguments(of processID: pid_t) -> [String]? {
        var maximum: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var names: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&names, 2, &maximum, &size, nil, 0) == 0, maximum > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(maximum))
        var length = buffer.count
        names = [CTL_KERN, KERN_PROCARGS2, processID]
        guard sysctl(&names, 3, &buffer, &length, nil, 0) == 0, length > MemoryLayout<Int32>.size else { return nil }
        let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < length, buffer[index] != 0 { index += 1 }
        while index < length, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(count), index < length {
            let start = index
            while index < length, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == Int(count) ? arguments : nil
    }

    /// A process's current folder.
    static func currentDirectory(of processID: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[0..<end], as: UTF8.self)
        }
        return path.hasPrefix("/") ? path : nil
    }
}
