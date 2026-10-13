import AVFoundation
import AVKit
import FocusStudioCore
import SwiftUI

struct ProjectPreviewView: View {
    let project: RecordingProject
    let playbackClock: EditorPlaybackClock
    @Binding var isPlaying: Bool
    var seekRevision: Int
    @Binding var renderError: String?
    @State private var isSeeking = false
    @State private var pendingSeekTime: Double?
    @State private var seekTask: Task<Void, Never>?
    @State private var seekTaskGeneration = UUID()

    @State private var player = AVPlayer()
    @State private var isLoading = true
    @State private var observerToken: Any?
    @State private var isVisible = false
    @State private var renderGeneration = UUID()
    @State private var playbackDuration = 0.0

    var body: some View {
        let _ = EditorPlaybackMetrics.record("preview.body")
        ZStack {
            Color.black.opacity(0.35)
            PlayerView(player: player)

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Rendering preview…")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: player.currentItem == nil ? .center : .topTrailing)
                .padding(12)
            }

            if let renderError {
                VStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                    Text(renderError)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .padding(18)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .aspectRatio(previewRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
        // A name change or a media-library import does not alter visible
        // frames. Rebuilding the AV composition for either makes the editor
        // appear to pause while the person is still arranging their project.
        .task(id: renderKey) {
            let generation = UUID()
            renderGeneration = generation
            isLoading = true
            renderError = nil
            do {
                // Inspector sliders can emit dozens of values per second. A short
                // debounce keeps preview changes fluid instead of rebuilding an
                // AVVideoComposition for every intermediate drag position.
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                let item = try await ProjectVideoRenderer.makePlayerItem(project: project)
                guard !Task.isCancelled, isVisible, renderGeneration == generation else { return }
                player.replaceCurrentItem(with: item)
                // A composition rebuild follows every clip/audio/transition
                // edit. The default seek tolerance can land on a nearby key
                // frame and silently move the editor playhead by ~0.2 s.
                // Keep the requested output-frame position across rebuilds.
                await player.seek(
                    to: CMTime(seconds: playbackClock.time, preferredTimescale: 60_000),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                guard !Task.isCancelled, isVisible, renderGeneration == generation else { return }
            } catch is CancellationError {
                return
            } catch {
                guard isVisible, renderGeneration == generation else { return }
                renderError = error.localizedDescription
            }
            if isVisible, renderGeneration == generation {
                isLoading = false
                reconcilePlayback()
            }
        }
        .onAppear {
            isVisible = true
            playbackDuration = project.duration
            installTimeObserver()
        }
        .onChange(of: project.duration) { _, duration in
            // The long-lived observer must use the edited output duration,
            // rather than the project value captured when the editor opened.
            playbackDuration = duration
        }
        .onDisappear {
            isVisible = false
            renderGeneration = UUID()
            seekTaskGeneration = UUID()
            seekTask?.cancel()
            seekTask = nil
            pendingSeekTime = nil
            isSeeking = false
            player.pause()
            removeTimeObserver()
            player.replaceCurrentItem(with: nil)
        }
        .onChange(of: isPlaying) { _, _ in
            reconcilePlayback()
        }
        .onChange(of: seekRevision) { _, _ in
            guard isVisible else { return }
            isSeeking = true
            player.pause()
            // Dragging the ruler can submit many positions before AVPlayer
            // decodes one exact frame. Keep the newest position and allow only
            // one seek at a time, so obsolete decode requests cannot pile up.
            pendingSeekTime = playbackClock.time
            if seekTask != nil { player.currentItem?.cancelPendingSeeks() }
            drainSeeksIfNeeded()
        }
    }

    private func drainSeeksIfNeeded() {
        guard seekTask == nil else { return }
        let generation = UUID()
        seekTaskGeneration = generation
        seekTask = Task { @MainActor in
            while !Task.isCancelled, seekTaskGeneration == generation,
                  let seconds = pendingSeekTime {
                pendingSeekTime = nil
                await player.seek(
                    to: CMTime(seconds: seconds, preferredTimescale: 60_000),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                if pendingSeekTime != nil {
                    // Limit continuous scrubbing to the display cadence while
                    // preserving the final exact frame after the drag stops.
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
            if seekTaskGeneration == generation {
                seekTask = nil
                isSeeking = false
                reconcilePlayback()
            }
        }
    }

    private func reconcilePlayback() {
        guard isVisible else { return }
        // Seeking after reaching the end can reset AVPlayer's rate to zero.
        // Apply the latest intent only after the last exact seek completes;
        // an earlier Play must never override a newer Pause while decoding.
        if isPlaying, !isLoading, !isSeeking { player.play() }
        else { player.pause() }
    }

    private var previewRatio: CGFloat {
        if let ratio = project.settings.aspectRatio.ratio {
            return CGFloat(ratio)
        }
        let sourceSize = CGSize(
            width: max(1, project.sourceWidth),
            height: max(1, project.sourceHeight)
        )
        let crop = project.settings.sourceCropInsets?.sourceRect(in: sourceSize)
            ?? CGRect(origin: .zero, size: sourceSize)
        return crop.width / max(1, crop.height)
    }

    private var renderKey: RenderKey {
        let referencedIDs = Set((project.videoClips ?? []).compactMap(\.mediaAssetID))
        return RenderKey(
            id: project.id,
            sourceVideoPath: project.sourceVideoPath,
            duration: project.duration,
            sourceWidth: project.sourceWidth,
            sourceHeight: project.sourceHeight,
            videoClips: project.videoClips,
            videoTransitions: project.videoTransitions,
            mediaAssets: project.mediaAssets?.filter { referencedIDs.contains($0.id) } ?? [],
            editCutTimes: project.editCutTimes,
            zoomSegments: project.zoomSegments,
            regionEffects: project.regionEffects,
            chapters: project.chapters,
            settings: project.settings
        )
    }

    private func installTimeObserver() {
        guard observerToken == nil else { return }
        observerToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { time in
            MainActor.assumeIsolated {
                guard isVisible, !isSeeking, !isLoading else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                playbackClock.update(seconds.clamped(to: 0...max(playbackDuration, 0.001)))
                if seconds >= playbackDuration - 0.02 {
                    isPlaying = false
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let observerToken {
            player.removeTimeObserver(observerToken)
            self.observerToken = nil
        }
    }
}

private struct RenderKey: Hashable {
    let id: UUID
    let sourceVideoPath: String
    let duration: Double
    let sourceWidth: Int
    let sourceHeight: Int
    let videoClips: [DemoVideoClip]?
    let videoTransitions: [DemoVideoTransition]?
    let mediaAssets: [DemoMediaAsset]
    let editCutTimes: [Double]?
    let zoomSegments: [ZoomSegment]
    let regionEffects: [RegionEffect]?
    let chapters: [DemoChapter]?
    let settings: ProjectSettings
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
