import AppKit
import FocusStudioAutomation
import SwiftUI

/// The external AI calls running now, for the in-app indicator
/// ("Claude Code is working…").
@MainActor
final class AutomationActivity: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let clientName: String
        let tool: String
        let startedAt: Date
    }

    @Published private(set) var running: [Entry] = []

    func begin(clientName: String, tool: String) -> UUID {
        let entry = Entry(id: UUID(), clientName: clientName, tool: tool, startedAt: Date())
        running.append(entry)
        return entry.id
    }

    func end(_ id: UUID) {
        running.removeAll { $0.id == id }
    }

    /// Each client with a call running, once, in the order they started.
    var workingClientNames: [String] {
        var seen = Set<String>()
        return running.map(\.clientName).filter { seen.insert($0).inserted }
    }
}

/// A small badge over the main window while an AI tool works in the app.
struct AutomationActivityBadge: View {
    @ObservedObject var activity: AutomationActivity

    var body: some View {
        let names = activity.workingClientNames
        ZStack {
            if !names.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(label(for: names))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("automation.activity")
                .help(Text("An AI tool connected over MCP is using Focus Studio. You can watch each step here."))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: names)
    }

    private func label(for names: [String]) -> String {
        if names.count == 1 { return L10n.format("%@ is working…", names[0]) }
        return L10n.format("%@ are working…", names.joined(separator: ", "))
    }
}

/// Keeps a main window on screen for calls that change what it shows, so
/// the person can watch, without activating the app or taking keyboard
/// focus: an existing window is ordered to the front regardless, and when
/// none is open a new one is opened through SwiftUI.
/// - A hidden app (⌘H) is unhidden without activation first, and the window
///   is chosen once it has: its windows are not visible while hidden, and
///   opening another would stack a second editor on the same project.
///   Closed windows stay registered (weakly), so they are never candidates.
/// - A minimized window is ordered front once it has been restored: ordering
///   it during the restore animation leaves it behind the active app's windows.
@MainActor
final class MainWindowPresenter {
    static let shared = MainWindowPresenter()

    /// What ``present()`` does, given the app's state and its registered
    /// main windows (in registration order).
    enum Step: Equatable {
        case unhideFirst
        case orderFront(Int)
        case restore(Int)
        case openNew
        case nothing
    }

    private let windows = NSHashTable<NSWindow>.weakObjects()
    /// Opens a main window; set from a SwiftUI view's `openWindow`.
    var openMainWindow: (() -> Void)?
    private var ordersNextWindowFront = false
    private var unhideObserver: NSObjectProtocol?
    private var restoreObserver: NSObjectProtocol?

    /// A main window appeared (StudioRootView's host window).
    func register(_ window: NSWindow) {
        windows.add(window)
        if ordersNextWindowFront {
            ordersNextWindowFront = false
            window.orderFrontRegardless()
        }
    }

    static func step(appIsHidden: Bool, windows: [(isVisible: Bool, isMiniaturized: Bool)], canOpen: Bool) -> Step {
        if appIsHidden { return .unhideFirst }
        let candidates = windows.indices.filter { windows[$0].isVisible || windows[$0].isMiniaturized }
        if let shown = candidates.first(where: { !windows[$0].isMiniaturized }) { return .orderFront(shown) }
        if let minimized = candidates.first { return .restore(minimized) }
        return canOpen ? .openNew : .nothing
    }

    func present() {
        let registered = windows.allObjects
        let state = registered.map { (isVisible: $0.isVisible, isMiniaturized: $0.isMiniaturized) }
        switch Self.step(appIsHidden: NSApp.isHidden, windows: state, canOpen: openMainWindow != nil) {
        case .unhideFirst:
            if unhideObserver == nil {
                unhideObserver = NotificationCenter.default.addObserver(forName: NSApplication.didUnhideNotification, object: NSApp, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let observer = self.unhideObserver { NotificationCenter.default.removeObserver(observer) }
                        self.unhideObserver = nil
                        self.present()
                    }
                }
            }
            NSApp.unhideWithoutActivation()
        case let .orderFront(index):
            registered[index].orderFrontRegardless()
        case let .restore(index):
            let window = registered[index]
            if let observer = restoreObserver { NotificationCenter.default.removeObserver(observer) }
            restoreObserver = NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if let observer = self?.restoreObserver { NotificationCenter.default.removeObserver(observer) }
                    self?.restoreObserver = nil
                    window?.orderFrontRegardless()
                }
            }
            window.deminiaturize(nil)
        case .openNew:
            ordersNextWindowFront = true
            openMainWindow?()
        case .nothing:
            break
        }
    }
}

/// Reports the NSWindow hosting a SwiftUI view.
struct HostingWindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
