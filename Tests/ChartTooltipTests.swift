import XCTest
import SwiftUI
import AppKit
import DiskLensCore
@testable import DiskLens

/// Validates the floating hover tooltip actually paints something. The bug it
/// guards against is subtle: the view is *inserted* on hover (the status bar
/// updates fine), but renders fully transparent, so nothing shows. A pure-logic
/// test can't catch that — only rendering can — so these render the real view
/// via `ImageRenderer` and inspect the pixels.
@MainActor
final class ChartTooltipTests: XCTestCase {

    private func sampleNode(name: String = "Photos Library.photoslibrary") -> FileNode {
        FileNode(name: name, isDirectory: true,
                 sizeOnDisk: 1_500_000_000, logicalSize: 1_500_000_000,
                 modified: nil, fileCount: 4231, flags: [], children: [])
    }

    /// The whole point of the feature: hovering shows a visible card. We render
    /// the public `.chartTooltip` overlay (exactly what the charts attach) over a
    /// pure-black host and assert the tooltip introduced non-black pixels.
    func testTooltipPaintsVisiblePixels() throws {
        let side: CGFloat = 360
        let host = Color.black
            .frame(width: side, height: side)
            .chartTooltip(
                ChartHoverHit(node: sampleNode(), point: CGPoint(x: side / 2, y: side / 2)),
                bounds: CGSize(width: side, height: side),
                focus: nil)
            .frame(width: side, height: side)

        let renderer = ImageRenderer(content: host)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")

        XCTAssertTrue(nonBlackPixelCount(image) > 200,
                      "the hover tooltip drew nothing visible over the black host")

        // Set DISKLENS_TOOLTIP_SNAPSHOT=<dir> in the scheme's test environment to
        // dump a PNG for eyeballing.
        if let dir = ProcessInfo.processInfo.environment["DISKLENS_TOOLTIP_SNAPSHOT"] {
            writePNG(image, to: "\(dir)/tooltip.png")
        }
    }

    /// No hover → nothing painted (the overlay must stay empty when hit is nil).
    func testNoTooltipWhenNotHovering() throws {
        let side: CGFloat = 360
        let host = Color.black
            .frame(width: side, height: side)
            .chartTooltip(nil, bounds: CGSize(width: side, height: side), focus: nil)
            .frame(width: side, height: side)

        let renderer = ImageRenderer(content: host)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(nonBlackPixelCount(image), 0, "no tooltip should paint when not hovering")
    }

    /// The tooltip card must never spill outside the chart bounds, wherever the
    /// cursor is — including the corners, where it has to flip sides. `origin`
    /// is the card's top-left corner.
    func testOriginStaysWithinBounds() {
        let bounds = CGSize(width: 300, height: 200)
        let card = CGSize(width: ChartTooltip.clampWidth, height: ChartTooltip.clampHeight)
        let cursors = [
            CGPoint(x: 5, y: 5), CGPoint(x: 295, y: 195),
            CGPoint(x: 150, y: 100), CGPoint(x: 299, y: 0), CGPoint(x: 0, y: 199),
        ]
        for p in cursors {
            let o = ChartTooltip.origin(point: p, bounds: bounds, size: card)
            XCTAssertGreaterThanOrEqual(o.x, -0.5, "left edge clipped at \(p)")
            XCTAssertLessThanOrEqual(o.x + card.width, bounds.width + 0.5, "right edge clipped at \(p)")
            XCTAssertGreaterThanOrEqual(o.y, -0.5, "top edge clipped at \(p)")
            XCTAssertLessThanOrEqual(o.y + card.height, bounds.height + 0.5, "bottom edge clipped at \(p)")
        }
    }

    /// "Closer to the mouse pointer": with room to spare the card sits just
    /// down-and-right of the cursor — its near corner within a few points, not
    /// the ~90pt the old center-based placement left.
    func testTooltipHugsCursor() {
        let bounds = CGSize(width: 1000, height: 1000)
        let card = CGSize(width: 150, height: 44)
        let o = ChartTooltip.origin(point: CGPoint(x: 300, y: 300), bounds: bounds, size: card)
        XCTAssertGreaterThan(o.x, 300, "card should be to the right of the cursor")
        XCTAssertGreaterThan(o.y, 300, "card should be below the cursor")
        XCTAssertLessThanOrEqual(o.x - 300, 12, "card should hug the cursor horizontally")
        XCTAssertLessThanOrEqual(o.y - 300, 12, "card should hug the cursor vertically")
    }

    /// The label must stay readable over any wedge colour. The tooltip uses a
    /// fixed dark surface with bright text; assert the colours meet WCAG
    /// contrast (AAA for the title, AA for the detail line).
    func testTextMeetsContrast() {
        XCTAssertGreaterThanOrEqual(
            ChartTooltip.contrastRatio(ChartTooltip.titleRGB, ChartTooltip.surfaceRGB), 7.0,
            "title text vs surface must meet WCAG AAA (7:1)")
        XCTAssertGreaterThanOrEqual(
            ChartTooltip.contrastRatio(ChartTooltip.detailRGB, ChartTooltip.surfaceRGB), 4.5,
            "detail text vs surface must meet WCAG AA (4.5:1)")
    }

    // MARK: pixel inspection

    /// Number of pixels that are not (near) black, by drawing the image into a
    /// known RGBA buffer and scanning it.
    private func nonBlackPixelCount(_ image: CGImage) -> Int {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var count = 0
        var i = 0
        while i < data.count {
            if data[i] > 24 || data[i + 1] > 24 || data[i + 2] > 24 { count += 1 }
            i += 4
        }
        return count
    }

    private func writePNG(_ image: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
