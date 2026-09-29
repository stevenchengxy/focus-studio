import FocusStudioAutomation
import FocusStudioCore
import Foundation

/// Routes the assistant's prompts through a Codex app-server thread instead of
/// an API-key model: the system prompt becomes the thread's developer
/// instructions and the user content is one turn. The dedicated
/// `CodexDirectorService` connects on demand with the Settings › Codex
/// executable and account, so no extra sign-in is needed.
struct CodexTextCompletion: AssistantConversationResetting, AssistantInteractiveCompletionProviding, AssistantConversationPreparing {
    let service: CodexDirectorService

    func resetConversation() async {
        await service.resetAssistantConversation()
    }

    func prepareConversation(system: String) async throws {
        try await service.prepareAssistantConversation(developerInstructions: system)
    }

    func complete(system: String, user: String, json: Bool) async throws -> String {
        try await service.completeText(developerInstructions: system, prompt: user, json: json, conversationSnapshot: true)
    }

    func complete(system: String, user: String, json: Bool, imageURLs: [URL]) async throws -> String {
        try await service.completeText(developerInstructions: system, prompt: user, json: json, imageURLs: imageURLs, conversationSnapshot: true)
    }

    func completeInteraction(system: String, user: String, json: Bool, imageURLs: [URL]) async throws -> String {
        try await service.completeText(developerInstructions: system, prompt: user, json: json, imageURLs: imageURLs, conversationSnapshot: true, interactive: true)
    }
}
