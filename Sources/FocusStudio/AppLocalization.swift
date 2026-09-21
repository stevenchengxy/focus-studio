import AppKit
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var localeIdentifier: String {
        switch self {
        case .system:
            return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
        case .english, .simplifiedChinese:
            return rawValue
        }
    }
}

@MainActor
final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()
    static let preferenceKey = "focusStudio.language"
    private let defaults: UserDefaults

    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Self.preferenceKey) }
    }

    var locale: Locale { Locale(identifier: language.localeIdentifier) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .system
    }
}

/// Native panels and dynamically assembled app-owned labels need the same
/// language as SwiftUI. User content must not be passed through this helper.
enum L10n {
    static var locale: Locale { Locale(identifier: language.localeIdentifier) }

    private static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "focusStudio.language") ?? "") ?? .system
    }

    static func tr(_ key: String) -> String {
        tr(key, language: language)
    }

    static func tr(_ key: String, language: AppLanguage) -> String {
        localizedBundle(for: language)?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: locale, arguments: arguments)
    }

    private static func localizedBundle(for language: AppLanguage) -> Bundle? {
        let identifier = language.localeIdentifier
        if let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        // `swift run` has no .app bundle. Keep native diagnostics and controls
        // localizable when launched from the source checkout as well.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: sourceRoot.appendingPathComponent("Resources/\(identifier).lproj"))
    }
}

/// Observe locale independently of recording/editor state. Never key a view's
/// identity to the language: changing a label must not stop an active recording.
struct AppLocalizedView<Content: View>: View {
    @ObservedObject private var localization = AppLocalization.shared
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content.environment(\.locale, localization.locale)
    }
}

struct AppLanguagePicker: View {
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        Picker("Language", selection: $localization.language) {
            Text("System language").tag(AppLanguage.system)
            Text(verbatim: "English").tag(AppLanguage.english)
            Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
        }
        .accessibilityIdentifier("settings.language")
    }
}

struct AppLanguageMenu: View {
    var body: some View {
        Menu {
            AppLanguagePicker()
        } label: {
            Label("Language", systemImage: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 12, weight: .medium))
        .accessibilityIdentifier("language.menu")
        .help("Change app language")
    }
}

struct AppLanguageCommands: Commands {
    @ObservedObject private var localization = AppLocalization.shared

    var body: some Commands {
        CommandMenu(L10n.tr("Language")) {
            Picker(L10n.tr("Language"), selection: $localization.language) {
                Text(L10n.tr("System language")).tag(AppLanguage.system)
                Text(verbatim: "English").tag(AppLanguage.english)
                Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
            }
        }
    }
}
