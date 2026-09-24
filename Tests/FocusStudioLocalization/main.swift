import FocusStudioAutomation
import Foundation

@main
struct LanguagePreferenceTests {
    @MainActor
    static func main() throws {
        let suiteName = "app.focusstudio.localization-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated language preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppLocalization(defaults: defaults)
        precondition(model.language == .system, "A new user should follow the system language")
        model.language = .english
        precondition(model.locale.identifier == "en")
        precondition(defaults.string(forKey: AppLocalization.preferenceKey) == "en")
        precondition(AppLocalization(defaults: defaults).language == .english, "English choice must survive relaunch")

        model.language = .simplifiedChinese
        precondition(model.locale.identifier == "zh-Hans")
        precondition(AppLocalization(defaults: defaults).language == .simplifiedChinese, "Chinese choice must survive relaunch")
        model.language = .system
        precondition(AppLocalization(defaults: defaults).language == .system)

        defaults.set("unsupported-language", forKey: AppLocalization.preferenceKey)
        precondition(AppLocalization(defaults: defaults).language == .system, "Invalid saved values must fall back safely")

        precondition(L10n.tr("New recording", language: .english) == "New recording")
        precondition(L10n.tr("New recording", language: .simplifiedChinese) == "新建录制")
        precondition(L10n.tr("Focus Studio", language: .simplifiedChinese) == "Focus Studio", "Brand name must not change")
        let unknown = "An unknown message with a user-defined filename.mov"
        precondition(L10n.tr(unknown, language: .simplifiedChinese) == unknown, "Unknown content must remain verbatim")
        let label = String(format: L10n.tr("Zoom %lld start", language: .simplifiedChinese), 7)
        precondition(label == "缩放 7 开始", "Numbered timeline controls must keep their identity in translation")

        print("Language preferences: PASS (isolated persistence, fallback, English/Chinese lookup, numbered format; no user preferences changed)")
    }
}
