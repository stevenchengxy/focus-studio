import AVFoundation
import Darwin
import Foundation
import FocusStudioCapture
import FocusStudioCore

/// Developer capture of the real client without switching its editor to the
/// recorder screen. Uses the shipping capture/compositor, never the app library.
/// Screen Recording/Input Monitoring remain normal macOS permissions.
enum TutorialWindowRecorder {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Trace: Codable {
        let target: CaptureTargetInfo
        let duration: Double
        let sourceWidth: Int
        let sourceHeight: Int
        let cursorSamples: [CursorSample]
        let clickEvents: [ClickEvent]
        let typingActivity: [TypingActivity]
        let eventDiagnostics: EventMonitorDiagnostics
        let eventCaptureWarning: String?
    }

    @MainActor
    static func record(windowID: UInt32, duration: Double, outputDirectory: URL, renderCursor: Bool) async throws {
        let manager = FileManager.default
        let sourceURL = outputDirectory.appendingPathComponent("source.mp4")
        let traceURL = outputDirectory.appendingPathComponent("capture-trace.json")
        let renderedURL = outputDirectory.appendingPathComponent("with-cursor.mp4")
        let stopURL = outputDirectory.appendingPathComponent("stop-recording")
        for url in [sourceURL, traceURL, renderedURL, stopURL] where manager.fileExists(atPath: url.path) {
            throw Failure(message: "Use a fresh output directory; refusing to replace \(url.path)")
        }
        let engine = CaptureEngine()
        let targets = try await engine.refreshAvailableTargets()
        guard let target = targets.first(where: { $0.kind == .window && $0.nativeID == windowID }) else {
            throw Failure(message: "Window \(windowID) is not visible. Select its current exact ID and retry.")
        }
        emit(["state": "countdown", "seconds": 3, "window_id": windowID,
              "target": target.title, "stop_file": stopURL.path])
        try await Task.sleep(for: .seconds(3))
        if manager.fileExists(atPath: stopURL.path) {
            emit(["state": "cancelled", "reason": "Stop requested before capture"])
            return
        }
        var options = CaptureOptions()
        options.frameRate = 30
        options.maximumOutputDimension = 2560
        options.capturesSystemAudio = false
        options.capturesMicrophone = false
        try await engine.startRecording(target: target, outputURL: sourceURL, options: options)
        emit(["state": "recording", "window_id": windowID, "source": sourceURL.path,
              "maximum_duration": duration, "microphone": false, "system_audio": false])
        do {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(duration))
            while clock.now < deadline && !manager.fileExists(atPath: stopURL.path) {
                if case let .failed(message) = engine.state { throw Failure(message: message) }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            // Finalize what was captured on cancellation instead of leaving an
            // open media writer. No source file is silently deleted.
            if engine.isRecording { _ = try? await engine.stopRecording() }
            throw error
        }
        let result = try await engine.stopRecording()
        let trace = Trace(target: result.target, duration: result.duration,
            sourceWidth: result.sourceWidth, sourceHeight: result.sourceHeight,
            cursorSamples: result.cursorSamples, clickEvents: result.clickEvents,
            typingActivity: result.typingActivity, eventDiagnostics: result.eventDiagnostics,
            eventCaptureWarning: engine.eventCaptureWarning)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(trace).write(to: traceURL, options: .atomic)
        emit(["state": "captured", "source": sourceURL.path, "trace": traceURL.path,
              "duration": result.duration, "cursor_samples": result.cursorSamples.count,
              "clicks": result.clickEvents.count])
        if renderCursor {
            var settings = ProjectSettings()
            settings.padding = 0
            settings.cornerRadius = 0
            settings.shadow = 0
            settings.autoZoomEnabled = false
            settings.showCursor = true
            settings.showClickRing = true
            settings.aspectRatio = .automatic
            settings.exportWidth = min(1920, result.sourceWidth)
            settings.frameRate = 30
            let project = RecordingProject(title: "Focus Studio tutorial capture",
                sourceVideoPath: result.outputURL.path, duration: result.duration,
                sourceWidth: result.sourceWidth, sourceHeight: result.sourceHeight,
                cursorSamples: result.cursorSamples, clickEvents: result.clickEvents,
                typingActivity: result.typingActivity, settings: settings)
            _ = try await ProjectVideoRenderer.export(project: project, to: renderedURL)
            emit(["state": "rendered", "path": renderedURL.path])
        }
        emit(["state": "finished", "path": renderCursor ? renderedURL.path : sourceURL.path])
    }

    private static func emit(_ values: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }
}
