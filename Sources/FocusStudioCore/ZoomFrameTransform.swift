import CoreGraphics
import Foundation

/// One camera matrix for footage and recorded interaction overlays. It adds
/// only the overscan necessary to cover the output frame during a tilt/slide,
/// avoiding black corners without changing the classic camera path.
public struct ZoomFrameTransform {
    public let affineTransform: CGAffineTransform
    public let effectiveScale: Double

    private let width: Double
    private let height: Double

    public init(state: ZoomState, width: Double, height: Double) {
        self.width = max(1, width.isFinite ? width : 1)
        self.height = max(1, height.isFinite ? height : 1)
        let centerX = state.centerX.isFinite ? state.centerX.clamped(to: 0.001...0.999) : 0.5
        let centerY = state.centerY.isFinite ? state.centerY.clamped(to: 0.001...0.999) : 0.5
        let angle = state.rotationRadians.isFinite
            ? state.rotationRadians.clamped(to: -0.12...0.12) : 0
        let offsetX = state.offsetX.isFinite ? state.offsetX.clamped(to: -0.12...0.12) : 0
        let offsetY = state.offsetY.isFinite ? state.offsetY.clamped(to: -0.12...0.12) : 0
        let baseScale = state.scale.isFinite ? max(1, state.scale) : 1
        let hasAdditionalMotion = abs(angle) > 0.000_001
            || abs(offsetX) > 0.000_001 || abs(offsetY) > 0.000_001
        let cosine = angle == 0 ? 1 : cos(angle)
        let sine = angle == 0 ? 0 : sin(angle)

        var coveredScale = baseScale
        if hasAdditionalMotion {
            // Inverse-map the four output corners. Each one must remain inside
            // the source rectangle after the matrix is applied.
            for xIndex in 0...1 {
                for yIndex in 0...1 {
                    let dx = (Double(xIndex) - 0.5 - offsetX) * self.width
                    let dy = (Double(yIndex) - 0.5 + offsetY) * self.height
                    let sourceDX = (cosine * dx + sine * dy) / self.width
                    let sourceDY = (-sine * dx + cosine * dy) / self.height
                    coveredScale = max(
                        coveredScale,
                        sourceDX >= 0 ? sourceDX / (1 - centerX) : -sourceDX / centerX,
                        sourceDY >= 0 ? sourceDY / centerY : -sourceDY / (1 - centerY)
                    )
                }
            }
            // Half a source pixel of guard avoids a transparent seam from CI's
            // bilinear interpolation at an otherwise exactly covered corner.
            coveredScale += 0.5 / min(self.width, self.height)
        }
        effectiveScale = coveredScale

        let a = coveredScale * cosine
        let b = coveredScale * sine
        let c = -coveredScale * sine
        let d = coveredScale * cosine
        let sourceCX = centerX * self.width
        let sourceCY = (1 - centerY) * self.height
        affineTransform = CGAffineTransform(
            a: CGFloat(a), b: CGFloat(b), c: CGFloat(c), d: CGFloat(d),
            tx: CGFloat(self.width * (0.5 + offsetX) - a * sourceCX - c * sourceCY),
            ty: CGFloat(self.height * (0.5 - offsetY) - b * sourceCX - d * sourceCY)
        )
    }

    /// Map top-left normalized source coordinates into the visible frame.
    /// The cursor hotspot and click feedback must use this exact same matrix.
    public func mappedPoint(x: Double, y: Double) -> CGPoint {
        let output = CGPoint(x: CGFloat(x * width), y: CGFloat((1 - y) * height))
            .applying(affineTransform)
        return CGPoint(x: output.x / CGFloat(width), y: 1 - output.y / CGFloat(height))
    }
}
