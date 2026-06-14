import Foundation

/// Bit flags describing notable properties of a scanned node.
public struct NodeFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    /// The node is a symbolic link (not followed during scanning).
    public static let symlink = NodeFlags(rawValue: 1 << 0)
    /// The node is a macOS package/bundle (e.g. `.app`, `.bundle`).
    public static let package = NodeFlags(rawValue: 1 << 1)
    /// The directory could not be read (permission denied); children are unknown.
    public static let permissionDenied = NodeFlags(rawValue: 1 << 2)
    /// The directory is a mount point for a different volume.
    public static let mountPoint = NodeFlags(rawValue: 1 << 3)
    /// A synthetic node aggregating files below the retain threshold.
    public static let aggregatedSmallFiles = NodeFlags(rawValue: 1 << 4)
}

/// An immutable node in a scanned file tree.
///
/// Built bottom-up by the scanner and frozen on completion, so it is safe to
/// hand across concurrency domains (`Sendable`). The full path of a node is
/// reconstructed by walking parent names from the tree root; nodes deliberately
/// do not store absolute paths to keep large trees compact.
public final class FileNode: Codable, Sendable {
    /// The final path component (e.g. `Photos`), not an absolute path.
    public let name: String
    public let isDirectory: Bool
    /// Aggregated allocated size on disk in bytes (children included).
    public let sizeOnDisk: Int64
    /// Aggregated logical size in bytes (children included).
    public let logicalSize: Int64
    /// Content modification date, when available.
    public let modified: Date?
    /// Recursive count of regular files at or below this node.
    public let fileCount: Int32
    public let flags: NodeFlags
    /// Child nodes; empty for files and aggregated leaves.
    public let children: [FileNode]

    public init(
        name: String,
        isDirectory: Bool,
        sizeOnDisk: Int64,
        logicalSize: Int64,
        modified: Date?,
        fileCount: Int32,
        flags: NodeFlags = [],
        children: [FileNode] = []
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.sizeOnDisk = sizeOnDisk
        self.logicalSize = logicalSize
        self.modified = modified
        self.fileCount = fileCount
        self.flags = flags
        self.children = children
    }
}
