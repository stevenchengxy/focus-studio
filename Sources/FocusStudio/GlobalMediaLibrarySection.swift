import FocusStudioAutomation
import FocusStudioCore
import SwiftUI

/// The shared catalog is visible before a recording is opened. A project only
/// receives an item after the user selects it from the editor's media picker.
struct GlobalMediaLibrarySection: View {
    let assets: [DemoMediaAsset]
    let onImport: () -> Void
    let onCreateWithAI: () -> Void
    @State private var showAll = false

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
                        VStack(alignment: .leading, spacing: 7) {
                            EditorMediaPoster(asset: asset)
                                .frame(height: 100)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(asset.title).lineLimit(1)
                                .font(.system(size: 11, weight: .semibold))
                            Text(asset.kind == .image ? L10n.tr("Image") : asset.duration.editorTimecode)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(StudioTheme.secondaryText)
                        }
                        .padding(7)
                        .background(StudioTheme.panelRaised, in: RoundedRectangle(cornerRadius: 11))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("library.sharedMedia.asset.\(asset.id.uuidString)")
                    }
                }
            }
        }
    }
}
