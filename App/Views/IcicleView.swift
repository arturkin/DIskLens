import SwiftUI
import DiskLensCore

/// Icicle chart: horizontal bands per depth, width ∝ size, nested under parents.
struct IcicleView: View {
    let focus: FileNode
    var hovered: FileNode?
    /// When set, overrides palette coloring (used for delta tinting in compare mode).
    var colorOverride: ((FileNode?) -> Color)?
    var onHover: (FileNode?) -> Void
    var onSelect: (FileNode) -> Void

    @State private var hover: ChartHoverHit?

    var body: some View {
        GeometryReader { geo in
            let tiles = IcicleLayout.tiles(focus: focus)
            let colors = IcicleColors.map(for: tiles)
            let depthCount = max(1, tiles.map(\.depth).max() ?? 1)
            let bandH = geo.size.height / CGFloat(depthCount)
            let W = geo.size.width

            Canvas { ctx, _ in
                let hoveredID = hovered.map(ObjectIdentifier.init)
                for tile in tiles {
                    let rect = CGRect(
                        x: tile.x * W,
                        y: CGFloat(tile.depth - 1) * bandH,
                        width: tile.width * W,
                        height: bandH)
                    let path = Path(rect.insetBy(dx: 0.5, dy: 0.75))
                    let base = colorOverride?(tile.node) ?? colors[tile.id] ?? .gray
                    let isHovered = tile.node.map { ObjectIdentifier($0) == hoveredID } ?? false
                    ctx.fill(path, with: .color(base.opacity(isHovered ? 1.0 : 0.92)))
                    ctx.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor)),
                               lineWidth: isHovered ? 1.5 : 0.5)

                    if rect.width > 40 {
                        ctx.draw(
                            Text(tile.node?.name ?? "Other").font(.system(size: 10)).foregroundStyle(.white),
                            at: CGPoint(x: rect.minX + 4, y: rect.midY),
                            anchor: .leading)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let node = hitTest(p, tiles, bandH: bandH, width: W)?.node
                    onHover(node)
                    hover = node.map { ChartHoverHit(node: $0, point: p) }
                case .ended:
                    onHover(nil)
                    hover = nil
                }
            }
            .chartTooltip(hover, bounds: geo.size, focus: focus)
            .gesture(SpatialTapGesture().onEnded { value in
                if let node = hitTest(value.location, tiles, bandH: bandH, width: W)?.node {
                    onSelect(node)
                }
            })
        }
    }

    private func hitTest(_ p: CGPoint, _ tiles: [IcicleTile], bandH: CGFloat, width: CGFloat) -> IcicleTile? {
        guard bandH > 0 else { return nil }
        let depth = Int(p.y / bandH) + 1
        let fx = p.x / width
        return tiles.first { $0.depth == depth && fx >= $0.x && fx < $0.x + $0.width }
    }
}
