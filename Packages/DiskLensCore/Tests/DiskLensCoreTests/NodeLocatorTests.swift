import Foundation
import Testing
@testable import DiskLensCore

struct NodeLocatorTests {
    /// Walk a scanned tree by name to reach a known file.
    private func node(_ tree: FileTree, _ components: [String]) -> FileNode? {
        var current: FileNode? = tree.root
        for name in components {
            current = current?.children.first { $0.name == name }
        }
        return current
    }

    @Test("resolved URL of a scanned node points at the real file on disk")
    func resolvesRealFile() throws {
        let t = TempTree()
        t.file("sub/deep/c.bin", bytes: 4096)
        let tree = try DiskScanner().scan(ScanOptions(root: t.root)).tree

        let target = try #require(node(tree, ["sub", "deep", "c.bin"]))
        let url = try #require(
            NodeLocator.absoluteURL(scannedRoot: tree.scannedRoot, root: tree.root, target: target))

        #expect(url.lastPathComponent == "c.bin")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.standardizedFileURL.path == t.root.appending(path: "sub/deep/c.bin").standardizedFileURL.path)
    }

    @Test("root resolves to the scanned root path")
    func resolvesRoot() throws {
        let t = TempTree()
        t.file("a.bin", bytes: 10)
        let tree = try DiskScanner().scan(ScanOptions(root: t.root)).tree

        let url = try #require(
            NodeLocator.absoluteURL(scannedRoot: tree.scannedRoot, root: tree.root, target: tree.root))
        #expect(url.standardizedFileURL.path == t.root.standardizedFileURL.path)
        #expect(NodeLocator.namePath(from: tree.root, to: tree.root) == [])
    }

    @Test("a node not in the tree returns nil")
    func notFound() throws {
        let t = TempTree()
        t.file("a.bin", bytes: 10)
        let tree = try DiskScanner().scan(ScanOptions(root: t.root)).tree
        let stranger = FileNode(name: "ghost", isDirectory: false, sizeOnDisk: 1, logicalSize: 1,
                                modified: nil, fileCount: 1)
        #expect(NodeLocator.namePath(from: tree.root, to: stranger) == nil)
        #expect(NodeLocator.absoluteURL(scannedRoot: tree.scannedRoot, root: tree.root, target: stranger) == nil)
    }
}
