import SwiftUI
import DiskLensCore

/// Shared coloring for all hierarchy charts: a base hue per top-level branch,
/// lightened with depth; aggregated "Other" slices are neutral gray.
enum ChartPalette {
    static let hues: [Double] = [
        0.58, 0.33, 0.08, 0.78, 0.92, 0.50, 0.15, 0.00, 0.45, 0.67, 0.86, 0.25
    ]

    static func hue(_ index: Int) -> Double {
        hues[((index % hues.count) + hues.count) % hues.count]
    }

    /// `hue < 0` => the neutral "Other" color.
    static func color(hue: Double, depth: Int) -> Color {
        if hue < 0 {
            return Color(white: max(0.32, 0.56 - Double(depth - 1) * 0.05))
        }
        let saturation = max(0.28, 0.72 - Double(depth - 1) * 0.10)
        let brightness = min(0.96, 0.68 + Double(depth - 1) * 0.06)
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

enum SunburstColors {
    static func map(for segments: [SunburstSegment]) -> [Int: Color] {
        var result: [Int: Color] = [:]
        var ring1: [(start: Double, end: Double, hue: Double)] = []

        for (i, seg) in segments.filter({ $0.depth == 1 }).enumerated() {
            let hue = seg.isOther ? -1 : ChartPalette.hue(i)
            ring1.append((seg.startAngle, seg.endAngle, hue))
            result[seg.id] = ChartPalette.color(hue: hue, depth: 1)
        }
        for seg in segments where seg.depth > 1 {
            let mid = (seg.startAngle + seg.endAngle) / 2
            let hue = seg.isOther ? -1 : (ring1.first { mid >= $0.start && mid < $0.end }?.hue ?? -1)
            result[seg.id] = ChartPalette.color(hue: hue, depth: seg.depth)
        }
        return result
    }
}

enum TreemapColors {
    static func map(for tiles: [TreemapTile]) -> [Int: Color] {
        var result: [Int: Color] = [:]
        var ring1: [(rect: TreemapRect, hue: Double)] = []

        for (i, tile) in tiles.filter({ $0.depth == 1 }).enumerated() {
            let hue = tile.isOther ? -1 : ChartPalette.hue(i)
            ring1.append((tile.rect, hue))
            result[tile.id] = ChartPalette.color(hue: hue, depth: 1)
        }
        for tile in tiles where tile.depth > 1 {
            let cx = tile.rect.x + tile.rect.width / 2
            let cy = tile.rect.y + tile.rect.height / 2
            let hue = tile.isOther ? -1 : (ring1.first {
                cx >= $0.rect.x && cx <= $0.rect.x + $0.rect.width &&
                cy >= $0.rect.y && cy <= $0.rect.y + $0.rect.height
            }?.hue ?? -1)
            result[tile.id] = ChartPalette.color(hue: hue, depth: tile.depth)
        }
        return result
    }
}

enum IcicleColors {
    static func map(for tiles: [IcicleTile]) -> [Int: Color] {
        var result: [Int: Color] = [:]
        var ring1: [(start: Double, end: Double, hue: Double)] = []

        for (i, tile) in tiles.filter({ $0.depth == 1 }).enumerated() {
            let hue = tile.isOther ? -1 : ChartPalette.hue(i)
            ring1.append((tile.x, tile.x + tile.width, hue))
            result[tile.id] = ChartPalette.color(hue: hue, depth: 1)
        }
        for tile in tiles where tile.depth > 1 {
            let mid = tile.x + tile.width / 2
            let hue = tile.isOther ? -1 : (ring1.first { mid >= $0.start && mid < $0.end }?.hue ?? -1)
            result[tile.id] = ChartPalette.color(hue: hue, depth: tile.depth)
        }
        return result
    }
}
