import AppKit
import FocusStudioAutomation
import FocusStudioCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @EnvironmentObject private var model: StudioModel
    @Binding var project: RecordingProject

    @State private var currentTime = 0.0
    @State private var isPlaying = false
    @State private var seekRevision = 0
    @State private var showsShortcuts = false
    @State private var selectedZoomID: UUID?
    @State private var selectedChapterID: UUID?
    @State private var selectedClipID: UUID?
    // QA hook, mirroring FOCUS_STUDIO_START_DESTINATION: opens the editor on a
    // named inspector tab so a panel can be screenshotted without scripted clicks.
    @State private var selectedTool: EditorTool = ProcessInfo.processInfo
        .environment["FOCUS_STUDIO_EDITOR_TOOL"]
        .flatMap(EditorTool.init(rawValue:)) ?? .video
    @State private var renderError: String?
    @State private var exportMessage: String?
    @State private var videoEditMessage: String?
    @State private var isApplyingVideoEdit = false
    @State private var isImportingMedia = false
    @Namespace private var toolHighlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider().overlay(StudioTheme.line)

            HStack(spacing: 0) {
                toolRail
                Divider().overlay(StudioTheme.line)

                VStack(spacing: 0) {
                    ZStack {
                        Color.black.opacity(0.12)
                        ProjectPreviewView(
                            project: project,
                            currentTime: $currentTime,
                            isPlaying: $isPlaying,
                            seekRevision: seekRevision,
                            renderError: $renderError
                        )
                        .padding(.horizontal, 46)
                        .padding(.vertical, 28)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider().overlay(StudioTheme.line)
                    playbackBar
                    Divider().overlay(StudioTheme.line)
                    EditorTimelineView(
                        project: $project,
                        currentTime: seekBinding,
                        selectedZoomID: $selectedZoomID,
                        selectedChapterID: $selectedChapterID,
                        selectedClipID: $selectedClipID,
                        selectedTool: $selectedTool,
                        onVideoEdit: applyVideoEdit,
                        onInsertMedia: insertMediaAsset,
                        isVideoEditing: isApplyingVideoEdit
                    )
                }

                Divider().overlay(StudioTheme.line)
                EditorInspectorView(
                    project: $project,
                    selectedZoomID: $selectedZoomID,
                    selectedChapterID: $selectedChapterID,
                    selectedClipID: $selectedClipID,
                    currentTime: seekBinding,
                    tool: selectedTool,
                    isVideoEditing: isApplyingVideoEdit,
                    canUndoVideoEdit: model.canUndoVideoEdit(projectID: project.id),
                    canRedoVideoEdit: model.canRedoVideoEdit(projectID: project.id),
                    onVideoEdit: applyVideoEdit,
                    onUndoVideoEdit: undoVideoEdit,
                    onRedoVideoEdit: redoVideoEdit,
                    onImportMedia: importMedia,
                    onCreateMediaWithAI: { openWindow(id: AssistantWindow.id) },
                    onInsertMedia: { insertMediaAsset($0, atIndex: insertionIndex(at: currentTime)) },
                    onImportSharedMedia: importSharedMedia,
                    onSaveMediaToShared: saveMediaToShared,
                    isImportingMedia: isImportingMedia
                )
                .id(selectedTool)
                .transition(StudioMotion.panel(reduceMotion: reduceMotion))
                .frame(width: 292)
                .clipped()
            }
        }
        .background(EditorKeyboardBridge(enabled: !model.isExportingFromEditor && !isApplyingVideoEdit
            && !isImportingMedia && exportMessage == nil && videoEditMessage == nil && !showsShortcuts,
            perform: handleTransport))
        .onAppear(perform: restoreVideoEditPosition)
        .onDisappear { isPlaying = false }
        .animation(reduceMotion ? nil : StudioMotion.panelAnimation, value: selectedTool)
        .overlay {
            if model.isExportingFromEditor {
                Color.black.opacity(0.42).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Rendering MP4…")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Zooms, cursor, background, and audio are being combined locally.")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTheme.secondaryText)
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
        }
        .alert("Export", isPresented: Binding(
            get: { exportMessage != nil },
            set: { if !$0 { exportMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportMessage ?? "")
        }
        .alert("Video edit", isPresented: Binding(
            get: { videoEditMessage != nil },
            set: { if !$0 { videoEditMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(videoEditMessage ?? "")
        }
        .onChange(of: selectedZoomID) { _, id in
            if id != nil { selectedChapterID = nil; selectedTool = .zoom }
        }
        .onChange(of: selectedChapterID) { _, id in
            if id != nil { selectedZoomID = nil; selectedTool = .captions }
        }
        .onChange(of: selectedClipID) { _, id in
            if id != nil {
                selectedZoomID = nil
                selectedChapterID = nil
                selectedTool = .video
            }
        }
    }

    private var editorToolbar: some View {
        HStack(spacing: 11) {
            Button {
                isPlaying = false
                model.closeEditor()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Back to library")
            .help("Save and return to the project library")

            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            TextField("Project name", text: $project.title)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: 280)

            Spacer()

            Picker("Aspect", selection: $project.settings.aspectRatio) {
                ForEach(CanvasAspectRatio.allCases, id: \.self) { ratio in
                    Text(LocalizedStringKey(ratio.title)).tag(ratio)
                }
            }
            .labelsHidden()
            .frame(width: 90)

            Button {
                seek(to: currentTime - 5)
            } label: { Image(systemName: "gobackward.5") }
            .buttonStyle(IconButtonStyle())

            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(IconButtonStyle())

            Button {
                seek(to: currentTime + 5)
            } label: { Image(systemName: "goforward.5") }
            .buttonStyle(IconButtonStyle())

            Spacer()

            AppLanguageMenu()

            Button {
                openWindow(id: AssistantWindow.id)
            } label: {
                Label("AI", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.purple)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
            .background(StudioTheme.purple.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .help("Open the AI assistant")
            .accessibilityIdentifier("editor.assistant")

            Button(action: export) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 18)
        .frame(height: 57)
        .background(StudioTheme.panel)
    }

    private var toolRail: some View {
        VStack(spacing: 8) {
            ForEach(EditorTool.allCases) { tool in
                Button {
                    withAnimation(reduceMotion ? nil : StudioMotion.selection) { selectedTool = tool }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tool.icon)
                            .font(.system(size: 15, weight: .medium))
                        Text(LocalizedStringKey(tool.title))
                            .font(.system(size: 8, weight: .medium))
                    }
                    .foregroundStyle(selectedTool == tool ? .white : StudioTheme.secondaryText)
                    .frame(width: 51, height: 49)
                    .background {
                        if selectedTool == tool {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(StudioTheme.purple.opacity(0.22))
                                .matchedGeometryEffect(id: "tool-highlight", in: toolHighlight)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .hoverLift(scale: 1.04, shadowOpacity: 0)
            }
            Spacer()
        }
        .padding(.vertical, 13)
        .frame(width: 64)
        .background(StudioTheme.panel)
    }

    private var seekBinding: Binding<Double> {
        Binding(get: { currentTime }, set: { seek(to: $0) })
    }

    private func seek(to time: Double) {
        isPlaying = false
        currentTime = time.clamped(to: 0...max(0, project.duration))
        seekRevision += 1
    }

    private func restoreVideoEditPosition() {
        guard let resume = model.pendingEditorVideoEditResume else { return }
        model.pendingEditorVideoEditResume = nil
        seek(to: resume.time)
        if let clipID = resume.clipID,
           let timeline = try? DemoVideoTimeline(project: project),
           timeline.clips.contains(where: { $0.id == clipID }) {
            selectedClipID = clipID
        }
    }

    private func reconcileVideoSelection(after edited: RecordingProject) {
        seek(to: min(currentTime, edited.duration))
        guard let timeline = try? DemoVideoTimeline(project: edited) else {
            selectedClipID = nil
            return
        }
        if let selectedClipID, timeline.clips.contains(where: { $0.id == selectedClipID }) { return }
        selectedClipID = timeline.placements.first(where: {
            currentTime >= $0.start && currentTime < $0.end
        })?.clip.id ?? timeline.clips.first?.id
    }

    private func applyVideoEdit(_ operation: DemoVideoEditOperation) {
        guard !isApplyingVideoEdit else { return }
        isPlaying = false
        isApplyingVideoEdit = true
        let projectID = project.id
        model.pendingEditorVideoEditResume = (currentTime, selectedClipID)
        Task { @MainActor in
            defer { isApplyingVideoEdit = false }
            do {
                let edited = try await model.applyVideoEdit(projectID: projectID, operation: operation)
                if edited.id == projectID { reconcileVideoSelection(after: edited) }
            } catch {
                model.pendingEditorVideoEditResume = nil
                videoEditMessage = error.localizedDescription
            }
        }
    }

    private func undoVideoEdit() {
        guard !isApplyingVideoEdit, model.canUndoVideoEdit(projectID: project.id) else { return }
        isPlaying = false
        isApplyingVideoEdit = true
        let projectID = project.id
        Task { @MainActor in
            defer { isApplyingVideoEdit = false }
            do {
                let edited = try await model.undoVideoEdit(projectID: projectID)
                reconcileVideoSelection(after: edited)
            } catch {
                videoEditMessage = error.localizedDescription
            }
        }
    }

    private func redoVideoEdit() {
        guard !isApplyingVideoEdit, model.canRedoVideoEdit(projectID: project.id) else { return }
        isPlaying = false
        isApplyingVideoEdit = true
        let projectID = project.id
        Task { @MainActor in
            defer { isApplyingVideoEdit = false }
            do {
                let edited = try await model.redoVideoEdit(projectID: projectID)
                reconcileVideoSelection(after: edited)
            } catch {
                videoEditMessage = error.localizedDescription
            }
        }
    }

    private func insertionIndex(at time: Double) -> Int {
        guard let timeline = try? DemoVideoTimeline(project: project) else { return 0 }
        return timeline.placements.firstIndex { time < ($0.start + $0.end) / 2 }
            ?? timeline.placements.count
    }

    private func insertMediaAsset(_ assetID: UUID, atIndex: Int) {
        guard !isApplyingVideoEdit, !isImportingMedia else { return }
        isPlaying = false
        isApplyingVideoEdit = true
        let projectID = project.id
        let priorClipIDs = Set(project.videoClips?.map(\.id) ?? [])
        Task { @MainActor in
            defer { isApplyingVideoEdit = false }
            do {
                let edited = try await model.insertEditorMedia(
                    projectID: projectID, assetID: assetID, atIndex: atIndex)
                reconcileVideoSelection(after: edited)
                if let inserted = edited.videoClips?.first(where: {
                    $0.mediaAssetID == assetID && !priorClipIDs.contains($0.id)
                }) {
                    selectedClipID = inserted.id
                }
                selectedTool = .video
            } catch {
                videoEditMessage = error.localizedDescription
            }
        }
    }

    private func importMedia() {
        guard !isApplyingVideoEdit, !isImportingMedia else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.tr("Import media into this demo")
        panel.prompt = L10n.tr("Import")
        panel.allowedContentTypes = [.movie, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        isPlaying = false
        isImportingMedia = true
        let projectID = project.id
        let urls = panel.urls
        model.pendingEditorVideoEditResume = (currentTime, selectedClipID)
        Task { @MainActor in
            defer { isImportingMedia = false }
            do {
                _ = try await model.importEditorMedia(from: urls, projectID: projectID)
            } catch {
                model.pendingEditorVideoEditResume = nil
                videoEditMessage = error.localizedDescription
            }
        }
    }

    private func importSharedMedia(_ assetID: UUID) {
        guard !isApplyingVideoEdit, !isImportingMedia else { return }
        isPlaying = false
        isImportingMedia = true
        let projectID = project.id
        model.pendingEditorVideoEditResume = (currentTime, selectedClipID)
        Task { @MainActor in
            defer { isImportingMedia = false }
            do { _ = try await model.importGlobalMediaToProject(assetIDs: [assetID], projectID: projectID) }
            catch {
                model.pendingEditorVideoEditResume = nil
                videoEditMessage = error.localizedDescription
            }
        }
    }

    private func saveMediaToShared(_ assetID: UUID) {
        guard let asset = project.mediaAssets?.first(where: { $0.id == assetID }) else { return }
        Task { @MainActor in
            do { _ = try await model.importGlobalMedia(from: [URL(fileURLWithPath: asset.filePath)]) }
            catch { videoEditMessage = error.localizedDescription }
        }
    }

    private func splitVideoAtPlayhead() {
        guard let timeline = try? DemoVideoTimeline(project: project),
              let placement = timeline.placements.first(where: {
                  currentTime > $0.start + 0.1 && currentTime < $0.end - 0.1
              }) else { return }
        selectedClipID = placement.clip.id
        selectedTool = .video
        applyVideoEdit(.split(clipID: placement.clip.id, at: currentTime))
    }

    private func togglePlayback() {
        guard project.duration > 0 else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        if !isPlaying && currentTime >= project.duration - 0.02 { seek(to: 0) }
        isPlaying.toggle()
    }

    private func handleTransport(_ command: EditorTransportCommand) {
        switch command {
        case .togglePlayback: togglePlayback()
        case .step(let frames):
            seek(to: EditorTransportCommand.steppedTime(currentTime, frames: frames,
                frameRate: project.settings.frameRate, duration: project.duration))
        case .jump(let seconds): seek(to: currentTime + seconds)
        case .beginning: seek(to: 0)
        case .end: seek(to: project.duration)
        case .split: splitVideoAtPlayhead()
        case .undo: undoVideoEdit()
        case .redo: redoVideoEdit()
        case .deselect:
            selectedZoomID = nil
            selectedChapterID = nil
            selectedClipID = nil
        }
    }

    private var playbackBar: some View {
        HStack(spacing: 10) {
            Button { seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(EditorTransportButtonStyle())
                .help("Go to beginning · Home")
                .accessibilityLabel("Go to beginning")
            Button { handleTransport(.step(-1)) } label: { Image(systemName: "backward.frame.fill") }
                .buttonStyle(EditorTransportButtonStyle())
                .help("Previous frame · ←")
                .accessibilityLabel("Previous frame")
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace.offUp))
                    .symbolEffectsRemoved(reduceMotion)
            }
            .buttonStyle(EditorTransportButtonStyle(prominent: true))
            .animation(reduceMotion ? nil : StudioMotion.press, value: isPlaying)
            .help("Play / Pause · Space")
            .accessibilityLabel(Text(LocalizedStringKey(isPlaying ? "Pause" : "Play")))
            .accessibilityIdentifier("editor.playback")
            Button { handleTransport(.step(1)) } label: { Image(systemName: "forward.frame.fill") }
                .buttonStyle(EditorTransportButtonStyle())
                .help("Next frame · →")
                .accessibilityLabel("Next frame")

            Divider().frame(height: 17)
            Button(action: undoVideoEdit) { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(EditorTransportButtonStyle())
                .disabled(!model.canUndoVideoEdit(projectID: project.id) || isApplyingVideoEdit)
                .help("Undo · ⌘Z")
                .accessibilityLabel("Undo edit")
                .accessibilityIdentifier("editor.undo")
            Button(action: redoVideoEdit) { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(EditorTransportButtonStyle())
                .disabled(!model.canRedoVideoEdit(projectID: project.id) || isApplyingVideoEdit)
                .help("Redo · ⇧⌘Z")
                .accessibilityLabel("Redo edit")
                .accessibilityIdentifier("editor.redo")

            Text(currentTime.editorTimecode)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(StudioTheme.text)
                .accessibilityIdentifier("editor.timecode")
                .frame(width: 82)
            Slider(value: seekBinding, in: 0...max(project.duration, 0.001))
                .tint(StudioTheme.purple)
                .controlSize(.small)
                .accessibilityLabel("Playback position")
            Text(project.duration.editorTimecode)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(StudioTheme.secondaryText)
            Button { showsShortcuts.toggle() } label: { Image(systemName: "keyboard") }
                .buttonStyle(EditorTransportButtonStyle())
                .help("Keyboard shortcuts")
                .accessibilityLabel("Keyboard shortcuts")
                .popover(isPresented: $showsShortcuts) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Keyboard shortcuts").font(.system(size: 13, weight: .semibold))
                        shortcut("Play / Pause", key: "Space")
                        shortcut("Previous / next frame", key: "←  →")
                        shortcut("Back / forward 5 seconds", key: "⇧ ←  ⇧ →")
                        shortcut("Beginning / end", key: "Home  End")
                        shortcut("Split clip", key: "S")
                        shortcut("Undo / Redo", key: "⌘Z  ⇧⌘Z")
                        shortcut("Delete selected block", key: "⌫")
                        shortcut("Deselect", key: "Esc")
                        Text("Shortcuts pause while you edit text.")
                            .font(.system(size: 10)).foregroundStyle(StudioTheme.secondaryText)
                    }
                    .padding(18).frame(width: 320)
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(StudioTheme.panelRaised.opacity(0.7))
    }

    private func shortcut(_ title: String, key: String) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
            Spacer()
            Text(LocalizedStringKey(key)).font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
        }.font(.system(size: 11))
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = L10n.tr("Export recording")
        panel.nameFieldStringValue = "\(project.title).mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // The model holds the export's state so automation leaves the editor
        // alone while it renders.
        let snapshot = project
        Task {
            do {
                let result = try await model.exportFromEditor(snapshot, to: url)
                exportMessage = L10n.format("Exported %lld × %lld at %lld fps to %@.", result.width, result.height, result.frameRate, result.outputURL.lastPathComponent)
            } catch {
                exportMessage = L10n.format("Export failed: %@", error.localizedDescription)
            }
        }
    }
}
