import SwiftUI

/// Identity of the main window scene.
enum MainWindow {
    static let id = "main"
}

@main
struct FocusStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // One model for the app's lifetime, shared with the AppDelegate so the
    // library loads and AI tools are served even when no window is open
    // (AppServices also gives it the assistant's saved conversation).
    @StateObject private var model = AppServices.shared.model

    var body: some Scene {
        WindowGroup(id: MainWindow.id) {
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
                StudioSettingsView(model: model)
            }
        }
    }
}

struct StudioRootView: View {
    @EnvironmentObject private var model: StudioModel
    @ObservedObject private var installation = AppInstallationCoordinator.shared
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
                        session: model.assistantSession,
                        director: model.codexDirector,
                        modelLabel: model.assistantModelLabel,
                        onClose: { model.closeDirector() },
                        openSettings: {
                            AppSettingsNavigation.shared.selection = .aiModels
                            openSettings()
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
            .disabled(installation.isWorking)

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
        .overlay(alignment: .top) {
            // "Claude Code is working…" while an external AI call runs.
            // Information only: it never catches clicks, and it sits below
            // every top bar (at most 64 pt), not on the editor toolbar's controls.
            AutomationActivityBadge(activity: AppServices.shared.activity)
                .allowsHitTesting(false)
                .padding(.top, 72)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.destination == .library || model.destination == .director {
                InstallationNoticeView(isBusy: model.isInstallationBusy, isBusyNow: { model.isInstallationBusy })
            }
        }
        .animation(reduceMotion ? nil : StudioMotion.pageAnimation, value: model.destination)
        .animation(StudioMotion.fade, value: model.isBusy)
        // The recording control bar follows the model, not this window
        // (RecordingControlPanelCoordinator.follow, from AppServices), and so
        // does a capture failure (StudioModel.handleCaptureStateChange): both
        // work while no main window is open.
        .foregroundStyle(StudioTheme.text)
        .background(HostingWindowReader { MainWindowPresenter.shared.register($0) })
        .onAppear {
            // Lets an AI call open a main window when none is open.
            MainWindowPresenter.shared.openMainWindow = { [openWindow] in openWindow(id: MainWindow.id) }
        }
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
