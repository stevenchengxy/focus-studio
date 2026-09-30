import FocusStudioAutomation
import FocusStudioCore
import SwiftUI

/// The shared catalog is visible before a recording is opened. A project only
/// receives an item after the user selects it from the editor's media picker.
struct GlobalMediaLibrarySection: View {
    let assets: [DemoMediaAsset]
    let onImport: () -> Void
    let onCreateWithAI: () -> Void
    let onDelete: (Set<UUID>) async -> Set<UUID>
    @State private var showAll = false
    @State private var isManaging = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var pendingDeletionIDs: Set<UUID> = []
    @State private var confirmsDeletion = false
    @State private var previewAsset: DemoMediaAsset?

    private let columns = [GridItem(.adaptive(minimum: 165, maximum: 220), spacing: 14)]

    /// The catalog appends on import, so newest additions lead the home
    /// preview even when there are more items than its eight visible cards.
    static func visibleAssets(_ assets: [DemoMediaAsset], showAll: Bool) -> [DemoMediaAsset] {
        Array(assets.reversed().prefix(showAll ? assets.count : 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Shared media library", systemImage: "square.stack.3d.up")
                    .font(.system(size: 16, weight: .semibold))
                Text(L10n.format("%lld items", assets.count))
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText)
                Spacer()
                if assets.count > 8 {
                    Button(showAll ? "Show less" : "View all") { showAll.toggle() }
                        .buttonStyle(.plain)
                        .foregroundStyle(StudioTheme.purple)
                }
                if !assets.isEmpty {
                    Button(isManaging ? "Done" : "Manage") {
                        withAnimation(StudioMotion.fade) {
                            isManaging.toggle()
                            selectedIDs = []
                            if isManaging { showAll = true }
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("library.sharedMedia.manage")
                }
                Button(action: onImport) {
                    Label("Import media", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("library.sharedMedia.import")
                Button(action: onCreateWithAI) {
                    Label("Create with AI", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
            }
            if isManaging {
                HStack(spacing: 12) {
                    Text(L10n.format("%lld selected", selectedIDs.count))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(StudioTheme.secondaryText)
                    Button("Select all") { selectedIDs = Set(assets.map(\.id)) }
                        .buttonStyle(.plain)
                    Button("Deselect all") { selectedIDs = [] }
                        .buttonStyle(.plain)
                        .disabled(selectedIDs.isEmpty)
                    Spacer()
                    Button(role: .destructive) { requestDeletion(selectedIDs) } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedIDs.isEmpty)
                    .accessibilityIdentifier("library.sharedMedia.deleteSelected")
                }
            }
            if assets.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 22, weight: .light))
                    Text("Images and videos you import or create with AI will appear here.")
                        .font(.system(size: 12))
                }
                .foregroundStyle(StudioTheme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 90)
                .background(StudioTheme.panelRaised, in: RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(Self.visibleAssets(assets, showAll: showAll)) { asset in
                        ZStack(alignment: .topTrailing) {
                        Button {
                            if isManaging {
                                if selectedIDs.contains(asset.id) { selectedIDs.remove(asset.id) }
                                else { selectedIDs.insert(asset.id) }
                            } else {
                                previewAsset = asset
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                EditorMediaPoster(asset: asset)
                                    .frame(height: 100)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay {
                                        if asset.kind == .video {
                                            Image(systemName: "play.fill")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .frame(width: 34, height: 34)
                                                .background(.black.opacity(0.72), in: Circle())
                                        }
                                    }
                                Text(asset.title).lineLimit(1)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(asset.kind == .image ? L10n.tr("Image") : asset.duration.editorTimecode)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(StudioTheme.secondaryText)
                            }
                            .padding(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(StudioTheme.panelRaised, in: RoundedRectangle(cornerRadius: 11))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11)
                                    .stroke(selectedIDs.contains(asset.id) ? StudioTheme.purple : .clear, lineWidth: 2)
                                    .allowsHitTesting(false)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(isManaging ? L10n.tr("Select media") : L10n.format("Preview %@", asset.title))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(isManaging ? L10n.format("Select %@", asset.title) : L10n.format("Preview %@", asset.title))
                        .accessibilityAddTraits(selectedIDs.contains(asset.id) ? .isSelected : [])
                        .accessibilityIdentifier("library.sharedMedia.asset.\(asset.id.uuidString)")
                        if isManaging {
                            Image(systemName: selectedIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                                .background(selectedIDs.contains(asset.id) ? StudioTheme.purple : Color.black.opacity(0.6), in: Circle())
                                .padding(13)
                                .allowsHitTesting(false)
                        } else {
                            Menu {
                                Button("Preview") { previewAsset = asset }
                                Button("Move to Trash", role: .destructive) {
                                    requestDeletion([asset.id])
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 15, weight: .bold))
                                    .frame(width: 28, height: 28)
                                    .background(.black.opacity(0.72), in: Circle())
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .padding(12)
                            .accessibilityLabel(L10n.format("Media actions: %@", asset.title))
                            .accessibilityIdentifier("library.sharedMedia.actions.\(asset.id.uuidString)")
                        }
                        }
                        .contextMenu {
                            Button("Preview") { previewAsset = asset }
                            Button("Move to Trash", role: .destructive) { requestDeletion([asset.id]) }
                        }
                    }
                }
            }
        }
        .sheet(item: $previewAsset) { asset in
            AssistantMediaPreviewSheet(url: URL(fileURLWithPath: asset.filePath), title: asset.title)
        }
        .alert("Move shared media to Trash?", isPresented: $confirmsDeletion) {
            Button("Cancel", role: .cancel) { pendingDeletionIDs = [] }
            Button("Move to Trash", role: .destructive) {
                let ids = pendingDeletionIDs
                pendingDeletionIDs = []
                Task {
                    let deleted = await onDelete(ids)
                    selectedIDs.subtract(deleted)
                    if assets.isEmpty { isManaging = false }
                }
            }
        } message: {
            Text("Only shared copies will be moved to Trash. Media already added to a demo stays in that project.")
        }
        .onChange(of: assets.map(\.id)) { _, ids in
            selectedIDs.formIntersection(ids)
            if ids.isEmpty { isManaging = false }
        }
    }

    private func requestDeletion(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDeletionIDs = ids
        confirmsDeletion = true
    }
}
