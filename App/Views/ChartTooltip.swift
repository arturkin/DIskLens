import SwiftUI
import DiskLensCore

/// A hovered node plus the cursor location inside the chart that produced it.
/// Chart views track this locally and hand it to `.chartTooltip(…)`.
struct ChartHoverHit {
    let node: FileNode
    let point: CGPoint
}

/// Floating, cursor-following tooltip that shows exactly which node is under the
/// pointer — name, size, share of the current view, and (for folders) file
/// count — so it's clear what a click would select. Never intercepts events.
///
/// **Readability:** it paints a fixed dark surface with bright white text
/// (DaisyDisk-style) rather than a translucent material, so the label stays
/// high-contrast over any wedge colour and in either app theme — a translucent
/// material let vivid wedges (e.g. a bright-green folder) bleed through and
/// washed the text out.
///
/// **Placement:** the card hugs the cursor — its near corner sits a few points
/// down-and-right of the pointer (flipping sides near an edge), then clamps
/// inside the chart. It measures its own size for placement but is **always**
/// rendered: size is only an offset input, never a visibility gate (gating on a
/// not-yet-settled measured size is what made an earlier version invisible).
struct ChartTooltip: View {
    let node: FileNode
    let point: CGPoint
    let bounds: CGSize
    /// Current focus node, for the "% of view" share.
    var focus: FileNode?

    /// Conservative card extents used for the first frame (before the real size
    /// is measured) and as the fallback if measurement never settles.
    static let clampWidth: CGFloat = 280
    static let clampHeight: CGFloat = 58

    /// Fixed colours (sRGB components) — defined numerically so the contrast can
    /// be unit-tested and so the surface is opaque enough that wedge colour
    /// never bleeds through.
    static let surfaceRGB: (Double, Double, Double) = (0.13, 0.13, 0.15)
    static let titleRGB: (Double, Double, Double) = (1, 1, 1)
    static let detailRGB: (Double, Double, Double) = (0.85, 0.86, 0.90)
    static let surfaceOpacity: Double = 0.97

    @State private var measured = CGSize(width: ChartTooltip.clampWidth,
                                         height: ChartTooltip.clampHeight)

    var body: some View {
        card
            .background(GeometryReader { g in
                Color.clear.preference(key: TooltipSizeKey.self, value: g.size)
            })
            .onPreferenceChange(TooltipSizeKey.self) { measured = $0 }
            .offset(offset(for: measured))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)   // clicks/hover pass through to the chart
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: NodeIcon.symbol(for: node))
                    .foregroundStyle(Self.color(Self.detailRGB))
                Text(displayName)
                    .fontWeight(.semibold).lineLimit(1)
                    .foregroundStyle(Self.color(Self.titleRGB))
            }
            HStack(spacing: 5) {
                Text(Format.bytes(node.sizeOnDisk))
                if let focus, focus.sizeOnDisk > 0 {
                    Text("·").opacity(0.5)
                    Text(Format.percent(Double(node.sizeOnDisk) / Double(focus.sizeOnDisk)))
                }
                if node.isDirectory {
                    Text("·").opacity(0.5)
                    Text("\(Format.count(Int(node.fileCount))) files")
                }
            }
            .font(.caption)
            .foregroundStyle(Self.color(Self.detailRGB))
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Self.color(Self.surfaceRGB, Self.surfaceOpacity),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 7, y: 2)
        .fixedSize()
    }

    private func offset(for size: CGSize) -> CGSize {
        let o = Self.origin(point: point, bounds: bounds, size: size)
        return CGSize(width: o.x, height: o.y)
    }

    /// Middle-truncates very long names so the card stays within `clampWidth`.
    private var displayName: String {
        let n = node.name
        guard n.count > 40 else { return n }
        return "\(n.prefix(24))…\(n.suffix(13))"
    }

    private static func color(_ rgb: (Double, Double, Double), _ opacity: Double = 1) -> Color {
        Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2, opacity: opacity)
    }

    /// Top-left corner of the card: a small `gap` down-and-right of the cursor,
    /// flipping to the other side when it would overflow, then clamped fully
    /// inside the chart bounds. Pure, so it can be unit-tested.
    static func origin(point: CGPoint, bounds: CGSize, size: CGSize) -> CGPoint {
        let w = size.width, h = size.height
        let pad: CGFloat = 6, gap: CGFloat = 6

        var x = point.x + gap
        if x + w > bounds.width - pad { x = point.x - gap - w }   // flip left
        var y = point.y + gap
        if y + h > bounds.height - pad { y = point.y - gap - h }   // flip up

        let maxX = max(pad, bounds.width - pad - w)
        let maxY = max(pad, bounds.height - pad - h)
        return CGPoint(x: min(max(x, pad), maxX), y: min(max(y, pad), maxY))
    }

    // MARK: WCAG contrast (for tests + design intent)

    /// Relative luminance of an sRGB colour, per WCAG 2.x.
    static func relativeLuminance(_ rgb: (Double, Double, Double)) -> Double {
        func lin(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(rgb.0) + 0.7152 * lin(rgb.1) + 0.0722 * lin(rgb.2)
    }

    /// WCAG contrast ratio between two sRGB colours (1…21).
    static func contrastRatio(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

private struct TooltipSizeKey: PreferenceKey {
    // Literals (not ChartTooltip.clamp*) — this nonisolated context can't read
    // the main-actor-isolated View statics. Kept in sync with them.
    static let defaultValue = CGSize(width: 280, height: 58)
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

extension View {
    /// Overlays a `ChartTooltip` at the hovered point, if any. Apply to a chart's
    /// canvas; `bounds` is the canvas size (its `GeometryReader` size).
    func chartTooltip(_ hit: ChartHoverHit?, bounds: CGSize, focus: FileNode?) -> some View {
        overlay {
            if let hit {
                ChartTooltip(node: hit.node, point: hit.point, bounds: bounds, focus: focus)
            }
        }
    }
}
