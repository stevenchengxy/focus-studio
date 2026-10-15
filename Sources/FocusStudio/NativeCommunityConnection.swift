import Foundation
import Security

/// The 1.14.6 credential was a raw UTF-8 token in this separate item. It is
/// consumed only by the upgrade path; new connections use the versioned vault.
protocol CommunityLegacyCredentialVault: Sendable {
    func read() async throws -> String?
    func delete(ifMatching token: String) async throws
}

actor CommunityLegacyKeychainVault: CommunityLegacyCredentialVault {
    static let service = "studio.focus.community"
    static let account = "community-device-token"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }
    func read() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw storageFailure()
        }
        // Invalid UTF-8 becomes an invalid token and can be cleared by the
        // migration validator; it must not strand the settings page forever.
        return String(decoding: data, as: UTF8.self)
    }
    func delete(ifMatching token: String) throws {
        guard try read() == token else { return }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw storageFailure() }
    }
    private func storageFailure() -> CommunityConnectionError {
        .init(code: "credential_storage", message: "The community connection could not be saved in Keychain. Please try again.")
    }
}

/// Preserve the installed-app gate shipped in 1.14.6. Development builds and
/// copies in Downloads cannot approve community publishing for a real account.
enum NativeCommunityInstallationPolicy {
    static var isRunningInstalledApp: Bool {
        let bundle = Bundle.main
        let url = bundle.bundleURL.standardizedFileURL
        let canonical = URL(fileURLWithPath: "/Applications/Focus Studio.app", isDirectory: true)
        return url.path == canonical.path && url.resolvingSymlinksInPath().path == canonical.path
            && bundle.bundleIdentifier == "com.local.focusstudio"
            && bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "FocusStudio"
    }
}
