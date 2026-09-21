import AppKit
import FocusStudioCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @EnvironmentObject private var model: StudioModel
    @Binding var project: RecordingProject

    @State private var currentTime = 0.0
    @State private var isPlaying = false
    @State private var selectedZoomID: UUID?
    @State private var selectedChapterID: UUID?
    @State private var selectedTool: EditorTool = .zoom
    @State private var renderError: String?
    @State private var isExporting = false
    @State private var exportMessage: String?
    @Namespace private var toolHighlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        currentTime: $currentTime,
                        selectedZoomID: $selectedZoomID,
                        selectedChapterID: $selectedChapterID,
                        selectedTool: $selectedTool
                    )
                }

                Divider().overlay(StudioTheme.line)
                EditorInspectorView(
                    project: $project,
                    selectedZoomID: $selectedZoomID,
                    selectedChapterID: $selectedChapterID,
                    tool: selectedTool
                )
                .id(selectedTool)
                .transition(StudioMotion.panel(reduceMotion: reduceMotion))
                .frame(width: 292)
                .clipped()
            }
        }
        .animation(reduceMotion ? nil : StudioMotion.panelAnimation, value: selectedTool)
        .overlay {
            if isExporting {
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
        .onChange(of: selectedZoomID) { _, id in
            if id != nil { selectedTool = .zoom }
        }
        .onChange(of: selectedChapterID) { _, id in
            if id != nil { selectedTool = .captions }
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
                currentTime = max(0, currentTime - 5)
            } label: { Image(systemName: "gobackward.5") }
            .buttonStyle(IconButtonStyle())

            Button { isPlaying.toggle() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(IconButtonStyle())

            Button {
                currentTime = min(project.duration, currentTime + 5)
            } label: { Image(systemName: "goforward.5") }
            .buttonStyle(IconButtonStyle())

            Spacer()

            AppLanguageMenu()

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

    private var playbackBar: some View {
        HStack(spacing: 11) {
            Button { isPlaying.toggle() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))

            Text(currentTime.formattedDuration)
                .font(.system(size: 10, design: .monospaced))
            Slider(value: $currentTime, in: 0...max(project.duration, 0.001))
                .controlSize(.mini)
            Text(project.duration.formattedDuration)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(StudioTheme.secondaryText)
            Button { currentTime = 0 } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioTheme.secondaryText)
        }
        .padding(.horizontal, 15)
        .frame(height: 34)
        .background(StudioTheme.panel)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = L10n.tr("Export recording")
        panel.nameFieldStringValue = "\(project.title).mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        Task {
            do {
                let result = try await ProjectVideoRenderer.export(project: project, to: url)
                exportMessage = L10n.format("Exported %lld × %lld at %lld fps to %@.", result.width, result.height, result.frameRate, result.outputURL.lastPathComponent)
            } catch {
                exportMessage = L10n.format("Export failed: %@", error.localizedDescription)
            }
            isExporting = false
        }
    }
}
