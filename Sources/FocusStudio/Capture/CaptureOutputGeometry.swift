import CoreGraphics
import Foundation

/// Deterministic pixel sizing shared by movie and screenshot capture.
///
/// Keeping this calculation separate from ScreenCaptureKit makes the contract
/// testable: an area target is encoded from the selected area's point size,
/// never from the full backing display.
public struct CapturePixelSize: Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum CaptureOutputGeometry {
    public static func pixelSize(
        sourcePointSize: CGSize,
        targetScaleFactor: Double,
        outputScale: Double?,
        maximumOutputDimension: Int
    ) -> CapturePixelSize {
        let scale = outputScale ?? max(1, targetScaleFactor)
        var width = max(2, Int((sourcePointSize.width * scale).rounded()))
        var height = max(2, Int((sourcePointSize.height * scale).rounded()))

        let largestDimension = max(width, height)
        if largestDimension > maximumOutputDimension {
            let reduction = Double(maximumOutputDimension) / Double(largestDimension)
            width = max(2, Int((Double(width) * reduction).rounded(.down)))
            height = max(2, Int((Double(height) * reduction).rounded(.down)))
        }

        // H.264/HEVC encoders are most reliable with even pixel dimensions.
        width -= width % 2
        height -= height % 2
        return CapturePixelSize(width: max(2, width), height: max(2, height))
    }
}
