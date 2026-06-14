import Foundation

/// A scanned volume's capacity and free space, as reported by the OS at scan
/// time. Lets charts of a whole volume also show free space, the way Disk
/// Utility does — only meaningful when the scanned root is a volume root.
public struct VolumeUsage: Codable, Sendable, Hashable {
    /// Total capacity of the volume, in bytes.
    public let capacity: Int64
    /// Free (available) space, in bytes — matches Disk Utility's "Free".
    public let free: Int64

    public init(capacity: Int64, free: Int64) {
        self.capacity = capacity
        self.free = free
    }

    /// Space the volume reports as occupied (`capacity − free`), never negative.
    public var used: Int64 { max(0, capacity - free) }
}

/// Wraps a scanned volume root with synthetic wedges so a chart shows the whole
/// disk — used folders plus free space (and any space the scan couldn't see).
public enum FreeSpaceDecorator {
    public static let freeSpaceName = "Free space"
    public static let otherSpaceName = "Other space"

    /// Returns a display copy of `root` with up to two synthetic, zero-file leaf
    /// children appended: `Free space` (the volume's free bytes) and, when the
    /// scan accounts for less than the rest of the disk, `Other space` (purgeable
    /// / system-reserved / unreadable bytes). The real children are reused **by
    /// reference**, so node identity — hovering, drilling, the collection bag —
    /// keeps working through the decorated root.
    ///
    /// Returns `root` unchanged when `usage` is nil or reports no capacity, so a
    /// plain folder scan (or a pre-feature run) renders exactly as before.
    public static func decorate(root: FileNode, usage: VolumeUsage?) -> FileNode {
        guard let usage, usage.capacity > 0 else { return root }

        let scanned = max(0, root.sizeOnDisk)
        let free = min(max(0, usage.free), usage.capacity)
        let other = max(0, usage.capacity - free - scanned)

        var children = root.children
        if free > 0 {
            children.append(FileNode(
                name: freeSpaceName, isDirectory: false, sizeOnDisk: free,
                logicalSize: free, modified: nil, fileCount: 0,
                flags: .freeSpace, children: []))
        }
        if other > 0 {
            children.append(FileNode(
                name: otherSpaceName, isDirectory: false, sizeOnDisk: other,
                logicalSize: other, modified: nil, fileCount: 0,
                flags: .unaccountedSpace, children: []))
        }
        return FileNode(
            name: root.name, isDirectory: true, sizeOnDisk: scanned + free + other,
            logicalSize: root.logicalSize, modified: root.modified,
            fileCount: root.fileCount, flags: root.flags, children: children)
    }
}
