import FocusStudioAutomation
import SwiftUI

/// One connection and submission path for the unified conversation. Recording
/// requests are reviewed and executed by AIAssistantSession's bounded task loop.
@MainActor
final class AssistantDemoController: ObservableObject {
    @Published private(set) var isConnecting = false
    @Published var error: String?
    private unowned let model: StudioModel

    init(model: StudioModel) { self.model = model }

    var isConnected: Bool {
        model.aiGateway.assistantBrain == .codex && model.codexAssistant.connectionState == .ready
    }

    func connect() async -> Bool {
        guard !model.assistantSession.isRunning, !isConnecting else { return false }
        error = nil
        isConnecting = true
        defer { isConnecting = false }
        model.codexAssistant.savePreferences(model.codexDirector.preferences)
        model.aiGateway.assistantBrain = .codex
        await model.codexAssistant.connect()
        guard model.codexAssistant.connectionState == .ready else {
            error = model.codexAssistant.lastErrorMessage ?? L10n.tr("Open connection settings to sign in to Codex, then try again.")
            return false
        }
        return true
    }

    func send(_ text: String, attachments: [URL]) async -> Bool {
        guard !model.assistantSession.isRunning, !isConnecting else { return false }
        error = nil
        if !isConnected { guard await connect() else { return false } }
        guard !model.assistantSession.isRunning else { return false }
        model.assistantSession.send(text, attachments: attachments)
        return true
    }

    func openVideo(_ projectID: UUID) {
        do {
            try model.openProject(id: projectID)
            model.presentMainWindow?()
        } catch { self.error = L10n.tr(error.localizedDescription) }
    }
}
