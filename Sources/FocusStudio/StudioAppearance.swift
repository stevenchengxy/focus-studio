import AppKit
import FocusStudioAutomation
import SwiftUI

enum StudioAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System Default"
        case .light: return "Light appearance"
        case .dark: return "Dark appearance"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class StudioAppearanceStore: ObservableObject {
    static let shared = StudioAppearanceStore()
    static let preferenceKey = "focusStudio.appearance"
    private let defaults: UserDefaults

    @Published var selection: StudioAppearance {
        didSet {
            defaults.set(selection.rawValue, forKey: Self.preferenceKey)
            applyToApplication()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = StudioAppearance(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .system
    }

    func applyToApplication() {
        // Also covers AppKit sheets, title bars and non-activating recording
        // panels. nil restores live tracking of the macOS appearance.
        NSApp?.appearance = selection.appKitAppearance
    }
}

private struct StudioAppearanceModifier: ViewModifier {
    @ObservedObject private var store = StudioAppearanceStore.shared

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(store.selection.colorScheme)
            .tint(StudioTheme.purple)
            .onAppear { store.applyToApplication() }
    }
}

extension View {
    /// Keep view identity stable: an appearance change must not replace the
    /// editor's player, active recording or undo history.
    func studioAppearance() -> some View { modifier(StudioAppearanceModifier()) }
}

struct StudioAppearancePicker: View {
    @ObservedObject private var store = StudioAppearanceStore.shared
    var body: some View {
        Picker("Appearance", selection: $store.selection) {
            ForEach(StudioAppearance.allCases) { choice in
                Label(LocalizedStringKey(choice.title), systemImage: choice.symbol).tag(choice)
            }
        }
        .accessibilityIdentifier("settings.appearance")
    }
}

struct StudioAppearanceMenu: View {
    @ObservedObject private var store = StudioAppearanceStore.shared
    var body: some View {
        Menu {
            StudioAppearancePicker()
        } label: {
            Image(systemName: store.selection.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 29, height: 29)
                .background(StudioTheme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioTheme.line))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(StudioTheme.text)
        .accessibilityLabel("Appearance")
        .accessibilityValue(LocalizedStringKey(store.selection.title))
        .accessibilityIdentifier("appearance.menu")
        .help("Change appearance")
    }
}

struct StudioAppearanceCommands: Commands {
    var body: some Commands {
        CommandMenu(L10n.tr("Appearance")) { StudioAppearancePicker() }
    }
}
