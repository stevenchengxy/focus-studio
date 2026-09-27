import AppKit
import FocusStudioAutomation
import SwiftUI

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
