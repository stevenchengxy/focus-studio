import Foundation

public enum MouseButton: String, Codable, Sendable {
    case left
    case right
    case other
}

/// The semantic cursor shape observed while recording.
///
/// Cursor appearance is deliberately stored separately in ``ProjectSettings``:
/// the same recording can therefore be restyled without losing the fact that a
/// particular sample was captured over an editable text region.
public enum CursorKind: String, Codable, Hashable, Sendable, CaseIterable {
    case arrow
    case iBeam
    /// The pointing hand macOS shows over links and other clickable web controls.
    case pointingHand
}

public struct CursorSample: Codable, Hashable, Sendable {
    public var time: Double
    public var x: Double
    public var y: Double
    public var cursorKind: CursorKind

    public init(
        time: Double,
        x: Double,
        y: Double,
        cursorKind: CursorKind = .arrow
    ) {
        self.time = time
        self.x = x
        self.y = y
        self.cursorKind = cursorKind
    }

    private enum CodingKeys: String, CodingKey {
        case time
        case x
        case y
        case cursorKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decode(Double.self, forKey: .time)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        cursorKind = try container.decodeIfPresent(CursorKind.self, forKey: .cursorKind) ?? .arrow
    }
}

public struct ClickEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var time: Double
    public var x: Double
    public var y: Double
    public var button: MouseButton

    public init(
        id: UUID = UUID(),
        time: Double,
        x: Double,
        y: Double,
        button: MouseButton
    ) {
        self.id = id
        self.time = time
        self.x = x
        self.y = y
        self.button = button
    }
}

/// Privacy-preserving typing timing and normalized editable-field focus.
/// Never stores typed text, keyboard characters, or key codes.
public struct TypingActivity: Codable, Hashable, Sendable {
    public var time: Double
    public var x: Double
    public var y: Double

    public init(time: Double, x: Double, y: Double) {
        self.time = time
        self.x = x
        self.y = y
    }
}

public struct TypingZoomSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var idleDelay: Double

    public init(enabled: Bool = true, idleDelay: Double = 1.4) {
        self.enabled = enabled
        self.idleDelay = idleDelay
    }

    public var sanitized: TypingZoomSettings {
        TypingZoomSettings(
            enabled: enabled,
            idleDelay: idleDelay.isFinite ? idleDelay.clamped(to: 0.4...5) : 1.4
        )
    }
}

public enum CaptureTargetKind: String, Codable, Sendable {
    case display
    case window
    case area
}

public struct CaptureRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct CaptureTargetInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: CaptureTargetKind
    public var nativeID: UInt32
    public var title: String
    public var appName: String?
    public var frame: CaptureRect
    public var scaleFactor: Double

    public init(
        id: String,
        kind: CaptureTargetKind,
        nativeID: UInt32,
        title: String,
        appName: String? = nil,
        frame: CaptureRect,
        scaleFactor: Double = 1
    ) {
        self.id = id
        self.kind = kind
        self.nativeID = nativeID
        self.title = title
        self.appName = appName
        self.frame = frame
        self.scaleFactor = scaleFactor
    }
}

public enum ZoomKind: String, Codable, Sendable, CaseIterable {
    case automatic
    case manual
}

/// Identifies the captured cue which a hand-edited block has taken over.
/// This prevents later automatic regeneration from putting the original cue
/// back underneath the user's shorter, moved, or disabled manual block.
public struct ZoomAutomaticSource: Codable, Hashable, Sendable {
    public var start: Double
    public var targetX: Double
    public var targetY: Double
    /// Exact captured event time for new cues; absent for migrated old cues.
    public var eventTime: Double?
    /// Exact membership survives regrouping when a global hold delay changes.
    /// Nil means an older project; an empty array means no events of this type.
    public var clickIDs: [UUID]?
    public var typingActivity: [TypingActivity]?
    /// Original pre-edit end used only to migrate cues without exact members.
    public var originalEnd: Double?

    public init(
        start: Double,
        targetX: Double,
        targetY: Double,
        eventTime: Double? = nil,
        clickIDs: [UUID]? = nil,
        typingActivity: [TypingActivity]? = nil,
        originalEnd: Double? = nil
    ) {
        self.start = start
        self.targetX = targetX
        self.targetY = targetY
        self.eventTime = eventTime
        self.clickIDs = clickIDs
        self.typingActivity = typingActivity
        self.originalEnd = originalEnd
    }
}

public struct ZoomSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var targetX: Double
    public var targetY: Double
    public var scale: Double
    public var kind: ZoomKind
    public var isEnabled: Bool
    public var isInstant: Bool
    /// Nil inherits the project transition duration. Optional for old projects.
    public var zoomEaseIn: Double?
    public var zoomEaseOut: Double?
    public var automaticSource: ZoomAutomaticSource?

    public init(
        id: UUID = UUID(),
        start: Double,
        end: Double,
        targetX: Double,
        targetY: Double,
        scale: Double,
        kind: ZoomKind = .automatic,
        isEnabled: Bool = true,
        isInstant: Bool = false,
        zoomEaseIn: Double? = nil,
        zoomEaseOut: Double? = nil,
        automaticSource: ZoomAutomaticSource? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.targetX = targetX
        self.targetY = targetY
        self.scale = scale
        self.kind = kind
        self.isEnabled = isEnabled
        self.isInstant = isInstant
        self.zoomEaseIn = zoomEaseIn
        self.zoomEaseOut = zoomEaseOut
        self.automaticSource = automaticSource
    }
}

public enum CanvasAspectRatio: String, Codable, Sendable, CaseIterable {
    case automatic
    case wide
    case vertical
    case square
    case classic
    case tall

    public var title: String {
        switch self {
        case .automatic: return "Auto"
        case .wide: return "16:9"
        case .vertical: return "9:16"
        case .square: return "1:1"
        case .classic: return "4:3"
        case .tall: return "3:4"
        }
    }

    public var ratio: Double? {
        switch self {
        case .automatic: return nil
        case .wide: return 16 / 9
        case .vertical: return 9 / 16
        case .square: return 1
        case .classic: return 4 / 3
        case .tall: return 3 / 4
        }
    }
}

public enum BackgroundStyle: String, Codable, Sendable, CaseIterable {
    case solid
    case gradient
    case image
}

/// Curated backgrounds are intentionally represented by the two persisted colors
/// already present in `ProjectSettings`. That keeps projects created by earlier
/// builds decodable while still giving the editor a useful one-click palette.
public enum BackgroundPreset: String, CaseIterable, Identifiable, Sendable {
    case aurora
    case ocean
    case sunset
    case blossom
    case citrus
    case midnight
    case graphite
    case cloud

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .aurora: return "Aurora"
        case .ocean: return "Ocean"
        case .sunset: return "Sunset"
        case .blossom: return "Blossom"
        case .citrus: return "Citrus"
        case .midnight: return "Midnight"
        case .graphite: return "Graphite"
        case .cloud: return "Cloud"
        }
    }

    public var primaryHex: String {
        switch self {
        case .aurora: return "#6D5DFB"
        case .ocean: return "#0866C6"
        case .sunset: return "#F97356"
        case .blossom: return "#C45CDE"
        case .citrus: return "#F7B733"
        case .midnight: return "#171A2C"
        case .graphite: return "#252831"
        case .cloud: return "#E8EDF7"
        }
    }

    public var secondaryHex: String {
        switch self {
        case .aurora: return "#18A6C9"
        case .ocean: return "#21D4B4"
        case .sunset: return "#7F5AF0"
        case .blossom: return "#FF8E8E"
        case .citrus: return "#FC4A1A"
        case .midnight: return "#3B2D64"
        case .graphite: return "#59616F"
        case .cloud: return "#C6D4F5"
        }
    }

    public func matches(primary: String, secondary: String) -> Bool {
        primary.caseInsensitiveCompare(primaryHex) == .orderedSame
            && secondary.caseInsensitiveCompare(secondaryHex) == .orderedSame
    }
}

public enum CursorAnimationStyle: String, Codable, Sendable, CaseIterable {
    case smooth
    case medium
    case rapid
    case none
}

/// A non-destructive visual treatment for cursor metadata during preview/export.
public enum CursorAppearance: String, Codable, Hashable, Sendable, CaseIterable {
    case system
    case highContrast
    case dot

    public var title: String {
        switch self {
        case .system: return "System"
        case .highContrast: return "High Contrast"
        case .dot: return "Dot"
        }
    }
}

public enum ClickAnimationStyle: String, Codable, Hashable, Sendable, CaseIterable {
    case ripple
    case halo
    case pulse

    public var title: String {
        switch self {
        case .ripple: return "Ripple"
        case .halo: return "Soft halo"
        case .pulse: return "Pulse"
        }
    }
}

/// Editing click feedback does not modify the captured pointer or click events.
public struct ClickAnimationSettings: Codable, Hashable, Sendable {
    public var style: ClickAnimationStyle
    public var colorHex: String
    public var size: Double
    public var duration: Double
    public var intensity: Double
    public var pressCursor: Bool

    public init(
        style: ClickAnimationStyle = .ripple,
        colorHex: String = "#8B7BFF",
        size: Double = 1,
        duration: Double = 0.65,
        intensity: Double = 0.85,
        pressCursor: Bool = true
    ) {
        self.style = style
        self.colorHex = colorHex
        self.size = size
        self.duration = duration
        self.intensity = intensity
        self.pressCursor = pressCursor
    }

    public var sanitized: ClickAnimationSettings {
        var result = self
        result.size = size.isFinite ? size.clamped(to: 0.4...2.5) : 1
        result.duration = duration.isFinite ? duration.clamped(to: 0.25...1.5) : 0.65
        result.intensity = intensity.isFinite ? intensity.clamped(to: 0...1) : 0.85
        return result
    }
}

public enum ScreenAnimationStyle: String, Codable, Sendable, CaseIterable {
    /// A camera-operator curve: quick to commit, long gentle settle, and
    /// continuous velocity and acceleration at both ends. Default for new projects.
    case cinematic
    case focused
    case smooth
    case gentle
    case snappy

    public var title: String {
        switch self {
        case .cinematic: return "Cinematic"
        case .focused: return "Focused"
        case .smooth: return "Smooth"
        case .gentle: return "Gentle"
        case .snappy: return "Snappy"
        }
    }
}

/// Optional audio finishing for short product-demo recordings.
///
/// The value is stored as an optional property on ``ProjectSettings`` so project
/// metadata written by Focus Studio builds which predate audio finishing remains
/// decodable. A missing value is equivalent to these defaults: preserve the
/// captured audio and do not add music or sound effects.
public struct ProductDemoAudioSettings: Codable, Hashable, Sendable {
    /// Linear gain applied to every audio track captured with the source video.
    public var sourceAudioVolume: Double
    /// Absolute path, or a path relative to the source video's directory.
    public var backgroundMusicPath: String?
    public var backgroundMusicVolume: Double
    public var backgroundMusicFadeIn: Double
    public var backgroundMusicFadeOut: Double

    public var clickSoundEnabled: Bool
    public var clickSoundVolume: Double
    /// Optional custom asset. When nil, the app-bundled `ui-click` sound is used.
    public var clickSoundPath: String?

    public var zoomTransitionSoundEnabled: Bool
    public var zoomTransitionSoundVolume: Double
    /// Optional custom asset. When nil, the app-bundled `zoom-whoosh` sound is used.
    public var zoomTransitionSoundPath: String?

    public init(
        sourceAudioVolume: Double = 1,
        backgroundMusicPath: String? = nil,
        backgroundMusicVolume: Double = 0.22,
        backgroundMusicFadeIn: Double = 0.8,
        backgroundMusicFadeOut: Double = 1.2,
        clickSoundEnabled: Bool = false,
        clickSoundVolume: Double = 0.38,
        clickSoundPath: String? = nil,
        zoomTransitionSoundEnabled: Bool = false,
        zoomTransitionSoundVolume: Double = 0.28,
        zoomTransitionSoundPath: String? = nil
    ) {
        self.sourceAudioVolume = sourceAudioVolume
        self.backgroundMusicPath = backgroundMusicPath
        self.backgroundMusicVolume = backgroundMusicVolume
        self.backgroundMusicFadeIn = backgroundMusicFadeIn
        self.backgroundMusicFadeOut = backgroundMusicFadeOut
        self.clickSoundEnabled = clickSoundEnabled
        self.clickSoundVolume = clickSoundVolume
        self.clickSoundPath = clickSoundPath
        self.zoomTransitionSoundEnabled = zoomTransitionSoundEnabled
        self.zoomTransitionSoundVolume = zoomTransitionSoundVolume
        self.zoomTransitionSoundPath = zoomTransitionSoundPath
    }
}

/// Where a chapter caption sits on the rendered canvas.
public enum CaptionPosition: String, Codable, Hashable, Sendable, CaseIterable {
    case bottom
    case top
}

/// A narrated section of a product demo: a time range plus the on-video
/// caption shown while it is active. Chapters live beside zoom segments and
/// never modify the captured recording or its interaction metadata.
public struct DemoChapter: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var title: String
    /// Rendered on the video when non-empty; otherwise the title is shown.
    public var caption: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        start: Double,
        end: Double,
        title: String,
        caption: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
        self.caption = caption
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case start
        case end
        case title
        case caption
        case isEnabled
    }

    /// Tolerant of hand-written or AI-produced JSON: only the time range is required.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        caption = try container.decodeIfPresent(String.self, forKey: .caption) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    /// The text drawn on the video: the caption, or the title when no caption exists.
    public var displayText: String {
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCaption.isEmpty { return trimmedCaption }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Appearance of the caption pill shared by preview and export.
///
/// Stored as an optional on ``ProjectSettings`` so projects written before
/// chapters existed decode unchanged; a missing value means these defaults.
public struct CaptionStyle: Codable, Hashable, Sendable {
    public static let scaleRange = 0.7...1.6
    public static let defaultAccentColorHex = "#8061FF"

    public var position: CaptionPosition
    /// Multiplies the reference caption size (2.4% of the canvas height).
    public var scale: Double
    public var showsChapterNumber: Bool
    /// Hex color of the chapter-number chip. Nil uses the app accent.
    public var accentColor: String?

    public init(
        position: CaptionPosition = .bottom,
        scale: Double = 1,
        showsChapterNumber: Bool = true,
        accentColor: String? = nil
    ) {
        self.position = position
        self.scale = scale
        self.showsChapterNumber = showsChapterNumber
        self.accentColor = accentColor
    }

    private enum CodingKeys: String, CodingKey {
        case position
        case scale
        case showsChapterNumber
        case accentColor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decodeIfPresent(CaptionPosition.self, forKey: .position) ?? .bottom
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        showsChapterNumber = try container.decodeIfPresent(Bool.self, forKey: .showsChapterNumber) ?? true
        accentColor = try container.decodeIfPresent(String.self, forKey: .accentColor)
    }

    public var sanitized: CaptionStyle {
        var result = self
        result.scale = scale.isFinite ? scale.clamped(to: Self.scaleRange) : 1
        if let accentColor, accentColor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.accentColor = nil
        }
        return result
    }

    public var resolvedAccentColorHex: String {
        sanitized.accentColor ?? Self.defaultAccentColorHex
    }
}

public struct ProjectSettings: Codable, Hashable, Sendable {
    public var autoZoomEnabled = true
    public var zoomScale = 1.75
    public var zoomLeadIn = 0.10
    public var zoomEaseIn = 0.42
    public var zoomHold = 0.90
    public var zoomEaseOut = 0.52
    /// Missing in older projects; only newly captured typing metadata uses it.
    public var typingZoom: TypingZoomSettings?
    public var cursorScale = 1.35
    public var cursorAnimation: CursorAnimationStyle = .smooth
    /// Optional so projects saved before cursor themes were introduced decode
    /// with the native system cursor instead of failing migration.
    public var cursorAppearance: CursorAppearance?
    /// Non-destructive pointer visibility. Missing in older recordings means
    /// visible; click feedback, cursor metadata and automatic zoom are separate.
    public var showCursor: Bool?
    public var screenAnimation: ScreenAnimationStyle = .cinematic
    /// Seconds after an automatic zoom ends during which a nearby click keeps
    /// the camera zoomed in and pans instead of zooming out and back in.
    /// Optional so projects saved before click chaining decode unchanged.
    public var zoomChainGap: Double?
    /// How strongly the camera drifts after the pointer while zoomed in (0 off,
    /// 1 full). Optional so earlier projects decode unchanged.
    public var zoomFollowsCursor: Double?
    public var hideIdleCursor = true
    public var showClickRing = true
    /// Optional to keep recordings saved before editable click feedback readable.
    public var clickAnimation: ClickAnimationSettings?
    public var motionBlur = 0.20
    public var backgroundStyle: BackgroundStyle = .gradient
    public var backgroundColor = "#6D5DFB"
    public var secondaryBackgroundColor = "#18A6C9"
    /// Absolute file path for an image background. Optional so projects written
    /// before image backgrounds were introduced remain decodable.
    public var backgroundImagePath: String?
    /// Core Image Gaussian blur radius, expressed in output pixels.
    public var backgroundBlur: Double?
    /// Core Image brightness adjustment in the range -1...1.
    public var backgroundBrightness: Double?
    public var padding = 64.0
    public var cornerRadius = 22.0
    public var shadow = 0.34
    /// Optional so recordings created by older builds remain decodable.
    /// Values are normalized against the uncropped source frame.
    public var sourceCropInsets: SourceCropInsets?
    public var aspectRatio: CanvasAspectRatio = .wide
    public var frameRate = 30
    public var exportWidth = 1920
    /// Optional to preserve decoding of projects created before audio finishing.
    public var productDemoAudio: ProductDemoAudioSettings?
    /// Optional so projects saved before chapter captions decode unchanged.
    public var captionStyle: CaptionStyle?
    /// What the demo shows, in the user's words. Feeds AI chapter generation.
    public var productDescription: String?

    public init() {}

    public var resolvedCaptionStyle: CaptionStyle {
        (captionStyle ?? CaptionStyle()).sanitized
    }

    /// Defaults for rendering legacy projects and for initializing the audio UI.
    public var resolvedProductDemoAudio: ProductDemoAudioSettings {
        productDemoAudio ?? ProductDemoAudioSettings()
    }

    public var resolvedCursorAppearance: CursorAppearance {
        cursorAppearance ?? .system
    }

    public var resolvedShowCursor: Bool {
        showCursor ?? true
    }

    public var resolvedClickAnimation: ClickAnimationSettings {
        (clickAnimation ?? ClickAnimationSettings()).sanitized
    }

    public var resolvedTypingZoom: TypingZoomSettings {
        (typingZoom ?? TypingZoomSettings()).sanitized
    }

    public static let defaultZoomChainGap = 1.0
    public static let maximumZoomChainGap = 2.5

    public static let defaultZoomFollowsCursor = 0.6

    public var resolvedZoomFollowsCursor: Double {
        guard let zoomFollowsCursor, zoomFollowsCursor.isFinite else { return Self.defaultZoomFollowsCursor }
        return zoomFollowsCursor.clamped(to: 0...1)
    }

    public var resolvedZoomChainGap: Double {
        guard let zoomChainGap, zoomChainGap.isFinite else { return Self.defaultZoomChainGap }
        return zoomChainGap.clamped(to: 0...Self.maximumZoomChainGap)
    }

    public var resolvedBackgroundBlur: Double {
        guard let backgroundBlur, backgroundBlur.isFinite else { return 0 }
        return backgroundBlur.clamped(to: 0...100)
    }

    public var resolvedBackgroundBrightness: Double {
        guard let backgroundBrightness, backgroundBrightness.isFinite else { return 0 }
        return backgroundBrightness.clamped(to: -1...1)
    }
}

public struct RecordingProject: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var sourceVideoPath: String
    public var duration: Double
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var cursorSamples: [CursorSample]
    public var clickEvents: [ClickEvent]
    /// Optional so existing projects remain readable without migration.
    public var typingActivity: [TypingActivity]?
    public var zoomSegments: [ZoomSegment]
    /// Narrated chapters with on-video captions. Optional so projects written
    /// by earlier builds decode unchanged; nil and empty are equivalent.
    public var chapters: [DemoChapter]?
    public var settings: ProjectSettings

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        sourceVideoPath: String,
        duration: Double,
        sourceWidth: Int,
        sourceHeight: Int,
        cursorSamples: [CursorSample] = [],
        clickEvents: [ClickEvent] = [],
        typingActivity: [TypingActivity]? = nil,
        zoomSegments: [ZoomSegment] = [],
        chapters: [DemoChapter]? = nil,
        settings: ProjectSettings = .init()
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.sourceVideoPath = sourceVideoPath
        self.duration = duration
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.cursorSamples = cursorSamples
        self.clickEvents = clickEvents
        self.typingActivity = typingActivity
        self.zoomSegments = zoomSegments
        self.chapters = chapters
        self.settings = settings
    }
}

public struct ZoomState: Hashable, Sendable {
    public var scale: Double
    public var centerX: Double
    public var centerY: Double
    public var progress: Double

    public init(scale: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5, progress: Double = 0) {
        self.scale = scale
        self.centerX = centerX
        self.centerY = centerY
        self.progress = progress
    }
}
