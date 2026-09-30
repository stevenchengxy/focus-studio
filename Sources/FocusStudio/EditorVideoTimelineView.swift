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
    let width: Double
    let originX: Double
    let visibleX: ClosedRange<Double>
    @State private var images: [Int: NSImage] = [:]

    private let tileWidth = 96.0
    private var tileCount: Int { max(1, Int(ceil(width / tileWidth))) }
    private var visibleTiles: ClosedRange<Int> {
        let bounds = 0...(tileCount - 1)
        let first = (Int(floor((visibleX.lowerBound - originX) / tileWidth)) - 1).clamped(to: bounds)
        let last = (Int(ceil((visibleX.upperBound - originX) / tileWidth)) + 1).clamped(to: bounds)
        return first...max(first, last)
    }
    // Tile bounds change only after scrolling one tile, rather than at every
    // pixel. Quantizing width avoids cancelling AVFoundation work for each
    // intermediate slider value while preserving close frame inspection.
    private var requestID: String {
        "\(videoPath):\(sourceStart):\(sourceEnd):\(Int((width / 4).rounded())):\(visibleTiles.lowerBound):\(visibleTiles.upperBound)"
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Double(visibleTiles.lowerBound) * tileWidth)
            ForEach(visibleTiles, id: \.self) { index in
                Group {
                    if let image = images[index] {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(colors: [.black.opacity(0.25), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                }
                .frame(width: min(tileWidth, max(1, width - Double(index) * tileWidth)))
                .frame(height: 46)
                .clipped()
            }
        }
        .frame(width: width, height: 46, alignment: .leading)
        .clipped()
        .task(id: requestID) {
            guard !videoPath.isEmpty else { return }
            let indices = Array(visibleTiles)
            let samples = indices.map { index in
                let tileStart = Double(index) * tileWidth
                let tileCenter = tileStart + min(tileWidth, max(1, width - tileStart)) / 2
                return sourceStart + tileCenter / width * (sourceEnd - sourceStart)
            }
            if isStillImage {
                let key = "image:\(videoPath)" as NSString
                let image = EditorFrameCache.images.object(forKey: key)
                    ?? EditorFrameCache.stillThumbnail(at: videoPath)
                if let image {
                    EditorFrameCache.images.setObject(image, forKey: key,
                        cost: Int(image.size.width * image.size.height * 4))
                    images = Dictionary(uniqueKeysWithValues: indices.map { ($0, image) })
                }
                return
            }
            var cached: [Int: NSImage] = [:]
            for (index, sample) in zip(indices, samples) {
                let key = "video:\(videoPath):\(Int((sample * 60).rounded()))" as NSString
                cached[index] = EditorFrameCache.images.object(forKey: key)
            }
            images = cached
            guard cached.count < indices.count else { return }
            // Zoom-slider changes can arrive faster than a seek. The request
            // is cancellable, and only currently visible tiles are decoded.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
            let generator = AVAssetImageGenerator(asset: asset)
            defer { generator.cancelAllCGImageGeneration() }
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 220, height: 110)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0 / 60, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0 / 60, preferredTimescale: 600)
            for (index, sample) in zip(indices, samples) where cached[index] == nil {
                guard !Task.isCancelled else { return }
                let key = "video:\(videoPath):\(Int((sample * 60).rounded()))" as NSString
                let time = CMTime(seconds: max(0, sample), preferredTimescale: 600)
                guard let (frame, _) = try? await generator.image(at: time) else { continue }
                guard !Task.isCancelled else { return }
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
    let trailingGutter: Double
    let visibleX: ClosedRange<Double>
    let currentTime: Double
    @Binding var selectedClipID: UUID?
    let onSelect: (UUID) -> Void
    let onSeek: (Double) -> Void
    let onEdit: (DemoVideoEditOperation) -> Void
    let onInsertMedia: (UUID, Int) -> Void
    let isEditing: Bool
    @State private var isMediaDropTarget = false
    @State private var hoveredTransitionID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var duration: Double { max(project.duration, 0.001) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.035))
            Rectangle()
                .fill(Color.white.opacity(0.03))
                .frame(height: 17)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            transitionSpans
            transitionMenus
            clipBlocks
        }
        .frame(width: timelineWidth + trailingGutter, height: 64, alignment: .leading)
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
                    visibleX: visibleX,
                    duration: duration,
                    currentTime: currentTime,
                    selected: selectedClipID == placement.clip.id,
                    isEditing: isEditing,
                    onSelect: { onSelect(placement.clip.id) },
                    onSeek: onSeek,
                    onEdit: onEdit
                )
                .offset(x: placement.start / duration * timelineWidth, y: 18)
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

    private var transitionSpans: some View {
        ForEach(Array(placements.dropLast().enumerated()), id: \.element.clip.id) { index, placement in
            if isVisible(placement), transitions.indices.contains(index) {
                let transition = transitions[index]
                if transition.preset != .cut {
                    let outgoing = transition.resolvedOutgoingDuration / duration * timelineWidth
                    let incoming = transition.resolvedIncomingDuration / duration * timelineWidth
                    RoundedRectangle(cornerRadius: 4)
                        .fill(StudioTheme.purple.opacity(0.32))
                        .frame(width: outgoing + incoming, height: 11)
                        .offset(x: placement.end / duration * timelineWidth - outgoing, y: 3)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func transitionMenu(after placement: DemoVideoClipPlacement, index: Int) -> some View {
        let transition = transitions.first { $0.fromClipID == placement.clip.id }
        let maximum = maximumTransitionDuration(after: index)
        let isHovered = hoveredTransitionID == placement.clip.id
        return Menu {
            Button("Cut") { onEdit(.setTransition(fromClipID: placement.clip.id, preset: .cut, duration: 0)) }
            Button("Fade to black") {
                changeTransition(after: placement, existing: transition,
                                 preset: .fadeToBlack, defaultDuration: min(0.5, maximum))
            }
            .disabled(maximum < 0.1 && transition?.preset == .cut)
            Button("Flash") {
                changeTransition(after: placement, existing: transition,
                                 preset: .flash, defaultDuration: min(0.3, maximum))
            }
            .disabled(maximum < 0.1 && transition?.preset == .cut)
        } label: {
            Image(systemName: transitionSymbol(transition?.preset ?? .cut))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 16)
                .background(transition?.preset == .cut || transition == nil ? StudioTheme.panelRaised : StudioTheme.purple,
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.white.opacity(isHovered ? 0.95 : 0.55), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 22, height: 17)
        .onHover { hoveredTransitionID = $0 ? placement.clip.id : nil }
        .animation(reduceMotion ? nil : StudioMotion.hover, value: isHovered)
        .disabled(isEditing)
        // A separate strip above the clips keeps the menu out of both trim
        // handles at the join, even when the timeline is zoomed in tightly.
        .offset(x: placement.end / duration * timelineWidth - 11, y: 0)
        .zIndex(4)
        .help("\(L10n.format("Transition after clip %lld", index + 1)) · \((transition?.duration ?? 0).formatted(.number.precision(.fractionLength(2))))s")
        .accessibilityLabel("Transition after clip")
        .accessibilityIdentifier("video.transition.\(placement.clip.id.uuidString)")
    }

    private func changeTransition(after placement: DemoVideoClipPlacement,
                                  existing: DemoVideoTransition?, preset: DemoTransitionPreset,
                                  defaultDuration: Double) {
        if let existing, existing.preset != .cut {
            onEdit(.setTransitionParameters(
                fromClipID: placement.clip.id, preset: preset,
                outgoingDuration: existing.resolvedOutgoingDuration,
                incomingDuration: existing.resolvedIncomingDuration,
                outgoingCurve: existing.resolvedOutgoingCurve,
                incomingCurve: existing.resolvedIncomingCurve))
        } else {
            onEdit(.setTransition(fromClipID: placement.clip.id, preset: preset,
                                  duration: defaultDuration))
        }
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
        let incoming = index > 0 ? transitions[index - 1].resolvedIncomingDuration : 0
        let nextOutgoing = index + 1 < transitions.count ? transitions[index + 1].resolvedOutgoingDuration : 0
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
    let visibleX: ClosedRange<Double>
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
    @State private var hoveredTrim: TrimEdge?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum TrimEdge: Equatable { case leading, trailing }

    private var width: Double { max(1, placement.duration / duration * timelineWidth) }
    private var pixelsPerSecond: Double { timelineWidth / duration }
    private var clip: DemoVideoClip { placement.clip }
    private var canShowHandles: Bool { width >= 48 && mediaAsset?.kind != .image }
    private var mediaAsset: DemoMediaAsset? {
        guard let mediaAssetID = clip.mediaAssetID else { return nil }
        return project.mediaAssets?.first { $0.id == mediaAssetID }
    }
    private var sourceEndLimit: Double {
        mediaAsset?.duration ?? project.videoSourceDuration ?? project.duration
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
                              width: width,
                              originX: placement.start / duration * timelineWidth,
                              visibleX: visibleX)
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
                            if !selected { onSelect() }
                            moveOffset = value.translation.width
                        }
                        .onEnded { value in
                            let targetTime = (placement.start + placement.duration / 2
                                              + Double(value.translation.width) / pixelsPerSecond)
                                .clamped(to: 0...duration)
                            let destination = placements.firstIndex { targetTime < $0.end } ?? clipCount - 1
                            withAnimation(reduceMotion ? nil : StudioMotion.hover) {
                                moveOffset = 0
                                if destination != index {
                                    onEdit(.move(clipID: clip.id, toIndex: destination))
                                }
                            }
                        }
                )
                if canShowHandles { trimHandle(leading: false) }
            }
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(abs(moveOffset) > 2 ? StudioTheme.purple : (selected ? .white : .white.opacity(0.25)),
                              lineWidth: selected || abs(moveOffset) > 2 ? 2 : 1)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: 46)
        .background(alignment: .leading) {
            // An outward drag previews the restored frames without changing
            // clip layout or asking AVFoundation to decode on every mouse move.
            if let leadingTrim, leadingTrim < clip.sourceStart {
                RoundedRectangle(cornerRadius: 5)
                    .fill(StudioTheme.yellow.opacity(0.5))
                    .frame(width: (clip.sourceStart - leadingTrim) * pixelsPerSecond)
                    .offset(x: (leadingTrim - clip.sourceStart) * pixelsPerSecond)
                    .allowsHitTesting(false)
            }
            if let trailingTrim, trailingTrim > clip.sourceEnd {
                RoundedRectangle(cornerRadius: 5)
                    .fill(StudioTheme.yellow.opacity(0.5))
                    .frame(width: (trailingTrim - clip.sourceEnd) * pixelsPerSecond)
                    .offset(x: width)
                    .allowsHitTesting(false)
            }
        }
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
            if mediaAsset?.kind != .image,
               clip.sourceStart > 0.001 || clip.sourceEnd < sourceEndLimit - 0.001 {
                Button("Expand to source bounds") {
                    onEdit(.trim(clipID: clip.id, sourceStart: 0, sourceEnd: sourceEndLimit))
                }
            }
            if index > 0 { Button("Move left") { onEdit(.move(clipID: clip.id, toIndex: index - 1)) } }
            if index < clipCount - 1 { Button("Move right") { onEdit(.move(clipID: clip.id, toIndex: index + 1)) } }
            Button("Remove clip", role: .destructive) { onEdit(.delete(clipID: clip.id)) }
                .disabled(clipCount <= 1)
        }
    }

    private func trimHandle(leading: Bool) -> some View {
        let active = leading ? leadingTrim : trailingTrim
        let hovered = hoveredTrim == (leading ? .leading : .trailing)
        return RoundedRectangle(cornerRadius: 2)
            .fill(.white.opacity(active == nil ? (hovered ? 0.65 : (selected ? 0.38 : 0.27)) : 0.75))
            .overlay(RoundedRectangle(cornerRadius: 1).fill(.white).frame(width: 2, height: 20))
            .frame(width: 16, height: 42)
            .contentShape(Rectangle())
            .offset(x: ((active ?? (leading ? clip.sourceStart : clip.sourceEnd))
                        - (leading ? clip.sourceStart : clip.sourceEnd)) * pixelsPerSecond)
            .onHover { hoveredTrim = $0 ? (leading ? .leading : .trailing) : nil }
            .animation(reduceMotion ? nil : StudioMotion.hover, value: hovered)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("video-timeline"))
                    .onChanged { value in
                        if !selected { onSelect() }
                        let delta = Double(value.translation.width) / pixelsPerSecond
                        if leading {
                            leadingTrim = (clip.sourceStart + delta).clamped(to: 0...(clip.sourceEnd - 0.1))
                        } else {
                            trailingTrim = (clip.sourceEnd + delta).clamped(to: (clip.sourceStart + 0.1)...sourceEndLimit)
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
            .help(leading ? "Drag to trim or restore the start" : "Drag to trim or restore the end")
            .accessibilityLabel(leading ? "Trim clip start" : "Trim clip end")
            .accessibilityValue((active ?? (leading ? clip.sourceStart : clip.sourceEnd)).editorTimecode)
            .accessibilityIdentifier("video.clip.\(clip.id.uuidString).\(leading ? "trimStart" : "trimEnd")")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.1 : -0.1
                if leading {
                    let start = (clip.sourceStart + delta).clamped(to: 0...(clip.sourceEnd - 0.1))
                    onEdit(.trim(clipID: clip.id, sourceStart: start, sourceEnd: clip.sourceEnd))
                } else {
                    let end = (clip.sourceEnd + delta).clamped(to: (clip.sourceStart + 0.1)...sourceEndLimit)
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
