import AppKit
import AVFoundation
import FocusStudioAutomation
import FocusStudioCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// AVFoundation decodes are expensive on a long take. A bounded shared cache
/// lets zoom and scrolling reuse frames instead of seeking the movie again.
enum EditorFrameCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 180
        cache.totalCostLimit = 40 * 1024 * 1024
        return cache
    }()

    static func stillThumbnail(at path: String) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320
        ]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
    }
}

/// The source image is sampled independently of the editor preview so the
/// filmstrip stays responsive while a new take is rendered or scrubbed.
private struct ClipFilmstrip: View {
    let videoPath: String
    let isStillImage: Bool
    let sourceStart: Double
    let sourceEnd: Double
    let count: Int
    @State private var images: [NSImage?] = []

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<count, id: \.self) { index in
                Group {
                    if images.indices.contains(index), let image = images[index] {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(colors: [.black.opacity(0.25), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
        }
        .clipped()
        .task(id: "\(videoPath):\(sourceStart):\(sourceEnd):\(count)") {
            images = Array(repeating: nil, count: count)
            // Dragging the zoom slider can change the frame count repeatedly;
            // wait for the layout to settle before seeking the source movie.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            guard !videoPath.isEmpty else { return }
            if isStillImage {
                let key = "image:\(videoPath)" as NSString
                let image = EditorFrameCache.images.object(forKey: key)
                    ?? EditorFrameCache.stillThumbnail(at: videoPath)
                if let image {
                    EditorFrameCache.images.setObject(image, forKey: key,
                        cost: Int(image.size.width * image.size.height * 4))
                    images = Array(repeating: image, count: count)
                }
                return
            }
            let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 220, height: 110)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
            for index in 0..<count {
                guard !Task.isCancelled else { return }
                let sample = sourceStart + (Double(index) + 0.5) / Double(count) * (sourceEnd - sourceStart)
                let key = "video:\(videoPath):\(Int((sample * 4).rounded()))" as NSString
                if let cached = EditorFrameCache.images.object(forKey: key) {
                    images[index] = cached
                    continue
                }
                let time = CMTime(seconds: max(0, sample), preferredTimescale: 600)
                guard let (frame, _) = try? await generator.image(at: time) else { continue }
                let image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
                EditorFrameCache.images.setObject(image, forKey: key, cost: frame.width * frame.height * 4)
                images[index] = image
            }
        }
        .accessibilityHidden(true)
    }
}

/// An ordered filmstrip of real clips. A drag on the middle reorders; drags
/// on either edge preview a source trim and commit it only when released.
struct EditorVideoTimelineView: View {
    let project: RecordingProject
    let placements: [DemoVideoClipPlacement]
    let transitions: [DemoVideoTransition]
    let timelineWidth: Double
    let visibleX: ClosedRange<Double>
    let currentTime: Double
    @Binding var selectedClipID: UUID?
    let onSelect: (UUID) -> Void
    let onSeek: (Double) -> Void
    let onEdit: (DemoVideoEditOperation) -> Void
    let onInsertMedia: (UUID, Int) -> Void
    let isEditing: Bool
    @State private var isMediaDropTarget = false

    private var duration: Double { max(project.duration, 0.001) }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.035))
            clipBlocks
            transitionMenus
        }
        .frame(width: timelineWidth, height: 48, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isMediaDropTarget ? StudioTheme.purple : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .onDrop(of: [UTType.plainText], delegate: EditorMediaDropDelegate(
            isTargeted: $isMediaDropTarget,
            perform: handleMediaDrop
        ))
        .coordinateSpace(name: "video-timeline")
        .clipped()
        .accessibilityIdentifier("timeline.videoClips")
    }

    private var clipBlocks: some View {
        ForEach(Array(placements.enumerated()), id: \.element.clip.id) { index, placement in
            if isVisible(placement) {
                VideoClipBlock(
                    placement: placement,
                    index: index,
                    clipCount: placements.count,
                    placements: placements,
                    project: project,
                    timelineWidth: timelineWidth,
                    duration: duration,
                    currentTime: currentTime,
                    selected: selectedClipID == placement.clip.id,
                    isEditing: isEditing,
                    onSelect: { onSelect(placement.clip.id) },
                    onSeek: onSeek,
                    onEdit: onEdit
                )
                .offset(x: placement.start / duration * timelineWidth)
                .zIndex(selectedClipID == placement.clip.id ? 1 : 0)
            }
        }
    }

    private var transitionMenus: some View {
        ForEach(Array(placements.dropLast().enumerated()), id: \.element.clip.id) { index, placement in
            if isVisible(placement) {
                transitionMenu(after: placement, index: index)
            }
        }
    }

    private func transitionMenu(after placement: DemoVideoClipPlacement, index: Int) -> some View {
        let transition = transitions.first { $0.fromClipID == placement.clip.id }
        let maximum = maximumTransitionDuration(after: index)
        return Menu {
            Button("Cut") { onEdit(.setTransition(fromClipID: placement.clip.id, preset: .cut, duration: 0)) }
            Button("Fade to black") {
                onEdit(.setTransition(fromClipID: placement.clip.id, preset: .fadeToBlack, duration: min(0.5, maximum)))
            }
            .disabled(maximum < 0.1)
            Button("Flash") {
                onEdit(.setTransition(fromClipID: placement.clip.id, preset: .flash, duration: min(0.3, maximum)))
            }
            .disabled(maximum < 0.1)
        } label: {
            Image(systemName: transitionSymbol(transition?.preset ?? .cut))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 19, height: 19)
                .background(transition?.preset == .cut || transition == nil ? StudioTheme.panelRaised : StudioTheme.purple,
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.55), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isEditing)
        .offset(x: placement.end / duration * timelineWidth - 10)
        .zIndex(4)
        .help(L10n.format("Transition after clip %lld", index + 1))
        .accessibilityLabel("Transition after clip")
        .accessibilityIdentifier("video.transition.\(placement.clip.id.uuidString)")
    }

    private func handleMediaDrop(_ info: DropInfo) -> Bool {
        guard !isEditing, let provider = info.itemProviders(for: [UTType.plainText]).first else { return false }
        let time = (Double(info.location.x) / timelineWidth * duration).clamped(to: 0...duration)
        let insertionIndex = placements.firstIndex { time < ($0.start + $0.end) / 2 } ?? placements.count
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            let value = (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                ?? (item as? String) ?? (item as? NSString).map(String.init)
            guard let value, let id = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  project.mediaAssets?.contains(where: { $0.id == id }) == true else { return }
            DispatchQueue.main.async { onInsertMedia(id, insertionIndex) }
        }
        return true
    }

    private func isVisible(_ placement: DemoVideoClipPlacement) -> Bool {
        let start = placement.start / duration * timelineWidth
        let end = placement.end / duration * timelineWidth
        return end >= visibleX.lowerBound - 240 && start <= visibleX.upperBound + 240
    }

    private func maximumTransitionDuration(after index: Int) -> Double {
        guard index >= 0, index + 1 < placements.count else { return 0 }
        let incoming = index > 0 ? transitions[index - 1].duration / 2 : 0
        let nextOutgoing = index + 1 < transitions.count ? transitions[index + 1].duration / 2 : 0
        return max(0, min(2,
            2 * (placements[index].duration - incoming),
            2 * (placements[index + 1].duration - nextOutgoing)))
    }
}

private struct EditorMediaDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let perform: (DropInfo) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText])
    }

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        return perform(info)
    }
}

private struct VideoClipBlock: View {
    let placement: DemoVideoClipPlacement
    let index: Int
    let clipCount: Int
    let placements: [DemoVideoClipPlacement]
    let project: RecordingProject
    let timelineWidth: Double
    let duration: Double
    let currentTime: Double
    let selected: Bool
    let isEditing: Bool
    let onSelect: () -> Void
    let onSeek: (Double) -> Void
    let onEdit: (DemoVideoEditOperation) -> Void

    @State private var leadingTrim: Double?
    @State private var trailingTrim: Double?
    @State private var moveOffset = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var width: Double { max(1, placement.duration / duration * timelineWidth) }
    private var pixelsPerSecond: Double { timelineWidth / duration }
    private var clip: DemoVideoClip { placement.clip }
    private var canShowHandles: Bool { width >= 31 && mediaAsset?.kind != .image }
    private var mediaAsset: DemoMediaAsset? {
        guard let mediaAssetID = clip.mediaAssetID else { return nil }
        return project.mediaAssets?.first { $0.id == mediaAssetID }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(StudioTheme.yellow.opacity(selected ? 0.95 : 0.75))
            if width > 48 {
                ClipFilmstrip(videoPath: mediaAsset?.filePath ?? project.sourceVideoPath,
                              isStillImage: mediaAsset?.kind == .image,
                              sourceStart: clip.sourceStart,
                              sourceEnd: clip.sourceEnd,
                              count: min(6, max(1, Int(width / 90))))
                    .opacity(0.75)
                    .overlay(LinearGradient(colors: [.black.opacity(0.56), .black.opacity(0.13)],
                                            startPoint: .leading, endPoint: .trailing))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            if let leadingTrim {
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(0, (leadingTrim - clip.sourceStart) * pixelsPerSecond))
            }
            if let trailingTrim {
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(0, (clip.sourceEnd - trailingTrim) * pixelsPerSecond))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(spacing: 0) {
                if canShowHandles { trimHandle(leading: true) }
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(index + 1) · \(mediaAsset?.title ?? "Recording") · \(clip.duration.formatted(.number.precision(.fractionLength(2))))s")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                    if width > 125 {
                        Text("\(clip.sourceStart.editorTimecode) – \(clip.sourceEnd.editorTimecode)")
                            .font(.system(size: 8, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.75), radius: 3)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect()
                    onSeek(placement.start)
                }
                .gesture(
                    DragGesture(minimumDistance: 7, coordinateSpace: .named("video-timeline"))
                        .onChanged { value in
                            onSelect()
                            moveOffset = value.translation.width
                        }
                        .onEnded { value in
                            moveOffset = 0
                            let targetTime = (placement.start + placement.duration / 2
                                              + Double(value.translation.width) / pixelsPerSecond)
                                .clamped(to: 0...duration)
                            let destination = placements.firstIndex { targetTime < $0.end } ?? clipCount - 1
                            if destination != index {
                                onEdit(.move(clipID: clip.id, toIndex: destination))
                            }
                        }
                )
                if canShowHandles { trimHandle(leading: false) }
            }
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(selected ? .white : .white.opacity(0.25), lineWidth: selected ? 2 : 1)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: 46)
        .offset(x: moveOffset)
        .animation(reduceMotion ? nil : StudioMotion.hover, value: selected)
        .disabled(isEditing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("Clip %lld, %.2f seconds", index + 1, clip.duration))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("video.clip.\(clip.id.uuidString)")
        .help(mediaAsset?.kind == .image
              ? "Select or drag to reorder. Adjust image duration in the inspector."
              : L10n.format("Select or drag to reorder. Drag the edges to trim. Source %@–%@.",
                            clip.sourceStart.editorTimecode, clip.sourceEnd.editorTimecode))
        .contextMenu {
            Button("Split at playhead") {
                onEdit(.split(clipID: clip.id, at: currentTime))
            }
            .disabled(currentTime <= placement.start + 0.1 || currentTime >= placement.end - 0.1)
            if index > 0 { Button("Move left") { onEdit(.move(clipID: clip.id, toIndex: index - 1)) } }
            if index < clipCount - 1 { Button("Move right") { onEdit(.move(clipID: clip.id, toIndex: index + 1)) } }
            Button("Remove clip", role: .destructive) { onEdit(.delete(clipID: clip.id)) }
                .disabled(clipCount <= 1)
        }
    }

    private func trimHandle(leading: Bool) -> some View {
        let active = leading ? leadingTrim : trailingTrim
        return RoundedRectangle(cornerRadius: 2)
            .fill(.white.opacity(active == nil ? 0.28 : 0.7))
            .overlay(RoundedRectangle(cornerRadius: 1).fill(.white).frame(width: 2, height: 20))
            .frame(width: 12, height: 42)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("video-timeline"))
                    .onChanged { value in
                        onSelect()
                        let delta = Double(value.translation.width) / pixelsPerSecond
                        if leading {
                            leadingTrim = (clip.sourceStart + delta).clamped(to: clip.sourceStart...(clip.sourceEnd - 0.1))
                        } else {
                            trailingTrim = (clip.sourceEnd + delta).clamped(to: (clip.sourceStart + 0.1)...clip.sourceEnd)
                        }
                    }
                    .onEnded { _ in
                        let start = leadingTrim ?? clip.sourceStart
                        let end = trailingTrim ?? clip.sourceEnd
                        leadingTrim = nil
                        trailingTrim = nil
                        if abs(start - clip.sourceStart) > 0.001 || abs(end - clip.sourceEnd) > 0.001 {
                            onEdit(.trim(clipID: clip.id, sourceStart: start, sourceEnd: end))
                        }
                    }
            )
            .accessibilityLabel(leading ? "Trim clip start" : "Trim clip end")
            .accessibilityValue((active ?? (leading ? clip.sourceStart : clip.sourceEnd)).editorTimecode)
            .accessibilityIdentifier("video.clip.\(clip.id.uuidString).\(leading ? "trimStart" : "trimEnd")")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.1 : -0.1
                if leading {
                    let start = (clip.sourceStart + delta).clamped(to: clip.sourceStart...(clip.sourceEnd - 0.1))
                    onEdit(.trim(clipID: clip.id, sourceStart: start, sourceEnd: clip.sourceEnd))
                } else {
                    let end = (clip.sourceEnd + delta).clamped(to: (clip.sourceStart + 0.1)...clip.sourceEnd)
                    onEdit(.trim(clipID: clip.id, sourceStart: clip.sourceStart, sourceEnd: end))
                }
            }
    }
}

private func transitionSymbol(_ preset: DemoTransitionPreset) -> String {
    switch preset {
    case .cut: "plus"
    case .fadeToBlack: "circle.lefthalf.filled"
    case .flash: "bolt.fill"
    }
}
