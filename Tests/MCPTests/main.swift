import FocusStudioAutomation
import Foundation
import MCP

/// Unit and in-process protocol coverage for focus-studio-mcp, compiled by
/// scripts/test-mcp.sh with the helper's sources (not its main.swift) and
/// linked against the objects of the helper's debug build:
/// - the catalog the helper lists: the exact v1 names (Tests/MCPTests/v1-tools.txt)
///   and conservative input schemas (one JSON type per property, only
///   keywords every client handles, ranges and defaults also in the
///   description, which is all Codex keeps of them);
/// - the SDK adapter's mapping: tools/list entries equal the catalog
///   descriptors, results shaped for the negotiated version and for clients
///   that show the model only structuredContent, JSON values both ways;
/// - identity (inside an app, also through a symlink), settings, the
///   progress relay and the M4 forwarder;
/// - the server over a scripted transport (ProtocolTests.swift);
/// - the app control channel's shared pieces (ControlChannelTests.swift);
/// - the helper's end of it, SocketAppForwarder, against an in-process fake
///   app and a scripted launcher (ForwarderTests.swift).
///
/// `--dump <file>` also writes the catalog as the helper should list it, for
/// the stdio client (mcp_client.py) to compare against.
@main
struct MCPTests {
    static func main() async throws {
        let arguments = CommandLine.arguments
        if arguments.contains(stdioProbeFlag) { stdioProbe() }
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let fixture = value(after: "--fixture") else { fatalError("usage: MCPTests --fixture v1-tools.txt [--dump catalog.json]") }

        step("catalog: v1 names"); try catalogNames(fixture: URL(fileURLWithPath: fixture))
        step("catalog: conservative schemas"); conservativeSchemas()
        step("adapter: tools/list entries"); try toolEntries()
        step("adapter: results by protocol version"); try resultMapping()
        step("adapter: JSON values"); try jsonValues()
        step("stdout isolation"); try stdioIsolation()
        step("identity and settings"); try identityAndSettings()
        step("progress relay"); await progressRelay()
        step("unreachable forwarder"); await unreachableForwarder()
        step("protocol: initialize and tools/list"); try await protocolHandshake()
        step("protocol: tools/call forwarding, roots, versions"); try await protocolForwarding()
        step("protocol: progress"); try await protocolProgress()
        step("protocol: cancellation"); try await protocolCancellation()
        step("protocol: unknown and withheld tools"); try await protocolUnknownTools()
        step("protocol: malformed calls and unknown arguments"); try await protocolMalformedCalls()
        step("protocol: arguments, results and tokens kept as sent"); try await protocolRawValues()
        step("protocol: batches refused"); try await protocolBatches()
        step("protocol: shutdown on end of input"); try await protocolShutdown()
        step("control channel: framing"); try controlFraming()
        step("control channel: messages and parameters"); try controlMessages()
        step("control channel: call replies"); try controlCallResults()
        step("control channel: socket location"); try controlSocketLocation()
        step("control channel: connections"); try await controlConnections()
        step("app forwarder: settings from the environment"); try forwarderSettings()
        step("app forwarder: calls, progress, quit mid-call, protocol, hello"); try await forwarderCalls()
        step("app forwarder: opening the app"); try await forwarderLaunch()
        step("app forwarder: cancellation and shutdown"); try await forwarderCancellation()
        step("app forwarder: a cancel never overtakes its call"); try await forwarderCancelOrder()
        if let dump = value(after: "--dump") { try dumpCatalog(to: URL(fileURLWithPath: dump)) }
        print("MCPTests: PASS (v1 catalog names, conservative schemas with ranges in descriptions, tools/list entries, results by protocol version and content, JSON values, stdout isolation, identity inside an app bundle and through symlinks, settings, progress relay, unreachable forwarder, protocol handshake, forwarding with cwd/client/version/roots, progress notifications, cancellation, unknown and withheld tools, malformed params -32602, unknown arguments refused, data-URL-like strings kept as sent, batches -32600, shutdown drain, control channel framing/messages/replies/socket location/connections and the optional elapsed time, app forwarder settings/calls (with the helper's own time, opening the app and a late hello included)/progress/quit mid-call/reconnect/protocol mismatch/hello refused or late/opening the app/cancellation/cancel after its call/shutdown)")
    }

    // MARK: - Helpers

    static func step(_ name: String) {
        print("MCPTests: \(name)")
        fflush(stdout)
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        guard condition() else { fatalError("FAIL: \(message)", file: file, line: line) }
    }

    /// Any Encodable as Focus Studio's JSON value, for comparisons.
    static func json<T: Encodable>(_ value: T) throws -> AIJSONValue {
        let data = try JSONEncoder().encode(value)
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let json = AIJSONValue(jsonObject: object) else { fatalError("FAIL: not JSON: \(String(decoding: data, as: UTF8.self))") }
        return json
    }

    // MARK: - Catalog

    static func fixtureNames(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func catalogNames(fixture: URL) throws {
        let names = MCPToolCatalog.v1.tools.map(\.name)
        let expected = try fixtureNames(fixture)
        check(names == expected, "the catalog lists exactly v1-tools.txt, in order: \(names)")
        check(Set(names).count == names.count, "tool names are unique")
        for withheld in MCPToolCatalog.withheldToolNames {
            check(!names.contains(withheld), "\(withheld) is withheld from MCP")
        }
        for name in names {
            check(name.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil, "\(name) is a portable tool name")
        }
    }

    /// Keywords every MCP client we target accepts (Claude Code, Codex, and
    /// the Gemini-style schema subset); a type union or `format` is not
    /// among them.
    static let schemaKeywords: Set<String> = ["type", "description", "properties", "required", "items", "enum", "minimum", "maximum", "minItems", "maxItems", "default"]
    static let schemaTypes: Set<String> = ["object", "array", "string", "number", "integer", "boolean"]

    /// Problems with `schema` at `path`; empty when it is conservative.
    static func schemaProblems(_ schema: AIJSONValue, path: String) -> [String] {
        guard let fields = schema.objectValue else { return ["\(path) is not an object"] }
        var problems = fields.keys.filter { !schemaKeywords.contains($0) }.sorted().map { "\(path) uses \($0)" }
        guard let type = fields["type"]?.stringValue, schemaTypes.contains(type) else {
            return problems + ["\(path) needs exactly one type, has \(fields["type"] ?? .null)"]
        }
        func matches(_ value: AIJSONValue) -> Bool {
            switch (type, value) {
            case ("string", .string), ("boolean", .bool), ("number", .number), ("array", .array), ("object", .object): return true
            case let ("integer", .number(number)): return number == number.rounded()
            default: return false
            }
        }
        if let options = fields["enum"] {
            if let values = options.arrayValue, !values.isEmpty, values.allSatisfy(matches) {} else { problems.append("\(path) enum must list \(type) values") }
        }
        if let value = fields["default"], !matches(value) { problems.append("\(path) default is not a \(type)") }
        for bound in ["minimum", "maximum"] where fields[bound] != nil {
            if !["number", "integer"].contains(type) || fields[bound]?.doubleValue == nil { problems.append("\(path) \(bound) needs a numeric type") }
        }
        for bound in ["minItems", "maxItems"] where fields[bound] != nil {
            if type != "array" || fields[bound]?.intValue == nil { problems.append("\(path) \(bound) needs an array") }
        }
        if fields["description"] != nil, fields["description"]?.stringValue == nil { problems.append("\(path) description is not text") }
        switch type {
        case "object":
            guard let properties = fields["properties"]?.objectValue else { return problems + ["\(path) object without properties"] }
            for (name, property) in properties.sorted(by: { $0.key < $1.key }) {
                problems += schemaProblems(property, path: "\(path).\(name)")
            }
            if let required = fields["required"] {
                let names = required.arrayValue?.compactMap(\.stringValue) ?? []
                if names.count != required.arrayValue?.count || Set(names).count != names.count || !names.allSatisfy({ properties[$0] != nil }) {
                    problems.append("\(path) required must name its properties once each")
                }
            }
        case "array":
            if let items = fields["items"] { problems += schemaProblems(items, path: "\(path)[]") } else { problems.append("\(path) array without items") }
        default:
            if fields["properties"] != nil || fields["items"] != nil || fields["required"] != nil { problems.append("\(path) \(type) with object or array keywords") }
        }
        return problems
    }

    /// A bound or default as a description would write it: 3, 0.35, -0.5, cut.
    static func schemaText(_ value: AIJSONValue) -> String {
        switch value {
        case let .number(number) where number == number.rounded() && abs(number) < 1e15: return String(Int(number))
        case let .number(number): return "\(number)"
        case let .string(text): return text
        case let .bool(flag): return "\(flag)"
        default: return "\(value)"
        }
    }

    /// Codex keeps only type, description, enum, items, properties and
    /// required of a schema: minimum, maximum and default must also be in
    /// the description, or its model sees a bare number.
    static func rangeDescriptionProblems(_ schema: AIJSONValue, path: String) -> [String] {
        guard let fields = schema.objectValue else { return [] }
        var problems: [String] = []
        let bounds = ["minimum", "maximum"].compactMap { fields[$0] }
        let defaultValue = fields["default"]
        if !bounds.isEmpty || defaultValue != nil {
            let description = fields["description"]?.stringValue ?? ""
            if description.isEmpty {
                problems.append("\(path) has a range or default but no description")
            } else {
                for bound in bounds where !description.contains(schemaText(bound)) {
                    problems.append("\(path) description does not state the bound \(schemaText(bound)): \(description)")
                }
                if let defaultValue, fields["type"] != "boolean", !description.contains(schemaText(defaultValue)) {
                    problems.append("\(path) description does not state the default \(schemaText(defaultValue)): \(description)")
                }
            }
        }
        for (name, property) in (fields["properties"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            problems += rangeDescriptionProblems(property, path: "\(path).\(name)")
        }
        if let items = fields["items"] { problems += rangeDescriptionProblems(items, path: "\(path)[]") }
        return problems
    }

    static func conservativeSchemas() {
        for spec in MCPToolCatalog.v1.tools {
            let problems = schemaProblems(spec.inputSchema, path: spec.name)
            check(problems.isEmpty, "\(spec.name) has a conservative schema: \(problems)")
            let ranges = rangeDescriptionProblems(spec.inputSchema, path: spec.name)
            check(ranges.isEmpty, "\(spec.name) states its ranges and defaults in words: \(ranges)")
            let required = spec.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            check(required.contains("project_id") == spec.requiresProjectID, "\(spec.name): project_id required \(spec.requiresProjectID)")
            check((spec.inputSchema["properties"]?["project_id"] != nil) == spec.acceptsProjectID, "\(spec.name): project_id offered \(spec.acceptsProjectID)")
        }
        // The in-app assistant shares these schemas (the withheld tools too):
        // none may use a type union.
        for tool in AIAssistantToolCatalog.standard {
            let schema = AIJSONValue(jsonObject: tool.parametersSchema) ?? .null
            let unions = typeUnions(schema, path: tool.name)
            check(unions.isEmpty, "\(tool.name) has one type per property: \(unions)")
        }
    }

    static func typeUnions(_ schema: AIJSONValue, path: String) -> [String] {
        switch schema {
        case let .object(fields):
            var found = fields["type"]?.arrayValue != nil ? [path] : []
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                found += typeUnions(value, path: "\(path).\(key)")
            }
            return found
        case let .array(items):
            return items.enumerated().flatMap { typeUnions($1, path: "\(path)[\($0)]") }
        default:
            return []
        }
    }

    // MARK: - Adapter mapping

    static func toolEntries() throws {
        let catalog = MCPToolCatalog.v1
        let tools = MCPServerHost.tools(from: catalog)
        check(tools.map(\.name) == catalog.tools.map(\.name), "one entry per catalog tool, in order")
        for (tool, spec) in zip(tools, catalog.tools) {
            let entry = try json(tool)
            check(entry == spec.descriptor, "\(spec.name)'s tools/list entry is its descriptor:\n\(entry)\nvs\n\(spec.descriptor)")
            check(tool.annotations.title == spec.title && tool.annotations.readOnlyHint == spec.annotations.readOnly, "\(spec.name) annotations")
        }
        // The schema keeps whole numbers whole: "minimum": 0, not 0.0.
        let wait = try JSONEncoder().encode(tools.first { $0.name == MCPToolCatalog.waitForJobName }!.inputSchema)
        check(String(decoding: wait, as: UTF8.self).contains("\"minimum\":0,") || String(decoding: wait, as: UTF8.self).contains("\"minimum\":0}"), "integers stay integers: \(String(decoding: wait, as: UTF8.self))")
    }

    static let sampleImage = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
    static let sampleResult = MCPToolCallResult(
        content: [.text("Captured frame at 2 s."), .image(data: sampleImage, mimeType: "image/jpeg")],
        structuredContent: ["path": "/tmp/frame.png", "time": 2, "size": ["width": 1920, "height": 1080]]
    )

    static func resultMapping() throws {
        let structured = sampleResult.structuredContent!
        let structuredText = String(decoding: try structured.jsonData(), as: UTF8.self)
        // A result with an image carries its data as a JSON text block at
        // every version: Codex drops every content block, the image
        // included, when structuredContent is present.
        for version in [nil, "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2099-01-01", "not-a-date", "2025-6-18"] as [String?] {
            let label = version ?? "nil"
            let presentation = MCPResultPresentation(sampleResult, protocolVersion: version)
            check(presentation.structuredContent == nil && presentation.content == sampleResult.content + [.text(structuredText)] && !presentation.isError, "\(label): an image result puts its data in a text block")
            let wire = try json(MCPServerHost.callToolResult(sampleResult, protocolVersion: version))
            check(wire["structuredContent"] == nil && wire["isError"] == false, "\(label): no structuredContent next to an image: \(wire)")
            let content = wire["content"]?.arrayValue ?? []
            check(content.count == 3 && content[0] == ["type": "text", "text": "Captured frame at 2 s."], "\(label): text first: \(content)")
            check(content[1] == ["type": "image", "data": AIJSONValue(sampleImage.base64EncodedString()), "mimeType": "image/jpeg"], "\(label): the image as base64: \(content)")
            let block = content[2]["text"]?.stringValue ?? ""
            check((try? JSONSerialization.jsonObject(with: Data(block.utf8))).flatMap(AIJSONValue.init(jsonObject:)) == structured, "\(label): the JSON block parses back to the data: \(block)")
        }
        // A text-only result: from 2025-06-18 its data goes in structuredContent
        // with the text as its summary (Claude Code and Codex show the model
        // structuredContent in place of the text blocks); before, a JSON block
        // without the summary follows the text.
        let textOnly = MCPToolCallResult(
            content: [.text("Removed every zoom (3). Automatic zooms return if the zoom style is regenerated.")],
            structuredContent: ["removed_count": 3, "remaining": 0]
        )
        let summarized: AIJSONValue = ["removed_count": 3, "remaining": 0, "summary": AIJSONValue(textOnly.text)]
        for version in ["2025-06-18", "2025-11-25", "2099-01-01"] {
            let presentation = MCPResultPresentation(textOnly, protocolVersion: version)
            check(presentation.content == textOnly.content && presentation.structuredContent == summarized, "\(version): structuredContent with the summary: \(presentation)")
            let wire = try json(MCPServerHost.callToolResult(textOnly, protocolVersion: version))
            check(wire["structuredContent"] == summarized && wire["content"]?.arrayValue?.count == 1, "\(version): on the wire: \(wire)")
        }
        let textOnlyJSON = String(decoding: try textOnly.structuredContent!.jsonData(), as: UTF8.self)
        for version in [nil, "2024-11-05", "2025-03-26"] as [String?] {
            let presentation = MCPResultPresentation(textOnly, protocolVersion: version)
            check(presentation.structuredContent == nil && presentation.content == textOnly.content + [.text(textOnlyJSON)], "\(version ?? "nil"): the JSON block, no summary: \(presentation)")
        }
        // Data with a summary of its own keeps it.
        let own = MCPToolCallResult(content: [.text("text")], structuredContent: ["summary": "its own"])
        check(MCPResultPresentation(own, protocolVersion: "2025-11-25").structuredContent == ["summary": "its own"], "a summary in the data is kept")
        // Failures: isError true, the text only, never an empty JSON block.
        let failure = MCPToolCallResult.failure("No project has the id 1.")
        for version in [nil, "2024-11-05", "2025-11-25"] as [String?] {
            let wire = try json(MCPServerHost.callToolResult(failure, protocolVersion: version))
            check(wire == ["content": [["type": "text", "text": "No project has the id 1."]], "isError": true], "\(version ?? "nil") failure: \(wire)")
        }
        // Structured data that is not an object is wrapped, as MCP requires.
        let scalar = MCPToolCallResult(content: [.text("3")], structuredContent: 3)
        let wrapped = try json(MCPServerHost.callToolResult(scalar, protocolVersion: "2025-06-18"))
        check(wrapped["structuredContent"] == ["value": 3, "summary": "3"], "scalar data is wrapped in an object: \(wrapped)")
    }

    static func jsonValues() throws {
        let value: AIJSONValue = ["int": 3, "fraction": 0.25, "negative": -7, "big": 1e20, "flag": true, "none": nil, "text": "héllo \"q\"", "list": [1, "two", [3.5]], "nested": ["k": ["deep": false]]]
        let sdk = MCP.Value(focusStudio: value)
        check(sdk.objectValue?["int"] == .int(3) && sdk.objectValue?["fraction"] == .double(0.25) && sdk.objectValue?["negative"] == .int(-7), "whole numbers become integers: \(sdk)")
        check(sdk.objectValue?["big"] == .double(1e20), "numbers beyond 2^53 stay doubles")
        check(AIJSONValue(mcp: sdk) == value, "round trip: \(AIJSONValue(mcp: sdk))")
        // The SDK decodes a data URL string as .data; a canonical base64 one
        // comes back as the same text. (tools/call params never take this
        // path; protocolRawValues covers the strings it would change.)
        let decoded = try JSONDecoder().decode([String: MCP.Value].self, from: Data(#"{"image":"data:image/png;base64,iVBORw0KGgo=","n":2,"x":2.5}"#.utf8))
        let arguments = decoded.mapValues(AIJSONValue.init(mcp:))
        check(arguments["image"] == "data:image/png;base64,iVBORw0KGgo=" && arguments["n"] == 2 && arguments["x"] == 2.5, "arguments convert back: \(arguments)")
        check(AIJSONValue(mcp: .double(.nan)) == .null, "a non-finite number becomes null")
    }

    // MARK: - Standard streams

    static let stdioProbeFlag = "--stdio-probe"
    static let probeProtocolLine = #"{"jsonrpc":"2.0","method":"probe"}"# + "\n"

    /// Run in a child process: isolates the streams as the helper's main
    /// does, writes stray output every usual way and one protocol line, and
    /// checks the descriptors' flags.
    static func stdioProbe() -> Never {
        guard let streams = try? HelperStandardStreams.isolateProtocolOutput() else { exit(2) }
        print("stray print")
        fflush(stdout)
        FileHandle.standardOutput.write(Data("stray FileHandle\n".utf8))
        _ = write(STDOUT_FILENO, "stray write\n", 12)
        _ = probeProtocolLine.withCString { write(streams.protocolOutput, $0, strlen($0)) }
        var action = sigaction()
        sigaction(SIGPIPE, nil, &action)
        guard let handler = action.__sigaction_u.__sa_handler,
              unsafeBitCast(handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self) else { exit(3) }
        guard streams.protocolOutput > STDERR_FILENO, fcntl(streams.protocolOutput, F_GETFD) & FD_CLOEXEC != 0 else { exit(4) }
        // restore() undoes the transport's non-blocking mode.
        let before = fcntl(streams.protocolOutput, F_GETFL)
        _ = fcntl(streams.protocolOutput, F_SETFL, before | O_NONBLOCK)
        _ = fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK)
        streams.restore()
        guard fcntl(streams.protocolOutput, F_GETFL) == before, fcntl(STDIN_FILENO, F_GETFL) & O_NONBLOCK == 0 else { exit(5) }
        exit(0)
    }

    static func stdioIsolation() throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        probe.arguments = [stdioProbeFlag]
        let output = Pipe(), errors = Pipe(), input = Pipe()
        probe.standardOutput = output
        probe.standardError = errors
        probe.standardInput = input
        try probe.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        check(probe.terminationStatus == 0, "the probe's descriptor checks pass (status \(probe.terminationStatus)); stderr: \(stderr)")
        check(String(decoding: stdout, as: UTF8.self) == probeProtocolLine, "stdout carries the protocol line only: \(String(decoding: stdout, as: UTF8.self))")
        for stray in ["stray print", "stray FileHandle", "stray write"] {
            check(stderr.contains(stray), "\(stray) goes to stderr: \(stderr)")
        }
    }

    // MARK: - Identity, settings, relay, forwarder

    static func identityAndSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MCPTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func makeBundle(_ name: String, identifier: String, version: String?) throws -> Bundle {
            let url = root.appendingPathComponent(name, isDirectory: true)
            let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "FocusStudio", "CFBundlePackageType": "APPL"]
            if let version { info["CFBundleShortVersionString"] = version }
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
            guard let bundle = Bundle(url: url) else { fatalError("FAIL: no bundle at \(url.path)") }
            return bundle
        }
        let app = try makeBundle("Focus Studio.app", identifier: HelperIdentity.appBundleIdentifier, version: "9.8.7")
        let identity = HelperIdentity.resolve(bundle: app)
        check(identity.version == "9.8.7" && identity.appURL?.lastPathComponent == "Focus Studio.app", "inside Focus Studio.app the helper reports its version: \(identity)")
        check(identity.name == "focus-studio" && identity.title == "Focus Studio", "server name and title")
        let other = HelperIdentity.resolve(bundle: try makeBundle("Other.app", identifier: "com.example.other", version: "2.0"))
        check(other.version == HelperIdentity.developmentVersion && other.appURL == nil, "another app's version is not reported: \(other)")
        let unversioned = HelperIdentity.resolve(bundle: try makeBundle("Bare.app", identifier: HelperIdentity.appBundleIdentifier, version: nil))
        check(unversioned.version == HelperIdentity.developmentVersion, "no version: the development version")
        // This test binary is no app: the development version.
        check(HelperIdentity.resolve().version == HelperIdentity.developmentVersion && HelperIdentity.resolve().appURL == nil, "outside an app: \(HelperIdentity.resolve())")
        // The app is found from the real executable path, so a symlink to the
        // helper still reports the app (test-mcp.sh runs one).
        let executable = HelperIdentity.realExecutableURL()
        check(executable?.lastPathComponent == URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent && executable.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true, "the real executable: \(executable?.path ?? "nil")")
        let helperPath = URL(fileURLWithPath: "/Applications/Focus Studio.app/Contents/MacOS/focus-studio-mcp")
        check(HelperIdentity.enclosingAppURL(of: helperPath)?.path == "/Applications/Focus Studio.app", "the app around Contents/MacOS")
        for elsewhere in ["/usr/local/bin/focus-studio-mcp", "/Applications/Focus Studio.app/Contents/Resources/focus-studio-mcp", "/tmp/Contents/MacOS/focus-studio-mcp"] {
            check(HelperIdentity.enclosingAppURL(of: URL(fileURLWithPath: elsewhere)) == nil, "no app around \(elsewhere)")
        }
        let pinned = URL(fileURLWithPath: "/private/tmp/Focus Studio.app")
        check(HelperIdentity.resolve(bundle: app, appURL: pinned).appURL == pinned, "the app's real path is kept")

        check(HelperSettings(environment: [:]).logLevel == .warning, "default log level: warning")
        check(HelperSettings(environment: ["FOCUS_STUDIO_MCP_LOG_LEVEL": "DEBUG"]).logLevel == .debug, "the log level is read case-insensitively")
        check(HelperSettings(environment: ["FOCUS_STUDIO_MCP_LOG_LEVEL": "loud"]).logLevel == .warning, "an unknown level falls back to warning")
        check(HelperLogLevel.allCases.allSatisfy { HelperLogLevel(name: "\($0)") == $0 }, "every level parses")
        check(MCPProtocolFeatures.isRevision("2025-06-18") && !MCPProtocolFeatures.isRevision("2025-06-1x") && !MCPProtocolFeatures.isRevision("latest"), "protocol revisions are dates")
    }

    final class Recorder<Element: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Element] = []
        var items: [Element] { lock.withLock { stored } }
        func append(_ item: Element) { lock.withLock { stored.append(item) } }
    }

    static func progressRelay() async {
        let sent = Recorder<Double>()
        let relay = OrderedProgressRelay { progress, _, _ in
            try? await Task.sleep(nanoseconds: 2_000_000)
            sent.append(progress)
        }
        let handler = relay.handler
        // Reports from many threads, some repeated or going backwards.
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            handler(Double(index % 50), 50, nil)
        }
        handler(.nan, nil, nil)
        handler(100, .infinity, "done")
        await relay.finish()
        let values = sent.items
        check(!values.isEmpty && zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "strictly increasing: \(values)")
        check(values.last == 100, "the last report is delivered: \(values)")
        handler(200, nil, nil)
        try? await Task.sleep(nanoseconds: 20_000_000)
        check(sent.items == values, "nothing is sent after finish")

        // Step by step, so coalescing cannot hide a repeat or a step back.
        let stepped = Recorder<Double>()
        let steps = OrderedProgressRelay { progress, _, _ in stepped.append(progress) }
        func settle(_ count: Int) async {
            for _ in 0..<200 where stepped.items.count < count { try? await Task.sleep(nanoseconds: 1_000_000) }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        steps.report(5, 10, nil)
        await settle(1)
        steps.report(5, 10, nil)
        steps.report(3, 10, nil)
        await settle(2)
        check(stepped.items == [5], "a repeated or smaller value is dropped: \(stepped.items)")
        steps.report(6, 10, nil)
        await steps.finish()
        check(stepped.items == [5, 6], "a larger one goes out: \(stepped.items)")
    }

    static func unreachableForwarder() async {
        let spec = MCPToolCatalog.v1.tool(named: "add_zoom")!
        let call = ForwardedToolCall(sequence: 1, tool: spec, arguments: [:], workingDirectory: URL(fileURLWithPath: "/tmp"), client: nil, protocolVersion: nil, progress: nil, roots: nil)
        guard case let .result(result) = await UnreachableAppForwarder().forward(call) else { fatalError("FAIL: the unreachable forwarder answers with a result") }
        check(result.isError && result.structuredContent == nil && result.text.contains("Focus Studio could not be reached") && result.text.contains("add_zoom"), "not reachable: \(result.text)")
    }

    // MARK: - Dump

    /// The catalog as the helper must list it, for mcp_client.py.
    static func dumpCatalog(to url: URL) throws {
        let catalog = MCPToolCatalog.v1
        let dump: AIJSONValue = [
            "instructions": AIJSONValue(MCPToolCatalog.instructions),
            "withheld": .array(MCPToolCatalog.withheldToolNames.map { AIJSONValue($0) }),
            "tools": .array(catalog.tools.map { spec in
                ["descriptor": spec.descriptor, "scope": AIJSONValue(spec.scope.rawValue), "requiresProjectID": AIJSONValue(spec.requiresProjectID), "acceptsProjectID": AIJSONValue(spec.acceptsProjectID)]
            }),
        ]
        try dump.jsonData(prettyPrinted: true).write(to: url)
    }
}
