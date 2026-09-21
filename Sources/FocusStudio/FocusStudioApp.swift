import SwiftUI

@main
struct FocusStudioApp: App {
    @StateObject private var model = StudioModel()

    var body: some Scene {
        WindowGroup {
            AppLocalizedView {
                StudioRootView()
                    .environmentObject(model)
                    .preferredColorScheme(.dark)
                    .frame(minWidth: 1_080, minHeight: 700)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1_440, height: 900)
        .commands { AppLanguageCommands() }

        Settings {
            AppLocalizedView {
                CodexConnectionSettingsView(director: model.codexDirector, showsDoneButton: false)
                    .preferredColorScheme(.dark)
            }
        }
    }
}

struct StudioRootView: View {
    @EnvironmentObject private var model: StudioModel

    var body: some View {
        ZStack {
            StudioTheme.window.ignoresSafeArea()

            switch model.destination {
            case .library:
                LibraryView()
            case .director:
                CodexDirectorView(
                    director: model.codexDirector,
                    onClose: { model.closeDirector() },
                    onCreatePlan: { prompt in
                        Task { await model.createCodexPlan(from: prompt) }
                    },
                    onRunPlan: { plan in
                        model.startCodexPlan(plan)
                    }
                )
            case .recorder:
                RecordingPickerView()
            case .countdown:
                RecordingCountdownView()
            case .recording:
                ActiveRecordingView()
            case .editor:
                if let project = model.activeProject {
                    EditorView(
                        // A disappearing editor can still read its bindings.
                        project: model.editorBinding(for: project)
                    )
                    .id(project.id)
                } else {
                    ProgressView("Opening project…")
                }
            }

            if model.isBusy {
                Color.black.opacity(0.32).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(LocalizedStringKey(model.busyMessage))
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
        }
        .foregroundStyle(StudioTheme.text)
        .task { await model.bootstrap() }
        .alert("Focus Studio", isPresented: $model.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage)
        }
    }
}
