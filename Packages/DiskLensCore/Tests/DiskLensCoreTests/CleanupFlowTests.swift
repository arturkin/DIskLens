import Foundation
import Testing
@testable import DiskLensCore

/// Exercises the real destructive pipeline the app composes: resolve a node's
/// path, move it to the Trash, then prune the tree. Uses the real Trash (items
/// are recoverable) on temp files.
struct CleanupFlowTests {
    @Test("resolve → trash → prune removes exactly the target and updates totals")
    func endToEnd() throws {
        let t = TempTree()
        let victimURL = t.file("victim.bin", bytes: 9000)
        t.file("keep.bin", bytes: 5000)
        let tree = try DiskScanner().scan(ScanOptions(root: t.root)).tree

        let victim = try #require(tree.root.child("victim.bin"))
        let url = try #require(
            NodeLocator.absoluteURL(scannedRoot: tree.scannedRoot, root: tree.root, target: victim))

        // The exact safety guard the app applies before deleting.
        #expect(url.lastPathComponent == victim.name)
        #expect(url.standardizedFileURL.path == victimURL.standardizedFileURL.path)

        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: t.root.appending(path: "keep.bin").path))

        let pruned = TreePruner.prune(tree, removing: [ObjectIdentifier(victim)])
        #expect(pruned.root.child("victim.bin") == nil)
        #expect(pruned.root.child("keep.bin") != nil)
        #expect(pruned.root.fileCount == 1)
    }
}
