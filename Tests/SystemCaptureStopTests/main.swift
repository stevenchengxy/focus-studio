import Foundation
@testable import FocusStudioCapture

@main
struct SystemCaptureStopTests {
    enum Failure: Error, Equatable { case removed, writer, stop }
    @MainActor static func main() async throws {
        var stopped = false
        var events: [String] = []
        try await RecordingStreamFinisher.finish(
            removeOutput: { events.append("remove"); throw Failure.removed },
            waitForWriter: {
                events.append("delegate-user-stop")
                stopped = true
                await Task.yield()
                events.append("writer-finished")
            },
            stopStream: { events.append("stop") },
            wasStoppedByUser: { stopped }
        )
        precondition(events == ["remove", "delegate-user-stop", "writer-finished"],
                     "A Stop Sharing racing Finish/Pause must drain the writer and avoid stopping it twice")
        events = []
        try await RecordingStreamFinisher.finish(
            removeOutput: { events.append("remove") },
            waitForWriter: { events.append("writer-finished") },
            stopStream: { events.append("stop") }, wasStoppedByUser: { true }
        )
        precondition(events == ["writer-finished"])
        do {
            try await RecordingStreamFinisher.finish(removeOutput: {}, waitForWriter: { throw Failure.writer },
                stopStream: {}, wasStoppedByUser: { true })
            preconditionFailure("User Stop must not hide a corrupt or unfinished output")
        } catch { precondition(error as? Failure == .writer) }
        do {
            try await RecordingStreamFinisher.finish(removeOutput: { throw Failure.removed }, waitForWriter: {},
                stopStream: {}, wasStoppedByUser: { false })
            preconditionFailure("Genuine removal errors remain failures")
        } catch { precondition(error as? Failure == .removed) }
        stopped = false
        try await RecordingStreamFinisher.finish(removeOutput: {}, waitForWriter: {},
            stopStream: { stopped = true; throw Failure.stop }, wasStoppedByUser: { stopped })
        do {
            try await RecordingStreamFinisher.finish(removeOutput: {}, waitForWriter: {},
                stopStream: { throw Failure.stop }, wasStoppedByUser: { false })
            preconditionFailure("A genuine stream-stop failure must propagate")
        } catch { precondition(error as? Failure == .stop) }
        print("SystemCaptureStopTests: PASS (late user-stop callback, writer drain, already stopped, real writer/removal/stop failures)")
    }
}
