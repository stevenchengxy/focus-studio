import AppKit
import FocusStudioAutomation
import FocusStudioCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct EditorTimelineView: View {
    @Binding var project: RecordingProject
    @Binding var currentTime: Double
    @Binding var selectedZoomID: UUID?
    @Binding var selectedChapterID: UUID?
    @Binding var selectedClipID: UUID?
    @Binding var selectedTool: EditorTool
    let onVideoEdit: (DemoVideoEditOperation) -> Void
    let onInsertMedia: (UUID, Int) -> Void
    let isVideoEditing: Bool

    private let labelWidth = 100.0
    private let rowHeight = 38.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isTimelineFocused: Bool
    @State private var timelineZoom = 1.0
    @State private var scrollOffset = 0.0

    private var timelineLabelWidth: Double { labelWidth + 22 }

    var body: some View {
        GeometryReader { proxy in
            let viewportWidth = max(1, proxy.size.width - timelineLabelWidth - 14)
            let timelineWidth = viewportWidth * timelineZoom
            let duration = max(project.duration, 0.001)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    timelineControls(maxZoom: maximumZoom(duration: duration, viewportWidth: viewportWidth))
                    Spacer(minLength: 0)
                    Text("Scroll to inspect frames")
                        .font(.system(size: 9))
                        .foregroundStyle(StudioTheme.secondaryText)
                }
                .frame(height: 27)
                .padding(.horizontal, 12)

                HStack(alignment: .top, spacing: 0) {
                    fixedLaneLabels
                        .frame(width: timelineLabelWidth)

                    ScrollView(.horizontal) {
                        VStack(spacing: 0) {
                            RulerRow(
                                duration: duration,
                                currentTime: Binding(get: { currentTime }, set: { isTimelineFocused = true; currentTime = $0 }),
                                timelineWidth: timelineWidth,
                                visibleX: scrollOffset...(scrollOffset + viewportWidth)
                            )
                            Divider().overlay(StudioTheme.line)

                            timelineRow(label: "Zoom", icon: "plus.magnifyingglass") {
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
                                    selectedChapterID = nil
                                    selectedClipID = nil
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

                        Canvas { context, _ in
                            for click in project.clickEvents {
                                let x = click.time / duration * timelineWidth
                                guard x >= scrollOffset - 4, x <= scrollOffset + viewportWidth + 4 else { continue }
                                context.fill(Path(ellipseIn: CGRect(x: x - 2, y: rowHeight - 9,
                                                                    width: 4, height: 4)),
                                             with: .color(.white.opacity(0.8)))
                            }
                        }
                        .allowsHitTesting(false)

                        if project.zoomSegments.isEmpty {
                            Text("Double-click to add a zoom")
                                .font(.system(size: 10))
                                .foregroundStyle(StudioTheme.secondaryText)
                                .padding(.leading, 10)
                                .allowsHitTesting(false)
                        }
                    }
                    .coordinateSpace(name: "zoom-timeline")
                    .clipped()
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
                                    selectedZoomID = nil
                                    selectedClipID = nil
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
                    .clipped()
                }

                            timelineRow(label: "Cursor", icon: "cursorarrow") {
                    CursorTrack(samples: project.cursorSamples, duration: duration,
                                visibleX: scrollOffset...(scrollOffset + viewportWidth))
                        .contentShape(Rectangle())
                        .onTapGesture { selectedTool = .cursor }
                }

                            timelineRow(label: "Audio", icon: "waveform") {
                    AudioTrack(settings: project.settings.productDemoAudio)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedTool = .audio }
                }

                            timelineRow(label: "Video", icon: "film", height: 56) {
                    if let videoTimeline {
                        EditorVideoTimelineView(
                            project: project,
                            placements: videoTimeline.placements,
                            transitions: videoTimeline.transitions,
                            timelineWidth: timelineWidth,
                            visibleX: scrollOffset...(scrollOffset + viewportWidth),
                            currentTime: currentTime,
                            selectedClipID: $selectedClipID,
                            onSelect: { id in
                                isTimelineFocused = true
                                selectedClipID = id
                                selectedZoomID = nil
                                selectedChapterID = nil
                                selectedTool = .video
                            },
                            onSeek: { currentTime = $0 },
                            onEdit: onVideoEdit,
                            onInsertMedia: onInsertMedia,
                            isEditing: isVideoEditing
                        )
                    } else {
                        Label("Video timeline unavailable", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(StudioTheme.yellow)
                    }
                            }
                        }
                        .frame(width: timelineWidth)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: TimelineScrollOffsetKey.self,
                                    value: -geometry.frame(in: .named("timeline-scroll")).minX)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                let playheadX = CGFloat((currentTime / duration).clamped(to: 0...1)) * timelineWidth
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 1.5, height: 236)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                    UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 1, bottomTrailingRadius: 1, topTrailingRadius: 3)
                        .fill(.white)
                        .frame(width: 10, height: 10)
                }
                .offset(x: playheadX - 5, y: 3)
                .allowsHitTesting(false)
                        }
                    }
                    .scrollIndicators(.visible)
                    .coordinateSpace(name: "timeline-scroll")
                    .onPreferenceChange(TimelineScrollOffsetKey.self) { scrollOffset = max(0, $0) }
                    .onChange(of: project.duration) { _, _ in
                        timelineZoom = min(timelineZoom,
                            maximumZoom(duration: max(project.duration, 0.001), viewportWidth: viewportWidth))
                    }
                    .frame(width: viewportWidth)
                    Spacer(minLength: 0)
                        .frame(width: 14)
                }
            }
        }
        .frame(height: 272)
        .padding(.vertical, 6)
        .background(StudioTheme.panel)
        .focusable()
        .focused($isTimelineFocused)
        .focusEffectDisabled()
        .onDeleteCommand { removeSelection() }
        .onChange(of: selectedZoomID) { _, id in
            if id != nil { isTimelineFocused = true }
        }
        .onChange(of: selectedChapterID) { _, id in
            if id != nil { isTimelineFocused = true }
        }
        .onChange(of: selectedClipID) { _, id in
            if id != nil { isTimelineFocused = true }
        }
    }

    private var videoTimeline: DemoVideoTimeline? { try? DemoVideoTimeline(project: project) }

    private func maximumZoom(duration: Double, viewportWidth: Double) -> Double {
        // At the far end of the slider, a frame should occupy several pixels.
        // Capping the scale prevents very large scroll surfaces on long takes.
        let frameScale = duration * Double(max(1, project.settings.frameRate)) * 8 / max(1, viewportWidth)
        return min(128, max(16, frameScale))
    }

    private func timelineControls(maxZoom: Double) -> some View {
        HStack(spacing: 5) {
            Text("Timeline")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StudioTheme.secondaryText)
                .padding(.trailing, 8)
            Button { timelineZoom = max(1, timelineZoom / 2) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(timelineZoom <= 1.001)
            .accessibilityLabel("Zoom timeline out")
            .accessibilityIdentifier("timeline.zoomOut")
            Slider(value: $timelineZoom, in: 1...maxZoom)
                .frame(width: 100)
                .accessibilityLabel("Timeline zoom")
                .accessibilityValue("\(Int(timelineZoom * 100)) percent")
                .accessibilityIdentifier("timeline.zoomSlider")
            Button { timelineZoom = min(maxZoom, timelineZoom * 2) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(timelineZoom >= maxZoom - 0.001)
            .accessibilityLabel("Zoom timeline in")
            .accessibilityIdentifier("timeline.zoomIn")
            Button("Fit") { timelineZoom = 1 }
                .disabled(timelineZoom <= 1.001)
                .accessibilityIdentifier("timeline.zoomFit")
            Text("\(Int((timelineZoom * 100).rounded()))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(StudioTheme.secondaryText)
                .frame(width: 44, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10))
    }

    private var fixedLaneLabels: some View {
        VStack(spacing: 0) {
            Text("TIMELINE")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(StudioTheme.secondaryText)
                .frame(height: 32)
            Divider().overlay(StudioTheme.line)
            fixedLaneLabel("Zoom", icon: "plus.magnifyingglass", tool: .zoom) {
                Button { insertZoom(at: currentTime, duration: max(0, project.duration)) } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .foregroundStyle(StudioTheme.purple)
                .help("Add zoom at playhead")
                .accessibilityLabel("Add zoom at playhead")
                .accessibilityIdentifier("timeline.addZoom")
            }
            fixedLaneLabel("Chapters", icon: "captions.bubble", tool: .captions) {
                Button {
                    addChapter(at: currentTime, duration: max(0, project.duration))
                } label: { Image(systemName: "plus.circle.fill") }
                .foregroundStyle(.cyan)
                .help("Add chapter at playhead")
                .accessibilityLabel("Add chapter at playhead")
            }
            fixedLaneLabel("Cursor", icon: "cursorarrow", tool: .cursor)
            fixedLaneLabel("Audio", icon: "waveform", tool: .audio)
            fixedLaneLabel("Video", icon: "film", tool: .video, height: 56) {
                Button(action: splitAtPlayhead) { Image(systemName: "scissors") }
                    .foregroundStyle(StudioTheme.yellow)
                    .disabled(!canSplitAtPlayhead || isVideoEditing)
                    .help("Split at playhead · S")
                    .accessibilityLabel("Split clip at playhead")
                    .accessibilityIdentifier("timeline.splitAtPlayhead")
            }
        }
        .background(StudioTheme.panel)
    }

    private func fixedLaneLabel(_ title: String, icon: String, tool: EditorTool,
                                height: Double = 38) -> some View {
        fixedLaneLabel(title, icon: icon, tool: tool, height: height) { EmptyView() }
    }

    private func fixedLaneLabel<Accessory: View>(_ title: String, icon: String,
                                                  tool: EditorTool, height: Double = 38,
                                                  @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).frame(width: 14)
            Text(LocalizedStringKey(title))
            Spacer(minLength: 0)
            accessory()
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(selectedTool == tool ? StudioTheme.text : StudioTheme.secondaryText)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: height)
        .contentShape(Rectangle())
        .onTapGesture { selectedTool = tool }
        .background(selectedTool == tool ? StudioTheme.purple.opacity(0.035) : .clear)
    }

    private var canSplitAtPlayhead: Bool {
        videoTimeline?.placements.contains {
            currentTime > $0.start + 0.1 && currentTime < $0.end - 0.1
        } == true
    }

    private func splitAtPlayhead() {
        guard let placement = videoTimeline?.placements.first(where: {
            currentTime > $0.start + 0.1 && currentTime < $0.end - 0.1
        }) else { return }
        selectedClipID = placement.clip.id
        selectedZoomID = nil
        selectedChapterID = nil
        selectedTool = .video
        onVideoEdit(.split(clipID: placement.clip.id, at: currentTime))
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
        selectedZoomID = nil
        selectedClipID = nil
        selectedTool = .captions
    }

    private func addChapter(at time: Double, duration: Double) {
        guard duration > 0 else { return }
        addChapter(at: CGFloat(time), timelineWidth: duration, duration: duration)
    }

    private func addZoom(at x: CGFloat, timelineWidth: Double, duration: Double) {
        guard duration > 0, timelineWidth > 0 else { return }
        insertZoom(at: (Double(x) / timelineWidth * duration).clamped(to: 0...duration), duration: duration)
    }

    private func removeSelection() {
        withAnimation(reduceMotion ? nil : StudioMotion.fade) {
            if selectedTool == .captions, let id = selectedChapterID {
                project.chapters?.removeAll { $0.id == id }
                selectedChapterID = nil
            } else if selectedTool == .zoom {
                removeSelectedZoom()
            } else if selectedTool == .video, let id = selectedClipID,
                      let timeline = videoTimeline, timeline.clips.count > 1 {
                onVideoEdit(.delete(clipID: id))
            }
        }
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
        selectedChapterID = nil
        selectedClipID = nil
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
        selectedChapterID = nil
        selectedClipID = nil
        selectedTool = .zoom
    }

    private func timelineRow<Content: View>(
        label: String,
        icon: String,
        height: Double = 38,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let tool: EditorTool? = switch label {
        case "Video": .video
        case "Zoom": .zoom
        case "Chapters": .captions
        case "Cursor": .cursor
        case "Audio": .audio
        default: nil
        }
        let active = tool == selectedTool
        return content()
            .frame(height: height - 6)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(active ? Color.white.opacity(0.12) : .clear, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        .padding(.vertical, 3)
        .frame(height: height)
        .background(active ? StudioTheme.purple.opacity(0.035) : .clear)
        .animation(reduceMotion ? nil : StudioMotion.fade, value: active)
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

private struct TimelineScrollOffsetKey: PreferenceKey {
    static var defaultValue = 0.0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = nextValue() }
}

private struct RulerRow: View {
    let duration: Double
    @Binding var currentTime: Double
    let timelineWidth: Double
    let visibleX: ClosedRange<Double>
    @State private var hoverX: Double?

    var body: some View {
        let pixelsPerSecond = timelineWidth / duration
        let interval = tickInterval(pixelsPerSecond: pixelsPerSecond)
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let first = max(0, Int(floor(visibleX.lowerBound / pixelsPerSecond / interval)) - 1)
                let last = min(Int(ceil(duration / interval)),
                               Int(ceil(visibleX.upperBound / pixelsPerSecond / interval)) + 1)
                guard last >= first else { return }
                for index in first...last {
                    let second = Double(index) * interval
                    let x = second * pixelsPerSecond
                    for minor in 0..<5 {
                        let minorX = x + Double(minor) * interval * pixelsPerSecond / 5
                        if minorX < visibleX.lowerBound - 10 || minorX > visibleX.upperBound + 10 { continue }
                        var path = Path()
                        path.move(to: CGPoint(x: minorX, y: size.height - (minor == 0 ? 8 : 4)))
                        path.addLine(to: CGPoint(x: minorX, y: size.height))
                        context.stroke(path, with: .color(.white.opacity(minor == 0 ? 0.25 : 0.10)))
                    }
                    let title = interval < 1 ? second.editorTimecode : second.formattedDuration
                    context.draw(context.resolve(Text(title)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(StudioTheme.secondaryText)),
                        at: CGPoint(x: x, y: 3), anchor: .topLeading)
                }
            }
            if let hoverX {
                Text((hoverX / timelineWidth * duration).editorTimecode)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(StudioTheme.purple, in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: (hoverX - 37).clamped(to: 0...max(0, timelineWidth - 80)), y: 0)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: timelineWidth, height: 32, alignment: .leading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hoverX = location.x.clamped(to: 0...timelineWidth)
            case .ended: hoverX = nil
            }
        }
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            currentTime = (Double(value.location.x) / timelineWidth * duration).clamped(to: 0...duration)
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(currentTime.editorTimecode)
        .accessibilityAdjustableAction { direction in
            currentTime = (currentTime + (direction == .increment ? 1 : -1)).clamped(to: 0...duration)
        }
        .help("Click or drag to scrub")
    }

    private func tickInterval(pixelsPerSecond: Double) -> Double {
        let target = 110 / max(0.001, pixelsPerSecond)
        let power = pow(10, floor(log10(target)))
        return [1.0, 2, 5, 10].map { $0 * power }.first(where: { $0 >= target }) ?? 10 * power
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
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
                .fill(LinearGradient(colors: segment.isEnabled ? [StudioTheme.purple, StudioTheme.purpleSoft] : [.gray.opacity(0.45), .gray.opacity(0.3)], startPoint: .top, endPoint: .bottom))
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
                .stroke(Color.white.opacity(isSelected ? 0.9 : (isHovering ? 0.35 : 0.12)), lineWidth: 1.5)
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
        .frame(width: width, height: 28)
        .onHover { isHovering = $0 }
        .offset(x: displayedStart)
        .animation(reduceMotion ? nil : StudioMotion.hover, value: isSelected)
        .animation(reduceMotion ? nil : StudioMotion.hover, value: isHovering)
        .animation(reduceMotion ? nil : StudioMotion.hover, value: segment.isEnabled)
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
        .frame(maxWidth: .infinity, minHeight: 28)
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
        .frame(width: innerHandleWidth, height: 28)
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
            .frame(width: handleWidth, height: 28)
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
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
                .stroke(Color.white.opacity(isSelected ? 0.9 : (isHovering ? 0.35 : 0.12)), lineWidth: 1.5)
            HStack(spacing: 0) {
                resizeHandle(isLeading: true)
                moveHandle(showTitle: width >= 64)
                    .frame(maxWidth: .infinity)
                resizeHandle(isLeading: false)
            }
        }
        .frame(width: width, height: 28)
        .onHover { isHovering = $0 }
        .offset(x: displayedStart)
        .animation(reduceMotion ? nil : StudioMotion.hover, value: isSelected)
        .animation(reduceMotion ? nil : StudioMotion.hover, value: isHovering)
        .animation(reduceMotion ? nil : StudioMotion.hover, value: chapter.isEnabled)
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
        .frame(maxWidth: .infinity, minHeight: 28)
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
            .frame(width: handleWidth, height: 28)
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
    let visibleX: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let firstTime = max(0, visibleX.lowerBound / max(1, size.width) * duration)
            let lastTime = min(duration, visibleX.upperBound / max(1, size.width) * duration)
            let first = max(0, lowerBound(firstTime) - 1)
            let last = min(samples.count, lowerBound(lastTime) + 2)
            guard last - first > 1 else { return }
            var path = Path()
            for index in first..<last {
                let sample = samples[index]
                let point = CGPoint(
                    x: CGFloat(sample.time / duration) * size.width,
                    y: size.height * (0.2 + CGFloat(sample.y) * 0.6)
                )
                if index == first { path.move(to: point) }
                else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(Color.cyan.opacity(0.65)), lineWidth: 1)
        }
        .background(Color.white.opacity(0.018))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    /// Cursor samples are captured in time order. Binary search avoids
    /// rebuilding a path across the entire recording when only a few seconds
    /// are visible at frame-level zoom.
    private func lowerBound(_ time: Double) -> Int {
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].time < time { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }
}
