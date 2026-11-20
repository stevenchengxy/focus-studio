import FocusStudioAutomation
import FocusStudioCapture
import FocusStudioCore
import Foundation
import ScreenCaptureKit

/// Script the system dialog's answers, never show one or enumerate/capture the
/// screen. A cancelled picker must not revive a previously approved source.
@MainActor
enum SystemCapturePickerRegression {
    static func run() async throws {
        precondition(SystemCaptureStopPolicy.isUserStop(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue)))
        precondition(!SystemCaptureStopPolicy.isUserStop(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.systemStoppedStream.rawValue)),
                     "A system failure must not be mistaken for a user-requested Finish")
        precondition(!SystemCaptureStopPolicy.isUserStop(NSError(domain: "Unrelated", code: SCStreamError.Code.userStopped.rawValue)))
        precondition(!RecordingControlPanelCoordinator.showsControls(destination: .recording, isSelectingArea: false, hidesForSystemCapture: true),
                     "The native full-display stream must not encode floating controls")
        precondition(RecordingControlPanelCoordinator.showsControls(destination: .countdown, isSelectingArea: false),
                     "The countdown remains visible until the stream starts")
        guard SystemCapturePicker.isSupported else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SystemPicker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var captures = 0
        var permissionQueries = 0
        let model = StudioModel(store: ProjectStore(projectsDirectory: directory),
            interactionTrackingAccess: { true }, inputMonitoringAccess: { true },
            screenCaptureAccess: { permissionQueries += 1; return false },
            startCapture: { _, _, _, _ in captures += 1; return 0 })
        var answers: [@MainActor (Result<SystemCaptureSelection?, Error>) -> Void] = []
        model.requestSystemCaptureSelection = { answers.append($0) }
        let previous = CaptureTargetInfo(id: "area-old", kind: .area, nativeID: 123,
            title: "Old area", frame: .init(x: 10, y: 20, width: 640, height: 480))
        try model.captureEngine.registerAreaTarget(previous)
        model.selectedTargetID = previous.id
        await model.showRecorder()
        precondition(model.usesSystemCapturePicker && model.isSelectingSystemContent && answers.count == 1)
        precondition(model.selectedTarget == nil && model.selectedTargetID == nil,
                     "Opening the system chooser invalidates the previous target")
        precondition(permissionQueries == 0 && model.captureEngine.availableTargets == [previous],
                     "System selection must not preflight or enumerate the whole desktop")
        model.selectToolbarTarget(previous)
        model.selectToolbarSourceKind(.area)
        precondition(model.selectedTargetID == nil, "Stale toolbar callbacks cannot replace the system selection")
        await model.refreshRecordingSourcesQuietly()
        precondition(model.captureEngine.availableTargets == [previous], "A source-list polling task must not run behind the system picker")
        model.startRecordingCountdown()
        precondition(captures == 0 && model.currentRecording == nil)
        do {
            _ = try model.startRecording(target: previous, options: AIRecordingOptions())
            preconditionFailure("MCP must wait while the person is choosing a source")
        } catch {
            precondition(error.localizedDescription.contains("macOS"))
        }
        precondition(model.automationNavigationRefusal == StudioModel.selectingSystemSourceRefusal)
        answers[0](.success(nil))
        precondition(!model.isSelectingSystemContent && model.selectedTarget == nil && captures == 0)
        model.isShowingError = false
        answers[0](.failure(CaptureEngineError.invalidTarget("Late failure")))
        precondition(!model.isShowingError, "A picker answer may only be consumed once")

        model.chooseSystemCaptureSource()
        precondition(answers.count == 2 && model.isSelectingSystemContent)
        model.destination = .library
        answers[1](.failure(CaptureEngineError.invalidTarget("Late failure")))
        precondition(model.destination == .library && !model.isShowingError && !model.isSelectingSystemContent,
                     "Leaving the recorder retires its callback without reopening it")

        await model.showRecorder()
        precondition(answers.count == 3)
        answers[1](.success(nil))
        precondition(model.isSelectingSystemContent, "An old callback cannot cancel a new chooser")
        answers[2](.failure(CaptureEngineError.invalidTarget("Unavailable window")))
        precondition(model.isShowingError && !model.isSelectingSystemContent && model.selectedTarget == nil)
        precondition(captures == 0 && model.currentRecording == nil,
                     "A failed or cancelled chooser never starts recording or substitutes another source")

        model.useListedCaptureSources()
        model.selectToolbarTarget(previous)
        precondition(!model.usesSystemCapturePicker && model.selectedTarget == previous,
                     "Explicit area/MCP workflows retain their existing source ID contract")
        model.destination = .library
        print("SystemCapturePickerRegression: PASS (no broad permission lookup, cancellation, failure, retired callbacks, MCP/toolbar exclusion, legacy source IDs)")
    }
}
