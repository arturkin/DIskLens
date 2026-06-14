import Foundation
import Testing
@testable import DiskLensCore

struct DiffEngineTests {
    private func dir(_ name: String, _ children: [FileNode]) -> FileNode {
        let size = children.reduce(0) { $0 + $1.sizeOnDisk }
        return FileNode(name: name, isDirectory: true, sizeOnDisk: size, logicalSize: size,
                        modified: nil, fileCount: Int32(children.count), children: children)
    }
    private func file(_ name: String, _ size: Int64) -> FileNode {
        FileNode(name: name, isDirectory: false, sizeOnDisk: size, logicalSize: size,
                 modified: nil, fileCount: 1)
    }
    private func tree(_ root: FileNode) -> FileTree { FileTree(root: root, scannedRoot: "/x") }

    @Test("an added file appears as a single added change and raises the total")
    func added() {
        let base = tree(dir("root", [file("a", 1000)]))
        let curr = tree(dir("root", [file("a", 1000), file("b", 4000)]))
        let d = DiffEngine.diff(baseline: base, current: curr)

        #expect(d.totalDelta == 4000)
        #expect(d.addedBytes == 4000)
        #expect(d.addedCount == 1)
        let b = d.changes.first { $0.name == "b" }!
        #expect(b.status == .added)
        #expect(b.delta == 4000)
        #expect(!d.changes.contains { $0.name == "a" })   // unchanged not listed
    }

    @Test("a removed file appears as a removed change and lowers the total")
    func removed() {
        let base = tree(dir("root", [file("a", 1000), file("b", 4000)]))
        let curr = tree(dir("root", [file("a", 1000)]))
        let d = DiffEngine.diff(baseline: base, current: curr)

        #expect(d.totalDelta == -4000)
        #expect(d.removedBytes == 4000)
        #expect(d.removedCount == 1)
        #expect(d.changes.first { $0.name == "b" }?.status == .removed)
    }

    @Test("a file that grew is reported with its delta")
    func grew() {
        let base = tree(dir("root", [file("a", 1000)]))
        let curr = tree(dir("root", [file("a", 3500)]))
        let d = DiffEngine.diff(baseline: base, current: curr)
        let a = d.changes.first { $0.name == "a" }!
        #expect(a.status == .grew)
        #expect(a.delta == 2500)
        #expect(d.totalDelta == 2500)
    }

    @Test("nested additions are attributed to the new leaf, not every ancestor")
    func nestedAddition() {
        let base = tree(dir("root", [dir("sub", [file("x", 1000)])]))
        let curr = tree(dir("root", [dir("sub", [file("x", 1000), file("y", 2000)])]))
        let d = DiffEngine.diff(baseline: base, current: curr)

        #expect(d.changes.contains { $0.name == "y" && $0.status == .added })
        // "sub" grew but isn't itself listed as a change (its child is the story).
        #expect(!d.changes.contains { $0.name == "sub" })
        let y = d.changes.first { $0.name == "y" }!
        #expect(y.path == ["sub", "y"])
    }

    @Test("a wholesale-added directory is listed once, not per descendant")
    func addedDirectory() {
        let base = tree(dir("root", [file("keep", 100)]))
        let curr = tree(dir("root", [file("keep", 100), dir("new", [file("x", 500), file("y", 700)])]))
        let d = DiffEngine.diff(baseline: base, current: curr)

        let added = d.changes.filter { $0.status == .added }
        #expect(added.count == 1)
        #expect(added.first?.name == "new")
        #expect(added.first?.currentSize == 1200)
        #expect(!d.changes.contains { $0.name == "x" })
    }

    @Test("changes are sorted by absolute delta, largest first")
    func sorted() {
        let base = tree(dir("root", [file("a", 1000), file("big", 10_000)]))
        let curr = tree(dir("root", [file("a", 1500), file("big", 1000), file("c", 3000)]))
        let d = DiffEngine.diff(baseline: base, current: curr)
        let magnitudes = d.changes.map { abs($0.delta) }
        #expect(magnitudes == magnitudes.sorted(by: >))
    }

    @Test("delta map keys on current nodes for chart tinting")
    func deltaMap() {
        let aOld = file("a", 1000)
        let base = tree(dir("root", [aOld]))
        let aNew = file("a", 2500)
        let currRoot = dir("root", [aNew])
        let curr = tree(currRoot)
        let d = DiffEngine.diff(baseline: base, current: curr)

        #expect(d.deltaByCurrentNode[ObjectIdentifier(aNew)] == 1500)
        #expect(d.deltaByCurrentNode[ObjectIdentifier(currRoot)] == 1500)
    }
}
