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
struct ChartTooltip: View {
    let node: FileNode
    let point: CGPoint
    let bounds: CGSize
    /// Current focus node, for the "% of view" share.
    var focus: FileNode?

    @State private var cardSize: CGSize = .zero

    var body: some View {
        card
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: TooltipSizeKey.self, value: g.size)
                }
            )
            .onPreferenceChange(TooltipSizeKey.self) { cardSize = $0 }
            .position(position)
            .opacity(cardSize == .zero ? 0 : 1)   // hide for the one frame before we know our size
            .allowsHitTesting(false)               // clicks/hover pass through to the chart
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: NodeIcon.symbol(for: node)).foregroundStyle(.secondary)
                Text(node.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 5) {
                Text(Format.bytes(node.sizeOnDisk))
                if let focus, focus.sizeOnDisk > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(Format.percent(Double(node.sizeOnDisk) / Double(focus.sizeOnDisk)))
                }
                if node.isDirectory {
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(Format.count(Int(node.fileCount))) files")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(radius: 6, y: 2)
    }

    /// Place the card down-right of the cursor, flipping to the other side when
    /// it would overflow, then clamp fully inside the chart bounds.
    private var position: CGPoint {
        let w = cardSize.width, h = cardSize.height
        let pad: CGFloat = 8, gap: CGFloat = 14

        var cx = point.x + gap + w / 2
        if cx + w / 2 > bounds.width - pad { cx = point.x - gap - w / 2 }
        var cy = point.y + gap + h / 2
        if cy + h / 2 > bounds.height - pad { cy = point.y - gap - h / 2 }

        let minX = pad + w / 2, maxX = max(minX, bounds.width - pad - w / 2)
        let minY = pad + h / 2, maxY = max(minY, bounds.height - pad - h / 2)
        return CGPoint(x: min(max(cx, minX), maxX), y: min(max(cy, minY), maxY))
    }
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

private struct TooltipSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
