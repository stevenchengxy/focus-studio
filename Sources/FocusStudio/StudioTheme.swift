import SwiftUI

enum StudioTheme {
    static let window = Color(red: 0.055, green: 0.059, blue: 0.067)
    static let panel = Color(red: 0.082, green: 0.086, blue: 0.098)
    static let panelRaised = Color(red: 0.105, green: 0.110, blue: 0.125)
    static let line = Color.white.opacity(0.085)
    static let text = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.52)
    static let purple = Color(red: 0.50, green: 0.38, blue: 1.0)
    static let purpleSoft = Color(red: 0.38, green: 0.27, blue: 0.86)
    static let yellow = Color(red: 0.98, green: 0.76, blue: 0.20)
    static let red = Color(red: 0.96, green: 0.27, blue: 0.32)
}

struct StudioPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(StudioTheme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(StudioTheme.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    func studioPanel() -> some View { modifier(StudioPanelModifier()) }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = StudioTheme.purple

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(tint.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(StudioTheme.text)
            .frame(width: 32, height: 30)
            .background(configuration.isPressed ? Color.white.opacity(0.10) : Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(StudioTheme.line, lineWidth: 1)
            )
    }
}
