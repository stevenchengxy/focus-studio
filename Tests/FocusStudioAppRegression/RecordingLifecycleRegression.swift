import FocusStudioAutomation
import FocusStudioCapture
import FocusStudioCore
import Foundation

/// Pure model lifecycle checks: transient synthetic area inventory only. No
/// permission dialogs, screen enumeration, actual capture, panels, or user data.
@MainActor
enum RecordingLifecycleRegression {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusStudio-RecordingLifecycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsDirectory: root)
        let model = StudioModel(store: store, interactionTrackingAccess: { true }, inputMonitoringAccess: { true })
        let area = CaptureTargetInfo(id: "synthetic-area", kind: .area, nativeID: 424242,
            title: "Synthetic test region", frame: CaptureRect(x: 50, y: 50, width: 320, height: 200))
        try model.captureEngine.registerAreaTarget(area)
        model.destination = .recorder
        model.selectToolbarTarget(area)
        precondition(model.selectedTargetID == area.id && model.recordingSourceKind == .area,
                     "Toolbar selection must synchronize picker mode and source ID")

        // The floating console's mode segments go through the model, under the
        // same guards as selectToolbarTarget.
        model.selectToolbarSourceKind(.window)
        precondition(model.recordingSourceKind == .window,
                     "The floating toolbar must be able to change source kind from the console")
        model.selectToolbarSourceKind(.area)
        precondition(model.recordingSourceKind == .area && model.selectedTargetID == area.id,
                     "Returning to Area must reuse the registered area, not clear the selection")
        precondition(model.areaDisplays.isEmpty && model.areaDrawDisplay() == nil,
                     "With no display targets there is nowhere to draw an area")

        model.isBusy = true
        model.startRecordingCountdown()
        precondition(model.destination == .recorder && !model.captureEngine.isRecording,
                     "Busy preparation must not start a second countdown")
        let other = CaptureTargetInfo(id: "other-window", kind: .window, nativeID: 424243,
            title: "Unregistered fake window", frame: area.frame)
        model.selectToolbarTarget(other)
        precondition(model.selectedTargetID == area.id && model.recordingSourceKind == .area,
                     "A busy toolbar cannot replace the selected source")
        model.selectToolbarSourceKind(.display)
        precondition(model.recordingSourceKind == .area,
                     "A busy model must ignore a toolbar mode switch")
        model.isBusy = false
        model.destination = .library
        model.selectToolbarTarget(other)
        precondition(model.selectedTargetID == area.id, "A stale toolbar callback cannot change library state")
        model.selectToolbarSourceKind(.window)
        precondition(model.recordingSourceKind == .area,
                     "A mode switch sent while the library is on screen must be ignored")
        model.destination = .recorder

        precondition(model.showRecordingCursor, "New recording pointer visibility defaults to on")
        model.showRecordingCursor = false
        model.startRecordingCountdown()
        precondition(model.destination == .countdown && model.recordingCountdown == 3 && !model.captureEngine.isRecording,
                     "Explicit start enters countdown, never captures immediately")
        model.cancelRecordingCountdown()
        model.destination = .library
        try await Task.sleep(for: .milliseconds(100))
        precondition(model.destination == .library && !model.captureEngine.isRecording,
                     "Cancelling then leaving must not be undone by queued countdown cleanup")

        // Cancel/restart immediately: the old task's defer must not clear the
        // new countdown token and permit a third overlapping start.
        model.destination = .recorder
        model.startRecordingCountdown()
        model.cancelRecordingCountdown()
        model.startRecordingCountdown()
        try await Task.sleep(for: .milliseconds(1120))
        precondition(model.destination == .countdown && model.recordingCountdown == 2)
        model.startRecordingCountdown()
        precondition(model.recordingCountdown == 2,
                     "Repeated Start must not reset or duplicate an existing countdown")
        model.selectToolbarTarget(other)
        precondition(model.selectedTargetID == area.id, "Source is locked throughout countdown")
        model.cancelRecordingCountdown()
        precondition(model.destination == .recorder && model.recordingCountdown == 3 && !model.captureEngine.isRecording)

        // The synthetic area's backing display intentionally doesn't exist.
        // The late revalidation must fail before any capture/permission API.
        model.startRecordingCountdown()
        try await Task.sleep(for: .milliseconds(3250))
        precondition(model.destination == .recorder && !model.captureEngine.isRecording && model.isShowingError,
                     "An unavailable source must return to a retryable picker before media preparation")
        precondition(!model.isBusy && !model.showRecordingCursor,
                     "Failed start preserves options and releases the UI")
        model.isShowingError = false
        await model.toggleRecordingPause()
        await model.stopRecording()
        await model.stopRecording()
        precondition(model.destination == .recorder && !model.captureEngine.isPaused && !model.isShowingError && !model.isBusy,
                     "Idle Pause/Finish callbacks are harmless and do not open an error or editor")
        await model.cancelRecording()
        precondition(model.destination == .recorder && !model.captureEngine.isRecording,
                     "A stale Cancel callback cannot navigate after the recording has ended")
        model.destination = .library

        // Source selection by chat must update the same picker mode as toolbar.
        // Cancelling immediately prevents the fake area reaching capture.
        model.recordingSourceKind = .window
        try model.startRecording(sourceID: area.id, options: AIRecordingOptions(automaticZooms: false))
        precondition(model.recordingSourceKind == area.kind && model.destination == .countdown,
                     "Assistant recording source must synchronize picker mode before countdown")
        model.cancelRecordingCountdown()

        model.destination = .recording
        model.isBusy = true
        model.handleCaptureStateChange(.failed("synthetic runtime failure"))
        precondition(model.destination == .recording && !model.isShowingError,
                     "A finishing operation owns its failure recovery; a state observer must not navigate over it")
        model.isBusy = false
        model.handleCaptureStateChange(.recording)
        precondition(model.destination == .recording && !model.isShowingError)
        model.handleCaptureStateChange(.failed("synthetic runtime failure"))
        precondition(model.destination == .recorder && model.isShowingError && model.errorMessage == "synthetic runtime failure",
                     "A runtime failure must return to a retryable picker with its actual error")
        model.isShowingError = false
        model.destination = .library
        model.handleCaptureStateChange(.failed("stale failure"))
        precondition(model.destination == .library && !model.isShowingError,
                     "Old capture failure notifications cannot hijack a different page")

        // Pre-recording panels exist before EventMonitor.prepare/reset. Their
        // exclusion IDs must not be erased when event capture resets its trace.
        let monitor = model.captureEngine.eventMonitor
        monitor.ignoredWindowNumbers = [101, 102]
        monitor.reset()
        precondition(monitor.ignoredWindowNumbers == [101, 102])
        monitor.stop()
        precondition(monitor.ignoredWindowNumbers == [101, 102], "Stopping input capture does not own panel lifetime")
        monitor.ignoredWindowNumbers.remove(101)
        monitor.ignoredWindowNumbers.insert(103)
        precondition(monitor.ignoredWindowNumbers == [102, 103], "Rebuilding one panel only replaces its exclusion ID")
        monitor.ignoredWindowNumbers.removeAll()

        let projects = try await store.loadProjects()
        precondition(projects.isEmpty, "Cancelled or missing-source attempts must not create project metadata")
        print("RecordingLifecycleRegression: PASS (ready/busy/source sync, explicit countdown, cancel/restart/double-start, unavailable source, idle pause/finish, toolbar exclusion lifetime; no actual screen capture)")
    }
}
