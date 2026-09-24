import AppKit
import ApplicationServices
import CoreGraphics
import FocusStudioCore
import Foundation

/// Pure accessibility semantics shared by live detection and deterministic tests.
public enum CursorKindSemantics {
    public static func classify(
        role: String?,
        subrole: String?,
        isEditable: Bool,
        hasEditableAncestor: Bool,
        isLink: Bool = false
    ) -> CursorKind {
        if role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || subrole == (kAXSearchFieldSubrole as String)
            || subrole == (kAXSecureTextFieldSubrole as String)
            || isEditable
            || hasEditableAncestor {
            return .iBeam
        }
        if isLink || role == "AXLink" {
            return .pointingHand
        }
        return .arrow
    }
}

/// Recognises the cursor macOS is actually showing by comparing a small
/// grayscale fingerprint of `NSCursor.currentSystem` with the system arrow,
/// I-beam and pointing hand. This mirrors what the viewer saw (Chrome, Safari
/// and native apps all use these system cursors) without needing the target
/// application's accessibility tree.
@MainActor
public final class SystemCursorMatcher {
    public static let fingerprintSize = 24
    /// Mean absolute difference (0...1) below which a cursor counts as a match.
    public static let matchThreshold = 0.06

    private struct Reference {
        let kind: CursorKind
        let fingerprint: [Float]
    }

    private lazy var references: [Reference] = [
        (CursorKind.arrow, NSCursor.arrow),
        (CursorKind.iBeam, NSCursor.iBeam),
        (CursorKind.pointingHand, NSCursor.pointingHand),
    ].compactMap { kind, cursor in
        Self.fingerprint(of: cursor.image).map { Reference(kind: kind, fingerprint: $0) }
    }

    public init() {}

    /// The kind whose fingerprint is closest to `cursor`, or nil when nothing
    /// is close enough (custom cursors, resize cursors, no cursor available).
    public func match(_ cursor: NSCursor?) -> CursorKind? {
        guard let cursor, let probe = Self.fingerprint(of: cursor.image) else { return nil }
        var best: (kind: CursorKind, distance: Double)?
        for reference in references {
            let distance = Self.distance(probe, reference.fingerprint)
            if best == nil || distance < best!.distance { best = (reference.kind, distance) }
        }
        guard let best, best.distance <= Self.matchThreshold else { return nil }
        return best.kind
    }

    /// Exposed for tests: how far apart two system cursors are.
    public func referenceDistance(_ lhs: NSCursor, _ rhs: NSCursor) -> Double? {
        guard let a = Self.fingerprint(of: lhs.image), let b = Self.fingerprint(of: rhs.image) else { return nil }
        return Self.distance(a, b)
    }

    /// True when the system cursor images are loadable in this process (they
    /// need an AppKit application context; a bare command-line tool sees
    /// empty images for some cursors).
    public var hasReferences: Bool { !references.isEmpty }

    private static func distance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var total = 0.0
        for index in a.indices { total += Double(abs(a[index] - b[index])) }
        return total / Double(a.count)
    }

    /// Alpha-weighted grayscale, scaled to fit a fixed square, so cursors of
    /// different pixel sizes (1x/2x, different themes) still compare.
    private static func fingerprint(of image: NSImage) -> [Float]? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard image.size.width > 0, image.size.height > 0,
              let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let size = fingerprintSize
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        // The context must draw while the buffer pointer is valid: keep both
        // inside one withUnsafeMutableBytes scope.
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .high
            let scale = min(Double(size) / Double(cgImage.width), Double(size) / Double(cgImage.height))
            let drawWidth = Double(cgImage.width) * scale
            let drawHeight = Double(cgImage.height) * scale
            // Anchor at the top-left so hot-spot-relative shapes line up.
            context.draw(cgImage, in: CGRect(x: 0, y: Double(size) - drawHeight, width: drawWidth, height: drawHeight))
            return true
        }
        guard drawn else { return nil }
        var result = [Float](repeating: 0, count: size * size)
        for index in 0..<(size * size) {
            let r = Float(pixels[index * 4]), g = Float(pixels[index * 4 + 1]), b = Float(pixels[index * 4 + 2])
            let a = Float(pixels[index * 4 + 3]) / 255
            // Premultiplied luminance plus coverage: the shape matters more than tint.
            result[index] = ((0.299 * r + 0.587 * g + 0.114 * b) / 255) * 0.5 + a * 0.5
        }
        return result
    }
}

/// Detects whether the pointer is over an editable accessibility element.
///
/// Accessibility lookup is intentionally best-effort and never prompts. When
/// access is unavailable, or an application does not expose useful semantics,
/// recording continues with an arrow cursor. Probes are throttled so a 120 Hz
/// mouse stream cannot saturate the main thread or the target application's AX
/// server.
@MainActor
final class CursorKindDetector {
    private let systemWideElement = AXUIElementCreateSystemWide()
    private let accessibilityTrustedOverride: Bool?
    private let systemCursorMatcher = SystemCursorMatcher()
    private var lastProbeUptime = -Double.infinity
    private var cachedKind: CursorKind = .arrow

    let minimumProbeInterval: TimeInterval = 1.0 / 15.0

    init(accessibilityTrusted: Bool? = nil) {
        self.accessibilityTrustedOverride = accessibilityTrusted
    }

    func reset() {
        lastProbeUptime = -.infinity
        cachedKind = .arrow
    }

    func kind(at point: CGPoint, uptime: TimeInterval) -> CursorKind {
        guard uptime - lastProbeUptime >= minimumProbeInterval else {
            return cachedKind
        }
        lastProbeUptime = uptime
        // The cursor the window server is showing is the ground truth (links
        // show the pointing hand, inputs the I-beam); it needs no permission.
        if let matched = systemCursorMatcher.match(NSCursor.currentSystem) {
            cachedKind = matched
            return cachedKind
        }
        // Permission may be enabled while the app remains open. Recheck it at
        // probe frequency without requesting access or reopening Settings.
        guard accessibilityTrustedOverride ?? AXIsProcessTrusted() else {
            cachedKind = .arrow
            return cachedKind
        }

        var hitElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &hitElement
        )
        guard result == .success, let hitElement else {
            cachedKind = .arrow
            return cachedKind
        }

        cachedKind = semanticKind(startingAt: hitElement)
        return cachedKind
    }

    private func semanticKind(startingAt element: AXUIElement) -> CursorKind {
        var current: AXUIElement? = element
        // Web content sometimes reports a static-text leaf underneath the mouse
        // and places editability on an ancestor. A small bounded walk handles
        // Chrome/Safari contenteditable without traversing an entire AX tree.
        for _ in 0..<5 {
            guard let element = current else { break }
            let role = stringAttribute(kAXRoleAttribute as CFString, of: element)
            let subrole = stringAttribute(kAXSubroleAttribute as CFString, of: element)
            let editable = boolAttribute("AXIsEditable" as CFString, of: element)
            let editableAncestor = elementAttribute("AXEditableAncestor" as CFString, of: element) != nil
            let isLink = attribute("AXURL" as CFString, of: element) != nil
            let kind = CursorKindSemantics.classify(
                role: role,
                subrole: subrole,
                isEditable: editable,
                hasEditableAncestor: editableAncestor,
                isLink: isLink
            )
            if kind != .arrow { return kind }
            current = elementAttribute(kAXParentAttribute as CFString, of: element)
        }
        return .arrow
    }

    private func stringAttribute(_ name: CFString, of element: AXUIElement) -> String? {
        attribute(name, of: element) as? String
    }

    private func boolAttribute(_ name: CFString, of element: AXUIElement) -> Bool {
        (attribute(name, of: element) as? Bool) ?? false
    }

    private func elementAttribute(_ name: CFString, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func attribute(_ name: CFString, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value
    }
}
