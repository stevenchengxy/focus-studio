import AppKit
import SwiftUI

// Small animated pieces of the assistant panel. Each one collapses to a
// static or crossfade-only form when the user asks macOS to reduce motion.

// MARK: - Typing indicator

/// Activity stays local to the response in progress; Reduce Motion is static.
struct TypingIndicatorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(StudioTheme.purple)
                    .frame(width: 6, height: 6)
                    .opacity(reduceMotion ? 0.65 : (animating ? 0.9 : 0.3))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.65).repeatForever(autoreverses: true).delay(Double(index) * 0.16),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 12)
        .onAppear { animating = !reduceMotion }
        .onChange(of: reduceMotion) { _, reduced in animating = !reduced }
        .accessibilityLabel(Text("Thinking…"))
    }
}

// MARK: - Level meter

/// Five bars driven by a 0…1 level; the middle bars react most.
struct AudioLevelMeterView: View {
    var level: Double
    var tint: Color = StudioTheme.red
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let weights: [Double] = [0.55, 0.8, 1, 0.8, 0.55]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.weights.count, id: \.self) { index in
                let drive = min(1, max(0, level * Self.weights[index] * 1.4))
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(drive > 0.08 ? tint : StudioTheme.secondaryText.opacity(0.35))
                    .frame(width: 3, height: 3 + 10 * drive)
            }
        }
        .frame(height: 14)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

// MARK: - Microphone button

/// Recording uses a steady red stop control; the nearby meter shows real audio.
struct MicrophoneButton: View {
    var isRecording: Bool
    var isPreparing: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isPreparing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isRecording ? Color.white : StudioTheme.text)
                }
            }
            .frame(width: 20, height: 30)
            .padding(.horizontal, 5)
            .background(isRecording ? StudioTheme.red : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Staggered appearance

/// Fades and lifts a view in after a delay proportional to its index, so a
/// row of chips appears once. Immediate presentation under Reduce Motion.
struct StaggeredAppearModifier: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 6)
            .onAppear {
                withAnimation(reduceMotion ? nil : StudioMotion.fade.delay(Double(index) * 0.04)) {
                    visible = true
                }
            }
    }
}

extension View {
    func staggeredAppearance(index: Int) -> some View {
        modifier(StaggeredAppearModifier(index: index))
    }
}

// MARK: - Confirmation arrival

/// A single border fade draws attention when approval becomes available.
/// The card then stays still while the user reads its scope and price.
struct ConfirmationHighlightModifier: ViewModifier {
    var color: Color
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(color.opacity(reduceMotion || settled ? 0.45 : 0.85), lineWidth: 1)
            )
            .onAppear {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.8)) { settled = true }
            }
    }
}

extension View {
    func confirmationHighlight(_ color: Color, cornerRadius: CGFloat) -> some View {
        modifier(ConfirmationHighlightModifier(color: color, cornerRadius: cornerRadius))
    }
}

// MARK: - Direct interaction feedback

struct AssistantControlButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 20, minHeight: 30)
            .padding(.horizontal, 5)
            .background(configuration.isPressed ? StudioTheme.controlPressed
                        : (hovering && isEnabled ? StudioTheme.controlFill : Color.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : StudioMotion.hover, value: hovering)
            .animation(reduceMotion ? nil : StudioMotion.press, value: configuration.isPressed)
    }
}

struct AssistantActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(hovering && isEnabled ? StudioTheme.controlFill : StudioTheme.panelRaised,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(hovering && isEnabled ? StudioTheme.purple.opacity(0.35) : StudioTheme.line, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 11))
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : StudioMotion.hover, value: hovering)
            .animation(reduceMotion ? nil : StudioMotion.press, value: configuration.isPressed)
    }
}

struct AssistantSendButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? nil : StudioMotion.press, value: configuration.isPressed)
    }
}

// MARK: - Icon toggle

/// Toggle drawn like ``IconButtonStyle``; filled with the accent while on.
struct IconToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(configuration.isOn ? Color.white : StudioTheme.text)
                .frame(width: 32, height: 30)
                .background(configuration.isOn ? StudioTheme.purple : StudioTheme.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(configuration.isOn ? StudioTheme.purple.opacity(0.7) : StudioTheme.line, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : StudioMotion.hover, value: configuration.isOn)
    }
}

// MARK: - Permission notice

/// Compact inline explanation when voice input cannot start, with a shortcut
/// to the matching System Settings privacy pane.
struct SpeechPermissionNotice: View {
    let issue: SpeechInputController.Issue
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(StudioTheme.warning)
            Text(issue.message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let url = issue.settingsURL {
                Button("Open Settings") { NSWorkspace.shared.open(url) }
                    .buttonStyle(PrimaryButtonStyle())
                    .controlSize(.small)
                    .accessibilityIdentifier("assistant.openPrivacySettings")
            }
            Button(action: dismiss) {
                Label("Dismiss", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioTheme.secondaryText)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(StudioTheme.yellow.opacity(0.08))
    }
}
