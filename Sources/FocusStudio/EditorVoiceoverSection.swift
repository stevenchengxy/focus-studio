import FocusStudioAutomation
import FocusStudioCore
import SwiftUI

/// Numeric edits commit as one project update, rather than rebuilding an
/// AVPlayer composition for every keystroke or slider tick.
struct EditorVoiceoverSection: View {
    @EnvironmentObject private var model: StudioModel
    @Binding var project: RecordingProject
    let insertionTime: () -> Double
    let pausePlayback: () -> Void
    @State private var selectedID: UUID?
    @State private var draft: VoiceoverClip?
    @State private var error: String?
    @State private var importing = false

    private var clips: [VoiceoverClip] { project.settings.resolvedProductDemoAudio.voiceovers ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Voiceover").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button {
                    importing = true
                    let projectID = project.id
                    Task {
                        defer { importing = false }
                        if var voice = await model.chooseVoiceover(for: project), project.id == projectID {
                            voice.timelineStart = min(max(0, insertionTime()), max(0, project.duration - 0.02))
                            update { $0.voiceovers = clips + [voice] }
                            selectedID = voice.id; draft = voice
                        }
                    }
                } label: { Label("Import voiceover", systemImage: "plus") }
                .disabled(importing || clips.count >= 64)
            }
            VoiceoverRecordingView(projectID: project.id, duration: project.duration,
                canAdd: !importing && clips.count < 64, insertionTime: insertionTime,
                pausePlayback: pausePlayback) { [projectID = project.id] url, position in
                    do {
                        var voice = try await model.importVoiceover(from: url, projectID: projectID)
                        guard project.id == projectID, model.activeProject?.id == projectID else { return }
                        voice.timelineStart = position
                        voice.title = L10n.tr("Voiceover") + " " + Date().formatted(date: .omitted, time: .shortened)
                        update { $0.voiceovers = clips + [voice] }
                        selectedID = voice.id; draft = voice
                    } catch { self.error = error.localizedDescription }
                }
            if clips.isEmpty {
                Text("Add a recorded explanation or an audio file.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Picker("Voiceover clip", selection: $selectedID) {
                    ForEach(clips) { clip in Text(clip.title).tag(Optional(clip.id)) }
                }.labelsHidden()
                if let value = draft {
                    Toggle("Enabled", isOn: field(\.isEnabled, value))
                    HStack {
                        number("Timeline start", field(\.timelineStart, value))
                        number("Volume %", Binding(get: { (draft?.volume ?? value.volume) * 100 },
                                                     set: { draft?.volume = $0 / 100 }))
                    }
                    HStack {
                        number("Source in", field(\.sourceStart, value))
                        number("Source out", field(\.sourceEnd, value))
                    }
                    HStack {
                        number("Fade in", field(\.fadeIn, value))
                        number("Fade out", field(\.fadeOut, value))
                    }
                    HStack {
                        Button("Apply") { apply() }
                            .disabled(value == clips.first { $0.id == value.id })
                        Button("Restore full audio") {
                            draft?.sourceStart = 0; draft?.sourceEnd = value.sourceDuration
                            apply()
                        }
                        Spacer()
                        Button(role: .destructive) {
                            update { $0.voiceovers = clips.filter { $0.id != value.id } }
                            selectedID = clips.first?.id
                            draft = clips.first
                        } label: { Image(systemName: "trash") }.help("Remove voiceover")
                    }
                    if value.timelineEnd > project.duration {
                        Text("Audio beyond the video end is not played.")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("Lower music during voiceover", isOn: Binding(
                get: { project.settings.resolvedProductDemoAudio.voiceoverDuckingLevel != nil },
                set: { enabled in update { $0.voiceoverDuckingLevel = enabled ? 0.25 : nil } }))
            if let level = project.settings.resolvedProductDemoAudio.voiceoverDuckingLevel {
                HStack {
                    Text("Music under voice").font(.system(size: 10))
                    Spacer()
                    Picker("Music under voice", selection: Binding(get: { level }, set: { level in
                        update { $0.voiceoverDuckingLevel = level }
                    })) {
                        Text("10%").tag(0.1); Text("25%").tag(0.25); Text("50%").tag(0.5)
                    }.labelsHidden().frame(width: 80)
                }
            }
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
        }
        .font(.system(size: 10))
        .padding(12)
        .background(StudioTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { reload() }
        .onChange(of: selectedID) { _, _ in reload() }
        .onChange(of: clips) { _, _ in reload() }
    }

    private func number(_ label: LocalizedStringKey, _ binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, value: binding, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder).onSubmit { apply() }
        }.frame(maxWidth: .infinity)
    }
    private func field<T>(_ key: WritableKeyPath<VoiceoverClip, T>, _ fallback: VoiceoverClip) -> Binding<T> {
        Binding(get: { (draft ?? fallback)[keyPath: key] }, set: { draft?[keyPath: key] = $0 })
    }
    private func reload() {
        if !clips.contains(where: { $0.id == selectedID }) { selectedID = clips.first?.id }
        draft = clips.first { $0.id == selectedID }; error = nil
    }
    private func update(_ change: (inout ProductDemoAudioSettings) -> Void) {
        var audio = project.settings.resolvedProductDemoAudio; change(&audio)
        project.settings.productDemoAudio = audio
    }
    private func apply() {
        guard let draft else { return }
        do {
            let valid = try draft.validated()
            update { $0.voiceovers = clips.map { $0.id == valid.id ? valid : $0 } }
            error = nil
        } catch { self.error = L10n.tr("Check the audio times, volume and fades.") }
    }
}
