import Foundation

/// Builds prompts for, and parses replies from, a text model that writes
/// chapter titles and captions for a recording.
///
/// There is deliberately no networking here: callers pass a completion
/// closure (or a ``TextCompletionProviding``), which keeps every prompt and
/// parser fully testable offline.
public enum DemoChapterGenerator {
    public typealias Completion = @Sendable (_ system: String, _ user: String) async throws -> String

    public struct Prompt: Hashable, Sendable {
        public let system: String
        public let user: String

        public init(system: String, user: String) {
            self.system = system
            self.user = user
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case emptyResponse
        case noJSON
        case noChapters

        public var errorDescription: String? {
            switch self {
            case .emptyResponse:
                return "The AI model returned an empty reply."
            case .noJSON:
                return "The AI reply did not contain chapter JSON."
            case .noChapters:
                return "The AI reply did not contain any usable chapters."
            }
        }
    }

    public static let chapterCountRange = 3...8
    public static let maximumCaptionLength = 60
    /// Keeps the prompt compact for long recordings with many interactions.
    public static let maximumListedEvents = 40

    // MARK: Generating chapters

    public static func generateChapters(
        project: RecordingProject,
        language: String,
        complete: Completion
    ) async throws -> [DemoChapter] {
        let prompt = chapterPrompt(project: project, language: language)
        let response = try await complete(prompt.system, prompt.user)
        return try parseChapters(from: response, duration: project.duration)
    }

    public static func generateChapters(
        project: RecordingProject,
        language: String,
        provider: any TextCompletionProviding
    ) async throws -> [DemoChapter] {
        try await generateChapters(project: project, language: language) { system, user in
            try await provider.complete(system: system, user: user, json: true)
        }
    }

    public static func chapterPrompt(project: RecordingProject, language: String) -> Prompt {
        let system = """
        You write chapter captions for short software product-demo videos. \
        Reply with JSON only, no prose: {"chapters":[{"start":0,"end":4.5,"title":"...","caption":"..."}]}
        Rules:
        - \(chapterCountRange.lowerBound) to \(chapterCountRange.upperBound) chapters in chronological order that together cover the whole recording without overlapping.
        - Times are seconds: start >= 0, end <= the recording duration, each chapter at least 1.5 seconds.
        - Group nearby clicks, zooms and typing into one chapter; change chapters at natural pauses.
        - Titles: at most 4 words. Captions: one line, at most \(maximumCaptionLength) characters, benefit-oriented (what the viewer gains), present tense, no emoji, no quotation marks.
        - Write titles and captions in \(languageName(language)).
        """
        return Prompt(system: system, user: projectSummary(project))
    }

    // MARK: Polishing captions

    /// Rewrites captions concisely. Identity, timing, titles and enabled
    /// state of every chapter are preserved; only captions change.
    public static func polishCaptions(
        _ chapters: [DemoChapter],
        project: RecordingProject,
        language: String,
        complete: Completion
    ) async throws -> [DemoChapter] {
        guard !chapters.isEmpty else { return chapters }
        let prompt = polishPrompt(chapters: chapters, project: project, language: language)
        let response = try await complete(prompt.system, prompt.user)
        return try parsePolishedCaptions(from: response, applyingTo: chapters)
    }

    public static func polishCaptions(
        _ chapters: [DemoChapter],
        project: RecordingProject,
        language: String,
        provider: any TextCompletionProviding
    ) async throws -> [DemoChapter] {
        try await polishCaptions(chapters, project: project, language: language) { system, user in
            try await provider.complete(system: system, user: user, json: true)
        }
    }

    public static func polishPrompt(
        chapters: [DemoChapter],
        project: RecordingProject,
        language: String
    ) -> Prompt {
        let system = """
        You polish captions for a software product-demo video. \
        Reply with JSON only, no prose: {"chapters":[{"index":1,"caption":"..."}]}
        Rules:
        - Return every chapter with its original index; do not add, remove or reorder chapters.
        - Rewrite each caption to be concise, concrete and benefit-oriented: one line, at most \(maximumCaptionLength) characters, present tense, no emoji, no quotation marks.
        - Use the title and the neighbouring chapters for context; write a caption when one is missing.
        - Write in \(languageName(language)).
        """
        var lines = [projectHeadline(project)]
        if let description = normalizedDescription(project.settings.productDescription) {
            lines.append("Product: \(description)")
        }
        lines.append("Chapters:")
        for (index, chapter) in chapters.enumerated() {
            lines.append(
                "{\"index\":\(index + 1),\"start\":\(seconds(chapter.start)),\"end\":\(seconds(chapter.end)),"
                    + "\"title\":\(jsonString(chapter.title)),\"caption\":\(jsonString(chapter.caption))}"
            )
        }
        return Prompt(system: system, user: lines.joined(separator: "\n"))
    }

    // MARK: Parsing

    /// Extracts chapters from a model reply, tolerating Markdown fences and
    /// prose around the JSON. Times outside the recording are clamped and
    /// chapters that do not survive ``ChapterMath/sanitized(_:duration:)``
    /// are rejected.
    public static func parseChapters(from response: String, duration: Double) throws -> [DemoChapter] {
        let entries = try chapterEntries(from: response)
        let chapters = entries.compactMap { entry -> DemoChapter? in
            guard let start = seconds(from: entry["start"]),
                  let end = seconds(from: entry["end"]) else { return nil }
            let title = text(entry["title"]) ?? text(entry["name"]) ?? ""
            let caption = text(entry["caption"]) ?? text(entry["text"]) ?? text(entry["subtitle"]) ?? ""
            return DemoChapter(start: start, end: end, title: singleLine(title), caption: singleLine(caption))
        }
        let valid = ChapterMath.sanitized(chapters, duration: duration)
        guard !valid.isEmpty else { throw Failure.noChapters }
        return valid
    }

    /// Applies polished captions by 1-based `index` (or by position when the
    /// reply omits indices). Chapters the reply skips keep their caption.
    public static func parsePolishedCaptions(
        from response: String,
        applyingTo chapters: [DemoChapter]
    ) throws -> [DemoChapter] {
        let entries = try chapterEntries(from: response)
        var result = chapters
        var applied = 0
        for (position, entry) in entries.enumerated() {
            let index: Int
            if let explicit = seconds(from: entry["index"]) {
                index = Int(explicit.rounded()) - 1
            } else {
                index = position
            }
            guard result.indices.contains(index) else { continue }
            let caption = singleLine(text(entry["caption"]) ?? text(entry["text"]) ?? "")
            guard !caption.isEmpty else { continue }
            result[index].caption = caption
            applied += 1
        }
        guard applied > 0 else { throw Failure.noChapters }
        return result
    }

    static func chapterEntries(from response: String) throws -> [[String: Any]] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyResponse }
        for candidate in jsonCandidates(in: trimmed) {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { continue }
            if let entries = chapterEntries(in: object) { return entries }
        }
        throw Failure.noJSON
    }

    private static func chapterEntries(in object: Any) -> [[String: Any]]? {
        if let dictionary = object as? [String: Any] {
            if let chapters = dictionary["chapters"] as? [[String: Any]] { return chapters }
            for value in dictionary.values {
                if let nested = value as? [String: Any],
                   let chapters = nested["chapters"] as? [[String: Any]] {
                    return chapters
                }
            }
            if dictionary["start"] != nil, dictionary["end"] != nil { return [dictionary] }
            return nil
        }
        if let array = object as? [[String: Any]], !array.isEmpty { return array }
        return nil
    }

    /// Likely JSON documents inside a reply, most specific first: fenced
    /// code blocks, the whole reply, then every balanced `{…}` / `[…]` span.
    static func jsonCandidates(in text: String) -> [String] {
        var candidates = fencedBlocks(in: text)
        candidates.append(text)
        candidates.append(contentsOf: balancedSpans(in: text))
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func fencedBlocks(in text: String) -> [String] {
        guard text.contains("```"),
              let expression = try? NSRegularExpression(
                pattern: "```[A-Za-z0-9_+-]*[ \\t]*\\r?\\n?([\\s\\S]*?)```"
              ) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let blockRange = Range(match.range(at: 1), in: text) else { return nil }
            let block = text[blockRange].trimmingCharacters(in: .whitespacesAndNewlines)
            return block.isEmpty ? nil : block
        }
    }

    private static func balancedSpans(in text: String) -> [String] {
        var spans: [String] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "{" || character == "[",
               let end = matchingClose(from: index, in: characters) {
                spans.append(String(characters[index...end]))
                index = end + 1
                continue
            }
            index += 1
        }
        return spans
    }

    private static func matchingClose(from start: Int, in characters: [Character]) -> Int? {
        var stack: [Character] = []
        var inString = false
        var index = start
        while index < characters.count {
            let character = characters[index]
            if inString {
                if character == "\\" {
                    index += 2
                    continue
                }
                if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{":
                    stack.append("}")
                case "[":
                    stack.append("]")
                case "}", "]":
                    guard stack.popLast() == character else { return nil }
                    if stack.isEmpty { return index }
                default:
                    break
                }
            }
            index += 1
        }
        return nil
    }

    // MARK: Prompt content

    static func projectSummary(_ project: RecordingProject) -> String {
        var lines = [projectHeadline(project)]
        if let description = normalizedDescription(project.settings.productDescription) {
            lines.append("Product: \(description)")
        }
        let duration = project.duration
        let clicks = project.clickEvents
            .filter { $0.time.isFinite && $0.time >= 0 && (!duration.isFinite || $0.time <= duration) }
            .sorted { $0.time < $1.time }
        if clicks.isEmpty {
            lines.append("Clicks: none captured")
        } else {
            let listed = clicks.prefix(maximumListedEvents).map {
                "\(seconds($0.time))@\(coordinate($0.x)),\(coordinate($0.y))"
            }
            var line = "Clicks (time s @ x,y from top-left, 0-1): " + listed.joined(separator: "; ")
            if clicks.count > maximumListedEvents { line += "; and \(clicks.count - maximumListedEvents) more" }
            lines.append(line)
        }
        let zooms = project.zoomSegments
            .filter { $0.isEnabled && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        if zooms.isEmpty {
            lines.append("Zooms: none")
        } else {
            let listed = zooms.prefix(maximumListedEvents).map {
                "\(seconds($0.start))-\(seconds($0.end))->\(coordinate($0.targetX)),\(coordinate($0.targetY))"
            }
            var line = "Zooms (start-end s -> focus x,y): " + listed.joined(separator: "; ")
            if zooms.count > maximumListedEvents { line += "; and \(zooms.count - maximumListedEvents) more" }
            lines.append(line)
        }
        let bursts = typingBursts(
            project.typingActivity ?? [],
            idleDelay: project.settings.resolvedTypingZoom.idleDelay
        )
        if bursts.isEmpty {
            lines.append("Typing bursts: 0")
        } else {
            let starts = bursts.prefix(maximumListedEvents).map { seconds($0.first) + " s" }
            lines.append("Typing bursts: \(bursts.count) (starting at \(starts.joined(separator: ", ")))")
        }
        return lines.joined(separator: "\n")
    }

    private static func projectHeadline(_ project: RecordingProject) -> String {
        let title = project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? "Untitled recording" : title
        return "Recording \(jsonString(name)): \(seconds(project.duration)) s, \(project.sourceWidth)x\(project.sourceHeight)."
    }

    /// Consecutive typing events closer than the idle delay (and in the same
    /// field) count as one burst, mirroring the automatic zoom grouping.
    static func typingBursts(
        _ activity: [TypingActivity],
        idleDelay: Double
    ) -> [(first: Double, last: Double)] {
        let events = activity
            .filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }
            .sorted { $0.time < $1.time }
        var bursts: [(first: Double, last: Double, x: Double, y: Double)] = []
        for event in events {
            if let last = bursts.last,
               event.time - last.last <= idleDelay,
               hypot(event.x - last.x, event.y - last.y) <= 0.08 {
                bursts[bursts.count - 1].last = event.time
            } else {
                bursts.append((event.time, event.time, event.x, event.y))
            }
        }
        return bursts.map { ($0.first, $0.last) }
    }

    static func languageName(_ code: String) -> String {
        let normalized = code.lowercased().replacingOccurrences(of: "_", with: "-")
        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") {
            return "Traditional Chinese (繁體中文)"
        }
        if normalized.hasPrefix("zh") { return "Simplified Chinese (简体中文)" }
        if normalized.hasPrefix("en") { return "English" }
        if normalized.hasPrefix("ja") { return "Japanese" }
        if normalized.hasPrefix("ko") { return "Korean" }
        if normalized.hasPrefix("de") { return "German" }
        if normalized.hasPrefix("fr") { return "French" }
        if normalized.hasPrefix("es") { return "Spanish" }
        return "the language with BCP 47 code \(code)"
    }

    private static func normalizedDescription(_ description: String?) -> String? {
        guard let description else { return nil }
        let value = singleLine(description)
        return value.isEmpty ? nil : String(value.prefix(600))
    }

    // MARK: Value helpers

    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline || $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// Accepts JSON numbers, numeric strings and `m:ss` / `h:mm:ss(,mmm)` clocks.
    static func seconds(from value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        guard var string = value as? String else { return nil }
        string = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasSuffix("s") { string.removeLast() }
        if let double = Double(string), double.isFinite { return double }
        let parts = string.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let component = Double(part), component.isFinite else { return nil }
            total = total * 60 + component
        }
        return total
    }

    private static func seconds(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.2f", value)
    }

    private static func coordinate(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.2f", value.clamped(to: 0...1))
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else { return "\"\"" }
        return String(encoded.dropFirst().dropLast())
    }
}
