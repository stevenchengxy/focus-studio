import AppKit
import CoreGraphics
import FocusStudioCore
import Foundation

/// Cursor styles, their artwork, and the click press animation.
func cursorStyleFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }

    // --- Settings decode without the new keys ----------------------------------
    let legacyClickJSON = """
    {"style":"ripple","colorHex":"#8B7BFF","size":1,"duration":0.65,"intensity":0.85,"pressCursor":true}
    """.data(using: .utf8)!
    if let legacy = try? JSONDecoder().decode(ClickAnimationSettings.self, from: legacyClickJSON) {
        expect(legacy.pressStyle == nil && legacy.pressAmount == nil,
               "click settings written before press styles carry no new keys")
        expect(legacy.resolvedPressStyle == .press,
               "a project without a press style keeps the original press animation")
        expect(legacy.resolvedPressAmount == 1,
               "a project without a press amount uses the full amount")
    } else {
        failures.append("click settings written before press styles must still decode")
    }

    var offSettings = ClickAnimationSettings()
    offSettings.pressCursor = false
    offSettings.pressStyle = .pop
    expect(offSettings.resolvedPressStyle == .none,
           "turning the pointer reaction off wins over a stored style")

    for style in ClickPressStyle.allCases {
        var settings = ClickAnimationSettings()
        settings.pressCursor = style != .none
        settings.pressStyle = style
        settings.pressAmount = 0.5
        guard let data = try? JSONEncoder().encode(settings),
              let restored = try? JSONDecoder().decode(ClickAnimationSettings.self, from: data)
        else {
            failures.append("press style \(style.rawValue) must survive a JSON round trip")
            continue
        }
        expect(restored.resolvedPressStyle == style,
               "press style \(style.rawValue) survives a JSON round trip")
        expect(restored.resolvedPressAmount == 0.5,
               "press amount survives a JSON round trip for \(style.rawValue)")
    }

    var wildAmount = ClickAnimationSettings()
    wildAmount.pressAmount = 42
    expect(wildAmount.sanitized.resolvedPressAmount == 1, "an out-of-range press amount is clamped")
    wildAmount.pressAmount = .nan
    expect(wildAmount.sanitized.resolvedPressAmount == 1, "a non-finite press amount falls back to the default")

    // --- Press curves -----------------------------------------------------------
    func legacyPressScale(age: Double, duration: Double) -> Double {
        let span = min(0.42, duration * 0.72)
        guard age > 0, age < span else { return 1 }
        let t = age / span
        if t < 0.24 { return 1 - 0.14 * TimelineMath.smootherStep(t / 0.24) }
        if t < 0.65 { return 0.86 + 0.17 * TimelineMath.smootherStep((t - 0.24) / 0.41) }
        return 1.03 - 0.03 * TimelineMath.smootherStep((t - 0.65) / 0.35)
    }

    var pressSettings = ClickAnimationSettings()
    pressSettings.pressStyle = .press
    let pressDuration = ClickAnimationMath.pressDuration(settings: pressSettings)
    expect(abs(pressDuration - min(0.42, 0.65 * 0.72)) < 1e-9,
           "the press lasts as long as it always has")
    var legacyDrift = 0.0
    for step in 0...200 {
        let age = Double(step) / 200 * pressDuration
        let now = ClickAnimationMath.cursorPressScale(age: age, settings: pressSettings)
        legacyDrift = max(legacyDrift, abs(now - legacyPressScale(age: age, duration: pressSettings.duration)))
    }
    expect(legacyDrift < 1e-9, "Press in reproduces the curve shipped before it was choosable (\(legacyDrift))")

    var popSettings = ClickAnimationSettings()
    popSettings.pressStyle = .pop
    let popDuration = ClickAnimationMath.pressDuration(settings: popSettings)

    func samples(_ settings: ClickAnimationSettings, _ duration: Double) -> [Double] {
        stride(from: 0.0, through: 1.0, by: 0.0025).map {
            ClickAnimationMath.cursorPressScale(age: $0 * duration, settings: settings)
        }
    }
    let pressCurve = samples(pressSettings, pressDuration)
    let popCurve = samples(popSettings, popDuration)

    for (name, curve) in [("Press in", pressCurve), ("Pop out", popCurve)] {
        expect(abs(curve.first! - 1) < 1e-9 && abs(curve.last! - 1) < 1e-9,
               "\(name) starts and ends at the resting size")
        let velocity = zip(curve, curve.dropFirst()).map { $1 - $0 }
        let acceleration = zip(velocity, velocity.dropFirst()).map { abs($1 - $0) }
        expect(acceleration.max()! < 0.002,
               "\(name) has no velocity kink (max \(acceleration.max()!))")
        expect(curve.allSatisfy { $0 > 0.5 && $0 < 1.6 },
               "\(name) stays within a sane scale range")
    }

    let firstPressExtreme = pressCurve.first { abs($0 - 1) > 0.01 } ?? 1
    expect(firstPressExtreme < 1, "Press in compresses the pointer first")
    let firstPopExtreme = popCurve.first { abs($0 - 1) > 0.01 } ?? 1
    expect(firstPopExtreme > 1, "Pop out swells the pointer first")
    expect(popCurve.min()! < 1, "Pop out settles back through the resting size")
    expect(pressCurve.max()! > 1, "Press in rebounds past the resting size")

    var halfAmount = popSettings
    halfAmount.pressAmount = 0.5
    let halfCurve = samples(halfAmount, ClickAnimationMath.pressDuration(settings: halfAmount))
    expect(abs((halfCurve.max()! - 1) - (popCurve.max()! - 1) / 2) < 0.002,
           "the press amount scales the excursion")

    var zeroAmount = popSettings
    zeroAmount.pressAmount = 0
    expect(samples(zeroAmount, popDuration).allSatisfy { $0 == 1 },
           "a zero press amount leaves the pointer alone")

    var noneSettings = ClickAnimationSettings()
    noneSettings.pressCursor = false
    expect(samples(noneSettings, pressDuration).allSatisfy { $0 == 1 },
           "None leaves the pointer alone")

    // --- Appearance decoding ----------------------------------------------------
    for raw in ["system", "highContrast", "dot"] {
        expect(CursorAppearance(rawValue: raw) != nil,
               "the cursor style \(raw) written by earlier builds still decodes")
    }
    expect(CursorAppearance.allCases.first == .system,
           "the gallery leads with the system pointer")
    expect(Set(CursorAppearance.allCases.map(\.rawValue)).count == CursorAppearance.allCases.count,
           "cursor style raw values are unique")
    expect(CursorAppearance.allCases.filter(\.usesAccentTint) == [.accent],
           "only the Accent style follows the click colour")
    for appearance in CursorAppearance.allCases {
        var settings = ProjectSettings()
        settings.cursorAppearance = appearance
        guard let data = try? JSONEncoder().encode(settings),
              let restored = try? JSONDecoder().decode(ProjectSettings.self, from: data)
        else {
            failures.append("cursor style \(appearance.rawValue) must survive a JSON round trip")
            continue
        }
        expect(restored.resolvedCursorAppearance == appearance,
               "cursor style \(appearance.rawValue) survives a JSON round trip")
    }
    var withoutAppearance = ProjectSettings()
    withoutAppearance.cursorAppearance = nil
    expect(withoutAppearance.resolvedCursorAppearance == .system,
           "a project without a stored style renders the system pointer")

    // --- Artwork ----------------------------------------------------------------
    MainActor.assumeIsolated {
        // Cursor images are empty until AppKit has a running application.
        _ = NSApplication.shared
        let tint = NSColor(srgbRed: 0.55, green: 0.48, blue: 1, alpha: 1)

        func fingerprint(_ image: CGImage) -> [UInt8] {
            let side = 24
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return }
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            }
            return pixels
        }

        var arrowPrints: [CursorAppearance: [UInt8]] = [:]
        for appearance in CursorAppearance.allCases {
            let set = CursorArtwork.set(for: appearance, tint: tint)
            expect(set.count == CursorKind.allCases.count,
                   "\(appearance.rawValue) provides artwork for every pointer shape")
            for kind in CursorKind.allCases {
                guard let graphic = set[kind] else {
                    failures.append("\(appearance.rawValue) is missing the \(kind.rawValue) pointer")
                    continue
                }
                expect(graphic.image.width > 0 && graphic.image.height > 0,
                       "\(appearance.rawValue)/\(kind.rawValue) has a drawable image")
                expect(graphic.supersample > 0,
                       "\(appearance.rawValue)/\(kind.rawValue) reports a usable density")
                expect(graphic.hotSpot.x >= 0, "\(appearance.rawValue)/\(kind.rawValue) hot spot is not negative")
                expect(graphic.hotSpot.y >= 0, "\(appearance.rawValue)/\(kind.rawValue) hot spot is not negative")
                expect(graphic.hotSpot.x <= CGFloat(graphic.image.width),
                       "\(appearance.rawValue)/\(kind.rawValue) hot spot is inside the image")
                expect(graphic.hotSpot.y <= CGFloat(graphic.image.height),
                       "\(appearance.rawValue)/\(kind.rawValue) hot spot is inside the image")
                // Rendered size is the pixel size divided by the density; every
                // style must land within a stone's throw of the system pointer
                // so switching style is not a size change in disguise.
                let renderedHeight = CGFloat(graphic.image.height) / graphic.supersample
                expect(renderedHeight > 20 && renderedHeight < 60,
                       "\(appearance.rawValue)/\(kind.rawValue) renders at a comparable size (\(renderedHeight))")
            }
            if let arrow = set[.arrow] { arrowPrints[appearance] = fingerprint(arrow.image) }
        }

        for (lhs, rhs) in [
            (CursorAppearance.elevated, CursorAppearance.highContrast),
            (.elevated, .light),
            (.light, .accent),
            (.accent, .dot),
            (.highContrast, .dot),
        ] {
            expect(arrowPrints[lhs] != arrowPrints[rhs],
                   "the \(lhs.rawValue) and \(rhs.rawValue) pointers are visibly different")
        }

        let warmTint = NSColor(srgbRed: 1, green: 0.4, blue: 0.2, alpha: 1)
        let accentCool = CursorArtwork.graphic(for: .arrow, appearance: .accent, tint: tint)
        let accentWarm = CursorArtwork.graphic(for: .arrow, appearance: .accent, tint: warmTint)
        expect(fingerprint(accentCool.image) != fingerprint(accentWarm.image),
               "the Accent pointer takes its colour from the click colour")
        let elevatedCool = CursorArtwork.graphic(for: .arrow, appearance: .elevated, tint: tint)
        let elevatedWarm = CursorArtwork.graphic(for: .arrow, appearance: .elevated, tint: warmTint)
        expect(fingerprint(elevatedCool.image) == fingerprint(elevatedWarm.image),
               "the other styles ignore the click colour")

        let swatch = CursorArtwork.preview(
            for: .elevated,
            tint: tint,
            size: CGSize(width: 54, height: 66)
        )
        expect(swatch?.width == 54 && swatch?.height == 66,
               "a gallery swatch is drawn at the requested size")
    }

    return failures
}
