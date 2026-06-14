import Foundation

/// Reconstructs absolute file paths for nodes (which store only their name).
/// Used before any destructive action, so correctness here is safety-critical.
public enum NodeLocator {
    /// Component names from `root` down to `target` (excluding the root's own
    /// name), or nil if `target` isn't in the tree. Matches by object identity.
    public static func namePath(from root: FileNode, to target: FileNode) -> [String]? {
        if root === target { return [] }
        for child in root.children {
            if let tail = namePath(from: child, to: target) { return [child.name] + tail }
        }
        return nil
    }

    /// Absolute file URL of `target`, given the tree's scanned-root path.
    public static func absoluteURL(scannedRoot: String, root: FileNode, target: FileNode) -> URL? {
        guard let names = namePath(from: root, to: target) else { return nil }
        var url = URL(filePath: scannedRoot)
        for name in names { url.append(path: name) }
        return url
    }
}
