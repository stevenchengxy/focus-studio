import FocusStudioAutomation
import Foundation

@MainActor
enum RecordedTextInputRegression {
    static func run() async throws {
        let frame = CGRect(x: 100, y: 80, width: 1000, height: 700)
        let focused = RecordedTextInput.Focus(processID: 123, windowID: 42, windowFrame: frame,
            fieldFrame: CGRect(x: 200, y: 300, width: 500, height: 50),
            webFrame: CGRect(x: 100, y: 200, width: 1000, height: 580), browserID: "com.google.Chrome",
            editable: true, secure: false, element: nil, fixtureID: "input-one")
        let observed = RecordedTextInput.Observation(focus: focused)
        precondition(observed.paired(with: observed).focus != nil, "Stable screenshot-time field identities are usable")
        let timedOut = RecordedTextInput.Observation(failure: .rejected("page_ancestor_timeout"))
        precondition(timedOut.paired(with: observed).failure?.diagnosticCode == "page_ancestor_timeout"
                     && observed.paired(with: timedOut).failure?.diagnosticCode == "page_ancestor_timeout",
                     "Screenshot diagnostics retain AX failures from either side of capture")
        var switched = focused; switched.fixtureID = "different-input"
        let changed = observed.paired(with: .init(focus: switched))
        precondition(changed.focus == nil && changed.failure?.diagnosticCode == "focused_field_changed",
                     "A changed screenshot-time focus is distinguishable from an unsupported field")
        var outsidePage = focused; outsidePage.fieldFrame.origin.y = 100
        do {
            try RecordedTextInput.validate(outsidePage, targetID: 42, frame: frame)
            preconditionFailure("An address bar must remain rejected")
        } catch let error as RecordedTextInput.InputError {
            precondition(error.diagnosticCode == "field_outside_page", "AX bounds failures identify the exact rejected boundary")
        }
        var current = focused
        var chunks: [String] = [], reported = 0
        var activityPoints: [CGPoint] = []
        var ready = true
        let driver = RecordedTextInput.Driver(focus: { current }, post: { units, pid in
            precondition(pid == 123, "Text targets only the observed browser process")
            chunks.append(String(decoding: units, as: UTF16.self))
        }, wait: {})
        func type(_ text: String, driver: RecordedTextInput.Driver) async throws {
            try await RecordedTextInput.run(text: text, targetID: 42, frame: frame,
                observedFocus: focused,
                waitUntilReady: { if !ready { throw CancellationError() } },
                onCharacters: { reported += $0 }, onActivity: { activityPoints.append($0) }, driver: driver)
        }
        let text = "演示搜索 OpenAI 👩‍💻"
        try await type(text, driver: driver)
        precondition(chunks.joined() == text && reported == text.count, "Native dispatch preserves complete Unicode graphemes")
        precondition(activityPoints.count == chunks.count && activityPoints.allSatisfy { abs($0.x - 0.35) < 1e-9 && abs($0.y - 0.35) < 1e-9 },
                     "Each dispatched chunk produces only the normalized editable-field point, independent of cursor position")
        let originalChunks = chunks.count
        for invalid in ["", "\n", "hello\rworld", "query\tnew", "query\u{0}", "query\u{2028}submit", String(repeating: "x", count: 1001)] {
            try await refuses { try await type(invalid, driver: driver) }
        }
        precondition(chunks.count == originalChunks, "Invalid text never sends any key events")
        precondition(activityPoints.count == originalChunks, "Rejected text cannot create pacing evidence")
        var invalidFocuses: [RecordedTextInput.Focus] = []
        current = focused; current.secure = true; invalidFocuses.append(current)
        current = focused; current.webFrame = nil; invalidFocuses.append(current)
        current = focused; current.fieldFrame = CGRect(x: 200, y: 100, width: 500, height: 30); invalidFocuses.append(current)
        current = focused; current.windowID = 999; invalidFocuses.append(current)
        current = focused; current.windowFrame.origin.x += 1; invalidFocuses.append(current)
        current = focused; current.browserID = "com.apple.Terminal"; invalidFocuses.append(current)
        current = focused; current.editable = false; invalidFocuses.append(current)
        for invalid in invalidFocuses {
            current = invalid
            try await refuses { try await type("demo", driver: driver) }
        }
        precondition(chunks.count == originalChunks, "Password, address bar, other window and non-editable fields cannot receive text")

        current = focused; current.fixtureID = "changed-after-screenshot"
        try await refuses { try await type("demo", driver: driver) }
        precondition(chunks.count == originalChunks, "Changing focus after the screenshot must be rejected before the first Unicode block")

        current = focused; chunks = []; reported = 0; activityPoints = []
        var growing = driver
        growing.post = { units, _ in
            chunks.append(String(decoding: units, as: UTF16.self))
            current.fieldFrame.size.height += 10
        }
        try await type("abcdefgh", driver: growing)
        precondition(chunks.joined() == "abcdefgh" && reported == 8,
                     "An observed textarea can grow while typing as long as its identity and page/window stay the same")
        precondition(activityPoints.count == 2 && activityPoints[1].y > activityPoints[0].y,
                     "Typing focus follows the validated field layout without inventing pointer movement")

        current = focused; chunks = []; reported = 0; activityPoints = []
        var pausing = driver
        pausing.post = { units, _ in chunks.append(String(decoding: units, as: UTF16.self)); ready = false }
        try await refuses { try await type("abcdefgh", driver: pausing) }
        precondition(chunks == ["abcd"] && reported == 4, "Pause/stop gates prevent the remaining text from being sent")
        precondition(activityPoints.count == 1, "A paused partial input retains only its actually dispatched activity")
        ready = true; current = focused; chunks = []; reported = 0; activityPoints = []
        var changing = driver
        changing.post = { units, _ in
            chunks.append(String(decoding: units, as: UTF16.self))
            current.fixtureID = "different-input"
        }
        try await refuses { try await type("abcdefgh", driver: changing) }
        precondition(chunks == ["abcd"] && reported == 4, "Focus cannot jump to another field between Unicode chunks")
        precondition(activityPoints.count == 1, "The undispatched tail cannot create activity after focus changes")

        current = focused; chunks = []; reported = 0; activityPoints = []
        var cancelled: Task<Void, Error>?
        var cancelling = driver
        cancelling.post = { units, _ in chunks.append(String(decoding: units, as: UTF16.self)); cancelled?.cancel() }
        let cancellationDriver = cancelling
        cancelled = Task { try await type("abcdefgh", driver: cancellationDriver) }
        try await refuses { try await cancelled!.value }
        precondition(chunks == ["abcd"] && reported == 4, "Task cancellation releases the operation without sending remaining characters")
        precondition(activityPoints.count == 1, "Cancellation preserves the first posted chunk's timing evidence")
        current = focused; chunks = []; reported = 0; activityPoints = []
        var failing = driver
        failing.post = { _, _ in throw RecordedTextInput.InputError.unavailableEvent }
        try await refuses { try await type("demo", driver: failing) }
        precondition(activityPoints.isEmpty && reported == 0, "A failed native dispatch emits no typing timing or character receipt")
        print("RecordedTextInputRegression: PASS (Unicode, screenshot focus diagnostics, password/address-bar rejection, pause and cancellation)")
    }

    private static func refuses(_ body: () async throws -> Void) async throws {
        var refused = false
        do { try await body() } catch { refused = true }
        precondition(refused, "This input must be rejected without touching the desktop")
    }
}
