import AVFoundation
import AVKit
import FocusStudioCore
import SwiftUI

struct ProjectPreviewView: View {
    let project: RecordingProject
    @Binding var currentTime: Double
    @Binding var isPlaying: Bool
    @Binding var renderError: String?

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
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Rendering preview…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioTheme.secondaryText)
                }
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
        .task(id: project) {
            let generation = UUID()
            renderGeneration = generation
            let desiredTime = currentTime
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
                await player.seek(to: CMTime(seconds: desiredTime, preferredTimescale: 600))
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
                if currentTime >= max(0, project.duration - 0.04) {
                    player.seek(to: .zero)
                }
                player.play()
            } else {
                player.pause()
            }
        }
        .onChange(of: currentTime) { oldValue, newValue in
            guard isVisible else { return }
            guard abs(oldValue - newValue) > 0.08 else { return }
            let actual = player.currentTime().seconds
            guard !actual.isFinite || abs(actual - newValue) > 0.12 else { return }
            player.seek(
                to: CMTime(seconds: newValue, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
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

    private func installTimeObserver() {
        guard observerToken == nil else { return }
        observerToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { time in
            guard isVisible else { return }
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
