import AppKit
import SwiftUI

/// Exercises actual SwiftUI/AppKit layout without showing or focusing a window.
/// In particular, review -> progress changes only the transcript viewport, not
/// its final message ID or text: the old onChange-only scroll logic missed it.
@MainActor
enum AssistantTranscriptScrollRegression {
    private final class Fixture: ObservableObject {
        @Published var count = 180
        @Published var footerHeight: CGFloat = 245
        @Published var expandedLastRow = false
        @Published var followRequest = UUID()
    }

    private struct Transcript: View {
        @ObservedObject var fixture: Fixture

        var body: some View {
            VStack(spacing: 0) {
                AssistantTranscriptScrollView(followRequest: fixture.followRequest) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<fixture.count, id: \.self) { index in
                            Text(String(repeating: "Message \(index). ", count: 1 + index % 11))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                            if index == fixture.count - 1, fixture.expandedLastRow {
                                Text(String(repeating: "Expanded receipt with additional result details. ", count: 45))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(12)
                }
                Color.clear.frame(height: fixture.footerHeight)
            }
            .animation(.easeInOut(duration: 0.18), value: fixture.footerHeight)
        }
    }

    static func run() async throws {
        _ = NSApplication.shared
        let fixture = Fixture()
        let host = NSHostingView(rootView: Transcript(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 630),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        let scroll = try transcriptScroll(in: host)
        try expectBottom(scroll, "Opening a long saved conversation must show the latest message")
        let originalHeight = scroll.contentView.bounds.height

        // Confirming a task replaces its large review card with compact live
        // progress. There is deliberately no message mutation in this step.
        fixture.footerHeight = 90
        fixture.followRequest = UUID()
        try await settle(host)
        precondition(scroll.contentView.bounds.height > originalHeight + 100)
        try expectBottom(scroll, "Review -> live progress must retain the latest message")

        // The reverse happens when a subsequent confirmation card appears.
        fixture.footerHeight = 290
        try await settle(host)
        try expectBottom(scroll, "A taller task card must keep the transcript at the bottom")

        fixture.count += 3
        try await settle(host)
        try expectBottom(scroll, "New variable-height receipts must remain visible")

        fixture.expandedLastRow = true
        try await settle(host)
        try expectBottom(scroll, "Changing the last receipt height must maintain the bottom anchor")

        window.setContentSize(NSSize(width: 590, height: 760))
        try await settle(host)
        try expectBottom(scroll, "Rewrapping history after window resize must preserve the bottom anchor")

        // Actual user intent is separate from layout movement: a user can read
        // history through any number of task or message updates, then opt in.
        var intent = AssistantTranscriptFollowState()
        intent.beginUserScroll()
        precondition(!intent.shouldAnchor)
        intent.endUserScroll(distanceFromBottom: 500)
        precondition(!intent.shouldAnchor)
        intent.requestLatest()
        precondition(intent.shouldAnchor)
        intent.beginUserScroll()
        intent.endUserScroll(distanceFromBottom: 12)
        precondition(intent.shouldAnchor)
        print("AssistantTranscriptScrollRegression: PASS (long history, review/live viewport changes, new/expanded receipts, resize, user follow intent)")
    }

    private static func settle(_ host: NSView) async throws {
        for _ in 0..<16 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        host.layoutSubtreeIfNeeded()
    }

    private static func transcriptScroll(in view: NSView) throws -> NSScrollView {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let result = try? transcriptScroll(in: child) { return result }
        }
        throw Failure(message: "The hosted transcript did not create its native scroll view")
    }

    private static func expectBottom(_ scroll: NSScrollView, _ message: String) throws {
        guard let document = scroll.documentView else { throw Failure(message: "Missing transcript document") }
        let visible = document.convert(scroll.contentView.bounds, from: scroll.contentView)
        let gap = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
        guard document.bounds.height > scroll.contentView.bounds.height, abs(gap) < 3 else {
            throw Failure(message: "\(message): bottom gap \(gap), content \(document.bounds.height), viewport \(scroll.contentView.bounds.height)")
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
