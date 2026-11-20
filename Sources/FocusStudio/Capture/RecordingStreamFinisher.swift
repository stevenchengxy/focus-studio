import Foundation

/// ScreenCaptureKit can stop an output before its delegate notification reaches
/// the main actor. Drain the writer even if removing it reports "already gone",
/// then decide using the terminal signal, not a snapshot from before the await.
@MainActor
enum RecordingStreamFinisher {
    static func finish(
        removeOutput: () throws -> Void,
        waitForWriter: () async throws -> Void,
        stopStream: () async throws -> Void,
        wasStoppedByUser: () -> Bool
    ) async throws {
        var removalError: Error?
        if !wasStoppedByUser() {
            do { try removeOutput() } catch { removalError = error }
        }
        var writerError: Error?
        do { try await waitForWriter() } catch { writerError = error }
        var stopError: Error?
        if !wasStoppedByUser() {
            do { try await stopStream() } catch { stopError = error }
        }
        // A genuine writer failure is never converted into a successful take.
        if let writerError { throw writerError }
        if !wasStoppedByUser(), let failure = removalError ?? stopError { throw failure }
        // The caller still probes the actual media before saving a project.
    }
}
