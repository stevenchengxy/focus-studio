import AppKit
import FocusStudioAutomation
import FocusStudioCore
import SwiftUI

/// Shared assets stay outside project folders until explicitly imported into a demo.
struct GlobalMediaLibrarySection: View {
    let assets: [DemoMediaAsset]
    @Binding var selection: ProjectLibrarySelection
    let onImport: () -> Void
    let onCreateWithAI: () -> Void
    let onBeginManagement: () -> Void
    let onRename: (UUID, String) async -> Bool
    let failureMessage: () -> String
    let onDelete: (Set<UUID>) async -> Set<UUID>
    @State private var showAll = false
    @State private var pendingDeletionIDs: Set<UUID> = []
    @State private var confirmsDeletion = false
    @State private var previewAsset: DemoMediaAsset?
    @State private var renamingAsset: DemoMediaAsset?

    private let columns = [GridItem(.adaptive(minimum: 165, maximum: 220), spacing: 14)]

    /// Import appends to the catalog, so newest additions lead the home preview.
    static func visibleAssets(_ assets: [DemoMediaAsset], showAll: Bool) -> [DemoMediaAsset] {
        Array(assets.reversed().prefix(showAll ? assets.count : 8))
    }

    private var orderedIDs: [UUID] { assets.reversed().map(\.id) }
    private var selectedAsset: DemoMediaAsset? { assets.first { selection.ids.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Shared media library", systemImage: "square.stack.3d.up")
                    .font(.system(size: 16, weight: .semibold))
                Text(L10n.format("%lld items", assets.count))
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText)
                Spacer()
                if assets.count > 8 && !selection.isSelecting {
                    Button(showAll ? "Show less" : "View all") { showAll.toggle() }
                        .buttonStyle(.plain)
                        .foregroundStyle(StudioTheme.purple)
                }
                if !assets.isEmpty {
                    Button {
                        withAnimation(StudioMotion.fade) {
                            if selection.isSelecting { selection.finish() }
                            else { onBeginManagement(); selection.begin(); showAll = true }
                        }
                    } label: {
                        Label(LocalizedStringKey(selection.isSelecting ? "Done" : "Manage"),
                              systemImage: selection.isSelecting ? "checkmark" : "checklist")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("library.sharedMedia.manage")
                    .help("Select, rename, or move media to Trash")
                }
                Button(action: onImport) { Label("Import media", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("library.sharedMedia.import")
                Button(action: onCreateWithAI) { Label("Create with AI", systemImage: "sparkles") }
                    .buttonStyle(.bordered)
            }

            if selection.isSelecting {
                LibrarySelectionActions(
                    count: selection.ids.count,
                    totalCount: assets.count,
                    identifierPrefix: "library.sharedMedia",
                    onSelectAll: { selection.selectAll(orderedIDs) },
                    onDeselectAll: { selection.deselectAll() },
                    onRename: { renamingAsset = selectedAsset },
                    onDelete: { requestDeletion(selection.ids) },
                    onDone: { selection.finish() }
                )
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
                        assetCard(asset)
                    }
                }
            }
        }
        .sheet(item: $previewAsset) { asset in
            AssistantMediaPreviewSheet(url: URL(fileURLWithPath: asset.filePath), title: asset.title)
        }
        .sheet(item: $renamingAsset) { asset in
            RenameLibraryItemSheet(kind: .media, initialName: asset.title,
                                   failureMessage: failureMessage) { name in
                await onRename(asset.id, name)
            }
        }
        .alert("Move shared media to Trash?", isPresented: $confirmsDeletion) {
            Button("Cancel", role: .cancel) { pendingDeletionIDs = [] }
            Button("Move to Trash", role: .destructive) {
                let ids = pendingDeletionIDs
                pendingDeletionIDs = []
                Task {
                    let deleted = await onDelete(ids)
                    selection.remove(deleted)
                }
            }
        } message: {
            Text("Only shared copies will be moved to Trash. Media already added to a demo stays in that project.")
        }
        .onChange(of: assets.map(\.id)) { _, ids in
            selection.retainExisting(ids)
            if ids.isEmpty { selection.finish() }
        }
    }

    private func assetCard(_ asset: DemoMediaAsset) -> some View {
        let selected = selection.ids.contains(asset.id)
        return ZStack(alignment: .top) {
            Button {
                if selection.isSelecting || NSEvent.modifierFlags.contains(.command)
                    || NSEvent.modifierFlags.contains(.shift) {
                    select(asset)
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
            }
            .buttonStyle(.plain)
            .help(selection.isSelecting ? L10n.tr("Select media") : L10n.format("Preview %@", asset.title))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(selection.isSelecting ? L10n.format("Select %@", asset.title)
                                                     : L10n.format("Preview %@", asset.title))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("library.sharedMedia.asset.\(asset.id.uuidString)")

            HStack {
                Button { select(asset) } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(selected ? StudioTheme.purple : Color.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(selected ? "Deselect media" : "Select media")))
                .accessibilityIdentifier("library.sharedMedia.select.\(asset.id.uuidString)")
                Spacer()
                Menu {
                    Button("Preview") { previewAsset = asset }
                    Button("Rename") { renamingAsset = asset }
                    Button(LocalizedStringKey(selected ? "Deselect media" : "Select media")) { select(asset) }
                    Divider()
                    Button("Move to Trash", role: .destructive) { requestDeletion([asset.id]) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(.black.opacity(0.72), in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(L10n.format("Media actions: %@", asset.title))
                .accessibilityIdentifier("library.sharedMedia.actions.\(asset.id.uuidString)")
            }
            .padding(8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(selected ? StudioTheme.purple : .clear, lineWidth: 2)
                .padding(-4)
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button("Preview") { previewAsset = asset }
            Button("Rename") { renamingAsset = asset }
            Button(LocalizedStringKey(selected ? "Deselect media" : "Select media")) { select(asset) }
            Divider()
            Button("Move to Trash", role: .destructive) { requestDeletion([asset.id]) }
        }
    }

    private func select(_ asset: DemoMediaAsset) {
        if !selection.isSelecting { onBeginManagement() }
        selection.toggle(asset.id, in: orderedIDs,
                         extendingRange: NSEvent.modifierFlags.contains(.shift))
        if selection.isSelecting { showAll = true }
    }

    private func requestDeletion(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDeletionIDs = ids
        confirmsDeletion = true
    }
}
