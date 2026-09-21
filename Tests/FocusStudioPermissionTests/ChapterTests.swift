import FocusStudioCore
import Foundation

/// Chapter captions: timing sanitization, playback selection, fades, the
/// zoom-based heuristic, SubRip export, AI reply parsing and compatibility.
/// Everything here is shared by the timeline, Inspector, preview and export.
func chapterFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }

    // --- Sanitizing ----------------------------------------------------------
    let messy = [
        DemoChapter(start: 9, end: 30, title: "Tail"),
        DemoChapter(start: -2, end: 3, title: "Head"),
        DemoChapter(start: 5, end: 5.2, title: "Blink"),
        DemoChapter(start: 6, end: 8, title: "   ", caption: "  "),
        DemoChapter(start: .nan, end: 4, title: "NaN"),
        DemoChapter(start: 4, end: 2, title: "Backwards"),
        DemoChapter(start: 3, end: 7, title: "  Middle  ", caption: " Caption \n"),
        DemoChapter(start: 50, end: 60, title: "Beyond"),
    ]
    let clean = ChapterMath.sanitized(messy, duration: 12)
    expect(clean.map(\.title) == ["Head", "Middle", "Tail"],
           "sanitized drops invalid chapters and sorts by start: \(clean.map(\.title))")
    expect(clean.first?.start == 0 && clean.last?.end == 12, "sanitized clamps chapters to the project")
    expect(clean.count == 3 && clean[1].caption == "Caption", "sanitized trims caption text")
    expect(ChapterMath.sanitized(messy, duration: 0).isEmpty, "no chapters without a duration")
    let sharedID = UUID()
    let separated = ChapterMath.sanitized([
        DemoChapter(id: sharedID, start: 0, end: 2, title: "A"),
        DemoChapter(id: sharedID, start: 3, end: 5, title: "B"),
    ], duration: 10)
    expect(Set(separated.map(\.id)).count == 2, "duplicate chapter ids are regenerated")

    // --- Edits ---------------------------------------------------------------
    let chapter = DemoChapter(start: 2, end: 6, title: "Edit")
    let moved = ChapterMath.applying(.move(9), to: chapter, duration: 10)
    expect(abs(moved.start - 6) < 1e-9 && abs(moved.end - 10) < 1e-9, "move keeps the length inside the video")
    let shrunk = ChapterMath.applying(.end(2.1), to: chapter, duration: 10)
    expect(abs(shrunk.end - 2.5) < 1e-9 && shrunk.start == 2, "end edits keep the minimum length")
    let pushed = ChapterMath.applying(.start(7), to: chapter, duration: 10)
    expect(abs(pushed.start - 5.5) < 1e-9 && pushed.end == 6, "start edits leave the end fixed")
    expect(ChapterMath.applying(.start(.infinity), to: chapter, duration: 10) == chapter, "invalid numbers are ignored")
    let fresh = ChapterMath.newChapter(at: 9, duration: 10, title: "New")
    expect(fresh?.start == 6 && fresh?.end == 10 && fresh?.title == "New", "new chapters are pulled back to fit")
    expect(ChapterMath.newChapter(at: 1, duration: 2, title: "Short")?.end == 2, "new chapters shrink to short recordings")

    // --- Active chapter and fade ---------------------------------------------
    let long = DemoChapter(start: 0, end: 10, title: "Overview")
    let nested = DemoChapter(start: 4, end: 6, title: "Detail")
    let disabled = DemoChapter(start: 5, end: 5.9, title: "Off", isEnabled: false)
    let chapters = [long, nested, disabled]
    expect(ChapterMath.activeChapter(at: 2, chapters: chapters)?.id == long.id, "the only covering chapter is active")
    expect(ChapterMath.activeChapter(at: 5, chapters: chapters)?.id == nested.id, "the latest-starting enabled chapter wins")
    expect(ChapterMath.activeChapter(at: 11, chapters: chapters) == nil, "nothing is active after the last chapter")
    expect(ChapterMath.opacity(at: 4, chapter: nested) == 0, "the fade starts from zero")
    expect(abs(ChapterMath.opacity(at: 4 + ChapterMath.fadeDuration, chapter: nested) - 1) < 1e-9, "fully visible after the fade-in")
    expect(ChapterMath.opacity(at: 5, chapter: nested) == 1, "opaque in the middle")
    expect(abs(ChapterMath.opacity(at: 4.14, chapter: nested) - 0.5) < 1e-9, "the fade is a smoother-step")
    expect(abs(ChapterMath.opacity(at: 5.86, chapter: nested) - 0.5) < 1e-9, "the fade-out mirrors the fade-in")
    expect(ChapterMath.opacity(at: 6, chapter: nested) == 0
           && ChapterMath.opacity(at: 3.9, chapter: nested) == 0
           && ChapterMath.opacity(at: 6.1, chapter: nested) == 0, "opacity is zero at and beyond both ends")

    // --- Heuristic chapters --------------------------------------------------
    var project = RecordingProject(
        title: "Demo",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        sourceVideoPath: "/tmp/demo.mp4",
        duration: 30,
        sourceWidth: 1920,
        sourceHeight: 1080
    )
    project.zoomSegments = [
        ZoomSegment(start: 1, end: 3, targetX: 0.5, targetY: 0.5, scale: 2),
        ZoomSegment(start: 4, end: 6, targetX: 0.5, targetY: 0.5, scale: 2),
        ZoomSegment(start: 10, end: 12, targetX: 0.5, targetY: 0.5, scale: 2),
        ZoomSegment(start: 20, end: 22, targetX: 0.5, targetY: 0.5, scale: 2),
        ZoomSegment(start: 25, end: 26, targetX: 0.5, targetY: 0.5, scale: 2, isEnabled: false),
    ]
    let derived = ChapterMath.chaptersFromZooms(project: project)
    expect(derived.count == 3, "three focus clusters make three chapters (\(derived.count))")
    expect(derived.first?.start == 0 && derived.last?.end == 30, "heuristic chapters span the recording")
    expect(derived.map(\.title) == ["Chapter 1", "Chapter 2", "Chapter 3"], "heuristic titles are numbered")
    expect(derived.allSatisfy { $0.caption.isEmpty }, "heuristic chapters leave captions empty")
    expect(derived.count == 3 && abs(derived[0].end - 8) < 1e-9 && abs(derived[1].end - 16) < 1e-9,
           "chapter boundaries sit midway between focus clusters: \(derived.map(\.end))")
    expect(zip(derived, derived.dropFirst()).allSatisfy { abs($0.end - $1.start) < 1e-9 }, "heuristic chapters are contiguous")
    var busy = project
    busy.zoomSegments = (0..<10).map {
        ZoomSegment(start: Double($0) * 3, end: Double($0) * 3 + 0.2, targetX: 0.5, targetY: 0.5, scale: 2)
    }
    expect(ChapterMath.chaptersFromZooms(project: busy).count == 6, "many focus clusters merge down to six chapters")
    var empty = project
    empty.zoomSegments = []
    let evenly = ChapterMath.chaptersFromZooms(project: empty)
    expect(evenly.count == 3 && abs(evenly[1].start - 10) < 1e-9, "no zooms produce three even chapters")
    var tiny = empty
    tiny.duration = 1.2
    expect(ChapterMath.chaptersFromZooms(project: tiny).count == 2, "short recordings get fewer chapters, never shorter than the minimum")
    expect(ChapterMath.chaptersFromZooms(project: empty) { "章节 \($0)" }.first?.title == "章节 1", "heuristic titles can be localized")

    // --- SubRip ---------------------------------------------------------------
    let srt = ChapterMath.srt(for: [
        DemoChapter(start: 4.25, end: 3661.5, title: "Long", caption: "Caption wins"),
        DemoChapter(start: 1.5, end: 4, title: "Title fallback"),
        DemoChapter(start: 5, end: 6, title: "Hidden", isEnabled: false),
    ])
    let expectedSRT = """
    1
    00:00:01,500 --> 00:00:04,000
    Title fallback

    2
    00:00:04,250 --> 01:01:01,500
    Caption wins

    """
    expect(srt == expectedSRT, "SRT numbering, HH:MM:SS,mmm timestamps and caption fallback:\n\(srt)")
    expect(ChapterMath.srtTimestamp(59.9996) == "00:01:00,000", "SRT timestamps round milliseconds with carry")
    expect(ChapterMath.srt(for: []).isEmpty, "no chapters make an empty SRT")

    // --- Generator parsing ----------------------------------------------------
    let fenced = """
    Here are the chapters:
    ```json
    {"chapters":[
      {"start":0,"end":4,"title":"Open the dashboard","caption":"See every metric at a glance"},
      {"start":"4","end":"9.5","title":"Filter","caption":"Narrow down to what matters"},
      {"start":40,"end":50,"title":"Beyond","caption":"Dropped"}
    ]}
    ```
    Let me know if you want changes.
    """
    do {
        let parsed = try DemoChapterGenerator.parseChapters(from: fenced, duration: 12)
        expect(parsed.count == 2, "fenced JSON with prose parses and out-of-range chapters are rejected (\(parsed.count))")
        expect(parsed.first?.title == "Open the dashboard" && parsed.last?.end == 9.5, "numeric strings are accepted")
    } catch {
        failures.append("fenced generator reply must parse: \(error)")
    }
    let prose = "Sure! {\"chapters\": [{\"start\": 1, \"end\": 20, \"title\": \"Tail\", \"caption\": \"Clamped\"}]} Enjoy."
    do {
        let parsed = try DemoChapterGenerator.parseChapters(from: prose, duration: 12)
        expect(parsed.count == 1 && parsed[0].end == 12, "prose around JSON parses and overlong chapters are clamped")
    } catch {
        failures.append("prose generator reply must parse: \(error)")
    }
    let bare = "[{\"start\":\"0:02\",\"end\":\"0:05.5\",\"title\":\"Array\"}]"
    let bareParsed = try? DemoChapterGenerator.parseChapters(from: bare, duration: 12)
    expect(bareParsed?.count == 1 && bareParsed?.first?.start == 2 && bareParsed?.first?.end == 5.5, "a bare array with clock times is accepted")
    let outOfRange = "{\"chapters\":[{\"start\":30,\"end\":40,\"title\":\"Late\"},{\"start\":5,\"end\":4,\"title\":\"Backwards\"}]}"
    do {
        _ = try DemoChapterGenerator.parseChapters(from: outOfRange, duration: 12)
        failures.append("chapters entirely outside the recording must be rejected")
    } catch let error as DemoChapterGenerator.Failure {
        expect(error == .noChapters, "rejection reports noChapters, got \(error)")
    } catch {
        failures.append("unexpected rejection error \(error)")
    }
    do {
        _ = try DemoChapterGenerator.parseChapters(from: "I cannot help with that.", duration: 12)
        failures.append("prose without JSON must be rejected")
    } catch let error as DemoChapterGenerator.Failure {
        expect(error == .noJSON, "a prose-only reply reports noJSON, got \(error)")
    } catch {
        failures.append("unexpected no-JSON error \(error)")
    }
    do {
        _ = try DemoChapterGenerator.parseChapters(from: "  \n", duration: 12)
        failures.append("an empty reply must be rejected")
    } catch let error as DemoChapterGenerator.Failure {
        expect(error == .emptyResponse, "an empty reply reports emptyResponse, got \(error)")
    } catch {
        failures.append("unexpected empty-reply error \(error)")
    }

    // --- Prompts --------------------------------------------------------------
    var described = project
    described.settings.productDescription = "Finlyze turns bank exports into cash-flow forecasts."
    described.clickEvents = [ClickEvent(time: 2.5, x: 0.25, y: 0.75, button: .left)]
    described.typingActivity = [
        TypingActivity(time: 5, x: 0.5, y: 0.5),
        TypingActivity(time: 5.5, x: 0.5, y: 0.5),
        TypingActivity(time: 20, x: 0.5, y: 0.5),
    ]
    let prompt = DemoChapterGenerator.chapterPrompt(project: described, language: "zh-Hans")
    expect(prompt.system.contains("Simplified Chinese") && prompt.system.contains("\"chapters\""),
           "the prompt names the UI language and the JSON shape")
    expect(prompt.user.contains("Finlyze") && prompt.user.contains("2.50@0.25,0.75")
           && prompt.user.contains("Typing bursts: 2") && prompt.user.contains("30.00 s")
           && prompt.user.contains("1.00-3.00->0.50,0.50"),
           "the prompt lists description, clicks, zooms, typing bursts and duration:\n\(prompt.user)")
    expect(DemoChapterGenerator.chapterPrompt(project: described, language: "en").system.contains("in English"),
           "English prompts ask for English")

    // --- Polishing ------------------------------------------------------------
    let original = [
        DemoChapter(start: 0, end: 4, title: "One", caption: "old one"),
        DemoChapter(start: 4, end: 8, title: "Two", caption: "old two"),
    ]
    let polishReply = "```\n{\"chapters\":[{\"index\":2,\"caption\":\"  New two  \"},{\"index\":1,\"caption\":\"\"},{\"index\":9,\"caption\":\"ignored\"}]}\n```"
    do {
        let polished = try DemoChapterGenerator.parsePolishedCaptions(from: polishReply, applyingTo: original)
        expect(polished.map(\.id) == original.map(\.id) && polished.map(\.start) == original.map(\.start)
               && polished.map(\.end) == original.map(\.end) && polished.map(\.title) == original.map(\.title),
               "polishing preserves ids, times and titles")
        expect(polished[1].caption == "New two" && polished[0].caption == "old one",
               "polishing applies non-empty captions by index: \(polished.map(\.caption))")
    } catch {
        failures.append("polish reply must parse: \(error)")
    }
    let polishPrompt = DemoChapterGenerator.polishPrompt(chapters: original, project: described, language: "en")
    expect(polishPrompt.user.contains("\"index\":2") && polishPrompt.user.contains("old two"), "the polish prompt lists numbered chapters")

    // --- End to end with a fake model -----------------------------------------
    let box = ResultBox<[DemoChapter]>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let generated = try await DemoChapterGenerator.generateChapters(project: described, language: "en") { system, user in
                guard user.contains("Finlyze"), system.contains("English") else { return "{}" }
                return "```json\n{\"chapters\":[{\"start\":0,\"end\":10,\"title\":\"Import\",\"caption\":\"Drop in a bank export\"},"
                    + "{\"start\":10,\"end\":30,\"title\":\"Forecast\",\"caption\":\"See next quarter's cash\"}]}\n```"
            }
            box.value = .success(generated)
        } catch {
            box.value = .failure(error)
        }
        semaphore.signal()
    }
    expect(semaphore.wait(timeout: .now() + 10) == .success, "the fake completion must finish")
    switch box.value {
    case .success(let generated)?:
        expect(generated.count == 2 && generated[1].title == "Forecast" && generated[1].end == 30,
               "generateChapters returns sanitized chapters from the fake model")
    case .failure(let error)?:
        failures.append("generateChapters with a fake model failed: \(error)")
    case nil:
        failures.append("generateChapters produced no result")
    }

    // --- Compatibility --------------------------------------------------------
    do {
        var full = project
        full.chapters = [DemoChapter(start: 0, end: 5, title: "Intro", caption: "Hello")]
        full.settings.captionStyle = CaptionStyle(position: .top, scale: 1.3, showsChapterNumber: false, accentColor: "#FF0000")
        full.settings.productDescription = "Desc"
        let encoder = JSONEncoder()
        let roundTrip = try JSONDecoder().decode(RecordingProject.self, from: encoder.encode(full))
        expect(roundTrip == full, "chapters, caption style and description round-trip through JSON")
        var object = try JSONSerialization.jsonObject(with: encoder.encode(full)) as? [String: Any] ?? [:]
        expect(object["chapters"] != nil, "chapters are persisted")
        object.removeValue(forKey: "chapters")
        var settingsObject = object["settings"] as? [String: Any] ?? [:]
        settingsObject.removeValue(forKey: "captionStyle")
        settingsObject.removeValue(forKey: "productDescription")
        object["settings"] = settingsObject
        let legacy = try JSONDecoder().decode(RecordingProject.self, from: JSONSerialization.data(withJSONObject: object))
        expect(legacy.chapters == nil && legacy.settings.captionStyle == nil && legacy.settings.productDescription == nil,
               "older projects decode without chapters")
        expect(legacy.settings.resolvedCaptionStyle == CaptionStyle(), "a missing caption style resolves to the defaults")
        let minimal = try JSONDecoder().decode(DemoChapter.self, from: Data("{\"start\":1,\"end\":3}".utf8))
        expect(minimal.isEnabled && minimal.caption.isEmpty && minimal.title.isEmpty, "a chapter needs only a time range to decode")
        var style = CaptionStyle()
        style.scale = 9
        expect(style.sanitized.scale == CaptionStyle.scaleRange.upperBound, "the caption scale is clamped")
        expect(CaptionStyle(accentColor: " ").resolvedAccentColorHex == CaptionStyle.defaultAccentColorHex, "a blank accent falls back")
    } catch {
        failures.append("chapter JSON compatibility failed: \(error)")
    }
    return failures
}

private final class ResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?

    var value: Result<Value, Error>? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}
