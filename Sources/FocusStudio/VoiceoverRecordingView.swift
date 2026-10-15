import FocusStudioAutomation
import SwiftUI

struct VoiceoverRecordingView: View {
    @EnvironmentObject private var model: StudioModel
    let projectID: UUID
    let duration: Double
    let canAdd: Bool
    let insertionTime: () -> Double
    let pausePlayback: () -> Void
    let completed: (URL, Double) async -> Void
    @StateObject private var recorder = VoiceoverRecorder()
    @State private var startTask: Task<Void, Never>?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if recorder.phase == .recording {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                        .monospacedDigit().frame(width: 40, alignment: .leading)
                    ProgressView(value: recorder.level).tint(.green)
                        .accessibilityLabel("Microphone level")
                    Button { recorder.finish() } label: { Image(systemName: "stop.fill") }
                        .help("Save voiceover").accessibilityLabel("Save voiceover")
                    Button { cancel() } label: { Image(systemName: "xmark") }
                        .help("Cancel voiceover").accessibilityLabel("Cancel voiceover")
                }
            } else if recorder.phase == .requesting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for microphone access…")
                    Spacer()
                    Button("Cancel") { cancel() }
                }
            } else {
                Button {
                    pausePlayback()
                    let position = min(max(0, insertionTime()), max(0, duration - 0.1))
                    startTask = Task {
                        await recorder.start(access: model.microphoneAccess, maximumDuration: duration - position) { url in
                            importing = true
                            Task {
                                defer { importing = false; try? FileManager.default.removeItem(at: url) }
                                await completed(url, position)
                            }
                        }
                    }
                } label: {
                    Label(importing ? "Saving voiceover…" : "Record voiceover", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canAdd || importing || model.isBusy || model.captureEngine.isRecording || model.isExportingFromEditor)
                .help("Record from the selected frame. Use headphones when playing the preview.")
            }
            if let error = recorder.error {
                Text(error).foregroundStyle(.orange).font(.system(size: 10))
            }
        }
        .font(.system(size: 10))
        .onDisappear { cancel() }
        .onChange(of: projectID) { _, _ in cancel() }
    }
    private func cancel() { startTask?.cancel(); startTask = nil; recorder.cancel() }
}
