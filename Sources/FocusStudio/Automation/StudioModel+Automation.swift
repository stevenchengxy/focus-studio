import AppKit
import FocusStudioAutomation
import FocusStudioCore
import Foundation

/// What the app does around an automation call: the person using Focus
/// Studio watches every change, so a call that edits a project first opens it
/// in the editor and a library action first shows the library, the way the
/// buttons would. Neither happens while a recording or another task is
/// under way.
extension StudioModel {
    /// What keeps a call from changing what the window shows.
    enum AutomationBlocker: Equatable {
        /// A countdown, a recording or the save that ends it.
        case recording(AIRecordingPhase)
        /// A rename, delete or import is running.
        case managingProjects
        case codexPlan
        /// The editor's own Export is rendering behind its overlay.
        case editorExport
        /// The busy overlay shows this message.
        case busy(String)

        /// For an external client, in English, with what to do next.
        var clientMessage: String {
            switch self {
            case let .recording(phase):
                let state = phase == .countdown ? "counting down to a recording" : phase == .stopping ? "saving a recording" : "recording"
                return "Focus Studio is \(state). Editing tools are refused until the recording is over: call stop_recording, or wait for the person to finish it, then try again."
            case .managingProjects:
                return "Focus Studio is renaming, deleting or importing projects. Try again in a moment."
            case .codexPlan:
                return "Focus Studio is running a Codex Director plan. Try again when it finishes."
            case .editorExport:
                return "Focus Studio is exporting a video from its editor. Try again when the export finishes."
            case let .busy(message):
                return "Focus Studio is busy (\(message)). Try again when it finishes."
            }
        }

        /// For the person using the app (in the UI language) and for a tool
        /// (in its call's language).
        var failure: AILocalizedFailure {
            switch self {
            case .recording:
                return AILocalizedFailure("Focus Studio is recording. Try again after the recording is stopped.")
            case .managingProjects:
                return AILocalizedFailure("Finish the current library operation before starting another.")
            case .codexPlan, .editorExport, .busy:
                return AILocalizedFailure("Focus Studio is busy. Try again when the current task finishes.")
            }
        }
    }

    var automationBlocker: AutomationBlocker? {
        switch recordingPhase {
        case .countdown, .recording, .stopping:
            return .recording(recordingPhase)
        case .idle, .failed:
            break
        }
        if isManagingProjects { return .managingProjects }
        if isRunningCodexPlan { return .codexPlan }
        if isExportingFromEditor { return .editorExport }
        if isBusy { return .busy(busyMessage) }
        return nil
    }

    /// Why an external call may not change what the window shows now, on top
    /// of what ``automationBlocker`` covers for its own paths: the in-app
    /// assistant is partway through a request (its tools edit whichever
    /// project is open), the editor's Export is rendering, a save or open
    /// panel is up, the person is drawing a recording area (its overlay
    /// covers the screen, and the recorder's source is theirs to choose), or
    /// the person clicked Record and macOS is asking them about the
    /// microphone (their countdown starts when they answer, with the source
    /// they chose, on the recorder). Checked for every call that navigates,
    /// the recording tools included. Kept out of automationBlocker, which the
    /// app's own Import video and Animate screenshot also check.
    var automationNavigationRefusal: String? {
        if isAssistantRunning {
            return "Focus Studio's own assistant is working on a request in the app. Try again when it finishes."
        }
        if isExportingFromEditor { return AutomationBlocker.editorExport.clientMessage }
        if NSApp?.modalWindow != nil {
            return "Focus Studio is showing a dialog, such as a save or open panel. Try again when the person has closed it."
        }
        if isSelectingArea { return Self.drawingAreaRefusal }
        if isWaitingForMicrophoneAccess { return Self.waitingForMicrophoneRefusal }
        return nil
    }

    /// For a call that arrives while the person draws a recording area.
    static let drawingAreaRefusal = "The person is drawing a recording area in Focus Studio. Try again when they have finished or cancelled it."

    /// For a call that arrives while the person's Record waits for macOS's
    /// microphone dialog (``isWaitingForMicrophoneAccess``).
    static let waitingForMicrophoneRefusal = "The person clicked Record in Focus Studio, and macOS is asking them whether Focus Studio may use the microphone; their own recording starts when they answer. Nothing was changed. Try again when that recording is over (get_status shows its state)."

    /// Shows `id` in the editor for a call that edits or renders it: saves
    /// and closes any other open project first (as Back does), then opens
    /// this one. Changes nothing and throws while the app is recording or
    /// busy, while the person's Record waits for macOS's microphone dialog,
    /// or for an unknown id.
    func openProjectForAutomation(id: UUID) throws {
        guard let project = projects.first(where: { $0.id == id }) else {
            throw AIToolError.invalidArgument("No project has the id \(id.uuidString). Call list_projects for the current ids.")
        }
        if let blocker = automationBlocker { throw AIToolError.failed(blocker.clientMessage) }
        // The person's Record would be dropped once they answer macOS.
        if isWaitingForMicrophoneAccess { throw AIToolError.failed(Self.waitingForMicrophoneRefusal) }
        if destination == .editor {
            if activeProject?.id == id { return }
            closeEditor()
        }
        open(project)
    }

    /// Shows the library for a rename or delete, the only place those run:
    /// saves and closes the editor (as Back does) or leaves the recorder or
    /// Director. Throws, changing nothing, while the app is recording or busy
    /// or the person's Record waits for macOS's microphone dialog.
    func showLibraryForProjectManagement() throws {
        if let blocker = automationBlocker { throw blocker.failure }
        // The person's Record would be dropped once they answer macOS.
        if isWaitingForMicrophoneAccess { throw AIToolError.failed(Self.waitingForMicrophoneRefusal) }
        switch destination {
        case .library:
            break
        case .editor:
            closeEditor()
        case .recorder, .director, .recording, .countdown:
            // No capture is running (see automationBlocker): the recorder or a
            // failed recording's screen has nothing to keep.
            destination = .library
        }
    }

    /// A fresh tool context for one automation call: English texts, the
    /// caller's working directory for relative paths, and when the call names
    /// a project, pinned to it with that project's assets folder. Without a
    /// project, generated files go to the shared AI Assets folder.
    func makeAutomationContext(projectID: UUID?, workingDirectory: URL?, progress: AIToolProgressHandler? = nil) -> AIAssistantContext {
        let assets = projectID
            .flatMap { project(id: $0) }
            .flatMap { AIProjectReport.assetsDirectory(for: $0, libraryRoot: libraryDirectory) }
            ?? sharedAssetsDirectory
        var context = makeToolContext(assetsDirectory: { assets }, language: { AppLanguage.english.localeIdentifier })
        context.isExternal = true
        context.workingDirectory = workingDirectory
        context.projectID = projectID
        context.numericProgress = progress
        return context
    }
}
