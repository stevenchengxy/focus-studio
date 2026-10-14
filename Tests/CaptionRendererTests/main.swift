import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import FocusStudioCore

@main
struct CaptionRendererTests {
    static func main() throws {
        var failures: [String] = []
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        let english = "Turn your everyday workflow into a clear product story. Show the important details, explain each step, and share a polished demo that people understand."
        let chinese = String((String(repeating: "打开工作台查看所有项目，点击卡片了解详情，并将重要的数据与团队分享。", count: 6)).prefix(150))
        let canvases = [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)]
        let samples = [("english", english), ("chinese", chinese), ("mixed", "工作流 👩🏽‍💻 — " + english),
                       ("url", "https://example.com/" + String(repeating: "feature", count: 22))]
        for canvas in canvases {
            for (label, text) in samples {
                let name = "\(label) \(Int(canvas.width))×\(Int(canvas.height))"
                guard let layout = CaptionRenderer.layout(text: text, number: 12, canvasSize: canvas, style: CaptionStyle()),
                      let artwork = CaptionRenderer.artwork(text: text, number: 12, canvasSize: canvas, style: CaptionStyle()) else {
                    failures.append("\(name) did not render its full text")
                    continue
                }
                expect(layout.lines.count > 1, "\(name) must wrap instead of truncate")
                expect(layout.lines.count <= CaptionRenderer.maximumLineCount, "\(name) stays within line limit")
                expect(artwork.size.width <= canvas.width * 0.8 && artwork.size.height <= canvas.height * 0.26,
                       "\(name) fits the complete safe area including stroke")
                expect(layout.fontSize >= canvas.height * 0.024 * 0.72, "\(name) remains readable")
                let string = layout.text as NSString
                let reconstructed = layout.lines.map { string.substring(with: NSRange(location: $0.range.location, length: $0.range.length)) }.joined()
                expect(reconstructed == CaptionRenderer.singleLine(text), "\(name) retains every character in order")
                expect(zip(layout.lines, layout.lines.dropFirst()).allSatisfy { $0.range.location + $0.range.length == $1.range.location },
                       "\(name) has no skipped or duplicated UTF-16 ranges")
                expect(CaptionRenderer.canRenderFullText(text: text, number: 12, canvasSize: canvas, style: CaptionStyle()),
                       "\(name) preflight matches rendered layout")
                if label == "chinese" || label == "english" {
                    let url = URL(fileURLWithPath: "/tmp/focus-caption-\(label)-\(Int(canvas.width)).png")
                    let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                                            bytesPerRow: Int(canvas.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.setFillColor(CGColor(red: 0.13, green: 0.15, blue: 0.21, alpha: 1))
                    context.fill(CGRect(origin: .zero, size: canvas))
                    context.draw(artwork.image, in: CGRect(x: (canvas.width - artwork.size.width) / 2, y: canvas.height * 0.06,
                                                          width: artwork.size.width, height: artwork.size.height))
                    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
                    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
                    expect(CGImageDestinationFinalize(destination), "\(name) reference image writes")
                }
            }
        }
        let portrait = CGSize(width: 1080, height: 1920)
        expect(!CaptionRenderer.canRenderFullText(text: String(repeating: "界", count: 240), number: 1,
                                                 canvasSize: portrait, style: CaptionStyle(scale: 1.6)),
               "oversized portrait captions fail preflight instead of losing text")
        let manualFallback = CaptionRenderer.artwork(text: String(repeating: "界", count: 240), number: 1,
                                                    canvasSize: portrait, style: CaptionStyle(scale: 1.6))
        expect(manualFallback != nil && manualFallback!.size.width <= portrait.width * 0.8
               && manualFallback!.size.height <= portrait.height * 0.26,
               "older/manual oversized captions retain a bounded visible ellipsis fallback")
        expect(CaptionRenderer.layout(text: String(repeating: "界", count: 4097), number: nil,
                                      canvasSize: portrait, style: CaptionStyle()) == nil,
               "pathological full-text input is bounded")
        expect(CaptionRenderer.artwork(text: String(repeating: "界", count: 4097), number: nil,
                                       canvasSize: portrait, style: CaptionStyle()) != nil,
               "an oversized old caption remains visible through the compatibility fallback")
        expect(CaptionRenderer.artwork(text: " \n\t ", number: nil, canvasSize: portrait, style: CaptionStyle()) == nil,
               "empty input produces no artwork")
        expect(CaptionRenderer.artwork(text: "Hello", number: nil, canvasSize: CGSize(width: CGFloat.nan, height: 1080), style: CaptionStyle()) == nil,
               "nonfinite canvas is rejected")
        if failures.isEmpty {
            print("Caption renderer: \(checks) checks passed (English \(english.count) characters; Chinese \(chinese.count) characters).")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            exit(1)
        }
    }
}
