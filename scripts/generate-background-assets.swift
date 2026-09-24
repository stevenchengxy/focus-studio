#!/usr/bin/env swift
//
// Generates Focus Studio's own background images.
//
// Every pixel is produced by the arithmetic below from a seeded generator, so
// the output is deterministic and the "original work" claim is reproducible by
// anyone who clones the repository. Nothing is downloaded and no third-party
// image is read. Run:
//
//     swift scripts/generate-background-assets.swift
//
// It rewrites Resources/Backgrounds/*.jpg and catalog.json, including the
// SHA-256 digests the build and release scripts verify.

import AppKit
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Deterministic randomness

/// A small linear congruential generator. Seeded per image so a change to one
/// background never reshuffles the others.
struct Seeded {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + next() * (range.upperBound - range.lowerBound)
    }
}

// MARK: - Palettes

struct Palette {
    let id: String
    let title: String
    let mood: String
    /// Base vertical gradient, top to bottom.
    let base: [String]
    /// Soft colour pools floated over the base.
    let blobs: [String]
    let seed: UInt64
    /// Light palettes darken their colour pools instead of adding light;
    /// adding light to a pale base just blows out to white.
    var isLight = false
}

let palettes: [Palette] = [
    Palette(id: "aurora-drift", title: "Aurora Drift", mood: "Violet · Indigo · Signature",
            base: ["#241B5E", "#0E0B2B"], blobs: ["#6D5DFB", "#3E8BFF", "#B06BFF"], seed: 11),
    Palette(id: "deep-ocean", title: "Deep Ocean", mood: "Navy · Cyan · Calm",
            base: ["#062B54", "#01101F"], blobs: ["#0866C6", "#18A6C9", "#2EE6D6"], seed: 22),
    Palette(id: "sunset-haze", title: "Sunset Haze", mood: "Coral · Amber · Warm",
            base: ["#5A1E3C", "#1C0A16"], blobs: ["#F97356", "#FFB25A", "#E8517F"], seed: 33),
    Palette(id: "blossom", title: "Blossom", mood: "Pink · Lilac · Soft",
            base: ["#4A2050", "#180B1C"], blobs: ["#C45CDE", "#FF8AC7", "#8E6BFF"], seed: 44),
    Palette(id: "citrus-fold", title: "Citrus Fold", mood: "Amber · Lime · Energetic",
            base: ["#4A3708", "#160F02"], blobs: ["#F6B93B", "#B8D94A", "#FF8A3D"], seed: 55),
    Palette(id: "midnight-ink", title: "Midnight Ink", mood: "Near-black · Blue · Minimal",
            base: ["#101632", "#04060F"], blobs: ["#27407F", "#3E5BB5", "#1B2A55"], seed: 66),
    Palette(id: "graphite", title: "Graphite", mood: "Neutral · Grey · Understated",
            base: ["#2C2F36", "#0E1013"], blobs: ["#4A4F5A", "#646B79", "#383D46"], seed: 77),
    Palette(id: "cloud-deck", title: "Cloud Deck", mood: "Light · Airy · Presentation",
            base: ["#EAF1FA", "#B9CBE4"], blobs: ["#7FA3D0", "#9DBBDD", "#6E8FC4"], seed: 88,
            isLight: true),
    Palette(id: "emerald-dusk", title: "Emerald Dusk", mood: "Green · Teal · Fresh",
            base: ["#0B3A31", "#031411"], blobs: ["#1FA97F", "#2EE6B0", "#0E7A8C"], seed: 99),
    Palette(id: "copper-sand", title: "Copper Sand", mood: "Terracotta · Sand · Editorial",
            base: ["#4A2A1C", "#180D08"], blobs: ["#C2703F", "#E8A96B", "#8E4A2F"], seed: 111),
    Palette(id: "arctic", title: "Arctic", mood: "Pale blue · Crisp · Clean",
            base: ["#EDF4FB", "#BAD2E6"], blobs: ["#8FB8D8", "#A9C9E2", "#6F9BC4"], seed: 122,
            isLight: true),
    Palette(id: "plum-velvet", title: "Plum Velvet", mood: "Deep purple · Rich · Premium",
            base: ["#2E1038", "#0D0413"], blobs: ["#7A2FA0", "#B14FD8", "#4B1E86"], seed: 133),
]

// MARK: - Drawing

let width = 2560
let height = 1600

func components(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
    var value = hex
    if value.hasPrefix("#") { value.removeFirst() }
    let number = UInt32(value, radix: 16) ?? 0
    return (
        CGFloat((number >> 16) & 0xFF) / 255,
        CGFloat((number >> 8) & 0xFF) / 255,
        CGFloat(number & 0xFF) / 255
    )
}

func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
    let (r, g, b) = components(hex)
    return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

func makeContext() -> CGContext {
    CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func render(_ palette: Palette) -> CGImage {
    var rng = Seeded(seed: palette.seed)
    let context = makeContext()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Base vertical gradient.
    let baseColors = palette.base.map { color($0) } as CFArray
    if let gradient = CGGradient(colorsSpace: space, colors: baseColors, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(height)),
            end: CGPoint(x: CGFloat(width) * 0.25, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    // Soft colour pools. Radial gradients that fade to zero alpha read as light
    // rather than as discs, which is what keeps this from looking like clip art.
    context.setBlendMode(palette.isLight ? .multiply : .plusLighter)
    for index in 0..<11 {
        let hex = palette.blobs[index % palette.blobs.count]
        let (r, g, b) = components(hex)
        let strength = palette.isLight ? rng.next(in: 0.10...0.26) : rng.next(in: 0.16...0.42)
        let stops: CFArray = [
            CGColor(srgbRed: r, green: g, blue: b, alpha: strength),
            CGColor(srgbRed: r, green: g, blue: b, alpha: strength * 0.45),
            CGColor(srgbRed: r, green: g, blue: b, alpha: 0),
        ] as CFArray
        guard let pool = CGGradient(colorsSpace: space, colors: stops, locations: [0, 0.45, 1]) else { continue }
        let centre = CGPoint(
            x: rng.next(in: -0.15...1.15) * Double(width),
            y: rng.next(in: -0.1...1.1) * Double(height)
        )
        let radius = rng.next(in: 0.22...0.62) * Double(width)
        context.drawRadialGradient(
            pool,
            startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: CGFloat(radius),
            options: []
        )
    }
    context.setBlendMode(.normal)

    // A wide diagonal sweep keeps the composition from being centre-heavy.
    let sweep: CFArray = [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: palette.isLight ? 0.02 : 0.06),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: space, colors: sweep, locations: [0, 1]) {
        context.saveGState()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: CGFloat(width) * 0.1, y: CGFloat(height)),
            end: CGPoint(x: CGFloat(width) * 0.75, y: CGFloat(height) * 0.15),
            options: []
        )
        context.restoreGState()
    }

    // Vignette, so a light UI recorded on top of it keeps its edges.
    let vignette: CFArray = [
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: palette.isLight ? 0.13 : 0.24),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: space, colors: vignette, locations: [0.55, 1]) {
        let centre = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.drawRadialGradient(
            gradient,
            startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: CGFloat(width) * 0.72,
            options: [.drawsAfterEndLocation]
        )
    }

    guard let flat = context.makeImage() else { fatalError("background render failed") }

    // Blur the colour pools together, then lay fine grain over the result so
    // large flat areas do not band when the exporter compresses them.
    let ciContext = CIContext(options: [.workingColorSpace: space])
    var image = CIImage(cgImage: flat)
    if let blur = CIFilter(name: "CIGaussianBlur") {
        blur.setValue(image, forKey: kCIInputImageKey)
        blur.setValue(60.0, forKey: kCIInputRadiusKey)
        if let output = blur.outputImage { image = output.cropped(to: CIImage(cgImage: flat).extent) }
    }
    if let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
        let grain = noise
            .cropped(to: image.extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.02, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.02, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.02, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.07),
            ])
        image = grain.composited(over: image)
    }
    guard let final = ciContext.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
        fatalError("background post-processing failed")
    }
    return final
}

// MARK: - Output

let projectDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)
let outputDirectory = projectDirectory.appendingPathComponent("Resources/Backgrounds", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

var entries: [[String: Any]] = []
for palette in palettes {
    let image = render(palette)
    let url = outputDirectory.appendingPathComponent("\(palette.id).jpg")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else { fatalError("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot finalize \(url.path)") }

    let data = try Data(contentsOf: url)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    entries.append([
        "id": palette.id,
        "title": palette.title,
        "mood": palette.mood,
        "relativePath": "\(palette.id).jpg",
        "width": width,
        "height": height,
        "bytes": data.count,
        "sha256": digest,
        "license": "Focus Studio Original",
    ])
    print("wrote \(palette.id).jpg  \(data.count / 1024) KB  \(digest.prefix(12))…")
}

let catalog: [String: Any] = [
    "schemaVersion": 1,
    "note": "Generated by scripts/generate-background-assets.swift. Every image is original output of that script; no third-party or system artwork is included.",
    "assets": entries,
]
let catalogURL = outputDirectory.appendingPathComponent("catalog.json")
try JSONSerialization
    .data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
    .write(to: catalogURL, options: .atomic)
print("wrote catalog.json with \(entries.count) backgrounds")
