@preconcurrency import AVFoundation
import FocusStudioCore
import Foundation

/// The automation API external clients build on: JSON values and structured
/// results, the language of tool texts, working-directory paths, pinned
/// projects, remove_zoom by id, get_project, get_status, per-export width and
/// frame rate with measured progress and cancellation, and assemble_video's
/// output path. Tool texts are checked in English and Chinese while the
/// app's own language setting is Chinese.
extension AIAssistantTests {
    // MARK: - Helpers

    /// The result's structured data, proven to survive `JSONSerialization`.
    static func structured(_ result: AIToolResult, _ name: String) throws -> AIJSONValue {
        guard let data = result.data else { fatalError("FAIL: \(name) returned no structured data") }
        let decoded = try JSONSerialization.jsonObject(with: data.jsonData())
        check(AIJSONValue(jsonObject: decoded) == data, "\(name): structured data survives JSONSerialization")
        return data
    }

    /// Runs `body` with the app's UI language setting (the key AppLocalization
    /// writes) set in the volatile argument domain, which is never saved.
    @MainActor
    static func withAppLanguage<T>(_ code: String, _ body: @MainActor () async throws -> T) async rethrows -> T {
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(saved.merging(["focusStudio.language": code]) { $1 }, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        return try await body()
    }

    // MARK: - JSON values

    static func jsonValues() throws {
        let text = #"{"name":"demo","count":3,"ratio":0.25,"on":true,"off":false,"none":null,"list":[1,"two",[false]],"nested":{"path":"/tmp/a b.mp4"}}"#
        guard let value = AIJSONValue(jsonObject: try JSONSerialization.jsonObject(with: Data(text.utf8))) else {
            fatalError("FAIL: JSONSerialization output must convert")
        }
        check(value["name"]?.stringValue == "demo" && value["count"]?.intValue == 3 && value["ratio"]?.doubleValue == 0.25, "strings and numbers: \(value)")
        check(value["on"] == .bool(true) && value["off"] == .bool(false) && value["none"] == .null && value["none"]?.isNull == true, "booleans stay booleans and null stays null")
        check(value["list"]?[0] == .number(1) && value["list"]?[1]?.stringValue == "two" && value["list"]?[2]?[0] == .bool(false) && value["list"]?[3] == nil, "arrays nest")
        check(value["nested"]?["path"]?.stringValue == "/tmp/a b.mp4" && value["missing"] == nil && value["name"]?["x"] == nil, "objects nest")
        check(AIJSONValue(jsonObject: NSNumber(value: 1)) == .number(1) && AIJSONValue(jsonObject: NSNumber(value: true)) == .bool(true)
              && AIJSONValue(jsonObject: true) == .bool(true) && AIJSONValue(jsonObject: 0) == .number(0), "1 and true stay distinct")

        let reparsed = try JSONSerialization.jsonObject(with: value.jsonData())
        check(AIJSONValue(jsonObject: reparsed) == value, "JSONSerialization round trip")
        let coded = try JSONDecoder().decode(AIJSONValue.self, from: JSONEncoder().encode(value))
        check(coded == value, "Codable round trip")
        let decoded = try JSONDecoder().decode(AIJSONValue.self, from: Data(text.utf8))
        check(decoded == value, "JSONDecoder reads the same document")
        check((value.jsonObject as? [String: Any])?["count"] is Int && (value.jsonObject as? [String: Any])?["ratio"] is Double, "whole numbers come back as Int")

        check(AIJSONValue(jsonObject: Date()) == nil && AIJSONValue(jsonObject: Double.nan) == nil && AIJSONValue(jsonObject: ["a": [Date()]]) == nil, "non-JSON values are rejected")
        check(AIJSONValue(Double.infinity) == .null && AIJSONValue.rounded(.nan) == .null, "non-finite numbers become null")
        check(AIJSONValue.rounded(1.234_56) == .number(1.235) && AIJSONValue.rounded(2.0 / 3.0, places: 1) == .number(0.7), "rounding keeps numbers short")
        let literal: AIJSONValue = ["id": "x", "n": 2, "f": 1.5, "ok": true, "none": nil, "list": [1, "a"]]
        let compact = String(decoding: try literal.jsonData(), as: UTF8.self)
        check(compact == #"{"f":1.5,"id":"x","list":[1,"a"],"n":2,"none":null,"ok":true}"#, "literals build compact JSON with sorted keys: \(compact)")
        check(AIJSONValue(URL(fileURLWithPath: "/tmp/x y.mp4")) == .string("/tmp/x y.mp4") && AIJSONValue(Date(timeIntervalSince1970: 0)) == .string("1970-01-01T00:00:00Z"), "paths are absolute strings, dates ISO 8601")
        check(AIToolResult(text: "t").data == nil && AIToolResult(text: "t", data: ["a": 1]) != AIToolResult(text: "t"), "data is optional and compared")
    }

    // MARK: - Result language

    @MainActor
    static func resultLanguage(root: URL) async throws {
        try await withAppLanguage("zh-Hans") {
            check(L10n.tr("Set %lld chapters") == "已设置 %lld 个章节", "the app's own language is Chinese for this test: \(L10n.tr("Set %lld chapters"))")
            let box = ProjectBox(makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 12))
            var english = makeContext(root: root, box: box)
            english.assetsDirectory = root.appendingPathComponent("language-assets", isDirectory: true)
            var chinese = english
            chinese.uiLanguage = "zh-Hans"
            check(english.resultLanguage == .english && chinese.resultLanguage == .simplifiedChinese, "the context names its result language")

            let chapters: [String: Any] = ["chapters": [["start": 0, "end": 3, "title": "Intro"]]]
            let inEnglish = try await SetChaptersTool().run(arguments: chapters, context: english, progress: { _ in })
            let inChinese = try await SetChaptersTool().run(arguments: chapters, context: chinese, progress: { _ in })
            check(inEnglish.text.hasPrefix("Set 1 chapters") && inChinese.text.hasPrefix("已设置 1 个章节"), "set_chapters follows the call's language: \(inEnglish.text) / \(inChinese.text)")
            let settingsEnglish = try await UpdateSettingsTool().run(arguments: ["padding": 20], context: english, progress: { _ in })
            let settingsChinese = try await UpdateSettingsTool().run(arguments: ["padding": 24], context: chinese, progress: { _ in })
            check(settingsEnglish.text == "Updated padding = 20" && settingsChinese.text == "已更新 padding = 24", "update_settings too: \(settingsEnglish.text) / \(settingsChinese.text)")
            let assets = try await ListAssetsTool().run(arguments: [:], context: english, progress: { _ in })
            check(assets.text.hasPrefix("No assets yet"), "list_assets too: \(assets.text)")

            // Progress and errors follow it as well.
            let (appContext, _, _) = makeFakeApp(root: root)
            let messages = ToolLog()
            _ = try await ListRecordingSourcesTool().run(arguments: [:], context: appContext, progress: { messages.record($0) })
            var chineseApp = appContext
            chineseApp.uiLanguage = "zh-Hans"
            _ = try await ListRecordingSourcesTool().run(arguments: [:], context: chineseApp, progress: { messages.record($0) })
            check(messages.runs == ["Finding screens and windows…", "正在查找屏幕和窗口…"], "progress is written in the call's language: \(messages.runs)")
            // The app's own refusals too, from the recording tools and edits.
            let busy = AILocalizedFailure("Finish the current library operation before starting another.")
            let (busyApp, fakeApp, _) = makeFakeApp(root: root)
            var busyChinese = busyApp
            busyChinese.uiLanguage = "zh-Hans"
            fakeApp.refreshError = busy
            await expectToolError("list_recording_sources refusal in English", { _ = try await ListRecordingSourcesTool().run(arguments: [:], context: busyApp, progress: { _ in }) }) {
                $0 == .failed("Finish the current library operation before starting another.")
            }
            await expectToolError("list_recording_sources refusal in Chinese", { _ = try await ListRecordingSourcesTool().run(arguments: [:], context: busyChinese, progress: { _ in }) }) {
                $0 == .failed("请等待当前项目库操作完成后再进行下一项操作。")
            }
            fakeApp.refreshError = nil
            fakeApp.startFailure = busy
            await expectToolError("start_recording refusal in English", { _ = try await StartRecordingTool().run(arguments: ["source": "display-1"], context: busyApp, progress: { _ in }) }) {
                $0 == .failed("Finish the current library operation before starting another.")
            }
            check(fakeApp.recordingPhase == .idle, "a refused start leaves nothing recording")
            var refusingEdits = english
            refusingEdits.updateProject = { _ in throw busy }
            await expectToolError("an edit refused by the app in English", { _ = try await SetChaptersTool().run(arguments: chapters, context: refusingEdits, progress: { _ in }) }) {
                $0 == .failed("Finish the current library operation before starting another.")
            }
            let keyless = makeContext(root: root, box: box, key: nil)
            await expectToolError("missing key in English", { _ = try await AIToolSupport.requireArkClient(keyless) }) {
                $0 == .failed("Add a Volcengine Ark API key in Settings to generate media.")
            }

            check(L10n.format("Set %lld chapters", language: .english, 3) == "Set 3 chapters" && L10n.format("Set %lld chapters", language: .simplifiedChinese, 3) == "已设置 3 个章节", "L10n.format takes an explicit language")
            check(AppLanguage(localeIdentifier: "zh-Hans") == .simplifiedChinese && AppLanguage(localeIdentifier: "zh-Hant-TW") == .simplifiedChinese
                  && AppLanguage(localeIdentifier: "en-GB") == .english && AppLanguage(localeIdentifier: "ja") == .english, "identifiers map to the shipped languages")
            // An English call leaves nothing behind: the app's own texts stay Chinese.
            check(L10n.tr("Exporting…") == "导出中…" && L10n.format("Set %lld chapters", 2) == "已设置 2 个章节", "the global language is untouched")
        }
    }

    // MARK: - Working-directory paths

    @MainActor
    static func workingDirectoryPaths(root: URL) async throws {
        let fileManager = FileManager.default
        let cwd = root.appendingPathComponent("client-cwd", isDirectory: true)
        let assets = root.appendingPathComponent("cwd-assets", isDirectory: true)
        try fileManager.createDirectory(at: cwd.appendingPathComponent("media", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)
        let background = cwd.appendingPathComponent("media/bg.jpg")
        try Pixels.writeJPEG(width: 8, height: 8, color: (0.9, 0.1, 0.1), to: background)
        try Pixels.writeJPEG(width: 8, height: 8, color: (0.1, 0.9, 0.1), to: assets.appendingPathComponent("generated.jpg"))
        for folder in [cwd, assets] { try Pixels.writeJPEG(width: 8, height: 8, color: (0.1, 0.1, 0.9), to: folder.appendingPathComponent("both.jpg")) }

        let box = ProjectBox(makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 12))
        var context = makeContext(root: root, box: box)
        context.assetsDirectory = assets
        context.workingDirectory = cwd
        context.isExternal = true
        func input(_ raw: String, _ context: AIAssistantContext) -> String {
            (try? AIToolPaths.existingLocalFile(raw, context: context).path) ?? "missing"
        }
        check(input("media/bg.jpg", context) == background.path, "a relative input is found in the working directory")
        check(input("./media/../media/bg.jpg", context) == background.path, "dot segments resolve inside it")
        check(input("generated.jpg", context) == assets.appendingPathComponent("generated.jpg").path, "else it names a file in the assets folder")
        check(input("both.jpg", context) == cwd.appendingPathComponent("both.jpg").path, "the working directory wins when both have the file")
        check(input("nowhere.jpg", context) == "missing" && input(background.path, context) == background.path, "missing files fail; absolute paths are used as given")
        var inApp = context
        inApp.workingDirectory = nil
        inApp.isExternal = false
        check(input("both.jpg", inApp) == assets.appendingPathComponent("both.jpg").path && input("media/bg.jpg", inApp) == "missing", "without a working directory inputs come from the assets folder, as before")
        _ = try await SetBackgroundImageTool().run(arguments: ["path": "media/bg.jpg"], context: context, progress: { _ in })
        check(box.project?.settings.backgroundImagePath == background.path, "tools read working-directory inputs")

        func output(_ raw: String?, _ context: AIAssistantContext) -> String {
            do { return try ExportProjectTool.resolveOutputURL(path: raw, context: context).path } catch { return "error: \(error.localizedDescription)" }
        }
        check(output("out/demo", context) == cwd.appendingPathComponent("out/demo.mp4").path, "a relative output lands in the working directory")
        let folder = output("renders/", context)
        check(folder.hasPrefix(cwd.appendingPathComponent("renders").path + "/export-") && folder.hasSuffix(".mp4"), "a relative folder too: \(folder)")
        check(output(nil, context).hasPrefix(assets.path + "/export-"), "no path still means the assets folder")
        let absolute = root.appendingPathComponent("absolute/demo.mp4").path
        let home = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Movies/fs-cwd-test.mp4").path
        check(output(absolute, context) == absolute && output("~/Movies/fs-cwd-test.mp4", context) == home, "absolute and ~ paths ignore the working directory")
        for (name, directory) in [("no working directory", nil), ("working directory /", URL(fileURLWithPath: "/"))] as [(String, URL?)] {
            var external = context
            external.workingDirectory = directory
            check(output("demo.mp4", external).contains("absolute path"), "\(name): an external relative output asks for an absolute path: \(output("demo.mp4", external))")
            check(output(absolute, external) == absolute && output(nil, external).hasPrefix(assets.path), "\(name): absolute and default outputs still work")
            var local = external
            local.isExternal = false
            check(output("demo.mp4", local) == assets.appendingPathComponent("demo.mp4").path, "\(name): the in-app assistant keeps the assets folder")
        }

        // The export guard applies to working-directory paths: the project's own folder as cwd.
        let library = root.appendingPathComponent("cwd-library", isDirectory: true)
        var project = makeProject(sourceVideoPath: "", duration: 5)
        let projectFolder = library.appendingPathComponent(project.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: projectFolder.appendingPathComponent("ai", isDirectory: true), withIntermediateDirectories: true)
        let recording = projectFolder.appendingPathComponent("raw.mp4")
        try Data("keep".utf8).write(to: recording)
        project.sourceVideoPath = recording.path
        var guarded = context
        guarded.projectsDirectory = library
        guarded.workingDirectory = projectFolder
        guarded.assetsDirectory = projectFolder.appendingPathComponent("ai", isDirectory: true)
        func refusal(_ raw: String, overwrite: Bool = false) -> String {
            do { return "accepted \(try ExportProjectTool.resolveOutputURL(path: raw, context: guarded, project: project, overwrite: overwrite).path)" } catch { return error.localizedDescription }
        }
        check(refusal("raw.mp4", overwrite: true).contains("this project uses"), "the recording is refused through the working directory: \(refusal("raw.mp4", overwrite: true))")
        check(refusal("demo.mp4").contains("inside the Focus Studio library"), "the library is refused through the working directory")
        check(refusal("ai/final.mp4") == "accepted " + projectFolder.appendingPathComponent("ai/final.mp4").path, "the project's ai folder is allowed")
        let kept = try Data(contentsOf: recording)
        check(kept == Data("keep".utf8), "the recording is untouched")
    }

    // MARK: - Structured results

    /// Every tool external clients get returns structured data next to its
    /// text (capture_frame, export_project and assemble_video are checked with
    /// real media below), and a call pinned to a project never touches another.
    @MainActor
    static func structuredResults(root: URL) async throws {
        let (context, app, box) = makeFakeApp(root: root)
        app.tracks = [AIMusicTrack(id: "calm-gradient", title: "Calm Gradient", mood: "Soft", durationSeconds: 60, suggestedVolume: 0.17, path: "/bundle/calm.m4a")]

        let sources = try structured(try await ListRecordingSourcesTool().run(arguments: [:], context: context, progress: { _ in }), "list_recording_sources")
        check(sources["display_count"] == 2 && sources["window_count"] == 3 && sources["sources"]?.arrayValue?.count == 5 && sources["omitted_windows"] == 0, "sources are counted and listed: \(sources)")
        check(sources["sources"]?[0]?["id"] == "display-1" && sources["sources"]?[0]?["kind"] == "display" && sources["sources"]?[2]?["id"] == "win-3" && sources["sources"]?[2]?["app"] == "Xcode" && sources["sources"]?[2]?["width"] == 1_600, "displays first, then windows by size, with app and size")

        let started = try structured(try await StartRecordingTool(startTimeout: 2).run(arguments: ["source": "Safari", "microphone": true, "frame_rate": 30], context: context, progress: { _ in }), "start_recording")
        check(started["state"] == "recording" && started["source"]?["id"] == "win-1" && started["options"] == ["microphone": true, "frame_rate": 30], "start reports the source and only the given options: \(started)")
        check(started["started_at"]?.stringValue?.contains("T") == true && started["duration"] == nil && started["auto_stop_at"] == nil, "start reports when it started, and no automatic stop without a duration: \(started)")
        let stopped = try structured(try await StopRecordingTool(stopTimeout: 2).run(arguments: [:], context: context, progress: { _ in }), "stop_recording")
        let recorded = app.projects[0]
        check(stopped["project_id"]?.stringValue == recorded.id.uuidString && stopped["id"]?.stringValue == recorded.id.uuidString && stopped["duration"] == 12 && stopped["open_in_editor"] == true && stopped["title"] == "Recording 1" && stopped["state"] == "finished", "stop returns the new project: \(stopped)")

        var older = makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 4)
        older.title = "Older"
        app.projects.append(older)
        let listed = try structured(try await ListProjectsTool().run(arguments: [:], context: context, progress: { _ in }), "list_projects")
        check(listed["total"] == 2 && listed["omitted"] == 0 && listed["open_project_id"]?.stringValue == recorded.id.uuidString, "the library is counted and the open project named: \(listed)")
        check(listed["projects"]?[0]?["id"]?.stringValue == recorded.id.uuidString && listed["projects"]?[0]?["open_in_editor"] == true && listed["projects"]?[1]?["title"] == "Older" && listed["projects"]?[1]?["open_in_editor"] == false && listed["projects"]?[1]?["created_at"]?.stringValue?.contains("T") == true, "entries carry id, title, dates and whether they are open")
        check(listed["has_more"] == false && listed["matched"] == 2 && listed["offset"] == 0, "a small library fits one page: \(listed)")

        let projectID = AIJSONValue(recorded.id.uuidString)
        let zoom = try structured(try await AddZoomTool().run(arguments: ["start": 2, "end": 3, "x": 0.25, "y": 0.75, "scale": 2], context: context, progress: { _ in }), "add_zoom")
        let addedID = box.project!.zoomSegments.last!.id.uuidString
        check(zoom["project_id"] == projectID && zoom["zoom_id"]?.stringValue == addedID && zoom["index"] == 2 && zoom["zoom_count"] == 2, "add_zoom returns the new zoom's id and number: \(zoom)")
        check(zoom["zoom"]?["x"] == 0.25 && zoom["zoom"]?["y"] == 0.75 && zoom["zoom"]?["start"] == 2 && zoom["zoom"]?["kind"] == "manual" && zoom["zoom"]?["enabled"] == true, "and the zoom itself")
        let style = try structured(try await SetZoomStyleTool().run(arguments: ["zoomHold": 1.2, "zoomScale": 2.2], context: context, progress: { _ in }), "set_zoom_style")
        check(style["project_id"] == projectID && style["zoom_style"]?["zoomHold"] == 1.2 && style["zoom_style"]?["zoomScale"] == 2.2 && style["changes"]?.arrayValue?.count == 2 && style["zoom_count"]?.intValue != nil, "set_zoom_style returns the resulting style: \(style)")
        let settings = try structured(try await UpdateSettingsTool().run(arguments: ["padding": 500, "exportWidth": 2_560, "backgroundPreset": "ocean"], context: context, progress: { _ in }), "update_settings")
        check(settings["look"]?["padding"] == 160 && settings["look"]?["backgroundPreset"] == "ocean" && settings["export_width"] == 2_560 && settings["frame_rate"] == 30, "update_settings returns the resulting look and export: \(settings)")
        check(settings["changes"]?.arrayValue?.contains(.string("padding = 160 (clamped)")) == true, "and the change notes: \(settings["changes"] ?? .null)")
        let chapters = try structured(try await SetChaptersTool().run(arguments: ["chapters": [["start": 0, "end": 4, "title": "Intro", "caption": "Hello"], ["start": 5, "end": 5.1, "title": "Blink"], ["end": 2]]], context: context, progress: { _ in }), "set_chapters")
        check(chapters["chapters"] == [["index": 1, "start": 0, "end": 4, "title": "Intro", "caption": "Hello"]] && chapters["dropped"] == 2, "set_chapters returns what was kept and how many were dropped: \(chapters)")

        let image = root.appendingPathComponent("structured-background.jpg")
        try Pixels.writeJPEG(width: 32, height: 18, color: (0.3, 0.3, 0.3), to: image)
        let background = try structured(try await SetBackgroundImageTool().run(arguments: ["path": image.path], context: context, progress: { _ in }), "set_background_image")
        check(background == ["project_id": projectID, "path": AIJSONValue(image), "width": 32, "height": 18], "set_background_image: \(background)")
        let music = try structured(try await SetBackgroundMusicTool().run(arguments: ["track": "calm", "volume": 0.4], context: context, progress: { _ in }), "set_background_music")
        check(music["track"]?["id"] == "calm-gradient" && music["track"]?["bundled"] == true && music["track"]?["path"] == "/bundle/calm.m4a" && music["volume"] == 0.4, "set_background_music names the bundled track: \(music)")
        let silence = try structured(try await SetBackgroundMusicTool().run(arguments: ["track": "none"], context: context, progress: { _ in }), "set_background_music none")
        check(silence == ["project_id": projectID, "track": nil], "removing music: \(silence)")
        let effects = try structured(try await SetSoundEffectsTool().run(arguments: ["click": true, "zoom_volume": 0.5], context: context, progress: { _ in }), "set_sound_effects")
        check(effects["click"] == true && effects["zoom"] == false && effects["zoom_volume"] == 0.5 && effects["project_id"] == projectID, "set_sound_effects returns the resulting audio: \(effects)")
        var assetContext = context
        assetContext.assetsDirectory = root.appendingPathComponent("structured-assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetContext.assetsDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: image, to: assetContext.assetsDirectory.appendingPathComponent("still.jpg"))
        try "notes".write(to: assetContext.assetsDirectory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let assets = try structured(try await ListAssetsTool().run(arguments: [:], context: assetContext, progress: { _ in }), "list_assets")
        check(assets["count"] == 1 && assets["directory"]?.stringValue == assetContext.assetsDirectory.path && assets["assets"]?[0]?["name"] == "still.jpg" && assets["assets"]?[0]?["kind"] == "image"
              && assets["assets"]?[0]?["width"] == 32 && (assets["assets"]?[0]?["size_bytes"]?.intValue ?? 0) > 0 && assets["assets"]?[0]?["path"]?.stringValue?.hasPrefix("/") == true, "list_assets returns absolute paths, kinds and sizes: \(assets)")

        // A call pinned to one project never reads or edits another.
        var pinned = context
        pinned.projectID = older.id
        let writes = box.writeCount
        await expectToolError("pinned to a project that is not open", { _ = try await AddZoomTool().run(arguments: ["start": 1, "end": 2, "x": 0.5, "y": 0.5], context: pinned, progress: { _ in }) }) {
            if case let .failed(message) = $0 { return message.contains(older.id.uuidString) && message.contains("no longer the one open") } else { return false }
        }
        check(box.writeCount == writes, "nothing was written")
        pinned.projectID = recorded.id
        _ = try await AddZoomTool().run(arguments: ["start": 1, "end": 2, "x": 0.5, "y": 0.5], context: pinned, progress: { _ in })
        check(box.writeCount == writes + 1, "a call pinned to the open project works")
    }

    // MARK: - remove_zoom by id

    @MainActor
    static func removeZoomByID(root: URL) async throws {
        let (context, app, box) = makeFakeApp(root: root)
        let project = makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 10)
        app.projects = [project]
        try app.openProject(id: project.id)
        let late = try await AddZoomTool().run(arguments: ["start": 6, "end": 7, "x": 0.5, "y": 0.5], context: context, progress: { _ in })
        let lateID = try structured(late, "add_zoom")["zoom_id"]!.stringValue!
        // An earlier zoom shifts the late one's number from 2 to 3; its id still finds it.
        _ = try await AddZoomTool().run(arguments: ["start": 3, "end": 4, "x": 0.5, "y": 0.5], context: context, progress: { _ in })
        check(AIToolSupport.orderedZooms(box.project!).first { $0.segment.id.uuidString == lateID }?.index == 3, "the late zoom is now #3")
        let removeSchema = RemoveZoomTool().parametersSchema
        check((removeSchema["properties"] as? [String: Any])?["id"] != nil && removeSchema["required"] == nil, "the schema offers id and requires neither")
        let removeProperties = removeSchema["properties"] as? [String: [String: Any]]
        check(removeProperties?["index"]?["type"] as? String == "integer" && removeProperties?["all"]?["type"] as? String == "boolean",
              "one JSON type per property: index is a number, all a flag")
        await expectToolError("id and a different index", { _ = try await RemoveZoomTool().run(arguments: ["id": lateID, "index": 2], context: context, progress: { _ in }) }) {
            if case let .invalidArgument(message) = $0 { return message.contains("#3") } else { return false }
        }
        let removed = try await RemoveZoomTool().run(arguments: ["id": lateID.lowercased(), "index": 3], context: context, progress: { _ in })
        let data = try structured(removed, "remove_zoom")
        check(!box.project!.zoomSegments.contains { $0.id.uuidString == lateID } && box.project!.zoomSegments.count == 2, "the zoom with that id is gone")
        check(removed.text.contains("Removed zoom #3") && data["removed"]?["id"]?.stringValue == lateID && data["removed_count"] == 1 && data["remaining"] == 2, "remove by id reports what went: \(removed.text) \(data)")
        await expectToolError("removed id", { _ = try await RemoveZoomTool().run(arguments: ["id": lateID], context: context, progress: { _ in }) }) {
            if case let .invalidArgument(message) = $0 { return message.contains("No zoom has the id") } else { return false }
        }
        await expectToolError("malformed id", { _ = try await RemoveZoomTool().run(arguments: ["id": "zoom-3"], context: context, progress: { _ in }) }) {
            if case let .invalidArgument(message) = $0 { return message.contains("zoom id") } else { return false }
        }
        let firstID = AIToolSupport.orderedZooms(box.project!)[0].segment.id.uuidString
        _ = try await RemoveZoomTool().run(arguments: ["zoom_id": firstID], context: context, progress: { _ in })
        check(box.project!.zoomSegments.count == 1, "zoom_id is accepted as an alias")
        let remainingID = AIToolSupport.orderedZooms(box.project!)[0].segment.id.uuidString
        for conflicting in [["id": remainingID, "all": true], ["index": 1, "all": true]] as [[String: Any]] {
            await expectToolError("all with \(conflicting.keys.sorted())", { _ = try await RemoveZoomTool().run(arguments: conflicting, context: context, progress: { _ in }) }) {
                if case let .invalidArgument(message) = $0 { return message.contains("only one") } else { return false }
            }
        }
        check(box.project!.zoomSegments.count == 1, "conflicting arguments remove nothing")
        let all = try structured(try await RemoveZoomTool().run(arguments: ["all": true], context: context, progress: { _ in }), "remove_zoom all")
        check(all["removed_count"] == 1 && all["remaining"] == 0 && box.project!.zoomSegments.isEmpty, "remove all: \(all)")
        let legacy = try await RemoveZoomTool().run(arguments: ["index": "all"], context: context, progress: { _ in })
        check(legacy.text == "The project has no zooms.", "index \"all\" is still accepted: \(legacy.text)")
        await expectThrows("neither index nor id") { _ = try await RemoveZoomTool().run(arguments: [:], context: context, progress: { _ in }) }
    }

    // MARK: - list_projects paging

    /// Every project stays reachable by id: pages through offset and limit,
    /// and a title search, while the call without arguments reads as before.
    @MainActor
    static func listProjectsPaging(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)
        app.projects = (0..<45).map { number in
            var project = makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 3)
            project.title = number % 10 == 3 ? "Checkout take \(number)" : "Demo \(number)"
            return project
        }
        func list(_ arguments: [String: Any]) async throws -> (text: String, data: AIJSONValue) {
            let result = try await ListProjectsTool().run(arguments: arguments, context: context, progress: { _ in })
            return (result.text, try structured(result, "list_projects \(arguments)"))
        }

        let first = try await list([:])
        check(first.data["total"] == 45 && first.data["matched"] == 45 && first.data["offset"] == 0 && first.data["has_more"] == true && first.data["omitted"] == 15
              && first.data["projects"]?.arrayValue?.count == 30 && first.data["projects"]?[0]?["title"] == "Demo 0", "the first page holds the newest 30: \(first.data["has_more"] ?? .null)")
        check(first.text.hasPrefix("45 projects (newest first)") && first.text.contains("\n30. Demo 29") && first.text.hasSuffix("(15 older projects omitted)"), "the default text reads as before: \(first.text.suffix(80))")

        let rest = try await list(["offset": 30])
        check(rest.data["has_more"] == false && rest.data["offset"] == 30 && rest.data["omitted"] == 30 && rest.data["projects"]?.arrayValue?.count == 15
              && rest.data["projects"]?[14]?["id"]?.stringValue == app.projects[44].id.uuidString, "the next page reaches the oldest project: \(rest.data["projects"]?.arrayValue?.count ?? -1)")
        check(rest.text.contains("\n31. Demo 30") && rest.text.contains("45. Demo 44") && !rest.text.contains("more;") && !rest.text.contains("omitted"), "pages number from the offset: \(rest.text.prefix(120))")
        let paged = try await list(["offset": "10", "limit": 5])
        check(paged.data["projects"]?.arrayValue?.map { $0["title"]?.stringValue ?? "" } == (10..<15).map { $0 == 13 ? "Checkout take 13" : "Demo \($0)" } && paged.data["has_more"] == true, "offset and limit pick a slice: \(paged.data["projects"] ?? .null)")
        check(paged.text.hasSuffix("(30 more; call again with offset: 15)"), "a paging caller learns the next offset: \(paged.text.suffix(60))")
        let wide = try await list(["limit": 500])
        check(wide.data["projects"]?.arrayValue?.count == 45 && wide.data["has_more"] == false, "limit is capped at 100 and covers a 45-project library")
        let clamped = try await list(["limit": 0, "offset": -3])
        check(clamped.data["projects"]?.arrayValue?.count == 1 && clamped.data["offset"] == 0, "out-of-range numbers are clamped")
        let past = try await list(["offset": 60])
        check(past.data["projects"]?.arrayValue?.isEmpty == true && past.data["has_more"] == false && past.text.contains("nothing after offset 60"), "an offset past the end: \(past.text)")

        let search = try await list(["query": "  CHECKOUT "])
        check(search.data["matched"] == 5 && search.data["total"] == 45 && search.data["has_more"] == false
              && search.data["projects"]?.arrayValue?.map { $0["title"]?.stringValue ?? "" } == [3, 13, 23, 33, 43].map { "Checkout take \($0)" }, "query matches titles case-insensitively, newest first: \(search.data["projects"] ?? .null)")
        check(search.text.hasPrefix("5 of 45 projects contain \"CHECKOUT\"") && search.text.contains("1. Checkout take 3") && search.text.contains("5. Checkout take 43"), "search text: \(search.text.prefix(80))")
        let searchPage = try await list(["query": "checkout", "offset": 3, "limit": 1])
        check(searchPage.data["projects"]?[0]?["title"] == "Checkout take 33" && searchPage.data["has_more"] == true && searchPage.text.hasSuffix("(1 more; call again with offset: 4)"), "search results page too: \(searchPage.text)")
        let none = try await list(["query": "invoice"])
        check(none.text == "No project title contains \"invoice\"." && none.data["matched"] == 0 && none.data["projects"] == [], "a query with no match says so: \(none.text)")
        let blank = try await list(["query": "   "])
        check(blank.data["matched"] == 45 && blank.text.hasSuffix("(15 older projects omitted)"), "a blank query lists everything")
    }

    // MARK: - get_project

    @MainActor
    static func getProject(root: URL) async throws {
        let (context, app, box) = makeFakeApp(root: root)
        let folder = root.appendingPathComponent("report-project", isDirectory: true)
        var project = makeProject(sourceVideoPath: folder.appendingPathComponent("raw.mp4").path, duration: 20)
        project.title = "Checkout flow"
        project.clickEvents = [ClickEvent(time: 1.23456, x: 0.1, y: 0.2, button: .left), ClickEvent(time: 0.5, x: 0.3, y: 0.4, button: .left)]
        project.typingActivity = [TypingActivity(time: 4, x: 0.6, y: 0.7)]
        project.chapters = [DemoChapter(start: 5, end: 9, title: "Pay", caption: "One tap"), DemoChapter(start: 0, end: 4, title: "Browse")]
        project.settings.padding = 40
        project.settings.frameRate = 60
        project.settings.productDemoAudio = ProductDemoAudioSettings(backgroundMusicPath: "/bundle/calm.m4a", backgroundMusicVolume: 0.3, clickSoundEnabled: true)
        app.tracks = [AIMusicTrack(id: "calm-gradient", title: "Calm Gradient", path: "/bundle/calm.m4a")]
        var other = makeProject(sourceVideoPath: "/elsewhere/raw.mp4", duration: 3)
        other.title = "Other"
        app.projects = [other, project]
        try app.openProject(id: other.id)

        // Not open: read from the library, and the editor stays on the other project.
        let result = try await GetProjectTool().run(arguments: ["project_id": project.id.uuidString], context: context, progress: { _ in })
        let data = try structured(result, "get_project")
        check(app.openID == other.id && box.project?.id == other.id && app.closeCount == 0, "get_project never navigates")
        check(data["id"]?.stringValue == project.id.uuidString && data["title"] == "Checkout flow" && data["duration"] == 20 && data["source_width"] == 640 && data["source_height"] == 360 && data["open_in_editor"] == false, "identity and size: \(data)")
        check(data["created_at"]?.stringValue?.contains("T") == true && data["export_width"] == 1_920 && data["frame_rate"] == 60, "dates and export settings")
        check(data["look"]?["padding"] == 40 && data["look"]?["backgroundStyle"] == "gradient" && data["look"]?["aspectRatio"] == "wide" && data["look"]?["captionPosition"] == "bottom", "look under update_settings' names: \(data["look"] ?? .null)")
        check(data["zoom_style"]?["autoZoomEnabled"] == true && data["zoom_style"]?["zoomHold"]?.doubleValue != nil, "zoom style under set_zoom_style's names")
        check(data["audio"]?["background_music"]?["track_id"] == "calm-gradient" && data["audio"]?["background_music"]?["volume"] == 0.3 && data["audio"]?["click"] == true && data["audio"]?["zoom"] == false, "audio under set_sound_effects' names: \(data["audio"] ?? .null)")
        let zoomID = project.zoomSegments[0].id.uuidString
        check(data["zoom_count"] == 1 && data["zooms"]?[0]?["id"]?.stringValue == zoomID && data["zooms"]?[0]?["index"] == 1 && data["zooms"]?[0]?["scale"] == 1.6, "zooms with ids and numbers: \(data["zooms"] ?? .null)")
        check(data["chapters"]?[0]?["title"] == "Browse" && data["chapters"]?[1]?["caption"] == "One tap" && data["chapters"]?[1]?["index"] == 2, "chapters in time order")
        check(data["clicks"]?["count"] == 2 && data["clicks"]?["items"] == [[0.5, 0.3, 0.4], [1.235, 0.1, 0.2]], "clicks as [t, x, y] in time order, rounded: \(data["clicks"] ?? .null)")
        check(data["typing"] == [["t": 4, "x": 0.6, "y": 0.7]] && data["typing_count"] == 1, "typing moments")
        check(data["assets_dir"]?.stringValue == folder.appendingPathComponent("ai").path, "the project's assets folder: \(data["assets_dir"] ?? .null)")
        check(result.text.hasPrefix("Project \"Checkout flow\" (id \(project.id.uuidString), not open in the editor)") && result.text.contains("Title: Checkout flow") && result.text.contains("Chapters: 1. 0–4 s Browse"), "text: \(result.text)")

        // The open project is read from the editor, with edits the library has not seen.
        box.project!.title = "Edited in the editor"
        let open = try structured(try await GetProjectTool().run(arguments: ["project_id": other.id.uuidString], context: context, progress: { _ in }), "get_project open")
        check(open["title"] == "Edited in the editor" && open["open_in_editor"] == true, "the editor's copy is the freshest: \(open["title"] ?? .null)")
        let byDefault = try structured(try await GetProjectTool().run(arguments: [:], context: context, progress: { _ in }), "get_project without id")
        check(byDefault["id"]?.stringValue == other.id.uuidString, "without an id the open project is described")
        var pinned = context
        pinned.projectID = project.id
        let pinnedData = try structured(try await GetProjectTool().run(arguments: [:], context: pinned, progress: { _ in }), "get_project pinned")
        check(pinnedData["id"]?.stringValue == project.id.uuidString && app.openID == other.id, "a pinned call describes its project without opening it")

        await expectToolError("unknown id", { _ = try await GetProjectTool().run(arguments: ["project_id": UUID().uuidString], context: context, progress: { _ in }) }) {
            if case let .invalidArgument(message) = $0 { return message.contains("list_projects") } else { return false }
        }
        await expectToolError("malformed id", { _ = try await GetProjectTool().run(arguments: ["project_id": "checkout"], context: context, progress: { _ in }) }) {
            if case .invalidArgument = $0 { return true } else { return false }
        }
        app.closeEditor()
        await expectToolError("no id and nothing open", { _ = try await GetProjectTool().run(arguments: [:], context: context, progress: { _ in }) }) {
            if case let .invalidArgument(message) = $0 { return message.contains("project_id") } else { return false }
        }
        await expectToolError("no app", { _ = try await GetProjectTool().run(arguments: ["project_id": project.id.uuidString], context: makeContext(root: root, box: box), progress: { _ in }) }) { $0 == .appUnavailable }
        // Relative sources live in the library's project folder.
        var legacy = makeProject(sourceVideoPath: "raw.mp4", duration: 2)
        legacy.title = "Legacy"
        app.projects.append(legacy)
        let legacyData = try structured(try await GetProjectTool().run(arguments: ["project_id": legacy.id.uuidString], context: context, progress: { _ in }), "get_project legacy")
        check(legacyData["assets_dir"]?.stringValue == app.library.appendingPathComponent("\(legacy.id.uuidString)/ai").path, "assets folder from the library root: \(legacyData["assets_dir"] ?? .null)")

        // A long recording stays far below a client's output limit.
        var long = makeProject(sourceVideoPath: "/long/raw.mp4", duration: 1_800)
        long.clickEvents = (0..<1_000).map { ClickEvent(time: Double($0) * 1.7, x: 0.123_456, y: 0.654_321, button: .left) }
        long.typingActivity = (0..<1_000).map { TypingActivity(time: Double($0) * 1.3, x: 0.5, y: 0.5) }
        long.zoomSegments = (0..<500).map { ZoomSegment(start: Double($0) * 3.5, end: Double($0) * 3.5 + 1.25, targetX: 0.333_333, targetY: 0.666_666, scale: 1.75, kind: .automatic) }
        long.cursorSamples = (0..<50_000).map { CursorSample(time: Double($0) / 30, x: 0.5, y: 0.5) }
        long.chapters = (0..<12).map { DemoChapter(start: Double($0) * 100, end: Double($0) * 100 + 50, title: "Chapter \($0)", caption: String(repeating: "c", count: 60)) }
        app.projects.append(long)
        let longResult = try await GetProjectTool().run(arguments: ["project_id": long.id.uuidString], context: context, progress: { _ in })
        let longData = try structured(longResult, "get_project long")
        let bytes = try longData.jsonData().count + longResult.text.utf8.count
        check(longData["zoom_count"] == 500 && longData["zooms"]?.arrayValue?.count == AIProjectReport.maximumDataZooms && longData["clicks"]?["count"] == 1_000
              && longData["clicks"]?["items"]?.arrayValue?.count == 200 && longData["typing"]?.arrayValue?.count == 200 && longData["typing_count"] == 1_000, "long lists are capped with their totals")
        check(longData["clicks"]?["items"]?[0]?[0] == 0 && longData["clicks"]?["items"]?[199]?[0] == .rounded(999 * 1.7), "sampled clicks span the whole recording")
        // About 10k tokens at worst, well under Claude Code's 25k-token tool-output cap.
        check(bytes < 32_000, "get_project for a 30-minute recording stays small (\(bytes) bytes, cursor samples excluded)")

        // Chapters and texts nothing else limits (the editor, a set_chapters call) are capped too.
        let longIndex = app.projects.firstIndex { $0.id == long.id }!
        app.projects[longIndex].chapters = (0..<300).map { DemoChapter(start: Double($0) * 5, end: Double($0) * 5 + 4, title: "T\($0) " + String(repeating: "t", count: 1_000), caption: String(repeating: "c", count: 1_000)) }
        app.projects[longIndex].settings.productDescription = String(repeating: "d", count: 5_000)
        let wordyResult = try await GetProjectTool().run(arguments: ["project_id": long.id.uuidString], context: context, progress: { _ in })
        let wordy = try structured(wordyResult, "get_project wordy")
        let wordyChapters = wordy["chapters"]?.arrayValue ?? []
        let wordyBytes = try wordy.jsonData().count + wordyResult.text.utf8.count
        check(wordy["chapter_count"] == 300 && wordyChapters.count == AIProjectReport.maximumDataChapters && wordyChapters.last?["index"] == .number(Double(AIProjectReport.maximumDataChapters)), "chapters are capped with their total: \(wordy["chapter_count"] ?? .null), \(wordyChapters.count)")
        check(wordyChapters.allSatisfy { ($0["title"]?.stringValue?.count ?? .max) == AIProjectReport.maximumDataChapterText + 1 && $0["caption"]?.stringValue?.hasSuffix("…") == true && ($0["caption"]?.stringValue?.count ?? .max) == AIProjectReport.maximumDataChapterText + 1 }, "long chapter texts are shortened with …")
        let description = wordy["look"]?["productDescription"]?.stringValue ?? ""
        check(description.count == AIProjectReport.maximumDataText + 1 && description.hasSuffix("…"), "the product description is shortened like update_settings stores it: \(description.count)")
        check(wordyResult.text.contains("; and 288 more") && !wordyResult.text.contains(String(repeating: "c", count: AIProjectReport.maximumListedCaption + 1)), "the text lists 12 chapters with short captions")
        // Every list at its cap still fits well under the 25k-token cap.
        check(wordyBytes < 48_000, "get_project at every cap stays bounded (\(wordyBytes) bytes)")
    }

    // MARK: - get_status

    @MainActor
    static func getStatus(root: URL) async throws {
        let (context, app, _) = makeFakeApp(root: root)
        app.tracks = [AIMusicTrack(id: "calm-gradient", title: "Calm Gradient", mood: "Soft, airy pads", durationSeconds: 61.26, suggestedVolume: 0.17, path: "/bundle/calm.m4a")]
        app.permissions = AIPermissionStatus(screenRecording: false, accessibility: true, inputMonitoring: false)
        let project = makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 5)
        app.projects = [project, makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 6)]

        let idle = try await GetStatusTool().run(arguments: [:], context: context, progress: { _ in })
        let data = try structured(idle, "get_status")
        check(data["recording"] == ["state": "idle", "elapsed": nil, "remaining": nil, "error": nil] && data["open_project_id"] == .null && data["library_count"] == 2, "idle state: \(data)")
        check(data["permissions"] == ["screen_recording": false, "accessibility": true, "input_monitoring": false], "permissions: \(data["permissions"] ?? .null)")
        check(data["music_tracks"] == [["id": "calm-gradient", "title": "Calm Gradient", "mood": "Soft, airy pads", "duration": 61.3, "suggested_volume": 0.17]], "bundled music: \(data["music_tracks"] ?? .null)")
        check(data["app"]?["name"] == "Focus Studio" && data["app"]?["path"]?.stringValue?.isEmpty == false && data["app"]?["version"] != nil, "app identity (version from Bundle.main, null outside the app): \(data["app"] ?? .null)")
        check(idle.text.contains("Recording: idle") && idle.text.contains("Editor: closed") && idle.text.contains("Library: 2 projects")
              && idle.text.contains("Screen Recording missing") && idle.text.contains("System Settings") && idle.text.contains("Calm Gradient (calm-gradient)"), "text: \(idle.text)")

        try app.openProject(id: project.id)
        app.permissions.screenRecording = true
        app.recordingPhase = .recording
        app.elapsed = 12.34
        let recording = try structured(try await GetStatusTool().run(arguments: [:], context: context, progress: { _ in }), "get_status recording")
        check(recording["recording"] == ["state": "recording", "elapsed": 12.3, "remaining": nil, "error": nil] && recording["open_project_id"]?.stringValue == project.id.uuidString, "recording with elapsed time: \(recording)")
        app.recordingPhase = .countdown
        let countdown = try await GetStatusTool().run(arguments: [:], context: context, progress: { _ in })
        let countdownData = try structured(countdown, "get_status countdown")
        check(countdownData["recording"]?["state"] == "countdown" && countdown.text.contains("Screen Recording granted") && !countdown.text.contains("System Settings"), "countdown: \(countdown.text)")
        app.recordingPhase = .failed("The stream stopped")
        let failed = try structured(try await GetStatusTool().run(arguments: [:], context: context, progress: { _ in }), "get_status failed")
        check(failed["recording"] == ["state": "failed", "elapsed": nil, "remaining": nil, "error": "The stream stopped"], "failure message: \(failed)")
        app.recordingPhase = .idle
        await expectToolError("no app", { _ = try await GetStatusTool().run(arguments: [:], context: makeContext(root: root, box: ProjectBox(nil)), progress: { _ in }) }) { $0 == .appUnavailable }
    }

    // MARK: - Export options, progress and cancellation

    final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(completed: Double, total: Double?, message: String?)] = []
        var values: [(completed: Double, total: Double?, message: String?)] { lock.lock(); defer { lock.unlock() }; return entries }
        func record(_ completed: Double, _ total: Double?, _ message: String?) { lock.lock(); entries.append((completed, total, message)); lock.unlock() }
    }

    @MainActor
    static func exportOptions(root: URL) async throws {
        let fileManager = FileManager.default
        let media = root.appendingPathComponent("export-options", isDirectory: true)
        let cwd = media.appendingPathComponent("cwd", isDirectory: true)
        try fileManager.createDirectory(at: cwd, withIntermediateDirectories: true)
        let recording = media.appendingPathComponent("recording.mp4")
        try await SolidClipWriter.write(to: recording, width: 640, height: 360, duration: 1.5, color: (0.2, 0.5, 0.8), audio: true)
        let box = ProjectBox(makeProject(sourceVideoPath: recording.path, duration: 1.5))
        var context = makeContext(root: root, box: box)
        context.assetsDirectory = media.appendingPathComponent("ai", isDirectory: true)
        context.workingDirectory = cwd
        context.isExternal = true
        let measured = ProgressLog()
        context.numericProgress = { measured.record($0, $1, $2) }
        let texts = ToolLog()
        let before = box.project!.settings

        // Width and frame rate for this export only, into the working directory.
        let result = try await ExportProjectTool().run(arguments: ["path": "out/demo", "width": 1_280, "frame_rate": "24"], context: context, progress: { texts.record($0) })
        let output = cwd.appendingPathComponent("out/demo.mp4")
        let track = try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first!
        let (size, frameRate) = try await track.load(.naturalSize, .nominalFrameRate)
        check(size.width == 1_280 && abs(Double(frameRate) - 24) < 1, "the export uses the per-call width and frame rate: \(size), \(frameRate) fps")
        check(box.project!.settings == before && box.project!.settings.exportWidth == 1_920 && box.project!.settings.frameRate == 30 && box.writeCount == 0, "the project's own settings are not changed or saved")
        let data = try structured(result, "export_project")
        check(data["path"]?.stringValue == output.path && data["width"] == 1_280 && data["frame_rate"] == 24 && data["includes_audio"] == true
              && abs((data["duration"]?.doubleValue ?? 0) - 1.5) < 0.1 && (data["size_bytes"]?.intValue ?? 0) > 1_000 && data["project_id"]?.stringValue == box.project!.id.uuidString, "export data: \(data)")
        let values = measured.values
        check(values.count >= 2 && values.first?.completed == 0 && values.last?.completed == 1 && values.allSatisfy { $0.total == 1 }, "measured progress runs from 0 to 1 of 1: \(values.map(\.completed))")
        check(zip(values, values.dropFirst()).allSatisfy { $0.completed <= $1.completed }, "and never goes back")
        check(values.last?.message == "Exporting… 100%" && texts.runs.first == "Exporting…" && texts.runs.last == "Exporting… 100%", "text progress carries the percentage: \(texts.runs)")

        // The saved export settings apply when no per-call value is given.
        _ = try await ExportProjectTool().run(arguments: ["path": output.path, "overwrite": true, "frame_rate": 60], context: context, progress: { _ in })
        let (defaultSize, sixty) = try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first!.load(.naturalSize, .nominalFrameRate)
        check(defaultSize.width == 1_920 && abs(Double(sixty) - 60) < 1.5, "project width with a per-call frame rate: \(defaultSize), \(sixty) fps")
        for (name, arguments) in [("width not offered", ["width": 1_000] as [String: Any]), ("frame rate not offered", ["frame_rate": 25]), ("width word", ["width": "4k"]), ("huge width", ["width": 1e19])] {
            await expectToolError(name, { _ = try await ExportProjectTool().run(arguments: arguments.merging(["path": "rejected.mp4"]) { $1 }, context: context, progress: { _ in }) }) {
                if case let .invalidArgument(message) = $0 { return message.contains("must be one of") } else { return false }
            }
        }
        check(!fileManager.fileExists(atPath: cwd.appendingPathComponent("rejected.mp4").path), "rejected exports write nothing")
        let schema = ExportProjectTool().parametersSchema["properties"] as? [String: Any]
        check((schema?["width"] as? [String: Any])?["enum"] as? [Int] == UpdateSettingsTool.exportWidths && (schema?["frame_rate"] as? [String: Any])?["enum"] as? [Int] == UpdateSettingsTool.exportFrameRates, "the schema offers the editor's choices")

        // capture_frame reports the PNG it wrote.
        let frame = try await CaptureFrameTool().run(arguments: ["time": 0.5, "width": 800], context: context, progress: { _ in })
        let frameData = try structured(frame, "capture_frame")
        check(frameData["path"]?.stringValue == frame.attachments.first?.path && frameData["width"] == 800 && frameData["time"] == 0.5 && (frameData["size_bytes"]?.intValue ?? 0) > 0, "capture_frame data: \(frameData)")

        // Cancelling stops AVFoundation, leaves no partial file and surfaces as cancellation.
        let long = media.appendingPathComponent("long.mp4")
        try await SolidClipWriter.write(to: long, width: 640, height: 360, duration: 12, color: (0.8, 0.3, 0.2), audio: false)
        box.project = makeProject(sourceVideoPath: long.path, duration: 12)
        let cancelFolder = cwd.appendingPathComponent("cancelled", isDirectory: true)
        try fileManager.createDirectory(at: cancelFolder, withIntermediateDirectories: true)
        let started = ProgressLog()
        var cancelContext = context
        cancelContext.numericProgress = { started.record($0, $1, $2) }
        let frozen = cancelContext
        let export = Task { try await ExportProjectTool().run(arguments: ["path": "cancelled/long.mp4", "width": 3_840], context: frozen, progress: { _ in }) }
        try await waitUntil(timeout: 60, "the long export to make progress") { started.values.contains { $0.completed > 0 } }
        let cancelledAt = Date()
        export.cancel()
        switch await export.result {
        case .success:
            fatalError("FAIL: a cancelled export must not succeed")
        case let .failure(error):
            check(error is CancellationError, "cancellation propagates unwrapped, got \(error)")
        }
        check(Date().timeIntervalSince(cancelledAt) < 5, "the export stops promptly")
        let leftovers = try fileManager.contentsOfDirectory(atPath: cancelFolder.path)
        check(leftovers.isEmpty, "no output or partial file is left: \(leftovers)")
    }

    // MARK: - assemble_video output

    @MainActor
    static func assembleOutput(root: URL) async throws {
        let fileManager = FileManager.default
        let folder = root.appendingPathComponent("assemble-output", isDirectory: true)
        let cwd = folder.appendingPathComponent("cwd", isDirectory: true)
        let library = folder.appendingPathComponent("library", isDirectory: true)
        try fileManager.createDirectory(at: cwd.appendingPathComponent("clips", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
        let intro = cwd.appendingPathComponent("clips/intro.mp4")
        let outro = cwd.appendingPathComponent("clips/outro.mp4")
        try await SolidClipWriter.write(to: intro, width: 320, height: 180, duration: 1, color: (0.9, 0.2, 0.2), audio: false)
        try await SolidClipWriter.write(to: outro, width: 320, height: 180, duration: 1, color: (0.2, 0.2, 0.9), audio: false)
        let box = ProjectBox(nil)
        var context = makeContext(root: root, box: box)
        context.assetsDirectory = folder.appendingPathComponent("assets", isDirectory: true)
        context.workingDirectory = cwd
        context.isExternal = true
        context.projectsDirectory = library
        let measured = ProgressLog()
        context.numericProgress = { measured.record($0, $1, $2) }

        let result = try await AssembleVideoTool().run(arguments: ["clips": ["clips/intro.mp4", "clips/outro.mp4"], "output": "720p", "path": "joined"], context: context, progress: { _ in })
        let joined = cwd.appendingPathComponent("joined.mp4")
        let data = try structured(result, "assemble_video")
        check(fileManager.fileExists(atPath: joined.path) && result.attachments == [joined], "relative clips and path resolve in the working directory: \(result.text)")
        check(data["path"]?.stringValue == joined.path && data["width"] == 1_280 && data["height"] == 720 && data["clip_count"] == 2 && data["transition"] == "cut"
              && abs((data["duration"]?.doubleValue ?? 0) - 2) < 0.1 && data["clips"] == [AIJSONValue(intro), AIJSONValue(outro)], "assemble data: \(data)")
        check(measured.values.last?.completed == 1 && measured.values.first?.message == "Assembling 2 clips…", "assembly reports measured progress: \(measured.values.map(\.completed))")

        let introBytes = try Data(contentsOf: intro)
        func refusal(_ arguments: [String: Any], _ context: AIAssistantContext) async -> String {
            do {
                _ = try await AssembleVideoTool().run(arguments: (["clips": [intro.path]] as [String: Any]).merging(arguments) { $1 }, context: context, progress: { _ in })
                return "accepted"
            } catch { return error.localizedDescription }
        }
        let existing = await refusal(["path": "joined.mp4"], context)
        check(existing.contains("overwrite: true"), "an existing file needs overwrite: \(existing)")
        let replaced = await refusal(["path": "joined.mp4", "overwrite": true], context)
        check(replaced == "accepted", "overwrite: true replaces it: \(replaced)")
        let overClip = await refusal(["path": "clips/intro.mp4", "overwrite": true], context)
        check(overClip.contains("input of this call"), "a clip is never overwritten: \(overClip)")
        let inLibrary = await refusal(["path": library.appendingPathComponent("demo.mp4").path], context)
        check(inLibrary.contains("inside the Focus Studio library"), "the library is refused: \(inLibrary)")
        let badFlag = await refusal(["path": "bad", "overwrite": "maybe"], context)
        check(badFlag.contains("overwrite"), "overwrite must be a boolean: \(badFlag)")
        var noCWD = context
        noCWD.workingDirectory = nil
        let relative = await refusal(["path": "joined-again.mp4"], noCWD)
        check(relative.contains("absolute path"), "an external relative path needs a working directory: \(relative)")
        let introAfter = try Data(contentsOf: intro)
        check(introAfter == introBytes, "the clip survived")
        let byDefault = try await AssembleVideoTool().run(arguments: ["clips": [intro.path]], context: context, progress: { _ in })
        check(byDefault.attachments[0].deletingLastPathComponent().path == context.assetsDirectory.path && byDefault.attachments[0].lastPathComponent.hasPrefix("assembled-"), "no path still means the assets folder")
        check(AssembleVideoTool().parametersSchema.description.contains("overwrite") && (AssembleVideoTool().parametersSchema["required"] as? [String]) == ["clips"], "the schema offers path and overwrite; only clips is required")
    }
}
