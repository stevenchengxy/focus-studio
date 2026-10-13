import AppKit
import AVFoundation
import FocusStudioAutomation
import FocusStudioCore
import ImageIO
import SwiftUI

extension RegionEffectPreset {
    var displayTitle: String {
        switch self {
        case .spotlight: return "Spotlight"
        case .lift: return "Lift card"
        case .tilt: return "Tilt card"
        case .perspective: return "Perspective card"
        case .magnify: return "Magnifier"
        case .outline: return "Draw outline"
        }
    }
    var symbol: String {
        switch self {
        case .spotlight: return "viewfinder"
        case .lift: return "rectangle.on.rectangle"
        case .tilt: return "rotate.right"
        case .perspective: return "rectangle.portrait.rotate"
        case .magnify: return "magnifyingglass"
        case .outline: return "rectangle.dashed"
        }
    }
}

extension RegionEffectBackground {
    var displayTitle: String {
        switch self {
        case .dim: return "Dim"
        case .blur: return "Blur"
        case .none: return "None"
        }
    }
}

/// UI timing is constrained to the visible clip. Persisted effects keep their
/// source bounds so trimming and later restoring footage is non-destructive.
enum EditorRegionTiming {
    static func availableRange(in clip: DemoVideoClip, project: RecordingProject,
                               near time: Double, excludingID: UUID? = nil) -> ClosedRange<Double>? {
        let others = (project.regionEffects ?? []).filter {
            $0.id != excludingID && $0.clipID == clip.id && $0.isEnabled
                && $0.sourceEnd > clip.sourceStart && $0.sourceStart < clip.sourceEnd
        }.sorted { $0.sourceStart < $1.sourceStart }
        var free: [ClosedRange<Double>] = []
        var lower = clip.sourceStart
        for effect in others {
            let upper = min(clip.sourceEnd, effect.sourceStart)
            if upper - lower >= 0.1 { free.append(lower...upper) }
            lower = max(lower, effect.sourceEnd)
        }
        if clip.sourceEnd - lower >= 0.1 { free.append(lower...clip.sourceEnd) }
        return free.first { $0.contains(time) }
            ?? free.first { $0.lowerBound >= time }
            ?? free.last
    }

    static func duplicate(_ original: RegionEffect, project: RecordingProject) -> RegionEffect? {
        guard let timeline = try? DemoVideoTimeline(project: project),
              let clip = timeline.clips.first(where: { $0.id == original.clipID }),
              let range = availableRange(in: clip, project: project, near: original.sourceEnd) else { return nil }
        var copy = original
        copy.id = UUID()
        let length = min(original.sourceEnd - original.sourceStart, range.upperBound - range.lowerBound)
        copy.sourceStart = original.sourceEnd.clamped(to: range.lowerBound...(range.upperBound - length))
        copy.sourceEnd = copy.sourceStart + length
        // Both the inspector and the lane append only this validated result.
        // In particular, a full project must not save an invisible 129th cue.
        guard (try? RegionEffectValidator.validate(copy, in: project)) != nil else { return nil }
        return copy
    }

    static func selectionSourceTime(effect: RegionEffect?, clip: DemoVideoClip,
                                    timelineStart: Double, currentTime: Double) -> Double {
        let sourceTime = clip.sourceStart + currentTime - timelineStart
        guard let effect else { return sourceTime.clamped(to: clip.sourceStart...clip.sourceEnd) }
        let visibleStart = max(effect.sourceStart, clip.sourceStart)
        let visibleEnd = min(effect.sourceEnd, clip.sourceEnd)
        if visibleStart < visibleEnd {
            if currentTime >= timelineStart, currentTime < timelineStart + clip.duration,
               sourceTime >= visibleStart, sourceTime < visibleEnd { return sourceTime }
            return (visibleStart + visibleEnd) / 2
        }
        // A completely hidden cue still has a meaningful source frame. Do not
        // substitute a different page from the current clip's trimmed range.
        return (effect.sourceStart + effect.sourceEnd) / 2
    }

    static func decodableSourceTime(_ time: Double, sourceBounds: ClosedRange<Double>, frameRate: Int) -> Double {
        let lastFrame = max(sourceBounds.lowerBound,
                            sourceBounds.upperBound - 1 / Double(max(1, frameRate)))
        return time.clamped(to: sourceBounds.lowerBound...lastFrame)
    }
}

struct RegionSelectionRequest: Identifiable {
    let id = UUID()
    let effectID: UUID?
    let clipID: UUID
    let sourceTime: Double
    let initialRect: NormalizedRegionRect?
}

/// Select on the source frame, never on an already zoomed/rendered preview.
/// The visible crop is converted back into full-source coordinates on commit.
struct EditorRegionSelectionSheet: View {
    let project: RecordingProject
    let request: RegionSelectionRequest
    let onCommit: (NormalizedRegionRect) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var selection: CGRect?
    @State private var frameError: String?

    private var clip: DemoVideoClip? {
        (try? DemoVideoTimeline(project: project))?.clips.first { $0.id == request.clipID }
    }
    private var media: DemoMediaAsset? {
        project.mediaAssets?.first { $0.id == clip?.mediaAssetID }
    }
    private var crop: SourceCropInsets {
        clip?.mediaAssetID == nil ? (project.settings.sourceCropInsets ?? SourceCropInsets()).sanitized : SourceCropInsets()
    }
    private var validSelection: Bool {
        guard let selection else { return false }
        return selection.width * (1 - crop.leading - crop.trailing) >= 0.01
            && selection.height * (1 - crop.top - crop.bottom) >= 0.01
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Select a region", systemImage: "viewfinder")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("Drag around a detail")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.secondaryText)
            }
            ZStack {
                Color.black.opacity(0.45)
                if let image {
                    selectionCanvas(image)
                } else if let frameError {
                    Text(frameError).font(.system(size: 12)).padding(24)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 760, height: 450)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("Fixed region · video continues inside")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use region") {
                    guard let selection, validSelection else { return }
                    onCommit(NormalizedRegionRect(
                        x: crop.leading + Double(selection.minX) * (1 - crop.leading - crop.trailing),
                        y: crop.top + Double(selection.minY) * (1 - crop.top - crop.bottom),
                        width: Double(selection.width) * (1 - crop.leading - crop.trailing),
                        height: Double(selection.height) * (1 - crop.top - crop.bottom)))
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!validSelection || image == nil)
                .accessibilityIdentifier("editor.regionSelection.confirm")
            }
        }
        .padding(22)
        .background(StudioTheme.panel)
        .task { await loadFrame() }
    }

    private func selectionCanvas(_ image: NSImage) -> some View {
        GeometryReader { proxy in
            let factor = min(proxy.size.width / max(1, image.size.width), proxy.size.height / max(1, image.size.height))
            let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                if let selection {
                    let rect = CGRect(x: selection.minX * size.width, y: selection.minY * size.height,
                                      width: selection.width * size.width, height: selection.height * size.height)
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: size))
                        path.addRect(rect)
                    }
                    .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                    Rectangle().stroke(.mint, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    ForEach(0..<4) { corner in
                        Circle().fill(.white).frame(width: 6, height: 6)
                            .offset(x: (corner % 2 == 0 ? rect.minX : rect.maxX) - 3,
                                    y: (corner < 2 ? rect.minY : rect.maxY) - 3)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                func point(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: (p.x / size.width).clamped(to: 0...1), y: (p.y / size.height).clamped(to: 0...1))
                }
                let start = point(value.startLocation), end = point(value.location)
                selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                   width: abs(end.x - start.x), height: abs(end.y - start.y))
            })
            .accessibilityLabel("Region selection canvas")
            .accessibilityHint("Drag around the area to emphasize")
            .accessibilityIdentifier("editor.regionSelection.canvas")
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    @MainActor private func loadFrame() async {
        guard let clip, let timeline = try? DemoVideoTimeline(project: project) else {
            frameError = L10n.tr("This clip is no longer available."); return
        }
        let path = media?.filePath ?? project.sourceVideoPath
        do {
            let raw: CGImage
            if media?.kind == .image {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600
                ]
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    frameError = L10n.tr("Unable to load this frame."); return
                }
                raw = frame
            } else {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 1600, height: 1200)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                defer { generator.cancelAllCGImageGeneration() }
                let time = EditorRegionTiming.decodableSourceTime(request.sourceTime,
                    sourceBounds: timeline.sourceBounds(for: clip), frameRate: project.settings.frameRate)
                raw = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000)).image
            }
            guard !Task.isCancelled else { return }
            let cropRect = CGRect(x: Double(raw.width) * crop.leading, y: Double(raw.height) * crop.top,
                                  width: Double(raw.width) * (1 - crop.leading - crop.trailing),
                                  height: Double(raw.height) * (1 - crop.top - crop.bottom))
            let frame = raw.cropping(to: cropRect.integral) ?? raw
            image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            if let rect = request.initialRect {
                let visible = CGRect(x: (rect.x - crop.leading) / (1 - crop.leading - crop.trailing),
                                     y: (rect.y - crop.top) / (1 - crop.top - crop.bottom),
                                     width: rect.width / (1 - crop.leading - crop.trailing),
                                     height: rect.height / (1 - crop.top - crop.bottom))
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                if !visible.isNull { selection = visible }
            }
        } catch {
            frameError = error.localizedDescription
        }
    }
}

struct EditorRegionEffectInspector: View {
    @Binding var project: RecordingProject
    @Binding var selectedID: UUID?
    @Binding var currentTime: Double
    let onSelectRegion: (UUID?) -> Void
    @State private var draft: RegionEffect?
    @State private var showsAdvanced = false
    @State private var error: String?
    private var selected: RegionEffect? { project.regionEffects?.first { $0.id == selectedID } }
    private var placement: RegionEffectPlacement? {
        (try? RegionEffectTimeline(project: project))?.placements.first { $0.effect.id == selectedID }
    }
    private var clip: DemoVideoClip? {
        (try? DemoVideoTimeline(project: project))?.clips.first { $0.id == selected?.clipID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Button { onSelectRegion(nil) } label: {
                Label("Select a region", systemImage: "viewfinder").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("editor.region.add")
            if !(project.regionEffects ?? []).isEmpty {
                Picker("Selected emphasis", selection: $selectedID) {
                    Text("Select an effect").tag(Optional<UUID>.none)
                    ForEach(Array((project.regionEffects ?? []).enumerated()), id: \.element.id) { index, effect in
                        Text("\(index + 1) · \(L10n.tr(effect.preset.displayTitle))").tag(Optional(effect.id))
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("editor.region.selected")
            }
            if let draft {
                effectControls(draft)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "viewfinder").font(.system(size: 28)).foregroundStyle(.mint)
                    Text("Bring one detail into focus").font(.system(size: 12, weight: .semibold))
                    Text("Pause on a frame, then draw around a card, chart, or button.")
                        .font(.system(size: 11)).foregroundStyle(StudioTheme.secondaryText)
                }
                .padding(.vertical, 8)
            }
            if let error {
                Text(error).font(.system(size: 10)).foregroundStyle(StudioTheme.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { draft = selected }
        .onChange(of: selected) { _, value in draft = value; error = nil }
    }

    @ViewBuilder private func effectControls(_ effect: RegionEffect) -> some View {
        HStack {
            Toggle("Enabled", isOn: setting(\.isEnabled, fallback: effect)).toggleStyle(.switch).controlSize(.small)
            Spacer()
            Button { onSelectRegion(effect.id) } label: { Image(systemName: "viewfinder") }
                .help("Reselect region").accessibilityLabel("Reselect region")
                .accessibilityIdentifier("editor.region.reselect")
            Menu {
                Button("Duplicate effect") { duplicate() }
                    .disabled(EditorRegionTiming.duplicate(effect, project: project) == nil)
                Button("Delete effect", role: .destructive) {
                    project.regionEffects?.removeAll { $0.id == effect.id }; selectedID = nil
                }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).frame(width: 18)
            .accessibilityLabel("Effect actions")
        }
        Picker("Effect", selection: setting(\.preset, fallback: effect)) {
            ForEach(RegionEffectPreset.allCases, id: \.self) { preset in
                Label(LocalizedStringKey(preset.displayTitle), systemImage: preset.symbol).tag(preset)
            }
        }
        .accessibilityIdentifier("editor.region.preset")
        Picker("Background", selection: setting(\.background, fallback: effect)) {
            ForEach(RegionEffectBackground.allCases, id: \.self) { value in
                Text(LocalizedStringKey(value.displayTitle)).tag(value)
            }
        }
        .accessibilityIdentifier("editor.region.background")
        if effect.background != .none {
            parameter("Strength", keyPath: \.intensity, range: 0...1, format: { "\(Int($0 * 100))%" })
        }
        if effect.preset != .spotlight && effect.preset != .outline {
            parameter("Scale", keyPath: \.scale, range: 1...3, format: { $0.formatted(.number.precision(.fractionLength(2))) + "×" })
        }
        if let clip, let placement {
            let visibleStart = max(effect.sourceStart, clip.sourceStart)
            let room = effect.isEnabled
                ? EditorRegionTiming.availableRange(in: clip, project: project,
                    near: (max(effect.sourceStart, clip.sourceStart) + min(effect.sourceEnd, clip.sourceEnd)) / 2,
                    excludingID: effect.id)?.upperBound ?? clip.sourceEnd
                : clip.sourceEnd
            RegionParameterSlider(title: "Duration", value: Binding(
                get: {
                    let edited = draft ?? effect
                    return max(0.1, min(edited.sourceEnd, clip.sourceEnd) - max(edited.sourceStart, clip.sourceStart))
                },
                set: {
                    // Only an intentional duration edit adopts visible bounds.
                    // Merely selecting or inspecting a trimmed effect preserves
                    // its hidden source range for later restoration.
                    draft?.sourceStart = visibleStart
                    draft?.sourceEnd = visibleStart + $0
                }
            ), range: 0.1...max(0.1, room - visibleStart),
                format: { $0.formatted(.number.precision(.fractionLength(2))) + " s" }, onCommit: commit)
            if placement.duration < effect.sourceEnd - effect.sourceStart - 0.001 {
                Text("Partly outside this trim. Duration edits apply to the visible range.")
                    .font(.system(size: 10)).foregroundStyle(StudioTheme.secondaryText)
            }
        } else if clip != nil {
            Label("Outside this clip’s trim", systemImage: "scissors")
                .font(.system(size: 11)).foregroundStyle(StudioTheme.yellow)
            Text("Restore the clip to reveal this effect.")
                .font(.system(size: 10)).foregroundStyle(StudioTheme.secondaryText)
        }
        DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
            VStack(spacing: 14) {
                if effect.preset == .perspective {
                    optionalParameter("Perspective angle", keyPath: \.perspectiveDegrees, defaultValue: 18,
                        range: -35...35, format: { "\(Int($0))°" })
                }
                if effect.preset == .outline || effect.preset == .magnify {
                    optionalParameter("Border width", keyPath: \.outlineWidth, defaultValue: 3,
                        range: 1...12, format: { $0.formatted(.number.precision(.fractionLength(1))) + " px" })
                }
                parameter("Entrance", keyPath: \.easeIn, range: 0...5, format: { $0.formatted(.number.precision(.fractionLength(2))) + " s" })
                parameter("Exit", keyPath: \.easeOut, range: 0...5, format: { $0.formatted(.number.precision(.fractionLength(2))) + " s" })
            }.padding(.top, 12)
        }
        .font(.system(size: 11))
        Button {
            if let placement { currentTime = (placement.start + placement.end) / 2 }
        } label: {
            Label("Preview emphasis", systemImage: "eye").frame(maxWidth: .infinity)
        }
        .disabled(placement == nil)
        .accessibilityIdentifier("editor.region.preview")
        Text("Fixed region · video continues inside")
            .font(.system(size: 10)).foregroundStyle(StudioTheme.secondaryText)
    }

    private func setting<T>(_ keyPath: WritableKeyPath<RegionEffect, T>, fallback: RegionEffect) -> Binding<T> {
        Binding(get: { (draft ?? fallback)[keyPath: keyPath] }, set: {
            draft?[keyPath: keyPath] = $0
            commit()
        })
    }
    private func parameter(_ title: String, keyPath: WritableKeyPath<RegionEffect, Double>,
                           range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        RegionParameterSlider(title: title, value: Binding(
            get: { draft?[keyPath: keyPath] ?? range.lowerBound },
            set: { draft?[keyPath: keyPath] = $0 }), range: range, format: format, onCommit: commit)
    }
    private func optionalParameter(_ title: String, keyPath: WritableKeyPath<RegionEffect, Double?>,
                                   defaultValue: Double, range: ClosedRange<Double>,
                                   format: @escaping (Double) -> String) -> some View {
        RegionParameterSlider(title: title, value: Binding(
            get: { (draft?[keyPath: keyPath] ?? nil) ?? defaultValue },
            set: { draft?[keyPath: keyPath] = $0 }), range: range, format: format, onCommit: commit)
    }
    private func commit() {
        guard let draft, let index = project.regionEffects?.firstIndex(where: { $0.id == draft.id }) else { return }
        do {
            try RegionEffectValidator.validate(draft, in: project)
            project.regionEffects?[index] = draft
            error = nil
        } catch {
            self.draft = selected
            self.error = L10n.tr(error.localizedDescription)
        }
    }
    private func duplicate() {
        guard let selected, let copy = EditorRegionTiming.duplicate(selected, project: project) else { return }
        project.regionEffects = (project.regionEffects ?? []) + [copy]
        selectedID = copy.id
    }
}

private struct RegionParameterSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let onCommit: () -> Void
    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(LocalizedStringKey(title))
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(StudioTheme.secondaryText)
            }.font(.system(size: 11))
            Slider(value: $value, in: range, onEditingChanged: { if !$0 { onCommit() } })
                .controlSize(.small)
                .accessibilityLabel(Text(LocalizedStringKey(title)))
                .accessibilityIdentifier("editor.region.\(title.lowercased())")
        }
    }
}

struct EditorRegionEffectLane: View {
    @Binding var project: RecordingProject
    @Binding var selectedID: UUID?
    let timelineWidth: Double
    let onSelect: () -> Void
    let onAdd: () -> Void
    @State private var error: String?
    private var placements: [RegionEffectPlacement] {
        (try? RegionEffectTimeline(project: project))?.placements ?? []
    }
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.025))
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onAdd)
                .contextMenu { Button("Select a region", action: onAdd) }
            if placements.isEmpty {
                Text("Select a region to emphasize")
                    .font(.system(size: 10)).foregroundStyle(StudioTheme.secondaryText)
                    .padding(.leading, 10).allowsHitTesting(false)
            }
            ForEach(placements, id: \.effect.id) { placement in
                RegionEffectBlock(placement: placement, project: project,
                    timelineWidth: timelineWidth, selected: selectedID == placement.effect.id,
                    onSelect: { selectedID = placement.effect.id; onSelect() },
                    onCommit: { effect in
                        guard let index = project.regionEffects?.firstIndex(where: { $0.id == effect.id }) else { return }
                        do {
                            try RegionEffectValidator.validate(effect, in: project)
                            project.regionEffects?[index] = effect
                            error = nil
                        } catch { self.error = L10n.tr(error.localizedDescription) }
                    },
                    onDuplicate: {
                        guard let copy = EditorRegionTiming.duplicate(placement.effect, project: project) else { return }
                        project.regionEffects = (project.regionEffects ?? []) + [copy]
                        selectedID = copy.id
                        onSelect()
                    },
                    onDelete: {
                        project.regionEffects?.removeAll { $0.id == placement.effect.id }
                        if selectedID == placement.effect.id { selectedID = nil }
                    })
                .zIndex(selectedID == placement.effect.id ? 1 : 0)
            }
        }
        .frame(width: timelineWidth, height: 32, alignment: .leading)
        .coordinateSpace(name: "region-effects")
        .clipped()
        .accessibilityIdentifier("timeline.regionEffects")
        .alert("Local emphasis", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}

/// Pointer moves only update this small block. No project write, composition
/// rebuild, frame decoding or undo entry is created until the drag completes.
private struct RegionEffectBlock: View {
    let placement: RegionEffectPlacement
    let project: RecordingProject
    let timelineWidth: Double
    let selected: Bool
    let onSelect: () -> Void
    let onCommit: (RegionEffect) -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    @State private var draft: RegionEffect?
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var effect: RegionEffect { draft ?? placement.effect }
    private var pixelsPerSecond: Double { timelineWidth / max(0.001, project.duration) }
    private var start: Double { placement.start + max(effect.sourceStart, placement.clip.sourceStart) - max(placement.effect.sourceStart, placement.clip.sourceStart) }
    private var end: Double { placement.end + min(effect.sourceEnd, placement.clip.sourceEnd) - min(placement.effect.sourceEnd, placement.clip.sourceEnd) }
    private var width: Double { max(12, (end - start) * pixelsPerSecond) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [.mint.opacity(0.68), .teal.opacity(0.72)], startPoint: .top, endPoint: .bottom))
            HStack(spacing: 5) {
                Image(systemName: effect.preset.symbol)
                if width > 95 { Text(LocalizedStringKey(effect.preset.displayTitle)).lineLimit(1) }
                if width > 175 { Text("\(end - start, specifier: "%.2f")s").monospacedDigit() }
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 16)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(drag(.move))
            .onTapGesture(perform: onSelect)
            HStack(spacing: 0) {
                handle(.leading)
                Spacer(minLength: 0)
                handle(.trailing)
            }
        }
        .frame(width: width, height: 28)
        .opacity(effect.isEnabled ? 1 : 0.42)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
            selected ? Color.white : Color.white.opacity(isHovered ? 0.55 : 0.12), lineWidth: selected ? 1.5 : 1))
        .shadow(color: .black.opacity(draft == nil ? 0 : 0.25), radius: 5, y: 2)
        .offset(x: start * pixelsPerSecond)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
        .contextMenu {
            Button("Duplicate effect", action: onDuplicate)
                .disabled(EditorRegionTiming.duplicate(placement.effect, project: project) == nil)
            Button("Delete effect", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(LocalizedStringKey(effect.preset.displayTitle)))
        .accessibilityValue("\(start.formatted(.number.precision(.fractionLength(2))))–\(end.formatted(.number.precision(.fractionLength(2)))) s")
        .accessibilityIdentifier("timeline.regionEffect.\(effect.id.uuidString)")
        .onChange(of: placement.effect) { _, _ in draft = nil }
    }

    private enum DragMode { case move, leading, trailing }
    private func handle(_ mode: DragMode) -> some View {
        Capsule().fill(.white.opacity(0.8))
            .frame(width: 3, height: 13)
            .frame(width: min(14, width / 3), height: 28)
            .contentShape(Rectangle())
            .gesture(drag(mode))
            .help(mode == .leading ? "Trim effect start" : "Trim effect end")
            .accessibilityLabel(mode == .leading ? "Trim effect start" : "Trim effect end")
    }

    private func drag(_ mode: DragMode) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("region-effects"))
            .onChanged { value in
                if draft == nil { onSelect() }
                let original = placement.effect
                let visibleStart = max(original.sourceStart, placement.clip.sourceStart)
                let visibleEnd = min(original.sourceEnd, placement.clip.sourceEnd)
                let allowed = original.isEnabled
                    ? EditorRegionTiming.availableRange(in: placement.clip, project: project,
                                                        near: (visibleStart + visibleEnd) / 2,
                                                        excludingID: original.id)
                    : placement.clip.sourceStart...placement.clip.sourceEnd
                guard let allowed else { return }
                let fps = Double(max(1, project.settings.frameRate))
                let delta = Double(value.translation.width) / max(0.001, pixelsPerSecond)
                func snapped(_ time: Double) -> Double { (time * fps).rounded() / fps }
                var updated = original
                switch mode {
                case .move:
                    let length = visibleEnd - visibleStart
                    guard allowed.upperBound - allowed.lowerBound >= length else { return }
                    updated.sourceStart = snapped(visibleStart + delta)
                        .clamped(to: allowed.lowerBound...(allowed.upperBound - length))
                    updated.sourceEnd = updated.sourceStart + length
                case .leading:
                    updated.sourceStart = snapped(visibleStart + delta)
                        .clamped(to: allowed.lowerBound...max(allowed.lowerBound, visibleEnd - 0.1))
                    updated.sourceEnd = visibleEnd
                case .trailing:
                    updated.sourceStart = visibleStart
                    updated.sourceEnd = snapped(visibleEnd + delta)
                        .clamped(to: min(allowed.upperBound, visibleStart + 0.1)...allowed.upperBound)
                }
                draft = updated
            }
            .onEnded { _ in
                if let draft, draft != placement.effect { onCommit(draft) }
                draft = nil
            }
    }
}
