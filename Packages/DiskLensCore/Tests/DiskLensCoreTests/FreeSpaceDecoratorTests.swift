import Foundation
import Testing
@testable import DiskLensCore

struct FreeSpaceDecoratorTests {
    /// A root with two real folders totalling `scanned` bytes.
    private func root(scanned: Int64) -> FileNode {
        FileNode(
            name: "/", isDirectory: true, sizeOnDisk: scanned, logicalSize: scanned,
            modified: nil, fileCount: 3,
            children: [
                FileNode(name: "Users", isDirectory: true, sizeOnDisk: scanned * 3 / 4,
                         logicalSize: scanned * 3 / 4, modified: nil, fileCount: 2),
                FileNode(name: "Applications", isDirectory: true, sizeOnDisk: scanned / 4,
                         logicalSize: scanned / 4, modified: nil, fileCount: 1),
            ])
    }

    @Test("no usage leaves the tree untouched")
    func noUsage() {
        let r = root(scanned: 100)
        #expect(FreeSpaceDecorator.decorate(root: r, usage: nil) === r)
        #expect(FreeSpaceDecorator.decorate(root: r, usage: VolumeUsage(capacity: 0, free: 0)) === r)
    }

    @Test("decoration fills the ring to capacity with Free + Other wedges")
    func fullBreakdown() {
        // capacity 494, free 181, scanned 284 → other = 29.
        let r = root(scanned: 284)
        let d = FreeSpaceDecorator.decorate(root: r, usage: VolumeUsage(capacity: 494, free: 181))

        #expect(d !== r)                       // a new display root
        #expect(d.sizeOnDisk == 494)           // ring spans the whole volume
        #expect(d.fileCount == r.fileCount)    // synthetic wedges aren't files

        let free = d.children.first { $0.flags.contains(.freeSpace) }
        #expect(free?.sizeOnDisk == 181)
        let other = d.children.first { $0.flags.contains(.unaccountedSpace) }
        #expect(other?.sizeOnDisk == 29)

        // Real folders survive by reference so drilling/identity keep working.
        #expect(d.children.contains { $0 === r.children[0] })
        #expect(d.children.contains { $0 === r.children[1] })
    }

    @Test("no Other wedge when the scan already accounts for all non-free space")
    func noOtherWedge() {
        let r = root(scanned: 313)             // 313 + 181 == 494
        let d = FreeSpaceDecorator.decorate(root: r, usage: VolumeUsage(capacity: 494, free: 181))
        #expect(d.children.contains { $0.flags.contains(.freeSpace) })
        #expect(!d.children.contains { $0.flags.contains(.unaccountedSpace) })
        #expect(d.sizeOnDisk == 494)
    }

    @Test("free is clamped to capacity and never produces negative Other")
    func clampsFree() {
        let r = root(scanned: 10)
        let d = FreeSpaceDecorator.decorate(root: r, usage: VolumeUsage(capacity: 100, free: 200))
        let free = d.children.first { $0.flags.contains(.freeSpace) }
        #expect(free?.sizeOnDisk == 100)       // clamped to capacity
        #expect(!d.children.contains { $0.flags.contains(.unaccountedSpace) })
    }
}
