import Foundation
import Testing
@testable import DiskLensCore

struct TreePrunerTests {
    // Directory size == sum of children (own overhead 0) for deterministic asserts.
    private func dir(_ name: String, _ children: [FileNode]) -> FileNode {
        let size = children.reduce(0) { $0 + $1.sizeOnDisk }
        let files = children.reduce(Int32(0)) { $0 + $1.fileCount }
        return FileNode(name: name, isDirectory: true, sizeOnDisk: size, logicalSize: size,
                        modified: nil, fileCount: files, children: children)
    }
    private func file(_ name: String, _ size: Int64) -> FileNode {
        FileNode(name: name, isDirectory: false, sizeOnDisk: size, logicalSize: size,
                 modified: nil, fileCount: 1)
    }
    private func child(_ node: FileNode, _ name: String) -> FileNode {
        node.children.first { $0.name == name }!
    }

    @Test("removing a leaf shrinks all ancestors and drops the file count")
    func removeLeaf() {
        let a = file("a", 1000)
        let b = file("b", 3000)
        let sub = dir("sub", [b])
        let root = dir("root", [a, sub])
        let tree = FileTree(root: root, scannedRoot: "/x")

        let pruned = TreePruner.prune(tree, removing: [ObjectIdentifier(a)])
        #expect(pruned.root.sizeOnDisk == 3000)         // lost a (1000)
        #expect(pruned.root.fileCount == 1)
        #expect(pruned.root.child("a") == nil)
        #expect(pruned.root.child("sub")?.sizeOnDisk == 3000)  // untouched branch
    }

    @Test("removing a directory removes its whole subtree from the totals")
    func removeSubtree() {
        let b = file("b", 3000)
        let sub = dir("sub", [b])
        let a = file("a", 1000)
        let root = dir("root", [a, sub])
        let tree = FileTree(root: root, scannedRoot: "/x")

        let pruned = TreePruner.prune(tree, removing: [ObjectIdentifier(sub)])
        #expect(pruned.root.sizeOnDisk == 1000)
        #expect(pruned.root.fileCount == 1)
        #expect(pruned.root.child("sub") == nil)
    }

    @Test("a directory's own overhead is preserved when a child is removed")
    func preservesOwnOverhead() {
        let a = file("a", 1000)
        // Directory with 500 bytes of its own overhead beyond its child.
        let root = FileNode(name: "root", isDirectory: true, sizeOnDisk: 1500,
                            logicalSize: 1500, modified: nil, fileCount: 1, children: [a])
        let tree = FileTree(root: root, scannedRoot: "/x")

        let pruned = TreePruner.prune(tree, removing: [ObjectIdentifier(a)])
        #expect(pruned.root.sizeOnDisk == 500)   // child gone, own overhead remains
        #expect(pruned.root.fileCount == 0)
    }

    @Test("removing a deep grandchild updates every ancestor, not just its parent")
    func removeDeepGrandchild() {
        // root keeps the same number of children (just `mid`), and `mid` keeps a
        // surviving child (`keep`). Removing `victim` must still shrink root.
        let victim = file("victim", 7000)
        let keep = file("keep", 1000)
        let mid = dir("mid", [keep, victim])
        let root = dir("root", [mid])
        let tree = FileTree(root: root, scannedRoot: "/x")

        let pruned = TreePruner.prune(tree, removing: [ObjectIdentifier(victim)])
        #expect(pruned.root.sizeOnDisk == 1000)                       // 8000 − 7000
        #expect(pruned.root.fileCount == 1)
        #expect(pruned.root.child("mid")?.sizeOnDisk == 1000)
        #expect(pruned.root.child("mid")?.child("victim") == nil)
        #expect(pruned.root.child("mid")?.child("keep") != nil)
    }

    @Test("removing nothing returns an equivalent tree")
    func removeNothing() {
        let root = dir("root", [file("a", 10), file("b", 20)])
        let pruned = TreePruner.prune(FileTree(root: root, scannedRoot: "/x"), removing: [])
        #expect(pruned.root.sizeOnDisk == 30)
        #expect(pruned.root.children.count == 2)
    }
}
