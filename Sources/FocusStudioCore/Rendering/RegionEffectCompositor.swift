import CoreImage
import Foundation

/// Pointer artwork stays separate until the cut-out is placed, so it is drawn
/// once and follows the same transform as the pixels beneath its hotspot.
struct RegionEffectOverlay {
    let image: CIImage
    let anchor: CGPoint
}

/// A single immutable composition graph serves preview and export. Both the
/// background and selected card reuse the incoming decoded frame.
final class RegionEffectCompositor: @unchecked Sendable {
    private struct Artwork {
        let mask: CIImage
        let shadow: CIImage
        let referenceSize: CGSize
    }

    private let timeline: RegionEffectTimeline?
    private let artwork: [UUID: Artwork]

    init(project: RecordingProject) {
        timeline = try? RegionEffectTimeline(project: project)
        guard let placements = timeline?.placements, !placements.isEmpty else {
            artwork = [:]
            return
        }
        let context = CIContext(options: [.cacheIntermediates: true])
        var artwork: [UUID: Artwork] = [:]
        for placement in placements {
            let effect = placement.effect
            let r = effect.rect
            let media = project.mediaAssets?.first { $0.id == placement.clip.mediaAssetID }
            let sourceWidth = CGFloat(max(1, media?.width ?? project.sourceWidth))
            let sourceHeight = CGFloat(max(1, media?.height ?? project.sourceHeight))
            let referenceScale = 1_024 / max(sourceWidth, sourceHeight)
            let size = CGSize(width: sourceWidth * referenceScale, height: sourceHeight * referenceScale)
            let rect = CGRect(x: r.x * size.width, y: (1 - r.y - r.height) * size.height,
                              width: r.width * size.width, height: r.height * size.height)
            let radius = min(12, min(rect.width, rect.height) * 0.08)
            guard let maskGraph = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                kCIInputExtentKey: CIVector(cgRect: rect),
                kCIInputRadiusKey: radius,
                kCIInputColorKey: CIColor.white
            ])?.outputImage else { continue }
            let maskBounds = rect.insetBy(dx: -1, dy: -1).integral
            guard let pixels = context.createCGImage(maskGraph, from: maskBounds) else { continue }
            let mask = CIImage(cgImage: pixels).transformed(by: CGAffineTransform(
                translationX: maskBounds.minX, y: maskBounds.minY))
            let shadowBounds = rect.insetBy(dx: -54, dy: -54).integral
            let shadowGraph = mask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 14])
            let shadow: CIImage
            if let pixels = context.createCGImage(shadowGraph, from: shadowBounds) {
                shadow = CIImage(cgImage: pixels).transformed(by: CGAffineTransform(
                    translationX: shadowBounds.minX, y: shadowBounds.minY))
            } else {
                shadow = mask
            }
            artwork[effect.id] = Artwork(mask: mask, shadow: shadow, referenceSize: size)
        }
        self.artwork = artwork
    }

    func render(
        image: CIImage,
        overlays: [RegionEffectOverlay],
        at seconds: Double,
        sourceSize: CGSize,
        sourceToCanvas: CGAffineTransform,
        screenFrame: CGRect
    ) -> CIImage {
        guard let placement = timeline?.active(at: seconds),
              let artwork = artwork[placement.effect.id] else {
            return overlays.reduce(image) { $1.image.composited(over: $0) }
        }
        let progress = placement.progress(at: seconds).clamped(to: 0...1)
        guard progress > 0.000_01 else {
            return overlays.reduce(image) { $1.image.composited(over: $0) }
        }
        let effect = placement.effect
        let r = effect.rect
        let selectedSource = CGRect(x: r.x * sourceSize.width,
                                    y: (1 - r.y - r.height) * sourceSize.height,
                                    width: r.width * sourceSize.width,
                                    height: r.height * sourceSize.height)
        let selectedFrame = selectedSource.applying(sourceToCanvas).intersection(screenFrame)
        guard !selectedFrame.isNull, selectedFrame.width > 1, selectedFrame.height > 1 else {
            return overlays.reduce(image) { $1.image.composited(over: $0) }
        }
        let referenceToCanvas = CGAffineTransform(scaleX: sourceSize.width / artwork.referenceSize.width,
                                                  y: sourceSize.height / artwork.referenceSize.height)
            .concatenating(sourceToCanvas)
        let mask = artwork.mask.transformed(by: referenceToCanvas).cropped(to: screenFrame)
        let transparent = CIImage(color: .clear).cropped(to: screenFrame)
        let inverse = sourceToCanvas.inverted()
        var background = image
        var selectedOverlays: [CIImage] = []
        for overlay in overlays {
            if selectedSource.contains(overlay.anchor.applying(inverse)) {
                selectedOverlays.append(overlay.image)
            } else {
                background = overlay.image.composited(over: background)
            }
        }

        let strength = effect.intensity.clamped(to: 0...1) * progress
        switch effect.background {
        case .none:
            break
        case .dim:
            background = background.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - strength, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - strength, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - strength, w: 0)
            ])
        case .blur:
            // Zero strength must preserve the original background exactly;
            // even a radius-zero downsample/upsample can soften source pixels.
            guard strength > 0 else { break }
            // Text in the card remains native-resolution. Only the backdrop
            // takes this small, bounded blur path, independent of export size.
            let downsample = min(1, 640 / max(screenFrame.width, screenFrame.height))
            let low = background.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: downsample, y: downsample))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 10 * strength])
                .transformed(by: CGAffineTransform(scaleX: 1 / downsample, y: 1 / downsample))
                .cropped(to: screenFrame)
            background = background.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: low, kCIInputTimeKey: strength
            ])
        }
        var card = image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: transparent,
            kCIInputMaskImageKey: mask
        ])
        for overlay in selectedOverlays { card = overlay.composited(over: card) }
        guard effect.preset != .spotlight else {
            return card.composited(over: background).cropped(to: screenFrame)
        }

        let angle: Double
        if effect.preset == .tilt, effect.easeIn > 0 {
            let rampFactor = min(1, placement.duration / max(0.000_001, effect.easeIn + effect.easeOut))
            let entry = ((seconds - placement.start) / (effect.easeIn * rampFactor)).clamped(to: 0...1)
            angle = -0.075 * sin(.pi * entry) * progress
        } else {
            angle = 0
        }
        let transform = Self.cardTransform(rect: selectedFrame, within: screenFrame,
                                           scale: 1 + (effect.scale.clamped(to: 1...3) - 1) * progress,
                                           angle: angle)
        let shadowMask = artwork.shadow.transformed(by: referenceToCanvas)
            .cropped(to: screenFrame)
            .transformed(by: transform)
            .transformed(by: CGAffineTransform(translationX: 0, y: -8 * progress))
        let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.38 * progress))
            .cropped(to: screenFrame)
            .applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: transparent,
                kCIInputMaskImageKey: shadowMask
            ])
        return card.transformed(by: transform)
            .composited(over: shadow.composited(over: background))
            .cropped(to: screenFrame)
    }

    /// Limit the whole rotated card to the visible screen, including selections
    /// beside an edge. At zero progress this is precisely the identity matrix.
    private static func cardTransform(rect: CGRect, within frame: CGRect,
                                      scale requestedScale: Double, angle: Double) -> CGAffineTransform {
        let cosine = CGFloat(Foundation.cos(angle))
        let sine = CGFloat(Foundation.sin(angle))
        let rotatedWidth = abs(cosine) * rect.width + abs(sine) * rect.height
        let rotatedHeight = abs(sine) * rect.width + abs(cosine) * rect.height
        let scale = min(CGFloat(requestedScale), frame.width / rotatedWidth, frame.height / rotatedHeight)
        var transform = CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        let result = rect.applying(transform)
        let dx = max(0, frame.minX - result.minX) - max(0, result.maxX - frame.maxX)
        let dy = max(0, frame.minY - result.minY) - max(0, result.maxY - frame.maxY)
        transform = transform.concatenating(CGAffineTransform(translationX: dx, y: dy))
        return transform
    }
}
