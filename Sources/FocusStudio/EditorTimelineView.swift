import FocusStudioCore
import Foundation
import SwiftUI

struct EditorTimelineView: View {
    @Binding var project: RecordingProject
    @Binding var currentTime: Double
    @Binding var selectedZoomID: UUID?
    @Binding var selectedChapterID: UUID?
    @Binding var selectedTool: EditorTool

    private let labelWidth = 76.0
    private let rowHeight = 31.0
    @FocusState private var isTimelineFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let timelineWidth = max(1, proxy.size.width - labelWidth - 14)
            let duration = max(project.duration, 0.001)

            VStack(spacing: 0) {
                RulerRow(
                    duration: duration,
                    currentTime: $currentTime,
                    labelWidth: labelWidth,
                    timelineWidth: timelineWidth
                )
                Divider().overlay(StudioTheme.line)

                timelineRow(label: "Zoom", icon: "plus.magnifyingglass", accessory: {
                    Button {
                        insertZoom(at: currentTime, duration: duration)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioTheme.purple)
                    .help("Add zoom at playhead")
                    .accessibilityLabel("Add zoom at playhead")
                    .accessibilityIdentifier("timeline.addZoom")
                }) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.025))
                            .contentShape(Rectangle())
                            .gesture(
                                SpatialTapGesture(count: 2).onEnded { value in
                                    addZoom(at: value.location.x, timelineWidth: timelineWidth, duration: duration)
                                }
                            )
                            .contextMenu {
                                Button("Add zoom at playhead") { insertZoom(at: currentTime, duration: duration) }
                                if selectedZoomID != nil {
                                    Button("Duplicate zoom") { duplicateSelectedZoom(duration: duration) }
                                    Button("Remove zoom", role: .destructive) { removeSelectedZoom() }
                                }
                            }

                        ForEach($project.zoomSegments) { $segment in
                            ZoomBlockView(
                                segment: $segment,
                                duration: duration,
                                timelineWidth: timelineWidth,
                                settings: project.settings,
                                ordinal: (project.zoomSegments.firstIndex(where: { $0.id == segment.id }) ?? 0) + 1,
                                isSelected: selectedZoomID == segment.id,
                                onSelect: {
                                    selectedZoomID = segment.id
                                    selectedTool = .zoom
                                },
                                onDelete: {
                                    let id = segment.id
                                    project.zoomSegments.removeAll { $0.id == id }
                                    if selectedZoomID == id { selectedZoomID = nil }
                                }
                            )
                            .zIndex(selectedZoomID == segment.id ? 1 : 0)
                        }

                        ForEach(project.clickEvents) { click in
                            Circle()
                                .fill(Color.white.opacity(0.8))
                                .frame(width: 4, height: 4)
                                .position(
                                    x: CGFloat(click.time / duration) * timelineWidth,
                                    y: rowHeight - 5
                                )
                                .allowsHitTesting(false)
                        }

                        if project.zoomSegments.isEmpty {
                            Text("Double-click to add a zoom")
                                .font(.system(size: 10))
                                .foregroundStyle(StudioTheme.secondaryText)
                                .padding(.leading, 10)
                                .allowsHitTesting(false)
                        }
                    }
                    .coordinateSpace(name: "zoom-timeline")
                }

                timelineRow(label: "Chapters", icon: "captions.bubble") {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.025))
                            .contentShape(Rectangle())
                            .gesture(
                                SpatialTapGesture(count: 2).onEnded { value in
                                    addChapter(at: value.location.x, timelineWidth: timelineWidth, duration: duration)
                                }
                            )

                        ForEach(chapters) { $chapter in
                            ChapterBlockView(
                                chapter: $chapter,
                                duration: duration,
                                timelineWidth: timelineWidth,
                                ordinal: chapterNumber(chapter.id),
                                isSelected: selectedChapterID == chapter.id,
                                onSelect: {
                                    selectedChapterID = chapter.id
                                    selectedTool = .captions
                                },
                                onDelete: {
                                    let id = chapter.id
                                    project.chapters?.removeAll { $0.id == id }
                                    if selectedChapterID == id { selectedChapterID = nil }
                                }
                            )
                            .zIndex(selectedChapterID == chapter.id ? 1 : 0)
                        }

                        if (project.chapters ?? []).isEmpty {
                            Text("Double-click to add a chapter")
                                .font(.system(size: 10))
                                .foregroundStyle(StudioTheme.secondaryText)
                                .padding(.leading, 10)
                                .allowsHitTesting(false)
                        }
                    }
                    .coordinateSpace(name: "chapter-timeline")
                }

                timelineRow(label: "Cursor", icon: "cursorarrow") {
                    CursorTrack(samples: project.cursorSamples, duration: duration)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedTool = .cursor }
                }

                timelineRow(label: "Audio", icon: "waveform") {
                    AudioTrack(settings: project.settings.productDemoAudio)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedTool = .audio }
                }

                timelineRow(label: "Video", icon: "film") {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(StudioTheme.yellow.opacity(0.78))
                        .overlay(alignment: .leading) {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform")
                                Text(project.title)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.72))
                            .padding(.horizontal, 9)
                        }
                }
            }
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 1, height: proxy.size.height - 6)
                    .offset(x: labelWidth + 7 + CGFloat(currentTime / duration) * timelineWidth)
                    .overlay(alignment: .top) {
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.white)
                            .offset(x: labelWidth + 7 + CGFloat(currentTime / duration) * timelineWidth - 3)
                    }
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 194)
        .padding(.vertical, 8)
        .background(StudioTheme.panel)
        .focusable()
        .focused($isTimelineFocused)
        .focusEffectDisabled()
        .onDeleteCommand { removeSelectedZoom() }
        .onChange(of: selectedZoomID) { _, id in
            // A freshly selected block should answer the Delete key right away.
            if id != nil { isTimelineFocused = true }
        }
    }

    /// Nil and empty chapter lists are equivalent; the lane edits a plain array.
    private var chapters: Binding<[DemoChapter]> {
        Binding(
            get: { project.chapters ?? [] },
            set: { project.chapters = $0 }
        )
    }

    /// Numbering follows playback order, matching the Inspector, SRT and video.
    private func chapterNumber(_ id: UUID) -> Int {
        let sorted = (project.chapters ?? []).sorted(by: ChapterMath.precedes)
        return (sorted.firstIndex { $0.id == id } ?? 0) + 1
    }

    private func addChapter(at x: CGFloat, timelineWidth: Double, duration: Double) {
        guard duration > 0, timelineWidth > 0 else { return }
        let time = (Double(x) / timelineWidth * duration).clamped(to: 0...duration)
        let existing = project.chapters ?? []
        guard let chapter = ChapterMath.newChapter(
            at: time,
            duration: duration,
            title: L10n.format("Chapter %lld", existing.count + 1)
        ) else { return }
        project.chapters = existing + [chapter]
        selectedChapterID = chapter.id
        selectedTool = .captions
    }

    private func addZoom(at x: CGFloat, timelineWidth: Double, duration: Double) {
        guard duration > 0, timelineWidth > 0 else { return }
        insertZoom(at: (Double(x) / timelineWidth * duration).clamped(to: 0...duration), duration: duration)
    }

    private func removeSelectedZoom() {
        guard let id = selectedZoomID else { return }
        project.zoomSegments.removeAll { $0.id == id }
        selectedZoomID = nil
    }

    /// Copies the selected block right after itself, keeping its look and timing.
    private func duplicateSelectedZoom(duration: Double) {
        guard let source = project.zoomSegments.first(where: { $0.id == selectedZoomID }) else { return }
        var copy = source
        copy.id = UUID()
        copy.kind = .manual
        copy.automaticSource = nil
        let length = source.end - source.start
        let start = min(source.end, max(0, duration - length))
        copy.start = start
        copy.end = min(duration, start + length)
        guard copy.end > copy.start else { return }
        project.zoomSegments.append(copy)
        selectedZoomID = copy.id
        selectedTool = .zoom
    }

    private func insertZoom(at time: Double, duration: Double) {
        guard duration > 0 else { return }
        let time = time.clamped(to: 0...duration)
        let length = min(duration, 1.25)
        let start = (time - 0.1).clamped(to: 0...max(0, duration - length))
        let segment = ZoomSegment(
            start: start,
            end: min(duration, start + length),
            targetX: 0.5,
            targetY: 0.5,
            scale: project.settings.zoomScale,
            kind: .manual
        )
        project.zoomSegments.append(segment)
        selectedZoomID = segment.id
        selectedTool = .zoom
    }

    @ViewBuilder
    private func timelineRow<Content: View>(
        label: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        timelineRow(label: label, icon: icon, accessory: { EmptyView() }, content: content)
    }

    @ViewBuilder
    private func timelineRow<Accessory: View, Content: View>(
        label: String,
        icon: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: icon).frame(width: 13)
                Text(LocalizedStringKey(label))
                Spacer(minLength: 0)
                accessory()
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(StudioTheme.secondaryText)
            .frame(width: labelWidth, alignment: .leading)
            .padding(.leading, 8)
            content()
                .frame(height: rowHeight)
        }
        .frame(height: rowHeight)
    }
}

private struct AudioTrack: View {
    let settings: ProductDemoAudioSettings?

    var body: some View {
        let hasMusic = settings?.backgroundMusicPath != nil
        let hasEffects = settings?.clickSoundEnabled == true
            || settings?.zoomTransitionSoundEnabled == true
        let hasEnhancements = hasMusic || hasEffects
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hasEnhancements ? Color.cyan.opacity(0.46) : Color.white.opacity(0.025))
            .overlay(alignment: .leading) {
                HStack(spacing: 6) {
                    Image(systemName: hasMusic ? "music.note" : (hasEffects ? "waveform" : "plus.circle"))
                    Group {
                        if hasMusic {
                            Text(verbatim: trackTitle)
                        } else {
                            Text(LocalizedStringKey(trackTitle))
                        }
                    }
                    .lineLimit(1)
                    if settings?.clickSoundEnabled == true {
                        Image(systemName: "cursorarrow.click")
                    }
                    if settings?.zoomTransitionSoundEnabled == true {
                        Image(systemName: "plus.magnifyingglass")
                    }
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hasEnhancements ? Color.white.opacity(0.88) : StudioTheme.secondaryText)
                .padding(.horizontal, 9)
            }
    }

    private var trackTitle: String {
        if settings?.backgroundMusicPath != nil { return musicName }
        if settings?.clickSoundEnabled == true || settings?.zoomTransitionSoundEnabled == true {
            return "Sound effects"
        }
        return settings == nil ? "No added audio — click to edit" : "Choose music or effects"
    }

    private var musicName: String {
        guard let path = settings?.backgroundMusicPath else { return "No added audio" }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}

private struct RulerRow: View {
    let duration: Double
    @Binding var currentTime: Double
    let labelWidth: Double
    let timelineWidth: Double

    var body: some View {
        HStack(spacing: 7) {
            Text(currentTime.formattedDuration)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(StudioTheme.secondaryText)
                .frame(width: labelWidth, alignment: .leading)
                .padding(.leading, 8)
            ZStack(alignment: .leading) {
                ForEach(0..<6, id: \.self) { tick in
                    VStack(alignment: .leading, spacing: 2) {
                        Text((duration * Double(tick) / 5).formattedDuration)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(StudioTheme.secondaryText)
                        Rectangle()
                            .fill(StudioTheme.line)
                            .frame(width: 1, height: 5)
                    }
                    .offset(x: CGFloat(tick) / CGFloat(5) * timelineWidth)
                }
            }
            .frame(width: timelineWidth, height: 18, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    currentTime = (Double(value.location.x) / timelineWidth * duration)
                        .clamped(to: 0...duration)
                }
            )
        }
        .frame(height: 25)
    }
}

private struct ZoomBlockView: View {
    @Binding var segment: ZoomSegment
    let duration: Double
    let timelineWidth: Double
    let settings: ProjectSettings
    let ordinal: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var moveOrigin: ZoomSegment?
    @State private var leadingOrigin: ZoomSegment?
    @State private var trailingOrigin: ZoomSegment?
    @State private var fullZoomOrigin: ZoomSegment?
    @State private var zoomOutOrigin: ZoomSegment?

    private let handleWidth = 14.0
    private let innerHandleWidth = 10.0

    var body: some View {
        let startX = segment.start / duration * timelineWidth
        let width = min(timelineWidth, max(40, (segment.end - segment.start) / duration * timelineWidth))
        let displayedStart = startX.clamped(to: 0...max(0, timelineWidth - width))
        let timing = ZoomTiming.resolve(segment, settings: settings)
        let pixelsPerSecond = width / max(0.001, segment.end - segment.start)
        let easeInWidth = min(width, timing.easeIn * pixelsPerSecond)
        let easeOutWidth = min(width, timing.easeOut * pixelsPerSecond)
        let showsInnerHandles = isSelected && !segment.isInstant && width >= 96

        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(segment.isEnabled ? StudioTheme.purple : Color.gray.opacity(0.45))
                .shadow(color: StudioTheme.purple.opacity(isSelected ? 0.55 : 0), radius: isSelected ? 6 : 0)
            // The transitions are shaded so their length is visible at a glance.
            if !segment.isInstant {
                HStack(spacing: 0) {
                    LinearGradient(colors: [Color.black.opacity(0.28), Color.clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: easeInWidth)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [Color.clear, Color.black.opacity(0.28)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: easeOutWidth)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .allowsHitTesting(false)
            }
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5)
            HStack(spacing: 0) {
                resizeHandle(isLeading: true)
                moveHandle(showDuration: width >= 84)
                    .frame(maxWidth: .infinity)
                resizeHandle(isLeading: false)
            }
            if showsInnerHandles {
                // Inner boundaries: when the zoom-in completes and the zoom-out begins.
                innerHandle(isFullZoom: true)
                    .offset(x: (easeInWidth - width / 2).clamped(to: (-width / 2 + handleWidth)...(width / 2 - handleWidth)))
                innerHandle(isFullZoom: false)
                    .offset(x: (width / 2 - easeOutWidth).clamped(to: (-width / 2 + handleWidth)...(width / 2 - handleWidth)))
            }
        }
        .frame(width: width, height: 24)
        .offset(x: displayedStart)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: segment.isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Zoom \(ordinal)"))
        .accessibilityIdentifier("zoom.\(segment.id.uuidString)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("Start \(seconds(segment.start))s · End \(seconds(segment.end))s · Duration \(seconds(segment.end - segment.start))s. Drag the middle to move; drag either edge to resize.")
        .contextMenu {
            Button(LocalizedStringKey(segment.isEnabled ? "Disable" : "Enable")) {
                onSelect()
                segment.isEnabled.toggle()
            }
            Button("Remove zoom", role: .destructive, action: onDelete)
        }
    }

    private func moveHandle(showDuration: Bool) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: "\(ordinal)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
            if showDuration {
                Text("·")
                Text("\(seconds(segment.end - segment.start))s")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white.opacity(0.94))
        .frame(maxWidth: .infinity, minHeight: 24)
        .background(Color.white.opacity(0.001))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("zoom-timeline"))
                .onChanged { value in
                    onSelect()
                    let origin = moveOrigin ?? segment
                    if moveOrigin == nil { moveOrigin = origin }
                    segment = ZoomTiming.applying(
                        .move(origin.start + timeDelta(value.translation.width)),
                        to: origin,
                        projectDuration: duration,
                        settings: settings
                    )
                }
                .onEnded { _ in moveOrigin = nil }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Move zoom \(ordinal)"))
        .accessibilityValue("Start \(seconds(segment.start)) seconds, end \(seconds(segment.end)) seconds")
        .accessibilityHint("Drag to move the whole interval. Adjust to move by one tenth of a second.")
        .accessibilityIdentifier("zoom.\(segment.id.uuidString).move")
        .accessibilityAction { onSelect() }
        .accessibilityAdjustableAction { direction in
            adjust(direction) { .move(segment.start + $0) }
        }
    }

    /// Drags the moment the zoom-in finishes (leading) or the zoom-out starts
    /// (trailing) without moving the block's edges.
    private func innerHandle(isFullZoom: Bool) -> some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.001))
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.85))
                .frame(width: 2, height: 16)
            Image(systemName: isFullZoom ? "arrowtriangle.right.fill" : "arrowtriangle.left.fill")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .offset(y: -9)
        }
        .frame(width: innerHandleWidth, height: 24)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("zoom-timeline"))
                .onChanged { value in
                    onSelect()
                    let origin = (isFullZoom ? fullZoomOrigin : zoomOutOrigin) ?? segment
                    if isFullZoom { if fullZoomOrigin == nil { fullZoomOrigin = origin } }
                    else if zoomOutOrigin == nil { zoomOutOrigin = origin }
                    let originTiming = ZoomTiming.resolve(origin, settings: settings)
                    let delta = timeDelta(value.translation.width)
                    segment = ZoomTiming.applying(
                        isFullZoom ? .fullZoomAt(originTiming.fullZoomStart + delta) : .zoomOutAt(originTiming.zoomOutStart + delta),
                        to: origin,
                        projectDuration: duration,
                        settings: settings
                    )
                }
                .onEnded { _ in
                    if isFullZoom { fullZoomOrigin = nil } else { zoomOutOrigin = nil }
                }
        )
        .help(LocalizedStringKey(isFullZoom ? "Drag to change when the zoom-in finishes" : "Drag to change when the zoom-out starts"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(isFullZoom ? "Zoom in ends" : "Zoom out starts")))
        .accessibilityValue("\(seconds(isFullZoom ? ZoomTiming.resolve(segment, settings: settings).fullZoomStart : ZoomTiming.resolve(segment, settings: settings).zoomOutStart)) seconds")
        .accessibilityIdentifier("zoom.\(segment.id.uuidString).\(isFullZoom ? "fullZoom" : "zoomOut")")
        .accessibilityAdjustableAction { direction in
            adjust(direction) { delta in
                let timing = ZoomTiming.resolve(segment, settings: settings)
                return isFullZoom ? .fullZoomAt(timing.fullZoomStart + delta) : .zoomOutAt(timing.zoomOutStart + delta)
            }
        }
    }

    private func resizeHandle(isLeading: Bool) -> some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(isSelected ? 0.18 : 0.06))
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(isSelected ? 1 : 0.72))
                .frame(width: 3, height: 12)
        }
            .frame(width: handleWidth, height: 24)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("zoom-timeline"))
                    .onChanged { value in
                        onSelect()
                        let delta = timeDelta(value.translation.width)
                        let origin = (isLeading ? leadingOrigin : trailingOrigin) ?? segment
                        if isLeading {
                            if leadingOrigin == nil { leadingOrigin = origin }
                        } else {
                            if trailingOrigin == nil { trailingOrigin = origin }
                        }
                        segment = ZoomTiming.applying(
                            isLeading ? .start(origin.start + delta) : .end(origin.end + delta),
                            to: origin,
                            projectDuration: duration,
                            settings: settings
                        )
                    }
                    .onEnded { _ in
                        if isLeading { leadingOrigin = nil } else { trailingOrigin = nil }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isLeading ? Text("Zoom \(ordinal) start") : Text("Zoom \(ordinal) end"))
            .accessibilityValue("\(seconds(isLeading ? segment.start : segment.end)) seconds")
            .accessibilityHint(Text(LocalizedStringKey(isLeading ? "Drag the left edge to change the start. Adjust by one tenth of a second." : "Drag the right edge to change the end. Adjust by one tenth of a second.")))
            .accessibilityIdentifier("zoom.\(segment.id.uuidString).\(isLeading ? "start" : "end")")
            .accessibilityAction { onSelect() }
            .accessibilityAdjustableAction { direction in
                adjust(direction) { isLeading ? .start(segment.start + $0) : .end(segment.end + $0) }
            }
    }

    private func timeDelta(_ translation: CGFloat) -> Double {
        Double(translation) / max(1, timelineWidth) * duration
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection, edit: (Double) -> ZoomTimingEdit) {
        let delta: Double
        switch direction {
        case .increment: delta = 0.1
        case .decrement: delta = -0.1
        @unknown default: return
        }
        onSelect()
        segment = ZoomTiming.applying(edit(delta), to: segment, projectDuration: duration, settings: settings)
    }

    private func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }
}

private struct ChapterBlockView: View {
    @Binding var chapter: DemoChapter
    let duration: Double
    let timelineWidth: Double
    let ordinal: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var moveOrigin: DemoChapter?
    @State private var leadingOrigin: DemoChapter?
    @State private var trailingOrigin: DemoChapter?

    private let handleWidth = 14.0
    private static let tint = Color(red: 0.13, green: 0.66, blue: 0.80)

    var body: some View {
        let startX = chapter.start / duration * timelineWidth
        let width = min(timelineWidth, max(40, (chapter.end - chapter.start) / duration * timelineWidth))
        let displayedStart = startX.clamped(to: 0...max(0, timelineWidth - width))

        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(chapter.isEnabled ? Self.tint : Color.gray.opacity(0.45))
                .shadow(color: Self.tint.opacity(isSelected ? 0.55 : 0), radius: isSelected ? 6 : 0)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5)
            HStack(spacing: 0) {
                resizeHandle(isLeading: true)
                moveHandle(showTitle: width >= 64)
                    .frame(maxWidth: .infinity)
                resizeHandle(isLeading: false)
            }
        }
        .frame(width: width, height: 24)
        .offset(x: displayedStart)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: chapter.isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Chapter \(ordinal)"))
        .accessibilityIdentifier("chapter.\(chapter.id.uuidString)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("Start \(seconds(chapter.start))s · End \(seconds(chapter.end))s · Duration \(seconds(chapter.end - chapter.start))s. Drag the middle to move; drag either edge to resize.")
        .contextMenu {
            Button(LocalizedStringKey(chapter.isEnabled ? "Disable" : "Enable")) {
                onSelect()
                chapter.isEnabled.toggle()
            }
            Button("Remove", role: .destructive, action: onDelete)
        }
    }

    private func moveHandle(showTitle: Bool) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: "\(ordinal)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
            if showTitle {
                Text(verbatim: chapter.displayText)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(.white.opacity(0.94))
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: 24)
        .background(Color.white.opacity(0.001))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("chapter-timeline"))
                .onChanged { value in
                    onSelect()
                    let origin = moveOrigin ?? chapter
                    if moveOrigin == nil { moveOrigin = origin }
                    chapter = ChapterMath.applying(
                        .move(origin.start + timeDelta(value.translation.width)),
                        to: origin,
                        duration: duration
                    )
                }
                .onEnded { _ in moveOrigin = nil }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Move chapter \(ordinal)"))
        .accessibilityValue("Start \(seconds(chapter.start)) seconds, end \(seconds(chapter.end)) seconds")
        .accessibilityHint("Drag to move the whole interval. Adjust to move by one tenth of a second.")
        .accessibilityIdentifier("chapter.\(chapter.id.uuidString).move")
        .accessibilityAction { onSelect() }
        .accessibilityAdjustableAction { direction in
            adjust(direction) { .move(chapter.start + $0) }
        }
    }

    private func resizeHandle(isLeading: Bool) -> some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(isSelected ? 0.18 : 0.06))
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(isSelected ? 1 : 0.72))
                .frame(width: 3, height: 12)
        }
            .frame(width: handleWidth, height: 24)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("chapter-timeline"))
                    .onChanged { value in
                        onSelect()
                        let delta = timeDelta(value.translation.width)
                        let origin = (isLeading ? leadingOrigin : trailingOrigin) ?? chapter
                        if isLeading {
                            if leadingOrigin == nil { leadingOrigin = origin }
                        } else {
                            if trailingOrigin == nil { trailingOrigin = origin }
                        }
                        chapter = ChapterMath.applying(
                            isLeading ? .start(origin.start + delta) : .end(origin.end + delta),
                            to: origin,
                            duration: duration
                        )
                    }
                    .onEnded { _ in
                        if isLeading { leadingOrigin = nil } else { trailingOrigin = nil }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isLeading ? Text("Chapter \(ordinal) start") : Text("Chapter \(ordinal) end"))
            .accessibilityValue("\(seconds(isLeading ? chapter.start : chapter.end)) seconds")
            .accessibilityHint(Text(LocalizedStringKey(isLeading ? "Drag the left edge to change the start. Adjust by one tenth of a second." : "Drag the right edge to change the end. Adjust by one tenth of a second.")))
            .accessibilityIdentifier("chapter.\(chapter.id.uuidString).\(isLeading ? "start" : "end")")
            .accessibilityAction { onSelect() }
            .accessibilityAdjustableAction { direction in
                adjust(direction) { isLeading ? .start(chapter.start + $0) : .end(chapter.end + $0) }
            }
    }

    private func timeDelta(_ translation: CGFloat) -> Double {
        Double(translation) / max(1, timelineWidth) * duration
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection, edit: (Double) -> ChapterEdit) {
        let delta: Double
        switch direction {
        case .increment: delta = 0.1
        case .decrement: delta = -0.1
        @unknown default: return
        }
        onSelect()
        chapter = ChapterMath.applying(edit(delta), to: chapter, duration: duration)
    }

    private func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }
}

private struct CursorTrack: View {
    let samples: [CursorSample]
    let duration: Double

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            var path = Path()
            for (index, sample) in samples.enumerated() {
                let point = CGPoint(
                    x: CGFloat(sample.time / duration) * size.width,
                    y: size.height * (0.2 + CGFloat(sample.y) * 0.6)
                )
                if index == 0 { path.move(to: point) }
                else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(Color.cyan.opacity(0.65)), lineWidth: 1)
        }
        .background(Color.white.opacity(0.018))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
