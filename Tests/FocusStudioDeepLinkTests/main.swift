import Foundation

@main
struct FocusStudioDeepLinkTests {
    static func main() throws {
        let accepted: [(String, AppSettingsDeepLink)] = [
            ("focusstudio://settings/community", .community),
            ("focusstudio://settings/codex", .codex),
        ]
        for (value, expected) in accepted {
            precondition(AppSettingsDeepLink(url: URL(string: value)!) == expected)
        }

        let rejected = [
            "focusstudio://settings", "focusstudio://settings/", "focusstudio://settings/account",
            "focusstudio://settings/aiTools", "focusstudio://community", "focusstudio://codex",
            "https://settings/community", "file:///settings/community", "javascript:settings/community",
            "FOCUSSTUDIO://settings/community", "focusstudio://SETTINGS/community",
            "focusstudio://settings/Community", "focusstudio://settings/Codex",
            "focusstudio://settings/community/", "focusstudio://settings/codex/",
            "focusstudio://settings/community/activate", "focusstudio://settings/codex/run",
            "focusstudio://settings/other/../community", "focusstudio://settings/./community",
            "focusstudio://settings/%63ommunity", "focusstudio://settings/%63odex",
            "focusstudio://settings/community%2F", "focusstudio://settings/community%00",
            "focusstudio://settings/community?", "focusstudio://settings/community#",
            "focusstudio://settings/community?token=fs_secret", "focusstudio://settings/community?ownerId=other",
            "focusstudio://settings/community?path=/tmp/project", "focusstudio://settings/codex?command=run",
            "focusstudio://settings/codex?prompt=record", "focusstudio://settings/codex#token=fs_secret",
            "focusstudio://user@settings/community", "focusstudio://user:password@settings/community",
            "focusstudio://settings:443/community", "focusstudio://settings.invalid/community",
            "focusstudio://settings/community%3Ftoken=fs_secret", "focusstudio:settings/community",
        ]
        for value in rejected {
            guard let url = URL(string: value) else { continue }
            precondition(AppSettingsDeepLink(url: url) == nil, "Unexpected route: \(value)")
        }
        let relative = URL(string: "community", relativeTo: URL(string: "focusstudio://settings/")!)!
        precondition(relative.absoluteString == AppSettingsDeepLink.community.rawValue)
        precondition(AppSettingsDeepLink(url: relative) == nil, "Relative URL aliases are not external routes")

        // Confirm Launch Services registers only the intended scheme without
        // turning the settings navigation into a file/document association.
        let info = URL(fileURLWithPath: CommandLine.arguments[1])
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as! [String: Any]
        let types = plist["CFBundleURLTypes"] as! [[String: Any]]
        precondition(types.count == 1)
        precondition(types[0]["CFBundleURLSchemes"] as? [String] == ["focusstudio"])
        precondition(types[0]["CFBundleURLName"] as? String == "com.local.focusstudio.settings")
        precondition(types[0]["CFBundleTypeRole"] as? String == "Viewer")
        precondition(plist["CFBundleDocumentTypes"] == nil)
        print("FocusStudioDeepLinkTests: PASS (two navigation routes, \(rejected.count + 1) denied URL forms, exact scheme registration)")
    }
}
