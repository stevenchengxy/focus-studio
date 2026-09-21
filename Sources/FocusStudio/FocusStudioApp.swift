import SwiftUI

@main
struct FocusStudioApp: App {
    @StateObject private var model = StudioModel()

    var body: some Scene {
        WindowGroup {
            AppLocalizedView {
                TextCompletionInjector(store: model.aiGateway) {
                    StudioRootView()
                        .environmentObject(model)
                        .preferredColorScheme(.dark)
                        .frame(minWidth: 1_080, minHeight: 700)
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1_440, height: 900)
        .commands { AppLanguageCommands() }

        // The assistant lives in its own window so it can drive the app
        // (record, open projects, edit, export) while the main window changes pages.
        Window("AI Assistant", id: AssistantWindow.id) {
            AppLocalizedView {
                AssistantWindowView(model: model, gateway: model.aiGateway, codexDirector: model.codexDirector)
            }
        }
        .defaultSize(width: AssistantWindow.defaultSize.width, height: AssistantWindow.defaultSize.height)

        Settings {
            AppLocalizedView {
                TabView {
                    AIGatewaySettingsView(store: model.aiGateway)
                        .tabItem { Label("AI models", systemImage: "sparkles") }
                    CodexConnectionSettingsView(director: model.codexDirector, showsDoneButton: false)
                        .tabItem { Label("Codex", systemImage: "terminal") }
                }
                .preferredColorScheme(.dark)
            }
        }
    }
}

struct StudioRootView: View {
    @EnvironmentObject private var model: StudioModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            StudioTheme.window.ignoresSafeArea()

            // Each destination is its own identity so SwiftUI cross-fades the
            // pages instead of morphing unrelated controls into each other.
            Group {
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
            }
            .id(model.destination)
            .transition(StudioMotion.page(reduceMotion: reduceMotion))

            if model.isBusy {
                Color.black.opacity(0.32).ignoresSafeArea()
                    .transition(.opacity)
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(LocalizedStringKey(model.busyMessage))
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(reduceMotion ? nil : StudioMotion.pageAnimation, value: model.destination)
        .animation(StudioMotion.fade, value: model.isBusy)
        .foregroundStyle(StudioTheme.text)
        .task {
            await model.bootstrap()
            // QA hook: FOCUS_STUDIO_OPEN_SETTINGS=1 opens the Settings window on launch.
            if ProcessInfo.processInfo.environment["FOCUS_STUDIO_OPEN_SETTINGS"] == "1" {
                openSettings()
            }
            // QA hook: FOCUS_STUDIO_ASSISTANT_PROMPT="…" opens the assistant window and
            // sends that prompt, so an end-to-end run can be captured on screen.
            if let prompt = ProcessInfo.processInfo.environment["FOCUS_STUDIO_ASSISTANT_PROMPT"],
               !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                openWindow(id: AssistantWindow.id)
                model.assistantSession.send(prompt)
            }
        }
        .alert("Focus Studio", isPresented: $model.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage)
        }
    }
}
