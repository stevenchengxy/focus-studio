import Foundation

/// Only non-secret connection preferences belong in the app's preferences.
/// Authentication is delegated to Codex and, for a separate account, macOS Keychain.
struct CodexConnectionPreferences: Codable, Equatable, Sendable {
    enum AccountScope: String, Codable, CaseIterable, Sendable {
        case focusStudio
        case existingCodex

        var title: String {
            switch self {
            case .focusStudio: return "Sign in for Focus Studio"
            case .existingCodex: return "Use existing Codex sign-in"
            }
        }
    }

    var executablePath = ""
    var modelID = ""
    var accountScope: AccountScope = .focusStudio

    static let defaultsKey = "codexDirector.connection.v1"

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data)
        else { return .init() }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    var normalized: Self {
        var value = self
        value.executablePath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        value.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }
}

struct CodexAvailableModel: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let defaultEffort: String?
    let isDefault: Bool
    let supportsImages: Bool

    init?(json: CodexJSONValue) {
        guard let value = json.objectValue,
              let id = value["model"]?.stringValue ?? value["id"]?.stringValue,
              value["hidden"]?.boolValue != true else { return nil }
        self.id = id
        title = value["displayName"]?.stringValue ?? id
        defaultEffort = value["defaultReasoningEffort"]?.stringValue
        isDefault = value["isDefault"]?.boolValue == true
        supportsImages = value["inputModalities"]?.arrayValue.map {
            $0.contains(.string("image"))
        } ?? true
    }
}

enum CodexExecutableDiscovery {
    static func resolve(
        explicitPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        let explicitPath = explicitPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitPath.isEmpty {
            let expanded = (explicitPath as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/"), isExecutableFile(expanded, fileManager: fileManager) else {
                throw CodexDirectorServiceError.invalidExecutable(explicitPath)
            }
            return URL(fileURLWithPath: expanded)
        }

        let home = fileManager.homeDirectoryForCurrentUser
        var candidates: [String] = []
        if let path = environment["CODEX_EXECUTABLE"], !path.isEmpty { candidates.append(path) }
        candidates += (environment["PATH"] ?? "").split(separator: ":")
            .map { String($0) + "/codex" }
        candidates += [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".npm-global/bin/codex").path
        ]
        guard let found = candidates.first(where: { isExecutableFile($0, fileManager: fileManager) }) else {
            throw CodexDirectorServiceError.executableNotFound
        }
        return URL(fileURLWithPath: found)
    }

    private static func isExecutableFile(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && fileManager.isExecutableFile(atPath: path)
    }
}
