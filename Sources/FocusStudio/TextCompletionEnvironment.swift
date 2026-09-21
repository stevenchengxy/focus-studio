import FocusStudioCore
import SwiftUI

/// The text model available to editor tools that ask AI for help.
///
/// Nil means no model is configured: AI buttons stay disabled with a hint.
/// The app injects its configured provider with
/// `.environment(\.textCompletion, provider)` above the editor.
private struct TextCompletionKey: EnvironmentKey {
    static let defaultValue: (any TextCompletionProviding)? = nil
}

extension EnvironmentValues {
    var textCompletion: (any TextCompletionProviding)? {
        get { self[TextCompletionKey.self] }
        set { self[TextCompletionKey.self] = newValue }
    }
}
