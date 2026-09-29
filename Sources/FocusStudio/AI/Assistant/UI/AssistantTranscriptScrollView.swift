import SwiftUI
import FocusStudioAutomation

/// A conversation follows new content until the user deliberately scrolls away.
/// Layout changes (for example, replacing the review card with live progress)
/// must not be mistaken for that user intent.
struct AssistantTranscriptFollowState {
    private(set) var followsLatest = true
    private(set) var userIsScrolling = false

    var shouldAnchor: Bool { followsLatest && !userIsScrolling }

    mutating func beginUserScroll() {
        userIsScrolling = true
        followsLatest = false
    }

    mutating func endUserScroll(distanceFromBottom: CGFloat) {
        userIsScrolling = false
        followsLatest = distanceFromBottom <= 40
    }

    mutating func requestLatest() {
        userIsScrolling = false
        followsLatest = true
    }
}

/// Uses the real scroll geometry, rather than an estimated lazy-row location.
/// Corrections run after layout and without inheriting the task-card animation.
struct AssistantTranscriptScrollView<Content: View>: View {
    let followRequest: UUID
    let content: Content

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var follow = AssistantTranscriptFollowState()
    @State private var anchorRevision = 0
    @State private var distanceFromBottom: CGFloat = 0

    init(followRequest: UUID, @ViewBuilder content: () -> Content) {
        self.followRequest = followRequest
        self.content = content()
    }

    private struct Geometry: Equatable {
        let contentHeight: CGFloat
        let viewportHeight: CGFloat
        let distanceFromBottom: CGFloat

        init(_ geometry: ScrollGeometry) {
            contentHeight = geometry.contentSize.height
            viewportHeight = geometry.containerSize.height
            distanceFromBottom = max(0, contentHeight + geometry.contentInsets.bottom - geometry.visibleRect.maxY)
        }
    }

    var body: some View {
        ScrollView {
            content
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(follow.shouldAnchor ? .bottom : nil, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .onScrollGeometryChange(for: Geometry.self, of: Geometry.init) { _, geometry in
            distanceFromBottom = geometry.distanceFromBottom
            if follow.shouldAnchor, geometry.viewportHeight > 0, geometry.distanceFromBottom > 1 {
                anchorRevision &+= 1
            }
        }
        .onScrollPhaseChange { oldPhase, newPhase, context in
            switch newPhase {
            case .tracking, .interacting, .decelerating:
                follow.beginUserScroll()
            case .idle where oldPhase != .animating:
                if follow.userIsScrolling {
                    follow.endUserScroll(distanceFromBottom: Geometry(context.geometry).distanceFromBottom)
                    if follow.shouldAnchor { anchorRevision &+= 1 }
                }
            default:
                break
            }
        }
        .onAppear { requestLatest() }
        .onChange(of: followRequest) { _, _ in requestLatest() }
        .task(id: anchorRevision) {
            // Let the new content and the surrounding task card lay out first.
            await Task.yield()
            guard !Task.isCancelled, follow.shouldAnchor else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottomTrailing) {
            if !follow.followsLatest, distanceFromBottom > 40 {
                Button(action: requestLatest) {
                    Label(L10n.tr("Latest messages"), systemImage: "arrow.down")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .background(.regularMaterial, in: Capsule())
                .clipShape(Capsule())
                .padding(10)
                .accessibilityIdentifier("assistant.latestMessages")
            }
        }
        .transaction { $0.animation = nil }
    }

    private func requestLatest() {
        follow.requestLatest()
        anchorRevision &+= 1
    }
}
