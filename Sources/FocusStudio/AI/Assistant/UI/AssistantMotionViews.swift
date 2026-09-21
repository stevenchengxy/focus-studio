import AppKit
import SwiftUI

// Small animated pieces of the assistant panel. Each one collapses to a
// static or crossfade-only form when the user asks macOS to reduce motion.

// MARK: - Typing indicator

/// Three dots that bob while the model works (fade only under Reduce Motion).
struct TypingIndicatorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(StudioTheme.purple)
                    .frame(width: 6, height: 6)
                    .offset(y: animating && !reduceMotion ? -3 : 0)
                    .opacity(animating ? 1 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.42).repeatForever(autoreverses: true).delay(Double(index) * 0.14),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 12)
        .onAppear { animating = true }
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
                    .fill(drive > 0.08 ? tint : Color.white.opacity(0.2))
                    .frame(width: 3, height: 3 + 10 * drive)
            }
        }
        .frame(height: 14)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

// MARK: - Microphone button

/// Mic toggle: a red fill with a rippling ring while recording, a spinner
/// while permissions and the audio engine start.
struct MicrophoneButton: View {
    var isRecording: Bool
    var isPreparing: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    RecordingRipple()
                }
                if isPreparing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isRecording ? Color.white : StudioTheme.text)
                }
            }
            .frame(width: 32, height: 30)
            .background(isRecording ? StudioTheme.red : Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isRecording ? StudioTheme.red.opacity(0.7) : StudioTheme.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RecordingRipple: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(StudioTheme.red, lineWidth: 2)
            .frame(width: 22, height: 22)
            .scaleEffect(expanded && !reduceMotion ? 1.6 : 1)
            .opacity(expanded ? 0 : 0.75)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 1.1).repeatForever(autoreverses: false),
                value: expanded
            )
            .onAppear {
                guard !reduceMotion else { return }
                expanded = true
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Staggered appearance

/// Fades and lifts a view in after a delay proportional to its index, so a
/// row of chips appears one after another. Opacity only under Reduce Motion.
struct StaggeredAppearModifier: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 6)
            .onAppear {
                withAnimation(reduceMotion ? StudioMotion.fade : StudioMotion.selection.delay(Double(index) * 0.06)) {
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

// MARK: - Pulsing border

/// A slow breathing stroke used to draw attention to the confirmation card.
struct PulsingBorderModifier: ViewModifier {
    var color: Color
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(color.opacity(reduceMotion ? 0.6 : (bright ? 0.95 : 0.4)), lineWidth: 1)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}

extension View {
    func pulsingBorder(_ color: Color, cornerRadius: CGFloat) -> some View {
        modifier(PulsingBorderModifier(color: color, cornerRadius: cornerRadius))
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
                .background(configuration.isOn ? StudioTheme.purple : Color.white.opacity(0.055))
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
                .foregroundStyle(StudioTheme.yellow)
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
