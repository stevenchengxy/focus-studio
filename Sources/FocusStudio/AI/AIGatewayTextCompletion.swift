import FocusStudioCore
import Foundation
import SwiftUI

/// Bridges the configured default text model to the editor's AI features.
///
/// The client is resolved on every call so changing the default model in
/// Settings takes effect immediately, and a missing configuration surfaces as
/// a normal error instead of a stale client.
struct AIGatewayTextCompletion: TextCompletionProviding {
    let store: AIGatewayStore

    func complete(system: String, user: String, json: Bool) async throws -> String {
        let client = try await MainActor.run { try store.resolvedClient() }
        let response = try await client.complete(
            AICompletionRequest(system: system, user: user, jsonMode: json, maxTokens: 4_000, temperature: nil)
        )
        return response.text
    }
}

/// Publishes the gateway's default model into the SwiftUI environment as a
/// `TextCompletionProviding`, or nil while nothing is configured so AI
/// buttons stay disabled with their hint.
struct TextCompletionInjector<Content: View>: View {
    @ObservedObject var store: AIGatewayStore
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.textCompletion, store.defaultTextModel == nil ? nil : AIGatewayTextCompletion(store: store))
    }
}
