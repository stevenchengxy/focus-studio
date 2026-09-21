import FocusStudioCore
import Foundation

/// Routes the assistant's prompts through a Codex app-server thread instead of
/// an API-key model: the system prompt becomes the thread's developer
/// instructions and the user content is one turn. The dedicated
/// `CodexDirectorService` connects on demand with the Settings › Codex
/// executable and account, so no extra sign-in is needed.
struct CodexTextCompletion: TextCompletionProviding {
    let service: CodexDirectorService

    func complete(system: String, user: String, json: Bool) async throws -> String {
        try await service.completeText(developerInstructions: system, prompt: user, json: json)
    }
}
