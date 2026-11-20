import FocusStudioCapture
import Foundation
import ScreenCaptureKit

/// The sharing indicator can end a stream independently of the app's source
/// picker. Keep that normal finish distinct from actual capture failures.
@MainActor
enum CaptureStopPolicyRegression {
    static func run() {
        precondition(SystemCaptureStopPolicy.isUserStop(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue)))
        precondition(!SystemCaptureStopPolicy.isUserStop(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.systemStoppedStream.rawValue)),
                     "A system failure must not be mistaken for a user-requested Finish")
        precondition(!SystemCaptureStopPolicy.isUserStop(NSError(domain: "Unrelated", code: SCStreamError.Code.userStopped.rawValue)))
        precondition(RecordingControlPanelCoordinator.showsControls(destination: .recorder, isSelectingArea: false))
        precondition(RecordingControlPanelCoordinator.showsControls(destination: .countdown, isSelectingArea: false))
        precondition(RecordingControlPanelCoordinator.showsControls(destination: .recording, isSelectingArea: false),
                     "The recording controls remain available for listed window, display and area sources")
        precondition(!RecordingControlPanelCoordinator.showsControls(destination: .recorder, isSelectingArea: true),
                     "Drawing an area temporarily hides the recording controls")
        print("CaptureStopPolicyRegression: PASS (normal user stop, genuine failures, listed-source recording controls)")
    }
}
