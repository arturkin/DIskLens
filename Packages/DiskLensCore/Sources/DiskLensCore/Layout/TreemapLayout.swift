import Foundation

public struct TreemapRect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var area: Double { width * height }
}

/// One rectangle in a treemap.
public struct TreemapTile: Sendable, Identifiable {
    public let id: Int
    public let depth: Int          // 1 = top level (focus's children)
    public let rect: TreemapRect
    public let node: FileNode?     // nil for an aggregated "Other" tile
    public let sizeOnDisk: Int64

    public var isOther: Bool { node == nil }
}

/// Pure squarified treemap layout (Bruls, Huizing, van Wijk).
///
/// Lays the focus node's children into `bounds` with near-square aspect ratios,
/// recursing into directories (each inset to leave room for a parent border)
/// up to `maxDepth`. Tiles smaller than `minFraction` of the focus total are
/// folded into one "Other" tile per level.
public enum TreemapLayout {
    public static func tiles(
        focus: FileNode,
        in bounds: TreemapRect,
        maxDepth: Int = 4,
        minFraction: Double = 0.002,
        inset: Double = 3
    ) -> [TreemapTile] {
        var result: [TreemapTile] = []
        var nextID = 0
        let minSize = Double(max(focus.sizeOnDisk, 1)) * minFraction

        func layout(_ parent: FileNode, in rect: TreemapRect, depth: Int) {
            guard depth <= maxDepth, rect.width > 0.5, rect.height > 0.5 else { return }

            // Build the item list, folding tiny children into one "Other".
            var items: [(node: FileNode?, size: Int64)] = []
            var otherSize: Int64 = 0
            for child in parent.children where child.sizeOnDisk > 0 {
                if Double(child.sizeOnDisk) < minSize {
                    otherSize += child.sizeOnDisk
                } else {
                    items.append((child, child.sizeOnDisk))
                }
            }
            if otherSize > 0 { items.append((nil, otherSize)) }
            items.sort { $0.size > $1.size }
            guard !items.isEmpty else { return }

            for placed in squarify(items, in: rect) {
                let tile = TreemapTile(
                    id: nextID, depth: depth, rect: placed.rect,
                    node: placed.item.node, sizeOnDisk: placed.item.size)
                nextID += 1
                result.append(tile)

                if let node = placed.item.node, node.isDirectory, !node.children.isEmpty,
                   depth < maxDepth {
                    let inner = insetRect(placed.rect, by: inset)
                    if inner.width > 1, inner.height > 1 {
                        layout(node, in: inner, depth: depth + 1)
                    }
                }
            }
        }

        layout(focus, in: bounds, depth: 1)
        return result
    }

    // MARK: - Squarify

    private struct Item { let node: FileNode?; let size: Int64; let area: Double }
    private struct Placed { let item: (node: FileNode?, size: Int64); let rect: TreemapRect }

    private static func squarify(_ items: [(node: FileNode?, size: Int64)], in rect: TreemapRect) -> [Placed] {
        let total = items.reduce(0.0) { $0 + Double($1.size) }
        guard total > 0 else { return [] }
        let scale = rect.area / total
        var remaining = items.map { Item(node: $0.node, size: $0.size, area: Double($0.size) * scale) }

        var placed: [Placed] = []
        var free = rect

        while !remaining.isEmpty {
            let side = min(free.width, free.height)
            var row: [Item] = [remaining[0]]
            var rest = Array(remaining.dropFirst())
            while let head = rest.first,
                  worstRatio(row + [head], side: side) <= worstRatio(row, side: side) {
                row.append(head)
                rest.removeFirst()
            }
            placed.append(contentsOf: placeRow(row, in: &free))
            remaining = rest
        }
        return placed
    }

    private static func worstRatio(_ row: [Item], side: Double) -> Double {
        let areas = row.map(\.area)
        let sum = areas.reduce(0, +)
        guard let mn = areas.min(), let mx = areas.max(), sum > 0, mn > 0, side > 0 else { return .infinity }
        let sum2 = sum * sum
        let side2 = side * side
        return max(side2 * mx / sum2, sum2 / (side2 * mn))
    }

    private static func placeRow(_ row: [Item], in free: inout TreemapRect) -> [Placed] {
        let rowArea = row.reduce(0.0) { $0 + $1.area }
        var placed: [Placed] = []

        if free.width >= free.height {
            let colW = rowArea / free.height
            var y = free.y
            for item in row {
                let h = item.area / colW
                placed.append(Placed(item: (item.node, item.size),
                                     rect: TreemapRect(x: free.x, y: y, width: colW, height: h)))
                y += h
            }
            free = TreemapRect(x: free.x + colW, y: free.y, width: free.width - colW, height: free.height)
        } else {
            let rowH = rowArea / free.width
            var x = free.x
            for item in row {
                let w = item.area / rowH
                placed.append(Placed(item: (item.node, item.size),
                                     rect: TreemapRect(x: x, y: free.y, width: w, height: rowH)))
                x += w
            }
            free = TreemapRect(x: free.x, y: free.y + rowH, width: free.width, height: free.height - rowH)
        }
        return placed
    }

    private static func insetRect(_ rect: TreemapRect, by inset: Double) -> TreemapRect {
        // Inset all sides; leave a little extra at the top for a parent label band.
        let top = inset + 11
        return TreemapRect(
            x: rect.x + inset,
            y: rect.y + top,
            width: max(0, rect.width - inset * 2),
            height: max(0, rect.height - inset - top)
        )
    }
}
