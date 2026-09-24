import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    /// The app language for a resolved identifier such as `uiLanguage`
    /// ("zh-Hans", "en", "zh-Hant-TW"). The app ships English and Simplified
    /// Chinese, so anything that is not Chinese reads as English.
    public init(localeIdentifier identifier: String) {
        self = identifier.lowercased().hasPrefix("zh") ? .simplifiedChinese : .english
    }

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

    /// Formats in `language` whatever the app's UI language is, for text whose
    /// reader is known (a tool result for an external client is English).
    public static func format(_ key: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
        format(key, language: language, arguments: arguments)
    }

    public static func format(_ key: String, language: AppLanguage, arguments: [CVarArg]) -> String {
        String(format: tr(key, language: language), locale: Locale(identifier: language.localeIdentifier), arguments: arguments)
    }

    /// `format` for arguments already collected, in the app's UI language.
    static func format(_ key: String, arguments: [CVarArg]) -> String {
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

/// An app failure worded as a localization key and its arguments. The app
/// shows it in the UI language (``errorDescription``); a tool returns it in
/// the language of the call (``message(in:)``), so an external client reads
/// English whatever language the app shows.
public struct AILocalizedFailure: LocalizedError, Equatable, Sendable {
    public enum Argument: Equatable, Sendable {
        /// User content such as a title or a path, never translated.
        case verbatim(String)
        /// An app text that is itself a key, e.g. a store error's description.
        case text(String)
        case count(Int)
    }

    public var key: String
    public var arguments: [Argument]

    public init(_ key: String, _ arguments: Argument...) {
        self.key = key
        self.arguments = arguments
    }

    public func message(in language: AppLanguage) -> String {
        let values = arguments.map { value(of: $0) { L10n.tr($0, language: language) } }
        return values.isEmpty ? L10n.tr(key, language: language) : L10n.format(key, language: language, arguments: values)
    }

    public var errorDescription: String? {
        let values = arguments.map { value(of: $0) { L10n.tr($0) } }
        return values.isEmpty ? L10n.tr(key) : L10n.format(key, arguments: values)
    }

    private func value(of argument: Argument, translate: (String) -> String) -> CVarArg {
        switch argument {
        case let .verbatim(text): return text
        case let .text(key): return translate(key)
        case let .count(number): return number
        }
    }
}
