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

/// Shared motion vocabulary. Every duration here is short enough to feel
/// immediate and is disabled when the user asks macOS to reduce motion.
enum StudioMotion {
    static let page: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .offset(y: 12)).combined(with: .scale(scale: 0.992)),
        removal: .opacity
    )
    static let pageAnimation: Animation = .easeOut(duration: 0.28)
    static let panel: AnyTransition = .opacity.combined(with: .move(edge: .trailing))
    static let panelAnimation: Animation = .easeOut(duration: 0.22)
    static let selection: Animation = .spring(response: 0.32, dampingFraction: 0.82)
    static let hover: Animation = .easeOut(duration: 0.16)
    static let press: Animation = .easeOut(duration: 0.12)
    static let fade: Animation = .easeOut(duration: 0.2)

    /// A transition that respects the system Reduce Motion setting.
    static func page(reduceMotion: Bool) -> AnyTransition { reduceMotion ? .opacity : page }
    static func panel(reduceMotion: Bool) -> AnyTransition { reduceMotion ? .opacity : panel }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = StudioTheme.purple
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(tint.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(StudioMotion.press, value: configuration.isPressed)
    }
}

struct IconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(StudioTheme.text)
            .frame(width: 32, height: 30)
            .background(configuration.isPressed ? Color.white.opacity(0.12) : Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(StudioTheme.line, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(StudioMotion.press, value: configuration.isPressed)
    }
}

/// Lifts a card slightly on hover. Used by library and source cards.
struct HoverLiftModifier: ViewModifier {
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scale = 1.012
    var shadowOpacity = 0.28

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovering && !reduceMotion ? scale : 1)
            .shadow(color: .black.opacity(isHovering ? shadowOpacity : 0), radius: 14, y: 8)
            .onHover { isHovering = $0 }
            .animation(StudioMotion.hover, value: isHovering)
    }
}

extension View {
    func hoverLift(scale: Double = 1.012, shadowOpacity: Double = 0.28) -> some View {
        modifier(HoverLiftModifier(scale: scale, shadowOpacity: shadowOpacity))
    }
}
