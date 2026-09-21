import FocusStudioCore
import Foundation
import SwiftUI

struct EditorTimelineView: View {
    @Binding var project: RecordingProject
    @Binding var currentTime: Double
    @Binding var selectedZoomID: UUID?
    @Binding var selectedTool: EditorTool

    private let labelWidth = 76.0
    private let rowHeight = 31.0

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
        .frame(height: 163)
        .padding(.vertical, 8)
        .background(StudioTheme.panel)
    }

    private func addZoom(at x: CGFloat, timelineWidth: Double, duration: Double) {
        guard duration > 0, timelineWidth > 0 else { return }
        let time = (Double(x) / timelineWidth * duration).clamped(to: 0...duration)
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
        HStack(spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: icon).frame(width: 13)
                Text(LocalizedStringKey(label))
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

    private let handleWidth = 14.0

    var body: some View {
        let startX = segment.start / duration * timelineWidth
        let width = min(timelineWidth, max(40, (segment.end - segment.start) / duration * timelineWidth))
        let displayedStart = startX.clamped(to: 0...max(0, timelineWidth - width))

        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(segment.isEnabled ? StudioTheme.purple : Color.gray.opacity(0.45))
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
            }
            HStack(spacing: 0) {
                resizeHandle(isLeading: true)
                moveHandle(showDuration: width >= 84)
                    .frame(maxWidth: .infinity)
                resizeHandle(isLeading: false)
            }
        }
        .frame(width: width, height: 24)
        .offset(x: displayedStart)
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
            Button("Remove", role: .destructive, action: onDelete)
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
