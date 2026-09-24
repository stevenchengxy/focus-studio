import FocusStudioCore
import Foundation
import ImageIO

/// The MCP layer, transport independent: the exact v1 tool catalog (schemas
/// with project_id, annotations, descriptions, instructions), the result
/// shape with inline images, long calls as jobs (detach, wait_for_job,
/// progress, cancellation, retention) and the library tools (import,
/// screenshot demo, rename, delete) against the fake app.
extension AIAssistantTests {
    static let mcpV1ToolNames = [
        "get_status", "list_projects", "get_project", "rename_project", "delete_project", "import_video", "create_screenshot_demo",
        "list_recording_sources", "start_recording", "stop_recording", "add_zoom", "remove_zoom", "set_zoom_style", "update_settings",
        "set_chapters", "set_background_image", "set_background_music", "set_sound_effects", "capture_frame", "export_project",
        "assemble_video", "list_assets", "wait_for_job",
    ]

    /// A thread-safe flag for work that runs off the main actor.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
        func raise() { lock.lock(); raised = true; lock.unlock() }
    }

    static func callResult(_ outcome: AutomationCallResult, _ name: String) -> MCPToolCallResult {
        guard case let .result(result) = outcome else { fatalError("FAIL: \(name) returned \(outcome), expected a result") }
        return result
    }

    // MARK: - Catalog

    static func mcpCatalog() throws {
        let catalog = MCPToolCatalog.v1
        check(catalog.tools.map(\.name) == mcpV1ToolNames, "exactly the v1 tools, in order: \(catalog.tools.map(\.name))")
        let inApp = AIAssistantToolCatalog.standard
        let inAppNames = Set(inApp.map(\.name))
        for withheld in MCPToolCatalog.withheldToolNames {
            check(catalog.tool(named: withheld) == nil && inAppNames.contains(withheld), "\(withheld) stays in the app only")
        }
        // MCP-only tools do not leak into the in-app assistant.
        for mcpOnly in ["get_project", "get_status", "rename_project", "delete_project", "import_video", "create_screenshot_demo", "wait_for_job"] {
            check(!inAppNames.contains(mcpOnly), "\(mcpOnly) is not in the in-app catalog")
        }
        check(inApp.count == 23, "the in-app catalog keeps its 23 tools: \(inApp.count)")

        let scopes: [String: MCPToolScope] = [
            "get_status": .global, "list_projects": .global, "import_video": .global, "create_screenshot_demo": .global,
            "list_recording_sources": .global, "start_recording": .global, "stop_recording": .global, "wait_for_job": .global,
            "get_project": .projectReadOnly, "list_assets": .projectReadOnly, "assemble_video": .projectReadOnly,
            "rename_project": .library, "delete_project": .library,
            "add_zoom": .project, "remove_zoom": .project, "set_zoom_style": .project, "update_settings": .project, "set_chapters": .project,
            "set_background_image": .project, "set_background_music": .project, "set_sound_effects": .project, "capture_frame": .project,
            "export_project": .project,
        ]
        let readOnly: Set<String> = ["get_status", "list_projects", "get_project", "list_assets", "wait_for_job"]
        // Calls that make the app show something else run one at a time.
        let stayPut: Set<String> = ["get_status", "list_projects", "get_project", "list_assets", "assemble_video", "wait_for_job"]
        // Replacing an existing file (overwrite: true) is destructive too.
        let destructive: Set<String> = ["delete_project", "remove_zoom", "set_chapters", "update_settings", "set_zoom_style", "export_project", "assemble_video"]
        let idempotent: Set<String> = ["rename_project", "delete_project", "list_recording_sources", "set_zoom_style", "update_settings", "set_background_image", "set_background_music", "set_sound_effects"]
        for spec in catalog.tools {
            let name = spec.name
            check(spec.scope == scopes[name], "\(name) scope: \(spec.scope)")
            if name == MCPToolCatalog.waitForJobName {
                check(spec.tool == nil, "wait_for_job is answered by the job table")
            } else {
                check(spec.tool?.name == name, "\(name) runs its own tool")
                if let shared = inApp.first(where: { $0.name == name }) {
                    check(String(describing: type(of: spec.tool!)) == String(describing: type(of: shared)), "\(name) runs the in-app assistant's tool")
                }
            }
            check(!spec.title.isEmpty && spec.description.count > 60, "\(name) has a title and a description")
            check(!spec.description.contains("the open project") && !spec.description.contains("project summary"), "\(name)'s description is written for external callers: \(spec.description)")

            // Schemas: an object with properties; project_id for every project scope.
            let schema = spec.inputSchema
            check(schema["type"] == "object" && schema["properties"]?.objectValue != nil, "\(name) schema is an object")
            let required = schema["required"]?.arrayValue ?? []
            let projectID = schema["properties"]?["project_id"]
            if spec.scope == .global {
                check(projectID == nil && !required.contains("project_id") && !spec.acceptsProjectID && !spec.requiresProjectID, "\(name) takes no project_id")
            } else {
                check(projectID?["type"] == "string" && projectID?["format"] == nil && projectID?["description"]?.stringValue?.contains("list_projects") == true, "\(name) takes a project_id: \(projectID ?? .null)")
                let optional = ["list_assets", "assemble_video"].contains(name)
                check(spec.requiresProjectID == !optional && required.contains("project_id") == !optional, "\(name): project_id required \(!optional)")
            }
            check(Set(required.compactMap(\.stringValue)).count == required.count, "\(name): required has no duplicates")

            // Annotations.
            let annotations = spec.annotations
            check(annotations.readOnly == readOnly.contains(name), "\(name) readOnlyHint")
            check(annotations.destructive == destructive.contains(name), "\(name) destructiveHint")
            check(!annotations.openWorld, "\(name) stays on this Mac")
            if !annotations.readOnly { check(annotations.idempotent == idempotent.contains(name), "\(name) idempotentHint") }
            // Clients skip approval for read-only tools and run them in parallel.
            check(!(spec.navigates && annotations.readOnly), "\(name): a call that changes what Focus Studio shows is not readOnlyHint")
            if schema["properties"]?["overwrite"] != nil { check(annotations.destructive, "\(name) can replace a file, so it is destructive") }
            let json = spec.descriptor["annotations"]
            check(json?["title"]?.stringValue == spec.title && json?["readOnlyHint"] == AIJSONValue(annotations.readOnly) && json?["openWorldHint"] == false, "\(name) annotation JSON")
            // MCP defaults destructiveHint to true, so writers state it; readers omit it.
            check(annotations.readOnly ? json?["destructiveHint"] == nil : json?["destructiveHint"] == AIJSONValue(annotations.destructive), "\(name) destructiveHint is explicit for writers")
            check(spec.returnsImage == (name == "capture_frame"), "\(name) returnsImage")
            check(spec.navigates == !stayPut.contains(name), "\(name) navigates: \(spec.navigates)")
            check(spec.descriptor["name"]?.stringValue == name && spec.descriptor["inputSchema"] == schema && spec.descriptor["description"]?.stringValue == spec.description, "\(name) descriptor")
        }

        // Tool arguments survive the injection; paths are described for callers outside the app.
        let addZoom = catalog.tool(named: "add_zoom")!
        check(addZoom.inputSchema["required"] == ["project_id", "start", "end", "x", "y"], "add_zoom keeps its own required arguments: \(addZoom.inputSchema["required"] ?? .null)")
        check(addZoom.description.contains("top-left") && addZoom.description.contains("seconds"), "add_zoom explains coordinates and times")
        check(catalog.tool(named: "start_recording")!.inputSchema["required"] == ["source"], "start_recording requires only its source")
        check(catalog.tool(named: "get_project")!.inputSchema["required"] == ["project_id"], "get_project's own optional project_id becomes required")
        check(catalog.tool(named: "rename_project")!.inputSchema["required"] == ["project_id", "title"], "rename_project requires the id and the title")
        check(catalog.tool(named: "list_assets")!.inputSchema["required"] == nil, "list_assets requires nothing")
        check(catalog.tool(named: "wait_for_job")!.inputSchema["required"] == ["job_id"] && catalog.tool(named: "wait_for_job")!.inputSchema["properties"]?["timeout_seconds"]?["maximum"] == 240, "wait_for_job takes a job id and a bounded timeout")
        for (tool, property) in [("export_project", "path"), ("assemble_video", "path"), ("assemble_video", "clips"), ("set_background_image", "path"), ("import_video", "path"),
                                 ("create_screenshot_demo", "path"), ("set_background_music", "track"), ("update_settings", "backgroundImagePath")] {
            let text = catalog.tool(named: tool)!.inputSchema["properties"]?[property]?["description"]?.stringValue ?? ""
            check(text.contains("working directory"), "\(tool).\(property) explains relative paths: \(text)")
        }
        let exportSchema = catalog.tool(named: "export_project")!.inputSchema["properties"]
        check(exportSchema?["width"]?["enum"] == [1_280, 1_920, 2_560, 3_840] && exportSchema?["frame_rate"]?["enum"] == [24, 30, 60], "export_project offers the per-call width and frame rate")
        // The in-app assistant's schema is untouched by the injection.
        check((AddZoomTool().parametersSchema["properties"] as? [String: Any])?["project_id"] == nil, "the in-app schema has no project_id")

        // tools/list serializes, and stays compact.
        let listing = try catalog.descriptors.jsonData()
        let parsed = try JSONSerialization.jsonObject(with: listing)
        check((parsed as? [Any])?.count == mcpV1ToolNames.count && AIJSONValue(jsonObject: parsed) == catalog.descriptors, "the listing survives JSONSerialization")
        check(listing.count < 48_000, "the listing is compact: \(listing.count) bytes")

        // A custom catalog (tests, later tools) builds specs the same way.
        let custom = MCPToolSpec(tool: SetSoundEffectsTool(), title: "Effects", description: String(repeating: "x", count: 70), scope: .project, requiresProjectID: false, annotations: MCPToolAnnotations(readOnly: false))
        check(custom.inputSchema["required"] == nil && custom.inputSchema["properties"]?["project_id"] != nil, "an optional project_id is offered but not required")

        let instructions = MCPToolCatalog.instructions
        // Claude Code cuts server instructions at 2,048 UTF-16 units; the rule
        // about project.json must survive any cut.
        check(instructions.utf16.count <= 2_000, "the server instructions fit Claude Code's 2,048-character limit: \(instructions.utf16.count)")
        check(String(instructions.prefix(1_024)).contains("project.json"), "the project.json rule is near the top of the instructions")
        for phrase in ["list_recording_sources → start_recording", "stop_recording", "project_id", "top-left", "seconds", "working directory", "countdown",
                       "control bar", "editor", "in-app assistant", "wait_for_job", "overwrite", "project.json"] {
            check(instructions.contains(phrase), "the server instructions mention \(phrase)")
        }
    }

    // MARK: - Result shape

    @MainActor
    static func mcpResults(root: URL) throws {
        let folder = root.appendingPathComponent("mcp-results", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let plain = MCPToolCallResult(AIToolResult(text: "Done", data: ["project_id": "abc", "count": 2]))
        check(plain.content == [.text("Done")] && plain.structuredContent == ["project_id": "abc", "count": 2] && !plain.isError, "text and structured content")
        check(plain.json == ["content": [["type": "text", "text": "Done"]], "structuredContent": ["project_id": "abc", "count": 2], "isError": false], "MCP's CallToolResult shape: \(plain.json)")
        check(MCPToolCallResult(AIToolResult(text: "No data")).json == ["content": [["type": "text", "text": "No data"]], "isError": false], "no data, no structuredContent")
        check(MCPToolCallResult(content: [.text("x")], structuredContent: [1, 2]).structuredContent == ["value": [1, 2]], "structured content is always an object")
        let failed = MCPToolCallResult.failure(AIToolError.invalidArgument("\"x\" must be a number."))
        check(failed.isError && failed.text == "\"x\" must be a number." && failed.structuredContent == nil, "a tool error is an error result with its text")
        check(MCPToolCallResult.failure(AIToolError.noProject).text.contains("No recording is open"), "AIToolError texts are kept")
        check(MCPToolCallResult.failure(NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disk full"])).text == "Disk full", "other errors by their description")

        // capture_frame's PNG becomes an inline JPEG, at most 1568 pixels and 1 MiB of base64.
        /// A smooth gradient, or random noise that compresses badly.
        func png(_ name: String, width: Int, height: Int, noise: Bool) throws -> URL {
            var pixels = [UInt64](repeating: 0, count: width * height / 2)
            var generator = SystemRandomNumberGenerator()
            if noise { for index in pixels.indices { pixels[index] = generator.next() } }
            let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
                if !noise, let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1), CGColor(red: 0.9, green: 0.6, blue: 0.2, alpha: 1)] as CFArray, locations: nil) {
                    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
                }
                return context.makeImage()
            }
            let url = folder.appendingPathComponent(name)
            try AIToolSupport.writePNG(image!, to: url)
            return url
        }
        func inlineImage(_ result: MCPToolCallResult) -> (data: Data, width: Int, height: Int)? {
            guard result.content.count == 2, case let .image(data, mimeType) = result.content[1], mimeType == "image/jpeg",
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            return (data, width, height)
        }
        let wide = try png("wide.png", width: 3_000, height: 1_500, noise: false)
        let frame = MCPToolCallResult(AIToolResult(text: "Frame", attachments: [wide], data: ["path": AIJSONValue(wide)]), includesImage: true)
        guard let scaled = inlineImage(frame) else { fatalError("FAIL: capture_frame's PNG must become an inline JPEG: \(frame.content.count) blocks") }
        check(scaled.width == 1_568 && scaled.height == 784 && Array(scaled.data.prefix(3)) == [0xFF, 0xD8, 0xFF], "the frame is a JPEG scaled to 1568 px: \(scaled.width)×\(scaled.height)")
        check(frame.content[0] == .text("Frame") && frame.structuredContent?["path"]?.stringValue == wide.path, "text and data stay next to the image")
        let imageJSON = frame.json["content"]?[1]
        check(imageJSON?["type"] == "image" && imageJSON?["mimeType"] == "image/jpeg" && Data(base64Encoded: imageJSON?["data"]?.stringValue ?? "") == scaled.data, "the image block carries base64 data")

        let noisy = try png("noisy.png", width: 2_400, height: 1_600, noise: true)
        guard let capped = inlineImage(MCPToolCallResult(AIToolResult(text: "Noise", attachments: [noisy]), includesImage: true)) else { fatalError("FAIL: a noisy frame must still be inlined") }
        check(capped.data.base64EncodedString().utf8.count <= MCPToolCallResult.maximumImageBytes && max(capped.width, capped.height) <= 1_568,
              "a frame that compresses badly is shrunk under 1 MiB of base64: \(capped.data.count) bytes, \(capped.width)×\(capped.height)")
        let small = try png("small.png", width: 800, height: 450, noise: false)
        let unscaled = inlineImage(MCPToolCallResult(AIToolResult(text: "Small", attachments: [small]), includesImage: true))
        check(unscaled?.width == 800 && unscaled?.height == 450, "a small frame is not enlarged")
        check(MCPToolCallResult(AIToolResult(text: "No image", attachments: [wide])).content == [.text("No image")], "only tools that return images inline one")
        let missing = MCPToolCallResult(AIToolResult(text: "Gone", attachments: [folder.appendingPathComponent("gone.png")]), includesImage: true)
        check(missing.content == [.text("Gone")] && !missing.isError, "an unreadable image is left out; the text still names the file")
    }

    // MARK: - Jobs

    @MainActor
    static func automationJobs() async throws {
        // A call that finishes in time is answered directly and not stored.
        let quick = AutomationJobs(detachAfter: 5)
        let direct = callResult(await quick.run(tool: "quick", progress: nil) { _ in MCPToolCallResult(content: [.text("done")], structuredContent: ["ok": true]) }, "quick")
        check(direct.text == "done" && direct.structuredContent == ["ok": true] && quick.runningJobIDs.isEmpty, "a quick call returns its own result")
        let failing = callResult(await quick.run(tool: "failing", progress: nil) { _ in throw AIToolError.failed("It broke.") }, "failing")
        check(failing.isError && failing.text == "It broke.", "a thrown error becomes an error result")

        // A slow call is detached with a running status; wait_for_job collects it.
        let jobs = AutomationJobs(detachAfter: 0.3)
        let released = Flag()
        let firstReports = ProgressLog()
        let final = MCPToolCallResult(content: [.text("Exported demo.mp4")], structuredContent: ["path": "/tmp/demo.mp4", "duration": 12])
        let running = callResult(await jobs.run(tool: "export_project", clientName: "claude-code", progress: { firstReports.record($0, $1, $2) }) { report in
            report(0.1, 1, "Exporting… 10%")
            while !released.isRaised { try await Task.sleep(nanoseconds: 10_000_000) }
            // Leaves the waiter time to attach first.
            try await Task.sleep(nanoseconds: 50_000_000)
            report(0.05, 1, "backwards")
            report(0.6, 1, "Exporting… 60%")
            try await Task.sleep(nanoseconds: 50_000_000)
            report(1, 1, "Exporting… 100%")
            return final
        }, "slow run")
        let status = running.structuredContent
        guard let jobID = status?["job_id"]?.stringValue else { fatalError("FAIL: a detached call names its job: \(running.json)") }
        check(status?["status"] == "running" && status?["tool"] == "export_project" && (status?["elapsed"]?.doubleValue ?? 0) >= 0.3 && status?["progress"] == 0.1 && !running.isError,
              "the running status: \(status ?? .null)")
        check(running.text.contains("wait_for_job") && running.text.contains(jobID) && running.text.contains("10% done"), "the text says how to collect it: \(running.text)")
        check(jobs.runningJobIDs == [jobID], "the job keeps running")
        check(firstReports.values.map(\.completed) == [0.1], "the first call saw progress until it returned: \(firstReports.values.map(\.completed))")

        let polled = callResult(await jobs.waitForJob(arguments: ["job_id": jobID, "timeout_seconds": 0.05], progress: nil), "short wait")
        check(polled.structuredContent?["status"] == "running" && polled.structuredContent?["job_id"]?.stringValue == jobID, "a short wait reports it still running")
        let waitReports = ProgressLog()
        released.raise()
        let collected = callResult(await jobs.waitForJob(arguments: ["job_id": jobID.uppercased(), "timeout_seconds": "5"], progress: { waitReports.record($0, $1, $2) }), "long wait")
        check(collected == final, "wait_for_job returns the original call's result: \(collected.json)")
        let waited = waitReports.values.map(\.completed)
        check(waited.first == 0.1 && waited.last == 1 && zip(waited, waited.dropFirst()).allSatisfy { $0 < $1 } && !waited.contains(0.05), "the wait starts from the latest report and only moves forward: \(waited)")
        check(firstReports.values.count == 1, "nothing reaches the first call after it returned")
        let again = callResult(await jobs.waitForJob(arguments: ["job_id": jobID], progress: nil), "again")
        check(again == final && jobs.runningJobIDs.isEmpty, "the result is kept for another wait")

        for (arguments, expected) in [([:], "job_id"), (["job_id": "nope"], "No job has the id nope"), (["job_id": jobID, "timeout_seconds": 241], "timeout_seconds"),
                                      (["job_id": jobID, "timeout_seconds": "soon"], "timeout_seconds")] as [([String: Any], String)] {
            let refused = callResult(await jobs.waitForJob(arguments: arguments, progress: nil), "bad wait")
            check(refused.isError && refused.text.contains(expected), "wait_for_job explains \(expected): \(refused.text)")
        }

        // Time a call waited for its turn counts toward the threshold; a quick
        // call that waited still gets a short grace to answer directly.
        let queued = AutomationJobs(detachAfter: 0.5)
        let queuedAt = Date()
        let late = callResult(await queued.run(tool: "export_project", arrivedAt: Date().addingTimeInterval(-10), progress: nil) { _ in
            try await Task.sleep(nanoseconds: 300_000_000)
            return final
        }, "queued slow")
        check(late.structuredContent?["status"] == "running" && Date().timeIntervalSince(queuedAt) < 0.3, "a call that already waited out the threshold detaches at once: \(Date().timeIntervalSince(queuedAt)) s")
        let quickAfterWait = callResult(await queued.run(tool: "add_zoom", arrivedAt: Date().addingTimeInterval(-10), progress: nil) { _ in
            MCPToolCallResult(content: [.text("zoomed")])
        }, "queued quick")
        check(quickAfterWait.text == "zoomed", "a quick call that waited answers with its result: \(quickAfterWait.json)")
        let recent = callResult(await queued.run(tool: "add_zoom", arrivedAt: Date().addingTimeInterval(-0.1), progress: nil) { _ in
            try await Task.sleep(nanoseconds: 200_000_000)
            return MCPToolCallResult(content: [.text("zoomed later")])
        }, "queued briefly")
        check(recent.text == "zoomed later", "the rest of the threshold still applies: \(recent.json)")

        // Cancelling the caller before detaching cancels the work and waits for it.
        let stopped = Flag()
        let cancellable = Task { @MainActor in
            await AutomationJobs(detachAfter: 30).run(tool: "export_project", progress: nil) { _ in
                do {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                } catch {
                    stopped.raise()
                    throw error
                }
                return final
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelledAt = Date()
        cancellable.cancel()
        let cancelled = await cancellable.value
        check(cancelled == .cancelled && stopped.isRaised && Date().timeIntervalSince(cancelledAt) < 2, "a cancelled call cancels its work: \(cancelled)")

        // Cancelling a wait leaves the job running.
        let gate = Flag()
        let background = AutomationJobs(detachAfter: 0.05)
        let detached = callResult(await background.run(tool: "assemble_video", progress: nil) { _ in
            while !gate.isRaised { try await Task.sleep(nanoseconds: 10_000_000) }
            return MCPToolCallResult(content: [.text("Assembled")])
        }, "background")
        let backgroundID = detached.structuredContent!["job_id"]!.stringValue!
        let waiting = Task { @MainActor in await background.waitForJob(arguments: ["job_id": backgroundID, "timeout_seconds": 60], progress: nil) }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiting.cancel()
        let waitOutcome = await waiting.value
        check(waitOutcome == .cancelled && background.runningJobIDs == [backgroundID], "a cancelled wait only stops waiting")
        gate.raise()
        let afterWait = callResult(await background.waitForJob(arguments: ["job_id": backgroundID, "timeout_seconds": 5], progress: nil), "after wait")
        check(afterWait.text == "Assembled", "the job still finished")

        // Work cancelled by someone else is an error result, never a silent drop.
        let selfCancelled = callResult(await quick.run(tool: "export_project", progress: nil) { _ in throw CancellationError() }, "self-cancelled")
        check(selfCancelled.isError && selfCancelled.text.contains("cancelled before it finished"), "a cancellation the caller did not ask for is reported")

        // Finished results expire after the retention time and beyond the capacity.
        let bounded = AutomationJobs(detachAfter: 0, retention: 60, capacity: 1)
        var ids: [String] = []
        for index in 0..<2 {
            // The first finishes well before the second, whatever the timer coalescing.
            let delay: UInt64 = index == 0 ? 10_000_000 : 200_000_000
            let answer = callResult(await bounded.run(tool: "job-\(index)", progress: nil) { _ in
                try await Task.sleep(nanoseconds: delay)
                return MCPToolCallResult(content: [.text("job \(index)")])
            }, "bounded \(index)")
            ids.append(answer.structuredContent!["job_id"]!.stringValue!)
        }
        try await waitUntil("both bounded jobs to finish") { bounded.runningJobIDs.isEmpty }
        let oldest = callResult(await bounded.waitForJob(arguments: ["job_id": ids[0], "timeout_seconds": 0], progress: nil), "oldest")
        let newest = callResult(await bounded.waitForJob(arguments: ["job_id": ids[1], "timeout_seconds": 0], progress: nil), "newest")
        check(oldest.isError && newest.text == "job 1", "beyond the capacity the oldest result is dropped, the newest kept: \(oldest.text) / \(newest.text)")
        let shortLived = AutomationJobs(detachAfter: 0, retention: 0.2)
        let expiring = callResult(await shortLived.run(tool: "export_project", progress: nil) { _ in
            try await Task.sleep(nanoseconds: 20_000_000)
            return final
        }, "expiring").structuredContent!["job_id"]!.stringValue!
        try await waitUntil("the expiring job to finish") { shortLived.runningJobIDs.isEmpty }
        try await Task.sleep(nanoseconds: 300_000_000)
        let expired = callResult(await shortLived.waitForJob(arguments: ["job_id": expiring], progress: nil), "expired")
        check(expired.isError && expired.text.contains("No job has the id"), "a result expires after the retention time: \(expired.text)")
    }

    // MARK: - One call at a time

    @MainActor
    static func callQueue() async throws {
        let queue = AutomationCallQueue()
        let first = await queue.acquire()
        check(first && queue.waitingCount == 0, "the first caller goes at once")
        let order = ToolLog()
        var callers: [Task<Void, Never>] = []
        for name in ["a", "b", "c"] {
            callers.append(Task { @MainActor in
                guard await queue.acquire() else { order.record("\(name) cancelled"); return }
                order.record(name)
                try? await Task.sleep(nanoseconds: 10_000_000)
                queue.release()
            })
            // Arrive in this order.
            try await waitUntil("caller \(name) to queue") { queue.waitingCount == callers.count }
        }
        check(order.runs.isEmpty, "later callers wait for the turn")
        callers[1].cancel()
        try await waitUntil("the cancelled caller to leave") { queue.waitingCount == 2 && order.runs == ["b cancelled"] }
        queue.release()
        for caller in callers { await caller.value }
        check(order.runs == ["b cancelled", "a", "c"], "turns go in arrival order; a cancelled caller leaves without one: \(order.runs)")
        let free = await queue.acquire()
        check(free && queue.waitingCount == 0, "after the last turn the queue is free")
        queue.release()
    }

    // MARK: - Library tools

    @MainActor
    static func libraryTools(root: URL) async throws {
        let fileManager = FileManager.default
        let (fakeContext, app, box) = makeFakeApp(root: root)
        let cwd = root.appendingPathComponent("library-cwd", isDirectory: true)
        try fileManager.createDirectory(at: cwd.appendingPathComponent("clips", isDirectory: true), withIntermediateDirectories: true)
        var context = fakeContext
        context.workingDirectory = cwd
        context.isExternal = true
        var chinese = context
        chinese.uiLanguage = "zh-Hans"
        let clip = cwd.appendingPathComponent("clips/launch.mov")
        try Data("movie".utf8).write(to: clip)
        try Data("notes".utf8).write(to: cwd.appendingPathComponent("notes.txt"))
        let existing = makeProject(sourceVideoPath: "/nonexistent.mp4", duration: 6)
        app.projects = [existing]
        try app.openProject(id: existing.id)

        // import_video: a working-directory path, opened like Import video.
        let imported = try await ImportVideoTool().run(arguments: ["path": "clips/launch.mov"], context: context, progress: { _ in })
        let importedData = try structured(imported, "import_video")
        let newID = app.projects[0].id
        check(app.imported == [clip] && app.openID == newID && app.closeCount == 1, "the file is imported and opened, the other project closed first")
        check(importedData["project_id"]?.stringValue == newID.uuidString && importedData["title"] == "launch" && importedData["open_in_editor"] == true
              && importedData["source"]?.stringValue == clip.path && importedData["duration"] == 8, "import data: \(importedData)")
        check(imported.text.hasPrefix("Imported \"launch\" as project \(newID.uuidString)") && imported.text.contains("open in the editor"), "import text: \(imported.text)")
        _ = try await ImportVideoTool().run(arguments: ["path": clip.path, "title": "  Launch demo "], context: context, progress: { _ in })
        check(app.projects[0].title == "Launch demo", "an explicit title is trimmed and used")
        for (arguments, expected) in [(["path": "notes.txt"], "not a video file"), (["path": "missing.mp4"], "File not found"), (["path": "clips/launch.mov", "title": "   "], "title"), ([:], "path")] as [([String: Any], String)] {
            await expectToolError("import_video \(arguments)", { _ = try await ImportVideoTool().run(arguments: arguments, context: context, progress: { _ in }) }) {
                $0.localizedDescription.contains(expected)
            }
        }
        // The app's own reasons come back in the call's language.
        app.libraryFailure = AILocalizedFailure("Focus Studio is busy. Try again when the current task finishes.")
        await expectToolError("busy app, English", { _ = try await ImportVideoTool().run(arguments: ["path": "clips/launch.mov"], context: context, progress: { _ in }) }) {
            $0 == .failed("Focus Studio is busy. Try again when the current task finishes.")
        }
        app.libraryFailure = AILocalizedFailure("Focus Studio is busy. Try again when the current task finishes.")
        await expectToolError("busy app, Chinese", { _ = try await ImportVideoTool().run(arguments: ["path": "clips/launch.mov"], context: chinese, progress: { _ in }) }) {
            $0 == .failed("Focus Studio 正忙。请在当前任务完成后重试。")
        }

        // create_screenshot_demo: PNG or JPEG only, readable.
        let jpeg = cwd.appendingPathComponent("shot.jpg")
        try Pixels.writeJPEG(width: 16, height: 9, color: (0.2, 0.3, 0.4), to: jpeg)
        let png = cwd.appendingPathComponent("shot.png")
        _ = try ArkMediaClient.writePNG(from: jpeg, to: png)
        let demo = try structured(try await CreateScreenshotDemoTool().run(arguments: ["path": "shot.png"], context: context, progress: { _ in }), "create_screenshot_demo")
        check(demo["title"] == "shot Demo" && demo["duration"] == 12 && demo["source"]?.stringValue == png.path && app.imported.last == png, "a screenshot demo: \(demo)")
        _ = try await CreateScreenshotDemoTool().run(arguments: ["path": jpeg.path, "title": "Checkout"], context: context, progress: { _ in })
        check(app.projects[0].title == "Checkout", "JPEG and an explicit title")
        try Data("GIF89a".utf8).write(to: cwd.appendingPathComponent("shot.gif"))
        try Data("not an image".utf8).write(to: cwd.appendingPathComponent("fake.png"))
        for (path, expected) in [("shot.gif", "not a PNG or JPEG"), ("fake.png", "not a readable image"), ("clips/launch.mov", "not a PNG or JPEG")] {
            await expectToolError("create_screenshot_demo \(path)", { _ = try await CreateScreenshotDemoTool().run(arguments: ["path": path], context: context, progress: { _ in }) }) {
                $0.localizedDescription.contains(expected)
            }
        }

        // rename_project: by its argument or the pinned id, never the open project by default.
        let target = app.projects.first { $0.title == "launch" }!
        let renamed = try structured(try await RenameProjectTool().run(arguments: ["project_id": target.id.uuidString, "title": "Launch v2"], context: context, progress: { _ in }), "rename_project")
        check(app.projects.first { $0.id == target.id }?.title == "Launch v2" && app.openID == nil, "renamed, and the library shows")
        check(renamed == ["project_id": AIJSONValue(target.id.uuidString), "title": "Launch v2", "previous_title": "launch", "closed_editor": true], "rename data: \(renamed)")
        var pinned = context
        pinned.projectID = target.id
        let pinnedRename = try await RenameProjectTool().run(arguments: ["title": "Launch v3"], context: pinned, progress: { _ in })
        check(pinnedRename.text.contains("\"Launch v2\" to \"Launch v3\"") && !pinnedRename.text.contains("editor"), "a pinned call renames its project: \(pinnedRename.text)")
        try app.openProject(id: existing.id)
        await expectToolError("no project id", { _ = try await RenameProjectTool().run(arguments: ["title": "Wrong"], context: context, progress: { _ in }) }) {
            $0.localizedDescription.contains("project_id")
        }
        check(app.projects.first { $0.id == existing.id }?.title != "Wrong", "the open project is never renamed by default")
        await expectToolError("no title", { _ = try await RenameProjectTool().run(arguments: [:], context: pinned, progress: { _ in }) }) { $0.localizedDescription.contains("\"title\"") }
        await expectToolError("unknown id", { _ = try await RenameProjectTool().run(arguments: ["project_id": UUID().uuidString, "title": "X"], context: context, progress: { _ in }) }) {
            $0.localizedDescription.contains("list_projects")
        }
        await expectToolError("blank title in English", { _ = try await RenameProjectTool().run(arguments: ["title": " "], context: pinned, progress: { _ in }) }) {
            $0 == .failed("Project “Launch v3” could not be renamed: Please enter a project name.")
        }
        var pinnedChinese = pinned
        pinnedChinese.uiLanguage = "zh-Hans"
        await expectToolError("blank title in Chinese", { _ = try await RenameProjectTool().run(arguments: ["title": " "], context: pinnedChinese, progress: { _ in }) }) {
            $0 == .failed("无法重命名项目“Launch v3”：请输入项目名称。")
        }

        // delete_project: to the Trash, reporting that the editor was closed first.
        try app.openProject(id: target.id)
        let count = app.projects.count
        let deleted = try await DeleteProjectTool().run(arguments: ["project_id": target.id.uuidString], context: context, progress: { _ in })
        let deletedData = try structured(deleted, "delete_project")
        check(app.trashed == [target.id] && app.projects.count == count - 1 && app.openID == nil, "moved to the Trash")
        check(deletedData == ["project_id": AIJSONValue(target.id.uuidString), "title": "Launch v3", "moved_to_trash": true, "closed_editor": true, "library_count": AIJSONValue(count - 1)], "delete data: \(deletedData)")
        check(deleted.text.contains("to the Trash") && deleted.text.contains("It was open in the editor"), "delete text: \(deleted.text)")
        await expectToolError("deleted twice", { _ = try await DeleteProjectTool().run(arguments: ["project_id": target.id.uuidString], context: context, progress: { _ in }) }) {
            $0.localizedDescription.contains("Trash already")
        }
        app.libraryFailure = AILocalizedFailure("“%@”: %@", .verbatim("Checkout"), .text("The project could not be moved to Trash. Its files were kept."))
        let checkout = app.projects.first { $0.title == "Checkout" }!
        await expectToolError("trash failure", { _ = try await DeleteProjectTool().run(arguments: ["project_id": checkout.id.uuidString], context: context, progress: { _ in }) }) {
            $0 == .failed("“Checkout”: The project could not be moved to Trash. Its files were kept.")
        }
        check(app.projects.contains { $0.id == checkout.id }, "a failed move keeps the project")
        await expectToolError("no app", { _ = try await DeleteProjectTool().run(arguments: ["project_id": checkout.id.uuidString], context: makeContext(root: root, box: box), progress: { _ in }) }) {
            $0 == .appUnavailable
        }

        // The failure type itself: the call's language, or the app's.
        let failure = AILocalizedFailure("Moved %lld of %lld selected projects to Trash. The remaining projects were kept.\n%@", .count(1), .count(2), .verbatim("“Demo”"))
        check(failure.message(in: .english) == "Moved 1 of 2 selected projects to Trash. The remaining projects were kept.\n“Demo”", "English: \(failure.message(in: .english))")
        check(failure.message(in: .simplifiedChinese).contains("“Demo”") && failure.message(in: .simplifiedChinese) != failure.message(in: .english), "Chinese: \(failure.message(in: .simplifiedChinese))")
        await withAppLanguage("zh-Hans") {
            check(failure.localizedDescription == failure.message(in: .simplifiedChinese), "the app shows it in its own language")
        }
    }

    // MARK: - assemble_video pinned to a project

    /// A call pinned to a project that is not open writes into that
    /// project's assets folder, which the output guard allows.
    @MainActor
    static func assemblePinned(root: URL) async throws {
        let fileManager = FileManager.default
        let (fakeContext, app, _) = makeFakeApp(root: root)
        app.library = root.appendingPathComponent("pinned-library", isDirectory: true)
        let project = makeProject(sourceVideoPath: "raw.mp4", duration: 4)
        let other = makeProject(sourceVideoPath: "raw.mp4", duration: 4)
        app.projects = [project, other]
        try app.openProject(id: other.id)
        let clip = root.appendingPathComponent("pinned-clip.mp4")
        try await SolidClipWriter.write(to: clip, width: 160, height: 90, duration: 0.5, color: (0.5, 0.5, 0.5), audio: false)
        var context = fakeContext
        context.projectsDirectory = app.library
        context.projectID = project.id
        context.isExternal = true
        let assets = app.library.appendingPathComponent("\(project.id.uuidString)/ai", isDirectory: true)
        context.assetsDirectory = assets
        let result = try await AssembleVideoTool().run(arguments: ["clips": [clip.path], "output": "720p"], context: context, progress: { _ in })
        check(result.attachments.first?.deletingLastPathComponent().path == assets.path && fileManager.fileExists(atPath: result.attachments[0].path),
              "the pinned project's assets folder is the default and allowed: \(result.attachments)")
        let elsewhere = app.library.appendingPathComponent("\(other.id.uuidString)/ai/joined.mp4").path
        await expectToolError("another project's folder", { _ = try await AssembleVideoTool().run(arguments: ["clips": [clip.path], "path": elsewhere], context: context, progress: { _ in }) }) {
            $0.localizedDescription.contains("inside the Focus Studio library")
        }
        check(app.openID == other.id, "nothing was opened")
    }
}
