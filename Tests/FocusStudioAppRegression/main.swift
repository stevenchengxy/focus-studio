import FocusStudioCore
import Foundation
import SwiftUI

@main
struct AppRegression {
    @MainActor
    static func main() async throws {
        // Never touch the real ark.env, secrets.json or the network from a
        // test: the ControlServer and MCP end-to-end fixtures run
        // StudioModel.bootstrap(), which would import an Ark key otherwise.
        setenv("FOCUS_STUDIO_IMPORT_ARK_ENV", "0", 1)
        unsetenv("FOCUS_STUDIO_START_DESTINATION")
        unsetenv("FOCUS_STUDIO_ASSISTANT_PROMPT")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusStudio-Navigation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(projectsDirectory: directory)
        var inputAccess = false
        var monitoringAccess = true
        let permissionModel = StudioModel(store: store, interactionTrackingAccess: { inputAccess }, inputMonitoringAccess: { monitoringAccess })
        permissionModel.destination = .recorder
        precondition(!permissionModel.confirmInteractionTrackingBeforeRecording())
        precondition(permissionModel.isShowingInteractionSetup)
        precondition(permissionModel.destination == .recorder && !permissionModel.captureEngine.isRecording,
                     "Missing input access must not silently start a recording")
        precondition(permissionModel.confirmInteractionTrackingBeforeRecording(allowUnavailable: true))
        precondition(!permissionModel.isShowingInteractionSetup)
        // Consent to continue once is not a persistent bypass for later recordings.
        precondition(!permissionModel.confirmInteractionTrackingBeforeRecording())
        inputAccess = true
        precondition(permissionModel.confirmInteractionTrackingBeforeRecording())
        precondition(permissionModel.interactionTrackingAuthorized && !permissionModel.isShowingInteractionSetup)
        monitoringAccess = false
        precondition(!permissionModel.confirmInteractionTrackingBeforeRecording(),
                     "Accessibility alone must not silently promise complete input tracking")
        precondition(permissionModel.accessibilityAuthorized && !permissionModel.inputMonitoringAuthorized)
        inputAccess = false
        permissionModel.automaticZooms = false
        precondition(permissionModel.confirmInteractionTrackingBeforeRecording(),
                     "Screen-only recordings must not require input permissions")
        let model = StudioModel(store: store)
        var original = RecordingProject(
            title: "Navigation regression",
            sourceVideoPath: "raw.mp4",
            duration: 3,
            sourceWidth: 1280,
            sourceHeight: 720
        )
        for iteration in 0..<50 {
            model.open(original)
            let outgoing = model.editorBinding(for: original)
            var edited = outgoing.wrappedValue
            edited.title = "Saved edit \(iteration)"
            outgoing.wrappedValue = edited
            precondition(model.activeProject?.title == edited.title)
            model.closeEditor()
            precondition(model.destination == .library && model.activeProject == nil)
            // This read used to trap at FocusStudioApp.swift:62.
            precondition(outgoing.wrappedValue.id == original.id)
            outgoing.wrappedValue = edited
            precondition(model.activeProject == nil, "Late writes must not resurrect an editor")

            let other = RecordingProject(
                title: "Another project",
                sourceVideoPath: "raw.mp4",
                duration: 1,
                sourceWidth: 640,
                sourceHeight: 480
            )
            model.open(other)
            precondition(outgoing.wrappedValue.id == original.id)
            outgoing.wrappedValue = edited
            precondition(model.activeProject?.id == other.id, "Old callbacks must not replace the new project")
            model.closeEditor()
            original = edited
        }
        await model.flushProjectEdits()
        let saved = try await store.loadProjects()
        precondition(saved.first(where: { $0.id == original.id })?.title == original.title,
                     "Back must preserve the most recent edit")

        var timingSettings = ProjectSettings()
        timingSettings.zoomEaseIn = 0.2
        timingSettings.zoomEaseOut = 0.3
        var timingProject = RecordingProject(
            title: "Post-recording timing persistence",
            sourceVideoPath: "raw.mp4",
            duration: 10,
            sourceWidth: 1280,
            sourceHeight: 720,
            clickEvents: [ClickEvent(time: 1, x: 0.4, y: 0.6, button: .left)],
            settings: timingSettings
        )
        TimelineMath.regenerateAutomaticZoomSegments(in: &timingProject)
        precondition(timingProject.zoomSegments.count == 1)
        let zoomID = timingProject.zoomSegments[0].id
        model.open(timingProject)
        let timingBinding = model.editorBinding(for: timingProject)
        let edits: [ZoomTimingEdit] = [.start(0.5), .end(4), .duration(2.25), .easeIn(0.12), .easeOut(0.65), .hold(1.5), .move(5)]
        for edit in edits {
            var updated = timingBinding.wrappedValue
            updated.zoomSegments[0] = ZoomTiming.applying(edit, to: updated.zoomSegments[0], projectDuration: updated.duration, settings: updated.settings)
            timingBinding.wrappedValue = updated
            precondition(model.activeProject?.zoomSegments[0] == updated.zoomSegments[0],
                         "Editor timing bindings must update the active project immediately")
        }
        let finalTiming = timingBinding.wrappedValue.zoomSegments[0]
        precondition(finalTiming.id == zoomID && finalTiming.kind == .manual)
        precondition(abs(finalTiming.start - 5) < 0.000001 && abs(finalTiming.end - 7.27) < 0.000001)
        precondition(finalTiming.zoomEaseIn == 0.12 && finalTiming.zoomEaseOut == 0.65)
        model.closeEditor()
        await model.flushProjectEdits()
        let timingSavedProjects = try await store.loadProjects()
        guard var reopened = timingSavedProjects.first(where: { $0.id == timingProject.id }) else {
            preconditionFailure("Edited timing project was not saved before leaving the editor")
        }
        precondition(reopened.zoomSegments == [finalTiming],
                     "Start/end/hold and per-block speed overrides must survive Back and project reload")
        reopened.settings.zoomHold = 5
        TimelineMath.regenerateAutomaticZoomSegments(in: &reopened)
        precondition(reopened.zoomSegments == [finalTiming],
                     "The persisted manual edit must not regain its replaced automatic source cue")
        precondition(TimelineMath.zoomState(at: 1.5, segments: reopened.zoomSegments, settings: reopened.settings).scale == 1,
                     "Moving the saved block must remove the source click's original zoom")
        precondition(TimelineMath.zoomState(at: finalTiming.end + 0.01, segments: reopened.zoomSegments, settings: reopened.settings).scale == 1,
                     "The persisted block must actually return to overview after its chosen end")
        model.open(reopened)
        let reopenedBinding = model.editorBinding(for: reopened)
        precondition(reopenedBinding.wrappedValue.zoomSegments == [finalTiming])
        model.closeEditor()
        await model.flushProjectEdits()
        try await ProjectLibraryRegression.run()
        try await AssistantControlRegression.run()
        try await RecordingSessionRegression.run()
        try await AutomationBridgeRegression.run()
        try await ControlServerRegression.run()
        try await MCPClientConnectorRegression.run()
        try await MCPEndToEndRegression.run()
        print("FocusStudioAppRegression: PASS (interaction preflight, 50 open/edit/back cycles, stale binding reads/writes, autosave, zoom timing edit/save/reload/regeneration, assistant control, recording sessions (countdown, duration, joined stop, per-recording options), automation bridge, control server and approvals, MCP client connector, MCP end to end through focus-studio-mcp)")
    }
}
