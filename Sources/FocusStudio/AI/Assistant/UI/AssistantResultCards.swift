import AppKit
import FocusStudioAutomation
import SwiftUI

/// Tool receipts remain in history verbatim. Their transport payload is useful
/// for inspection, but the conversation shows a short human-readable result.
struct AssistantToolResultCard: View {
    let message: AIAssistantMessage

    private var summary: String {
        if let display = message.displayText?.trimmingCharacters(in: .whitespacesAndNewlines), !display.isEmpty {
            return display
        }
        let raw = message.text.lowercased()
        if raw.contains("cancelled —") || raw.contains("\"declined\"") {
            return L10n.tr("This action was cancelled.")
        }
        if raw.contains("\"interrupted\"") || raw.contains("already attempted") {
            return L10n.tr("This action was already attempted. Review its result before continuing.")
        }
        switch message.toolName {
        case "prepare_demo_page": return L10n.tr("The demo webpage is ready to review.")
        case "get_status": return L10n.tr("Recording readiness checked.")
        case "list_recording_sources": return L10n.tr("Available windows and screens checked.")
        case "start_recording": return L10n.tr("Recording status updated.")
        case "capture_recording_frame": return L10n.tr("The current recording view is ready.")
        case "perform_recording_action": return L10n.tr("Pointer action result received.")
        case "stop_recording", "wait_for_recording": return L10n.tr("Recording progress updated.")
        case "get_project", "list_projects", "open_project", "close_editor": return L10n.tr("Project information updated.")
        case "generate_image", "generate_video", "capture_frame": return L10n.tr("Media result received.")
        case "list_media_assets": return L10n.tr("Media library checked.")
        case "import_media_asset": return L10n.tr("Media asset added to the library.")
        case "insert_media_asset": return L10n.tr("Media asset added to the video track.")
        case "redo_clip_edit": return L10n.tr("Last video edit redone.")
        case "export_project", "export_demo", "assemble_video": return L10n.tr("Video output updated.")
        case "analyze_demo_pacing": return L10n.tr("Candidate waits identified. Check page changes before cutting.")
        case "create_demo_cut": return L10n.tr("An editable copy is ready. The original recording is preserved.")
        case "add_zoom", "update_zoom", "remove_zoom", "set_zoom_style", "update_settings", "set_chapters",
             "set_background_image", "set_background_music", "set_sound_effects":
            return L10n.tr("The edit has been applied.")
        default: return L10n.tr("Result received. Details are available below.")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: AIAssistantPanel.toolIcon(message.toolName))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StudioTheme.purple)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                Text(AIAssistantPanel.toolTitle(message.toolName ?? ""))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTheme.secondaryText)
                Text(verbatim: summary)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                // Repeated observation thumbnails belong with their receipt;
                // generated media stays visible and playable in the transcript.
                if message.toolName != "capture_recording_frame", !message.attachments.isEmpty {
                    AssistantAttachmentGrid(urls: message.attachments)
                }
                AssistantMessageDetails(
                    text: message.text,
                    attachments: message.toolName == "capture_recording_frame" ? message.attachments : [],
                    identifier: message.id.uuidString
                )
                if message.toolName != "capture_recording_frame", !message.attachments.isEmpty {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(message.attachments)
                    } label: {
                        Label("Reveal", systemImage: "magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioTheme.purple)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(StudioTheme.panelRaised)
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(StudioTheme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }
}

struct AssistantErrorCard: View {
    let message: AIAssistantMessage
    let openSettings: (() -> Void)?

    private var presentation: (title: LocalizedStringKey, guidance: LocalizedStringKey, settings: Bool) {
        let raw = message.text.lowercased()
        if raw.contains("did not answer") || raw.contains("timed out") {
            return ("Codex did not respond in time", "Retry the reply. A request that failed before capture does not start recording.", false)
        }
        if raw.contains("does not accept screenshots") || raw.contains("image support") {
            return ("Choose a model with image support", "Open settings and select a model that can inspect the recording window.", true)
        }
        if ["sign in", "sign-in", "authentication", "codex is unavailable", "could not connect", "登录"].contains(where: raw.contains) {
            return ("Connect Codex to continue", "Finish connecting in settings, then retry your request.", true)
        }
        if ["permission", "accessibility", "权限"].contains(where: raw.contains) {
            return ("Check recording permissions", "Review the permission instructions in Details, then try again.", false)
        }
        if ["observation", "obscured", "covered", "window changed", "window is no longer", "遮挡"].contains(where: raw.contains) {
            return ("Refresh the recording view", "Bring the target window forward, then retry this step.", false)
        }
        switch message.toolName {
        case "start_recording": return ("Recording could not start", "Check the selected window and the details below before trying again.", false)
        case "stop_recording", "wait_for_recording": return ("Check the recording result", "Review the details before starting another recording.", false)
        case "export_project", "export_demo", "assemble_video": return ("Video output needs attention", "Check the output location in Details, then retry the export.", false)
        default: return ("This step needs attention", "Review the details, then retry or adjust your request.", false)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(StudioTheme.yellow)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                Text(presentation.title)
                    .font(.system(size: 13, weight: .semibold))
                if let display = message.displayText, !display.isEmpty {
                    Text(verbatim: display)
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(presentation.guidance)
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if presentation.settings, let openSettings {
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                AssistantMessageDetails(text: message.text, attachments: message.attachments, identifier: message.id.uuidString)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(StudioTheme.yellow.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }
}

/// Each message owns its disclosure state, so reading one receipt never opens
/// every historical response. Collapsing it does not alter persisted messages.
private struct AssistantMessageDetails: View {
    let text: String
    let attachments: [URL]
    let identifier: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Details", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !attachments.isEmpty { AssistantAttachmentGrid(urls: attachments) }
                Text(verbatim: text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy details", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioTheme.purple)
            }
            .padding(.top, 6)
        }
        .font(.system(size: 11))
        .foregroundStyle(StudioTheme.secondaryText)
        .accessibilityIdentifier("assistant.details.\(identifier)")
    }
}
