import Foundation
import Testing
@testable import DiskLensCore

struct TreemapLayoutTests {
    private func dir(_ name: String, _ children: [FileNode]) -> FileNode {
        let size = children.reduce(0) { $0 + $1.sizeOnDisk }
        return FileNode(name: name, isDirectory: true, sizeOnDisk: size, logicalSize: size,
                        modified: nil, fileCount: Int32(children.count), children: children)
    }
    private func file(_ name: String, _ size: Int64) -> FileNode {
        FileNode(name: name, isDirectory: false, sizeOnDisk: size, logicalSize: size,
                 modified: nil, fileCount: 1)
    }
    private let bounds = TreemapRect(x: 0, y: 0, width: 100, height: 100)

    @Test("one level tiles the bounds with areas proportional to size")
    func levelOneCoverage() {
        let focus = dir("root", [file("a", 4000), file("b", 3000), file("c", 2000), file("d", 1000)])
        let tiles = TreemapLayout.tiles(focus: focus, in: bounds, maxDepth: 1, inset: 0)

        #expect(tiles.count == 4)
        let totalArea = tiles.reduce(0.0) { $0 + $1.rect.area }
        #expect(abs(totalArea - bounds.area) < 1.0)   // tiles cover the bounds

        // Areas are proportional to sizes (a is 4x d).
        let a = tiles.first { $0.node?.name == "a" }!
        let d = tiles.first { $0.node?.name == "d" }!
        #expect(abs(a.rect.area / d.rect.area - 4.0) < 0.05)
    }

    @Test("tiles stay within the bounds")
    func withinBounds() {
        let focus = dir("root", (1...8).map { file("f\($0)", Int64($0 * 100)) })
        let tiles = TreemapLayout.tiles(focus: focus, in: bounds, maxDepth: 1, inset: 0)
        for t in tiles {
            #expect(t.rect.x >= -0.001)
            #expect(t.rect.y >= -0.001)
            #expect(t.rect.x + t.rect.width <= bounds.width + 0.01)
            #expect(t.rect.y + t.rect.height <= bounds.height + 0.01)
            #expect(t.rect.width > 0)
            #expect(t.rect.height > 0)
        }
    }

    @Test("aspect ratios are reasonable (squarified, not slivers)")
    func aspectRatios() {
        let focus = dir("root", (1...10).map { file("f\($0)", Int64(100 + $0)) })  // near-equal
        let tiles = TreemapLayout.tiles(focus: focus, in: bounds, maxDepth: 1, inset: 0)
        for t in tiles {
            let ratio = max(t.rect.width, t.rect.height) / min(t.rect.width, t.rect.height)
            #expect(ratio < 6.0)   // squarified keeps these well below slice-and-dice extremes
        }
    }

    @Test("nested tiles sit inside their parent tile")
    func nesting() {
        let inner = dir("inner", [file("x", 600), file("y", 400)])
        let focus = dir("root", [inner, file("solo", 1000)])
        let tiles = TreemapLayout.tiles(focus: focus, in: bounds, maxDepth: 2, inset: 2)

        let parent = tiles.first { $0.node?.name == "inner" && $0.depth == 1 }!
        let kids = tiles.filter { $0.depth == 2 }
        #expect(kids.count == 2)
        for k in kids {
            #expect(k.rect.x >= parent.rect.x - 0.001)
            #expect(k.rect.y >= parent.rect.y - 0.001)
            #expect(k.rect.x + k.rect.width <= parent.rect.x + parent.rect.width + 0.001)
            #expect(k.rect.y + k.rect.height <= parent.rect.y + parent.rect.height + 0.001)
        }
    }

    @Test("tiny tiles fold into one Other tile")
    func otherAggregation() {
        var kids: [FileNode] = [file("big", 100_000)]
        for i in 0..<100 { kids.append(file("t\(i)", 10)) }
        let focus = dir("root", kids)
        let tiles = TreemapLayout.tiles(focus: focus, in: bounds, maxDepth: 1, minFraction: 0.01, inset: 0)

        #expect(tiles.filter(\.isOther).count == 1)
        #expect(tiles.contains { $0.node?.name == "big" })
        #expect(!tiles.contains { $0.node?.name == "t0" })
    }
}
