import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    public var localeIdentifier: String {
        switch self {
        case .system:
            return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
        case .english, .simplifiedChinese:
            return rawValue
        }
    }
}

/// Native panels and dynamically assembled app-owned labels need the same
/// language as SwiftUI. User content must not be passed through this helper.
public enum L10n {
    public static var locale: Locale { Locale(identifier: language.localeIdentifier) }

    private static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "focusStudio.language") ?? "") ?? .system
    }

    public static func tr(_ key: String) -> String {
        tr(key, language: language)
    }

    public static func tr(_ key: String, language: AppLanguage) -> String {
        localizedBundle(for: language)?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: locale, arguments: arguments)
    }

    private static func localizedBundle(for language: AppLanguage) -> Bundle? {
        let identifier = language.localeIdentifier
        // Bundle.main is the app bundle even from this library, which carries
        // no resources of its own.
        if let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        // `swift run` has no .app bundle. Keep native diagnostics and controls
        // localizable when launched from the source checkout as well
        // (Sources/FocusStudioAutomation/Localization.swift → repository root).
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: sourceRoot.appendingPathComponent("Resources/\(identifier).lproj"))
    }
}
