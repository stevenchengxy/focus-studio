import AppKit
import AVFoundation
import FocusStudioAutomation
import FocusStudioCore
import SwiftUI

/// Imported files live with the editable project. Clicking inserts at the
/// playhead; dragging offers precise placement on the video track.
struct EditorMediaLibraryView: View {
    let assets: [DemoMediaAsset]
    let sharedAssets: [DemoMediaAsset]
    let isImporting: Bool
    let onImport: () -> Void
    let onCreateWithAI: () -> Void
    let onInsert: (UUID) -> Void
    let onImportShared: (UUID) -> Void
    let onSaveShared: (UUID) -> Void
    @State private var showingShared = false
    @State private var projectPreviewAsset: DemoMediaAsset?
    @State private var sharedPreviewAsset: DemoMediaAsset?

    private let columns = [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button(action: onImport) {
                    Label(isImporting ? "Importing…" : "Import", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isImporting)
                .accessibilityIdentifier("media.import")
                Button(action: onCreateWithAI) {
                    Label("Create with AI", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("media.createWithAI")
            }
            .buttonStyle(.borderedProminent)
            .font(.system(size: 10))

            Button {
                showingShared = true
            } label: {
                Label("From shared library", systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .font(.system(size: 10))
            .accessibilityIdentifier("media.importShared")

            if assets.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 24))
                    Text("Your media will appear here")
                        .font(.system(size: 10, weight: .medium))
                    Text("Import a video or image, then drag it onto the video track.")
                        .font(.system(size: 9))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(StudioTheme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .padding(.horizontal, 8)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            } else {
                Text("Click to add at the playhead, or drag onto the video track.")
                    .font(.system(size: 9))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(assets) { asset in
                        mediaCard(asset)
                            .contextMenu {
                                Button("Preview") { projectPreviewAsset = asset }
                                Button("Save to shared library") { onSaveShared(asset.id) }
                            }
                    }
                }
            }
        }
        .sheet(isPresented: $showingShared) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Shared media library").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button("Done") { showingShared = false }
                }
                if sharedAssets.isEmpty {
                    Text("No shared media yet. Import on the home screen or ask the AI assistant to create a clip.")
                        .foregroundStyle(StudioTheme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                            ForEach(sharedAssets) { asset in
                                VStack(alignment: .leading, spacing: 6) {
                                    Button { sharedPreviewAsset = asset } label: {
                                        EditorMediaPoster(asset: asset)
                                            .frame(height: 80)
                                            .clipShape(RoundedRectangle(cornerRadius: 7))
                                            .overlay {
                                                if asset.kind == .video {
                                                    Image(systemName: "play.fill")
                                                        .font(.system(size: 11, weight: .semibold))
                                                        .foregroundStyle(.white)
                                                        .frame(width: 30, height: 30)
                                                        .background(.black.opacity(0.72), in: Circle())
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(L10n.format("Preview %@", asset.title))
                                    Text(asset.title).lineLimit(1)
                                        .font(.system(size: 11))
                                    HStack(spacing: 4) {
                                        Text(asset.kind == .image ? L10n.tr("Image") : asset.duration.editorTimecode)
                                            .font(.system(size: 10))
                                            .foregroundStyle(StudioTheme.secondaryText)
                                        Spacer(minLength: 2)
                                        Button("Add") {
                                            onImportShared(asset.id)
                                            showingShared = false
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.mini)
                                        .accessibilityIdentifier("media.shared.add.\(asset.id.uuidString)")
                                    }
                                }
                                .padding(6)
                                .background(StudioTheme.panelRaised, in: RoundedRectangle(cornerRadius: 9))
                                .accessibilityIdentifier("media.shared.\(asset.id.uuidString)")
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 480, minHeight: 330)
            .sheet(item: $sharedPreviewAsset) { asset in
                AssistantMediaPreviewSheet(url: URL(fileURLWithPath: asset.filePath), title: asset.title)
            }
        }
        .sheet(item: $projectPreviewAsset) { asset in
            AssistantMediaPreviewSheet(url: URL(fileURLWithPath: asset.filePath), title: asset.title)
        }
    }

    private func mediaCard(_ asset: DemoMediaAsset) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            EditorMediaPoster(asset: asset)
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: asset.kind == .video ? "film.fill" : "photo.fill")
                        .font(.system(size: 9))
                        .padding(4)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
            Text(asset.title)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
            Group {
                if asset.kind == .image {
                    Text("Still image")
                } else {
                    Text(asset.duration.editorTimecode)
                }
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(StudioTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(5)
        .background(StudioTheme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { onInsert(asset.id) }
        .onDrag { NSItemProvider(object: asset.id.uuidString as NSString) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(asset.title), \(asset.kind == .image ? "image" : "video")")
        .accessibilityHint("Click to insert at playhead, or drag to the video track")
        .accessibilityIdentifier("media.asset.\(asset.id.uuidString)")
    }
}

struct EditorMediaPoster: View {
    let asset: DemoMediaAsset
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.35))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: asset.kind == .image ? "photo" : "film")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .clipped()
        .task(id: asset.filePath) {
            let key = "poster:\(asset.filePath)" as NSString
            if let cached = EditorFrameCache.images.object(forKey: key) {
                image = cached
                return
            }
            if asset.kind == .image {
                image = EditorFrameCache.stillThumbnail(at: asset.filePath)
            } else {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: asset.filePath)))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 220, height: 130)
                let sample = CMTime(seconds: min(0.5, asset.duration / 2), preferredTimescale: 600)
                if let (frame, _) = try? await generator.image(at: sample) {
                    image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
                }
            }
            if let image {
                EditorFrameCache.images.setObject(image, forKey: key,
                    cost: Int(image.size.width * image.size.height * 4))
            }
        }
    }
}
