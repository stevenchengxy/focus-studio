import CoreImage
import CoreGraphics
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
        let rim: CIImage
        let selection: CGRect
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
            let media = project.mediaAssets?.first { $0.id == placement.clip.mediaAssetID }
            let sourceWidth = CGFloat(max(1, media?.width ?? project.sourceWidth))
            let sourceHeight = CGFloat(max(1, media?.height ?? project.sourceHeight))
            let referenceScale = 1_024 / max(sourceWidth, sourceHeight)
            let size = CGSize(width: sourceWidth * referenceScale, height: sourceHeight * referenceScale)
            let rect = Self.selectionRect(effect: effect, sourceSize: size)
            let radius = effect.preset == .magnify ? rect.width / 2 : min(12, min(rect.width, rect.height) * 0.08)
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
            let width = max(0.75, effect.resolvedOutlineWidth * size.height / 1080)
            let rim = Self.makeRim(rect: rect, radius: radius, width: width) ?? mask
            artwork[effect.id] = Artwork(mask: mask, shadow: shadow, rim: rim,
                                          selection: rect, referenceSize: size)
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
        let selectedSource = Self.selectionRect(effect: effect, sourceSize: sourceSize)
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
            let point = overlay.anchor.applying(inverse)
            let withinSelection = selectedSource.contains(point)
                && (effect.preset != .magnify || hypot(point.x - selectedSource.midX, point.y - selectedSource.midY) <= selectedSource.width / 2)
            if withinSelection {
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
        if effect.preset == .outline {
            // Draw the perimeter once during entry; fade it on return. No
            // per-frame bitmap allocation or path rasterization is needed.
            let ramp = min(effect.easeIn, placement.duration / 2)
            let reveal = ramp > 0 ? ((seconds - placement.start) / ramp).clamped(to: 0...1) : 1
            let rim = Self.revealedRim(artwork.rim, rect: artwork.selection, fraction: reveal)
                .transformed(by: referenceToCanvas)
            return Self.coloredMask(rim, color: CIColor(red: 0.42, green: 0.94, blue: 0.78, alpha: progress), within: screenFrame)
                .composited(over: card.composited(over: background)).cropped(to: screenFrame)
        }
        if effect.preset == .perspective {
            let corners = RegionPerspectiveGeometry.corners(rect: selectedFrame, within: screenFrame,
                scale: effect.scale, degrees: effect.resolvedPerspectiveDegrees, progress: progress)
            let placed = Self.perspective(card.cropped(to: selectedFrame), corners: corners)
            // Project the cached shadow with the same homography, then soften
            // its boundary after projection to avoid a rectangular edge.
            let shadowMask = artwork.shadow.transformed(by: referenceToCanvas)
            let projectedShadow = Self.perspective(shadowMask.cropped(to: selectedFrame), corners: corners)
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 7 * progress])
                .transformed(by: CGAffineTransform(translationX: 0, y: -8 * progress))
            let shadow = Self.coloredMask(projectedShadow,
                color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.34 * progress), within: screenFrame)
            return placed.composited(over: shadow.composited(over: background)).cropped(to: screenFrame)
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
        var foreground = card.transformed(by: transform)
        if effect.preset == .magnify {
            let rim = artwork.rim.transformed(by: referenceToCanvas).transformed(by: transform)
            foreground = Self.coloredMask(rim, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.9 * progress), within: screenFrame)
                .composited(over: foreground)
        }
        return foreground.composited(over: shadow.composited(over: background)).cropped(to: screenFrame)
    }


    private static func selectionRect(effect: RegionEffect, sourceSize: CGSize) -> CGRect {
        let r = effect.rect
        let rectangle = CGRect(x: r.x * sourceSize.width, y: (1 - r.y - r.height) * sourceSize.height,
                               width: r.width * sourceSize.width, height: r.height * sourceSize.height)
        guard effect.preset == .magnify else { return rectangle }
        let diameter = min(rectangle.width, rectangle.height)
        return CGRect(x: rectangle.midX - diameter / 2, y: rectangle.midY - diameter / 2,
                      width: diameter, height: diameter)
    }

    private static func makeRim(rect: CGRect, radius: CGFloat, width: CGFloat) -> CIImage? {
        let bounds = rect.insetBy(dx: -width - 2, dy: -width - 2).integral
        guard let context = CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(width)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
        guard let pixels = context.makeImage() else { return nil }
        return CIImage(cgImage: pixels).transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
    }

    private static func coloredMask(_ mask: CIImage, color: CIColor, within frame: CGRect) -> CIImage {
        CIImage(color: color).cropped(to: frame).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: frame),
            kCIInputMaskImageKey: mask
        ])
    }

    private static func revealedRim(_ image: CIImage, rect: CGRect, fraction: Double) -> CIImage {
        guard fraction < 1 else { return image }
        let extent = image.extent
        let pad = max(rect.minX - extent.minX, rect.minY - extent.minY) + 1
        let lengths = [rect.width, rect.height, rect.width, rect.height]
        var remaining = (rect.width + rect.height) * 2 * fraction
        var result = CIImage(color: .clear).cropped(to: extent)
        for (index, length) in lengths.enumerated() {
            let part = min(length, max(0, remaining)); remaining -= length
            guard part > 0 else { continue }
            let area: CGRect
            switch index {
            case 0: area = CGRect(x: rect.minX - pad, y: rect.maxY - pad, width: part + pad, height: pad * 2)
            case 1: area = CGRect(x: rect.maxX - pad, y: rect.maxY - part, width: pad * 2, height: part + pad)
            case 2: area = CGRect(x: rect.maxX - part, y: rect.minY - pad, width: part + pad, height: pad * 2)
            default: area = CGRect(x: rect.minX - pad, y: rect.minY - pad, width: pad * 2, height: part + pad)
            }
            result = image.cropped(to: area).composited(over: result)
        }
        return result
    }

    private static func perspective(_ image: CIImage, corners: [CGPoint]) -> CIImage {
        image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: corners[0]), "inputTopRight": CIVector(cgPoint: corners[1]),
            "inputBottomRight": CIVector(cgPoint: corners[2]), "inputBottomLeft": CIVector(cgPoint: corners[3])
        ])
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
