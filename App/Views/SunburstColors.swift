import SwiftUI
import DiskLensCore

/// Assigns each sunburst segment a color: a base hue per top-level (ring-1)
/// branch, lightened with depth so nested folders read as shades of their parent.
enum SunburstColors {
    private static let hues: [Double] = [
        0.58, 0.33, 0.08, 0.78, 0.92, 0.50, 0.15, 0.00, 0.45, 0.67, 0.86, 0.25
    ]

    static func map(for segments: [SunburstSegment]) -> [Int: Color] {
        var result: [Int: Color] = [:]
        var ring1Ranges: [(start: Double, end: Double, hue: Double)] = []

        let ring1 = segments.filter { $0.depth == 1 }
        for (i, seg) in ring1.enumerated() {
            let hue = seg.isOther ? -1 : hues[i % hues.count]
            ring1Ranges.append((seg.startAngle, seg.endAngle, hue))
            result[seg.id] = color(hue: hue, depth: 1)
        }

        for seg in segments where seg.depth > 1 {
            let mid = (seg.startAngle + seg.endAngle) / 2
            let hue = ring1Ranges.first { mid >= $0.start && mid < $0.end }?.hue ?? -1
            result[seg.id] = color(hue: seg.isOther ? -1 : hue, depth: seg.depth)
        }
        return result
    }

    private static func color(hue: Double, depth: Int) -> Color {
        if hue < 0 {
            // Aggregated "Other" slices: neutral gray, dimming with depth.
            return Color(white: 0.55 - Double(depth - 1) * 0.06)
        }
        let saturation = max(0.30, 0.72 - Double(depth - 1) * 0.10)
        let brightness = min(0.95, 0.70 + Double(depth - 1) * 0.06)
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}
