import Foundation
import ScreenCaptureKit

/// A user stopping the macOS sharing indicator finishes the recorded take.
/// This applies to ScreenCaptureKit streams regardless of how their source
/// was selected; genuine system or writer failures remain failures.
public enum SystemCaptureStopPolicy {
    public static func isUserStop(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userStopped.rawValue
    }
}
