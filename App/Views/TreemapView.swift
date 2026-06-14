import SwiftUI
import DiskLensCore

/// Squarified treemap: nested rectangles, area ∝ size. Hover highlights, click
/// drills into a directory.
struct TreemapView: View {
    let focus: FileNode
    var hovered: FileNode?
    var onHover: (FileNode?) -> Void
    var onSelect: (FileNode) -> Void

    var body: some View {
        GeometryReader { geo in
            let bounds = TreemapRect(x: 0, y: 0, width: geo.size.width, height: geo.size.height)
            let tiles = TreemapLayout.tiles(focus: focus, in: bounds)
            let colors = TreemapColors.map(for: tiles)

            Canvas { ctx, _ in
                let hoveredID = hovered.map(ObjectIdentifier.init)
                for tile in tiles {
                    let rect = CGRect(x: tile.rect.x, y: tile.rect.y,
                                      width: tile.rect.width, height: tile.rect.height)
                    let path = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2)
                    let base = colors[tile.id] ?? .gray
                    let isHovered = tile.node.map { ObjectIdentifier($0) == hoveredID } ?? false
                    ctx.fill(path, with: .color(base.opacity(isHovered ? 1.0 : 0.92)))
                    ctx.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor)),
                               lineWidth: isHovered ? 2 : 0.5)

                    if rect.width > 44, rect.height > 15 {
                        let label = tile.node?.name ?? "Other"
                        ctx.draw(
                            Text(label).font(.system(size: 10)).foregroundStyle(.white),
                            at: CGPoint(x: rect.minX + 4, y: rect.minY + 3),
                            anchor: .topLeading)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): onHover(hitTest(p, tiles)?.node)
                case .ended: onHover(nil)
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if let node = hitTest(value.location, tiles)?.node { onSelect(node) }
            })
        }
    }

    /// Deepest tile under the point (innermost rectangle wins).
    private func hitTest(_ p: CGPoint, _ tiles: [TreemapTile]) -> TreemapTile? {
        tiles
            .filter {
                p.x >= $0.rect.x && p.x <= $0.rect.x + $0.rect.width &&
                p.y >= $0.rect.y && p.y <= $0.rect.y + $0.rect.height
            }
            .max { $0.depth < $1.depth }
    }
}
