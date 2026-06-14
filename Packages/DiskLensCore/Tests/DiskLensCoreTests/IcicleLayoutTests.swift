import Foundation
import Testing
@testable import DiskLensCore

struct IcicleLayoutTests {
    private func dir(_ name: String, _ children: [FileNode]) -> FileNode {
        let size = children.reduce(0) { $0 + $1.sizeOnDisk }
        return FileNode(name: name, isDirectory: true, sizeOnDisk: size, logicalSize: size,
                        modified: nil, fileCount: Int32(children.count), children: children)
    }
    private func file(_ name: String, _ size: Int64) -> FileNode {
        FileNode(name: name, isDirectory: false, sizeOnDisk: size, logicalSize: size,
                 modified: nil, fileCount: 1)
    }

    @Test("depth-1 tiles partition the full [0,1] width proportionally")
    func levelOne() {
        let focus = dir("root", [file("a", 3000), file("b", 1000)])
        let level1 = IcicleLayout.tiles(focus: focus).filter { $0.depth == 1 }
        #expect(level1.count == 2)
        #expect(abs(level1[0].x - 0) < 1e-9)
        let total = level1.reduce(0.0) { $0 + $1.width }
        #expect(abs(total - 1.0) < 1e-9)
        #expect(abs(level1[0].width - 0.75) < 1e-9)
    }

    @Test("child tiles nest within their parent's x-range")
    func nesting() {
        let a = dir("a", [file("a1", 500), file("a2", 500)])
        let focus = dir("root", [a, file("b", 1000)])
        let tiles = IcicleLayout.tiles(focus: focus)
        let parent = tiles.first { $0.depth == 1 && $0.node?.name == "a" }!
        for kid in tiles.filter({ $0.depth == 2 }) {
            #expect(kid.x >= parent.x - 1e-9)
            #expect(kid.x + kid.width <= parent.x + parent.width + 1e-9)
        }
    }
}
