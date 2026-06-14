import Foundation
import Testing
@testable import DiskLensCore

struct ScannerTests {

    @Test("scans a flat directory: structure, logical sizes, file count")
    func flatDirectory() throws {
        let t = TempTree()
        t.file("a.txt", bytes: 10_000)
        t.file("b.txt", bytes: 20_000)

        let result = try DiskScanner().scan(ScanOptions(root: t.root))
        let root = result.tree.root

        #expect(root.isDirectory)
        #expect(root.fileCount == 2)
        #expect(root.child("a.txt")?.logicalSize == 10_000)
        #expect(root.child("b.txt")?.logicalSize == 20_000)
        // Allocated size is block-rounded and at least the logical size.
        let a = try #require(root.child("a.txt"))
        #expect(a.sizeOnDisk % 512 == 0)
        #expect(a.sizeOnDisk >= a.logicalSize)
        // Parent total covers its children plus its own directory blocks.
        #expect(root.sizeOnDisk >= root.children.reduce(0) { $0 + $1.sizeOnDisk })
    }

    @Test("getattrlistbulk and lstat listing paths produce identical trees")
    func bulkMatchesLstat() throws {
        let t = TempTree()
        t.file("a.txt", bytes: 10_000)
        t.file("sub/b.bin", bytes: 30_000)
        t.file("sub/deep/c.dat", bytes: 7_000)
        let original = t.file("sub/orig.bin", bytes: 12_000)
        t.hardlink("sub/deep/link.bin", to: original)   // hard link → dedupe on both paths
        t.symlink("sub/ptr", to: original)              // symlink → not followed

        let bulk = try DiskScanner().scan(ScanOptions(root: t.root))
        var lstatScanner = DiskScanner()
        lstatScanner.forceLstatListing = true
        let lstat = try lstatScanner.scan(ScanOptions(root: t.root))

        #expect(bulk.stats == lstat.stats)
        #expect(bulk.tree.root.sizeOnDisk == lstat.tree.root.sizeOnDisk)
        assertSameTree(bulk.tree.root, lstat.tree.root)
    }

    /// Recursively asserts two scanned trees are structurally and numerically equal
    /// (children matched by name, since both paths sort by size).
    private func assertSameTree(_ a: FileNode, _ b: FileNode) {
        #expect(a.name == b.name)
        #expect(a.isDirectory == b.isDirectory)
        #expect(a.sizeOnDisk == b.sizeOnDisk)
        #expect(a.logicalSize == b.logicalSize)
        #expect(a.fileCount == b.fileCount)
        #expect(a.flags == b.flags)
        #expect(a.children.count == b.children.count)
        for childA in a.children {
            guard let childB = b.children.first(where: { $0.name == childA.name }) else {
                Issue.record("missing child \(childA.name) in lstat tree"); continue
            }
            assertSameTree(childA, childB)
        }
    }

    @Test("a hard link spanning two parallel subtrees is counted once")
    func crossSubtreeHardlinkDedupe() throws {
        // dirA and dirB are separate root children → walked by separate parallel
        // SubWalks. The shared inode set must still dedupe the link between them.
        let t = TempTree()
        let original = t.file("dirA/orig.bin", bytes: 64_000)
        t.dir("dirB")
        t.hardlink("dirB/link.bin", to: original)

        let result = try DiskScanner().scan(ScanOptions(root: t.root))
        #expect(result.stats.hardlinksDeduped == 1)
        // Total counts the 64 KB once, not twice (du-equivalent).
        #expect(result.tree.root.sizeOnDisk == t.duBytes())
    }

    @Test("nested directories aggregate descendant sizes and counts")
    func nested() throws {
        let t = TempTree()
        t.file("sub/c.bin", bytes: 30_000)
        t.file("top.bin", bytes: 5_000)

        let root = try DiskScanner().scan(ScanOptions(root: t.root)).tree.root
        let sub = try #require(root.child("sub"))
        #expect(sub.child("c.bin")?.logicalSize == 30_000)
        #expect(sub.fileCount == 1)
        #expect(root.fileCount == 2)
        #expect(root.logicalSize >= 35_000)
    }

    @Test("hard links count toward disk size only once")
    func hardLinks() throws {
        let t = TempTree()
        let orig = t.file("orig.bin", bytes: 50_000)
        t.hardlink("dup.bin", to: orig)

        let result = try DiskScanner().scan(ScanOptions(root: t.root))
        let root = result.tree.root

        #expect(root.fileCount == 2)
        #expect(result.stats.hardlinksDeduped == 1)
        let sizes = [root.child("orig.bin")!.sizeOnDisk, root.child("dup.bin")!.sizeOnDisk].sorted()
        #expect(sizes[0] == 0)            // the second-seen link contributes nothing
        #expect(sizes[1] > 0)
        // The directory only counts the data once.
        #expect(root.sizeOnDisk >= sizes[1])
        #expect(root.sizeOnDisk < sizes[1] * 2)
    }

    @Test("symlinks are flagged and never followed")
    func symlinks() throws {
        let t = TempTree()
        let realDir = t.dir("real")
        t.file("real/big.bin", bytes: 40_000)
        t.symlink("link", to: realDir)

        let result = try DiskScanner().scan(ScanOptions(root: t.root))
        let root = result.tree.root
        let link = try #require(root.child("link"))

        #expect(link.flags.contains(.symlink))
        #expect(link.children.isEmpty)        // not followed into `real`
        #expect(result.stats.symlinks == 1)
    }

    @Test("minRetainedSize folds tiny files into one aggregate node")
    func smallFileAggregation() throws {
        let t = TempTree()
        t.file("big.bin", bytes: 200_000)
        for i in 0..<5 { t.file("tiny\(i).txt", bytes: 8) }

        // Threshold above one allocation block so the 8-byte files (which still
        // occupy a 4 KB block on disk) fall under it, but big.bin does not.
        let root = try DiskScanner().scan(ScanOptions(root: t.root, minRetainedSize: 16_384)).tree.root

        #expect(root.child("big.bin") != nil)
        for i in 0..<5 { #expect(root.child("tiny\(i).txt") == nil) }
        let agg = try #require(root.children.first { $0.flags.contains(.aggregatedSmallFiles) })
        #expect(agg.fileCount == 5)
        #expect(root.fileCount == 6)
    }

    @Test("excludePaths are skipped entirely")
    func excludePaths() throws {
        let t = TempTree()
        t.file("keep/a.bin", bytes: 10_000)
        t.file("skip/b.bin", bytes: 10_000)

        let opts = ScanOptions(root: t.root, excludePaths: [t.root.appending(path: "skip")])
        let root = try DiskScanner().scan(opts).tree.root

        #expect(root.child("keep") != nil)
        #expect(root.child("skip") == nil)
        #expect(root.fileCount == 1)
    }

    @Test("packages are collapsed to a single node when treatPackagesAsFiles is on")
    func packagesCollapsed() throws {
        let t = TempTree()
        t.file("Foo.app/Contents/MacOS/bin", bytes: 50_000)

        let collapsed = try DiskScanner().scan(
            ScanOptions(root: t.root, treatPackagesAsFiles: true)).tree.root
        let app = try #require(collapsed.child("Foo.app"))
        #expect(app.flags.contains(.package))
        #expect(app.children.isEmpty)
        #expect(app.sizeOnDisk >= 50_000)
        #expect(app.fileCount == 1)

        let expanded = try DiskScanner().scan(
            ScanOptions(root: t.root, treatPackagesAsFiles: false)).tree.root
        #expect(expanded.child("Foo.app")?.children.isEmpty == false)
    }

    @Test("a pre-cancelled scan throws CancellationError")
    func cancellation() throws {
        let t = TempTree()
        t.file("a.bin", bytes: 1000)
        let token = ScanCancellation()
        token.cancel()
        #expect(throws: CancellationError.self) {
            _ = try DiskScanner().scan(ScanOptions(root: t.root), cancellation: token)
        }
    }

    @Test("progress is reported and the final event totals every file")
    func progress() throws {
        let t = TempTree()
        for i in 0..<20 { t.file("f\(i).bin", bytes: 1000) }

        let collector = ProgressCollector()
        let result = try DiskScanner(progressInterval: 4).scan(
            ScanOptions(root: t.root), progress: { collector.record($0) })

        #expect(!collector.events.isEmpty)
        #expect(collector.last?.filesScanned == 20)
        #expect(result.stats.filesScanned == 20)
    }

    @Test("emits each top-level subtree through the partial callback as it completes")
    func progressivePartials() throws {
        let t = TempTree()
        t.file("alpha/a.bin", bytes: 40_000)
        t.file("beta/b.bin", bytes: 30_000)
        t.file("gamma/deep/c.bin", bytes: 20_000)
        t.file("loose.bin", bytes: 5_000)   // a root-level file is not a parallel unit

        let collector = NodeCollector()
        let result = try DiskScanner().scan(
            ScanOptions(root: t.root), partial: { collector.add($0) })

        // Exactly one partial per top-level subdirectory (the parallel units).
        #expect(Set(collector.nodes.map(\.name)) == ["alpha", "beta", "gamma"])
        #expect(collector.nodes.count == 3)
        // Each partial equals its corresponding final child.
        for node in collector.nodes {
            #expect(node.isDirectory)
            let finalChild = try #require(result.tree.root.child(node.name))
            #expect(node.sizeOnDisk == finalChild.sizeOnDisk)
            #expect(node.fileCount == finalChild.fileCount)
        }
    }

    @Test("total disk size matches du -s for the same tree")
    func matchesDu() throws {
        let t = TempTree()
        t.file("a.bin", bytes: 123_456)
        t.file("nested/b.bin", bytes: 7_777)
        t.file("nested/deep/c.bin", bytes: 1_000_000)

        let root = try DiskScanner().scan(ScanOptions(root: t.root)).tree.root
        #expect(root.sizeOnDisk == t.duBytes())
    }
}
