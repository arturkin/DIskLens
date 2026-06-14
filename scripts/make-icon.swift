import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Renders the DiskLens app-icon master (1024×1024 PNG): a sunburst donut — the
// app's signature chart — on a dark, macOS-style rounded-rect body. Colors are
// the app's ChartPalette hues, so the icon stays on-brand with the live charts.
//
// Usage: swift scripts/make-icon.swift [output.png]   (default: /tmp/diskicon_1024.png)
// Prefer `scripts/make-icon.sh`, which also downscales into the .appiconset.

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/diskicon_1024.png"

let S = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

let cx: CGFloat = 512, cy: CGFloat = 512

// ChartPalette hues (verbatim) — keeps the icon on-brand with the live charts.
let hues: [Double] = [0.58, 0.33, 0.08, 0.78, 0.92, 0.50, 0.15, 0.00, 0.45, 0.67, 0.86, 0.25]

func paletteColor(hue: Double, depth: Int) -> CGColor {
    let sat = max(0.28, 0.72 - Double(depth - 1) * 0.10)
    let bri = min(0.96, 0.68 + Double(depth - 1) * 0.06)
    return NSColor(hue: CGFloat(hue), saturation: CGFloat(sat),
                   brightness: CGFloat(bri), alpha: 1).usingColorSpace(.sRGB)!.cgColor
}
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
}

// MARK: rounded-rect body clip (Apple macOS grid: 824 body, r≈185.4, 100 margin)
let margin: CGFloat = 100
let body = CGRect(x: margin, y: margin, width: CGFloat(S) - 2*margin, height: CGFloat(S) - 2*margin)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()

// Background: vertical gradient (lighter slate at top → deep navy at bottom).
let bg = CGGradient(colorsSpace: cs,
                    colors: [rgb(0.07, 0.08, 0.13), rgb(0.22, 0.25, 0.34)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.minY),
                       end: CGPoint(x: 0, y: body.maxY), options: [])
// Soft top sheen.
let sheen = CGGradient(colorsSpace: cs,
                       colors: [rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: cx, y: body.maxY - 40), startRadius: 0,
                       endCenter: CGPoint(x: cx, y: body.maxY - 40), endRadius: 560, options: [])

// MARK: sunburst geometry
let hole: CGFloat = 150
let r1i: CGFloat = 150, r1o: CGFloat = 268
let r2i: CGFloat = 276, r2o: CGFloat = 372
let dark = rgb(0.04, 0.05, 0.09)        // gap backing + shadow caster

// Drop shadow cast by one solid annulus (later fully covered by segments, so
// only its soft shadow shows — and the gaps reveal this dark backing).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34,
              color: NSColor.black.withAlphaComponent(0.55).cgColor)
let annulus = CGMutablePath()
annulus.addEllipse(in: CGRect(x: cx - r2o, y: cy - r2o, width: 2*r2o, height: 2*r2o))
annulus.addEllipse(in: CGRect(x: cx - hole, y: cy - hole, width: 2*hole, height: 2*hole))
ctx.addPath(annulus)
ctx.setFillColor(dark)
ctx.fillPath(using: .evenOdd)
ctx.restoreGState()

// Annular-sector wedge. Angles measured clockwise from top, in turns [0,1).
func wedge(_ innerR: CGFloat, _ outerR: CGFloat, _ startTurn: Double, _ endTurn: Double,
           gapDeg: Double, color: CGColor) {
    let gap = gapDeg * .pi / 180
    let a0 = CGFloat(.pi/2 - startTurn * 2 * .pi) - CGFloat(gap)/2
    let a1 = CGFloat(.pi/2 - endTurn   * 2 * .pi) + CGFloat(gap)/2
    let p = CGMutablePath()
    p.addArc(center: CGPoint(x: cx, y: cy), radius: outerR, startAngle: a0, endAngle: a1, clockwise: true)
    p.addArc(center: CGPoint(x: cx, y: cy), radius: innerR, startAngle: a1, endAngle: a0, clockwise: false)
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(color)
    ctx.fillPath()
}

// Inner ring: organic segment sizes; each subdivides into outer children.
let ring1: [Double] = [0.22, 0.17, 0.14, 0.13, 0.12, 0.12, 0.10]
let children: [[Double]] = [
    [0.55, 0.45], [0.60, 0.40], [1.0], [0.50, 0.30, 0.20], [0.70, 0.30], [1.0], [0.60, 0.40],
]

var cursor = 0.0
for (i, frac) in ring1.enumerated() {
    let start = cursor, end = cursor + frac
    wedge(r1i, r1o, start, end, gapDeg: 1.8, color: paletteColor(hue: hues[i], depth: 1))
    var sub = start
    for childFrac in children[i] {
        let cEnd = sub + childFrac * frac
        wedge(r2i, r2o, sub, cEnd, gapDeg: 1.2, color: paletteColor(hue: hues[i], depth: 2))
        sub = cEnd
    }
    cursor = end
}

// Faint lens glint inside the hole.
let glint = CGGradient(colorsSpace: cs,
                       colors: [rgb(1, 1, 1, 0.16), rgb(1, 1, 1, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawRadialGradient(glint, startCenter: CGPoint(x: cx - 36, y: cy + 36), startRadius: 0,
                       endCenter: CGPoint(x: cx, y: cy), endRadius: hole, options: [])

ctx.restoreGState() // body clip

// MARK: write PNG
let img = ctx.makeImage()!
let url = URL(fileURLWithPath: outPath)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(url.path)")
