import Foundation
import Testing
@testable import DiskLensCore

struct SunburstLayoutTests {
    private let twoPi = Double.pi * 2

    private func dir(_ name: String, _ children: [FileNode]) -> FileNode {
        let size = children.reduce(0) { $0 + $1.sizeOnDisk }
        return FileNode(name: name, isDirectory: true, sizeOnDisk: size,
                        logicalSize: size, modified: nil, fileCount: Int32(children.count),
                        children: children)
    }
    private func file(_ name: String, _ size: Int64) -> FileNode {
        FileNode(name: name, isDirectory: false, sizeOnDisk: size, logicalSize: size,
                 modified: nil, fileCount: 1)
    }

    @Test("ring 1 partitions the full circle proportionally to child size")
    func ringOnePartition() {
        let focus = dir("root", [file("a", 3000), file("b", 1000)])
        let segs = SunburstLayout.segments(focus: focus).filter { $0.depth == 1 }

        #expect(segs.count == 2)
        #expect(segs.first?.startAngle == 0)
        #expect(abs((segs.last?.endAngle ?? 0) - twoPi) < 1e-9)
        // Contiguous, no gaps.
        #expect(abs(segs[0].endAngle - segs[1].startAngle) < 1e-9)
        // a is 3/4 of the circle, b is 1/4.
        #expect(abs(segs[0].angularWidth - twoPi * 0.75) < 1e-9)
        #expect(abs(segs[1].angularWidth - twoPi * 0.25) < 1e-9)
    }

    @Test("ring 2 nests within its parent's angular span")
    func ringTwoNesting() {
        let a = dir("a", [file("a1", 500), file("a2", 500)])  // two equal grandkids
        let focus = dir("root", [a, file("b", 1000)])         // a and b equal halves
        let all = SunburstLayout.segments(focus: focus)

        let aSeg = try! #require(all.first { $0.depth == 1 && $0.node?.name == "a" })
        let grandkids = all.filter { $0.depth == 2 }
        #expect(grandkids.count == 2)
        for g in grandkids {
            #expect(g.startAngle >= aSeg.startAngle - 1e-9)
            #expect(g.endAngle <= aSeg.endAngle + 1e-9)
        }
        // The two equal grandkids split a's span in half.
        #expect(abs(grandkids[0].angularWidth - aSeg.angularWidth / 2) < 1e-9)
    }

    @Test("maxDepth limits the number of rings")
    func depthCap() {
        let deep = dir("l1", [dir("l2", [dir("l3", [file("x", 100)])])])
        let focus = dir("root", [deep])
        let segs = SunburstLayout.segments(focus: focus, maxDepth: 2)
        #expect(segs.allSatisfy { $0.depth <= 2 })
        #expect(segs.contains { $0.depth == 2 })
    }

    @Test("slivers below minFraction fold into one Other slice")
    func otherAggregation() {
        var kids: [FileNode] = [file("big", 100)]
        for i in 0..<50 { kids.append(file("t\(i)", 1)) }
        let focus = dir("root", kids)

        let ring1 = SunburstLayout.segments(focus: focus, minFraction: 0.02).filter { $0.depth == 1 }
        let others = ring1.filter(\.isOther)
        #expect(others.count == 1)
        #expect(ring1.contains { $0.node?.name == "big" })
        #expect(!ring1.contains { $0.node?.name == "t0" })   // tiny ones folded away
        // Other carries the summed size of the folded tiny files.
        #expect(others.first?.sizeOnDisk == 50)
        // Full circle still covered.
        let total = ring1.reduce(0.0) { $0 + $1.angularWidth }
        #expect(abs(total - twoPi) < 1e-9)
    }

    @Test("zero-size children are skipped")
    func skipsZero() {
        let focus = dir("root", [file("a", 1000), file("zero", 0)])
        let ring1 = SunburstLayout.segments(focus: focus).filter { $0.depth == 1 }
        #expect(ring1.count == 1)
        #expect(ring1.first?.node?.name == "a")
    }
}
