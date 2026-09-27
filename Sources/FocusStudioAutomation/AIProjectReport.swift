import FocusStudioCore
import Foundation

/// A project described for a model or a program: the "[Project]" block the
/// in-app assistant sends with every message, and the structured details
/// get_project returns. Both read only the project and its assets folder.
public enum AIProjectReport {
    static let maximumListedZooms = 16
    static let maximumListedChapters = 12
    static let maximumListedAssets = 12
    /// Structured lists are capped so get_project stays far below a client's
    /// tool-output limit (Claude Code keeps about 25k tokens; a 30-minute
    /// recording comes to about 10k) and carry their totals; cursor samples
    /// are never included. Zooms and chapters are the first ones in time
    /// order, and long texts are shortened with "…".
    static let maximumDataZooms = 100
    static let maximumDataClicks = 200
    static let maximumDataTyping = 200
    static let maximumDataChapters = 50
    /// Chapter titles and captions (set_chapters asks for 4 words and 60
    /// characters) and the product description (update_settings stores at
    /// most 600 characters), in characters.
    static let maximumDataChapterText = 120
    static let maximumDataText = 600
    static let maximumListedCaption = 60

    // MARK: - Text

    /// The project block of the assistant's prompt, in English (it is read by
    /// the model). Nil explains how to get a project open.
    static func summary(of project: RecordingProject?, assetsDirectory: URL) -> String {
        guard let project else { return "No recording is open. Use list_projects and open_project, or record a new demo." }
        let settings = project.settings
        var lines: [String] = []
        let title = project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("Title: \(title.isEmpty ? "Untitled" : title) | Duration: \(seconds(project.duration)) s | Source: \(project.sourceWidth)×\(project.sourceHeight) | Clicks: \(project.clickEvents.count) | Zooms: \(project.zoomSegments.filter(\.isEnabled).count) | Chapters: \(project.chapters?.count ?? 0)")
        lines.append("Look: background \(backgroundDescription(settings)) | aspect \(settings.aspectRatio.title) | padding \(Int(settings.padding)) px | corner radius \(Int(settings.cornerRadius)) px | shadow \(seconds(settings.shadow)) | screen animation \(settings.screenAnimation.rawValue) | zoom scale \(seconds(settings.zoomScale))× | caption \(settings.resolvedCaptionStyle.position.rawValue)")
        if let description = settings.productDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            lines.append("Product: \(String(description.prefix(400)))")
        }
        let audio = settings.resolvedProductDemoAudio
        let music = audio.backgroundMusicPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "none"
        lines.append("Zoom style: automatic zooms \(settings.autoZoomEnabled ? "on" : "off") | hold \(seconds(settings.zoomHold)) s | ease in \(seconds(settings.zoomEaseIn)) s | ease out \(seconds(settings.zoomEaseOut)) s | chain gap \(seconds(settings.resolvedZoomChainGap)) s")
        lines.append("Audio: music \(music) (volume \(seconds(audio.backgroundMusicVolume))) | click sound \(audio.clickSoundEnabled ? "on" : "off") | zoom whoosh \(audio.zoomTransitionSoundEnabled ? "on" : "off")")
        lines.append("Export: \(settings.exportWidth) px wide | \(settings.frameRate) fps")
        let zooms = AIToolSupport.orderedZooms(project)
        if !zooms.isEmpty {
            let listed = zooms.prefix(maximumListedZooms).map { "#\($0.index) \(AIToolSupport.zoomLine($0.segment))" }
            var text = "Zooms (time order): " + listed.joined(separator: "; ")
            if zooms.count > maximumListedZooms { text += "; and \(zooms.count - maximumListedZooms) more" }
            lines.append(text)
        }
        if let chapters = project.chapters, !chapters.isEmpty {
            let listed = chapters.sorted(by: ChapterMath.precedes).prefix(maximumListedChapters).enumerated().map { index, chapter in
                "\(index + 1). \(seconds(chapter.start))–\(seconds(chapter.end)) s \(clipped(chapter.title, to: maximumListedCaption))\(chapter.caption.isEmpty ? "" : " — \(clipped(chapter.caption, to: maximumListedCaption))")"
            }
            var text = "Chapters: " + listed.joined(separator: "; ")
            if chapters.count > maximumListedChapters { text += "; and \(chapters.count - maximumListedChapters) more" }
            lines.append(text)
        }
        let assets = listedAssets(in: assetsDirectory)
        lines.append(assets.isEmpty ? "Assets: none yet (folder \(assetsDirectory.path))" : "Assets in \(assetsDirectory.path): \(assets.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }

    // MARK: - Structured

    /// Everything a client needs to edit the project by id: look, zoom style
    /// and audio settings under the argument names update_settings,
    /// set_zoom_style and set_sound_effects take, the export width and frame
    /// rate (update_settings' exportWidth and frameRate), zooms with stable
    /// ids for remove_zoom, chapters, and click and typing moments for add_zoom.
    static func data(
        of project: RecordingProject,
        isOpen: Bool,
        assetsDirectory: URL?,
        musicTracks: [AIMusicTrack] = []
    ) -> AIJSONValue {
        let settings = project.settings
        let zooms = AIToolSupport.orderedZooms(project)
        let chapters = (project.chapters ?? []).sorted(by: ChapterMath.precedes)
        let typing = project.typingActivity ?? []
        let clickItems = sampled(project.clickEvents.sorted { $0.time < $1.time }, limit: maximumDataClicks)
            .map { click -> AIJSONValue in [.rounded(click.time), .rounded(click.x), .rounded(click.y)] }
        let typingItems = sampled(typing.sorted { $0.time < $1.time }, limit: maximumDataTyping)
            .map { entry -> AIJSONValue in ["t": .rounded(entry.time), "x": .rounded(entry.x), "y": .rounded(entry.y)] }
        return [
            "id": AIJSONValue(project.id.uuidString),
            "title": AIJSONValue(project.title),
            "created_at": AIJSONValue(project.createdAt),
            "duration": .rounded(project.duration),
            "source_width": AIJSONValue(project.sourceWidth),
            "source_height": AIJSONValue(project.sourceHeight),
            "open_in_editor": AIJSONValue(isOpen),
            "look": lookData(settings),
            "zoom_style": zoomStyleData(settings),
            "audio": audioData(settings, tracks: musicTracks),
            "export_width": AIJSONValue(settings.exportWidth),
            "frame_rate": AIJSONValue(settings.frameRate),
            "zoom_count": AIJSONValue(zooms.count),
            "zooms": .array(zooms.prefix(maximumDataZooms).map { zoomData(index: $0.index, segment: $0.segment) }),
            "chapter_count": AIJSONValue(chapters.count),
            "chapters": .array(chapters.prefix(maximumDataChapters).enumerated().map { chapterData(index: $0.offset + 1, chapter: $0.element) }),
            "clicks": [
                "count": AIJSONValue(project.clickEvents.count),
                // [seconds, x, y]; evenly sampled across the recording beyond the cap.
                "items": .array(clickItems),
            ],
            "typing_count": AIJSONValue(typing.count),
            "typing": .array(typingItems),
            "assets_dir": assetsDirectory.map { AIJSONValue($0) } ?? .null,
        ]
    }

    /// The look under update_settings' argument names.
    static func lookData(_ settings: ProjectSettings) -> AIJSONValue {
        let caption = settings.resolvedCaptionStyle
        let preset = BackgroundPreset.allCases.first { $0.matches(primary: settings.backgroundColor, secondary: settings.secondaryBackgroundColor) }
        let description = settings.productDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "backgroundStyle": AIJSONValue(settings.backgroundStyle.rawValue),
            "backgroundPreset": settings.backgroundStyle == .gradient ? preset.map { .string($0.rawValue) } ?? .null : .null,
            "backgroundColor": AIJSONValue(settings.backgroundColor),
            "secondaryBackgroundColor": AIJSONValue(settings.secondaryBackgroundColor),
            "backgroundImagePath": settings.backgroundImagePath.map { .string($0) } ?? .null,
            "backgroundBlur": .rounded(settings.resolvedBackgroundBlur),
            "backgroundBrightness": .rounded(settings.resolvedBackgroundBrightness),
            "padding": .rounded(settings.padding),
            "cornerRadius": .rounded(settings.cornerRadius),
            "shadow": .rounded(settings.shadow),
            "screenAnimation": AIJSONValue(settings.screenAnimation.rawValue),
            "zoomScale": .rounded(settings.zoomScale),
            "aspectRatio": AIJSONValue(settings.aspectRatio.rawValue),
            "motionBlur": .rounded(settings.motionBlur),
            "captionPosition": AIJSONValue(caption.position.rawValue),
            "captionScale": .rounded(caption.scale),
            "showsChapterNumber": AIJSONValue(caption.showsChapterNumber),
            "productDescription": (description?.isEmpty ?? true) ? .null : AIJSONValue(clipped(description!)),
        ]
    }

    /// Zoom motion under set_zoom_style's argument names.
    static func zoomStyleData(_ settings: ProjectSettings) -> AIJSONValue {
        [
            "autoZoomEnabled": AIJSONValue(settings.autoZoomEnabled),
            "zoomHold": .rounded(settings.zoomHold),
            "zoomEaseIn": .rounded(settings.zoomEaseIn),
            "zoomEaseOut": .rounded(settings.zoomEaseOut),
            "zoomChainGap": .rounded(settings.resolvedZoomChainGap),
        ]
    }

    /// Music and effects under set_sound_effects' argument names; the music
    /// names its bundled track when it is one.
    static func audioData(_ settings: ProjectSettings, tracks: [AIMusicTrack]) -> AIJSONValue {
        let audio = settings.resolvedProductDemoAudio
        var music = AIJSONValue.null
        if let path = audio.backgroundMusicPath, !path.isEmpty {
            let track = tracks.first { $0.path == path }
            music = [
                "path": AIJSONValue(path),
                "title": AIJSONValue(track?.title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent),
                "track_id": track.map { .string($0.id) } ?? .null,
                "volume": .rounded(audio.backgroundMusicVolume),
            ]
        }
        return [
            "background_music": music,
            "click": AIJSONValue(audio.clickSoundEnabled),
            "click_volume": .rounded(audio.clickSoundVolume),
            "zoom": AIJSONValue(audio.zoomTransitionSoundEnabled),
            "zoom_volume": .rounded(audio.zoomTransitionSoundVolume),
        ]
    }

    /// One zoom with its 1-based time-order number and its stable id.
    static func zoomData(index: Int, segment: ZoomSegment) -> AIJSONValue {
        [
            "index": AIJSONValue(index),
            "id": AIJSONValue(segment.id.uuidString),
            "start": .rounded(segment.start),
            "end": .rounded(segment.end),
            "x": .rounded(segment.targetX),
            "y": .rounded(segment.targetY),
            "scale": .rounded(segment.scale),
            "kind": AIJSONValue(segment.kind.rawValue),
            "enabled": AIJSONValue(segment.isEnabled),
        ]
    }

    static func chapterData(index: Int, chapter: DemoChapter) -> AIJSONValue {
        [
            "index": AIJSONValue(index),
            "start": .rounded(chapter.start),
            "end": .rounded(chapter.end),
            "title": AIJSONValue(clipped(chapter.title, to: maximumDataChapterText)),
            "caption": AIJSONValue(clipped(chapter.caption, to: maximumDataChapterText)),
        ]
    }

    /// A library entry for list_projects and stop_recording.
    static func summaryData(_ summary: AIProjectSummary, isOpen: Bool) -> AIJSONValue {
        [
            "id": AIJSONValue(summary.id.uuidString),
            "title": AIJSONValue(summary.displayTitle),
            "duration": .rounded(summary.duration),
            "created_at": AIJSONValue(summary.createdAt),
            "source_width": AIJSONValue(summary.sourceWidth),
            "source_height": AIJSONValue(summary.sourceHeight),
            "zoom_count": AIJSONValue(summary.zoomCount),
            "chapter_count": AIJSONValue(summary.chapterCount),
            "open_in_editor": AIJSONValue(isOpen),
        ]
    }

    /// Where the assistant keeps a project's generated files: `ai/` next to
    /// its recording (the folder the app's assets locator uses), else inside
    /// the project's library folder. Nil when neither is known.
    public static func assetsDirectory(for project: RecordingProject, libraryRoot: URL?) -> URL? {
        if project.sourceVideoPath.hasPrefix("/") {
            return URL(fileURLWithPath: project.sourceVideoPath).deletingLastPathComponent().appendingPathComponent("ai", isDirectory: true)
        }
        return libraryRoot?.appendingPathComponent(project.id.uuidString, isDirectory: true).appendingPathComponent("ai", isDirectory: true)
    }

    // MARK: - Helpers

    /// `text`, cut to `limit` characters with "…" when it is longer.
    static func clipped(_ text: String, to limit: Int = maximumDataText) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// At most `limit` elements, evenly spread over `items` (first and last kept).
    static func sampled<Element>(_ items: [Element], limit: Int) -> [Element] {
        guard items.count > limit, limit > 1 else { return Array(items.prefix(max(0, limit))) }
        let step = Double(items.count - 1) / Double(limit - 1)
        return (0..<limit).map { items[Int((Double($0) * step).rounded())] }
    }

    static func backgroundDescription(_ settings: ProjectSettings) -> String {
        switch settings.backgroundStyle {
        case .image:
            let name = settings.backgroundImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
            return "image (\(name))"
        case .solid:
            return "solid \(settings.backgroundColor)"
        case .gradient:
            if let preset = BackgroundPreset.allCases.first(where: { $0.matches(primary: settings.backgroundColor, secondary: settings.secondaryBackgroundColor) }) {
                return "gradient preset \(preset.title)"
            }
            return "gradient \(settings.backgroundColor) → \(settings.secondaryBackgroundColor)"
        }
    }

    static func listedAssets(in directory: URL) -> [String] {
        let media = AIToolSupport.mediaFiles(in: directory)
        var names = media.prefix(maximumListedAssets).map(\.lastPathComponent)
        if media.count > maximumListedAssets { names.append("and \(media.count - maximumListedAssets) more") }
        return names
    }

    static func seconds(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
