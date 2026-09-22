import AppKit
import FocusStudioCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum EditorTool: String, CaseIterable, Identifiable {
    case zoom
    case captions
    case design
    case cursor
    case audio
    case animation
    case export

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .zoom: return "plus.magnifyingglass"
        case .captions: return "captions.bubble"
        case .design: return "paintpalette"
        case .cursor: return "cursorarrow"
        case .audio: return "waveform"
        case .animation: return "sparkles"
        case .export: return "slider.horizontal.3"
        }
    }
}

struct EditorInspectorView: View {
    @EnvironmentObject private var model: StudioModel
    @Environment(\.textCompletion) private var textCompletion
    @Binding var project: RecordingProject
    @Binding var selectedZoomID: UUID?
    @Binding var selectedChapterID: UUID?
    let tool: EditorTool
    @State private var isGeneratingChapters = false
    @State private var captionsMessage: String?
    private let systemWallpapers = SystemWallpaperCatalog.installed
    private let bundledBackgrounds = (try? BackgroundCatalog.loadBundled())?.assets ?? []
    private let bundledBackgroundCatalog = try? BackgroundCatalog.loadBundled()

    private var selectedZoomIndex: Int? {
        guard let selectedZoomID else { return nil }
        return project.zoomSegments.firstIndex { $0.id == selectedZoomID }
    }

    private var hasMissingInteractionTrace: Bool {
        project.settings.autoZoomEnabled
            && project.clickEvents.isEmpty
            && (project.typingActivity ?? []).isEmpty
            && project.cursorSamples.count <= 1
    }

    private var missingInteractionWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No interaction events captured", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTheme.yellow)
            Text("This recording has video, but no captured clicks or typing to create automatic zooms. Check Focus Studio’s Accessibility permission, then make a new recording.")
                .font(.system(size: 10))
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Granting permission now cannot add events to this saved video. You can still double-click the Zoom lane to add zooms manually.")
                .font(.system(size: 10))
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .lineSpacing(2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor.missingInteractionEvents")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: tool.icon)
                        .foregroundStyle(StudioTheme.purple)
                    Text(LocalizedStringKey(tool.title))
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                }

                Divider().overlay(StudioTheme.line)

                switch tool {
                case .zoom:
                    if !project.zoomSegments.isEmpty {
                        Picker("Selected zoom", selection: $selectedZoomID) {
                            Text("Select a zoom").tag(Optional<UUID>.none)
                            ForEach(project.zoomSegments) { segment in
                                let number = (project.zoomSegments.firstIndex { $0.id == segment.id } ?? 0) + 1
                                Text("Zoom \(number) · \(segment.start, specifier: "%.2f")–\(segment.end, specifier: "%.2f")s")
                                    .tag(Optional(segment.id))
                            }
                        }
                        .font(.system(size: 11))
                        .accessibilityIdentifier("editor.selectedZoom")
                    }
                    zoomInspector
                case .captions:
                    captionsInspector
                case .design:
                    designInspector
                case .cursor:
                    cursorInspector
                case .audio:
                    audioInspector
                case .animation:
                    animationInspector
                case .export:
                    exportInspector
                }
            }
            .padding(18)
        }
        .background(StudioTheme.panel)
    }

    @ViewBuilder
    private var zoomInspector: some View {
        if let index = selectedZoomIndex {
            let selected = project.zoomSegments[index]
            let zoom = Binding<ZoomSegment>(
                get: { project.zoomSegments.first { $0.id == selected.id } ?? selected },
                set: { updated in
                    guard let liveIndex = project.zoomSegments.firstIndex(where: { $0.id == selected.id }) else { return }
                    let previous = project.zoomSegments[liveIndex]
                    guard updated != previous else { return }
                    var authored = updated
                    if previous.kind == .automatic, updated.kind == .automatic {
                        // Focus, scale, enabled and instant edits are authored
                        // choices too. Preserve their captured-event ownership.
                        let takeover = ZoomTiming.applying(.move(previous.start), to: previous, projectDuration: project.duration, settings: project.settings)
                        authored.kind = .manual
                        authored.automaticSource = takeover.automaticSource
                    }
                    project.zoomSegments[liveIndex] = authored
                }
            )
            let timing = ZoomTiming.resolve(zoom.wrappedValue, settings: project.settings)
            InspectorSection("Zoom type") {
                HStack {
                    Text("Zoom \(index + 1)")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(LocalizedStringKey(zoom.wrappedValue.kind == .automatic ? "Automatic cue" : "Manually edited"))
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTheme.secondaryText)
                }
            }
            InspectorSection("Scale") {
                LabeledSlider(value: zoom.scale, range: 1.1...3, suffix: "×", decimals: 2)
            }
            InspectorSection("Timing") {
                NumberField(title: "Start", value: segmentTimingBinding(zoom, value: \.start, edit: ZoomTimingEdit.start), range: 0...max(0, project.duration), suffix: "s")
                NumberField(title: "End", value: segmentTimingBinding(zoom, value: \.end, edit: ZoomTimingEdit.end), range: 0...max(0, project.duration), suffix: "s")
                NumberField(title: "Total duration", value: segmentTimingBinding(zoom, value: \.duration, edit: ZoomTimingEdit.duration), range: 0...max(0, project.duration), suffix: "s")
                NumberField(title: "Hold at full zoom", value: segmentTimingBinding(zoom, value: \.hold, edit: ZoomTimingEdit.hold), range: 0...max(0, project.duration), suffix: "s")
                NumberField(title: "Zoom in ends", value: segmentTimingBinding(zoom, value: \.fullZoomStart, edit: ZoomTimingEdit.fullZoomAt), range: 0...max(0, project.duration), suffix: "s")
                NumberField(title: "Zoom out starts", value: segmentTimingBinding(zoom, value: \.zoomOutStart, edit: ZoomTimingEdit.zoomOutAt), range: 0...max(0, project.duration), suffix: "s")
                Toggle("Instant animation", isOn: zoom.isInstant)
                    .font(.system(size: 11))
                Toggle("Enabled", isOn: zoom.isEnabled)
                    .font(.system(size: 11))
            }
            .id(selected.id)
            InspectorSection("Speed for this zoom") {
                Picker("Project curve", selection: $project.settings.screenAnimation) {
                    ForEach(ScreenAnimationStyle.allCases, id: \.self) { style in
                        Text(LocalizedStringKey(style.title)).tag(style)
                    }
                }
                LabeledSlider(
                    value: segmentTimingBinding(zoom, value: \.easeIn, edit: ZoomTimingEdit.easeIn),
                    range: 0...3,
                    label: "Zoom in",
                    suffix: "s",
                    decimals: 2
                )
                LabeledSlider(
                    value: segmentTimingBinding(zoom, value: \.easeOut, edit: ZoomTimingEdit.easeOut),
                    range: 0...3,
                    label: "Zoom out",
                    suffix: "s",
                    decimals: 2
                )
                HStack(spacing: 8) {
                    transitionPreset("Fast", incoming: 0.18, outgoing: 0.22, zoom: zoom)
                    transitionPreset("Natural", incoming: 0.36, outgoing: 0.52, zoom: zoom)
                    transitionPreset("Gentle", incoming: 0.8, outgoing: 1.0, zoom: zoom)
                }
                .controlSize(.small)
                .disabled(zoom.wrappedValue.isInstant)
                Text("In \(timing.easeIn, specifier: "%.2f")s · Hold \(timing.hold, specifier: "%.2f")s · Out \(timing.easeOut, specifier: "%.2f")s")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(StudioTheme.secondaryText)
                Button("Use project speeds") {
                    zoom.wrappedValue = ZoomTiming.applying(.resetTransitions, to: zoom.wrappedValue, projectDuration: project.duration, settings: project.settings)
                }
                .font(.system(size: 10))
            }
            InspectorSection("Focus point") {
                LabeledSlider(value: zoom.targetX, range: 0...1, label: "Horizontal", suffix: "%", multiplier: 100, decimals: 0)
                LabeledSlider(value: zoom.targetY, range: 0...1, label: "Vertical", suffix: "%", multiplier: 100, decimals: 0)
            }
            Button(role: .destructive) {
                let id = project.zoomSegments[index].id
                project.zoomSegments.removeAll { $0.id == id }
                selectedZoomID = nil
            } label: {
                Label("Remove zoom", systemImage: "trash")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioTheme.red)
        } else {
            if hasMissingInteractionTrace {
                missingInteractionWarning
            }
            VStack(spacing: 11) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(StudioTheme.secondaryText)
                Text(LocalizedStringKey(project.zoomSegments.isEmpty ? "Add a zoom manually" : "Select a purple zoom block"))
                    .font(.system(size: 12, weight: .medium))
                Text("Or double-click the Zoom lane to add a manual camera move.")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    private func segmentTimingBinding(
        _ zoom: Binding<ZoomSegment>,
        value: KeyPath<ResolvedZoomTiming, Double>,
        edit: @escaping (Double) -> ZoomTimingEdit
    ) -> Binding<Double> {
        Binding(
            get: { ZoomTiming.resolve(zoom.wrappedValue, settings: project.settings)[keyPath: value] },
            set: { requested in
                zoom.wrappedValue = ZoomTiming.applying(edit(requested), to: zoom.wrappedValue, projectDuration: project.duration, settings: project.settings)
            }
        )
    }

    private func transitionPreset(_ title: String, incoming: Double, outgoing: Double, zoom: Binding<ZoomSegment>) -> some View {
        Button(LocalizedStringKey(title)) {
            var segment = zoom.wrappedValue
            segment = ZoomTiming.applying(.easeIn(incoming), to: segment, projectDuration: project.duration, settings: project.settings)
            segment = ZoomTiming.applying(.easeOut(outgoing), to: segment, projectDuration: project.duration, settings: project.settings)
            zoom.wrappedValue = segment
        }
    }

    private var designInspector: some View {
        Group {
            InspectorSection("Canvas") {
                Picker("Aspect ratio", selection: $project.settings.aspectRatio) {
                    ForEach(CanvasAspectRatio.allCases, id: \.self) { ratio in
                        Text(LocalizedStringKey(ratio.title)).tag(ratio)
                    }
                }
                LabeledSlider(value: $project.settings.padding, range: 0...160, label: "Padding", suffix: "px", decimals: 0)
                LabeledSlider(value: $project.settings.cornerRadius, range: 0...52, label: "Corners", suffix: "px", decimals: 0)
                LabeledSlider(value: $project.settings.shadow, range: 0...0.8, label: "Shadow", suffix: "%", multiplier: 100, decimals: 0)
            }
            InspectorSection("Content crop") {
                Picker("Preset", selection: cropPresetBinding) {
                    ForEach(ContentCropPreset.allCases) { preset in
                        Text(LocalizedStringKey(preset.title)).tag(preset)
                    }
                }
                LabeledSlider(
                    value: cropInsetBinding(\.top),
                    range: 0...0.30,
                    label: "Top",
                    suffix: "%",
                    multiplier: 100,
                    decimals: 0
                )
                DisclosureGroup("More edges") {
                    VStack(spacing: 9) {
                        LabeledSlider(
                            value: cropInsetBinding(\.leading),
                            range: 0...0.30,
                            label: "Left",
                            suffix: "%",
                            multiplier: 100,
                            decimals: 0
                        )
                        LabeledSlider(
                            value: cropInsetBinding(\.trailing),
                            range: 0...0.30,
                            label: "Right",
                            suffix: "%",
                            multiplier: 100,
                            decimals: 0
                        )
                        LabeledSlider(
                            value: cropInsetBinding(\.bottom),
                            range: 0...0.30,
                            label: "Bottom",
                            suffix: "%",
                            multiplier: 100,
                            decimals: 0
                        )
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 10, weight: .medium))

            }
            InspectorSection("Background") {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4),
                    spacing: 8
                ) {
                    ForEach(BackgroundPreset.allCases) { preset in
                        Button {
                            project.settings.backgroundStyle = .gradient
                            project.settings.backgroundColor = preset.primaryHex
                            project.settings.secondaryBackgroundColor = preset.secondaryHex
                        } label: {
                            BackgroundPresetSwatch(
                                preset: preset,
                                isSelected: project.settings.backgroundStyle == .gradient
                                    && preset.matches(
                                        primary: project.settings.backgroundColor,
                                        secondary: project.settings.secondaryBackgroundColor
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .help(preset.title)
                        .accessibilityLabel("\(preset.title) background")
                    }
                }
                Picker("Style", selection: $project.settings.backgroundStyle) {
                    Text("Solid").tag(BackgroundStyle.solid)
                    Text("Gradient").tag(BackgroundStyle.gradient)
                    Text("Image").tag(BackgroundStyle.image)
                }
                if project.settings.backgroundStyle == .image {
                    if let catalog = bundledBackgroundCatalog, !bundledBackgrounds.isEmpty {
                        Text("FOCUS STUDIO BACKGROUNDS")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.55)
                            .foregroundStyle(StudioTheme.secondaryText)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(bundledBackgrounds) { asset in
                                    let path = catalog.fileURL(for: asset).path
                                    Button {
                                        project.settings.backgroundStyle = .image
                                        project.settings.backgroundImagePath = path
                                    } label: {
                                        BackgroundAssetSwatch(
                                            url: catalog.fileURL(for: asset),
                                            isSelected: project.settings.backgroundImagePath == path
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .help(Text(verbatim: "\(asset.title) · \(asset.mood)"))
                                    .accessibilityLabel(Text(verbatim: asset.title))
                                }
                            }
                        }
                    }
                    if systemWallpapers.isEmpty {
                        Text("No readable macOS wallpapers were found on this Mac.")
                            .font(.system(size: 9))
                            .foregroundStyle(StudioTheme.secondaryText)
                    } else {
                        Text("MACOS WALLPAPERS")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.55)
                            .foregroundStyle(StudioTheme.secondaryText)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(systemWallpapers.prefix(16))) { wallpaper in
                                    Button {
                                        project.settings.backgroundStyle = .image
                                        project.settings.backgroundImagePath = wallpaper.path
                                    } label: {
                                        WallpaperSwatch(
                                            wallpaper: wallpaper,
                                            isSelected: project.settings.backgroundImagePath == wallpaper.path
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .help(wallpaper.displayName)
                                }
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Import image…") {
                            Task {
                                if let path = await model.importBackgroundImage(for: project) {
                                    project.settings.backgroundStyle = .image
                                    project.settings.backgroundImagePath = path
                                }
                            }
                        }
                        if project.settings.backgroundImagePath != nil {
                            Button {
                                project.settings.backgroundImagePath = nil
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .help("Remove background image")
                        }
                    }
                    .font(.system(size: 9, weight: .medium))

                    if let path = project.settings.backgroundImagePath {
                        Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(StudioTheme.secondaryText)
                            .lineLimit(1)
                        LabeledSlider(
                            value: backgroundBlurBinding,
                            range: 0...60,
                            label: "Blur",
                            suffix: "px",
                            decimals: 0
                        )
                        LabeledSlider(
                            value: backgroundBrightnessBinding,
                            range: -0.5...0.35,
                            label: "Brightness",
                            suffix: "%",
                            multiplier: 100,
                            decimals: 0
                        )
                    }
                } else {
                    ColorPicker("Primary", selection: hexColorBinding($project.settings.backgroundColor))
                        .font(.system(size: 11))
                    if project.settings.backgroundStyle == .gradient {
                        ColorPicker("Secondary", selection: hexColorBinding($project.settings.secondaryBackgroundColor))
                            .font(.system(size: 11))
                    }
                }
            }
        }
    }

    private var cursorInspector: some View {
        Group {
            InspectorSection("Appearance") {
                Toggle("Show cursor", isOn: Binding(
                    get: { project.settings.resolvedShowCursor },
                    set: { project.settings.showCursor = $0 }
                ))
                .font(.system(size: 11))
                .accessibilityIdentifier("cursor.showCursor")
                .help("Hiding the pointer keeps click effects and zooms. It does not erase a pointer already baked into an imported video or screenshot.")
                cursorStyleGallery
                if project.settings.resolvedCursorAppearance.usesAccentTint {
                    // The Accent pointer inks itself from the click colour, whose
                    // only other control lives behind the Animate clicks toggle.
                    ColorPicker("Color", selection: hexColorBinding(clickAnimationBinding(\.colorHex)), supportsOpacity: false)
                        .font(.system(size: 11))
                        .disabled(!project.settings.resolvedShowCursor)
                }
                LabeledSlider(value: $project.settings.cursorScale, range: 0.5...3, label: "Size", suffix: "×", decimals: 2)
                    .disabled(!project.settings.resolvedShowCursor)
                Picker("Cursor press", selection: pressStyleBinding) {
                    ForEach(ClickPressStyle.allCases, id: \.self) { style in
                        Text(LocalizedStringKey(style.title)).tag(style)
                    }
                }
                .accessibilityIdentifier("cursor.pressStyle")
                .disabled(!project.settings.resolvedShowCursor)
                if pressStyleBinding.wrappedValue != .none {
                    LabeledSlider(value: pressAmountBinding, range: 0...1, label: "Press amount", suffix: "%", multiplier: 100, decimals: 0)
                        .disabled(!project.settings.resolvedShowCursor)
                }
                Toggle("Hide cursor while idle", isOn: $project.settings.hideIdleCursor)
                    .font(.system(size: 11))
                    .disabled(!project.settings.resolvedShowCursor)
            }
            InspectorSection("Click feedback") {
                Toggle("Animate clicks", isOn: $project.settings.showClickRing)
                    .font(.system(size: 11))
                    .accessibilityIdentifier("cursor.animateClicks")
                if project.settings.showClickRing {
                    Picker("Effect", selection: clickAnimationBinding(\.style)) {
                        ForEach(ClickAnimationStyle.allCases, id: \.self) { style in
                            Text(LocalizedStringKey(style.title)).tag(style)
                        }
                    }
                    .accessibilityIdentifier("cursor.clickEffect")
                    ColorPicker("Color", selection: hexColorBinding(clickAnimationBinding(\.colorHex)), supportsOpacity: false)
                        .font(.system(size: 11))
                    LabeledSlider(value: clickAnimationBinding(\.size), range: 0.4...2.5, label: "Effect size", suffix: "×", decimals: 2)
                    LabeledSlider(value: clickAnimationBinding(\.duration), range: 0.25...1.5, label: "Duration", suffix: "s", decimals: 2)
                    LabeledSlider(value: clickAnimationBinding(\.intensity), range: 0...1, label: "Intensity", suffix: "%", multiplier: 100, decimals: 0)
                }
                Text(LocalizedStringKey(project.clickEvents.isEmpty
                     ? "This recording has no captured clicks. Enable Input Monitoring before recording to capture clicks in other apps."
                     : "Feedback stays at each click location. Play or scrub to a click to preview your changes."))
                    .font(.system(size: 9))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .lineSpacing(2)
            }
            InspectorSection("Movement") {
                Picker("Smoothing", selection: $project.settings.cursorAnimation) {
                    ForEach(CursorAnimationStyle.allCases, id: \.self) { style in
                        Text(LocalizedStringKey(style.rawValue.capitalized)).tag(style)
                    }
                }
                .disabled(!project.settings.resolvedShowCursor)
            }
        }
    }

    private var audioInspector: some View {
        Group {
            InspectorSection("Product demo mix") {
                if project.settings.productDemoAudio == nil {
                    Label("Nothing has been added", systemImage: "checkmark.shield")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioTheme.secondaryText)
                    Button {
                        project.settings.productDemoAudio = ProductDemoAudioSettings()
                    } label: {
                        Label("Add music or effects", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(role: .destructive) {
                        project.settings.productDemoAudio = nil
                    } label: {
                        Label("Remove added audio", systemImage: "trash")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                }
            }

            if project.settings.productDemoAudio != nil {
                InspectorSection("Captured audio") {
                    LabeledSlider(
                        value: audioBinding(\.sourceAudioVolume),
                        range: 0...1,
                        label: "Original",
                        suffix: "%",
                        multiplier: 100,
                        decimals: 0
                    )
                }

                InspectorSection("Background music") {
                    HStack(spacing: 7) {
                        Image(systemName: "music.note")
                            .foregroundStyle(StudioTheme.purple)
                        Text(backgroundMusicName)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                    }

                    VStack(spacing: 6) {
                        ForEach(model.bundledMusicAssets) { asset in
                            Button {
                                selectBackgroundMusic(asset)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: isSelectedMusic(asset) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelectedMusic(asset) ? StudioTheme.purple : StudioTheme.secondaryText)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(LocalizedStringKey(asset.title))
                                            .font(.system(size: 9, weight: .semibold))
                                        Text(LocalizedStringKey(asset.mood))
                                            .font(.system(size: 8))
                                            .foregroundStyle(StudioTheme.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(asset.durationSeconds.formatted(.number.precision(.fractionLength(0))) + "s")
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(StudioTheme.secondaryText)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 38)
                                .background(Color.white.opacity(isSelectedMusic(asset) ? 0.07 : 0.025))
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Import…") {
                            Task {
                                if let path = await model.importBackgroundMusic(for: project) {
                                    var audio = project.settings.resolvedProductDemoAudio
                                    audio.backgroundMusicPath = path
                                    project.settings.productDemoAudio = audio
                                }
                            }
                        }
                        if project.settings.resolvedProductDemoAudio.backgroundMusicPath != nil {
                            Button {
                                var audio = project.settings.resolvedProductDemoAudio
                                audio.backgroundMusicPath = nil
                                project.settings.productDemoAudio = audio
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .help("Remove background music")
                        }
                    }
                    .font(.system(size: 9, weight: .medium))

                    LabeledSlider(
                        value: audioBinding(\.backgroundMusicVolume),
                        range: 0...0.65,
                        label: "Music",
                        suffix: "%",
                        multiplier: 100,
                        decimals: 0
                    )
                    LabeledSlider(
                        value: audioBinding(\.backgroundMusicFadeIn),
                        range: 0...4,
                        label: "Fade in",
                        suffix: "s",
                        decimals: 1
                    )
                    LabeledSlider(
                        value: audioBinding(\.backgroundMusicFadeOut),
                        range: 0...5,
                        label: "Fade out",
                        suffix: "s",
                        decimals: 1
                    )
                }

                InspectorSection("Sound effects") {
                    Toggle("Click confirmation", isOn: audioBinding(\.clickSoundEnabled))
                        .font(.system(size: 11))
                    if project.settings.resolvedProductDemoAudio.clickSoundEnabled {
                        Picker("Sound", selection: clickSoundAssetBinding) {
                            ForEach(clickSoundAssets) { asset in
                                Text(LocalizedStringKey(asset.title)).tag(asset.id)
                            }
                        }
                        LabeledSlider(
                            value: audioBinding(\.clickSoundVolume),
                            range: 0...1,
                            label: "Click",
                            suffix: "%",
                            multiplier: 100,
                            decimals: 0
                        )
                    }
                    Toggle("Zoom whoosh", isOn: audioBinding(\.zoomTransitionSoundEnabled))
                        .font(.system(size: 11))
                    if project.settings.resolvedProductDemoAudio.zoomTransitionSoundEnabled {
                        if let asset = zoomSoundAsset {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform")
                                Text(LocalizedStringKey(asset.title))
                                Spacer()
                                Text(LocalizedStringKey(asset.mood))
                                    .foregroundStyle(StudioTheme.secondaryText)
                            }
                            .font(.system(size: 9))
                        }
                        LabeledSlider(
                            value: audioBinding(\.zoomTransitionSoundVolume),
                            range: 0...1,
                            label: "Whoosh",
                            suffix: "%",
                            multiplier: 100,
                            decimals: 0
                        )
                    }
                }
            }
        }
    }

    private var animationInspector: some View {
        Group {
            InspectorSection("Screen animation") {
                Picker("Style", selection: $project.settings.screenAnimation) {
                    ForEach(ScreenAnimationStyle.allCases, id: \.self) { style in
                        Text(LocalizedStringKey(style.title)).tag(style)
                    }
                }
                LabeledSlider(value: zoomTimingBinding(\.zoomEaseIn), range: 0.05...1, label: "Zoom in", suffix: "s", decimals: 2)
                LabeledSlider(value: zoomHoldBinding, range: 0.2...3, label: "Click hold", suffix: "s", decimals: 2)
                LabeledSlider(value: zoomTimingBinding(\.zoomEaseOut), range: 0.05...1.4, label: "Zoom out", suffix: "s", decimals: 2)
                LabeledSlider(value: zoomChainGapBinding, range: 0...ProjectSettings.maximumZoomChainGap, label: "Link nearby clicks", suffix: "s", decimals: 1)
                LabeledSlider(value: zoomFollowBinding, range: 0...1, label: "Follow cursor", suffix: "%", multiplier: 100, decimals: 0)
            }
            InspectorSection("Typing focus") {
                Toggle("Hold zoom while typing", isOn: typingZoomBinding(\.enabled))
                    .font(.system(size: 11))
                    .accessibilityIdentifier("animation.holdWhileTyping")
                if project.settings.resolvedTypingZoom.enabled {
                    LabeledSlider(value: typingZoomBinding(\.idleDelay), range: 0.4...5, label: "Wait after typing", suffix: "s", decimals: 1)
                }
                if hasMissingInteractionTrace {
                    missingInteractionWarning
                } else {
                    Text(LocalizedStringKey((project.typingActivity ?? []).isEmpty
                         ? "No typing activity was captured in this recording. You can extend a zoom block manually on the timeline; new recordings capture typing timing with Accessibility enabled."
                         : "Keep the input in focus until typing pauses, then ease back out. Changes rebuild automatic zooms and preserve your manual blocks."))
                        .font(.system(size: 9))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .lineSpacing(2)
                }
            }
            InspectorSection("Motion") {
                LabeledSlider(value: $project.settings.motionBlur, range: 0...1, label: "Motion blur", suffix: "%", multiplier: 100, decimals: 0)
            }
        }
    }

    private var exportInspector: some View {
        Group {
            InspectorSection("Video") {
                Picker("Resolution", selection: $project.settings.exportWidth) {
                    Text("1280p").tag(1280)
                    Text("1920p").tag(1920)
                    Text("2560p").tag(2560)
                    Text("3840p").tag(3840)
                }
                Picker("Frame rate", selection: $project.settings.frameRate) {
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
            }
            Text("Exports H.264 MP4 with the current music, effects, source-audio mix, zooms, and design. All processing happens locally.")
                .font(.system(size: 10))
                .foregroundStyle(StudioTheme.secondaryText)
                .lineSpacing(2)
        }
    }

    private func audioBinding<Value>(
        _ keyPath: WritableKeyPath<ProductDemoAudioSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { project.settings.resolvedProductDemoAudio[keyPath: keyPath] },
            set: { newValue in
                var audio = project.settings.resolvedProductDemoAudio
                audio[keyPath: keyPath] = newValue
                project.settings.productDemoAudio = audio
            }
        )
    }

    private var backgroundMusicName: String {
        guard let path = project.settings.resolvedProductDemoAudio.backgroundMusicPath else {
            return "No music selected"
        }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private var backgroundBlurBinding: Binding<Double> {
        Binding(
            get: { project.settings.resolvedBackgroundBlur },
            set: { project.settings.backgroundBlur = $0 }
        )
    }

    private var backgroundBrightnessBinding: Binding<Double> {
        Binding(
            get: { project.settings.resolvedBackgroundBrightness },
            set: { project.settings.backgroundBrightness = $0 }
        )
    }

    private var cursorAppearanceBinding: Binding<CursorAppearance> {
        Binding(
            get: { project.settings.resolvedCursorAppearance },
            set: { project.settings.cursorAppearance = $0 }
        )
    }

    /// Choosing `None` switches the pointer reaction off through the original
    /// flag, so projects written before press styles keep the same meaning.
    private var pressStyleBinding: Binding<ClickPressStyle> {
        Binding(
            get: { project.settings.resolvedClickAnimation.resolvedPressStyle },
            set: { style in
                var settings = project.settings.resolvedClickAnimation
                settings.pressCursor = style != .none
                if style != .none { settings.pressStyle = style }
                project.settings.clickAnimation = settings
            }
        )
    }

    private var pressAmountBinding: Binding<Double> {
        Binding(
            get: { project.settings.resolvedClickAnimation.resolvedPressAmount },
            set: { value in
                var settings = project.settings.resolvedClickAnimation
                settings.pressAmount = value
                project.settings.clickAnimation = settings
            }
        )
    }

    private var cursorStyleGallery: some View {
        VStack(alignment: .leading, spacing: 7) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3),
                spacing: 7
            ) {
                ForEach(CursorAppearance.allCases, id: \.self) { appearance in
                    Button {
                        cursorAppearanceBinding.wrappedValue = appearance
                        // Choosing a pointer that is switched off would be a
                        // control that visibly does nothing.
                        if !project.settings.resolvedShowCursor { project.settings.showCursor = true }
                    } label: {
                        CursorStyleSwatch(
                            appearance: appearance,
                            tintHex: project.settings.resolvedClickAnimation.colorHex,
                            isSelected: project.settings.resolvedCursorAppearance == appearance
                        )
                    }
                    .buttonStyle(.plain)
                    .help(LocalizedStringKey(appearance.title))
                    .accessibilityLabel(Text(LocalizedStringKey(appearance.title)))
                    .accessibilityIdentifier("cursor.style.\(appearance.rawValue)")
                }
            }
            Text(LocalizedStringKey(project.settings.resolvedCursorAppearance.title))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(StudioTheme.secondaryText)
        }
        .accessibilityIdentifier("cursor.styleGallery")
    }

    private func clickAnimationBinding<Value>(
        _ keyPath: WritableKeyPath<ClickAnimationSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { project.settings.resolvedClickAnimation[keyPath: keyPath] },
            set: { value in
                var settings = project.settings.resolvedClickAnimation
                settings[keyPath: keyPath] = value
                project.settings.clickAnimation = settings
            }
        )
    }

    private var clickSoundAssets: [AudioAssetCatalog.Asset] {
        let preferred = model.bundledSoundEffectAssets.filter { $0.id != "zoom-whoosh" }
        return preferred.isEmpty ? model.bundledSoundEffectAssets : preferred
    }

    private var zoomSoundAsset: AudioAssetCatalog.Asset? {
        model.bundledSoundEffectAssets.first { $0.id == "zoom-whoosh" }
    }

    private var clickSoundAssetBinding: Binding<String> {
        Binding(
            get: {
                let current = project.settings.resolvedProductDemoAudio.clickSoundPath
                return clickSoundAssets.first(where: {
                    model.bundledAudioPath(for: $0) == current
                })?.id ?? clickSoundAssets.first?.id ?? ""
            },
            set: { id in
                guard let asset = clickSoundAssets.first(where: { $0.id == id }),
                      let path = model.bundledAudioPath(for: asset)
                else { return }
                var audio = project.settings.resolvedProductDemoAudio
                audio.clickSoundPath = path
                audio.clickSoundVolume = asset.suggestedVolume
                project.settings.productDemoAudio = audio
            }
        )
    }

    private func selectBackgroundMusic(_ asset: AudioAssetCatalog.Asset) {
        guard let path = model.bundledAudioPath(for: asset) else { return }
        var audio = project.settings.resolvedProductDemoAudio
        audio.backgroundMusicPath = path
        audio.backgroundMusicVolume = asset.suggestedVolume
        project.settings.productDemoAudio = audio
    }

    private func isSelectedMusic(_ asset: AudioAssetCatalog.Asset) -> Bool {
        guard let path = model.bundledAudioPath(for: asset) else { return false }
        return project.settings.resolvedProductDemoAudio.backgroundMusicPath == path
    }

    private var zoomHoldBinding: Binding<Double> {
        Binding(
            get: { project.settings.zoomHold },
            set: { newValue in
                let oldValue = project.settings.zoomHold
                project.settings.zoomHold = newValue
                TimelineMath.adjustAutomaticClickHold(in: &project, by: newValue - oldValue)
            }
        )
    }

    private var zoomFollowBinding: Binding<Double> {
        Binding(
            get: { project.settings.resolvedZoomFollowsCursor },
            set: { project.settings.zoomFollowsCursor = $0 }
        )
    }

    private var zoomChainGapBinding: Binding<Double> {
        Binding(
            get: { project.settings.resolvedZoomChainGap },
            set: { value in
                project.settings.zoomChainGap = value
                // Chaining only changes how automatic cues are grouped; manual
                // blocks are preserved by regeneration.
                TimelineMath.regenerateAutomaticZoomSegments(in: &project)
            }
        )
    }

    private func zoomTimingBinding(_ keyPath: WritableKeyPath<ProjectSettings, Double>) -> Binding<Double> {
        Binding(
            get: { project.settings[keyPath: keyPath] },
            set: { value in
                let previous = project.settings[keyPath: keyPath]
                project.settings[keyPath: keyPath] = value
                if keyPath == \ProjectSettings.zoomEaseOut {
                    // Keep the hold's release time and the user's retiming intact;
                    // only the outgoing envelope gains/loses this duration.
                    TimelineMath.adjustAutomaticHold(
                        in: &project.zoomSegments,
                        by: value - previous,
                        duration: project.duration
                    )
                }
            }
        )
    }

    private func typingZoomBinding<Value>(_ keyPath: WritableKeyPath<TypingZoomSettings, Value>) -> Binding<Value> {
        Binding(
            get: { project.settings.resolvedTypingZoom[keyPath: keyPath] },
            set: { value in
                var settings = project.settings.resolvedTypingZoom
                settings[keyPath: keyPath] = value
                project.settings.typingZoom = settings.sanitized
                if !(project.typingActivity ?? []).isEmpty {
                    TimelineMath.regenerateAutomaticZoomSegments(in: &project)
                }
            }
        )
    }

    private var cropPresetBinding: Binding<ContentCropPreset> {
        Binding(
            get: {
                let crop = project.settings.sourceCropInsets?.sanitized ?? SourceCropInsets()
                if crop.isEffectivelyEmpty { return .fullWindow }
                if ContentCropPreset.chrome.matches(crop) { return .chrome }
                if ContentCropPreset.safari.matches(crop) { return .safari }
                return .custom
            },
            set: { preset in
                switch preset {
                case .fullWindow:
                    project.settings.sourceCropInsets = nil
                case .chrome:
                    project.settings.sourceCropInsets = .chromeContent
                case .safari:
                    project.settings.sourceCropInsets = .safariContent
                case .custom:
                    if project.settings.sourceCropInsets?.isEffectivelyEmpty != false {
                        project.settings.sourceCropInsets = SourceCropInsets(top: 0.08)
                    }
                }
            }
        )
    }

    private func cropInsetBinding(
        _ keyPath: WritableKeyPath<SourceCropInsets, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                (project.settings.sourceCropInsets?.sanitized ?? SourceCropInsets())[keyPath: keyPath]
            },
            set: { newValue in
                var crop = project.settings.sourceCropInsets?.sanitized ?? SourceCropInsets()
                crop[keyPath: keyPath] = newValue
                crop = crop.sanitized
                project.settings.sourceCropInsets = crop.isEffectivelyEmpty ? nil : crop
            }
        )
    }

    private func hexColorBinding(_ value: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: value.wrappedValue) },
            set: { color in value.wrappedValue = color.hexString ?? value.wrappedValue }
        )
    }
}

// MARK: - Captions

private let chapterTint = Color(red: 0.13, green: 0.66, blue: 0.80)

extension EditorInspectorView {
    /// Chapters in playback order; numbering matches the timeline, SRT and video.
    private var sortedChapters: [DemoChapter] {
        (project.chapters ?? []).sorted(by: ChapterMath.precedes)
    }

    private var selectedChapter: DemoChapter? {
        guard let selectedChapterID else { return nil }
        return project.chapters?.first { $0.id == selectedChapterID }
    }

    private func chapterNumber(_ id: UUID) -> Int {
        (sortedChapters.firstIndex { $0.id == id } ?? 0) + 1
    }

    @ViewBuilder
    private var captionsInspector: some View {
        let chapters = sortedChapters
        InspectorSection("Chapters") {
            if chapters.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "captions.bubble")
                    Text("No chapters")
                }
                .font(.system(size: 10))
                .foregroundStyle(StudioTheme.secondaryText)
                .help("Double-click the Chapters lane or add one here")
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        chapterRow(chapter, number: index + 1)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Add chapter", action: addChapter)
                    .help("Add a 4-second chapter after the last one")
                    .accessibilityIdentifier("captions.addChapter")
                Button("From zooms", action: deriveChaptersFromZooms)
                    .help("Create chapters from the zoom blocks")
                    .accessibilityIdentifier("captions.fromZooms")
                Button("Export SRT…", action: exportSRT)
                    .disabled(chapters.isEmpty)
                    .help("Save captions as a SubRip subtitle file")
            }
            .font(.system(size: 10, weight: .medium))
            .controlSize(.small)
        }

        if let selected = selectedChapter {
            let chapter = chapterBinding(selected)
            InspectorSection(L10n.format("Chapter %lld", chapterNumber(selected.id))) {
                TextField("Title", text: chapter.title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .accessibilityIdentifier("captions.title")
                TextField("Caption", text: chapter.caption, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .help("Shown on the video; the title is used when empty")
                    .accessibilityIdentifier("captions.caption")
                NumberField(
                    title: "Start",
                    value: chapterTimeBinding(chapter, value: \.start, edit: ChapterEdit.start),
                    range: 0...max(0, project.duration),
                    suffix: "s"
                )
                NumberField(
                    title: "End",
                    value: chapterTimeBinding(chapter, value: \.end, edit: ChapterEdit.end),
                    range: 0...max(0, project.duration),
                    suffix: "s"
                )
                Toggle("Enabled", isOn: chapter.isEnabled)
                    .font(.system(size: 11))
                Button(role: .destructive) {
                    removeChapter(selected.id)
                } label: {
                    Label("Remove", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioTheme.red)
            }
            .id(selected.id)
        }

        InspectorSection("Style") {
            Picker("Position", selection: captionStyleBinding(\.position)) {
                Text("Bottom").tag(CaptionPosition.bottom)
                Text("Top").tag(CaptionPosition.top)
            }
            LabeledSlider(
                value: captionStyleBinding(\.scale),
                range: CaptionStyle.scaleRange,
                label: "Size",
                suffix: "×",
                decimals: 2
            )
            Toggle("Chapter number", isOn: captionStyleBinding(\.showsChapterNumber))
                .font(.system(size: 11))
                .help("Show the chapter number on the caption")
            ColorPicker("Accent", selection: accentColorBinding, supportsOpacity: false)
                .font(.system(size: 11))
                .disabled(!project.settings.resolvedCaptionStyle.showsChapterNumber)
        }

        InspectorSection("AI") {
            TextField("What does this demo show?", text: productDescriptionBinding, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .help("Used to write chapter titles and captions")
                .accessibilityIdentifier("captions.productDescription")
            HStack(spacing: 8) {
                Button("Generate chapters", action: generateChapters)
                    .help(LocalizedStringKey(textCompletion == nil
                        ? "Set up an AI model in Settings"
                        : "Write chapters from the clicks, zooms and typing"))
                    .accessibilityIdentifier("captions.generate")
                Button("Polish captions", action: polishCaptions)
                    .disabled(chapters.isEmpty)
                    .help(LocalizedStringKey(textCompletion == nil
                        ? "Set up an AI model in Settings"
                        : "Rewrite every caption concisely"))
                    .accessibilityIdentifier("captions.polish")
                if isGeneratingChapters {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .controlSize(.small)
            .disabled(textCompletion == nil || isGeneratingChapters)
            if let captionsMessage {
                Text(verbatim: captionsMessage)
                    .font(.system(size: 9))
                    .foregroundStyle(StudioTheme.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chapterRow(_ chapter: DemoChapter, number: Int) -> some View {
        let isSelected = selectedChapterID == chapter.id
        return HStack(spacing: 7) {
            Text(verbatim: "\(number)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(chapter.isEnabled ? chapterTint : Color.gray.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Group {
                    if chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Untitled")
                    } else {
                        Text(verbatim: chapter.title)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                Text(verbatim: "\(seconds(chapter.start))–\(seconds(chapter.end))s")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(StudioTheme.secondaryText)
            }
            Spacer(minLength: 4)
            Toggle("Enabled", isOn: chapterBinding(chapter).isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 7)
        .frame(height: 36)
        .background(Color.white.opacity(isSelected ? 0.08 : 0.025))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? chapterTint.opacity(0.9) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedChapterID = chapter.id }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Chapter \(number)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("captions.chapter.\(chapter.id.uuidString)")
    }

    private func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    private func chapterBinding(_ chapter: DemoChapter) -> Binding<DemoChapter> {
        Binding(
            get: { project.chapters?.first { $0.id == chapter.id } ?? chapter },
            set: { updated in
                guard let index = project.chapters?.firstIndex(where: { $0.id == chapter.id }) else { return }
                project.chapters?[index] = updated
            }
        )
    }

    private func chapterTimeBinding(
        _ chapter: Binding<DemoChapter>,
        value: KeyPath<DemoChapter, Double>,
        edit: @escaping (Double) -> ChapterEdit
    ) -> Binding<Double> {
        Binding(
            get: { chapter.wrappedValue[keyPath: value] },
            set: { requested in
                chapter.wrappedValue = ChapterMath.applying(
                    edit(requested),
                    to: chapter.wrappedValue,
                    duration: project.duration
                )
            }
        )
    }

    private func captionStyleBinding<Value>(
        _ keyPath: WritableKeyPath<CaptionStyle, Value>
    ) -> Binding<Value> {
        Binding(
            get: { project.settings.resolvedCaptionStyle[keyPath: keyPath] },
            set: { newValue in
                var style = project.settings.resolvedCaptionStyle
                style[keyPath: keyPath] = newValue
                project.settings.captionStyle = style.sanitized
            }
        )
    }

    private var accentColorBinding: Binding<Color> {
        hexColorBinding(Binding(
            get: { project.settings.resolvedCaptionStyle.resolvedAccentColorHex },
            set: { hex in
                var style = project.settings.resolvedCaptionStyle
                style.accentColor = hex
                project.settings.captionStyle = style
            }
        ))
    }

    private var productDescriptionBinding: Binding<String> {
        Binding(
            get: { project.settings.productDescription ?? "" },
            set: { project.settings.productDescription = $0.isEmpty ? nil : $0 }
        )
    }

    private func addChapter() {
        let existing = project.chapters ?? []
        guard let chapter = ChapterMath.newChapter(
            at: existing.map(\.end).max() ?? 0,
            duration: project.duration,
            title: L10n.format("Chapter %lld", existing.count + 1)
        ) else { return }
        project.chapters = existing + [chapter]
        selectedChapterID = chapter.id
    }

    private func removeChapter(_ id: UUID) {
        project.chapters?.removeAll { $0.id == id }
        if selectedChapterID == id { selectedChapterID = nil }
    }

    private func deriveChaptersFromZooms() {
        let derived = ChapterMath.chaptersFromZooms(project: project) { L10n.format("Chapter %lld", $0) }
        project.chapters = derived
        selectedChapterID = derived.first?.id
        captionsMessage = nil
    }

    private func exportSRT() {
        let panel = NSSavePanel()
        panel.title = L10n.tr("Export captions")
        panel.nameFieldStringValue = "\(project.title).srt"
        panel.allowedContentTypes = [UTType(filenameExtension: "srt", conformingTo: .plainText) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = ChapterMath.srt(for: ChapterMath.sanitized(project.chapters ?? [], duration: project.duration))
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            captionsMessage = nil
        } catch {
            captionsMessage = error.localizedDescription
        }
    }

    private func generateChapters() {
        guard let provider = textCompletion, !isGeneratingChapters else { return }
        let snapshot = project
        let language = L10n.locale.identifier
        isGeneratingChapters = true
        captionsMessage = nil
        Task { @MainActor in
            defer { isGeneratingChapters = false }
            do {
                let chapters = try await DemoChapterGenerator.generateChapters(
                    project: snapshot,
                    language: language,
                    provider: provider
                )
                project.chapters = chapters
                selectedChapterID = chapters.first?.id
            } catch {
                captionsMessage = L10n.tr(error.localizedDescription)
            }
        }
    }

    private func polishCaptions() {
        guard let provider = textCompletion, !isGeneratingChapters else { return }
        let snapshot = project
        let chapters = sortedChapters
        let language = L10n.locale.identifier
        isGeneratingChapters = true
        captionsMessage = nil
        Task { @MainActor in
            defer { isGeneratingChapters = false }
            do {
                project.chapters = try await DemoChapterGenerator.polishCaptions(
                    chapters,
                    project: snapshot,
                    language: language,
                    provider: provider
                )
            } catch {
                captionsMessage = L10n.tr(error.localizedDescription)
            }
        }
    }
}

private enum ContentCropPreset: String, CaseIterable, Identifiable {
    case fullWindow
    case chrome
    case safari
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullWindow: return "Full window"
        case .chrome: return "Chrome page"
        case .safari: return "Safari page"
        case .custom: return "Custom"
        }
    }

    func matches(_ crop: SourceCropInsets) -> Bool {
        let expected: SourceCropInsets
        switch self {
        case .chrome: expected = .chromeContent
        case .safari: expected = .safariContent
        case .fullWindow: expected = SourceCropInsets()
        case .custom: return false
        }
        let value = crop.sanitized
        let reference = expected.sanitized
        return abs(value.top - reference.top) < 0.000_001
            && abs(value.leading - reference.leading) < 0.000_001
            && abs(value.bottom - reference.bottom) < 0.000_001
            && abs(value.trailing - reference.trailing) < 0.000_001
    }
}

/// The same treatment as a system wallpaper swatch, for an image that ships
/// with the app rather than one found on the Mac.
private struct BackgroundAssetSwatch: View {
    let url: URL
    let isSelected: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.05))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(StudioTheme.secondaryText)
            }
        }
        .frame(width: 82, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isSelected ? Color.white : Color.white.opacity(0.13),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                    .padding(4)
            }
        }
        .task(id: url.path) {
            guard thumbnail == nil else { return }
            thumbnail = WallpaperSwatch.loadThumbnail(from: url)
        }
    }
}

private struct WallpaperSwatch: View {
    let wallpaper: SystemWallpaper
    let isSelected: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.05))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(StudioTheme.secondaryText)
            }
        }
        .frame(width: 82, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isSelected ? Color.white : Color.white.opacity(0.13),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                    .padding(4)
            }
        }
        .task(id: wallpaper.path) {
            guard thumbnail == nil else { return }
            thumbnail = Self.loadThumbnail(from: wallpaper.url)
        }
    }

    static func loadThumbnail(from url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

/// The gallery draws the same artwork the renderer uses, so a swatch can never
/// promise a pointer the export will not produce.
private struct CursorStyleSwatch: View {
    let appearance: CursorAppearance
    let tintHex: String
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.9), Color(white: 0.17)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            if let image = CursorSwatchCache.image(for: appearance, tintHex: tintHex) {
                Image(decorative: image, scale: 2)
                    .interpolation(.high)
            }
        }
        .frame(height: 40)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isSelected ? Color.white : Color.white.opacity(0.13),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .padding(3)
            }
        }
    }
}

/// Swatches are bitmaps; redrawing them on every inspector layout pass would
/// rasterize six cursors per keystroke elsewhere in the panel.
@MainActor
private enum CursorSwatchCache {
    private static var images: [String: CGImage] = [:]

    static func image(for appearance: CursorAppearance, tintHex: String) -> CGImage? {
        let key = appearance.rawValue + (appearance.usesAccentTint ? "-\(tintHex)" : "")
        if let cached = images[key] { return cached }
        let tint = NSColor(Color(hex: tintHex))
        guard let made = CursorArtwork.preview(
            for: appearance,
            tint: tint,
            size: CGSize(width: 54, height: 66)
        ) else { return nil }
        images[key] = made
        return made
    }
}

private struct BackgroundPresetSwatch: View {
    let preset: BackgroundPreset
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(hex: preset.primaryHex), Color(hex: preset.secondaryHex)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(height: 34)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        isSelected ? Color.white : Color.white.opacity(0.13),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                        .padding(4)
                }
            }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(LocalizedStringKey(title))
                .textCase(.uppercase)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(StudioTheme.secondaryText)
            content
        }
        .padding(13)
        .background(Color.white.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(StudioTheme.line, lineWidth: 1)
        )
    }
}

private struct LabeledSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var label: String = "Amount"
    var suffix: String = ""
    var multiplier = 1.0
    var decimals = 1

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(LocalizedStringKey(label))
                Spacer()
                Text("\((value * multiplier).formatted(.number.precision(.fractionLength(decimals))))\(suffix)")
                    .fontDesign(.monospaced)
                    .foregroundStyle(StudioTheme.secondaryText)
            }
            .font(.system(size: 10))
            Slider(value: $value, in: range)
                .controlSize(.small)
                .accessibilityLabel(Text(LocalizedStringKey(label)))
        }
    }
}

private struct NumberField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String
    @State private var draft = ""
    @State private var originalDraft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text(LocalizedStringKey(title)).font(.system(size: 10))
            Spacer()
            TextField(LocalizedStringKey(title), text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
                .focused($isFocused)
                .accessibilityLabel(Text(LocalizedStringKey(title)))
                .onSubmit { commit() }
                .onAppear { refresh() }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onChange(of: value) { _, newValue in
                    if !isFocused { refresh() }
                }
            Text(suffix)
                .font(.system(size: 9))
                .foregroundStyle(StudioTheme.secondaryText)
        }
    }

    private func refresh() {
        draft = value.formatted(.number.precision(.fractionLength(2)).grouping(.never))
        originalDraft = draft
    }

    private func commit() {
        // Merely focusing a rounded display must not rewrite its full-precision
        // value or silently turn an automatic cue into a manual override.
        guard draft != originalDraft else { return }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        let number = Double(draft.trimmingCharacters(in: .whitespaces))
            ?? formatter.number(from: draft)?.doubleValue
        if let number, number.isFinite {
            let bounded = number.clamped(to: range)
            if abs(bounded - value) > 0.000_000_001 { value = bounded }
        }
        refresh()
    }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var number: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&number)
        let red, green, blue: Double
        if cleaned.count == 6 {
            red = Double((number >> 16) & 0xff) / 255
            green = Double((number >> 8) & 0xff) / 255
            blue = Double(number & 0xff) / 255
        } else {
            red = 0.42; green = 0.36; blue = 0.96
        }
        self.init(red: red, green: green, blue: blue)
    }

    var hexString: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int(color.redComponent * 255),
            Int(color.greenComponent * 255),
            Int(color.blueComponent * 255)
        )
    }
}
