import Foundation

/// Navigation only. Match the complete URL without decoding or normalizing
/// aliases, so external links can never supply credentials, files or commands.
enum AppSettingsDeepLink: String, Equatable, Sendable {
    case community = "focusstudio://settings/community"
    case codex = "focusstudio://settings/codex"

    init?(url: URL) {
        guard url.baseURL == nil else { return nil }
        self.init(rawValue: url.absoluteString)
    }
}
