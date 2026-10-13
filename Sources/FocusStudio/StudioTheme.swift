import AppKit
import SwiftUI

enum StudioTheme {
    // Dynamic system colors resolve in each window's effective appearance.
    // Editing surfaces use flat fills: no per-frame material/blur work.
    static let window = adaptive("window", light: 0xEFF1F9, dark: 0x0E0F11)
    static let panel = adaptive("panel", light: 0xF8F9FD, dark: 0x151619)
    static let panelRaised = adaptive("panelRaised", light: 0xFFFFFF, dark: 0x1B1C20)
    static let line = adaptive("line", light: 0x637091, lightAlpha: 0.18, dark: 0xFFFFFF, darkAlpha: 0.085)
    static let text = adaptive("text", light: 0x242634, dark: 0xF0F0F2)
    static let secondaryText = adaptive("secondaryText", light: 0x666D80, dark: 0x9B9CA3)
    static let purple = adaptive("purple", light: 0x6750D3, dark: 0x8061FF)
    static let purpleSoft = adaptive("purpleSoft", light: 0xE4DFFC, dark: 0x6145DB)
    // Track labels stay white in both appearances. Keep their fills separate
    // from the pale surfaces used by chat bubbles and cards.
    static let purpleTrackEnd = adaptive("purpleTrackEnd", light: 0x5940BA, dark: 0x6145DB)
    static let cyanTrack = adaptive("cyanTrack", light: 0x25798E, dark: 0x218CA6)
    static let tealTrack = adaptive("tealTrack", light: 0x287E79, dark: 0x398E87)
    static let mutedTrack = adaptive("mutedTrack", light: 0x737687, dark: 0x54555D)
    static let controlFill = adaptive("controlFill", light: 0xFFFFFF, lightAlpha: 0.78, dark: 0xFFFFFF, darkAlpha: 0.065)
    static let controlPressed = adaptive("controlPressed", light: 0xDFE1F0, dark: 0xFFFFFF, darkAlpha: 0.12)
    static let inset = adaptive("inset", light: 0x616D91, lightAlpha: 0.055, dark: 0xFFFFFF, darkAlpha: 0.035)
    static let playhead = adaptive("playhead", light: 0x34304D, dark: 0xFFFFFF)
    static let guide = adaptive("guide", light: 0x7162B9, dark: 0x55D3ED)
    static let rim = adaptive("rim", light: 0xFFFFFF, lightAlpha: 0.95, dark: 0xFFFFFF, darkAlpha: 0.06)
    static let panelShadow = adaptive("panelShadow", light: 0x4D567C, lightAlpha: 0.055, dark: 0x000000, darkAlpha: 0)
    static let canvasTop = adaptive("canvasTop", light: 0xECEAF8, dark: 0x101014)
    static let canvasBottom = adaptive("canvasBottom", light: 0xEAF2F7, dark: 0x0E0F11)
    static let warning = adaptive("warning", light: 0x896017, dark: 0xFAC233)
    static let yellow = Color(red: 0.98, green: 0.76, blue: 0.20)
    static let red = Color(red: 0.96, green: 0.27, blue: 0.32)

    static var canvas: LinearGradient {
        LinearGradient(colors: [canvasTop, window, canvasBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private static func adaptive(_ name: String, light: UInt32, lightAlpha: Double = 1,
                                 dark: UInt32, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("FocusStudio.\(name)")) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
                           green: Double((rgb >> 8) & 255) / 255,
                           blue: Double(rgb & 255) / 255,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
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
            .shadow(color: StudioTheme.panelShadow, radius: 9, y: 4)
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
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.5))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(tint.opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.32))
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
            .background(configuration.isPressed ? StudioTheme.controlPressed : StudioTheme.controlFill)
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
