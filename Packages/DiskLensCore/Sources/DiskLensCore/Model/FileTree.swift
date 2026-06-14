import Foundation

/// A complete scan result: the root node plus the absolute path it was scanned from.
public struct FileTree: Codable, Sendable {
    public let root: FileNode
    /// Absolute path of the scanned root (e.g. `/Users/me` or `/`).
    public let scannedRoot: String

    public init(root: FileNode, scannedRoot: String) {
        self.root = root
        self.scannedRoot = scannedRoot
    }
}
