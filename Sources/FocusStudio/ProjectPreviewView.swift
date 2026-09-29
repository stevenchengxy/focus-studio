import AVFoundation
import AVKit
import FocusStudioCore
import SwiftUI

struct ProjectPreviewView: View {
    let project: RecordingProject
    @Binding var currentTime: Double
    @Binding var isPlaying: Bool
    var seekRevision: Int
    @Binding var renderError: String?
    @State private var isSeeking = false
    @State private var seekGeneration = 0

    @State private var player = AVPlayer()
    @State private var isLoading = true
    @State private var observerToken: Any?
    @State private var isVisible = false
    @State private var renderGeneration = UUID()

    var body: some View {
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
                    to: CMTime(seconds: currentTime, preferredTimescale: 60_000),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                guard !Task.isCancelled, isVisible, renderGeneration == generation else { return }
                if isPlaying { player.play() }
            } catch is CancellationError {
                return
            } catch {
                guard isVisible, renderGeneration == generation else { return }
                renderError = error.localizedDescription
            }
            if isVisible, renderGeneration == generation { isLoading = false }
        }
        .onAppear {
            isVisible = true
            installTimeObserver()
        }
        .onDisappear {
            isVisible = false
            renderGeneration = UUID()
            player.pause()
            removeTimeObserver()
            player.replaceCurrentItem(with: nil)
        }
        .onChange(of: isPlaying) { _, playing in
            guard isVisible else { return }
            if playing {
                player.play()
            } else {
                player.pause()
            }
        }
        .onChange(of: seekRevision) { _, _ in
            guard isVisible else { return }
            seekGeneration += 1
            let generation = seekGeneration
            isSeeking = true
            player.seek(
                to: CMTime(seconds: currentTime, preferredTimescale: 60000),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                Task { @MainActor in
                    guard generation == seekGeneration else { return }
                    isSeeking = false
                }
            }
        }
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
            guard isVisible, !isSeeking, !isLoading else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            currentTime = seconds.clamped(to: 0...max(project.duration, 0.001))
            if seconds >= project.duration - 0.02 {
                isPlaying = false
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
