import Foundation

/// A text model the editor can ask for chapter titles and captions.
///
/// The app injects its configured provider; Core only builds prompts and
/// parses replies, so everything here stays testable without a network.
public protocol TextCompletionProviding: Sendable {
    /// - Parameters:
    ///   - system: Role and output rules.
    ///   - user: The request body.
    ///   - json: When true the caller expects a JSON object and the provider
    ///     may enable its structured-output mode.
    func complete(system: String, user: String, json: Bool) async throws -> String
}
