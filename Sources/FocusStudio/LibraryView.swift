import FocusStudioCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: StudioModel
    @State private var selection = ProjectLibrarySelection()
    @State private var renamingProject: RecordingProject?
    @State private var pendingDeletion: [RecordingProject] = []
    @State private var confirmsDeletion = false
    @State private var trashedCount: Int?

    private var orderedIDs: [UUID] { model.projects.map(\.id) }
    private var selectedProjects: [RecordingProject] {
        model.projects.filter { selection.ids.contains($0.id) }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 270, maximum: 340), spacing: 18)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                Text("Focus Studio")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                AppLanguageMenu()
                    .foregroundStyle(StudioTheme.secondaryText)
                Button {
                    model.showDirector()
                } label: {
                    Label("Codex Director", systemImage: "sparkles.rectangle.stack")
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioTheme.purple)
                .font(.system(size: 12, weight: .semibold))

                Button {
                    Task { await model.importVideo() }
                } label: {
                    Label("Import video", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioTheme.secondaryText)
                .font(.system(size: 12, weight: .medium))

                Button {
                    Task { await model.importScreenshotDemo() }
                } label: {
                    Label("Screenshot demo", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioTheme.secondaryText)
                .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 28)
            .frame(height: 64)
            .background(StudioTheme.panel.opacity(0.7))
            .overlay(alignment: .bottom) { Divider().overlay(StudioTheme.line) }

            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    HStack(spacing: 26) {
                        VStack(alignment: .leading, spacing: 13) {
                            Text("Make every click easy to follow.")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .tracking(-0.8)
                            Text("Record. Clicks become cinematic zooms. Edit, caption, export.")
                                .font(.system(size: 14))
                                .foregroundStyle(StudioTheme.secondaryText)

                            HStack(spacing: 10) {
                                Button {
                                    model.showDirector()
                                } label: {
                                    Label("Create with Codex", systemImage: "sparkles")
                                }
                                .buttonStyle(PrimaryButtonStyle())

                                Button {
                                    Task { await model.showRecorder() }
                                } label: {
                                    Label("New recording", systemImage: "record.circle")
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(height: 34)
                                .padding(.horizontal, 14)
                                .background(Color.white.opacity(0.065))
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(StudioTheme.line, lineWidth: 1)
                                )

                                Button {
                                    Task { await model.importVideo() }
                                } label: {
                                    Label("Open video", systemImage: "folder")
                                        .font(.system(size: 13, weight: .semibold))
                                        .frame(height: 34)
                                        .padding(.horizontal, 14)
                                }
                                .buttonStyle(.plain)
                                .background(Color.white.opacity(0.065))
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(StudioTheme.line, lineWidth: 1)
                                )

                                Button {
                                    Task { await model.importScreenshotDemo() }
                                } label: {
                                    Label("Animate screenshot", systemImage: "photo.badge.plus")
                                        .font(.system(size: 13, weight: .semibold))
                                        .frame(height: 34)
                                        .padding(.horizontal, 14)
                                }
                                .buttonStyle(.plain)
                                .background(Color.white.opacity(0.065))
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(StudioTheme.line, lineWidth: 1)
                                )
                            }
                            .padding(.top, 5)
                        }

                        Spacer(minLength: 20)

                        ZStack {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [StudioTheme.purple, Color.cyan.opacity(0.76)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 280, height: 168)
                                .rotationEffect(.degrees(-3))
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(Color(red: 0.055, green: 0.06, blue: 0.07))
                                .frame(width: 236, height: 132)
                                .shadow(color: .black.opacity(0.35), radius: 16, y: 10)
                                .overlay {
                                    Image(systemName: "cursorarrow.motionlines")
                                        .font(.system(size: 52, weight: .light))
                                        .foregroundStyle(.white.opacity(0.78))
                                }
                        }
                        .padding(.trailing, 24)
                    }
                    .padding(32)
                    .background(StudioTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(StudioTheme.line, lineWidth: 1)
                    )

                    libraryControls

                    if model.projects.isEmpty {
                        VStack(spacing: 13) {
                            Image(systemName: "rectangle.stack.badge.plus")
                                .font(.system(size: 31, weight: .light))
                                .foregroundStyle(StudioTheme.secondaryText)
                            Text("Your first recording will appear here")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 190)
                        .studioPanel()
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(model.projects) { project in
                                ProjectCard(
                                    project: project,
                                    isSelecting: selection.isSelecting,
                                    isSelected: selection.ids.contains(project.id),
                                    onActivate: { activate(project) },
                                    onOpen: { model.open(project) },
                                    onSelect: { select(project) },
                                    onRename: { renamingProject = project },
                                    onDelete: { requestDeletion([project]) }
                                )
                            }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 1_220)
                .frame(maxWidth: .infinity)
            }
            if selection.isSelecting {
                Divider().overlay(StudioTheme.line)
                selectionActions
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(StudioTheme.panel)
            }
        }
        .disabled(model.isManagingProjects)
        .onChange(of: orderedIDs) { _, ids in selection.retainExisting(ids) }
        .sheet(item: $renamingProject) { project in
            RenameRecordingSheet(project: project, failureMessage: { model.errorMessage }) { name in
                let succeeded = await model.renameProject(id: project.id, to: name)
                // A sheet owns its own error; avoid stacking a root alert behind it.
                if !succeeded { model.isShowingError = false }
                return succeeded
            }
        }
        .alert("Move recordings to Trash?", isPresented: $confirmsDeletion) {
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
            Button("Move to Trash", role: .destructive) {
                let ids = Set(pendingDeletion.map(\.id))
                pendingDeletion = []
                Task {
                    let deleted = await model.deleteProjects(ids: ids)
                    selection.remove(deleted)
                    if !deleted.isEmpty { trashedCount = deleted.count }
                }
            }
        } message: {
            Text(verbatim: deletionMessage)
        }
    }

    private var deletionMessage: String {
        [
            L10n.format("%lld recordings selected for deletion.", pendingDeletion.count),
            pendingDeletion.prefix(5).map(\.title).joined(separator: "\n"),
            L10n.tr("The selected recordings and media inside their project folders will be moved to the Trash. You can restore those folders from the Trash.")
        ].joined(separator: "\n\n")
    }

    private var libraryControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Recent projects")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(model.projects.count) projects")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.secondaryText)
                if !model.projects.isEmpty {
                    Button {
                        if selection.isSelecting { selection.finish() } else { selection.begin() }
                    } label: {
                        Label(LocalizedStringKey(selection.isSelecting ? "Done selecting" : "Select recordings"), systemImage: selection.isSelecting ? "checkmark" : "checklist")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("library.selectionMode")
                    .help(LocalizedStringKey(selection.isSelecting
                        ? "Selection mode: click cards to select; Shift-click selects a range."
                        : "Use the checkboxes to select recordings, or Command-click a card."))
                }
            }
            if let trashedCount {
                HStack {
                    Label {
                        Text("\(trashedCount) recordings moved to Trash.")
                    } icon: { Image(systemName: "checkmark.circle.fill") }
                    Spacer()
                    Button { self.trashedCount = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                }
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.secondaryText)
            }
        }
    }

    /// Keep batch actions visible even at the bottom of a long recording library.
    private var selectionActions: some View {
        HStack(spacing: 12) {
            Text("\(selection.ids.count) selected")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityIdentifier("library.selectionCount")
            Button("Select all") { selection.selectAll(orderedIDs) }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(renamingProject != nil || confirmsDeletion || model.projects.isEmpty)
                .accessibilityIdentifier("library.selectAll")
            Button("Deselect all") { selection.deselectAll() }
                .disabled(selection.ids.isEmpty)
                .accessibilityIdentifier("library.deselectAll")
            Spacer()
            Button {
                renamingProject = selectedProjects.first
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(selection.ids.count != 1)
            .accessibilityIdentifier("library.renameSelected")
            Button(role: .destructive) { requestDeletion(selectedProjects) } label: {
                Label("Delete selected", systemImage: "trash")
            }
            .disabled(selection.ids.isEmpty)
            .accessibilityIdentifier("library.deleteSelected")
            Button("Done selecting") { selection.finish() }
                .accessibilityIdentifier("library.finishSelection")
        }
        .buttonStyle(.bordered)
    }

    private func activate(_ project: RecordingProject) {
        let flags = NSEvent.modifierFlags
        if selection.isSelecting || flags.contains(.command) || flags.contains(.shift) {
            select(project)
        } else {
            model.open(project)
        }
    }

    private func select(_ project: RecordingProject) {
        trashedCount = nil
        selection.toggle(project.id, in: orderedIDs, extendingRange: NSEvent.modifierFlags.contains(.shift))
    }

    private func requestDeletion(_ projects: [RecordingProject]) {
        guard !projects.isEmpty else { return }
        pendingDeletion = projects
        confirmsDeletion = true
    }
}

private struct ProjectCard: View {
    let project: RecordingProject
    let isSelecting: Bool
    let isSelected: Bool
    let onActivate: () -> Void
    let onOpen: () -> Void
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @ObservedObject private var posters = ProjectPosterStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            Button(action: onActivate) { content }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.project.\(project.id)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])

            HStack {
                Button(action: onSelect) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.9))
                        .frame(width: 30, height: 30)
                        .background(isSelected ? StudioTheme.purple : Color.black.opacity(0.35))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(isSelected ? "Deselect recording" : "Select recording")))
                .accessibilityValue(Text(verbatim: project.title))
                .accessibilityIdentifier("library.select.\(project.id)")
                Spacer()
                Menu {
                    Button("Open recording", action: onOpen)
                    Button("Rename", action: onRename)
                    Button(LocalizedStringKey(isSelected ? "Deselect recording" : "Select recording"), action: onSelect)
                    Divider()
                    Button("Move to Trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Color.black.opacity(0.35))
                        .clipShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Recording actions")
                .accessibilityValue(Text(verbatim: project.title))
                .accessibilityIdentifier("library.actions.\(project.id)")
            }
            .padding(8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(isSelected ? StudioTheme.purple : Color.clear, lineWidth: 2)
                .padding(-4)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : StudioMotion.selection, value: isSelected)
        .hoverLift()
        .task(id: project.id) { posters.requestPoster(for: project) }
        .contextMenu {
            Button("Open recording", action: onOpen)
            Button("Rename", action: onRename)
            Button(LocalizedStringKey(isSelected ? "Deselect recording" : "Select recording"), action: onSelect)
            Divider()
            Button("Move to Trash", role: .destructive, action: onDelete)
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    LinearGradient(
                        colors: [StudioTheme.purpleSoft.opacity(0.72), Color.blue.opacity(0.40)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    if let poster = posters.poster(for: project) {
                        Image(nsImage: poster)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    } else {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 31))
                            .foregroundStyle(.white.opacity(0.88))
                    }
                }
                .frame(height: 145)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .animation(StudioMotion.fade, value: posters.poster(for: project) == nil)

                VStack(alignment: .leading, spacing: 5) {
                    Text(project.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .help(project.title)
                    HStack {
                        Text(project.createdAt, style: .date)
                        Text("•")
                        Text(project.duration.formattedDuration)
                        Spacer()
                        Text("\(project.zoomSegments.count) zooms")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText)
                }
                .padding(.horizontal, 3)
                .padding(.top, 11)
                .padding(.bottom, 3)
            }
            .contentShape(Rectangle())
    }
}

private struct RenameRecordingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: RecordingProject
    let failureMessage: () -> String
    let save: (String) async -> Bool
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { !trimmedName.isEmpty && trimmedName.count <= 120 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename recording").font(.system(size: 19, weight: .semibold))
            Text("Enter a name for this recording.")
                .font(.system(size: 12))
                .foregroundStyle(StudioTheme.secondaryText)
            TextField("Recording name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .accessibilityIdentifier("library.rename.name")
                .onSubmit { submit() }
            HStack {
                if trimmedName.isEmpty {
                    Text("A recording name cannot be empty.").foregroundStyle(StudioTheme.red)
                } else if trimmedName.count > 120 {
                    Text("Names can contain up to 120 characters.").foregroundStyle(StudioTheme.red)
                }
                Spacer()
                Text("\(trimmedName.count) of 120 characters")
                    .foregroundStyle(StudioTheme.secondaryText)
            }
            .font(.system(size: 11))
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("Save", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid || isSaving)
                    .accessibilityIdentifier("library.rename.save")
            }
        }
        .padding(24)
        .frame(width: 430)
        .onAppear { name = project.title; nameFocused = true }
        .interactiveDismissDisabled(isSaving)
    }

    private func submit() {
        guard isValid, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            let succeeded = await save(trimmedName)
            isSaving = false
            if succeeded { dismiss() }
            else { errorMessage = failureMessage() }
        }
    }
}

extension Double {
    var formattedDuration: String {
        guard isFinite else { return "0:00" }
        let seconds = max(0, Int(self.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
